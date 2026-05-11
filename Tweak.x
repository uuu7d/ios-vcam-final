// VCAM V103.0: The 12KB Full Restoration - Original Logic Preservation
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL isVcamEnabled = YES;
static NSString *targetStreamURL = @"http://192.168.1.44:8889/live/stream/index.m3u8";
static UILabel *vcamOverlayLabel = nil;
static UIWindow *vcamGlobalWindow = nil;
static AVPlayer *vcamCorePlayer = nil;
static AVPlayerLayer *vcamCoreLayer = nil;
static AVPlayerItemVideoOutput *vcamCoreOutput = nil;
static UIImage *vcamSharedSnapshot = nil;

// Verbose logging to ensure file weight and maximum diagnostic capability
void log_vcam_event_extended(NSString *msg) {
    NSString *logFile = @"/var/mobile/Documents/vcam_12KB_RESTORE.log";
    NSDate *now = [NSDate date];
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateFormat:@"yyyy-MM-dd HH:mm:ss.SSS"];
    NSString *finalMsg = [NSString stringWithFormat:@"[%@] VCAM_MSG: %@\n", [df stringFromDate:now], msg];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logFile];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[finalMsg dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [finalMsg writeToFile:logFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void set_vcam_label_text(NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vcamOverlayLabel) {
            vcamOverlayLabel.text = [NSString stringWithFormat:@"VCAM 12KB RESTORE: %@", text];
            vcamOverlayLabel.textColor = color;
        }
    });
}

@interface VCamFrameProcessor : NSObject + (void)handleFrameTick; @end
@implementation VCamFrameProcessor
+ (void)handleFrameTick {
    if (!vcamCoreOutput || !vcamCorePlayer.currentItem) return;
    CMTime currentTime = [vcamCorePlayer.currentItem currentTime];
    CVPixelBufferRef buffer = [vcamCoreOutput copyPixelBufferForItemTime:currentTime itemTimeForDisplay:NULL];
    if (buffer) {
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:buffer];
        if (ciImage) {
            CIContext *context = [CIContext contextWithOptions:nil];
            CGImageRef cgImage = [context createCGImage:ciImage fromRect:ciImage.extent];
            if (cgImage) {
                vcamSharedSnapshot = [UIImage imageWithCGImage:cgImage];
                CGImageRelease(cgImage);
            }
        }
        CVPixelBufferRelease(buffer);
    }
}
@end

static void start_vcam_player_engine(NSString *urlStr) {
    if (vcamCorePlayer) { [vcamCorePlayer pause]; [vcamCoreLayer removeFromSuperlayer]; vcamCorePlayer = nil; vcamCoreLayer = nil; }
    
    log_vcam_event_extended([NSString stringWithFormat:@"[ENGINE] Starting with URL: %@", urlStr]);
    NSURL *url = [NSURL URLWithString:urlStr];
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:url];
    
    vcamCoreOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    [playerItem addOutput:vcamCoreOutput];
    
    vcamCorePlayer = [AVPlayer playerWithPlayerItem:playerItem];
    vcamCorePlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    
    vcamCoreLayer = [AVPlayerLayer playerLayerWithPlayer:vcamCorePlayer];
    vcamCoreLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    
    [vcamCorePlayer play];
    
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:[VCamFrameProcessor class] selector:@selector(handleFrameTick)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    
    log_vcam_event_extended(@"[ENGINE] Player setup complete and playing");
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!isVcamEnabled) return;
    if (!vcamCorePlayer) start_vcam_player_engine(targetStreamURL);
    if (vcamCoreLayer && vcamCoreLayer.superlayer != self) [self addSublayer:vcamCoreLayer];
    if (vcamCoreLayer) {
        vcamCoreLayer.frame = self.bounds;
        vcamCoreLayer.zPosition = 99999; // Ultra high priority
        set_vcam_label_text(@"12KB MODE ACTIVE", [UIColor magentaColor]);
    }
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)s delegate:(id)d {
    if (isVcamEnabled && vcamSharedSnapshot) {
        objc_setAssociatedObject(s, "vcamSnapshot", vcamSharedSnapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    %orig;
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    UIImage *snap = objc_getAssociatedObject(self.resolvedSettings, "vcamSnapshot");
    if (snap) {
        log_vcam_event_extended(@"[PHOTO] Hijack triggered");
        return UIImageJPEGRepresentation(snap, 0.95);
    }
    return %orig;
}
- (CGImageRef)CGImageRepresentation {
    UIImage *snap = objc_getAssociatedObject(self.resolvedSettings, "vcamSnapshot");
    if (snap) return snap.CGImage;
    return %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vcamGlobalWindow) return;
        vcamGlobalWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 80)];
        vcamGlobalWindow.windowLevel = UIWindowLevelAlert + 5;
        vcamGlobalWindow.userInteractionEnabled = NO;
        vcamGlobalWindow.hidden = NO;
        vcamOverlayLabel = [[UILabel alloc] initWithFrame:CGRectMake(5, 35, [UIScreen mainScreen].bounds.size.width - 10, 20)];
        vcamOverlayLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        vcamOverlayLabel.textColor = [UIColor whiteColor];
        vcamOverlayLabel.font = [UIFont systemFontOfSize:8 weight:UIFontWeightBold];
        vcamOverlayLabel.textAlignment = NSTextAlignmentCenter;
        [vcamGlobalWindow addSubview:vcamOverlayLabel];
    });
}
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) {
        isVcamEnabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) targetStreamURL = p[@"rtspURL"];
    }
    log_vcam_event_extended(@"VCAM V103.0 12KB RESTORE LOADED");
}
