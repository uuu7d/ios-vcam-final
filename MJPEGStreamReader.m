#import "MJPEGStreamReader.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

@interface MJPEGStreamReader () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableData *imageData;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) AVPlayer *hlsPlayer;
@property (nonatomic, strong) AVPlayerItemVideoOutput *videoOutput;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) BOOL isHLS;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, assign, readwrite) BOOL isConnecting;
@property (nonatomic, assign, readwrite) NSUInteger frameCount;
@property (nonatomic, assign, readwrite) CFAbsoluteTime lastFrameTime;
@end

@implementation MJPEGStreamReader

- (instancetype)initWithURL:(NSURL *)url {
    self = [super init];
    if (self) {
        _streamURL = url;
        _isConnecting = NO;
        _frameCount = 0;
        _lastFrameTime = 0;
        _ciContext = [CIContext contextWithOptions:nil];

        NSString *urlString = url.absoluteString.lowercaseString;
        _isHLS = [urlString containsString:@".m3u8"];

        NSLog(@"[VCamStream] init URL=%@ type=%@", url, _isHLS ? @"HLS" : @"MJPEG");
    }
    return self;
}

- (void)startStreaming {
    if (_isRunning) return;
    _isRunning = YES;
    _isConnecting = YES;
    if (_isHLS) [self startHLSStream]; else [self startMJPEGStream];
}

- (void)stopStreaming {
    _isRunning = NO;
    _isConnecting = NO;
    if (_isHLS) [self stopHLSStream]; else [self stopMJPEGStream];
}

#pragma mark - HLS

- (void)startHLSStream {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:self.streamURL];
        self.hlsPlayer = [AVPlayer playerWithPlayerItem:item];

        NSDictionary *attrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
        };
        self.videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
        [item addOutput:self.videoOutput];

        [self.hlsPlayer play];

        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

        self.isConnecting = NO;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemDidReachEnd:)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:item];
    });
}

- (void)displayLinkCallback:(CADisplayLink *)sender {
    if (!self.isRunning) return;

    CMTime t = [self.hlsPlayer currentTime];
    CVPixelBufferRef pb = [self.videoOutput copyPixelBufferForItemTime:t itemTimeForDisplay:nil];
    if (!pb) return;

    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    CGImageRef cg = [self.ciContext createCGImage:ci fromRect:ci.extent];
    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    CVPixelBufferRelease(pb);

    if (self.frameCallback) self.frameCallback(image);
    self->_frameCount++;
    self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
}

- (void)playerItemDidReachEnd:(NSNotification *)n {
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

#pragma mark - MJPEG

- (void)startMJPEGStream {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.timeoutIntervalForRequest = 15.0;
    cfg.timeoutIntervalForResource = 300.0;
    cfg.HTTPMaximumConnectionsPerHost = 1;

    self.session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    self.imageData = [NSMutableData data];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.streamURL];
    [req setValue:@"multipart/x-mixed-replace" forHTTPHeaderField:@"Accept"];

    self.task = [self.session dataTaskWithRequest:req];
    [self.task resume];
}

- (void)stopMJPEGStream {
    [self.task cancel];
    self.task = nil;
    [self.session invalidateAndCancel];
    self.session = nil;
    self.imageData = nil;
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t
didReceiveResponse:(NSURLResponse *)r completionHandler:(void (^)(NSURLSessionResponseDisposition))h {
    self.isConnecting = NO;
    h(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d {
    if (!self.isRunning) return;
    [self.imageData appendData:d];

    NSData *start = [NSData dataWithBytes:(unsigned char[]){0xFF,0xD8} length:2];
    NSData *end   = [NSData dataWithBytes:(unsigned char[]){0xFF,0xD9} length:2];

    NSRange sR = [self.imageData rangeOfData:start options:0 range:NSMakeRange(0,self.imageData.length)];
    NSRange eR = [self.imageData rangeOfData:end   options:0 range:NSMakeRange(0,self.imageData.length)];

    if (sR.location != NSNotFound && eR.location != NSNotFound && eR.location > sR.location) {
        NSRange r = NSMakeRange(sR.location, eR.location + end.length - sR.location);
        NSData *img = [self.imageData subdataWithRange:r];
        UIImage *image = [UIImage imageWithData:img];
        if (image) {
            if (self.frameCallback) {
                dispatch_async(dispatch_get_main_queue(), ^{ self.frameCallback(image); });
            }
            self->_frameCount++;
            self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
        }
        [self.imageData replaceBytesInRange:NSMakeRange(0, eR.location + end.length) withBytes:NULL length:0];
    }

    if (self.imageData.length > 10*1024*1024) [self.imageData setLength:0];
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)e {
    if (e) {
        if (self.errorCallback) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.errorCallback(e); });
        }
        if (self.isRunning) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0*NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (self.isRunning) [self startMJPEGStream];
            });
        }
    }
}

- (void)dealloc { [self stopStreaming]; }

@end
