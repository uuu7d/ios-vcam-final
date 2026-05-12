// VirtualCamPro V210.0: The Ultimate KYC Stealth Master
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live.mjpg";
static WKWebView *vcamView = nil;
static UIImage *lastSnapshot = nil;
static UILabel *statusLabel = nil;

// --- Anti-Detection & Hardware Spoofing ---

%hook AVCaptureDevice
- (NSString *)uniqueID {
    return @"com.apple.avfoundation.avcapturedevice.built-in_video:back";
}
- (NSString *)localizedName {
    return @"Back Camera";
}
- (AVCaptureDeviceType)deviceType {
    return AVCaptureDeviceTypeBuiltInWideAngleCamera;
}
%end

// --- Global ATS & Network Fix ---

%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"NSAppTransportSecurity"]) {
        return @{ @"NSAllowsArbitraryLoads": @YES, @"NSAllowsArbitraryLoadsInWebContent": @YES };
    }
    return %orig;
}
%end

// --- Video Hijack (Preview & KYC) ---

%hook AVCaptureConnection
- (BOOL)isEnabled {
    if (enabled && [self.output isKindOfClass:NSClassFromString(@"AVCaptureVideoPreviewLayer")]) {
        return NO; // Disable real preview
    }
    return %orig;
}
%end

static void setup_vcam_ultimate(UIView *parent) {
    if (!parent || !enabled) return;
    
    if (vcamView && vcamView.superview == parent) {
        [parent bringSubviewToFront:vcamView];
        return;
    }

    if (vcamView) [vcamView removeFromSuperview];

    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    config.allowsInlineMediaPlayback = YES;
    config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    
    vcamView = [[WKWebView alloc] initWithFrame:parent.bounds configuration:config];
    vcamView.backgroundColor = [UIColor blackColor];
    vcamView.opaque = YES;
    vcamView.userInteractionEnabled = NO;
    vcamView.scrollView.scrollEnabled = NO;

    // Clean MJPEG Stream with Auto-Recovery
    NSString *html = [NSString stringWithFormat:
        @"<html><head><style>"
        "body{margin:0;padding:0;background:black;overflow:hidden;}"
        "img{width:100%%;height:100%%;object-fit:cover;position:fixed;top:0;left:0;}"
        "</style></head><body>"
        "<img id='stream' src='%@' onerror='setTimeout(function(){location.reload();}, 1000);'>"
        "<script>setInterval(function(){ document.querySelectorAll('*').forEach(el => { if(el.tagName != 'IMG' && el.tagName != 'BODY' && el.tagName != 'HTML') el.remove(); }); }, 100);</script>"
        "</body></html>", streamURL];
    
    [vcamView loadHTMLString:html baseURL:nil];
    [parent addSubview:vcamView];
    [parent bringSubviewToFront:vcamView];

    if (!statusLabel) {
        statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 50, 200, 20)];
        statusLabel.textColor = [UIColor greenColor];
        statusLabel.font = [UIFont boldSystemFontOfSize:10];
        statusLabel.text = @"\u25CF VCAM STEALTH ACTIVE";
    }
    [parent addSubview:statusLabel];
    [parent bringSubviewToFront:statusLabel];

    // Continuous Snapshot for Photo/Gallery Hijack
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) {
            if (vcamView) {
                [vcamView takeSnapshotWithConfiguration:nil completionHandler:^(UIImage *img, NSError *err) {
                    if (img) lastSnapshot = img;
                }];
            }
        }];
    });
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *target = nil;
        if ([self.delegate isKindOfClass:[UIView class]]) target = (UIView *)self.delegate;
        else if ([self.superlayer.delegate isKindOfClass:[UIView class]]) target = (UIView *)self.superlayer.delegate;

        if (target) {
            setup_vcam_ultimate(target);
            vcamView.frame = target.bounds;
        }
    }
}
%end

// --- Photo Hijack ---

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && lastSnapshot) return UIImageJPEGRepresentation(lastSnapshot, 1.0);
    return %orig;
}
- (struct CGImage *)CGImageRepresentation {
    if (enabled && lastSnapshot) return lastSnapshot.CGImage;
    return %orig;
}
%end

// --- Gallery & Thumbnail Hijack ---

%hook PHImageManager
- (PHImageRequestID)requestImageForAsset:(PHAsset *)asset targetSize:(CGSize)targetSize contentMode:(PHImageContentMode)contentMode options:(PHImageRequestOptions *)options resultHandler:(void (^)(UIImage *result, NSDictionary *info))resultHandler {
    // Only hijack very recent photos (within 60s) to avoid breaking old gallery
    if (enabled && lastSnapshot && [[NSDate date] timeIntervalSinceDate:asset.creationDate] < 60) {
        if (resultHandler) {
            resultHandler(lastSnapshot, nil);
            return (PHImageRequestID)1;
        }
    }
    return %orig;
}
%end

// --- Camera Interface (Small Preview Icon) ---

%hook CAMImageWell
- (void)setThumbnailImage:(UIImage *)image {
    if (enabled && lastSnapshot) {
        %orig(lastSnapshot);
    } else {
        %orig;
    }
}
%end

%ctor {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:@"com.murkaska.virtualcampro"];
    enabled = [defs objectForKey:@"enabled"] ? [defs boolForKey:@"enabled"] : YES;
    NSString *str = [defs stringForKey:@"rtspURL"];
    if (str && str.length > 5) streamURL = str;
    
    // Enable for all apps if enabled
    if (enabled) {
        NSLog(@"[VirtualCamPro] Stealth Engine Initialized");
    }
}