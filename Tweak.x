#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _vcp_enabled = YES;
static NSString *_vcp_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_vcp_player = nil;
static AVPlayerItemVideoOutput *_vcp_out = nil;
static CVPixelBufferRef _vcp_buf = NULL;
static AVPlayerLayer *_vcp_view = nil;

static void _vcp_load() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _vcp_enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        if (p[@"rtspURL"]) _vcp_url = p[@"rtspURL"];
    }
}

static void _vcp_sync() {
    if (!_vcp_out || !_vcp_enabled || !_vcp_player) return;
    CMTime t = [_vcp_player.currentItem currentTime];
    if ([_vcp_out hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_vcp_out copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            CVPixelBufferRef old = _vcp_buf;
            _vcp_buf = pb;
            if (old) CVPixelBufferRelease(old);
        }
    }
}

// Ультимативный хук на упаковку данных (CMSampleBuffer)
%hookf(OSStatus, CMSampleBufferCreateForImageBuffer, CFAllocatorRef allocator, CVImageBufferRef imageBuffer, Boolean dataReady, CMSampleBufferMakeDataReadyCallback makeDataReadyCallback, void *makeDataReadyRefcon, CMVideoFormatDescriptionRef formatDescription, const CMSampleTimingInfo *sampleTiming, CMSampleBufferRef *sBufOut) {
    if (_vcp_enabled && _vcp_buf) {
        return %orig(allocator, _vcp_buf, dataReady, makeDataReadyCallback, makeDataReadyRefcon, formatDescription, sampleTiming, sBufOut);
    }
    return %orig(allocator, imageBuffer, dataReady, makeDataReadyCallback, makeDataReadyRefcon, formatDescription, sampleTiming, sBufOut);
}

%hook AVCapturePhoto
- (CVPixelBufferRef)pixelBuffer {
    if (_vcp_enabled && _vcp_buf) return CVPixelBufferRetain(_vcp_buf);
    return %orig;
}
- (NSData *)fileDataRepresentation {
    if (_vcp_enabled && _vcp_buf) {
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_vcp_buf];
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CGImageRef cg = [ctx createCGImage:ci fromRect:ci.extent];
        UIImage *ui = [UIImage imageWithCGImage:cg];
        NSData *d = UIImageJPEGRepresentation(ui, 0.9);
        CGImageRelease(cg);
        return d;
    }
    return %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_vcp_enabled) return;
    self.hidden = YES;
    if (!_vcp_player) {
        _vcp_load();
        _vcp_player = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_vcp_url]];
        _vcp_out = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_vcp_player.currentItem addOutput:_vcp_out];
        [_vcp_player play];
        _vcp_view = [AVPlayerLayer playerLayerWithPlayer:_vcp_player];
        _vcp_view.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:_vcp_view above:self];
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _vcp_sync(); }];
    }
    if (_vcp_view) _vcp_view.frame = self.bounds;
}
%end

%ctor {
    _vcp_load();
    %init;
}
