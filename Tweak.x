// VCAM V129.0: The UI Integrator - Direct WebView Injection (Buttons & TG Fix)
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static WKWebView *vcamWebView = nil;
static UIImage *snapshotForPhoto = nil;

static void setup_integrated_web_engine(UIView *parent) {
    if (!parent) return;
    if (vcamWebView && vcamWebView.superview == parent) return;
    
    if (vcamWebView) [vcamWebView removeFromSuperview];
    
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    
    vcamWebView = [[WKWebView alloc] initWithFrame:parent.bounds configuration:config];
    vcamWebView.backgroundColor = [UIColor blackColor];
    vcamWebView.opaque = YES;
    vcamWebView.userInteractionEnabled = NO; // Touches go to buttons below/above
    vcamWebView.scrollView.scrollEnabled = NO;
    
    // Aggressive CSS to hide all player UI
    NSString *css = @"video { width: 100vw !important; height: 100vh !important; object-fit: cover !important; } "
                    "button, .controls, .overlay { display: none !important; }";
    WKUserScript *script = [[WKUserScript alloc] initWithSource:[NSString stringWithFormat:@"var style = document.createElement('style'); style.innerHTML = '%@'; document.head.appendChild(style);", css] injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [vcamWebView.configuration.userContentController addUserScript:script];
    
    [parent insertSubview:vcamWebView atIndex:0]; // Place BEHIND all camera controls
    [vcamWebView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:streamURL]]];
    
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        [vcamWebView takeSnapshotWithConfiguration:nil completionHandler:^(UIImage *img, NSError *err) {
            if (img) snapshotForPhoto = img;
        }];
    }];
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *parent = nil;
        if ([self.delegate isKindOfClass:[UIView class]]) parent = (UIView *)self.delegate;
        else if (self.superlayer.delegate && [self.superlayer.delegate isKindOfClass:[UIView class]]) parent = (UIView *)self.superlayer.delegate;
        
        if (parent) {
            setup_integrated_web_engine(parent);
            vcamWebView.frame = parent.bounds;
            
            // Mirroring logic
            AVCaptureSession *s = self.session; BOOL f = NO;
            if (s) {
                for (id i in s.inputs) {
                    if ([i isKindOfClass:objc_getClass("AVCaptureDeviceInput")] && ((AVCaptureDeviceInput *)i).device.position == 2) { f = YES; break; }
                }
            }
            vcamWebView.transform = f ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;
            [self setOpacity:0.0]; // Hide real lens but keep buttons visible
        }
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
    UIImage *snap = objc_getAssociatedObject([self resolvedSettings], "vcamS");
    if (snap) return UIImageJPEGRepresentation(snap, 0.95);
    return %orig;
}
- (struct CGImage *)CGImageRepresentation { UIImage *snap = objc_getAssociatedObject([self resolvedSettings], "vcamS"); if (snap) return snap.CGImage; return %orig; }
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) {
        enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) streamURL = [p[@"rtspURL"] stringByReplacingOccurrencesOfString:@"/index.m3u8" withString:@""];
    }
}
