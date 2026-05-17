#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import "MJPEGStreamReader.h"

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8888/live";

static MJPEGStreamReader *gReader = nil;
static UIImage *gLastFrame = nil;
static UIImageView *gPreviewView = nil;
static UILabel *gStatusLabel = nil;

// --- Вспомогательная функция для конвертации UIImage в системный буфер ---
CMSampleBufferRef CreateSampleBufferFromImage(UIImage *image, CMTime timestamp) {
    if (!image) return NULL;
    
    CGImageRef cgImage = image.CGImage;
    CVPixelBufferRef pxbuffer = NULL;
    
    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    
    NSDictionary *options = @{
        (id)kCVPixelBufferCGImageCompatibilityKey: @YES,
        (id)kCVPixelBufferCGBitmapContextCompatibilityKey: @YES
    };
    
    CVReturn status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)options, &pxbuffer);
    if (status != kCVReturnSuccess) return NULL;
    
    CVPixelBufferLockBaseAddress(pxbuffer, 0);
    void *pxdata = CVPixelBufferGetBaseAddress(pxbuffer);
    
    CGColorSpaceRef rgbColorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pxdata, width, height, 8, CVPixelBufferGetBytesPerRow(pxbuffer), rgbColorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    
    CGColorSpaceRelease(rgbColorSpace);
    CGContextRelease(context);
    CVPixelBufferUnlockBaseAddress(pxbuffer, 0);
    
    CMVideoFormatDescriptionRef formatDescription;
    CMVideoFormatDescriptionCreateForImageBuffer(NULL, pxbuffer, &formatDescription);
    
    CMSampleTimingInfo timingInfo = { kCMTimeInvalid, timestamp, kCMTimeInvalid };
    CMSampleBufferRef sampleBuffer = NULL;
    
    CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, pxbuffer, YES, NULL, NULL, formatDescription, &timingInfo, &sampleBuffer);
    
    CFRelease(formatDescription);
    CVPixelBufferRelease(pxbuffer);
    
    return sampleBuffer;
}

void UpdateStatus(NSString *text, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gStatusLabel) {
            gStatusLabel.text = text;
            gStatusLabel.textColor = color;
        }
    });
}

// --- ХУК 1: Подмена превью на экране ---
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;
    
    self.opacity = 0.0; // Скрываем реальную камеру
    UIView *container = (UIView *)self.delegate;
    
    if ([container isKindOfClass:[UIView class]]) {
        if (!gPreviewView) {
            gPreviewView = [[UIImageView alloc] initWithFrame:container.bounds];
            gPreviewView.contentMode = UIViewContentModeScaleAspectFill;
            gPreviewView.backgroundColor = [UIColor blackColor];
            [container insertSubview:gPreviewView atIndex:0];
            
            gStatusLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 40, 200, 30)];
            gStatusLabel.font = [UIFont boldSystemFontOfSize:14];
            gStatusLabel.text = @"Wait Stream...";
            gStatusLabel.textColor = [UIColor yellowColor];
            [container addSubview:gStatusLabel];
        }
        gPreviewView.frame = container.bounds;
        if (gLastFrame) gPreviewView.image = gLastFrame;
    }
}
%end

// --- ХУК 2: Подмена данных для сохранения ФОТО ---
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && gLastFrame) return UIImageJPEGRepresentation(gLastFrame, 0.95);
    return %orig;
}
%end

// --- ХУК 3: ГЛУБОКАЯ ПОДМЕНА (Видеозвонки и системные данные) ---
%hook NSObject
// Перехватываем метод делегата, через который проходят ВСЕ кадры видео
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    if (enabled && gLastFrame) {
        // Берем временную метку оригинального кадра, чтобы не было фризов
        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        
        CMSampleBufferRef fakeBuffer = CreateSampleBufferFromImage(gLastFrame, timestamp);
        if (fakeBuffer) {
            // Подсовываем наш кадр вместо системного
            %orig(output, fakeBuffer, connection);
            CFRelease(fakeBuffer);
            return;
        }
    }
    %orig;
}
%end

%ctor {
    gReader = [[MJPEGStreamReader alloc] initWithURL:[NSURL URLWithString:streamURL]];
    gReader.frameCallback = ^(UIImage *f) {
        gLastFrame = f;
        UpdateStatus(@"● LIVE", [UIColor greenColor]);
        if (gPreviewView) {
            dispatch_async(dispatch_get_main_queue(), ^{
                gPreviewView.image = f;
            });
        }
    };
    gReader.errorCallback = ^(NSError *error) {
        UpdateStatus(@"● ERROR", [UIColor redColor]);
    };
    [gReader startStreaming];
}
