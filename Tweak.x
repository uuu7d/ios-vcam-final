// VirtualCamPro Tweak Version 89.0 - KYC Master
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>

static BOOL enabled = YES;
static NSString *rtspURL = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static UILabel *statusLabel = nil;
static UIWindow *overlayWindow = nil;
static AVPlayer *vcamPlayer = nil;
static AVPlayerLayer *vcamLayer = nil;
static AVPlayerItemVideoOutput *vcamVideoOutput = nil;

void vcam_log(NSString *message) {
    NSString *logPath = @"/var/mobile/Documents/vcam_DEBUG.log";
    NSString *timestamp = [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterLongStyle];
    NSString *formattedMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (fileHandle) {
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[formattedMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [formattedMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void update_vcam_status(NSString *status, UIColor *color) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (statusLabel) {
            statusLabel.text = [NSString stringWithFormat:@"VCAM: %@", status];
            statusLabel.textColor = color;
        }
    });
    vcam_log(status);
}

void setup_vcam_player() {
    if (vcamPlayer) {
        [[NSNotificationCenter defaultCenter] removeObserver:vcamPlayer.currentItem];
        [vcamPlayer pause];
        vcamPlayer = nil;
        vcamLayer = nil;
        vcamVideoOutput = nil;
    }
    
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL URLWithString:rtspURL]];
    vcamPlayer = [AVPlayer playerWithPlayerItem:item];
    vcamLayer = [AVPlayerLayer playerLayerWithPlayer:vcamPlayer];
    vcamLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    vcamPlayer.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    
    NSDictionary *pixelBufferOptions = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    vcamVideoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixelBufferOptions];
    [item addOutput:vcamVideoOutput];
    
    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemDidPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        [vcamPlayer seekToTime:kCMTimeZero];
        [vcamPlayer play];
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:AVPlayerItemFailedToPlayToEndTimeNotification object:item queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *note) {
        vcam_log(@"Stream failed, reconnecting...");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            setup_vcam_player();
        });
    }];
    
    [vcamPlayer play];
}

void setup_status_bar() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!overlayWindow) {
            overlayWindow = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, [UIScreen mainScreen].bounds.size.width, 100)];
            overlayWindow.windowLevel = UIWindowLevelAlert + 2;
            overlayWindow.userInteractionEnabled = NO;
            overlayWindow.backgroundColor = [UIColor clearColor];
            overlayWindow.hidden = NO;

            statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 40, 300, 25)];
            statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
            statusLabel.textColor = [UIColor whiteColor];
            statusLabel.font = [UIFont boldSystemFontOfSize:12];
            statusLabel.layer.cornerRadius = 5;
            statusLabel.clipsToBounds = YES;
            statusLabel.textAlignment = NSTextAlignmentCenter;
            [overlayWindow addSubview:statusLabel];
        }
        overlayWindow.hidden = !enabled;
    });
}

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (enabled) {
        if (!vcamPlayer) {
            setup_vcam_player();
        }
        if (vcamLayer.superlayer != self) {
            [self addSublayer:vcamLayer];
        }
        vcamLayer.frame = self.bounds;
        vcamLayer.zPosition = 999;

        if (vcamPlayer.status == AVPlayerStatusReadyToPlay) {
            update_vcam_status(@"STREAMING ACTIVE", [UIColor greenColor]);
        } else {
            update_vcam_status(@"CONNECTING...", [UIColor yellowColor]);
        }
    }
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    if (enabled && vcamVideoOutput) {
        CMTime itemTime = [vcamPlayer.currentItem currentTime];
        if ([vcamVideoOutput hasNewPixelBufferForItemTime:itemTime]) {
            CVPixelBufferRef pixelBuffer = [vcamVideoOutput copyPixelBufferForItemTime:itemTime itemTimeForDisplay:NULL];
            if (pixelBuffer) {
                vcam_log(@"KYC Master: Hijacking photo capture with OBS frame.");
                // In a real implementation, we would wrap this pixelBuffer into a CMSampleBuffer 
                // and pass it back through the delegate methods. 
                // For now, logging to confirm the hook is active for V89.0.
                CVPixelBufferRelease(pixelBuffer);
            }
        }
    }
    %orig;
}
%end

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    vcam_log(@"Capture Session Started");
    setup_status_bar();
}
%end

static void loadPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    if (prefs) {
        enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
        rtspURL = prefs[@"rtspURL"] ? prefs[@"rtspURL"] : rtspURL;
    }
}

%ctor {
    loadPrefs();
    vcam_log(@"Tweak Loaded - Version 89.0 KYC Master");
}
