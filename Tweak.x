#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _sys_en = YES;
static NSString *_sys_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_sys_p = nil;
static AVPlayerItemVideoOutput *_sys_o = nil;
static CVPixelBufferRef _sys_b = NULL;
static CIContext *_sys_c = nil;

static void _sys_sync() {
    if (!_sys_o || !_sys_en || !_sys_p) return;
    if (_sys_p.status != AVPlayerStatusReadyToPlay) return;
    
    CMTime t = [_sys_p.currentItem currentTime];
    if ([_sys_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_sys_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_sys_b) CVPixelBufferRelease(_sys_b);
            _sys_b = pb;
        }
    }
}

static void _sys_ensure_alive() {
    if (_sys_en && (!_sys_p || _sys_p.error || _sys_p.status == AVPlayerStatusFailed)) {
        _sys_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_sys_url]];
        _sys_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_sys_p.currentItem addOutput:_sys_o];
        _sys_p.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        [_sys_p play];
    }
}

@interface AppleInternalPhoto : AVCapturePhoto
@end
@implementation AppleInternalPhoto
- (CVPixelBufferRef)pixelBuffer { _sys_sync(); return _sys_b ? CVPixelBufferRetain(_sys_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _sys_sync(); return _sys_b ? CVPixelBufferRetain(_sys_b) : NULL; }
- (NSData *)fileDataRepresentation {
    _sys_sync(); if (!_sys_b) return nil;
    if (!_sys_c) _sys_c = [[CIContext alloc] initWithOptions:nil];
    CGImageRef cg = [_sys_c createCGImage:[CIImage imageWithCVPixelBuffer:_sys_b] fromRect:CGRectMake(0,0,CVPixelBufferGetWidth(_sys_b),CVPixelBufferGetHeight(_sys_b))];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGImageRelease(cg); return d;
}
- (NSDictionary *)metadata { return @{}; }
@end

@interface AppleInternalSink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) id _t;
@end
@implementation AppleInternalSink
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_sys_en && _sys_b) {
        _sys_sync();
        CMSampleBufferRef nb = NULL; CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _sys_b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _sys_b, YES, NULL, NULL, fd, &ti, &nb);
        if (nb) {
            if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if (!_sys_en && [self._t respondsToSelector:_cmd]) [self._t captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_sys_en && p && _sys_b) { _sys_sync(); object_setClass(p, [AppleInternalPhoto class]); }
    if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didFinishProcessingPhoto:p error:e];
}
- (BOOL)respondsToSelector:(SEL)a { return [self._t respondsToSelector:a]; }
- (id)forwardingTargetForSelector:(SEL)a { return self._t; }
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_sys_en && d && ![d isKindOfClass:[AppleInternalSink class]]) {
        AppleInternalSink *p = [[AppleInternalSink alloc] init]; p._t = d;
        objc_setAssociatedObject(self, "_p_v", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (_sys_en && d && ![d isKindOfClass:[AppleInternalSink class]]) {
        AppleInternalSink *p = [[AppleInternalSink alloc] init]; p._t = d;
        objc_setAssociatedObject(self, "_p_p", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(s, p);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_sys_en) return; self.hidden = YES; _sys_ensure_alive();
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_l");
    if (!l && _sys_p) {
        l = [AVPlayerLayer playerLayerWithPlayer:_sys_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        objc_setAssociatedObject(self, "_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _sys_sync(); _sys_ensure_alive(); }];
    }
    if (l) l.frame = self.bounds;
}
%end

%ctor { 
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) { _sys_en = [p[@"enabled"] boolValue]; _sys_url = p[@"rtspURL"] ?: _sys_url; }
    %init; 
}
