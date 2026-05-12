// VCAM V205.2: Perfect Global Injection
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <Photos/Photos.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static WKWebView *vcamWebView = nil;
static UIImage *lastSnapshot = nil;
static UILabel *statusLabel = nil;

static void setup_vcam_v205(UIView *parent) {
    if (!parent || (vcamWebView && vcamWebView.superview == parent)) return;
    if (vcamWebView) [vcamWebView removeFromSuperview];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    
    vcamWebView = [[WKWebView alloc] initWithFrame:parent.bounds configuration:config];
    vcamWebView.backgroundColor = [UIColor blackColor];
    vcamWebView.userInteractionEnabled = NO;
    vcamWebView.scrollView.scrollEnabled = NO;
    vcamWebView.opaque = YES;

    [vcamWebView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:streamURL]]];

    NSString *js = @"var s = document.createElement('style'); s.innerHTML = '* {color:transparent!important;background:black!important;} video {position:fixed;top:0;left:0;width:100vw;height:100vh;object-fit:cover!important;z-index:99999!important;}'; document.head.appendChild(s); setInterval(function(){var v = document.querySelector('video'); if(v) v.play();}, 100);";
    WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [vcamWebView.configuration.userContentController addUserScript:script];

    [parent insertSubview:vcamWebView atIndex:0];

    if (!statusLabel) {
        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, 200, 20)];
        statusLabel.text = @"VCAM ACTIVE V205";
        statusLabel.textColor = [UIColor greenColor];
        statusLabel.font = [UIFont boldSystemFontOfSize:10];
    }
    [parent addSubview:statusLabel];

    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
        [vcamWebView takeSnapshotWithConfiguration:nil completionHandler:^(UIImage *img, NSError *err) {
            if (img) lastSnapshot = img;
        }];
    }];
}

%hook AVCaptureVideoPreviewLayer
- (void)setContents:(id)contents {
    if (enabled) %orig(nil);
    else %orig;
}
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *parentView = nil;
        if ([self.delegate isKindOfClass:[UIView class]]) parentView = (UIView *)self.delegate;
        else if ([self.superlayer.delegate isKindOfClass:[UIView class]]) parentView = (UIView *)self.superlayer.delegate;

        if (parentView) {
            setup_vcam_v205(parentView);
            vcamWebView.frame = parentView.bounds;
        }
    }
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && lastSnapshot) return UIImageJPEGRepresentation(lastSnapshot, 0.9);
    return %orig;
}
- (struct CGImage *)CGImageRepresentation {
    if (enabled && lastSnapshot) return lastSnapshot.CGImage;
    return %orig;
}
%end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)delegate queue:(dispatch_queue_t)queue {
    %orig;
}
%end

%hook PHImageManager
- (int)requestImageForAsset:(PHAsset *)asset targetSize:(CGSize)targetSize contentMode:(int)contentMode options:(id)options resultHandler:(void (^)(UIImage *result, NSDictionary *info))resultHandler {
    if (enabled && lastSnapshot && [[NSDate date] timeIntervalSinceDate:asset.creationDate] < 60) {
        resultHandler(lastSnapshot, nil);
        return 1;
    }
    return %orig;
}
%end

%ctor {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:@"com.murkaska.virtualcampro"];
    enabled = [defs objectForKey:@"enabled"] ? [defs boolForKey:@"enabled"] : YES;
    NSString *str = [defs stringForKey:@"rtspURL"];
    if (str && str.length > 5) streamURL = str;
}
