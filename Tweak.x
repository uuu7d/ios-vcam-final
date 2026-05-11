// VCAM V109.0: The Final KYC Override - Pure MJPEG Engine & Deep Photo Hook
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *rtspURL = @"http://192.168.1.44:8889/live/stream";
static AVPlayer *vPlayer = nil;
static AVPlayerLayer *vLayer = nil;
static AVPlayerItemVideoOutput *vOutput = nil;
static UIImage *lastImg = nil;
static UILabel *vHUD = nil;
static UIWindow *vWindow = nil;

void vcam_final_log(NSString *msg) {
    NSString *p = @"/var/mobile/Documents/vcam_FINAL.log";
    NSString *f = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:p];
    if (h) { [h seekToEndOfFile]; [h writeData:[f dataUsingEncoding:NSUTF8StringEncoding]]; [h closeFile]; }
    else { [f writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
}

void update_vcam_hud(NSString *txt, UIColor *clr) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vHUD) { vHUD.text = [NSString stringWithFormat:@"VCAM OVERRIDE: %@", txt]; vHUD.textColor = clr; }
    });
}

@interface VCamFrameManager : NSObject + (void)tick; @end
@implementation VCamFrameManager
+ (void)tick {
    if (!vOutput || !vPlayer.currentItem) return;
    CVPixelBufferRef pb = [vOutput copyPixelBufferForItemTime:[vPlayer.currentItem currentTime] itemTimeForDisplay:NULL];
    if (pb) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
        if (cg) { lastImg = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
        CVPixelBufferRelease(pb);
    }
}
@end

static void setup_engine(NSString *u) {
    if (vPlayer) { [vPlayer pause]; [vLayer removeFromSuperlayer]; vPlayer = nil; vLayer = nil; }
    NSURL *url = [NSURL URLWithString:u];
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    vOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    [item addOutput:vOutput];
    vPlayer = [AVPlayer playerWithPlayerItem:item];
    vPlayer.automaticallyWaitsToMinimizeStalling = NO;
    vLayer = [AVPlayerLayer playerLayerWithPlayer:vPlayer];
    vLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [vPlayer play];
    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:[VCamFrameManager class] selector:@selector(tick)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    update_vcam_hud(@"CONNECTING MJPEG...", [UIColor yellowColor]);
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;
    if (!vPlayer) setup_engine(rtspURL);
    if (vLayer.superlayer != self) [self addSublayer:vLayer];
    vLayer.frame = self.bounds; vLayer.zPosition = 999999;
    AVCaptureSession *s = self.session; BOOL f = NO;
    for (AVCaptureInput *i in s.inputs) { if ([i isKindOfClass:[AVCaptureDeviceInput class]] && ((AVCaptureDeviceInput *)i).device.position == AVCaptureDevicePositionFront) { f = YES; break; } }
    vLayer.transform = f ? CATransform3DMakeAffineTransform(CGAffineTransformMakeScale(-1, 1)) : CATransform3DIdentity;
    if (vPlayer.status == AVPlayerStatusReadyToPlay) update_vcam_hud(f ? @"MJPEG ACTIVE (FRONT)" : @"MJPEG ACTIVE", [UIColor greenColor]);
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)s delegate:(id)d {
    if (enabled && lastImg) objc_setAssociatedObject(s, "vcamS", lastImg, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    UIImage *snap = objc_getAssociatedObject(self.resolvedSettings, "vcamS");
    if (snap) { vcam_final_log(@"Deep Photo Hijack: Triggered"); return UIImageJPEGRepresentation(snap, 0.95); }
    return %orig;
}
- (CGImageRef)CGImageRepresentation { UIImage *snap = objc_getAssociatedObject(self.resolvedSettings, "vcamS"); if (snap) return snap.CGImage; return %orig; }
%end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (vWindow) return;
        vWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 80)];
        vWindow.windowLevel = UIWindowLevelAlert + 500;
        vWindow.userInteractionEnabled = NO; vWindow.hidden = NO;
        vHUD = [[UILabel alloc] initWithFrame:CGRectMake(10, 35, [UIScreen mainScreen].bounds.size.width - 20, 30)];
        vHUD.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
        vHUD.textColor = [UIColor whiteColor]; vHUD.font = [UIFont boldSystemFontOfSize:9];
        vHUD.textAlignment = NSTextAlignmentCenter; vHUD.layer.cornerRadius = 6; vHUD.clipsToBounds = YES;
        [vWindow addSubview:vHUD];
    });
}
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) { enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES; if (p[@"rtspURL"]) rtspURL = p[@"rtspURL"]; }
    vcam_final_log(@"VCAM V109.0 FINAL BOOT");
}
