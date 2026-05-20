#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _v_en = YES;
static NSString *_v_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_v_p = nil;
static AVPlayerItemVideoOutput *_v_o = nil;
static CVPixelBufferRef _v_b = NULL;
static CIContext *_v_c = nil;
static AVPlayerLayer *_v_l = nil;

static void _v_sync() {
    if (!_v_o || !_v_en || !_v_p) return;
    CMTime t = [_v_p.currentItem currentTime];
    if ([_v_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_v_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            CVPixelBufferRef old = _v_b;
            _v_b = pb;
            if (old) CVPixelBufferRelease(old);
        }
    }
}

@interface VCPFakePhoto : NSObject
@end
@implementation VCPFakePhoto
- (CVPixelBufferRef)pixelBuffer { _v_sync(); return _v_b ? CVPixelBufferRetain(_v_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _v_sync(); return _v_b ? CVPixelBufferRetain(_v_b) : NULL; }
- (CGImageRef)CGImageRepresentation {
    _v_sync();
    if (!_v_b) return NULL;
    if (!_v_c) _v_c = [[CIContext alloc] initWithOptions:nil];
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_v_b];
    return [_v_c createCGImage:ci fromRect:ci.extent];
}
- (NSData *)fileDataRepresentation {
    _v_sync();
    if (!_v_b) return nil;
    if (!_v_c) _v_c = [[CIContext alloc] initWithOptions:nil];
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_v_b];
    CGImageRef cg = [_v_c createCGImage:ci fromRect:ci.extent];
    UIImage *ui = [UIImage imageWithCGImage:cg];
    NSData *d = UIImageJPEGRepresentation(ui, 0.9);
    CGImageRelease(cg);
    return d;
}
- (NSDictionary *)metadata { return @{}; }
- (id)portraitEffectsMatte { return nil; }
@end

%hook AVCapturePhotoOutput
- (void)captureOutput:(id)output didFinishProcessingPhoto:(id)photo error:(id)error {
    if (_v_en && photo && _v_b) {
        object_setClass(photo, [VCPFakePhoto class]);
    }
    %orig;
}
%end

%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    _v_sync();
    return (_v_en && _v_b) ? CVPixelBufferRetain(_v_b) : %orig;
}
- (NSData *)fileDataRepresentation {
    _v_sync();
    if (_v_en && _v_b) {
        if (!_v_c) _v_c = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_v_b];
        CGImageRef cg = [_v_c createCGImage:ci fromRect:ci.extent];
        UIImage *ui = [UIImage imageWithCGImage:cg];
        NSData *d = UIImageJPEGRepresentation(ui, 0.9);
        CGImageRelease(cg);
        return d;
    }
    return %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_v_en) return;
    self.hidden = YES;
    if (!_v_p) {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (p) {
            _v_en = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
            if (p[@"rtspURL"]) _v_url = p[@"rtspURL"];
        }
        _v_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_v_url]];
        _v_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_v_p.currentItem addOutput:_v_o];
        [_v_p play];
        _v_l = [AVPlayerLayer playerLayerWithPlayer:_v_p];
        _v_l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:_v_l above:self];
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _v_sync(); }];
    }
    if (_v_l) _v_l.frame = self.bounds;
}
%end

%ctor { %init; }
