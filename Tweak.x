#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _vcp_en = YES;
static NSString *_vcp_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_vcp_p = nil;
static AVPlayerItemVideoOutput *_vcp_o = nil;
static CVPixelBufferRef _vcp_b = NULL;
static CIContext *_vcp_c = nil;
static AVPlayerLayer *_vcp_l = nil;

static void _vcp_sync() {
    if (!_vcp_o || !_vcp_en || !_vcp_p) return;
    CMTime t = [_vcp_p.currentItem currentTime];
    if ([_vcp_out hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_vcp_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_vcp_b) CVPixelBufferRelease(_vcp_b);
            _vcp_b = pb;
        }
    }
}

@interface VCPInternalPhoto : NSObject
@end
@implementation VCPInternalPhoto
- (CVPixelBufferRef)pixelBuffer { _vcp_sync(); return _vcp_b ? CVPixelBufferRetain(_vcp_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _vcp_sync(); return _vcp_b ? CVPixelBufferRetain(_vcp_b) : NULL; }
- (CGImageRef)CGImageRepresentation {
    _vcp_sync(); if (!_vcp_b) return NULL;
    if (!_vcp_c) _vcp_c = [[CIContext alloc] initWithOptions:nil];
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_vcp_b];
    return [_vcp_c createCGImage:ci fromRect:ci.extent];
}
- (CGImageRef)previewCGImageRepresentation { return [self CGImageRepresentation]; }
- (NSData *)fileDataRepresentation {
    _vcp_sync(); if (!_vcp_b) return nil;
    if (!_vcp_c) _vcp_c = [[CIContext alloc] initWithOptions:nil];
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_vcp_b];
    CGImageRef cg = [_vcp_c createCGImage:ci fromRect:ci.extent];
    UIImage *ui = [UIImage imageWithCGImage:cg];
    NSData *d = UIImageJPEGRepresentation(ui, 0.9);
    CGImageRelease(cg);
    return d;
}
- (NSDictionary *)metadata { return @{}; }
@end

%hook AVCapturePhotoOutput
- (void)captureOutput:(id)output didFinishProcessingPhoto:(id)photo error:(id)error {
    if (_vcp_en && photo && _vcp_b) {
        object_setClass(photo, [VCPInternalPhoto class]);
    }
    %orig;
}
%end

@interface VCPVideoDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id orig;
@end
@implementation VCPVideoDelegate
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_vcp_en && _vcp_b) {
        _vcp_sync();
        CMSampleBufferRef nb = NULL;
        CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _vcp_b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _vcp_b, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            if ([self.orig respondsToSelector:_cmd]) [self.orig captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd);
            return;
        }
    }
    if ([self.orig respondsToSelector:_cmd]) [self.orig captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_vcp_en && d && ![d isKindOfClass:[VCPVideoDelegate class]]) {
        VCPVideoDelegate *p = [[VCPVideoDelegate alloc] init];
        p.orig = d;
        objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_vcp_en) return;
    self.hidden = YES;
    if (!_vcp_p) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) {
            _vcp_en = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
            if (prefs[@"rtspURL"]) _vcp_url = prefs[@"rtspURL"];
        }
        _vcp_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_vcp_url]];
        _vcp_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_vcp_p.currentItem addOutput:_vcp_o];
        [_vcp_p play];
        _vcp_l = [AVPlayerLayer playerLayerWithPlayer:_vcp_p];
        _vcp_l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:_vcp_l above:self];
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _vcp_sync(); }];
    }
    if (_vcp_l) _vcp_l.frame = self.bounds;
}
%end

%ctor { %init; }
