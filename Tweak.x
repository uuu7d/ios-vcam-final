#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

// --- СТАБИЛЬНЫЙ ПРОКСИ-ОБЪЕКТ ---
@interface VCamSimpleDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, strong) id originalTarget;
@end

@implementation VCamSimpleDelegate

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    // В этой версии мы пока просто пропускаем кадр, чтобы проверить стабильность
    // Если вылеты прекратятся, мы добавим сюда чтение из локального буфера
    if ([self.originalTarget respondsToSelector:_cmd]) {
        [self.originalTarget captureOutput:output didOutputSampleBuffer:sampleBuffer fromConnection:connection];
    }
}

- (BOOL)respondsToSelector:(SEL)aSelector {
    return [super respondsToSelector:aSelector] || [self.originalTarget respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector {
    return self.originalTarget;
}
@end

// --- ХУКИ ---

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)sampleBufferCallbackQueue {
    if (delegate && ![delegate isKindOfClass:[VCamSimpleDelegate class]]) {
        VCamSimpleDelegate *proxy = [[VCamSimpleDelegate alloc] init];
        proxy.originalTarget = delegate;
        // Сохраняем прокси, чтобы его не удалил GC
        objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        %orig(proxy, sampleBufferCallbackQueue);
    } else {
        %orig;
    }
}
%end

// --- МАКСИМАЛЬНО БЕЗОПАСНЫЙ CTOR ---
%ctor {
    @autoreleasepool {
        NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
        
        // Список критических процессов, которые НЕЛЬЗЯ трогать ни в коем случае
        if (!bundleID || 
            [bundleID hasPrefix:@"com.apple.springboard"] || 
            [bundleID hasPrefix:@"com.apple.backboard"] ||
            [bundleID hasPrefix:@"com.apple.mediaserverd"] ||
            [bundleID hasPrefix:@"com.apple.geod"]) {
            return;
        }

        %init;
    }
}
