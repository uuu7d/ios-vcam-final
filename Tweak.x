// Tweak.x - VirtualCamPro V258.0: Core Overlord
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <os/log.h>
#import "MJPEGStreamReader.h"

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static MJPEGStreamReader *gReader = nil;
static UIImage *gLastFrame = nil;
static UILabel *gHUD = nil;

static void GlobalLog(NSString *msg) {
    os_log(OS_LOG_DEFAULT, "[VCam] %{public}@", msg);
    FILE *f = fopen("/tmp/vcam.log", "a");
    if (f) {
        fprintf(f, "[%s] %s\n", [[NSDate date].description UTF8String], [msg UTF8String]);
        fclose(f);
    }
}

// Improved SampleBuffer creation for higher compatibility with Banks/Telegram
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
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, px, YES, nil, nil, vdesc, &t, &sb);
    
    CFRelease(px);
    if (vdesc) CFRelease(vdesc);
    return sb;
}

static void UpdateHUD(UIView *view, NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gHUD) {
            gHUD = [[UILabel alloc] initWithFrame:CGRectMake(0, 100, view.bounds.size.width, 80)];
            gHUD.textAlignment = NSTextAlignmentCenter;
            gHUD.font = [UIFont boldSystemFontOfSize:14];
            gHUD.textColor = [UIColor whiteColor];
            gHUD.numberOfLines = 0;
            gHUD.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.8];
            [view addSubview:gHUD];
        }
        gHUD.text = [NSString stringWithFormat:@"V258 CORE OVERLORD\n%@", text];
        gHUD.textColor = color;
        [view bringSubviewToFront:gHUD];
    });
}

// 1. Visual Hijack (For the User)
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;
    self.opacity = 0.0;
    UIView *container = (UIView *)self.delegate;
    if ([container isKindOfClass:[UIView class]]) {
        UIImageView *v = [container viewWithTag:9999];
        if (!v) {
            v = [[UIImageView alloc] initWithFrame:container.bounds];
            v.tag = 9999;
            v.contentMode = UIViewContentModeScaleAspectFill;
            v.backgroundColor = [UIColor blackColor];
            [container insertSubview:v atIndex:0];
        }
        if (gLastFrame) v.image = gLastFrame;
        
        NSString *stat = (gReader.frameCount > 0) ? 
            [NSString stringWithFormat:@"LIVE | FPS: %lu", (unsigned long)gReader.frameCount] : 
            [NSString stringWithFormat:@"CONNECTING...\n%@", streamURL];
        UpdateHUD(container, stat, (gReader.frameCount > 0 ? [UIColor greenColor] : [UIColor orangeColor]));
    }
}
%end

// 2. Data Hijack (For Apps/Banks/Telegram)
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

// 3. Absolute Photo Hijack (Multiple Methods)
%hook AVCapturePhoto
- (CGImageRef)CGImageRepresentation {
    if (enabled && gLastFrame) return gLastFrame.CGImage;
    return %orig;
}
- (NSData *)fileDataRepresentation {
    if (enabled && gLastFrame) return UIImageJPEGRepresentation(gLastFrame, 0.95);
    return %orig;
}
%end

%ctor {
    NSString *bid = [NSBundle mainBundle].bundleIdentifier;
    // Only run networking in UI apps to prevent system-wide hangs
    if ([bid containsString:@"camera"] || [bid containsString:@"telegra"] || [bid containsString:@"safari"] || [bid containsString:@"chrome"]) {
        GlobalLog([NSString stringWithFormat:@"CORE OVERLORD active in %@", bid]);
        gReader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:streamURL]];
        gReader.frameCallback = ^(UIImage *f) { gLastFrame = f; };
        [gReader startStreaming];
    }
}
