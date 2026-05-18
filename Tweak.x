#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Photos/Photos.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8888/live/stream/index.m3u8";

static AVPlayer *gPlayer = nil;
static AVPlayerItemVideoOutput *gVideoOutput = nil;
static CVPixelBufferRef gGlobalBuffer = NULL;

static void SyncFrame() {
    if (!gVideoOutput || !enabled) return;
    CMTime vTime = [gPlayer.currentItem currentTime];
    CVPixelBufferRef pb = [gVideoOutput copyPixelBufferForItemTime:vTime itemTimeForDisplay:NULL];
    if (pb) {
        if (gGlobalBuffer) CVPixelBufferRelease(gGlobalBuffer);
        gGlobalBuffer = pb; 
    }
}

// --- GALLERY HIJACK ---
%hook PHAssetCreationRequest
+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    SyncFrame();
    if (enabled && gGlobalBuffer) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:gGlobalBuffer];
        UIImage *fake = [UIImage imageWithCIImage:ci];
        return %orig(fake);
    }
    return %orig;
}

+ (instancetype)creationRequestForAssetFromImageData:(NSData *)imageData {
    SyncFrame();
    if (enabled && gGlobalBuffer) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:gGlobalBuffer];
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
        NSData *fakeData = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
        CGImageRelease(cg);
        return %orig(fakeData);
    }
    return %orig;
}
%end

// --- CAPTURE HIJACK ---
%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    SyncFrame();
    return (enabled && gGlobalBuffer) ? CVPixelBufferRetain(gGlobalBuffer) : %orig;
}

- (NSData *)fileDataRepresentation {
    SyncFrame();
    if (enabled && gGlobalBuffer) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:gGlobalBuffer];
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
        NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
        CGImageRelease(cg);
        return data;
    }
    return %orig;
}
%end

// --- PREVIEW HIJACK ---
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;
    self.hidden = YES;

    if (!gPlayer) {
        gPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:streamURL]];
        gVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [gPlayer.currentItem addOutput:gVideoOutput];
        [gPlayer play];

        AVPlayerLayer *pl = [AVPlayerLayer playerLayerWithPlayer:gPlayer];
        pl.frame = self.bounds;
        pl.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:pl above:self];

        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { SyncFrame(); }];
    }
}
%end