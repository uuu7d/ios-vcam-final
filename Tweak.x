#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

static BOOL enabled = YES;
// Используем HLS поток, который MediaMTX отдает по умолчанию
static NSString *streamURL = @"http://192.168.1.44:8888/live/stream/index.m3u8";

static AVPlayer *gPlayer = nil;
static AVPlayerLayer *gPlayerLayer = nil;
static UIView *gOverlayView = nil;
static UILabel *gDebugLabel = nil;

// --- ХУК: Подмена превью ---
%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!enabled) return;

    // Скрываем реальную камеру
    self.opacity = 0.0;

    UIView *container = (UIView *)self.delegate;
    if ([container isKindOfClass:[UIView class]]) {
        if (!gPlayer) {
            NSURL *url = [NSURL URLWithString:streamURL];
            gPlayer = [AVPlayer playerWithURL:url];
            gPlayerLayer = [AVPlayerLayer playerLayerWithPlayer:gPlayer];
            gPlayerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            gPlayerLayer.frame = container.bounds;
            [container.layer addSublayer:gPlayerLayer];
            [gPlayer play];

            // Отладочная инфо-панель
            gDebugLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 60, 300, 50)];
            gDebugLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
            gDebugLabel.textColor = [UIColor greenColor];
            gDebugLabel.font = [UIFont boldSystemFontOfSize:12];
            gDebugLabel.numberOfLines = 0;
            gDebugLabel.text = [NSString stringWithFormat:@"VCam Active\nURL: %@", streamURL];
            [container addSubview:gDebugLabel];
        }
        gPlayerLayer.frame = container.bounds;
    }
}
%end

// --- ХУК: Подмена фото (берем текущий кадр из видео) ---
%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && gPlayer) {
        // Это упрощенный вариант: для реального фото нужно вытаскивать кадр из AVPlayerItemVideoOutput
        // Но для теста пока оставим так или вернем заглушку
        return %orig;
    }
    return %orig;
}
%end

%ctor {
    NSLog(@"[VCam] Tweak loaded for stream: %@", streamURL);
}
