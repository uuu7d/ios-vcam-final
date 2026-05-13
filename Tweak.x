// Tweak.x - VirtualCamPro V266.0: The Capture Hijack
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import "MJPEGStreamReader.h"

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static MJPEGStreamReader *gReader = nil;
static UIImage *gLastFrame = nil;
static UILabel *gStatusLabel = nil;

static void UpdateHUD(UIView *view, NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gStatusLabel) {
            gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 100, view.bounds.size.width, 100)];
            gStatusLabel.textAlignment = NSTextAlignmentCenter;
            gStatusLabel.font = [UIFont boldSystemFontOfSize:14];
            gStatusLabel.textColor = [UIColor whiteColor];
            gStatusLabel.numberOfLines = 0;
            gStatusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
            [view addSubview:gStatusLabel];
        }
        gStatusLabel.text = [NSString stringWithFormat:@"VCAM V266 ACTIVE\nSTATUS: %@\nURL: %@", text, streamURL];
        gStatusLabel.textColor = color;
        [view bringSubviewToFront:gStatusLabel];
    });
}

// 1. Visual Hijack (Preview)
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        self.opacity = 0.0; // Total blackout of real lens
        UIView *p = (UIView *)self.delegate;
        if ([p isKindOfClass:[UIView class]]) {
            UIImageView *v = [p viewWithTag:9999];
            if (!v) {
                v = [[UIImageView alloc] initWithFrame:p.bounds];
                v.tag = 9999;
                v.contentMode = UIViewContentModeScaleAspectFill;
                v.backgroundColor = [UIColor blackColor];
                [p insertSubview:v atIndex:0];
            }
            if (gLastFrame) v.image = gLastFrame;
            
            NSString *stat = (gReader.frameCount > 0) ? 
                [NSString stringWithFormat:@"LIVE | FPS: %lu", (unsigned long)gReader.frameCount] : 
                @"CONNECTING...";
            UpdateHUD(p, stat, (gReader.frameCount > 0 ? [UIColor greenColor] : [UIColor orangeColor]));
        }
    }
}
%end

// 2. Absolute Photo Hijack (The Fix for 'Takes real photo')
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && gLastFrame) {
        return UIImageJPEGRepresentation(gLastFrame, 0.95);
    }
    return %orig;
}
%end

%ctor {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if ([bid containsString:@"camera"] || [bid containsString:@"telegra"] || [bid containsString:@"safari"]) {
        gReader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:streamURL]];
        gReader.frameCallback = ^(UIImage *f) { gLastFrame = f; };
        [gReader startStreaming];
    }
}
