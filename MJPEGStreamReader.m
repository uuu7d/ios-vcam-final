// MJPEGStreamReader.m - VirtualCamPro V272.2 (Fixed)
#import \"MJPEGStreamReader.h\"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>

@interface MJPEGStreamReader ()
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *imageData;
@property (nonatomic, assign) BOOL isRunning;

@property (nonatomic, strong) AVPlayer *hlsPlayer;
@property (nonatomic, strong) AVPlayerItem *hlsPlayerItem;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL isHLS;

@property (nonatomic, assign, readwrite) BOOL isConnecting;
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
        _isHLS = [urlString hasSuffix:@\".m3u8\"] || [urlString containsString:@\".m3u8\"];

        NSLog(@\"[VCamStream] Initialized with URL: %@, type: %@\", url, _isHLS ? @\"HLS\" : @\"MJPEG\");
    }
    return self;
}

- (void)startStreaming {
    if (_isRunning) {
        NSLog(@\"[VCamStream] Already streaming\");
        return;
    }

    _isRunning = YES;
    _isConnecting = YES;
    NSLog(@\"[VCamStream] Starting %@ stream...\", _isHLS ? @\"HLS\" : @\"MJPEG\");

    if (_isHLS) {
        [self startHLSStream];
    } else {
        [self startMJPEGStream];
    }
}

- (void)stopStreaming {
    NSLog(@\"[VCamStream] Stopping stream...\");
    _isRunning = NO;
    _isConnecting = NO;

    if (_isHLS) {
        [self stopHLSStream];
    } else {
        [self stopMJPEGStream];
    }
}

// ========================================
// HLS STREAM HANDLING
// ========================================

- (void)startHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.hlsPlayerItem = [AVPlayerItem playerItemWithURL:self.streamURL];
        self.hlsPlayer = [AVPlayer playerWithPlayerItem:self.hlsPlayerItem];
        self.hlsPlayer.automaticallyWaitsToMinimizeStalling = NO;
        self.hlsPlayer.muted = YES;

        NSDictionary *pba = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };

        self.videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pba];
        [self.hlsPlayerItem addOutput:self.videoOutput];
        [self.hlsPlayer play];

        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
        self.displayLink.preferredFramesPerSecond = 30;
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

        self.isConnecting = NO;
        NSLog(@\"[VCamStream] HLS player started\");

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemDidReachEnd:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:self.hlsPlayerItem];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemFailed:)
                                                     name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                   object:self.hlsPlayerItem];
    });
}

- (void)displayLinkCallback:(CADisplayLink *)sender {
    if (!self.isRunning) return;

    CMTime currentTime = [self.hlsPlayer currentTime];
    if (![self.videoOutput hasNewPixelBufferForItemTime:currentTime]) return;

    CVPixelBufferRef pixelBuffer = [self.videoOutput copyPixelBufferForItemTime:currentTime itemTimeForDisplay:nil];
    if (!pixelBuffer) return;

    self->_frameCount++;
    self->_lastFrameTime = CFAbsoluteTimeGetCurrent();

    if (self.pixelBufferCallback) {
        self.pixelBufferCallback(pixelBuffer);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    if (self.frameCallback) {
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [ctx createCGImage:ciImage fromRect:ciImage.extent];
        UIImage *image = cgImage ? [UIImage imageWithCGImage:cgImage] : nil;
        if (cgImage) CGImageRelease(cgImage);
        CVPixelBufferRelease(pixelBuffer);

        if (image) {
            self.frameCallback(image);
        }
    } else {
        CVPixelBufferRelease(pixelBuffer);
    }
}

- (void)playerItemDidReachEnd:(NSNotification *)n {
    NSLog(@\"[VCamStream] HLS stream ended, restarting...\");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.hlsPlayer seekToTime:kCMTimeZero];
        [self.hlsPlayer play];
    });
}

- (void)playerItemFailed:(NSNotification *)n {
    NSLog(@\"[VCamStream] HLS item failed, hard-restart in 2s\");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!self.isRunning) return;
        [self stopHLSStream];
        [self startHLSStream];
    });
}

- (void)stopHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        [self.displayLink invalidate];
        self.displayLink = nil;
        [self.hlsPlayer pause];
        self.hlsPlayer = nil;
        self.hlsPlayerItem = nil;
        self.videoOutput = nil;
    });
}

// ========================================
// MJPEG STREAM HANDLING
// ========================================

- (void)startMJPEGStream {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 300.0;
    config.HTTPMaximumConnectionsPerHost = 1;

    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    self.imageData = [NSMutableData data];

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:self.streamURL];
    [request setValue:@\"multipart/x-mixed-replace\" forHTTPHeaderField:@\"Accept\"];

    self.task = [self.session dataTaskWithRequest:request];
    [self.task resume];

    NSLog(@\"[VCamStream] MJPEG stream task started\");
}

- (void)stopMJPEGStream {
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
    self.imageData = nil;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))ch {
    self.isConnecting = NO;
    NSLog(@\"[VCamStream] MJPEG connected successfully\");
    ch(NSURLSessionResponseAllow);
}

- (CVPixelBufferRef)pixelBufferFromJPEGData:(NSData *)jpegData CF_RETURNS_RETAINED {
    CGImageSourceRef src = CGImageSourceCreateWithData((__bridge CFDataRef)jpegData, NULL);
    if (!src) return NULL;

    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) return NULL;

    size_t w = CGImageGetWidth(cg);
    size_t h = CGImageGetHeight(cg);

    NSDictionary *opts = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };

    CVPixelBufferRef pb = NULL;
    if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA,
                            (__bridge CFDictionaryRef)opts, &pb) != kCVReturnSuccess || !pb) {
        CGImageRelease(cg);
        return NULL;
    }

    CVPixelBufferLockBaseAddress(pb, 0);
    void *base = CVPixelBufferGetBaseAddress(pb);
    size_t bpr = CVPixelBufferGetBytesPerRow(pb);

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(base, w, h, 8, bpr, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(cs);

    if (ctx) {
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cg);
        CGContextRelease(ctx);
    }

    CVPixelBufferUnlockBaseAddress(pb, 0);
    CGImageRelease(cg);

    return pb;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (!self.isRunning) return;

    [self.imageData appendData:data];

    NSData *startMarker = [NSData dataWithBytes:(unsigned char[]){0xFF, 0xD8} length:2];
    NSData *endMarker = [NSData dataWithBytes:(unsigned char[]){0xFF, 0xD9} length:2];

    NSRange sRange = [self.imageData rangeOfData:startMarker options:0
                                           range:NSMakeRange(0, self.imageData.length)];
    NSRange eRange = [self.imageData rangeOfData:endMarker options:0
                                           range:NSMakeRange(0, self.imageData.length)];

    if (sRange.location != NSNotFound && eRange.location != NSNotFound &&
        eRange.location > sRange.location) {

        NSRange imgRange = NSMakeRange(sRange.location,
                                       eRange.location + endMarker.length - sRange.location);
        NSData *jpeg = [self.imageData subdataWithRange:imgRange];

        if (self.pixelBufferCallback) {
            CVPixelBufferRef pb = [self pixelBufferFromJPEGData:jpeg];
            if (pb) {
                self->_frameCount++;
                self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
                self.pixelBufferCallback(pb);
                CVPixelBufferRelease(pb);
            }
        }
        else if (self.frameCallback) {
            UIImage *image = [UIImage imageWithData:jpeg];
            if (image) {
                self->_frameCount++;
                self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.frameCallback(image);
                });
            }
        }

        [self.imageData replaceBytesInRange:NSMakeRange(0, eRange.location + endMarker.length)
                                  withBytes:NULL length:0];
    }

    if (self.imageData.length > 10 * 1024 * 1024) {
        [self.imageData setLength:0];
        NSLog(@\"[VCamStream] Buffer overflow, cleared\");
    }
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        NSLog(@\"[VCamStream] MJPEG stream error: %@\", error.localizedDescription);

        if (self.errorCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.errorCallback(error);
            });
        }

        if (self.isRunning) {
            NSLog(@\"[VCamStream] Reconnecting in 3s...\");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.isRunning) {
                    [self startMJPEGStream];
                }
            });
        }
    } else {
        NSLog(@\"[VCamStream] MJPEG stream ended normally\");
    }
}

- (void)dealloc {
    [self stopStreaming];
}

@end
