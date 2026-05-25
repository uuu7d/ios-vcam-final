#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreImage/CoreImage.h>

// --- ХИДЕРЫ ДЛЯ КОМПИЛЯТОРА ---
@interface AVPlayerItemVideoOutput (VCamFix)
- (BOOL)hasNewPixelBufferForTime:(CMTime)itemTime;
- (CVPixelBufferRef)copyPixelBufferForTime:(CMTime)itemTime itemTimeForDisplay:(CMTime *)outItemTimeForDisplay;
@end

static BOOL vcamEnabled = YES;
static NSString *streamUrl = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *vcamPlayer = nil;
static AVPlayerItemVideoOutput *vcamOutput = nil;
static CVPixelBufferRef vcamBuffer = NULL;
static CIContext *vcamContext = nil;
static dispatch_queue_t vcamQueue = nil;

// --- ЛОГИКА СИНХРОНИЗАЦИИ ---
static void vcam_sync() {
    if (!vcamEnabled || !vcamOutput || !vcamPlayer) return;
    if (!vcamQueue) vcamQueue = dispatch_queue_create("com.murkaska.vcam.queue", DISPATCH_QUEUE_SERIAL);

    dispatch_async(vcamQueue, ^{
        CMTime currentTime = [vcamPlayer.currentItem currentTime];
        if ([(AVPlayerItemVideoOutput *)vcamOutput hasNewPixelBufferForTime:currentTime]) {
            CVPixelBufferRef pb = [(AVPlayerItemVideoOutput *)vcamOutput copyPixelBufferForTime:currentTime itemTimeForDisplay:NULL];
            if (pb) {
                if (vcamBuffer) CVPixelBufferRelease(vcamBuffer);
                vcamBuffer = pb;
            }
        }
    });
}

// --- ХУКИ НА ФОТО (ДЛЯ KYC/БАНКОВ) ---
%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    vcam_sync();
    if (vcamEnabled && vcamBuffer) return (CVPixelBufferRef)CFRetain(vcamBuffer);
    return %orig;
}
- (CVPixelBufferRef)previewPixelBuffer {
    vcam_sync();
    if (vcamEnabled && vcamBuffer) return (CVPixelBufferRef)CFRetain(vcamBuffer);
    return %orig;
}
- (NSData *)fileDataRepresentation {
    if (vcamEnabled && vcamBuffer) {
        vcam_sync();
        CIImage *ci = [CIImage imageWithCVPixelBuffer:vcamBuffer];
        if (!vcamContext) vcamContext = [CIContext contextWithOptions:nil];
        CGImageRef cg = [vcamContext createCGImage:ci fromRect:ci.extent];
        NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
        CGImageRelease(cg);
        return d;
    }
    return %orig;
}
%end

// --- ПРОКСИ-ДЕЛЕГАТ (ДЛЯ ВИДЕО И МЕТАДАННЫХ) ---
@interface VCamDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate, AVCaptureMetadataOutputObjectsDelegate>
@property (nonatomic, strong) id target;
@end

@implementation VCamDelegateProxy
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    vcam_sync();
    if (vcamEnabled && vcamBuffer) {
        CMSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, vcamBuffer, &fd);
        CMSampleTimingInfo ti; CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        if (CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, vcamBuffer, YES, NULL, NULL, fd, &ti, &nb) == 0 && nb) {
            if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}

- (void)captureOutput:(id)o didOutputMetadataObjects:(id)m fromConnection:(id)c {
    // Блокируем QR-сканеры
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:o didOutputMetadataObjects:@[] fromConnection:c];
}

- (BOOL)respondsToSelector:(SEL)s { return [super respondsToSelector:s] || [self.target respondsToSelector:s]; }
- (id)forwardingTargetForSelector:(SEL)s { return self.target; }
@end

// --- ХУКИ НА ВЫВОД ДАННЫХ ---
%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (vcamEnabled && d && ![d isKindOfClass:[VCamDelegateProxy class]]) {
        VCamDelegateProxy *p = [[VCamDelegateProxy alloc] init]; p.target = d;
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

%hook AVCaptureMetadataOutput
- (void)setMetadataObjectsDelegate:(id)d queue:(id)q {
    if (vcamEnabled && d && ![d isKindOfClass:[VCamDelegateProxy class]]) {
        VCamDelegateProxy *p = [[VCamDelegateProxy alloc] init]; p.target = d;
        objc_setAssociatedObject(self, _cmd, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(p, q);
    } else %orig;
}
%end

// --- ХУК НА ПРЕДПРОСМОТР ---
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
    }
    
    AVPlayerLayer *l = objc_getAssociatedObject(self, "_v_l");
    if (!l && vcamPlayer) {
        l = [AVPlayerLayer playerLayerWithPlayer:vcamPlayer];
        l.videoGravity = AVLayerVideoGravityResizeAspectFill;
        l.zPosition = 9999;
        [self addSublayer:l];
        objc_setAssociatedObject(self, "_v_l", l, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [NSTimer scheduledTimerWithTimeInterval:0.033 repeats:YES block:^(NSTimer *t) { vcam_sync(); }];
    }
    if (l) l.frame = self.bounds;
}
%end

%ctor {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        // Загружаем только в приложения, чтобы не вешать SpringBoard
        if (bid && ![bid hasPrefix:@"com.apple.springboard"] && ![bid hasPrefix:@"com.apple.backboard"]) {
            %init;
        }
    }
}
