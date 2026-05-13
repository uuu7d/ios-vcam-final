// Tweak.x - VirtualCamPro V254.0: Targeted Injection Fix
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import "MJPEGStreamReader.h"

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static MJPEGStreamReader *gReader = nil;
static UIImage *gLastFrame = nil;

static void VCamLog(NSString *msg) {
    NSString *line = [NSString stringWithFormat:@"[VCam] %@\n", msg];
    NSLog(@"%@", line);
    FILE *f = fopen("/tmp/vcam.log", "a");
    if (f) {
        fprintf(f, "%s", [line UTF8String]);
        fclose(f);
    }
}

static void UpdateLabel(UIView *h, NSString *s, UIColor *c) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UILabel *l = (UILabel *)[h viewWithTag:7777];
        if (!l) {
            l = [[UILabel alloc] initWithFrame:CGRectMake(0, 120, h.bounds.size.width, 50)];
            l.tag = 7777;
            l.textAlignment = NSTextAlignmentCenter;
            l.font = [UIFont boldSystemFontOfSize:15];
            l.textColor = [UIColor whiteColor];
            l.numberOfLines = 0;
            [h addSubview:l];
        }
        l.text = s;
        l.backgroundColor = [c colorWithAlphaComponent:0.7];
    });
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        self.opacity = 0.0;
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
            
            NSString *status = (gReader.frameCount > 0) ? 
                [NSString stringWithFormat:@"V254 | LIVE | FPS: %lu", (unsigned long)gReader.frameCount] : 
                [NSString stringWithFormat:@"V254 | CONNECTING...\nURL: %@", streamURL];
            
            UpdateLabel(p, status, (gReader.frameCount > 0 ? [UIColor greenColor] : [UIColor orangeColor]));
        }
    }
}
%end

%ctor {
    VCamLog([NSString stringWithFormat:@"Loaded in %@", [NSBundle mainBundle].bundleIdentifier]);
    gReader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:streamURL]];
    gReader.frameCallback = ^(UIImage *f) { gLastFrame = f; };
    [gReader startStreaming];
}
