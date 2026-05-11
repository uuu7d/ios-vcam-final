// VCAM V132.0: The Stealth Master - Zero Leak & Deep Thumbnail Hijack
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static WKWebView *vcamWebView = nil;
static UIImage *lastGlobalSnap = nil;
static UIView *vcamBlackout = nil;

@interface VCamSnapshoter : NSObject @end
@implementation VCamSnapshoter
+ (void)syncSnap {
    if (!vcamWebView) return;
    WKSnapshotConfiguration *config = [[WKSnapshotConfiguration alloc] init];
    [vcamWebView takeSnapshotWithConfiguration:config completionHandler:^(UIImage *img, NSError *err) {
        if (img) lastGlobalSnap = img;
    }];
}
@end

static void setup_stealth_engine(UIView *parent) {
    if (!parent || (vcamWebView && vcamWebView.superview == parent)) return;
    if (vcamWebView) [vcamWebView removeFromSuperview];
    
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    
    vcamWebView = [[WKWebView alloc] initWithFrame:parent.bounds configuration:config];
    vcamWebView.backgroundColor = [UIColor blackColor];
    vcamWebView.opaque = YES;
    vcamWebView.userInteractionEnabled = NO;
    vcamWebView.scrollView.scrollEnabled = NO;
    
    // AGGRESSIVE UI WIPER: No pause, no buttons, no skip, just VIDEO
    NSString *js = @"var s = document.createElement('style'); "
                    "s.innerHTML = '* { background: black !important; color: transparent !important; cursor: none !important; } "
                    "video { position: fixed !important; top: 0 !important; left: 0 !important; width: 100vw !important; height: 100vh !important; object-fit: cover !important; z-index: 2147483647 !important; } "
                    "div, button, .controls, .video-controls, .overlay, .play-button, .skip-button, .timer, span, a, img { display: none !important; opacity: 0 !important; }'; "
                    "document.head.appendChild(s); "
                    "setInterval(function() { var v = document.querySelector('video'); if(v) { v.play(); v.controls = false; v.style.display='block'; } }, 30);";
    
    WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [vcamWebView.configuration.userContentController addUserScript:script];
    
    if (!vcamBlackout) {
        vcamBlackout = [[UIView alloc] initWithFrame:parent.bounds];
        vcamBlackout.backgroundColor = [UIColor blackColor];
        vcamBlackout.userInteractionEnabled = NO;
    }
    
    [parent insertSubview:vcamBlackout atIndex:0];
    [parent insertSubview:vcamWebView atIndex:1];
    [vcamWebView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:streamURL]]];
    
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { [VCamSnapshoter syncSnap]; }];
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *p = (UIView *)self.delegate;
        if (!p || ![p isKindOfClass:[UIView class]]) p = (UIView *)self.superlayer.delegate;
        if (p && [p isKindOfClass:[UIView class]]) {
            setup_stealth_engine(p);
            vcamWebView.frame = p.bounds;
            vcamBlackout.frame = p.bounds;
            
            AVCaptureSession *s = self.session; BOOL f = NO;
            if (s) {
                for (id i in s.inputs) { if ([i isKindOfClass:[AVCaptureDeviceInput class]] && ((AVCaptureDeviceInput *)i).device.position == 2) { f = YES; break; } }
            }
            vcamWebView.transform = f ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;
            
            // HIDE REAL LENS FOREVER
            [self setOpacity:0.0];
            [self setHidden:YES];
        }
    }
}
%end

// DEEP HIJACK 6.0: Hijacking EVERY possible output path for photos and thumbnails
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && lastGlobalSnap) return UIImageJPEGRepresentation(lastGlobalSnap, 0.95);
    return %orig;
}

- (struct CGImage *)CGImageRepresentation {
    if (enabled && lastGlobalSnap) return lastGlobalSnap.CGImage;
    return %orig;
}

- (struct CGImage *)previewCGImageRepresentation {
    if (enabled && lastGlobalSnap) return lastGlobalSnap.CGImage;
    return %orig;
}

- (struct __CVBuffer *)pixelBuffer {
    return %orig; // Used for RAW/Live, keeping original for stability
}

- (struct __CVBuffer *)previewPixelBuffer {
    return %orig;
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d { %orig; }
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) {
        enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) streamURL = [p[@"rtspURL"] stringByReplacingOccurrencesOfString:@"/index.m3u8" withString:@""];
    }
}
