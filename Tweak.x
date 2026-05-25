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
static NSString *_v_log = @"/tmp/.sys_vcam_status";

static void _v_write_log(NSString *msg) {
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:_v_log];
    if (h) { [h seekToEndOfFile]; [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
    else { [line writeToFile:_v_log atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
}

static void _v_ensure_init() {
    if (_v_player) {
        if (_v_player.rate == 0 && _v_player.error == nil) [_v_player play];
        return;
    }
    
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _v_write_log([NSString stringWithFormat:@"Initializing stream: %@", _v_url]);
        _v_player = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_v_url]];
        _v_output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        
        [_v_player.currentItem addOutput:_v_output];
        _v_player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
        
        [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:_v_player.currentItem queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
            [_v_player seekToTime:kCMTimeZero];
            [_v_player play];
        }];
        
        [_v_player play];
        _v_queue = dispatch_queue_create("com.murkaska.vcam.sync", DISPATCH_QUEUE_SERIAL);
        _v_write_log(@"Player started playing");
    });
}

static void _v_sync() {
    _v_ensure_init();
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

@interface VCamPhotoSystem : AVCapturePhoto @end
@implementation VCamPhotoSystem
- (CVPixelBufferRef)pixelBuffer { _v_sync(); return _v_buffer ? (CVPixelBufferRef)CFRetain(_v_buffer) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { return [self pixelBuffer]; }
- (NSData *)fileDataRepresentation {
    _v_sync();
    if (!_v_buffer) return nil;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_v_buffer];
    CIContext *ctx = [CIContext contextWithOptions:nil];
    CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.85);
    CGImageRelease(cg);
    return d;
}
@end

@interface VCamDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id target;
@end

@implementation VCamDelegateProxy
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    _v_sync();
    if (_v_enabled && _v_buffer) {
        CMSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _v_buffer, &fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _v_buffer, YES, NULL, NULL, fd, &ti, &nb) == 0 && nb) {
            if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}

- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_v_enabled && p) {
        _v_sync();
        if (_v_buffer) object_setClass(p, [VCamPhotoSystem class]);
    }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didFinishProcessingPhoto:p error:e];
}

- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.target respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.target; }
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_v_enabled && d && ![d isKindOfClass:[VCamDelegateProxy class]]) {
        _v_ensure_init();
        VCamDelegateProxy *p = [[VCamDelegateProxy alloc] init]; p.target = d;
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (_v_enabled && d && ![d isKindOfClass:[VCamDelegateProxy class]]) {
        _v_ensure_init();
        VCamDelegateProxy *p = [[VCamDelegateProxy alloc] init]; p.target = d;
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(s, p);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_v_enabled) return;
    _v_ensure_init();
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_v_l");
    if (!l && _v_player) {
        l = [AVPlayerLayer playerLayerWithPlayer:_v_player];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        l.zPosition = 1000; // Принудительно на передний план
        [self addSublayer:l];
        objc_setAssociatedObject(self, "_v_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (l) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        l.frame = self.bounds;
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
