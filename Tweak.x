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

static void _v_sync() {
    if (!_v_o || !_v_en || !_v_p) return;
    CMTime t = [_v_p.currentItem currentTime];
    if ([_v_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_v_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_v_b) CVPixelBufferRelease(_v_b);
            _v_b = pb;
        }
    }
}

%hookf(CVImageBufferRef, CMSampleBufferGetImageBuffer, CMSampleBufferRef sbuf) {
    if (_v_en && _v_b && sbuf) {
        _v_sync();
        CMFormatDescriptionRef d = CMSampleBufferGetFormatDescription(sbuf);
        if (d && CMFormatDescriptionGetMediaType(d) == kCMMediaType_Video) return _v_b;
    }
    return %orig(sbuf);
}

@interface AVInternalPhotoGhost : AVCapturePhoto
@end
@implementation AVInternalPhotoGhost
- (CVPixelBufferRef)pixelBuffer { _v_sync(); return _v_b ? CVPixelBufferRetain(_v_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _v_sync(); return _v_b ? CVPixelBufferRetain(_v_b) : NULL; }
- (CGImageRef)CGImageRepresentation {
    _v_sync(); if (!_v_b) return NULL;
    if (!_v_c) _v_c = [[CIContext alloc] initWithOptions:nil];
    return [_v_c createCGImage:[CIImage imageWithCVPixelBuffer:_v_b] fromRect:CGRectMake(0,0,CVPixelBufferGetWidth(_v_b),CVPixelBufferGetHeight(_v_b))];
}
- (NSData *)fileDataRepresentation {
    _v_sync(); if (!_v_b) return nil;
    CGImageRef cg = [self CGImageRepresentation];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGImageRelease(cg); return d;
}
- (NSDictionary *)metadata { return @{}; }
@end

%hook AVCapturePhotoOutput
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_v_en && p && _v_b) { _v_sync(); object_setClass(p, [AVInternalPhotoGhost class]); }
    %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_v_en) return; self.hidden = YES;
    if (!_v_p) {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (p) { _v_en = [p[@"enabled"] boolValue]; _v_url = p[@"rtspURL"] ?: _v_url; }
        _v_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_v_url]];
        _v_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_v_p.currentItem addOutput:_v_o]; [_v_p play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_v_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        objc_setAssociatedObject(self, "_v_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _v_sync(); }];
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_v_l");
    if (l) l.frame = self.bounds;
}
%end

%ctor { %init; }
