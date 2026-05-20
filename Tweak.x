#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _v_en = YES;
static NSString *_v_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_v_p = nil;
static AVPlayerItemVideoOutput *_v_o = nil;
static CVPixelBufferRef _v_b = NULL;
static CIContext *_v_c = nil;

static void _v_load() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _v_en = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) _v_url = p[@"rtspURL"];
    }
}

static void _v_sync() {
    if (!_v_o || !_v_en || !_v_p) return;
    CMTime t = [_v_p.currentItem currentTime];
    if ([_v_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_v_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            CVPixelBufferRef old = _v_b;
            _v_b = pb;
            if (old) CVPixelBufferRelease(old);
        }
    }
}

%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    _v_sync();
    return (_v_en && _v_b) ? CVPixelBufferRetain(_v_b) : %orig;
}
- (NSData *)fileDataRepresentation {
    _v_sync();
    if (_v_en && _v_b) {
        if (!_v_c) _v_c = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_v_b];
        CGImageRef cg = [_v_c createCGImage:ci fromRect:ci.extent];
        if (cg) {
            UIImage *ui = [UIImage imageWithCGImage:cg];
            NSData *d = UIImageJPEGRepresentation(ui, 0.9);
            CGImageRelease(cg);
            return d;
        }
    }
    return %orig;
}
%end

@interface VCPVideoDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id orig;
@end
@implementation VCPVideoDelegate
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_v_en && _v_b) {
        _v_sync();
        CMSampleBufferRef nb = NULL;
        CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _v_b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _v_b, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            if ([self.orig respondsToSelector:_cmd]) [self.orig captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd);
            return;
        }
    }
    if ([self.orig respondsToSelector:_cmd]) [self.orig captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_v_en && d && ![d isKindOfClass:[VCPVideoDelegate class]]) {
        VCPVideoDelegate *p = [[VCPVideoDelegate alloc] init];
        p.orig = d;
        objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_v_en) return;
    self.hidden = YES;
    if (!_v_p) {
        _v_load();
        _v_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_v_url]];
        _v_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_v_p.currentItem addOutput:_v_o];
        [_v_p play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_v_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _v_sync(); }];
        objc_setAssociatedObject(self, "_vcp_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_vcp_l");
    if (l) l.frame = self.bounds;
}
%end

%ctor { _v_load(); %init; }
