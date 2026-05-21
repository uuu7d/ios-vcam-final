#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

// --- COMPILER WORKAROUND ---
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
static id vcamLock = nil;

// --- LOGGING ---
void vcam_log(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [entry writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
}

// --- SYNC ---
static void vcam_sync() {
    if (!vcamEnabled || !vcamOutput || !vcamPlayer) return;
    if (!vcamLock) vcamLock = [NSObject new];
    CMTime t = [vcamPlayer.currentItem currentTime];
    if ([(AVPlayerItemVideoOutput *)vcamOutput hasNewPixelBufferForTime:t]) {
        CVPixelBufferRef pb = [(AVPlayerItemVideoOutput *)vcamOutput copyPixelBufferForTime:t itemTimeForDisplay:NULL];
        if (pb) {
            @synchronized(vcamLock) {
                if (vcamBuffer) CVPixelBufferRelease(vcamBuffer);
                vcamBuffer = pb;
            }
        }
    }
}

// --- PHOTO ---
@interface VCamPhoto : AVCapturePhoto
@end
@implementation VCamPhoto
- (CVPixelBufferRef)pixelBuffer {
    vcam_sync();
    @synchronized(vcamLock) { return vcamBuffer ? (CVPixelBufferRef)CFRetain(vcamBuffer) : NULL; }
}
- (CVPixelBufferRef)previewPixelBuffer { return [self pixelBuffer]; }
- (CGImageRef)CGImageRepresentation {
    vcam_sync();
    @synchronized(vcamLock) {
        if (!vcamBuffer) return NULL;
        if (!vcamContext) vcamContext = [CIContext contextWithOptions:nil];
        return [vcamContext createCGImage:[CIImage imageWithCVPixelBuffer:vcamBuffer] fromRect:[CIImage imageWithCVPixelBuffer:vcamBuffer].extent];
    }
}
- (NSData *)fileDataRepresentation {
    CGImageRef cg = [self CGImageRepresentation]; if (!cg) return nil;
    UIImage *ui = [UIImage imageWithCGImage:cg]; NSData *d = UIImageJPEGRepresentation(ui, 0.9);
    CGImageRelease(cg); return d;
}
@end

// --- PROXY ---
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id target;
@end
@implementation VCamProxy
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    vcam_sync();
    @synchronized(vcamLock) {
        if (vcamEnabled && vcamBuffer) {
            CMSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
            CMVideoFormatDescriptionCreateForImageBuffer(NULL, vcamBuffer, &fd);
            CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
            if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, vcamBuffer, YES, NULL, NULL, fd, &ti, &nb) == noErr && nb) {
                if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
                CFRelease(nb); if (fd) CFRelease(fd); return;
            }
        }
    }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(AVCapturePhotoOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)p error:(NSError *)e {
    if (vcamEnabled && p) { vcam_sync(); @synchronized(vcamLock) { if (vcamBuffer) object_setClass(p, [VCamPhoto class]); } }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didFinishProcessingPhoto:p error:e];
}
- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.target respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.target; }
@end

// --- HOOKS ---
%hookf(OSStatus, CMSampleBufferCreate, CFAllocatorRef a, CMBlockBufferRef d, Boolean r, CMSampleBufferMakeDataReadyCallback c, void *rc, CMFormatDescriptionRef f, CMItemCount ns, CMItemCount nt, const CMSampleTimingInfo *ta, CMItemCount nse, const size_t *sa, CMSampleBufferRef *so) {
    if (vcamEnabled) return %orig(kCFAllocatorDefault, d, r, c, rc, f, ns, nt, ta, nse, sa, so);
    return %orig;
}
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
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig; if (!vcamEnabled) return;
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_vcam_layer");
    if (!vcamPlayer) {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (p) { vcamEnabled = [p[@"enabled"] boolValue]; streamUrl = p[@"rtspURL"] ?: streamUrl; }
        vcamPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:streamUrl]];
        vcamOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [vcamPlayer.currentItem addOutput:vcamOutput]; [vcamPlayer play];
        l = [AVPlayerLayer playerLayerWithPlayer:vcamPlayer]; l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self addSublayer:l]; objc_setAssociatedObject(self, "_vcam_layer", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.033 repeats:YES block:^(NSTimer *t) { vcam_sync(); }];
    }
    if (l) { [CATransaction begin]; [CATransaction setDisableActions:YES]; l.frame = self.bounds; [CATransaction commit]; }
}
%end
%ctor { @autoreleasepool { vcam_log(@"VCamPro Safe v2 Loaded in %@", [[NSProcessInfo processInfo] processName]); %init; } }
