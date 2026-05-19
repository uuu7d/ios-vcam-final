#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _sys_enabled = YES;
static NSString *_sys_data_src = @"http://192.168.1.44:8888/live/stream/index.m3u8";

static AVPlayer *_internalPlayer = nil;
static AVPlayerItemVideoOutput *_internalOutput = nil;
static CVPixelBufferRef _internalBuffer = NULL;
static CIContext *_internalCtx = nil;

static void _update_internal_config() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _sys_enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        NSString *u = p[@"rtspURL"];
        if (u && u.length > 0) _sys_data_src = u;
    }
}

static void _sync_buffer() {
    if (!_internalOutput || !_sys_enabled || !_internalPlayer) return;
    CMTime t = [_internalPlayer.currentItem currentTime];
    if ([_internalOutput hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_internalOutput copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            CVPixelBufferRef old = _internalBuffer;
            _internalBuffer = pb; 
            if (old) CVPixelBufferRelease(old);
        }
    }
}

@interface AVCaptureDataOutputInternalDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id _orig_delegate;
@end

@implementation AVCaptureDataOutputInternalDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sbuf fromConnection:(AVCaptureConnection *)conn {
    if (_sys_enabled && _internalBuffer) {
        _sync_buffer();
        CMSampleBufferRef nb = NULL;
        CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _internalBuffer, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti;
        CMSampleBufferGetSampleTimingInfo(sbuf, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _internalBuffer, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            if ([self._orig_delegate respondsToSelector:_cmd]) {
                [self._orig_delegate captureOutput:output didOutputSampleBuffer:nb fromConnection:conn];
            }
            CFRelease(nb);
            if (fd) CFRelease(fd);
            return;
        }
    }
    if ([self._orig_delegate respondsToSelector:_cmd]) {
        [self._orig_delegate captureOutput:output didOutputSampleBuffer:sbuf fromConnection:conn];
    }
}
@end

%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    _sync_buffer();
    return (_sys_enabled && _internalBuffer) ? CVPixelBufferRetain(_internalBuffer) : %orig;
}
- (NSData *)fileDataRepresentation {
    _sync_buffer();
    if (_sys_enabled && _internalBuffer) {
        if (!_internalCtx) _internalCtx = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_internalBuffer];
        CGImageRef cg = [_internalCtx createCGImage:ci fromRect:ci.extent];
        if (cg) {
            UIImage *ui = [UIImage imageWithCGImage:cg];
            NSData *d = UIImageJPEGRepresentation(ui, 0.85);
            CGImageRelease(cg);
            return d;
        }
    }
    return %orig;
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)q {
    if (_sys_enabled && delegate && ![delegate isKindOfClass:[AVCaptureDataOutputInternalDelegate class]]) {
        AVCaptureDataOutputInternalDelegate *proxy = [[AVCaptureDataOutputInternalDelegate alloc] init];
        proxy._orig_delegate = delegate;
        objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(proxy, q);
    } else {
        %orig;
    }
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_sys_enabled) return;
    self.hidden = YES;
    if (!_internalPlayer) {
        _update_internal_config();
        _internalPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_sys_data_src]];
        _internalOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_internalPlayer.currentItem addOutput:_internalOutput];
        [_internalPlayer play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_internalPlayer];
        l.frame = self.bounds;
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _sync_buffer(); }];
    }
}
%end

%ctor {
    _update_internal_config();
    %init;
}
