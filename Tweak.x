// Tweak.x - VirtualCamPro V265.0: The Truth
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;
    
    // We make the real camera slightly visible (0.1) so you don't just see a void if the tweak fails
    self.opacity = 0.1;
    
    // We try to find the container view in multiple ways
    UIView *p = (UIView *)self.delegate;
    if (![p isKindOfClass:[UIView class]]) {
        p = [self valueForKey:@"_containerView"]; // Internal Apple key fallback
    }

    if ([p isKindOfClass:[UIView class]]) {
        UILabel *statusLabel = [p viewWithTag:7777];
        if (!statusLabel) {
            // Create a BIG RED label that is impossible to miss if the tweak is running
            statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 150, p.bounds.size.width, 120)];
            statusLabel.tag = 7777;
            statusLabel.text = [NSString stringWithFormat:@"VCAM V265 ACTIVE\nPROC: %@\nURL: %@\nWAITING FOR STREAM...", 
                                [NSBundle mainBundle].bundleIdentifier, streamURL];
            statusLabel.numberOfLines = 0;
            statusLabel.textAlignment = NSTextAlignmentCenter;
            statusLabel.textColor = [UIColor whiteColor];
            statusLabel.backgroundColor = [UIColor redColor];
            statusLabel.font = [UIFont boldSystemFontOfSize:14];
            [p addSubview:statusLabel];
            [p bringSubviewToFront:statusLabel];
            
            // Also add a black background for the video area
            UIView *bg = [[UIView alloc] initWithFrame:p.bounds];
            bg.backgroundColor = [UIColor blackColor];
            bg.tag = 6666;
            [p insertSubview:bg atIndex:0];
        }
        statusLabel.frame = CGRectMake(0, 150, p.bounds.size.width, 120);
        [p bringSubviewToFront:statusLabel];
    }
}
%end

%ctor {
    NSLog(@"[VCam] V265 Loaded in %@", [NSBundle mainBundle].bundleIdentifier);
}
