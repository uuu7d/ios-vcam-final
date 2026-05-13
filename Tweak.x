// VirtualCamPro V228.0: The Direct Stream Master (Broken Link Fix)
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static WKWebView *globalVcamView = nil;
static UIImage *globalLastImage = nil;

// --- Direct Preference Loading ---
static void load_vcam_prefs() {
    NSArray *paths = @[@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist", 
                       @"/var/jb/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) {
            enabled = [d[@"enabled"] ?: @YES boolValue];
            NSString *u = d[@"rtspURL"];
            if (u && u.length > 5) streamURL = u;
            break;
        }
    }
}

// --- Global ATS Fix ---
%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"NSAppTransportSecurity"]) {
        return @{ @"NSAllowsArbitraryLoads": @YES, @"NSAllowsArbitraryLoadsInWebContent": @YES, @"NSAllowsLocalNetworking": @YES };
    }
    return %orig;
}
%end

// --- Snapshot Logic for Photo Hijack ---
static void start_frame_capture() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
            if (enabled && globalVcamView) {
                [globalVcamView takeSnapshotWithConfiguration:nil completionHandler:^(UIImage *img, NSError *err) {
                    if (img) globalLastImage = img;
                }];
            }
        }];
    });
}

// --- Direct Stream Injection (No HTML Wrapper) ---
static void inject_vcam_direct(UIView *parent) {
    if (!parent || !enabled) return;
    
    if (globalVcamView && globalVcamView.superview == parent) {
        [parent bringSubviewToFront:globalVcamView];
        return;
    }

    if (globalVcamView) [globalVcamView removeFromSuperview];

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.allowsInlineMediaPlayback = YES;
    
    globalVcamView = [[WKWebView alloc] initWithFrame:parent.bounds configuration:config];
    globalVcamView.backgroundColor = [UIColor blackColor];
    globalVcamView.scrollView.backgroundColor = [UIColor blackColor];
    globalVcamView.opaque = YES;
    globalVcamView.userInteractionEnabled = NO;
    globalVcamView.scrollView.scrollEnabled = NO;

    // Load the URL DIRECTLY like Chrome does. This avoids "Question Mark" placeholders.
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:streamURL]];
    [globalVcamView loadRequest:request];
    
    [parent insertSubview:globalVcamView atIndex:0];
    
    start_frame_capture();
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *target = nil;
        if ([self.delegate isKindOfClass:[UIView class]]) target = (UIView *)self.delegate;
        else if ([self.superlayer.delegate isKindOfClass:[UIView class]]) target = (UIView *)self.superlayer.delegate;

        if (target) {
            inject_vcam_direct(target);
            globalVcamView.frame = target.bounds;
        }
    }
}
%end

// --- Anti-KYC Spoofing ---
%hook AVCaptureDevice
- (NSString *)uniqueID { return @"com.apple.avfoundation.avcapturedevice.built-in_video:back"; }
- (NSString *)localizedName { return @"Back Camera"; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (BOOL)isVirtualDevice { return NO; }
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && globalLastImage) return UIImageJPEGRepresentation(globalLastImage, 0.95);
    return %orig;
}
%end

%hook CAMImageWell
- (void)setThumbnailImage:(UIImage *)image {
    if (enabled && globalLastImage) %orig(globalLastImage);
    else %orig;
}
%end

%ctor {
    load_vcam_prefs();
    NSLog(@"[VirtualCamPro] Direct Stream Master V228.0 Active");
}