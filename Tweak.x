#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _sys_enabled = YES;
static NSString *_sys_source = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_sys_player = nil;
static AVPlayerItemVideoOutput *_sys_output = nil;
static CVPixelBufferRef _sys_buffer = NULL;
static CIContext *_sys_context = nil;

static void _sys_sync_frame() {
    if (!_sys_output || !_sys_enabled || !_sys_player) return;
    CMTime t = [_sys_player.currentItem currentTime];
    if ([_sys_output hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_sys_output copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_sys_buffer) CVPixelBufferRelease(_sys_buffer);
            _sys_buffer = pb;
        }
    }
}

@interface AppleInternalPhotoCapture : AVCapturePhoto
@end
@implementation AppleInternalPhotoCapture
- (CVPixelBufferRef)pixelBuffer { _sys_sync_frame(); return _sys_buffer ? CVPixelBufferRetain(_sys_buffer) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _sys_sync_frame(); return _sys_buffer ? CVPixelBufferRetain(_sys_buffer) : NULL; }
- (CGImageRef)CGImageRepresentation {
    _sys_sync_frame(); if (!_sys_buffer) return NULL;
    if (!_sys_context) _sys_context = [[CIContext alloc] initWithOptions:nil];
    return [_sys_context createCGImage:[CIImage imageWithCVPixelBuffer:_sys_buffer] fromRect:CGRectMake(0,0,CVPixelBufferGetWidth(_sys_buffer),CVPixelBufferGetHeight(_sys_buffer))];
}
- (NSData *)fileDataRepresentation {
    if (!_sys_buffer) return nil;
    CGImageRef cg = [self CGImageRepresentation];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGImageRelease(cg); return d;
}
- (NSDictionary *)metadata { return @{}; }
@end

@interface AppleInternalDataSink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) id _original_target;
@end
@implementation AppleInternalDataSink
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_sys_enabled && _sys_buffer) {
        _sys_sync_frame();
        CMSampleBufferRef nb = NULL; CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _sys_buffer, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _sys_buffer, YES, NULL, NULL, fd, &ti, &nb);
        if (nb) {
            if ([self._original_target respondsToSelector:_cmd]) [self._original_target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self._original_target respondsToSelector:_cmd]) [self._original_target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_sys_enabled && p && _sys_buffer) { _sys_sync_frame(); object_setClass(p, [AppleInternalPhotoCapture class]); }
    if ([self._original_target respondsToSelector:_cmd]) [self._original_target captureOutput:o didFinishProcessingPhoto:p error:e];
}
- (BOOL)respondsToSelector:(SEL)a { return [self._original_target respondsToSelector:a]; }
- (id)forwardingTargetForSelector:(SEL)a { return self._original_target; }
@end

%hook AVCaptureDevice
- (BOOL)isAdjustingFocus { return NO; }
- (BOOL)isAdjustingExposure { return NO; }
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_sys_enabled && d && ![d isKindOfClass:[AppleInternalDataSink class]]) {
        AppleInternalDataSink *p = [[AppleInternalDataSink alloc] init]; p._original_target = d;
        objc_setAssociatedObject(self, "_apple_internal_proxy", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCaptureMetadataOutput
- (void)setMetadataObjectsDelegate:(id)d queue:(id)q {
    if (_sys_enabled && d && ![d isKindOfClass:[AppleInternalDataSink class]]) {
        AppleInternalDataSink *p = [[AppleInternalDataSink alloc] init]; p._original_target = d;
        objc_setAssociatedObject(self, "_apple_internal_proxy_m", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (_sys_enabled && d && ![d isKindOfClass:[AppleInternalDataSink class]]) {
        AppleInternalDataSink *p = [[AppleInternalDataSink alloc] init]; p._original_target = d;
        objc_setAssociatedObject(self, "_apple_internal_proxy_p", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(s, p);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_sys_enabled) return; self.hidden = YES;
    if (!_sys_player) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) { _sys_enabled = [prefs[@"enabled"] boolValue]; _sys_source = prefs[@"rtspURL"] ?: _sys_source; }
        _sys_player = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_sys_source]];
        _sys_output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_sys_player.currentItem addOutput:_sys_output]; [_sys_player play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_sys_player];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        objc_setAssociatedObject(self, "_apple_layer", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _sys_sync_frame(); }];
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_apple_layer");
    if (l) l.frame = self.bounds;
}
%end

%ctor { %init; }
