#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8888/live/stream/index.m3u8";

static AVPlayer *gPlayer = nil;
static AVPlayerItemVideoOutput *gVideoOutput = nil;
static CVPixelBufferRef gGlobalBuffer = NULL;
static dispatch_semaphore_t gBufferLock;

static void UpdateBuffer() {
    if (!gVideoOutput || !enabled) return;
    
    if (dispatch_semaphore_wait(gBufferLock, dispatch_time(DISPATCH_TIME_NOW, 0)) == 0) {
        CMTime vTime = [gPlayer.currentItem currentTime];
        if ([gVideoOutput hasNewPixelBufferForItemTime:vTime]) {
            CVPixelBufferRef pb = [gVideoOutput copyPixelBufferForItemTime:vTime itemTimeForDisplay:NULL];
            if (pb) {
                if (gGlobalBuffer) CVPixelBufferRelease(gGlobalBuffer);
                gGlobalBuffer = pb; 
            }
        }
        dispatch_semaphore_signal(gBufferLock);
    }
}

@interface VCamPhotoProxy : NSObject <AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id originalDelegate;
@end

@implementation VCamPhotoProxy
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if ([self.originalDelegate respondsToSelector:_cmd]) {
        [self.originalDelegate captureOutput:output didFinishProcessingPhoto:photo error:error];
    }
}
- (void)captureOutput:(AVCapturePhotoOutput *)output willBeginCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings {
    if ([self.originalDelegate respondsToSelector:_cmd]) [self.originalDelegate captureOutput:output willBeginCaptureForResolvedSettings:settings];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings error:(NSError *)error {
    if ([self.originalDelegate respondsToSelector:_cmd]) [self.originalDelegate captureOutput:output didFinishCaptureForResolvedSettings:settings error:error];
}
@end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (enabled && delegate && ![delegate isKindOfClass:[VCamPhotoProxy class]]) {
        VCamPhotoProxy *proxy = [[VCamPhotoProxy alloc] init];
        proxy.originalDelegate = delegate;
        %orig(settings, proxy);
        return;
    }
    %orig;
}
%end

%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    if (enabled && gGlobalBuffer) return CVPixelBufferRetain(gGlobalBuffer);
    return %orig;
}
- (NSData *)fileDataRepresentation {
    if (enabled && gGlobalBuffer) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:gGlobalBuffer];
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
        NSData *data = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.95);
        CGImageRelease(cg);
        return data;
    }
    return %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;
    self.hidden = YES;

    if (!gPlayer) {
        gBufferLock = dispatch_semaphore_create(1);
        gPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:streamURL]];
        gVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [gPlayer.currentItem addOutput:gVideoOutput];
        [gPlayer play];

        AVPlayerLayer *pl = [AVPlayerLayer playerLayerWithPlayer:gPlayer];
        pl.frame = self.bounds;
        pl.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:pl above:self];

        [NSTimer scheduledTimerWithTimeInterval:0.033 repeats:YES block:^(NSTimer *t) { UpdateBuffer(); }];
    }
}
%end