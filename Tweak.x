// VirtualCamPro V242.0: The Ultimate Display & KYC Fix
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static WKWebView *globalVcamView = nil;
static UIImage *globalLastSnapshot = nil;

static void load_prefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (prefs) {
        enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
        NSString *u = prefs[@"rtspURL"];
        if (u && u.length > 5) streamURL = u;
    }
}

// Global Bypass for local networking and HTTP
%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"NSAppTransportSecurity"]) {
        return @{ @"NSAllowsArbitraryLoads": @YES, @"NSAllowsLocalNetworking": @YES };
    }
    return %orig;
}
%end

static void inject_vcam(UIView *parent) {
    if (!parent || !enabled) return;
    
    if (globalVcamView && globalVcamView.superview == parent) {
        [parent sendSubviewToBack:globalVcamView];
        return;
    }
    
    if (globalVcamView) [globalVcamView removeFromSuperview];

    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;

    // Improved JS: Force play and hide all UI elements including MediaMTX specific ones
    NSString *js = @"(function() { " 
                    "  let s = document.createElement('style'); " 
                    "  s.innerHTML = 'body, html { background: black !important; margin: 0; padding: 0; overflow: hidden; width: 100vw; height: 100vh; } " 
                    "                 video, img { width: 100vw !important; height: 100vh !important; object-fit: cover !important; position: absolute; top:0; left:0; pointer-events: none !important; } " 
                    "                 .vjs-control-bar, .vjs-big-play-button, .live-badge, .player-controls, .controls, #ui { display: none !important; }'; " 
                    "  document.head.appendChild(s); " 
                    "  setInterval(() => { " 
                    "    let v = document.querySelector('video'); " 
                    "    if(v) { v.muted = true; v.playsInline = true; v.controls = false; if(v.paused) v.play().catch(e=>{}); } " 
                    "  }, 500); " 
                    "})();";

    WKUserScript *script = [[WKUserScript alloc] initWithSource:js injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES];
    [config.userContentController addUserScript:script];

    globalVcamView = [[WKWebView alloc] initWithFrame:parent.bounds configuration:config];
    globalVcamView.backgroundColor = [UIColor blackColor];
    globalVcamView.scrollView.backgroundColor = [UIColor blackColor];
    globalVcamView.opaque = YES;
    globalVcamView.userInteractionEnabled = NO;
    globalVcamView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:streamURL] cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15.0];
    [globalVcamView loadRequest:req];

    [parent insertSubview:globalVcamView atIndex:0];
    
    // Snapshot loop for gallery
    [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *t) {
        if (globalVcamView) {
            [globalVcamView takeSnapshotWithConfiguration:nil completionHandler:^(UIImage *img, NSError *err) {
                if (img) globalLastSnapshot = img;
            }];
        }
    }];
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        self.opacity = 0.0;
        UIView *target = (UIView *)self.delegate;
        if ([target isKindOfClass:[UIView class]]) {
            inject_vcam(target);
            globalVcamView.frame = target.bounds;
        }
    }
}
%end

// Anti-KYC Device Identity
%hook AVCaptureDevice
- (NSString *)uniqueID { return @"com.apple.avfoundation.avcapturedevice.built-in_video:back"; }
- (NSString *)localizedName { return @"Back Camera"; }
- (BOOL)isVirtualDevice { return NO; }
%end

// Hijack photo capture
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && globalLastSnapshot) return UIImageJPEGRepresentation(globalLastSnapshot, 0.9);
    return %orig;
}
%end

// Hijack gallery thumbnail
%hook CAMImageWell
- (void)setThumbnailImage:(UIImage *)image {
    if (enabled && globalLastSnapshot) %orig(globalLastSnapshot);
    else %orig(image);
}
%end

// Hijack Photos Database for Recent Thumbnails
%hook PHImageManager
- (PHImageRequestID)requestImageForAsset:(PHAsset *)asset targetSize:(CGSize)size contentMode:(PHImageContentMode)mode options:(PHImageRequestOptions *)options resultHandler:(void (^)(UIImage *result, NSDictionary *info))handler {
    if (enabled && globalLastSnapshot && asset.mediaType == PHAssetMediaTypeImage) {
        NSTimeInterval diff = [[NSDate date] timeIntervalSinceDate:asset.creationDate];
        if (diff < 30.0) {
            handler(globalLastSnapshot, nil);
            return 0;
        }
    }
    return %orig;
}
%end

%ctor {
    load_prefs();
}
