#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _vcp_enabled = YES;
static NSString *_vcp_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_vcp_player = nil;
static AVPlayerItemVideoOutput *_vcp_out = nil;
static CVPixelBufferRef _vcp_buf = NULL;
static CIContext *_vcp_ctx = nil;
static AVPlayerLayer *_vcp_view = nil;

static void _vcp_load() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _vcp_enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) _vcp_url = p[@"rtspURL"];
    }
}

static void _vcp_sync() {
    if (!_vcp_out || !_vcp_enabled) return;
    CMTime t = [_vcp_player.currentItem currentTime];
    if ([_vcp_out hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_vcp_out copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            CVPixelBufferRef old = _vcp_buf;
            _vcp_buf = pb;
            if (old) CVPixelBufferRelease(old);
        }
    }
}

%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    _vcp_sync();
    return (_vcp_enabled && _vcp_buf) ? CVPixelBufferRetain(_vcp_buf) : %orig;
}
- (CVPixelBufferRef)previewPixelBuffer {
    _vcp_sync();
    return (_vcp_enabled && _vcp_buf) ? CVPixelBufferRetain(_vcp_buf) : %orig;
}
- (CGImageRef)CGImageRepresentation {
    _vcp_sync();
    if (_vcp_enabled && _vcp_buf) {
        if (!_vcp_ctx) _vcp_ctx = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_vcp_buf];
        return [_vcp_ctx createCGImage:ci fromRect:ci.extent];
    }
    return %orig;
}
- (NSData *)fileDataRepresentation {
    _vcp_sync();
    if (_vcp_enabled && _vcp_buf) {
        if (!_vcp_ctx) _vcp_ctx = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_vcp_buf];
        CGImageRef cg = [_vcp_ctx createCGImage:ci fromRect:ci.extent];
        UIImage *ui = [UIImage imageWithCGImage:cg];
        NSData *d = UIImageJPEGRepresentation(ui, 0.9);
        CGImageRelease(cg);
        return d;
    }
    return %orig;
}
%end

@interface VCPVideoProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id _orig;
@end
@implementation VCPVideoProxy
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_vcp_enabled && _vcp_buf) {
        _vcp_sync();
        CMSampleBufferRef nb = NULL;
        CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _vcp_buf, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti;
        CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _vcp_buf, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            if ([self._orig respondsToSelector:_cmd]) [self._orig captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb);
            if (fd) CFRelease(fd);
            return;
        }
    }
    if ([self._orig respondsToSelector:_cmd]) [self._orig captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_vcp_enabled && d && ![d isKindOfClass:[VCPVideoProxy class]]) {
        VCPVideoProxy *p = [[VCPVideoProxy alloc] init];
        p._orig = d;
        objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_vcp_enabled) return;
    self.hidden = YES;
    if (!_vcp_player) {
        _vcp_load();
        _vcp_player = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_vcp_url]];
        _vcp_out = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_vcp_player.currentItem addOutput:_vcp_out];
        [_vcp_player play];
        _vcp_view = [AVPlayerLayer playerLayerWithPlayer:_vcp_player];
        _vcp_view.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:_vcp_view above:self];
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _vcp_sync(); }];
    }
    if (_vcp_view) _vcp_view.frame = self.bounds;
}
%end

%ctor {
    _vcp_load();
    %init;
}
