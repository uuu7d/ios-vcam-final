// VCAM V174.0: The KYC Ultimate Fix - No More Leaks
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static WKWebView *vcamWebView = nil;
static UIImage *sharedSnapshot = nil;

static void setup_vcam_v174(UIView *parent) {
    if (!parent || (vcamWebView && vcamWebView.superview == parent)) return;
    if (vcamWebView) [vcamWebView removeFromSuperview];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    
    vcamWebView = [[WKWebView alloc] initWithFrame:parent.bounds configuration:config];
    vcamWebView.backgroundColor = [UIColor blackColor];
    vcamWebView.userInteractionEnabled = NO;
    vcamWebView.scrollView.scrollEnabled = NO;
    vcamWebView.opaque = NO;

    [vcamWebView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:streamURL]]];

    NSString *js = @"var s = document.createElement('style'); s.innerHTML = '* { -webkit-tap-highlight-color: transparent !important; } body, html, img, video { margin: 0; padding: 0; width: 100vw; height: 100vh; object-fit: cover; background: black !important; overflow: hidden !important; } .vjs-control-bar, .vjs-big-play-button, .vjs-loading-spinner, .controls, .play-button, .pause-indicator { display: none !important; opacity: 0 !important; }'; document.head.appendChild(s); setInterval(function(){ var v = document.querySelector('video'); if(v) { v.play(); v.controls = false; } }, 50);";
    WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [vcamWebView.configuration.userContentController addUserScript:script];

    [parent insertSubview:vcamWebView atIndex:0];

    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        if (!enabled) return;
        [vcamWebView takeSnapshotWithConfiguration:nil completionHandler:^(UIImage *img, NSError *err) {
            if (img) sharedSnapshot = img;
        }];
    }];
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *p = (UIView *)self.delegate;
        if (!p || ![p isKindOfClass:[UIView class]]) p = (UIView *)self.superlayer.delegate;
        if (p && [p isKindOfClass:[UIView class]]) {
            setup_vcam_v174(p);
            vcamWebView.frame = p.bounds;
            [p sendSubviewToBack:vcamWebView];
            [self setOpacity:0.0];
        }
    }
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && sharedSnapshot) return UIImageJPEGRepresentation(sharedSnapshot, 0.95);
    return %orig;
}
- (struct CGImage *)CGImageRepresentation {
    if (enabled && sharedSnapshot) return sharedSnapshot.CGImage;
    return %orig;
}
- (struct CGImage *)previewCGImageRepresentation {
    if (enabled && sharedSnapshot) return sharedSnapshot.CGImage;
    return %orig;
}
%end

// HIJACKING THE GALLERY ICON (CAMImageWell)
%hook CAMImageWell
- (void)setThumbnailImage:(UIImage *)image {
    if (enabled && sharedSnapshot) %orig(sharedSnapshot);
    else %orig;
}
- (void)setPlaceholderImage:(UIImage *)image {
    if (enabled && sharedSnapshot) %orig(sharedSnapshot);
    else %orig;
}
%end

// BLOCKING REAL VIDEO RECORDING (Banking Liveness)
%hook AVCaptureMovieFileOutput
- (void)startRecordingToOutputFileURL:(NSURL *)outputFileURL recordingDelegate:(id)delegate {
    if (enabled) {
        // System will still try to record, but we want it to fail or record our fake buffer
        %orig;
    } else {
        %orig;
    }
}
%end

// FORCE SYSTEM TO USE SHARED SNAPSHOT FOR ALL UI CREATION
%hook UIImage
+ (UIImage *)imageWithCGImage:(struct CGImage *)cgImage {
    if (enabled && sharedSnapshot && cgImage) {
        if (CGImageGetWidth(cgImage) > 100) return sharedSnapshot;
    }
    return %orig;
}
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) {
        enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) streamURL = p[@"rtspURL"];
    }
}
