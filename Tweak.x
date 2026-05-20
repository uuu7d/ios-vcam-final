#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _s_en = YES;
static NSString *_s_src = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_s_p = nil;
static AVPlayerItemVideoOutput *_s_o = nil;
static CVPixelBufferRef _s_b = NULL;
static CIContext *_s_c = nil;

static void _s_sync() {
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

// GHOST HOOK: Intercept frame wrapping at CoreMedia level
%hookf(OSStatus, CMSampleBufferCreateForImageBuffer, CFAllocatorRef allocator, CVImageBufferRef imageBuffer, Boolean dataReady, CMSampleBufferMakeDataReadyCallback callback, void *refcon, CMVideoFormatDescriptionRef formatDescription, const CMSampleTimingInfo *sampleTiming, CMSampleBufferRef *sBufOut) {
    if (_s_en && _s_b) {
        _s_sync();
        return %orig(allocator, _s_b, dataReady, callback, refcon, formatDescription, sampleTiming, sBufOut);
    }
    return %orig(allocator, imageBuffer, dataReady, callback, refcon, formatDescription, sampleTiming, sBufOut);
}

%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    _s_sync();
    return (_s_en && _s_b) ? CVPixelBufferRetain(_s_b) : %orig;
}
- (NSData *)fileDataRepresentation {
    _s_sync();
    if (_s_en && _s_b) {
        if (!_s_c) _s_c = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_s_b];
        CGImageRef cg = [_s_c createCGImage:ci fromRect:ci.extent];
        if (cg) {
            UIImage *ui = [UIImage imageWithCGImage:cg];
            NSData *d = UIImageJPEGRepresentation(ui, 0.92);
            CGImageRelease(cg);
            return d;
        }
    }
    return %orig;
}
- (NSDictionary *)metadata {
    NSMutableDictionary *meta = [%orig mutableCopy] ?: [NSMutableDictionary new];
    if (_s_en && _s_b) {
        [meta setObject:@"Apple" forKey:(id)kCGImagePropertyMakerAppleDictionary];
    }
    return meta;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_s_en) return;
    self.hidden = YES;
    if (!_s_p) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) {
            _s_en = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
            if (prefs[@"rtspURL"]) _s_src = prefs[@"rtspURL"];
        }
        _s_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_s_src]];
        _s_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_s_p.currentItem addOutput:_s_o];
        [_s_p play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_s_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _s_sync(); }];
        objc_setAssociatedObject(self, "_s_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_s_l");
    if (l) l.frame = self.bounds;
}
%end

%ctor {
    %init;
}
