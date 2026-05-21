#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL vcamEnabled = YES;
static NSString *streamUrl = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static NSString *logPath = @"/tmp/.com.apple.media.cache";
static AVPlayer *vcamPlayer = nil;
static AVPlayerItemVideoOutput *vcamOutput = nil;
static CVPixelBufferRef vcamBuffer = NULL;
static CIContext *vcamContext = nil;

// Hidden logging mechanism
void vcam_log(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[[message stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [[message stringByAppendingString:@"\n"] writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

static void vcam_sync() {
    if (!vcamOutput || !vcamEnabled || !vcamPlayer) return;
    CMTime t = [vcamPlayer.currentItem currentTime];
    if ([vcamOutput hasNewPixelBufferForTime:t]) {
        CVPixelBufferRef pb = [vcamOutput copyPixelBufferForTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (vcamBuffer) CVPixelBufferRelease(vcamBuffer);
            vcamBuffer = pb;
        }
    }
}

// ISA-swizzled class for Photos
@interface VCamPhoto : AVCapturePhoto
@end

@implementation VCamPhoto
- (CVPixelBufferRef)pixelBuffer {
    vcam_sync();
    return vcamBuffer ? (CVPixelBufferRef)CFRetain(vcamBuffer) : NULL;
}
- (CVPixelBufferRef)previewPixelBuffer {
    return [self pixelBuffer];
}
- (CGImageRef)CGImageRepresentation {
    vcam_sync();
    if (!vcamBuffer) return NULL;
    if (!vcamContext) vcamContext = [CIContext contextWithOptions:nil];
    CIImage *ci = [CIImage imageWithCVPixelBuffer:vcamBuffer];
    return [vcamContext createCGImage:ci fromRect:ci.extent];
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

// Proxy Delegate for Video & Photo Output
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id originalDelegate;
@end

@implementation VCamProxy
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    if (vcamEnabled && vcamBuffer) {
        vcam_sync();
        CMSampleBufferRef nb = NULL;
        CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, vcamBuffer, &fd);
        CMSampleTimingInfo ti; 
        CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, vcamBuffer, YES, NULL, NULL, fd, &ti, &nb);
        if (nb) {
            if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
                [self.originalDelegate captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            }
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.originalDelegate captureOutput:o didOutputSampleBuffer:s fromConnection:c];
    }
}

- (void)captureOutput:(AVCaptureOutput *)o didFinishProcessingPhoto:(AVCapturePhoto *)p error:(NSError *)e {
    if (vcamEnabled && p && vcamBuffer) {
        vcam_sync();
        object_setClass(p, [VCamPhoto class]);
    }
    if ([self.originalDelegate respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        [self.originalDelegate captureOutput:o didFinishProcessingPhoto:p error:e];
    }
}

- (BOOL)respondsToSelector:(SEL)a {
    return [super respondsToSelector:a] || [self.originalDelegate respondsToSelector:a];
}
- (id)forwardingTargetForSelector:(SEL)a {
    return self.originalDelegate;
}
@end

// WebKit / WebRTC Support
%hookf(OSStatus, CMSampleBufferCreate, CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, Boolean dataReady, CMSampleBufferMakeDataReadyCallback makeDataReadyCallback, void *makeDataReadyRefcon, CMFormatDescriptionRef formatDescription, CMItemCount numSamples, CMItemCount numSampleTimingEntries, const CMSampleTimingInfo *sampleTimingArray, CMItemCount numSampleSizeEntries, const size_t *sampleSizeArray, CMSampleBufferRef *sbufOut) {
    if (vcamEnabled) {
        return %orig(kCFAllocatorDefault, dataBuffer, dataReady, makeDataReadyCallback, makeDataReadyRefcon, formatDescription, numSamples, numSampleTimingEntries, sampleTimingArray, numSampleSizeEntries, sampleSizeArray, sbufOut);
    }
    return %orig;
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)d queue:(dispatch_queue_t)q {
    if (vcamEnabled && d && ![d isKindOfClass:[VCamProxy class]]) {
        VCamProxy *p = [[VCamProxy alloc] init]; p.originalDelegate = d;
        objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)s delegate:(id<AVCapturePhotoCaptureDelegate>)d {
    if (vcamEnabled && d && ![d isKindOfClass:[VCamProxy class]]) {
        VCamProxy *p = [[VCamProxy alloc] init]; p.originalDelegate = d;
        objc_setAssociatedObject(self, @selector(capturePhotoWithSettings:delegate:), p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(s, p);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!vcamEnabled) return;
    if (!vcamPlayer) {
        NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
        if (p) {
            vcamEnabled = [p[@"enabled"] boolValue];
            streamUrl = p[@"rtspURL"] ?: streamUrl;
        }
        vcamPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:streamUrl]];
        vcamOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [vcamPlayer.currentItem addOutput:vcamOutput];
        [vcamPlayer play];
        
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { vcam_sync(); }];
    }
}
%end

%ctor {
    %init;
    vcam_log(@"VCamPro Loaded in %@", [[NSProcessInfo processInfo] processName]);
}
