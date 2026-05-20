#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _s_en = YES;
static NSString *_s_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_s_p = nil;
static AVPlayerItemVideoOutput *_s_o = nil;
static CVPixelBufferRef _s_b = NULL;
static CIContext *_s_ctx = nil;

static void _load_cfg() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _s_en = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) _s_url = p[@"rtspURL"];
    }
    if (!_s_ctx) _s_ctx = [[CIContext alloc] initWithOptions:nil];
}

static void _sync_data() {
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

@interface FigCapturePhotoInternal : AVCapturePhoto
@end
@implementation FigCapturePhotoInternal
- (CVPixelBufferRef)pixelBuffer { _sync_data(); return _s_b ? CVPixelBufferRetain(_s_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _sync_data(); return _s_b ? CVPixelBufferRetain(_s_b) : NULL; }
- (NSData *)fileDataRepresentation {
    if (!_s_b) return nil;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:_s_b];
    CGImageRef cg = [_s_ctx createCGImage:ci fromRect:ci.extent];
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGImageRelease(cg); return d;
}
@end

%hook AVCaptureConnection
- (void)_enqueueVideoSampleBuffer:(CMSampleBufferRef)sbuf {
    if (_s_en && _s_b) {
        _sync_data();
        CMSampleBufferRef nb = NULL;
        CMFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _s_b, (CMVideoFormatDescriptionRef *)&fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(sbuf, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _s_b, YES, NULL, NULL, (CMVideoFormatDescriptionRef)fd, &ti, &nb);
        if (nb) {
            %orig(nb);
            CFRelease(nb);
            if (fd) CFRelease(fd);
            return;
        }
    }
    %orig(sbuf);
}
%end

%hook AVCapturePhotoOutput
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_s_en && p && _s_b) { _sync_data(); object_setClass(p, [FigCapturePhotoInternal class]); }
    %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!_s_en) return; self.hidden = YES;
    if (!_s_p) {
        _load_cfg();
        _s_p = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_s_url]];
        _s_o = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_s_p.currentItem addOutput:_s_o]; [_s_p play];
        AVPlayerLayer *l = [AVPlayerLayer playerLayerWithPlayer:_s_p];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:l above:self];
        objc_setAssociatedObject(self, "_v_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _sync_data(); }];
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_v_l");
    if (l) l.frame = self.bounds;
}
%end

%ctor { _load_cfg(); %init; }
