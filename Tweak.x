// VCAM V124.0: The Ghost In The Machine - Direct Layer Contents Hijack
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *vURL = @"http://192.168.1.44:8889/live/stream";
static UIImage *sharedSnap = nil;
static NSMutableData *vBuffer = nil;

@interface VCamEngine : NSObject <NSURLSessionDataDelegate> + (instancetype)shared; - (void)start; @end
@implementation VCamEngine
+ (instancetype)shared { static VCamEngine *s = nil; static dispatch_once_t o; dispatch_once(&o, ^{ s = [[self alloc] init]; }); return s; }
- (void)start {
    if (vBuffer) return;
    vBuffer = [NSMutableData data];
    NSURLSession *s = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration] delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    [[s dataTaskWithURL:[NSURL URLWithString:vURL]] resume];
}
- (void)URLSession:(NSURLSession *)s dataTask:(NSURLSessionDataTask *)t didReceiveData:(NSData *)d {
    [vBuffer appendData:d];
    const unsigned char *b = (const unsigned char *)vBuffer.bytes; NSInteger len = vBuffer.length;
    for (NSInteger i = 0; i < len - 1; i++) {
        if (b[i] == 0xFF && b[i+1] == 0xD8) {
            for (NSInteger j = i + 1; j < len - 1; j++) {
                if (b[j] == 0xFF && b[j+1] == 0xD9) {
                    UIImage *img = [UIImage imageWithData:[vBuffer subdataWithRange:NSMakeRange(i, j - i + 2)]];
                    if (img) sharedSnap = img;
                    [vBuffer replaceBytesInRange:NSMakeRange(0, j + 2) withBytes:NULL length:0]; return;
                }
            }
        }
    }
}
@end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        [[VCamEngine shared] start];
        if (sharedSnap) {
            // FORCE INJECT CONTENTS INTO THE NATIVE LAYER
            self.contents = (__bridge id)sharedSnap.CGImage;
            
            // Mirroring logic for front camera
            AVCaptureSession *s = self.session; BOOL f = NO;
            if (s) {
                for (AVCaptureInput *i in s.inputs) {
                    if ([i isKindOfClass:[AVCaptureDeviceInput class]] && ((AVCaptureDeviceInput *)i).device.position == 2) { f = YES; break; }
                }
            }
            self.transform = f ? CATransform3DMakeAffineTransform(CGAffineTransformMakeScale(-1, 1)) : CATransform3DIdentity;
        }
    }
}

// Block the system from putting the real camera frames back into the layer
- (void)setContents:(id)contents {
    if (enabled && sharedSnap) {
        %orig((__bridge id)sharedSnap.CGImage);
    } else {
        %orig;
    }
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)s delegate:(id)d {
    if (enabled && sharedSnap) objc_setAssociatedObject(s, "vcamS", sharedSnap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig;
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    UIImage *snap = objc_getAssociatedObject([self resolvedSettings], "vcamS");
    if (snap) return UIImageJPEGRepresentation(snap, 0.95);
    return %orig;
}
- (struct CGImage *)CGImageRepresentation {
    UIImage *snap = objc_getAssociatedObject([self resolvedSettings], "vcamS");
    if (snap) return snap.CGImage;
    return %orig;
}
%end

%ctor {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (p) {
        enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) vURL = [p[@"rtspURL"] stringByReplacingOccurrencesOfString:@"/index.m3u8" withString:@""];
    }
}
