// VCAM V81.0: Diagnostic Dashboard & Enhanced Logging
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreImage/CoreImage.h>

static BOOL enabled = NO;
static NSString *rtspURL = @"http://192.168.1.44:8889/live/stream";
static UILabel *statusLabel = nil;

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
            vcam_log(status);
        }
    });
}

%hook AVCaptureSession
- (void)startRunning {
    %orig;
    vcam_log(@"Capture Session Started");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!statusLabel) {
            statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 50, 300, 30)];
            statusLabel.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.5];
            statusLabel.font = [UIFont boldSystemFontOfSize:14];
            statusLabel.layer.cornerRadius = 5;
            statusLabel.clipsToBounds = YES;
            statusLabel.textAlignment = NSTextAlignmentCenter;
            [[UIApplication sharedApplication].keyWindow addSubview:statusLabel];
        }
        statusLabel.hidden = !enabled;
    });
    if (enabled) {
        update_vcam_status(@"CONNECTING...", [UIColor yellowColor]);
    }
}
%end

static void loadPrefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.vcampro.plist"];
    enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : NO;
    rtspURL = prefs[@"rtspURL"] ? prefs[@"rtspURL"] : rtspURL;
}

%ctor {
    loadPrefs();
    vcam_log(@"Tweak Loaded - Version 81.0");
}
