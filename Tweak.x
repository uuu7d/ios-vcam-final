// VCAM V96.0: Stable Restoration & Photo Hijack Fix
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *rtspURL = @"http://192.168.1.44:8889/live/stream/index.m3u8";
static UILabel *statusLabel = nil;
static UIWindow *overlayWindow = nil;
static AVPlayer *vcamPlayer = nil;
static AVPlayerLayer *vcamLayer = nil;
static AVPlayerItemVideoOutput *vcamVideoOutput = nil;
static UIImage *lastValidUIImage = nil;

void vcam_log(NSString *message) {
    NSString *logPath = @"/var/mobile/Documents/vcam_DEBUG.log";
    NSString *formatted = [NSString stringWithFormat:@"%@\n", message];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fh) { [fh seekToEndOfFile]; [fh writeData:[formatted dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    else { [formatted writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
}

void update_vcam_status(NSString *status, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (statusLabel) { statusLabel.text = [NSString stringWithFormat:@"VCAM: %@", status]; statusLabel.textColor = color; }
    });
    vcam_log(status);
}

void setup_status_bar(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (overlayWindow) return;
        overlayWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 100)];
        overlayWindow.windowLevel = UIWindowLevelAlert + 2;
        overlayWindow.userInteractionEnabled = NO;
        overlayWindow.backgroundColor = [UIColor clearColor];
        overlayWindow.hidden = NO;
        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 40, [UIScreen mainScreen].bounds.size.width - 20, 25)];
        statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
        statusLabel.textColor = [UIColor whiteColor];
        statusLabel.font = [UIFont boldSystemFontOfSize:11];
        statusLabel.layer.cornerRadius = 6;
        statusLabel.clipsToBounds = YES;
        statusLabel.textAlignment = NSTextAlignmentCenter;
        [overlayWindow addSubview:statusLabel];
    });
}

static CADisplayLink *frameGrabLink = nil;
@interface VCamFrameGrabber : NSObject + (void)tick:(CADisplayLink *)link; @end
@implementation VCamFrameGrabber
+ (void)tick:(CADisplayLink *)link {
    if (!vcamVideoOutput || !vcamPlayer.currentItem) return;
    CMTime itemTime = [vcamPlayer.currentItem currentTime];
    if (![vcamVideoOutput hasNewPixelBufferForItemTime:itemTime]) return;
    CVPixelBufferRef pb = [vcamVideoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
    if (pb) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
        if (ci) {
            CIContext *ctx = [CIContext contextWithOptions:nil];
            CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
            if (cg) { lastValidUIImage = [UIImage imageWithCGImage:cg]; CGImageRelease(cg); }
        }
        CVPixelBufferRelease(pb);
    }
}
@end

static void setup_player(NSString *u) {
    if (vcamPlayer) { [vcamPlayer pause]; [vcamLayer removeFromSuperlayer]; vcamPlayer = nil; vcamLayer = nil; }
    NSURL *url = [NSURL URLWithString:u];
    update_vcam_status([NSString stringWithFormat:@"STABLE CONN [%@]...", url.host], [UIColor yellowColor]);
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:url];
    vcamVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    [item addOutput:vcamVideoOutput];
    vcamPlayer = [AVPlayer playerWithPlayerItem:item];
    vcamLayer = [AVPlayerLayer playerLayerWithPlayer:vcamPlayer];
    vcamLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [vcamPlayer play];
    if (!frameGrabLink) { frameGrabLink = [CADisplayLink displayLinkWithTarget:[VCamFrameGrabber class] selector:@selector(tick:)]; [frameGrabLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes]; }
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;
    if (!vcamPlayer) setup_player(rtspURL);
    if (vcamLayer && vcamLayer.superlayer != self) [self addSublayer:vcamLayer];
    if (vcamLayer) {
        vcamLayer.frame = self.bounds; vcamLayer.zPosition = 9999;
        AVCaptureSession *s = self.session; BOOL f = NO;
        for (AVCaptureInput *i in s.inputs) { if ([i isKindOfClass:[AVCaptureDeviceInput class]] && ((AVCaptureDeviceInput *)i).device.position == AVCaptureDevicePositionFront) { f = YES; break; } }
        vcamLayer.transform = f ? CATransform3DMakeAffineTransform(CGAffineTransformMakeScale(-1, 1)) : CATransform3DIdentity;
        BOOL ready = vcamPlayer.status == AVPlayerStatusReadyToPlay && vcamPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay;
        if (!ready) { vcamLayer.backgroundColor = [UIColor blackColor].CGColor; update_vcam_status(@"CONNECTING...", [UIColor yellowColor]); }
        else { vcamLayer.backgroundColor = [UIColor clearColor].CGColor; update_vcam_status(f ? @"STREAMING (FRONT)" : @"STREAMING ACTIVE", [UIColor greenColor]); }
    }
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)s delegate:(id)d {
    if (enabled && lastValidUIImage) { objc_setAssociatedObject(s, "vcamSnapshot", lastValidUIImage, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    %orig;
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    UIImage *snap = objc_getAssociatedObject(self.resolvedSettings, "vcamSnapshot");
    if (snap) return UIImageJPEGRepresentation(snap, 0.9);
    return %orig;
}
- (CGImageRef)CGImageRepresentation { UIImage *snap = objc_getAssociatedObject(self.resolvedSettings, "vcamSnapshot"); if (snap) return snap.CGImage; return %orig; }
%end

%hook AVCaptureSession
- (void)startRunning { %orig; setup_status_bar(); }
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) { enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES; if (p[@"rtspURL"]) rtspURL = p[@"rtspURL"]; }
    vcam_log(@"VCAM V96.0 Restoration Loaded");
}
