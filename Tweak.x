// VirtualCamPro V232.0: The System Phantom Master (Total Lockdown)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static UIImage *globalLastImage = nil;
static CVPixelBufferRef globalLastPixelBuffer = NULL;

// --- Utility: Convert UIImage to CVPixelBuffer (BGRA) ---
static CVPixelBufferRef pixelBufferFromImage(UIImage *image) {
    if (!image) return NULL;
    CGImageRef cgImage = image.CGImage;
    size_t w = CGImageGetWidth(cgImage);
    size_t h = CGImageGetHeight(cgImage);
    
    CVPixelBufferRef pb = NULL;
    NSDictionary *options = @{(id)kCVPixelBufferCGImageCompatibilityKey:@YES,(id)kCVPixelBufferCGBitmapContextCompatibilityKey:@YES};
    CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)options, &pb);
    
    CVPixelBufferLockBaseAddress(pb, 0);
    CGContextRef ctx = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(pb), w, h, 8, CVPixelBufferGetBytesPerRow(pb), CGColorSpaceCreateDeviceRGB(), (CGBitmapInfo)kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), cgImage);
    CGContextRelease(ctx);
    CVPixelBufferUnlockBaseAddress(pb, 0);
    return pb;
}

// --- Global Stream Sync (Shared Memory) ---
static void start_phantom_sync() {
    static BOOL isRunning = NO;
    if (isRunning) return;
    isRunning = YES;
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        while (enabled) {
            @autoreleasepool {
                NSURL *url = [NSURL URLWithString:streamURL];
                NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingUncached error:nil];
                if (data) {
                    UIImage *img = [UIImage imageWithData:data];
                    if (img) {
                        globalLastImage = img;
                        CVPixelBufferRef pb = pixelBufferFromImage(img);
                        if (pb) {
                            CVPixelBufferRef old = globalLastPixelBuffer;
                            globalLastPixelBuffer = pb;
                            if (old) CFRelease(old);
                        }
                    }
                }
            }
            [NSThread sleepForTimeInterval:0.04];
        }
        isRunning = NO;
    });
}

// --- Direct Data Injection (The "Everywhere" Fix for Safari/Banks) ---
@interface VCAPDelegateWrapper : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, weak) id originalDelegate;
@end

@implementation VCAPDelegateWrapper
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (enabled && globalLastPixelBuffer) {
        CMSampleTimingInfo timingInfo;
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, 0, &timingInfo);
        
        CMVideoFormatDescriptionRef formatDesc = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, globalLastPixelBuffer, &formatDesc);
        
        CMSampleBufferRef newBuffer = NULL;
        CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, globalLastPixelBuffer, formatDesc, &timingInfo, &newBuffer);
        
        if (newBuffer) {
            [self.originalDelegate captureOutput:output didOutputSampleBuffer:newBuffer fromConnection:connection];
            CFRelease(newBuffer);
            if (formatDesc) CFRelease(formatDesc);
            return;
        }
    }
    [self.originalDelegate captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
}
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    if (enabled && delegate && ![delegate isKindOfClass:[VCAPDelegateWrapper class]]) {
        VCAPDelegateWrapper *wrapper = [[VCAPDelegateWrapper alloc] init];
        wrapper.originalDelegate = delegate;
        %orig(wrapper, queue);
    } else {
        %orig(delegate, queue);
    }
}
%end

// --- Visual Preview Hijack (Ultra Robust for Telegram/Camera) ---
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        UIView *parent = nil;
        if ([self.delegate isKindOfClass:[UIView class]]) parent = (UIView *)self.delegate;
        else if ([self.superlayer.delegate isKindOfClass:[UIView class]]) parent = (UIView *)self.superlayer.delegate;
        
        // Fallback: Use the key window to bypass complex view hierarchies (Telegram fix)
        if (!parent) parent = [UIApplication sharedApplication].keyWindow;

        if (parent) {
            UIImageView *vcamView = (UIImageView *)[parent viewWithTag:9922];
            if (!vcamView) {
                vcamView = [[UIImageView alloc] initWithFrame:parent.bounds];
                vcamView.backgroundColor = [UIColor blackColor];
                vcamView.contentMode = UIViewContentModeScaleAspectFill;
                vcamView.tag = 9922;
                vcamView.userInteractionEnabled = NO;
                [parent addSubview:vcamView];
                [parent bringSubviewToFront:vcamView];
                
                [NSTimer scheduledTimerWithTimeInterval:0.04 repeats:YES block:^(NSTimer *t) {
                    if (enabled && globalLastImage) vcamView.image = globalLastImage;
                }];
            }
            vcamView.frame = parent.bounds;
        }
    }
}
%end

// --- Hardware Spoofing (Anti-Detection) ---
%hook AVCaptureDevice
- (NSString *)uniqueID { return @"com.apple.avfoundation.avcapturedevice.built-in_video:back"; }
- (NSString *)localizedName { return @"Back Camera"; }
- (AVCaptureDeviceType)deviceType { return AVCaptureDeviceTypeBuiltInWideAngleCamera; }
- (BOOL)isVirtualDevice { return NO; }
%end

// --- Final Capture Fix (Photo/Gallery) ---
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && globalLastImage) return UIImageJPEGRepresentation(globalLastImage, 0.95);
    return %orig;
}
%end

%hook CAMImageWell
- (void)setThumbnailImage:(UIImage *)image {
    if (enabled && globalLastImage) %orig(globalLastImage);
    else %orig;
}
%end

%ctor {
    NSArray *paths = @[@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist", 
                       @"/var/jb/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    for (NSString *p in paths) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) {
            enabled = [d[@"enabled"] ?: @YES boolValue];
            NSString *u = d[@"rtspURL"];
            if (u && u.length > 5) streamURL = u;
            break;
        }
    }
    if (enabled) start_phantom_sync();
    NSLog(@"[VirtualCamPro] Phantom Master V232.0 Active");
}