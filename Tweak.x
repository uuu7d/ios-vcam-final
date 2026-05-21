#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

// --- WORKAROUND FOR SDK 17.5 COMPILER ---
@interface AVPlayerItemVideoOutput (VCamFix)
- (BOOL)hasNewPixelBufferForTime:(CMTime)itemTime;
- (CVPixelBufferRef)copyPixelBufferForTime:(CMTime)itemTime itemTimeForDisplay:(CMTime *)outItemTimeForDisplay;
@end

static BOOL vcamEnabled = YES;
static NSString *streamUrl = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static NSString *logPath = @"/tmp/.com.apple.media.cache";

static AVPlayer *vcamPlayer = nil;
static AVPlayerItemVideoOutput *vcamOutput = nil;
static CVPixelBufferRef vcamBuffer = NULL;
static CIContext *vcamContext = nil;
static NSObject *vcamLock = nil;

// --- LOGGING ---
void vcam_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *logEntry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], message];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logEntry dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logEntry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// --- CORE SYNC (Thread Safe) ---
static void vcam_sync() {
    if (!vcamEnabled || !vcamOutput || !vcamPlayer) return;
    if (!vcamLock) vcamLock = [NSObject new];

    CMTime currentTime = [vcamPlayer.currentItem currentTime];
    if ([(AVPlayerItemVideoOutput *)vcamOutput hasNewPixelBufferForTime:currentTime]) {
        CVPixelBufferRef pb = [(AVPlayerItemVideoOutput *)vcamOutput copyPixelBufferForTime:currentTime itemTimeForDisplay:NULL];
        if (pb) {
            @synchronized(vcamLock) {
                if (vcamBuffer) CVPixelBufferRelease(vcamBuffer);
                vcamBuffer = pb;
            }
        }
    }
}

// --- PHOTO HIJACK ---
@interface VCamPhoto : AVCapturePhoto
@end

@implementation VCamPhoto
- (CVPixelBufferRef)pixelBuffer {
    vcam_sync();
    @synchronized(vcamLock) {
        return vcamBuffer ? (CVPixelBufferRef)CFRetain(vcamBuffer) : NULL;
    }
}
- (CVPixelBufferRef)previewPixelBuffer { return [self pixelBuffer]; }
- (CGImageRef)CGImageRepresentation {
    vcam_sync();
    @synchronized(vcamLock) {
        if (!vcamBuffer) return NULL;
        if (!vcamContext) vcamContext = [CIContext contextWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:vcamBuffer];
        return [vcamContext createCGImage:ci fromRect:ci.extent];
    }
}
- (NSData *)fileDataRepresentation {
    CGImageRef cg = [self CGImageRepresentation];
    if (!cg) return nil;
    UIImage *ui = [UIImage imageWithCGImage:cg];
    NSData *d = UIImageJPEGRepresentation(ui, 0.9);
    CGImageRelease(cg);
    return d;
}
@end

// --- PROXY DELEGATE ---
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id target;
@end

@implementation VCamProxy
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    vcam_sync();
    @synchronized(vcamLock) {
        if (vcamEnabled && vcamBuffer) {
            CMSampleBufferRef newBuffer = NULL;
            CMVideoFormatDescriptionRef formatDesc = NULL;
            CMVideoFormatDescriptionCreateForImageBuffer(NULL, vcamBuffer, &formatDesc);
            CMSampleTimingInfo timingInfo;
            CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
            OSStatus status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, vcamBuffer, YES, NULL, NULL, formatDesc, &timingInfo, &newBuffer);
            if (status == noErr && newBuffer) {
                if ([self.target respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                    [self.target captureOutput:output didOutputSampleBuffer:newBuffer fromConnection:connection];
                }
                CFRelease(newBuffer); if (formatDesc) CFRelease(formatDesc); return;
            }
        }
    }
    if ([self.target respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (vcamEnabled && photo) {
        vcam_sync();
        @synchronized(vcamLock) { if (vcamBuffer) object_setClass(photo, [VCamPhoto class]); }
    }
    if ([self.target respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        [self.target captureOutput:output didFinishProcessingPhoto:photo error:error];
    }
}

- (BOOL)respondsToSelector:(SEL)sel { return [super respondsToSelector:sel] || [self.target respondsToSelector:sel]; }
- (id)forwardingTargetForSelector:(SEL)sel { return self.target; }
@end

// --- HOOKS ---
%hookf(OSStatus, CMSampleBufferCreate, CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, Boolean dataReady, CMSampleBufferMakeDataReadyCallback makeDataReadyCallback, void *makeDataReadyRefcon, CMFormatDescriptionRef formatDescription, CMItemCount numSamples, CMItemCount numSampleTimingEntries, const CMSampleTimingInfo *sampleTimingArray, CMItemCount numSampleSizeEntries, const size_t *sampleSizeArray, CMSampleBufferRef *sbufOut) {
    if (vcamEnabled) return %orig(kCFAllocatorDefault, dataBuffer, dataReady, makeDataReadyCallback, makeDataReadyRefcon, formatDescription, numSamples, numSampleTimingEntries, sampleTimingArray, numSampleSizeEntries, sampleSizeArray, sbufOut);
    return %orig;
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    if (vcamEnabled && delegate && ![delegate isKindOfClass:[VCamProxy class]]) {
        VCamProxy *proxy = [[VCamProxy alloc] init]; proxy.target = delegate;
        objc_setAssociatedObject(self, _cmd, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(proxy, queue);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id)delegate {
    if (vcamEnabled && delegate && ![delegate isKindOfClass:[VCamProxy class]]) {
        VCamProxy *proxy = [[VCamProxy alloc] init]; proxy.target = delegate;
        objc_setAssociatedObject(self, _cmd, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(settings, proxy);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!vcamEnabled) return;
    
    if (!vcamPlayer) {
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (prefs) {
            vcamEnabled = [prefs[@"enabled"] boolValue];
            streamUrl = prefs[@"rtspURL"] ?: streamUrl;
        }
        vcamPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:streamUrl]];
        vcamOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [vcamPlayer.currentItem addOutput:vcamOutput];
        [vcamPlayer play];
        
        AVPlayerLayer *playerLayer = [AVPlayerLayer playerLayerWithPlayer:vcamPlayer];
        playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        playerLayer.frame = self.bounds;
        [self addSublayer:playerLayer];
        objc_setAssociatedObject(self, "_vcam_layer", playerLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        [NSTimer scheduledTimerWithTimeInterval:0.033 repeats:YES block:^(NSTimer *t) { vcam_sync(); }];
    }
    
    AVPlayerLayer *playerLayer = objc_getAssociatedObject(self, "_vcam_layer");
    if (playerLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        playerLayer.frame = self.bounds;
        [CATransaction commit];
    }
}
%end

%ctor {
    @autoreleasepool {
        vcam_log(@"VCamPro Safe Core Loaded in %@", [[NSProcessInfo processInfo] processName]);
        %init;
    }
}
