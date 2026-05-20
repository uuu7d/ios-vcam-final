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
    CMTime t = [_sys_p.currentItem currentTime];
    if ([_sys_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_sys_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_sys_b) CVPixelBufferRelease(_sys_b);
            _sys_b = pb;
        }
    }
}

// --- ХУКИ ДЛЯ ФОТО ---
@interface AppleInternalPhoto : AVCapturePhoto
@end
@implementation AppleInternalPhoto
- (CVPixelBufferRef)pixelBuffer { _sys_sync(); return _sys_b ? CVPixelBufferRetain(_sys_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _sys_sync(); return _sys_b ? CVPixelBufferRetain(_sys_b) : NULL; }
- (CGImageRef)CGImageRepresentation {
    _sys_sync(); if (!_sys_b) return NULL;
    if (!_sys_c) _sys_c = [[CIContext alloc] initWithOptions:nil];
    return [_sys_c createCGImage:[CIImage imageWithCVPixelBuffer:_sys_b] fromRect:CGRectMake(0,0,CVPixelBufferGetWidth(_sys_b),CVPixelBufferGetHeight(_sys_b))];
}
- (NSData *)fileDataRepresentation {
    _sys_sync(); if (!_sys_b) return nil;
    CGImageRef cg = [self CGImageRepresentation];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGImageRelease(cg); return d;
}
- (NSDictionary *)metadata { return @{}; }
@end

// --- ПРОКСИ ДЛЯ WEBKIT И ВСЕГО ОСТАЛЬНОГО ---
@interface AppleInternalSink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) id _target;
@end

@implementation AppleInternalSink
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_sys_en && _sys_b) {
        _sys_sync();
        CMSampleBufferRef nb = NULL;
        CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _sys_b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        
        // Для WebKit/WebRTC критически важно использовать kCFAllocatorDefault
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _sys_b, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        
        if (nb) {
            if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb);
            if (fd) CFRelease(fd);
            return;
        }
    }
    if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}

- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_sys_en && p && _sys_b) { _sys_sync(); object_setClass(p, [AppleInternalPhoto class]); }
    if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didFinishProcessingPhoto:p error:e];
}

- (BOOL)respondsToSelector:(SEL)a { return [self._target respondsToSelector:a]; }
- (id)forwardingTargetForSelector:(SEL)a { return self._target; }
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_sys_en && d && ![d isKindOfClass:[AppleInternalSink class]]) {
        AppleInternalSink *p = [[AppleInternalSink alloc] init];
        p._target = d;
        objc_setAssociatedObject(self, "_v_proxy", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

// Дополнительный хук для WebKit (иногда они используют MetadataOutput для анализа кадра)
%hook AVCaptureMetadataOutput
- (void)setMetadataObjectsDelegate:(id)d queue:(id)q {
    if (_sys_en && d && ![d isKindOfClass:[AppleInternalSink class]]) {
        AppleInternalSink *p = [[AppleInternalSink alloc] init];
        p._target = d;
        objc_setAssociatedObject(self, "_m_proxy", p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_sys_en) return; self.hidden = YES;
    if (!_sys_p) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) { _sys_en = [prefs[@"enabled"] boolValue]; _sys_url = prefs[@"rtspURL"] ?: _sys_url; }
        _sys_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_sys_url]];
        // Добавляем поддержку разных форматов пикселей
        _sys_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_sys_p.currentItem addOutput:_sys_o];
        [_sys_p play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_sys_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        objc_setAssociatedObject(self, "_l_v", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _sys_sync(); }];
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_l_v");
    if (l) l.frame = self.bounds;
}
%end

%ctor { %init; }
