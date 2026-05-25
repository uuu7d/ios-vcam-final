"#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import "MJPEGStreamReader.h"

static BOOL _enabled = YES;
static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static MJPEGStreamReader *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static dispatch_queue_t _syncQueue = nil;
static BOOL _initialized = NO;

#define VCLog(fmt, ...) NSLog(@"[VirtualCamPro] " fmt, ##__VA_ARGS__)

static void _v_init() {
    if (_initialized) return;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        VCLog(@"Initializing virtual camera stream...");
        
        if (!_syncQueue) {
            _syncQueue = dispatch_queue_create("com.murkaska.vcam.sync", DISPATCH_QUEUE_SERIAL);
        }
        
        _reader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:_url]];
        
        _reader.frameCallback = ^(UIImage *image) {
            if (!image) {
                VCLog(@"Received nil image from stream");
                return;
            }
            
            CVPixelBufferRef pb = NULL;
            NSDictionary *options = @{
                (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
                (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
                (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
            };
            
            CGFloat width = image.size.width;
            CGFloat height = image.size.height;
            
            CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, 
                                                  (size_t)width, 
                                                  (size_t)height, 
                                                  kCVPixelFormatType_32BGRA, 
                                                  (__bridge CFDictionaryRef)options, 
                                                  &pb);
            
            if (status != kCVReturnSuccess || !pb) {
                VCLog(@"Failed to create pixel buffer: %d", status);
                return;
            }
            
            CVPixelBufferLockBaseAddress(pb, 0);
            void *data = CVPixelBufferGetBaseAddress(pb);
            size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pb);
            
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGContextRef ctx = CGBitmapContextCreate(data, 
                                                     (size_t)width, 
                                                     (size_t)height, 
                                                     8, 
                                                     bytesPerRow,
                                                     colorSpace, 
                                                     kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGColorSpaceRelease(colorSpace);
            
            if (ctx) {
                CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image.CGImage);
                CGContextRelease(ctx);
            }
            
            CVPixelBufferUnlockBaseAddress(pb, 0);
            
            dispatch_sync(_syncQueue, ^{
                if (_lastBuffer) {
                    CVPixelBufferRelease(_lastBuffer);
                }
                _lastBuffer = pb;
            });
        };
        
        _reader.errorCallback = ^(NSError *error) {
            VCLog(@"Stream error: %@", error.localizedDescription);
        };
        
        [_reader startStreaming];
        _initialized = YES;
        VCLog(@"Stream started successfully");
    });
}

static CVPixelBufferRef _v_getBuffer() {
    __block CVPixelBufferRef buffer = NULL;
    dispatch_sync(_syncQueue, ^{
        if (_lastBuffer) {
            buffer = (CVPixelBufferRef)CFRetain(_lastBuffer);
        }
    });
    return buffer;
}

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    if (_enabled) {
        _v_init();
        CVPixelBufferRef buffer = _v_getBuffer();
        if (buffer) {
            VCLog(@"Returning virtual buffer for pixelBuffer");
            return buffer;
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
            CIContext *context = [CIContext contextWithOptions:nil];
            CGImageRef cg = [context createCGImage:ci fromRect:ci.extent];
            NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
            CGImageRelease(cg);
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
            CIContext *context = [CIContext contextWithOptions:nil];
            CGImageRef cg = [context createCGImage:ci fromRect:ci.extent];
            NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
            CGImageRelease(cg);
            CVPixelBufferRelease(buffer);
            VCLog(@"Returning virtual JPEG data with customizer");
            return data;
        }
    }
    return %orig;
}

%end

%hook AVCaptureVideoPreviewLayer

- (instancetype)initWithSession:(AVCaptureSession *)session {
    VCLog(@"AVCaptureVideoPreviewLayer init");
    _v_init();
    return %orig;
}

- (void)layoutSublayers {
    %orig;
    
    if (!_enabled) return;
    
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
    overlay.frame = self.bounds;
    overlay.hidden = NO;
    overlay.opacity = 1.0;
    
    CVPixelBufferRef buffer = _v_getBuffer();
    if (buffer) {
        IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
        if (surface) {
            overlay.contents = (__bridge id)surface;
        }
        CVPixelBufferRelease(buffer);
    }
    
    [CATransaction commit];
}

%end

%hook AVCaptureVideoDataOutput

- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)sampleBufferDelegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    VCLog(@"AVCaptureVideoDataOutput setSampleBufferDelegate");
    _v_init();
    
    if (_enabled && sampleBufferDelegate) {
        id proxyDelegate = objc_getAssociatedObject(self, "vcam_proxy");
        if (!proxyDelegate) {
            proxyDelegate = [[NSObject alloc] init];
            
            IMP imp = imp_implementationWithBlock(^(id _self, AVCaptureOutput *output, CMSampleBufferRef sampleBuffer, AVCaptureConnection *connection) {
                CVPixelBufferRef virtualBuffer = _v_getBuffer();
                if (virtualBuffer) {
                    CMSampleBufferRef newSampleBuffer = NULL;
                    CMSampleTimingInfo timing = {
                        .duration = CMTimeMake(1, 30),
                        .presentationTimeStamp = CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000000),
                        .decodeTimeStamp = kCMTimeInvalid
                    };
                    
                    CMVideoFormatDescriptionRef formatDesc = NULL;
                    CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, virtualBuffer, &formatDesc);
                    
                    if (formatDesc) {
                        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,
                                                                virtualBuffer,
                                                                formatDesc,
                                                                &timing,
                                                                &newSampleBuffer);
                        CFRelease(formatDesc);
                    }
                    
                    if (newSampleBuffer) {
                        [sampleBufferDelegate captureOutput:output didOutputSampleBuffer:newSampleBuffer fromConnection:connection];
                        CFRelease(newSampleBuffer);
                    } else {
                        [sampleBufferDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
                    }
                    
                    CVPixelBufferRelease(virtualBuffer);
                } else {
                    [sampleBufferDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
                }
            });
            
            class_addMethod([proxyDelegate class], 
                          @selector(captureOutput:didOutputSampleBuffer:fromConnection:), 
                          imp, 
                          "v@:@@@");
            
            objc_setAssociatedObject(self, "vcam_proxy", proxyDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(self, "vcam_original_delegate", sampleBufferDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        
        %orig(proxyDelegate, sampleBufferCallbackQueue);
        VCLog(@"Installed proxy delegate for video output");
    } else {
        %orig;
    }
}

%end

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    VCLog(@"Capturing photo with settings");
    _v_init();
    %orig;
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
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        VCLog(@"Loading in bundle: %@", bundleID);
        
        if (bundleID && ![bundleID hasPrefix:@"com.apple.springboard"]) {
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
            
            if (prefs) {
                _enabled = [prefs[@"enabled"] boolValue];
                NSString *customURL = prefs[@"rtspURL"];
                if (customURL && customURL.length > 0) {
                    _url = customURL;
                }
                VCLog(@"Loaded preferences - enabled: %d, URL: %@", _enabled, _url);
            }
            
            if (_enabled) {
                VCLog(@"VirtualCamPro enabled - initializing hooks");
                %init;
                
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    _v_init();
                });
            } else {
                VCLog(@"VirtualCamPro disabled in preferences");
            }
        }
    }
}
"
