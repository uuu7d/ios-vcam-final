"// Tweak.x - VirtualCamPro V273.0 (critical-bug fixes pass 1)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <os/lock.h>
#import \"MJPEGStreamReader.h\"

static BOOL _enabled = YES;
static NSString *_url = @\"http://192.168.1.44:8888/live/stream/index.m3u8\";
static MJPEGStreamReader *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;

// Use os_unfair_lock — fast, no exceptions, safe for static init.
static os_unfair_lock _v_lock = OS_UNFAIR_LOCK_INIT;

static void _v_set_last_buffer(CVPixelBufferRef buf) {
    os_unfair_lock_lock(&_v_lock);
    if (_lastBuffer) CVPixelBufferRelease(_lastBuffer);
    _lastBuffer = buf ? CVPixelBufferRetain(buf) : NULL;
    os_unfair_lock_unlock(&_v_lock);
}

static CVPixelBufferRef _v_copy_last_buffer(void) CF_RETURNS_RETAINED {
    os_unfair_lock_lock(&_v_lock);
    CVPixelBufferRef out = _lastBuffer ? CVPixelBufferRetain(_lastBuffer) : NULL;
    os_unfair_lock_unlock(&_v_lock);
    return out;
}

static void _v_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *u = [NSURL URLWithString:_url];
        if (!u) {
            NSLog(@\"[VCam] Invalid URL: %@\", _url);
            return;
        }

        _reader = [[MJPEGStreamReader alloc] initWithURL:u];
        _reader.pixelBufferCallback = ^(CVPixelBufferRef buffer) {
            if (!buffer) return;
            _v_set_last_buffer(buffer);
        };
        [_reader startStreaming];
        NSLog(@\"[VCam] Stream initialized: %@\", u);
    });
}

// Build a fresh CMSampleBuffer from our _lastBuffer, optionally reusing timing from original.
// Returns retained sample buffer (caller releases) or NULL.
static CMSampleBufferRef _v_makeReplacementSampleBuffer(CMSampleBufferRef original) {
    CVPixelBufferRef src = _v_copy_last_buffer();
    if (!src) return NULL;

    CMVideoFormatDescriptionRef fmt = NULL;
    if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, src, &fmt) != noErr || !fmt) {
        CVPixelBufferRelease(src);
        return NULL;
    }

    CMSampleTimingInfo timing;
    if (original && CMSampleBufferGetSampleTimingInfo(original, 0, &timing) == noErr) {
        // reuse original timing
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
// 1. ПЕРЕХВАТ ДЕЛЕГАТА ВИДЕО-ВЫВОДА
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
                IMP origIMP = method_getImplementation(m);

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

                // Always add the method directly to `cls`.
                // If the method is inherited (class_addMethod returns YES), we get our own slot
                // and DO NOT touch the superclass implementation.
                // If `cls` already implements it directly, class_addMethod returns NO and we
                // safely method_setImplementation on the class's own method.
                BOOL added = class_addMethod(cls, sel, newIMP, types);
                if (!added) {
                    // Refetch the method *on cls itself* to be sure we don't modify the
                    // superclass when the implementation lives there.
                    Method ownMethod = NULL;
                    unsigned int count = 0;
                    Method *list = class_copyMethodList(cls, &count);
                    for (unsigned int i = 0; i < count; i++) {
                        if (method_getName(list[i]) == sel) { ownMethod = list[i]; break; }
                    }
                    free(list);
                    if (ownMethod) {
                        method_setImplementation(ownMethod, newIMP);
                    } else {
                        // Fallback: class_addMethod failed and method lives on superclass.
                        // Add a fresh slot on cls forcefully.
                        class_replaceMethod(cls, sel, newIMP, types);
                    }
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

// AVCapturePhoto.pixelBuffer is CF_RETURNS_NOT_RETAINED — return autoreleased.
- (CVPixelBufferRef)pixelBuffer {
    if (_enabled) {
        CVPixelBufferRef buf = _v_copy_last_buffer();
        if (buf) {
            NSLog(@\"[VCam] Returning virtual buffer for photo\");
            return (CVPixelBufferRef)CFAutorelease(buf);
        }
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    if (_enabled) {
        CVPixelBufferRef buf = _v_copy_last_buffer();
        if (buf) {
            CIImage *ci = [CIImage imageWithCVPixelBuffer:buf];
            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
            CVPixelBufferRelease(buf);
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
// 3. ПЕРЕХВАТ ПРЕДПРОСМОТРА КАМЕРЫ
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
        overlay.backgroundColor = [UIColor blackColor].CGColor;
        overlay.opaque = YES;
        [self addSublayer:overlay];
        objc_setAssociatedObject(self, \"_v_overlay\", overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    // Always keep overlay as the topmost sublayer (don't hide siblings — that breaks HUD).
    if (overlay.superlayer == self) {
        [overlay removeFromSuperlayer];
        [self addSublayer:overlay];
    }

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    overlay.frame = self.bounds;
    overlay.zPosition = CGFLOAT_MAX;
    overlay.hidden = NO;
    overlay.opacity = 1.0;

    CVPixelBufferRef buf = _v_copy_last_buffer();
    if (buf) {
        IOSurfaceRef surf = CVPixelBufferGetIOSurface(buf);
        if (surf) {
            overlay.contents = (__bridge id)surf;
        }
        CVPixelBufferRelease(buf);
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
    }
    return %orig;
}

+ (AVCaptureDevice *)defaultDeviceWithDeviceType:(AVCaptureDeviceType)deviceType
                                       mediaType:(AVMediaType)mediaType
                                        position:(AVCaptureDevicePosition)position {
    if (_enabled && [mediaType isEqualToString:AVMediaTypeVideo]) {
        _v_init();
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
"
