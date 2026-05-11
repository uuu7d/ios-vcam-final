// VCAM V138.0: The Direct Injector - <img> based MJPEG & Deep Photo Hijack
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static WKWebView *vcamWebView = nil;
static UIImage *snapshotForPhoto = nil;

static void setup_direct_injector(UIView *parent) {
    if (!parent || (vcamWebView && vcamWebView.superview == parent)) return;
    if (vcamWebView) [vcamWebView removeFromSuperview];
    
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    
    vcamWebView = [[WKWebView alloc] initWithFrame:parent.bounds configuration:config];
    vcamWebView.backgroundColor = [UIColor blackColor];
    vcamWebView.opaque = YES;
    vcamWebView.userInteractionEnabled = NO;
    vcamWebView.scrollView.scrollEnabled = NO;
    
    // Using <img> tag to bypass MediaMTX JS player errors and hide all UI
    NSString *html = [NSString stringWithFormat:@"<html><body style='margin:0;padding:0;background:black;overflow:hidden;'><img src='%@' style='width:100vw;height:100vh;object-fit:cover;'></body></html>", streamURL];
    [vcamWebView loadHTMLString:html baseURL:nil];
    
    // Place at the very bottom of the view hierarchy
    [parent insertSubview:vcamWebView atIndex:0];
    
    [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        [vcamWebView takeSnapshotWithConfiguration:nil completionHandler:^(UIImage *img, NSError *err) {
            if (img) snapshotForPhoto = img;
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
            setup_direct_injector(p);
            vcamWebView.frame = p.bounds;
            [p sendSubviewToBack:vcamWebView]; // Ensure native buttons stay on top
            
            AVCaptureSession *s = self.session; BOOL f = NO;
            if (s) {
                for (id i in s.inputs) { if ([i isKindOfClass:objc_getClass("AVCaptureDeviceInput")] && ((AVCaptureDeviceInput *)i).device.position == 2) { f = YES; break; } }
            }
            vcamWebView.transform = f ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;
            [self setOpacity:0.0];
        }
    }
}
%end

// ENHANCED PHOTO HIJACK: Catching all data paths
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && snapshotForPhoto) return UIImageJPEGRepresentation(snapshotForPhoto, 0.95);
    return %orig;
}
- (struct CGImage *)CGImageRepresentation { if (enabled && snapshotForPhoto) return snapshotForPhoto.CGImage; return %orig; }
- (struct CGImage *)previewCGImageRepresentation { if (enabled && snapshotForPhoto) return snapshotForPhoto.CGImage; return %orig; }
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) {
        enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) streamURL = [p[@"rtspURL"] stringByReplacingOccurrencesOfString:@"/index.m3u8" withString:@""];
    }
}
