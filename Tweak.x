#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _c_en = YES;
static NSString *_c_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_c_p = nil;
static AVPlayerItemVideoOutput *_c_o = nil;
static CVPixelBufferRef _c_b = NULL;

static void _c_load_cfg() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _c_en = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) _c_url = p[@"rtspURL"];
    }
}

static void _c_ensure_start() {
    if (_c_en && !_c_p) {
        _c_load_cfg();
        _c_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_c_url]];
        _c_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_c_p.currentItem addOutput:_c_o];
        [_c_p play];
    }
}

static void _c_sync() {
    if (!_c_o || !_c_en || !_c_p) return;
    CMTime t = [_c_p.currentItem currentTime];
    if ([_c_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_c_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_c_b) CVPixelBufferRelease(_c_b);
            _c_b = pb;
        }
    }
}

@interface AVInternalFakePhoto : NSObject
@end
@implementation AVInternalFakePhoto
- (CVPixelBufferRef)pixelBuffer { return _c_b ? CVPixelBufferRetain(_c_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { return _c_b ? CVPixelBufferRetain(_c_b) : NULL; }
- (NSData *)fileDataRepresentation {
    if (!_c_b) return nil;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_c_b];
    CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:ci.extent];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGImageRelease(cg);
    return d;
}
@end

@interface AVInternalDataCaptureSink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id _target;
@end
@implementation AVInternalDataCaptureSink
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    if (_c_en && _c_b) {
        _c_sync();
        CMSampleBufferRef nb = NULL;
        CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _c_b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _c_b, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)p error:(NSError *)e {
    if (_c_en && p && _c_b) {
        _c_sync();
        object_setClass(p, [AVInternalFakePhoto class]);
    }
    if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didFinishProcessingPhoto:p error:e];
}
@end

%hook AVCaptureSession
- (void)startRunning { _c_ensure_start(); %orig; }
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_c_en && d && ![d isKindOfClass:[AVInternalDataCaptureSink class]]) {
        AVInternalDataCaptureSink *p = [[AVInternalDataCaptureSink alloc] init];
        p._target = d;
        objc_setAssociatedObject(self, "_vcp_proxy", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (_c_en && d && ![d isKindOfClass:[AVInternalDataCaptureSink class]]) {
        AVInternalDataCaptureSink *p = [[AVInternalDataCaptureSink alloc] init];
        p._target = d;
        objc_setAssociatedObject(self, "_vcp_proxy_p", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(s, p);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_c_en) return; self.hidden = YES; _c_ensure_start();
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_vcp_l");
    if (!l && _c_p) {
        l = [AVPlayerLayer playerLayerWithPlayer:_c_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        objc_setAssociatedObject(self, "_vcp_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _c_sync(); }];
    }
    if (l) l.frame = self.bounds;
}
%end

%ctor { _c_load_cfg(); %init; }
