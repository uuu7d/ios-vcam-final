
📄 ФАЙЛ 1: Tweak.x
Удалите всё в файле Tweak.x и вставьте это:

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import "MJPEGStreamReader.h"

// Глобальные переменные
static BOOL _enabled = YES;
static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static MJPEGStreamReader *_reader = nil;
static CVPixelBufferRef _lastBuffer = NULL;
static dispatch_queue_t _syncQueue = nil;
static BOOL _initialized = NO;

// Логирование
#define VCLog(fmt, ...) NSLog(@"[VirtualCamPro] " fmt, ##__VA_ARGS__)

// Инициализация стрима
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

// Получить текущий буфер
static CVPixelBufferRef _v_getBuffer() {
    __block CVPixelBufferRef buffer = NULL;
    dispatch_sync(_syncQueue, ^{
        if (_lastBuffer) {
            buffer = (CVPixelBufferRef)CFRetain(_lastBuffer);
        }
    });
    return buffer;
}

// ==================== ХУКИ НА ФОТО ====================

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

// ==================== ХУКИ НА PREVIEW ====================

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

// ==================== ХУКИ НА SAMPLE BUFFER (КРИТИЧНО!) ====================

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

// ==================== ХУК НА PHOTO OUTPUT ====================

%hook AVCapturePhotoOutput

- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    VCLog(@"Capturing photo with settings");
    _v_init();
    %orig;
}

%end

// ==================== ХУК НА СИСТЕМНУЮ КАМЕРУ ====================

%hook CAMPreviewView

- (void)layoutSubviews {
    %orig;
    if (_enabled) {
        VCLog(@"CAMPreviewView layoutSubviews");
        _v_init();
    }
}

%end

// ==================== CONSTRUCTOR ====================

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
📄 ФАЙЛ 2: MJPEGStreamReader.m
Удалите всё в файле MJPEGStreamReader.m и вставьте это:

// MJPEGStreamReader.m - Enhanced version with HLS support
#import "MJPEGStreamReader.h"
#import <AVFoundation/AVFoundation.h>

@interface MJPEGStreamReader () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *imageData;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) AVPlayer *hlsPlayer;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL isHLS;
@end

@implementation MJPEGStreamReader

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _streamURL = url;
        _isConnecting = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        
        NSString *urlString = url.absoluteString.lowercaseString;
        _isHLS = [urlString hasSuffix:@".m3u8"] || [urlString containsString:@".m3u8"];
        
        NSLog(@"[VCamStream] Initialized with URL: %@, type: %@", url, _isHLS ? @"HLS" : @"MJPEG");
    }
    return self;
}

- (void)startStreaming {
    if (_isRunning) {
        NSLog(@"[VCamStream] Already streaming");
        return;
    }
    
    _isRunning = YES;
    _isConnecting = YES;
    
    NSLog(@"[VCamStream] Starting %@ stream...", _isHLS ? @"HLS" : @"MJPEG");
    
    if (_isHLS) {
        [self startHLSStream];
    } else {
        [self startMJPEGStream];
    }
}

- (void)stopStreaming {
    NSLog(@"[VCamStream] Stopping stream...");
    _isRunning = NO;
    _isConnecting = NO;
    
    if (_isHLS) {
        [self stopHLSStream];
    } else {
        [self stopMJPEGStream];
    }
}

#pragma mark - HLS Stream

- (void)startHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:self.streamURL];
        self.hlsPlayer = [AVPlayer playerWithPlayerItem:playerItem];
        
        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        
        self.videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixelBufferAttributes];
        [playerItem addOutput:self.videoOutput];
        
        [self.hlsPlayer play];
        
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        
        self.isConnecting = NO;
        NSLog(@"[VCamStream] HLS player started");
        
        [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(playerItemDidReachEnd:)
                                                   name:AVPlayerItemDidPlayToEndTimeNotification
                                                 object:playerItem];
    });
}

- (void)displayLinkCallback:(CADisplayLink *)sender {
    if (!self.isRunning) return;
    
    CMTime currentTime = [self.hlsPlayer currentTime];
    CVPixelBufferRef pixelBuffer = [self.videoOutput copyPixelBufferForItemTime:currentTime itemTimeForDisplay:nil];
    
    if (pixelBuffer) {
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        CIContext *context = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
        UIImage *image = [UIImage imageWithCGImage:cgImage];
        CGImageRelease(cgImage);
        CVPixelBufferRelease(pixelBuffer);
        
        if (self.frameCallback) {
            self.frameCallback(image);
        }
        
        self->_frameCount++;
        self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)notification {
    NSLog(@"[VCamStream] HLS stream ended, restarting...");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.hlsPlayer seekToTime:kCMTimeZero];
        [self.hlsPlayer play];
    });
}

- (void)stopHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [self.displayLink invalidate];
        self.displayLink = nil;
        [self.hlsPlayer pause];
        self.hlsPlayer = nil;
        self.videoOutput = nil;
    });
}

#pragma mark - MJPEG Stream

- (void)startMJPEGStream {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 300.0;
    config.HTTPMaximumConnectionsPerHost = 1;
    
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    self.imageData = [NSMutableData data];
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.streamURL];
    [request setValue:@"multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];
    
    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];
    
    NSLog(@"[VCamStream] MJPEG stream task started");
}

- (void)stopMJPEGStream {
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
    self.imageData = nil;
}

#pragma mark - NSURLSessionDataDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self->_isConnecting = NO;
    NSLog(@"[VCamStream] MJPEG connected successfully");
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!self.isRunning) return;
    
    [self.imageData appendData:data];
    
    NSData *startMarker = [NSData dataWithBytes:(unsigned char[]){0xFF, 0xD8} length:2];
    NSData *endMarker = [NSData dataWithBytes:(unsigned char[]){0xFF, 0xD9} length:2];
    
    NSRange startRange = [self.imageData rangeOfData:startMarker options:0 range:NSMakeRange(0, self.imageData.length)];
    NSRange endRange = [self.imageData rangeOfData:endMarker options:0 range:NSMakeRange(0, self.imageData.length)];
    
    if (startRange.location != NSNotFound && endRange.location != NSNotFound && endRange.location > startRange.location) {
        NSRange imageRange = NSMakeRange(startRange.location, endRange.location + endMarker.length - startRange.location);
        NSData *imageData = [self.imageData subdataWithRange:imageRange];
        
        UIImage *image = [UIImage imageWithData:imageData];
        if (image) {
            if (self.frameCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.frameCallback(image);
                });
            }
            
            self->_frameCount++;
            self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
        }
        
        [self.imageData replaceBytesInRange:NSMakeRange(0, endRange.location + endMarker.length) withBytes:NULL length:0];
    }
    
    if (self.imageData.length > 10 * 1024 * 1024) {
        [self.imageData setLength:0];
        NSLog(@"[VCamStream] Buffer overflow, cleared");
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        NSLog(@"[VCamStream] MJPEG stream error: %@", error.localizedDescription);
        
        if (self.errorCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.errorCallback(error);
            });
        }
        
        if (self.isRunning) {
            NSLog(@"[VCamStream] Reconnecting in 3 seconds...");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.isRunning) {
                    [self startMJPEGStream];
                }
            });
        }
    } else {
        NSLog(@"[VCamStream] MJPEG stream ended normally");
    }
}

- (void)dealloc {
    [self stopStreaming];
}

@end
