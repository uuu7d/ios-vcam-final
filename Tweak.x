#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>

@interface AVPlayerItemVideoOutput (VCamFix)
- (BOOL)hasNewPixelBufferForTime:(CMTime)t;
- (CVPixelBufferRef)copyPixelBufferForTime:(CMTime)t itemTimeForDisplay:(CMTime *)d;
@end

static BOOL _v_enabled = YES;
static NSString *_v_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_v_player = nil;
static AVPlayerItemVideoOutput *_v_output = nil;
static CVPixelBufferRef _v_buffer = NULL;
static dispatch_queue_t _v_queue = nil;

static void _v_ensure_init() {
    if (_v_player) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _v_player = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_v_url]];
        _v_output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_v_player.currentItem addOutput:_v_output];
        [_v_player play];
        _v_queue = dispatch_queue_create("com.murkaska.vcam.sync", DISPATCH_QUEUE_SERIAL);
    });
}

static void _v_sync() {
    if (!_v_player || !_v_output || !_v_queue) return;
    dispatch_async(_v_queue, ^{
        CMTime t = [_v_player.currentItem currentTime];
        if ([_v_output hasNewPixelBufferForTime:t]) {
            CVPixelBufferRef pb = [_v_output copyPixelBufferForTime:t itemTimeForDisplay:NULL];
            if (pb) {
                if (_v_buffer) CVPixelBufferRelease(_v_buffer);
                _v_buffer = pb;
            }
        }
    });
}

// --- DYNAMIC PROXY FOR STABILITY ---
@interface VCamDynamicProxy : NSProxy <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id target;
@end

@implementation VCamDynamicProxy
- (instancetype)initWithTarget:(id)target { self.target = target; return self; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel { return [self.target methodSignatureForSelector:sel]; }
- (void)forwardInvocation:(NSInvocation *)inv { [inv invokeWithTarget:self.target]; }
- (BOOL)respondsToSelector:(SEL)sel { return [self.target respondsToSelector:sel]; }

- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    _v_sync();
    if (_v_enabled && _v_buffer) {
        CMSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _v_buffer, &fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _v_buffer, YES, NULL, NULL, fd, &ti, &nb) == noErr && nb) {
            if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
@end

// --- HOOKS ---
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_v_enabled && d && ![d isKindOfClass:[VCamDynamicProxy class]]) {
        _v_ensure_init();
        VCamDynamicProxy *p = [[VCamDynamicProxy alloc] initWithTarget:d];
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_v_enabled) return;
    _v_ensure_init();
    
    // Обновляем превью через подмену контента, а не слоев
    _v_sync();
    if (_v_buffer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        self.contents = (__bridge id)CVPixelBufferGetIOSurface(_v_buffer);
        [CATransaction commit];
    }
}
%end

%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        if (!bundleID || [bundleID hasPrefix:@"com.apple.springboard"]) return;
        
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) {
            _v_enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : _v_enabled;
            _v_url = prefs[@"rtspURL"] ?: _v_url;
        }
        
        if (_v_enabled) %init;
    }
}
