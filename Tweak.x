// Tweak.x - VirtualCamPro V272.2 (Fixed full camera replacement)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import \"MJPEGStreamReader.h\"

static BOOL _enabled = YES;
static NSString *_url = @\"http://192.168.1.44:8888/live/stream/index.m3u8\";
static MJPEGStreamReader *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static id _v_lock = nil;

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (!_v_lock) _v_lock = [NSObject new];

        NSURL *u = [NSURL URLWithString:_url];
        if (!u) return;

        _reader = [[MJPEGStreamReader alloc] initWithURL:u];
        _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
            if (!buffer) return;
            @synchronized(_v_lock) {
                if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
                _lastBuffer = CVPixelBufferRetain(buffer);
            }
        };
        [_reader startStreaming];
        NSLog(@\"[VCam] Stream initialized and started\");
    });
}

// Build a fresh CMSampleBuffer from our _lastBuffer, optionally reusing timing from original.
// Returns retained sample buffer (caller releases) or NULL.
static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    CVPixelBufferRef src = NULL;
    @synchronized(_v_lock) {
        if (_lastBuffer) src = CVPixelBufferRetain(_lastBuffer);
    }
    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(src);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (original) {
        if (CMSampleBufferGetSampleTimingInfo(original, 0, &timing) != noErr) {
            timing.duration = CMTimeMake(1, 30);
            timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
            timing.decodeTimeStamp = kCMTimeInvalid;
        }
    } else {
        timing.duration = CMTimeMake(1, 30);
        timing.presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000);
        timing.decodeTimeStamp = kCMTimeInvalid;
    }

    CMSampleBufferRef out = NULL;
    OSStatus s = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, src, fmt, &timing, &out);
    CFRelease(fmt);
    CVPixelBufferRelease(src);

    return (s == noErr) ? out : NULL;
}

// ========================================
// 1. ПЕРЕХВАТ ДЕЛЕГАТА ВИДЕО-ВЫВОДА (правильное swizzling)
// ========================================
%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate
                          queue:(dispatch_queue_t)queue {
    if (!_enabled || !delegate) {
        %orig;
        return;
    }

    _v_init();

    static NSMutableSet *swizzledClassNames = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ swizzledClassNames = [NSMutableSet new]; });

    Class cls = object_getClass(delegate);
    NSString *clsName = NSStringFromClass(cls);
    SEL sel = @selector(captureOutput:didOutputSampleBuffer:fromConnection:);

    @synchronized(swizzledClassNames) {
        if (![swizzledClassNames containsObject:clsName]) {
            Method m = class_getInstanceMethod(cls, sel);
            if (m) {
                const char *types = method_getTypeEncoding(m);
                __block IMP origIMP = method_getImplementation(m);

                IMP newIMP = imp_implementationWithBlock(^(id self_,
                                                           AVCaptureOutput *output,
                                                           CMSampleBufferRef sb,
                                                           AVCaptureConnection *conn) {
                    CMSampleBufferRef replacement = NULL;
                    if (_enabled) {
                        replacement = _v_makeReplacementSampleBuffer(sb);
                    }
                    CMSampleBufferRef toUse = replacement ? replacement : sb;
                    ((void(*)(id, SEL, AVCaptureOutput *, CMSampleBufferRef, AVCaptureConnection *))origIMP)
                        (self_, sel, output, toUse, conn);
                    if (replacement) CFRelease(replacement);
                });

                // Add method directly to this class (so we don't pollute superclass) if inherited.
                BOOL added = class_addMethod(cls, sel, newIMP, types);
                if (!added) {
                    origIMP = method_setImplementation(m, newIMP);
                }
                [swizzledClassNames addObject:clsName];
                NSLog(@\"[VCam] Swizzled delegate class: %@\", clsName);
            }
        }
    }

    %orig;
}

%end

// ========================================
// 2. ПЕРЕХВАТ ФОТО-ЗАХВАТА
// ========================================
%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            NSLog(@\"[VCam] Returning virtual buffer for photo\");
            return (CVPixelBufferRef)CFRetain(_lastBuffer);
        }
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    @synchronized(_v_lock) {
        if (_enabled && _lastBuffer) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:_lastBuffer];
            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
            if (!cg) return %orig;
            NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
            CGImageRelease(cg);
            NSLog(@\"[VCam] Returning virtual photo data\");
            return d;
        }
    }
    return %orig;
}

%end

// ========================================
// 3. ПЕРЕХВАТ ПРЕДПРОСМОТРА КАМЕРЫ (визуальная подмена)
// ========================================
%hook AVCaptureVideoPreviewLayer

- (void)layoutSublayers {
    %orig;
    if (!_enabled) return;

    _v_init();

    CALayer *overlay = objc_getAssociatedObject(self, \"_v_overlay\");
    if (!overlay) {
        overlay = [CALayer layer];
        overlay.contentsGravity = kCAGravityResizeAspectFill;
        overlay.zPosition = 999999;
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, \"_v_overlay\", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;

    @synchronized(_v_lock) {
        if (_lastBuffer) {
            IOSurfaceRef surf = CVPixelBufferGetIOSurface(_lastBuffer);
            if (surf) {
                overlay.contents = (__bridge id)surf;
            }
        }
    }

    for (CALayer *sublayer in self.sublayers) {
        if (sublayer != overlay) {
            sublayer.hidden = YES;
        }
    }

    [CATransaction commit];
}

%end

// ========================================
// 4. ЛОГ СОЗДАНИЯ УСТРОЙСТВА КАМЕРЫ (для прогрева)
// ========================================
%hook AVCaptureDevice

+ (AVCaptureDevice *)defaultDeviceWithMediaType:(AVMediaType)mediaType {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) {
        _v_init();
        NSLog(@\"[VCam] defaultDeviceWithMediaType:AVMediaTypeVideo\");
    }
    return %orig;
}

+ (AVCaptureDevice *)defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType
                                       mediaType:(AVMediaType)mediaType
                                        position:(AVCaptureDevicePosition)position {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) {
        _v_init();
        NSLog(@\"[VCam] defaultDeviceWithDeviceType for video\");
    }
    return %orig;
}

%end

// ========================================
// ИНИЦИАЛИЗАЦИЯ ТВИКА
// ========================================
%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];

        // Не активируем в SpringBoard
        if (bid && ![bid hasPrefix:@\"com.apple.springboard\"]) {

            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
                @\"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist\"];
            if (prefs) {
                if (prefs[@\"enabled\"]) {
                    _enabled = [prefs[@\"enabled\"] boolValue];
                }
                NSString *u = prefs[@\"rtspURL\"];
                if (u.length > 0) _url = [u copy];
            }

            if (_enabled) {
                NSLog(@\"[VCam] Tweak enabled for bundle: %@\", bid);
                %init;
            } else {
                NSLog(@\"[VCam] Tweak disabled in preferences\");
            }
        }
    }
}
