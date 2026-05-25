// Tweak.x - VirtualCamPro V272.0 (Stage 1: fundamentals)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "MJPEGStreamReader.h"

static BOOL              _enabled       = YES;
static NSString *        _url           = @"http://192.168.1.44:8888/mystream/index.m3u8";
static MJPEGStreamReader *_reader       = nil;
static CVPixelBufferRef  _lastBuffer    = NULL;
static dispatch_queue_t  _syncQueue     = nil;
static BOOL              _initialized   = NO;

#define VCLog(fmt, ...) NSLog(@"[VirtualCamPro] " fmt, ##__VA_ARGS__)

static void _v_setBuffer(CVPixelBufferRef pb) {
    if (!pb) return;
    dispatch_sync(_syncQueue, ^{
        if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
        _lastBuffer = pb;
    });
}

static CVPixelBufferRef _v_getBuffer(void) CF_RETURNS_RETAINED {
    __block CVPixelBufferRef out = NULL;
    dispatch_sync(_syncQueue, ^{
        if (_lastBuffer) out = (CVPixelBufferRef)CFRetain(_lastBuffer);
    });
    return out;
}

static void _v_init(void) {
    if (_initialized) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        VCLog(@"Initializing virtual camera stream...");
        if (!_syncQueue) {
            _syncQueue = dispatch_queue_create("com.murkaska.vcam.sync", DISPATCH_QUEUE_SERIAL);
        }
        _reader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:_url]];
        _reader.pixelBufferCallback = ^(CVPixelBufferRef pb) { _v_setBuffer(pb); };
        _reader.errorCallback = ^(NSError *error) {
            VCLog(@"Stream error: %@", error.localizedDescription);
        };
        [_reader startStreaming];
        _initialized = YES;
        VCLog(@"Stream started successfully (URL=%@)", _url);
    });
}

static CMSampleBufferRef _v_makeSampleBuffer(CVPixelBufferRef pb,
                                             CMSampleBufferRef referenceSB) CF_RETURNS_RETAINED {
    if (!pb) return NULL;
    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pb, &fmt) != noErr || !fmt) {
        return NULL;
    }
    CMSampleTimingInfo timing;
    if (referenceSB) {
        if (CMSampleBufferGetSampleTimingInfo(referenceSB, 0, &timing) != noErr) {
            timing.duration = CMTimeMake(1, 30);
            timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
            timing.decodeTimeStamp = kCMTimeInvalid;
        }
    } else {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock());
        timing.decodeTimeStamp = kCMTimeInvalid;
    }
    CMSampleBufferRef sb = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pb, fmt, &timing, &sb);
    CFRelease(fmt);
    if (s != noErr) return NULL;
    return sb;
}

static SEL kCaptureSel;

static void _v_swizzledCapture(id self_, SEL _cmd,
                               AVCaptureOutput *output,
                               CMSampleBufferRef sampleBuffer,
                               AVCaptureConnection *connection) {
    if (_enabled) {
        CVPixelBufferRef vpb = _v_getBuffer();
        if (vpb) {
            CMSampleBufferRef fake = _v_makeSampleBuffer(vpb, sampleBuffer);
            CVPixelBufferRelease(vpb);
            if (fake) {
                struct objc_super sup = {
                    .receiver = self_,
                    .super_class = class_getSuperclass(object_getClass(self_))
                };
                ((void (*)(struct objc_super *, SEL, id, CMSampleBufferRef, id))objc_msgSendSuper)
                    (&sup, _cmd, output, fake, connection);
                CFRelease(fake);
                return;
            }
        }
    }
    struct objc_super sup = {
        .receiver = self_,
        .super_class = class_getSuperclass(object_getClass(self_))
    };
    ((void (*)(struct objc_super *, SEL, id, CMSampleBufferRef, id))objc_msgSendSuper)
        (&sup, _cmd, output, sampleBuffer, connection);
}

static Class _v_classLie(id self_, SEL _cmd) {
    return class_getSuperclass(object_getClass(self_));
}

static Class _v_subclassForDelegate(id delegate) {
    Class origClass = object_getClass(delegate);
    NSString *origName = NSStringFromClass(origClass);
    if ([origName hasPrefix:@"VCamProxy_"]) return origClass;

    NSString *newName = [@"VCamProxy_" stringByAppendingString:origName];
    Class sub = objc_getClass(newName.UTF8String);
    if (sub) return sub;

    sub = objc_allocateClassPair(origClass, newName.UTF8String, 0);
    if (!sub) {
        VCLog(@"objc_allocateClassPair failed for %@", origName);
        return origClass;
    }

    Method m = class_getInstanceMethod(origClass, kCaptureSel);
    const char *types = m ? method_getTypeEncoding(m) : "v@:@@@";
    class_addMethod(sub, kCaptureSel, (IMP)_v_swizzledCapture, types);
    class_addMethod(sub, @selector(class), (IMP)_v_classLie, "#@:");
    objc_registerClassPair(sub);
    VCLog(@"Allocated VCamProxy subclass for %@", origName);
    return sub;
}

%hook AVCaptureSession

- (void)startRunning {
    if (_enabled) {
        VCLog(@"AVCaptureSession startRunning");
        _v_init();
    }
    %orig;
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (_enabled && delegate) {
        _v_init();
        Class proxyClass = _v_subclassForDelegate(delegate);
        if (proxyClass && proxyClass != object_getClass(delegate)) {
            object_setClass(delegate, proxyClass);
            VCLog(@"ISA-swizzled delegate -> %s", class_getName(proxyClass));
        }
    }
    %orig;
}

%end

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    if (_enabled) {
        _v_init();
        CVPixelBufferRef buffer = _v_getBuffer();
        if (buffer) {
            VCLog(@"Returning virtual buffer for AVCapturePhoto.pixelBuffer");
            return (CVPixelBufferRef)CFAutorelease(buffer);
        }
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    if (_enabled) {
        _v_init();
        CVPixelBufferRef buffer = _v_getBuffer();
        if (buffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:buffer];
            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
            NSData *data = cg ? UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95) : nil;
            if (cg) CGImageRelease(cg);
            CVPixelBufferRelease(buffer);
            VCLog(@"Returning virtual JPEG data (%lu bytes)", (unsigned long)data.length);
            return data;
        }
    }
    return %orig;
}

- (NSData *)fileDataRepresentationWithCustomizer:(id)customizer {
    if (_enabled) {
        _v_init();
        CVPixelBufferRef buffer = _v_getBuffer();
        if (buffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:buffer];
            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
            NSData *data = cg ? UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95) : nil;
            if (cg) CGImageRelease(cg);
            CVPixelBufferRelease(buffer);
            VCLog(@"Returning virtual JPEG data with customizer");
            return data;
        }
    }
    return %orig;
}

%end

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id)delegate {
    VCLog(@"capturePhotoWithSettings");
    _v_init();
    %orig;
}

%end

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    VCLog(@"AVCaptureVideoPreviewLayer initWithSession");
    _v_init();
    return %orig;
}

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;

    CVPixelBufferRef buffer = _v_getBuffer();
    if (!buffer) return;

    CALayer *overlay = objc_getAssociatedObject(self, "vcam_overlay");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 9999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, "vcam_overlay", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        VCLog(@"Created overlay layer");
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    overlay.frame  = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
    if (surface) overlay.contents = (__bridge id)surface;
    [CATransaction commit];

    CVPixelBufferRelease(buffer);
}

%end

%hook CAMPreviewView

- (void)layoutSubviews {
    %orig;
    if (_enabled) {
        VCLog(@"CAMPreviewView layoutSubviews");
        _v_init();
    }
}

%end

%ctor {
    @autoreleasepool {
        kCaptureSel = NSSelectorFromString(@"captureOutput:didOutputSampleBuffer:fromConnection:");

        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        VCLog(@"Loading in bundle: %@", bundleID);

        if (!bundleID) return;
        if ([bundleID hasPrefix:@"com.apple.springboard"]) return;
        if ([bundleID hasPrefix:@"com.murkaska.virtualcampro"]) return;

        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) {
            if (prefs[@"enabled"]) _enabled = [prefs[@"enabled"] boolValue];
            NSString *customURL = prefs[@"rtspURL"];
            if (customURL.length > 0) _url = customURL;
            VCLog(@"Prefs loaded - enabled=%d url=%@", _enabled, _url);
        }

        if (!_enabled) {
            VCLog(@"VirtualCamPro disabled in preferences");
            return;
        }

        VCLog(@"VirtualCamPro enabled - installing hooks");
        %init;

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ _v_init(); });
    }
}
