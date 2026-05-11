// VCAM V147.0: The Bulletproof Native - No Browser, No Question Marks
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static UIImageView *vcamImageView = nil;
static UIImage *lastValidFrame = nil;

static void setup_native_vcam(UIView *parent) {
    if (!parent || (vcamImageView && vcamImageView.superview == parent)) return;
    if (vcamImageView) [vcamImageView removeFromSuperview];

    vcamImageView = [[UIImageView alloc] initWithFrame:parent.bounds];
    vcamImageView.backgroundColor = [UIColor blackColor];
    vcamImageView.contentMode = UIViewContentModeScaleAspectFill;
    vcamImageView.clipsToBounds = YES;
    vcamImageView.userInteractionEnabled = NO;
    [parent insertSubview:vcamImageView atIndex:0];

    // Native MJPEG Loader - Bypasses WebKit/Chrome restrictions
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (enabled) {
            @autoreleasepool {
                NSURL *url = [NSURL URLWithString:streamURL];
                NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:nil];
                if (data && data.length > 1000) {
                    UIImage *img = [UIImage imageWithData:data];
                    if (img) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            vcamImageView.image = img;
                            lastValidFrame = img;
                        });
                    }
                }
            }
            [NSThread sleepForTimeInterval:0.04]; // ~25 FPS
        }
    });
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *p = (UIView *)self.delegate;
        if (!p || ![p isKindOfClass:[UIView class]]) p = (UIView *)self.superlayer.delegate;
        if (p && [p isKindOfClass:[UIView class]]) {
            setup_native_vcam(p);
            vcamImageView.frame = p.bounds;
            
            AVCaptureSession *s = self.session;
            BOOL isFront = NO;
            if (s) {
                for (AVCaptureDeviceInput *i in s.inputs) {
                    if (i.device.position == 2) { isFront = YES; break; }
                }
            }
            vcamImageView.transform = isFront ? CGAffineTransformMakeScale(-1, 1) : CGAffineTransformIdentity;
            [self setOpacity:0.0];
        }
    }
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && lastValidFrame) return UIImageJPEGRepresentation(lastValidFrame, 0.95);
    return %orig;
}

- (struct CGImage *)CGImageRepresentation {
    if (enabled && lastValidFrame) return lastValidFrame.CGImage;
    return %orig;
}

- (struct CGImage *)previewCGImageRepresentation {
    if (enabled && lastValidFrame) return lastValidFrame.CGImage;
    return %orig;
}
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) {
        enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) streamURL = p[@"rtspURL"];
    }
}