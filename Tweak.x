#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

// --- WORKAROUND FOR COMPILER BLINDNESS ---
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

// --- СКРЫТОЕ ЛОГИРОВАНИЕ ---
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

// --- СИНХРОНИЗАЦИЯ БУФЕРА ---
static void vcam_sync() {
    if (!vcamEnabled || !vcamOutput || !vcamPlayer) return;
    
    CMTime currentTime = [vcamPlayer.currentItem currentTime];
    if ([vcamOutput hasNewPixelBufferForTime:currentTime]) {
        CVPixelBufferRef pb = [vcamOutput copyPixelBufferForTime:currentTime itemTimeForDisplay:NULL];
        if (pb) {
            if (vcamBuffer) CVPixelBufferRelease(vcamBuffer);
            vcamBuffer = pb;
        }
    }
}

// --- ПОДМЕНА ФОТО (ISA-SWIZZLING) ---
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
    NSData *d = UIImageJPEGRepresentation(ui, 0.95);
    CGImageRelease(cg);
    return d;
}

- (NSDictionary *)metadata {
    return @{ (id)kCGImagePropertyTIFFDictionary : @{ (id)kCGImagePropertyTIFFSoftware : @"Apple" } };
}
@end

// --- УНИВЕРСАЛЬНЫЙ ПРОКСИ (ВИДЕО/ФОТО/QR) ---
@interface VCamProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) id target;
@end

@implementation VCamProxy

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (vcamEnabled && vcamBuffer) {
        vcam_sync();
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
            CFRelease(newBuffer);
            if (formatDesc) CFRelease(formatDesc);
            return;
        }
    }
    if ([self.target respondsToSelector:@selector(captureOutput:didOutputSampleBuffer:fromConnection:)]) {
        [self.target captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (vcamEnabled && photo && vcamBuffer) {
        vcam_sync();
        object_setClass(photo, [VCamPhoto class]);
    }
    if ([self.target respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)]) {
        [(id<AVCapturePhotoCaptureDelegate>)self.target captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:photo error:error];
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputMetadataObjects:(NSArray *)metadataObjects fromConnection:(AVCaptureConnection *)connection {
    if ([self.target respondsToSelector:@selector(captureOutput:didOutputMetadataObjects:fromConnection:)]) {
        [self.target captureOutput:output didOutputMetadataObjects:@[] fromConnection:connection];
    }
}

- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [self.target respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    return self.target;
}
@end

// --- ХУКИ ---

%hookf(OSStatus, CMSampleBufferCreate, CFAllocatorRef allocator, CMBlockBufferRef dataBuffer, Boolean dataReady, CMSampleBufferMakeDataReadyCallback makeDataReadyCallback, void *makeDataReadyRefcon, CMFormatDescriptionRef formatDescription, CMItemCount numSamples, CMItemCount numSampleTimingEntries, const CMSampleTimingInfo *sampleTimingArray, CMItemCount numSampleSizeEntries, const size_t *sampleSizeArray, CMSampleBufferRef *sbufOut) {
    if (vcamEnabled) {
        return %orig(kCFAllocatorDefault, dataBuffer, dataReady, makeDataReadyCallback, makeDataReadyRefcon, formatDescription, numSamples, numSampleTimingEntries, sampleTimingArray, numSampleSizeEntries, sampleSizeArray, sbufOut);
    }
    return %orig;
}

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (vcamEnabled && delegate && ![delegate isKindOfClass:[VCamProxy class]]) {
        VCamProxy *proxy = [[VCamProxy alloc] init];
        proxy.target = delegate;
        objc_setAssociatedObject(self, _cmd, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(proxy, queue);
    } else %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (vcamEnabled && delegate && ![delegate isKindOfClass:[VCamProxy class]]) {
        VCamProxy *proxy = [[VCamProxy alloc] init];
        proxy.target = delegate;
        objc_setAssociatedObject(self, _cmd, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(settings, proxy);
    } else %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!vcamEnabled) return;
    self.hidden = YES;
    
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
        [self.superlayer insertSublayer:playerLayer above:self];
        objc_setAssociatedObject(self, "_vcam_layer", playerLayer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        
        [NSTimer scheduledTimerWithTimeInterval:0.033 repeats:YES block:^(NSTimer *t) { vcam_sync(); }];
    }
    
    AVPlayerLayer *vcamLayer = objc_getAssociatedObject(self, "_vcam_layer");
    if (vcamLayer) vcamLayer.frame = self.bounds;
}
%end

%ctor {
    @autoreleasepool {
        vcam_log(@"VCamPro Header Fixed Loaded in %@", [[NSProcessInfo processInfo] processName]);
        %init;
    }
}
