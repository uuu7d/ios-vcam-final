#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import "MJPEGStreamReader.h"

static BOOL _enabled = YES;
static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static MJPEGStreamReader *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static id _v_lock = nil;

static void _v_init() {
    if (_reader) return;
    if (!_v_lock) _v_lock = [NSObject new];
    
    _reader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:_url]];
    _reader.frameCallback = ^(UIImage *image) {
        if (!image) return;
        CVPixelBufferRef pb = NULL;
        // ВАЖНО: Добавляем kCVPixelBufferIOSurfacePropertiesKey для отображения в CALayer
        NSDictionary *options = @{
            (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
            (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        
        CVPixelBufferCreate(kCFAllocatorDefault, image.size.width, image.size.height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)options, &pb);
        if (pb) {
            CVPixelBufferLockBaseAddress(pb, 0);
            void *data = CVPixelBufferGetBaseAddress(pb);
            CGContextRef ctx = CGBitmapContextCreate(data, image.size.width, image.size.height, 8, CVPixelBufferGetBytesPerRow(pb), CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGContextDrawImage(ctx, CGRectMake(0, 0, image.size.width, image.size.height), image.CGImage);
            CGContextRelease(ctx);
            CVPixelBufferUnlockBaseAddress(pb, 0);
            
            @synchronized(_v_lock) {
                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = pb;
            }
        }
    };
    [_reader startStreaming];
}

// --- ХУКИ НА ФОТО (СОХРАНЕНИЕ ИЗ СТРИМА) ---
%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) return (CVPixelBufferRef)CFRetain(_lastBuffer);
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
            CGImageRelease(cg);
            return d;
        }
    }
    return %orig;
}
%end

// --- ХУКИ НА ВЫВОД ВИДЕО ---
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id target;
@end
@implementation VCamProxy
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    _v_init();
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            CMSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
            CMVideoFormatDescriptionCreateForImageBuffer(NULL, _lastBuffer, &fd);
            CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
            if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _lastBuffer, YES, NULL, NULL, fd, &ti, &nb) == noErr && nb) {
                if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
                CFRelease(nb); if (fd) CFRelease(fd); return;
            }
        }
    }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.target respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.target; }
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_enabled && d && ![d isKindOfClass:[VCamProxy class]]) {
        VCamProxy *p = [[VCamProxy alloc] init]; p.target = d;
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

// --- ХУК НА ПРЕДПРОСМОТР ---
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    _v_init();
    
    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 99999;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    overlay.frame = self.bounds;
    
    @synchronized(_v_lock) {
        if (_lastBuffer) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            overlay.contents = (__bridge id)CVPixelBufferGetIOSurface(_lastBuffer);
            [CATransaction commit];
        }
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
