#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import "MJPEGStreamReader.h"

static BOOL _enabled = YES;
static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static MJPEGStreamReader *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;

static void _v_init() {
    if (_reader) return;
    _reader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:_url]];
    
    // Правильная установка колбэка согласно MJPEGStreamReader.h
    _reader.frameCallback = ^(UIImage *image) {
        if (!image) return;
        CVPixelBufferRef pb = NULL;
        NSDictionary *options = @{(id)kCVPixelBufferCGImageCompatibilityKey: @YES, (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES};
        CVPixelBufferCreate(kCFAllocatorDefault, image.size.width, image.size.height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)options, &pb);
        if (pb) {
            CVPixelBufferLockBaseAddress(pb, 0);
            void *data = CVPixelBufferGetBaseAddress(pb);
            CGContextRef ctx = CGBitmapContextCreate(data, image.size.width, image.size.height, 8, CVPixelBufferGetBytesPerRow(pb), CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGContextDrawImage(ctx, CGRectMake(0, 0, image.size.width, image.size.height), image.CGImage);
            CGContextRelease(ctx);
            CVPixelBufferUnlockBaseAddress(pb, 0);
            
            if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
            _lastBuffer = pb;
        }
    };
    
    [_reader startStreaming];
}

// --- ХУКИ НА ВЫВОД ДАННЫХ ---
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id target;
@end

@implementation VCamProxy
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    _v_init();
    if (_enabled && _lastBuffer) {
        CMSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _lastBuffer, &fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _lastBuffer, YES, NULL, NULL, fd, &ti, &nb) == 0 && nb) {
            if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.target respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.target; }
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (d && ![d isKindOfClass:[VCamProxy class]]) {
        VCamProxy *p = [[VCamProxy alloc] init]; p.target = d;
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    _v_init();
    if (_lastBuffer) {
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        self.contents = (__bridge id)CVPixelBufferGetIOSurface(_lastBuffer);
        [CATransaction commit];
    }
}
%end

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid && ![bid hasPrefix:@"com.apple.springboard"]) {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (p) { _enabled = [p[@"enabled"] boolValue]; _url = p[@"rtspURL"] ?: _url; }
        if (_enabled) %init;
    }
}
