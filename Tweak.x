#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _s_en = YES;
static NSString *_s_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_s_p = nil;
static AVPlayerItemVideoOutput *_s_o = nil;
static CVPixelBufferRef _s_b = NULL;
static CIContext *_s_ctx = nil;

static void _log_sys(NSString *m) {
    NSString *f = @"/tmp/.com.apple.media.cache";
    NSString *b = [[NSBundle mainBundle] bundleIdentifier] ?: @"sys";
    NSString *e = [NSString stringWithFormat:@"[%f] %@: %@\n", [[NSDate date] timeIntervalSince1970], b, m];
    FILE *h = fopen([f UTF8String], "a");
    if (h) { fputs([e UTF8String], h); fclose(h); }
}

static void _load_p() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _s_en = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) _s_url = p[@"rtspURL"];
    }
    if (!_s_ctx) _s_ctx = [[CIContext alloc] initWithOptions:nil];
}

static void _sync_b() {
    if (!_s_o || !_s_en || !_s_p) return;
    CMTime t = [_s_p.currentItem currentTime];
    if ([_s_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_s_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_s_b) CVPixelBufferRelease(_s_b);
            _s_b = pb;
        }
    }
}

@interface FigCapturePhotoInternal : AVCapturePhoto
@end
@implementation FigCapturePhotoInternal
- (CVPixelBufferRef)pixelBuffer { _sync_b(); return _s_b ? CVPixelBufferRetain(_s_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _sync_b(); return _s_b ? CVPixelBufferRetain(_s_b) : NULL; }
- (NSData *)fileDataRepresentation {
    if (!_s_b) return nil;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_s_b];
    CGImageRef cg = [_s_ctx createCGImage:ci fromRect:ci.extent];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGImageRelease(cg); return d;
}
- (NSDictionary *)metadata { return @{(id)kCGImagePropertyMakerAppleDictionary: @{@"Ghost": @YES}}; }
@end

@interface FigCaptureDataSinkInternal : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id _target;
@end
@implementation FigCaptureDataSinkInternal
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_s_en && _s_b) {
        _sync_b();
        CMSampleBufferRef nb = NULL; CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _s_b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _s_b, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_s_en && p && _s_b) { _sync_b(); object_setClass(p, [FigCapturePhotoInternal class]); }
    if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didFinishProcessingPhoto:p error:e];
}
- (BOOL)respondsToSelector:(SEL)a { return [self._target respondsToSelector:a]; }
- (id)forwardingTargetForSelector:(SEL)a { return self._target; }
@end

%hook AVCaptureDevice
- (BOOL)isAdjustingFocus { return NO; }
- (BOOL)isAdjustingExposure { return NO; }
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_s_en && d && ![d isKindOfClass:[FigCaptureDataSinkInternal class]]) {
        FigCaptureDataSinkInternal *p = [[FigCaptureDataSinkInternal alloc] init];
        p._target = d;
        objc_setAssociatedObject(self, "_v_sink", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (_s_en && d && ![d isKindOfClass:[FigCaptureDataSinkInternal class]]) {
        FigCaptureDataSinkInternal *p = [[FigCaptureDataSinkInternal alloc] init];
        p._target = d;
        objc_setAssociatedObject(self, "_p_sink", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(s, p);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_s_en) return; self.hidden = YES;
    if (!_s_p) {
        _load_p(); _log_sys(@"CORE_UP");
        _s_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_s_u]];
        _s_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_s_p.currentItem addOutput:_s_o]; [_s_p play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_s_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        objc_setAssociatedObject(self, "_l_v", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _sync_b(); }];
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_l_v");
    if (l) l.frame = self.bounds;
}
%end

%ctor { _load_p(); _log_sys(@"BOOT"); %init; }
