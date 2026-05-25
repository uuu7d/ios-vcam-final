#import \"MJPEGStreamReader.h\
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
        NSLog(@\"[VCamStream] HLS player started\");
        
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
    NSLog(@\"[VCamStream] HLS stream ended, restarting...\");
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

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.isConnecting = NO;
    NSLog(@\"[VCamStream] MJPEG connected successfully\");
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
        NSLog(@\"[VCamStream] Buffer overflow, cleared\");
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        NSLog(@\"[VCamStream] MJPEG stream error: %@\", error.localizedDescription);
        
        if (self.errorCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self.errorCallback(error);
            });
        }
        
        if (self.isRunning) {
            NSLog(@\"[VCamStream] Reconnecting in 3 seconds...\");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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
"
