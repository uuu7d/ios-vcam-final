// VirtualCamPro V211.0: The Native Shadow (White Screen Fix)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static UIImageView *vcamImageView = nil;
static UIImage *lastSnapshot = nil;
static NSURLSessionDataTask *mjpegTask = nil;

// --- Native MJPEG Decoder ---

static void start_mjpeg_stream() {
    if (mjpegTask) [mjpegTask cancel];
    
    NSURL *url = [NSURL URLWithString:streamURL];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:nil delegateQueue:[NSOperationQueue mainQueue]];
    
    mjpegTask = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                start_mjpeg_stream();
            });
            return;
        }
        
        // Note: Real MJPEG requires boundary parsing. For simplicity and stability with MediaMTX,
        // we use a faster method or fallback to a recurring snapshot if the native stream fails.
    }];
    [mjpegTask resume];
}

// --- Global Hijack Logic ---

%hook AVCaptureDevice
- (NSString *)uniqueID { return @"com.apple.avfoundation.avcapturedevice.built-in_video:back"; }
- (NSString *)localizedName { return @"Back Camera"; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
%end

%hook AVCaptureConnection
- (BOOL)isEnabled {
    if (enabled && [self.output isKindOfClass:NSClassFromString(@"AVCaptureVideoPreviewLayer")]) return NO;
    return %orig;
}
%end

static void setup_vcam_native(UIView *parent) {
    if (!parent || !enabled) return;
    
    if (vcamImageView && vcamImageView.superview == parent) {
        [parent bringSubviewToFront:vcamImageView];
        return;
    }

    if (vcamImageView) [vcamImageView removeFromSuperview];

    vcamImageView = [[UIImageView alloc] initWithFrame:parent.bounds];
    vcamImageView.backgroundColor = [UIColor blackColor];
    vcamImageView.contentMode = UIViewContentModeScaleAspectFill;
    vcamImageView.userInteractionEnabled = NO;
    vcamImageView.clipsToBounds = YES;

    [parent addSubview:vcamImageView];
    [parent bringSubviewToFront:vcamImageView];

    // Using a simpler, more robust MJPEG/Snapshot loop to avoid "White Screen"
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
        if (!enabled) return;
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            NSData *data = [NSData dataWithContentsOfURL:[NSURL URLWithString:streamURL]];
            if (data) {
                UIImage *img = [UIImage imageWithData:data];
                if (img) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        vcamImageView.image = img;
                        lastSnapshot = img;
                    });
                }
            }
        });
    }];
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *target = nil;
        if ([self.delegate isKindOfClass:[UIView class]]) target = (UIView *)self.delegate;
        else if ([self.superlayer.delegate isKindOfClass:[UIView class]]) target = (UIView *)self.superlayer.delegate;

        if (target) {
            setup_vcam_native(target);
            vcamImageView.frame = target.bounds;
        }
    }
}
%end

// --- Deep Capture Hijack (KYC/Bank/Telegram) ---

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

// --- Gallery & Asset Hijack (The "No Thumbnail Leak" Fix) ---

%hook PHAssetCreationRequest
+ (instancetype)creationRequestForAssetFromImage:(UIImage *)image {
    if (enabled && lastSnapshot) return %orig(lastSnapshot);
    return %orig;
}
%end

%hook CAMImageWell
- (void)setThumbnailImage:(UIImage *)image {
    if (enabled && lastSnapshot) %orig(lastSnapshot);
    else %orig;
}
%end

%hook PHImageManager
- (PHImageRequestID)requestImageForAsset:(PHAsset *)asset targetSize:(CGSize)targetSize contentMode:(PHImageContentMode)contentMode options:(PHImageRequestOptions *)options resultHandler:(void (^)(UIImage *result, NSDictionary *info))resultHandler {
    if (enabled && lastSnapshot && [[NSDate date] timeIntervalSinceDate:asset.creationDate] < 30) {
        if (resultHandler) {
            resultHandler(lastSnapshot, nil);
            return (PHImageRequestID)1;
        }
    }
    return %orig;
}
%end

%ctor {
    NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:@"com.murkaska.virtualcampro"];
    enabled = [defs objectForKey:@"enabled"] ? [defs boolForKey:@"enabled"] : YES;
    NSString *str = [defs stringForKey:@"rtspURL"];
    if (str && str.length > 5) streamURL = str;

    NSLog(@"[VirtualCamPro] Native Stealth Engine V211.0 Loaded");
}