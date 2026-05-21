#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>

@interface AVPlayerItemVideoOutput (VCamFix)
- (BOOL)hasNewPixelBufferForTime:(CMTime)itemTime;
- (CVPixelBufferRef)copyPixelBufferForTime:(CMTime)itemTime itemTimeForDisplay:(CMTime *)outItemTimeForDisplay;
@end

static BOOL vcamEnabled = YES;
static NSString *streamUrl = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *vcamPlayer = nil;
static AVPlayerItemVideoOutput *vcamOutput = nil;
static CVPixelBufferRef vcamBuffer = NULL;
static dispatch_queue_t vcamQueue = nil;

static void vcam_sync() {
    if (!vcamEnabled) return;
    if (!vcamQueue) vcamQueue = dispatch_queue_create("com.murkaska.vcam.sync", DISPATCH_QUEUE_SERIAL);
    
    if (!vcamPlayer) {
        vcamPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:streamUrl]];
        vcamOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [vcamPlayer.currentItem addOutput:vcamOutput];
        [vcamPlayer play];
    }

    dispatch_async(vcamQueue, ^{
        CMTime t = [vcamPlayer.currentItem currentTime];
        if ([(AVPlayerItemVideoOutput *)vcamOutput hasNewPixelBufferForTime:t]) {
            CVPixelBufferRef pb = [(AVPlayerItemVideoOutput *)vcamOutput copyPixelBufferForTime:t itemTimeForDisplay:NULL];
            if (pb) {
                if (vcamBuffer) CVPixelBufferRelease(vcamBuffer);
                vcamBuffer = pb;
            }
        }
    });
}

@interface VCamPhoto : AVCapturePhoto
@end
@implementation VCamPhoto
- (CVPixelBufferRef)pixelBuffer {
    vcam_sync();
    return vcamBuffer ? (CVPixelBufferRef)CFRetain(vcamBuffer) : NULL;
}
- (CVPixelBufferRef)previewPixelBuffer { return [self pixelBuffer]; }
@end

@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id target;
@end
@implementation VCamProxy
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    vcam_sync();
    if (vcamEnabled && vcamBuffer) {
        CMSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, vcamBuffer, &fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, vcamBuffer, YES, NULL, NULL, fd, &ti, &nb) == noErr && nb) {
            if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (vcamEnabled && p && vcamBuffer) object_setClass(p, [VCamPhoto class]);
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didFinishProcessingPhoto:p error:e];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.target respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.target; }
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (vcamEnabled && d && ![d isKindOfClass:[VCamProxy class]]) {
        VCamProxy *p = [[VCamProxy alloc] init]; p.target = d;
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (vcamEnabled && d && ![d isKindOfClass:[VCamProxy class]]) {
        VCamProxy *p = [[VCamProxy alloc] init]; p.target = d;
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(s, p);
    } else %orig;
}
%end

%ctor { @autoreleasepool { %init; } }
