#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8888/live/stream/index.m3u8";

static AVPlayer *gPlayer = nil;
static AVPlayerItemVideoOutput *gVideoOutput = nil;
static CVPixelBufferRef gGlobalBuffer = NULL;

#define LOG_PATH @"/var/mobile/vcam_debug.log"

void VLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[VCam] %@", msg);
    
    NSString *line = [NSString stringWithFormat:@"%@: %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    if (!fh) {
        [line writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

static void SyncFrame() {
    if (!gVideoOutput) return;
    CMTime vTime = [gPlayer.currentItem currentTime];
    CVPixelBufferRef pb = [gVideoOutput copyPixelBufferForItemTime:vTime itemTimeForDisplay:NULL];
    if (pb) {
        if (gGlobalBuffer) CVPixelBufferRelease(gGlobalBuffer);
        gGlobalBuffer = pb;
    }
}

// --- ХУК: Подмена ВИДЕОПОТОКА --- 
%hook NSObject
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (enabled) {
        SyncFrame();
        if (gGlobalBuffer) {
            CMVideoFormatDescriptionRef fd;
            CMVideoFormatDescriptionCreateForImageBuffer(NULL, gGlobalBuffer, &fd);
            CMSampleTimingInfo ti = { kCMTimeInvalid, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), kCMTimeInvalid };
            CMSampleBufferRef fake;
            CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, gGlobalBuffer, YES, NULL, NULL, fd, &ti, &fake);
            
            %orig(output, fake, connection);
            
            VLog(@"Buffer swapped in captureOutput");
            if (fake) CFRelease(fake);
            if (fd) CFRelease(fd);
            return;
        }
    }
    %orig;
}
%end

// --- ХУК: Подмена ФОТО --- 
%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    VLog(@"App requested pixelBuffer from photo");
    SyncFrame();
    if (enabled && gGlobalBuffer) {
        VLog(@"Successfully providing faked pixelBuffer");
        return CVPixelBufferRetain(gGlobalBuffer);
    }
    VLog(@"Failing to provide fake pixelBuffer - Buffer is NULL");
    return %orig;
}

- (NSData *)fileDataRepresentation {
    VLog(@"App requested fileDataRepresentation from photo");
    SyncFrame();
    if (enabled && gGlobalBuffer) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:gGlobalBuffer];
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
        NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
        if (cg) CGImageRelease(cg);
        VLog(@"Successfully providing faked JPEG data");
        return data;
    }
    VLog(@"Failing to provide fake JPEG - Buffer is NULL");
    return %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id)delegate {
    VLog(@"capturePhotoWithSettings called. Delegate: %@", delegate);
    %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;
    self.hidden = YES;

    if (!gPlayer) {
        VLog(@"Initializing Player in layoutSublayers");
        gPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:streamURL]];
        NSDictionary *attrs = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
        gVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:attrs];
        [gPlayer.currentItem addOutput:gVideoOutput];
        [gPlayer play];

        AVPlayerLayer *pl = [AVPlayerLayer playerLayerWithPlayer:gPlayer];
        pl.frame = self.bounds;
        pl.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:pl above:self];
    }
    VLog(@"Preview layer updated");
}
%end

%ctor {
    VLog(@"VCam Tweak Loaded. Process: %@", [[NSProcessInfo processInfo] processName]);
}
