#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "MJPEGStreamReader.h"

static BOOL _enabled = YES;
static NSString *_url = @"http://192.168.1.44:8888/live";
static MJPEGStreamReader *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static dispatch_queue_t _syncQueue = nil;
static CIContext *_ciContext = nil;
static BOOL _initialized = NO;

#define VCLog(fmt, ...) NSLog(@"[VirtualCamPro] " fmt, ##__VA_ARGS__)

static void _v_init(void) {
    if (_initialized) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VCLog(@"Init stream, URL=%@", _url);
        _syncQueue = dispatch_queue_create("com.murkaska.vcam.sync", DISPATCH_QUEUE_SERIAL);
        _ciContext = [CIContext contextWithOptions:nil];

        _reader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:_url]];

        _reader.frameCallback = ^(UIImage *image) {
            if (!image) return;

            CGFloat w = image.size.width;
            CGFloat h = image.size.height;
            CVPixelBufferRef pb = NULL;
            NSDictionary *opts = @{
                (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };

            if (CVPixelBufferCreate(kCFAllocatorDefault,(size_t)w,(size_t)h,
                                    kCVPixelFormatType_32BGRA,
                                    (__bridge CFDictionaryRef)opts, &pb) != kCVReturnSuccess || !pb) {
                return;
            }

            CVPixelBufferLockBaseAddress(pb, 0);
            void *data = CVPixelBufferGetBaseAddress(pb);
            size_t bpr = CVPixelBufferGetBytesPerRow(pb);
            CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(data,(size_t)w,(size_t)h,8,bpr,cs,
                                                     kCGImageAlphaPremultipliedFirst|kCGBitmapByteOrder32Little);
            CGColorSpaceRelease(cs);
            if (ctx) {
                CGContextDrawImage(ctx, CGRectMake(0,0,w,h), image.CGImage);
                CGContextRelease(ctx);
            }
            CVPixelBufferUnlockBaseAddress(pb, 0);

            dispatch_sync(_syncQueue, ^{
                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = pb;
            });
        };

        _reader.errorCallback = ^(NSError *e) {
            VCLog(@"Stream error: %@", e.localizedDescription);
        };

        [_reader startStreaming];
        _initialized = YES;
    });
}

static CVPixelBufferRef _v_getBuffer(void) {
    __block CVPixelBufferRef buf = NULL;
    dispatch_sync(_syncQueue, ^{
        if (_lastBuffer) buf = (CVPixelBufferRef)CFRetain(_lastBuffer);
    });
    return buf;
}

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    if (_enabled) {
        _v_init();
        CVPixelBufferRef b = _v_getBuffer();
        if (b) return b;
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    if (_enabled) {
        _v_init();
        CVPixelBufferRef b = _v_getBuffer();
        if (b) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:b];
            CGImageRef cg = [_ciContext createCGImage:ci fromRect:ci.extent];
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
            CGImageRelease(cg);
            CVPixelBufferRelease(b);
            return d;
        }
    }
    return %orig;
}

- (NSData *)fileDataRepresentationWithCustomizer:(id)c {
    if (_enabled) {
        _v_init();
        CVPixelBufferRef b = _v_getBuffer();
        if (b) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:b];
            CGImageRef cg = [_ciContext createCGImage:ci fromRect:ci.extent];
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
            CGImageRelease(cg);
            CVPixelBufferRelease(b);
            return d;
        }
    }
    return %orig;
}

%end

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)s {
    _v_init();
    return %orig;
}

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;

    CVPixelBufferRef buf = _v_getBuffer();
    if (!buf) return;

    CALayer *overlay = objc_getAssociatedObject(self, "vcam_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 9999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "vcam_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(buf);
    if (surface) overlay.contents = (__bridge id)surface;

    [CATransaction commit];
    CVPixelBufferRelease(buf);
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)q {
    _v_init();

    if (!_enabled || !delegate) { %orig; return; }

    static Class proxyClass = nil;
    static dispatch_once_t onceP;
    dispatch_once(&onceP, ^{
        proxyClass = objc_allocateClassPair([NSObject class], "VCamProxyDelegate", 0);
        IMP imp = imp_implementationWithBlock(^(id self_,
                                                AVCaptureOutput *output,
                                                CMSampleBufferRef sb,
                                                AVCaptureConnection *conn) {
            id orig = objc_getAssociatedObject(self_, "vcam_real");
            CVPixelBufferRef vb = _v_getBuffer();
            if (vb && orig) {
                CMSampleBufferRef nsb = NULL;
                CMSampleTimingInfo timing = {
                    .duration = CMTimeMake(1,30),
                    .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(),1000000000),
                    .decodeTimeStamp = kCMTimeInvalid
                };
                CMVideoFormatDescriptionRef fd = NULL;
                CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, vb, &fd);
                if (fd) {
                    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, vb, fd, &timing, &nsb);
                    CFRelease(fd);
                }
                if (nsb) {
                    [orig captureOutput:output didOutputSampleBuffer:nsb fromConnection:conn];
                    CFRelease(nsb);
                } else {
                    [orig captureOutput:output didOutputSampleBuffer:sb fromConnection:conn];
                }
                CVPixelBufferRelease(vb);
            } else if (orig) {
                [orig captureOutput:output didOutputSampleBuffer:sb fromConnection:conn];
            }
        });
        class_addMethod(proxyClass,
                        @selector(captureOutput:didOutputSampleBuffer:fromConnection:),
                        imp, "v@:@@@");
        objc_registerClassPair(proxyClass);
    });

    id proxy = objc_getAssociatedObject(self, "vcam_proxy");
    if (!proxy) {
        proxy = [[proxyClass alloc] init];
        objc_setAssociatedObject(self, "vcam_proxy", proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(proxy, "vcam_real", delegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    %orig(proxy, q);
}

%end

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)s delegate:(id)d {
    _v_init();
    %orig;
}

%end

%hook CAMPreviewView

- (void)layoutSubviews {
    %orig;
    if (_enabled) _v_init();
}

%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid || [bid hasPrefix:@"com.apple.springboard"]) return;

        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) {
            if (prefs[@"enabled"]) _enabled = [prefs[@"enabled"] boolValue];
            NSString *u = prefs[@"rtspURL"];
            if (u.length > 0) _url = u;
        }

        if (_enabled) {
            VCLog(@"Loaded in %@", bid);
            %init;
        }
    }
}
