// VCAM V119.0: The Web Master - WKWebView Stream Engine (Chrome Logic)
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static UIWindow *vcamWindow = nil;
static WKWebView *vcamWebView = nil;
static UIImage *snapshotForPhoto = nil;

@interface VCamSnapshoter : NSObject @end
@implementation VCamSnapshoter
+ (void)takeSnap {
    if (!vcamWebView) return;
    WKSnapshotConfiguration *config = [[WKSnapshotConfiguration alloc] init];
    [vcamWebView takeSnapshotWithConfiguration:config completionHandler:^(UIImage *img, NSError *err) {
        if (img) snapshotForPhoto = img;
    }];
}
@end

static void setup_web_engine(void) {
    if (vcamWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        vcamWindow = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        vcamWindow.windowLevel = UIWindowLevelAlert + 5000;
        vcamWindow.userInteractionEnabled = NO;
        vcamWindow.backgroundColor = [UIColor clearColor];
        vcamWindow.hidden = NO;
        
        WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
        config.allowsInlineMediaPlayback = YES;
        config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
        
        vcamWebView = [[WKWebView alloc] initWithFrame:vcamWindow.bounds configuration:config];
        vcamWebView.backgroundColor = [UIColor clearColor];
        vcamWebView.scrollView.scrollEnabled = NO;
        [vcamWindow addSubview:vcamWebView];
        
        [vcamWebView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:streamURL]]];
        
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            [VCamSnapshoter takeSnap];
        }];
    });
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        setup_web_engine();
        vcamWindow.hidden = NO;
        AVCaptureSession *s = self.session; BOOL f = NO;
        for (AVCaptureInput *i in s.inputs) { if ([i isKindOfClass:objc_getClass("AVCaptureDeviceInput")] && ((AVCaptureDeviceInput *)i).device.position == 2) { f = YES; break; } }
        vcamWebView.transform = f ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;
        self.opacity = 0.01;
    }
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (enabled && snapshotForPhoto) objc_setAssociatedObject(s, "vcamS", snapshotForPhoto, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    UIImage *snap = objc_getAssociatedObject(self.resolvedSettings, "vcamS");
    if (snap) return UIImageJPEGRepresentation(snap, 0.95);
    return %orig;
}
- (struct CGImage *)CGImageRepresentation { UIImage *snap = objc_getAssociatedObject(self.resolvedSettings, "vcamS"); if (snap) return snap.CGImage; return %orig; }
%end

%hook AVCaptureSession
- (void)stopRunning { %orig; if (vcamWindow) vcamWindow.hidden = YES; }
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) {
        enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) streamURL = [p[@"rtspURL"] stringByReplacingOccurrencesOfString:@"/index.m3u8" withString:@""];
    }
}
