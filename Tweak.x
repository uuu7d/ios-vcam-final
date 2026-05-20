#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _sys_enabled = YES;
static NSString *_sys_data_src = @"http://192.168.1.44:8888/live/stream/index.m3u8";

static AVPlayer *_internalPlayer = nil;
static AVPlayerItemVideoOutput *_internalOutput = nil;
static CVPixelBufferRef _internalBuffer = NULL;
static CIContext *_internalCtx = nil;
static AVPlayerLayer *_vcp_layer = nil;

static void _update_internal_config() {
    NSDictionary *p = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (p) {
        _sys_enabled = p[@"enabled"] ? [p[@"enabled"] boolValue] : YES;
        NSString *u = p[@"rtspURL"];
        if (u && u.length > 0) _sys_data_src = u;
    }
}

static void _sync_buffer() {
    if (!_internalOutput || !_sys_enabled || !_internalPlayer) return;
    CMTime t = [_internalPlayer.currentItem currentTime];
    if ([_internalOutput hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_internalOutput copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            CVPixelBufferRef old = _internalBuffer;
            _internalBuffer = pb; 
            if (old) CVPixelBufferRelease(old);
        }
    }
}

%hook AVCapturePhoto

- (CVPixelBufferRef)pixelBuffer {
    _sync_buffer();
    return (_sys_enabled && _internalBuffer) ? CVPixelBufferRetain(_internalBuffer) : %orig;
}

- (CVPixelBufferRef)previewPixelBuffer {
    _sync_buffer();
    return (_sys_enabled && _internalBuffer) ? CVPixelBufferRetain(_internalBuffer) : %orig;
}

- (CGImageRef)CGImageRepresentation {
    _sync_buffer();
    if (_sys_enabled && _internalBuffer) {
        if (!_internalCtx) _internalCtx = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_internalBuffer];
        return [_internalCtx createCGImage:ci fromRect:ci.extent];
    }
    return %orig;
}

- (NSData *)fileDataRepresentation {
    _sync_buffer();
    if (_sys_enabled && _internalBuffer) {
        if (!_internalCtx) _internalCtx = [[CIContext alloc] initWithOptions:nil];
        CIImage *ci = [CIImage imageWithCVPixelBuffer:_internalBuffer];
        CGImageRef cg = [_internalCtx createCGImage:ci fromRect:ci.extent];
        if (cg) {
            UIImage *ui = [UIImage imageWithCGImage:cg];
            NSData *d = UIImageJPEGRepresentation(ui, 0.9);
            CGImageRelease(cg);
            return d;
        }
    }
    return %orig;
}
%end

%hook AVCaptureVideoPreviewLayer
- (void)layoutSublayers {
    %orig;
    if (!_sys_enabled) return;
    self.hidden = YES;

    if (!_internalPlayer) {
        _update_internal_config();
        _internalPlayer = [[AVPlayer alloc] initWithURL:[NSURL URLWithString:_sys_data_src]];
        _internalOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
        [_internalPlayer.currentItem addOutput:_internalOutput];
        [_internalPlayer play];
        
        _vcp_layer = [AVPlayerLayer playerLayerWithPlayer:_internalPlayer];
        _vcp_layer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.superlayer insertSublayer:_vcp_layer above:self];
        
        [NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t) { _sync_buffer(); }];
    }
    
    if (_vcp_layer) {
        _vcp_layer.frame = self.bounds;
    }
}
%end

%ctor {
    _update_internal_config();
    %init;
}
