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

// --- ХУКИ НА ФОТО ---
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
            CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:ci fromRect:ci.extent];
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
            CGImageRelease(cg);
            return d;
        }
    }
    return %orig;
}
%end

// --- ХУКИ НА ПРЕДПРОСМОТР (Persistence) ---
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;
    _v_init();
    
    CALayer *overlay = objc_getAssociatedObject(self, "_v_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "_v_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    
    // ПРИНУДИТЕЛЬНО ПЕРЕКРЫВАЕМ ВСЁ
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    
    @synchronized(_v_lock) {
        if (_lastBuffer) {
            overlay.contents = (__bridge id)CVPixelBufferGetIOSurface(_lastBuffer);
        }
    }
    [CATransaction commit];
}
%end

// --- СПЕЦИАЛЬНЫЙ ХУК ДЛЯ СИСТЕМНОЙ КАМЕРЫ APPLE ---
%hook CAMPreviewView
- (void)layoutSubviews {
    %orig;
    if (!_enabled) return;
    UIView *v = (UIView *)self;
    CALayer *l = v.layer;
    if (l) [l setNeedsLayout];
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (bid && ![bid hasPrefix:@"com.apple.springboard"]) {
            NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
            if (p) { _enabled = [p[@"enabled"] boolValue]; _url = p[@"rtspURL"] ?: _url; }
            if (_enabled) %init;
        }
    }
}
