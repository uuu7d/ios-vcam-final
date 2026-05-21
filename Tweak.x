#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>

// --- STEALTH DEFINITIONS ---
#define PREFS_PATH @"/var/mobile/Library/Preferences/com.apple.avfoundation.cache.plist"
#define HIDDEN_LOG @"/tmp/.sys_media_info_cache"

@interface AVPlayerItemVideoOutput (VCamInternal)
- (BOOL)hasNewPixelBufferForTime:(CMTime)t;
- (CVPixelBufferRef)copyPixelBufferForTime:(CMTime)t itemTimeForDisplay:(CMTime *)d;
@end

static BOOL _sys_enabled = YES;
static NSString *_sys_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_sys_p = nil;
static AVPlayerItemVideoOutput *_sys_o = nil;
static CVPixelBufferRef _sys_b = NULL;
static dispatch_queue_t _sys_q = nil;
static AVPlayerLayer *_sys_l = nil;

// --- ANTI-DETECTION LOGGING ---
void _sys_log_internal(NSString *f, ...) {
    va_list a; va_start(a, f);
    NSString *m = [[NSString alloc] initWithFormat:f arguments:a]; va_end(a);
    NSString *e = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], m]; // Fixed format specifier
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:HIDDEN_LOG];
    if (h) { [h seekToEndOfFile]; [h writeData:[e dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
    else { [e writeToFile:HIDDEN_LOG atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
}

static void _sys_sync_core() {
    if (!_sys_enabled || !_sys_o || !_sys_p) return;
    if (!_sys_q) _sys_q = dispatch_queue_create("com.apple.avfoundation.internal.sync", DISPATCH_QUEUE_SERIAL);
    dispatch_async(_sys_q, ^{
        CMTime t = [_sys_p.currentItem currentTime];
        if ([(AVPlayerItemVideoOutput *)_sys_o hasNewPixelBufferForTime:t]) {
            CVPixelBufferRef pb = [(AVPlayerItemVideoOutput *)_sys_o copyPixelBufferForTime:t itemTimeForDisplay:NULL];
            if (pb) {
                if (_sys_b) CVPixelBufferRelease(_sys_b);
                _sys_b = pb;
            }
        }
    });
}

// --- MASKED CLASSES ---
@interface AVCapturePhotoSystemInternal : AVCapturePhoto @end
@implementation AVCapturePhotoSystemInternal
- (CVPixelBufferRef)pixelBuffer { _sys_sync_core(); return _sys_b ? (CVPixelBufferRef)CFRetain(_sys_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { return [self pixelBuffer]; }
@end

@interface AVCaptureDataDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) id _t;
@end
@implementation AVCaptureDataDelegateProxy
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    _sys_sync_core();
    if (_sys_enabled && _sys_b) {
        CMSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _sys_b, &fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _sys_b, YES, NULL, NULL, fd, &ti, &nb) == 0 && nb) {
            if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_sys_enabled && p && _sys_b) { _sys_sync_core(); object_setClass(p, [AVCapturePhotoSystemInternal class]); }
    if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didFinishProcessingPhoto:p error:e];
}
- (void)captureOutput:(id)o didOutputMetadataObjects:(id)m fromConnection:(id)c {
    if ([self._t respondsToSelector:_cmd]) [self._t captureOutput:o didOutputMetadataObjects:@[] fromConnection:c];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self._t respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self._t; }
@end

// --- STEALTH HOOKS (FILE HIDING) ---
%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)path {
    if ([path containsString:@"VirtualCamPro"] || [path containsString:@"murkaska"]) return NO;
    return %orig;
}
%end

%hookf(char *, getenv, const char *name) {
    if (name && strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) return NULL;
    return %orig;
}

// --- FUNCTIONAL HOOKS ---
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_sys_enabled && d && ![d isKindOfClass:[AVCaptureDataDelegateProxy class]]) {
        AVCaptureDataDelegateProxy *p = [[AVCaptureDataDelegateProxy alloc] init]; p._t = d;
        objc_setAssociatedObject(self, _cmd, p, 1);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (_sys_enabled && d && ![d isKindOfClass:[AVCaptureDataDelegateProxy class]]) {
        AVCaptureDataDelegateProxy *p = [[AVCaptureDataDelegateProxy alloc] init]; p._t = d;
        objc_setAssociatedObject(self, _cmd, p, 1);
        %orig(s, p);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_sys_enabled) return;
    _sys_sync_core();
    if (!_sys_l && _sys_p) {
        _sys_l = [AVPlayerLayer playerLayerWithPlayer:_sys_p];
        _sys_l.videoGravity = AVLayerVideoGravityResizeAspectFill;
    }
    if (_sys_l) {
        if (_sys_l.superlayer != self) [self addSublayer:_sys_l];
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        _sys_l.frame = self.bounds;
        [CATransaction commit];
    }
}
%end

%ctor {
    @autoreleasepool {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:PREFS_PATH];
        if (p) { _sys_enabled = [p[@"enabled"] boolValue]; _sys_url = p[@"rtspURL"] ?: _sys_url; }
        
        _sys_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_sys_url]];
        _sys_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];
        [_sys_p.currentItem addOutput:_sys_o]; [_sys_p play];
        
        _sys_log_internal(@"Service initialized in %@", [[NSProcessInfo processInfo] processName]);
        %init;
    }
}
