#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _en = YES;
static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_p = nil;
static AVPlayerItemVideoOutput *_o = nil;
static CVPixelBufferRef _b = NULL;
static CIContext *_c = nil;
static AVPlayerLayer *_l = nil;

static void _sync() {
    if (!_o || !_en || !_p) return;
    CMTime t = [_p.currentItem currentTime];
    if ([_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_b) CVPixelBufferRelease(_b);
            _b = pb;
        }
    }
}

// --- ХУКИ ДЛЯ ОБЪЕКТА ФОТО (ДЛЯ ВСЕХ ПРИЛОЖЕНИЙ) ---
%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    _sync();
    return (_en && _b) ? CVPixelBufferRetain(_b) : %orig;
}

- (CVPixelBufferRef)previewPixelBuffer {
    _sync();
    return (_en && _b) ? CVPixelBufferRetain(_b) : %orig;
}

- (CGImageRef)CGImageRepresentation {
    _sync();
    if (_en && _b) {
        if (!_c) _c = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_b];
        return [_c createCGImage:ci fromRect:ci.extent];
    }
    return %orig;
}

- (CGImageRef)previewCGImageRepresentation {
    _sync();
    if (_en && _b) {
        if (!_c) _c = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_b];
        return [_c createCGImage:ci fromRect:ci.extent];
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    _sync();
    if (_en && _b) {
        if (!_c) _c = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_b];
        CGImageRef cg = [_c createCGImage:ci fromRect:ci.extent];
        if (cg) {
            UIImage *ui = [UIImage imageWithCGImage:cg];
            NSData *data = UIImageJPEGRepresentation(ui, 0.9);
            CGImageRelease(cg);
            return data;
        }
    }
    return %orig;
}

%end

// --- ПРОКСИ ДЛЯ ВИДЕОПОТОКА (КРУЖКИ ТГ, KYC) ---
@interface VCPInternalDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id orig;
@end

@implementation VCPInternalDelegate
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_en && _b) {
        _sync();
        CMSampleBufferRef nb = NULL;
        CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti;
        CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _b, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            if ([self.orig respondsToSelector:_cmd]) [self.orig captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb);
            if (fd) CFRelease(fd);
            return;
        }
    }
    if ([self.orig respondsToSelector:_cmd]) [self.orig captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_en && d && ![d isKindOfClass:[VCPInternalDelegate class]]) {
        VCPInternalDelegate *p = [[VCPInternalDelegate alloc] init];
        p.orig = d;
        objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

// --- ПРЕВЬЮ И МАСШТАБ ---
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_en) return;
    self.hidden = YES;
    if (!_p) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) {
            _en = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
            if (prefs[@"rtspURL"]) _url = prefs[@"rtspURL"];
        }
        _p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_url]];
        _o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_p.currentItem addOutput:_o];
        [_p play];
        _l = [AVPlayerLayer playerLayerWithPlayer:_p];
        _l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:_l above:self];
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _sync(); }];
    }
    if (_l) _l.frame = self.bounds;
}
%end

%ctor { %init; }
