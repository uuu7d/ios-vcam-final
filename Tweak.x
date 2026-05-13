// Tweak.x - VirtualCamPro V246.0
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import "MJPEGStreamReader.h"

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static MJPEGStreamReader *gReader = nil;
static UIImage *gLastFrame = nil;
static UILabel *gStatusLabel = nil;

static void load_prefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (prefs) {
        enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
        NSString *u = prefs[@"rtspURL"];
        if (u && [u length] > 5) streamURL = u;
    }
}

static void VCamInstallOverlay(UIView *host) {
    if (!host || !enabled) return;
    UIImageView *vcam = [host viewWithTag:9999];
    if (!vcam) {
        vcam = [[UIImageView alloc] initWithFrame:host.bounds];
        vcam.tag = 9999;
        vcam.contentMode = UIViewContentModeScaleAspectFill;
        vcam.backgroundColor = [UIColor blackColor];
        [host insertSubview:vcam atIndex:0];
        
        gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 40, 280, 20)];
        gStatusLabel.textColor = [UIColor greenColor];
        gStatusLabel.font = [UIFont boldSystemFontOfSize:12];
        gStatusLabel.text = @"● Connecting...";
        [host addSubview:gStatusLabel];
    }
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        self.opacity = 0.0;
        UIView *p = (UIView *)self.delegate;
        if ([p isKindOfClass:[UIView class]]) {
            VCamInstallOverlay(p);
            UIImageView *vcam = [p viewWithTag:9999];
            if (vcam) vcam.image = gLastFrame;
            if (gStatusLabel && gReader) {
                if (gReader.frameCount > 0) {
                    gStatusLabel.text = [NSString stringWithFormat:@"▶ Live | FPS: %lu", (unsigned long)gReader.frameCount];
                } else {
                    gStatusLabel.text = @"◌ Connecting...";
                }
            }
        }
    }
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && gLastFrame) return UIImageJPEGRepresentation(gLastFrame, 0.95);
    return %orig;
}
- (CGImageRef)CGImageRepresentation {
    if (enabled && gLastFrame) return gLastFrame.CGImage;
    return %orig;
}
%end

%hook CAMImageWell
- (void)setThumbnailImage:(UIImage *)image {
    if (enabled && gLastFrame) %orig(gLastFrame);
    else %orig(image);
}
%end

%ctor {
    load_prefs();
    if (enabled) {
        gReader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:streamURL]];
        gReader.frameCallback = ^(UIImage *frame) { gLastFrame = frame; };
        [gReader startStreaming];
    }
}
