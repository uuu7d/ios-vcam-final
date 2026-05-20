#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _s_e = YES;
static NSString *_s_u = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_s_p = nil;
static AVPlayerItemVideoOutput *_s_o = nil;
static CVPixelBufferRef _s_b = NULL;

static void _fig_log(NSString *m) {
    NSString *f = @"/tmp/.com.apple.media.cache";
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"sys";
    NSString *e = [NSString stringWithFormat:@"[%f] %@: %@\n", [[NSDate date] timeIntervalSince1970], b, m];
    FILE *h = fopen([f UTF8String], "a");
    if (h) { fputs([e UTF8String], h); fclose(h); }
}

static void _s_load() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _s_e = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) _s_u = p[@"rtspURL"];
    }
}

static void _s_sync() {
    if (!_s_o || !_s_e || !_s_p) return;
    CMTime t = [_s_p.currentItem currentTime];
    if ([_s_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_s_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_s_b) CVPixelBufferRelease(_s_b);
            _s_b = pb;
        }
    }
}

@interface FigCapturePhotoInternal : NSObject
@end
@implementation FigCapturePhotoInternal
- (CVPixelBufferRef)pixelBuffer { _s_sync(); return _s_b ? CVPixelBufferRetain(_s_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _s_sync(); return _s_b ? CVPixelBufferRetain(_s_b) : NULL; }
- (NSData *)fileDataRepresentation {
    if (!_s_b) return nil;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_s_b];
    CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:ci.extent];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
    CGImageRelease(cg); return d;
}
- (NSDictionary *)metadata { return @{(id)kCGImagePropertyMakerAppleDictionary: @{@"GhostMode": @YES}}; }
@end

@interface FigCaptureDataSinkInternal : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id _t;
@end
@implementation FigCaptureDataSinkInternal
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_s_e && _s_b) {
        _s_sync();
        CMSampleBufferRef nb = NULL; CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _s_b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _s_b, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_s_e && p && _s_b) { _s_sync(); object_setClass(p, [FigCapturePhotoInternal class]); }
    if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didFinishProcessingPhoto:p error:e];
}
- (BOOL)respondsToSelector:(SEL)a { return [self._t respondsToSelector:a]; }
- (id)forwardingTargetForSelector:(SEL)a { return self._t; }
@end

%hook AVCaptureDevice
- (BOOL)isAdjustingFocus { return NO; }
- (BOOL)isAdjustingExposure { return NO; }
- (BOOL)isAdjustingWhiteBalance { return NO; }
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_s_e && d && ![d isKindOfClass:[FigCaptureDataSinkInternal class]]) {
        FigCaptureDataSinkInternal *p = [[FigCaptureDataSinkInternal alloc] init];
        p._t = d;
        objc_setAssociatedObject(self, "_fig_sink", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (_s_e && d && ![d isKindOfClass:[FigCaptureDataSinkInternal class]]) {
        FigCaptureDataSinkInternal *p = [[FigCaptureDataSinkInternal alloc] init];
        p._t = d;
        objc_setAssociatedObject(self, "_fig_sink_p", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(s, p);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_s_e) return; self.hidden = YES;
    if (!_s_p) {
        _s_load(); _fig_log(@"SYNC_START");
        _s_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_s_u]];
        _s_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_s_p.currentItem addOutput:_s_o]; [_s_p play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_s_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        objc_setAssociatedObject(self, "_fig_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _s_sync(); }];
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_fig_l");
    if (l) l.frame = self.bounds;
}
%end

%ctor { _s_load(); _fig_log(@"INIT"); %init; }
