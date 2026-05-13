// VirtualCamPro V240.2: The Deep Engine Breakthrough (Clean Text Fix)
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

static BOOL enabled = YES;
static NSString *streamURL = @"http://192.168.1.44:8889/live/stream";
static UIImage *globalLastImage = nil;

@interface VCAMFetcher : NSObject <NSURLSessionDataDelegate>
@property (strong) NSURLSessionDataTask *task;
@property (strong) NSMutableData *buffer;
- (void)start;
@end

@implementation VCAMFetcher
- (instancetype)init {
    if (self = [super init]) {
        _buffer = [NSMutableData data];
    }
    return self;
}

- (void)start {
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    NSURLRequest *req = [NSURLRequest requestWithURL:[NSURL URLWithString:streamURL]];
    _task = [session dataTaskWithRequest:req];
    [_task resume];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [_buffer appendData:data];
    
    unsigned char s1[] = {0xff, 0xd8};
    unsigned char s2[] = {0xff, 0xd9};
    NSData *startData = [NSData dataWithBytes:s1 length:2];
    NSData *endData = [NSData dataWithBytes:s2 length:2];
    
    NSRange startRange = [_buffer rangeOfData:startData options:NSDataSearchBackwards range:NSMakeRange(0, _buffer.length)];
    if (startRange.location != NSNotFound) {
        NSRange endRange = [_buffer rangeOfData:endData options:0 range:NSMakeRange(startRange.location, _buffer.length - startRange.location)];
        if (endRange.location != NSNotFound) {
            NSRange imgRange = NSMakeRange(startRange.location, endRange.location - startRange.location + 2);
            NSData *jpeg = [_buffer subdataWithRange:imgRange];
            UIImage *img = [UIImage imageWithData:jpeg];
            if (img) globalLastImage = img;
            [_buffer replaceBytesInRange:NSMakeRange(0, endRange.location + 2) withBytes:NULL length:0];
        }
    }
    if (_buffer.length > 1024 * 1024 * 8) _buffer.length = 0;
}
@end

static VCAMFetcher *fetcher = nil;

static void load_prefs() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];
    if (prefs) {
        enabled = prefs[@"enabled"] ? [prefs[@"enabled"] boolValue] : YES;
        NSString *u = prefs[@"rtspURL"];
        if (u && u.length > 5) streamURL = u;
    }
}

%hook NSBundle
- (id)objectForInfoDictionaryKey:(NSString *)key {
    if ([key isEqualToString:@"NSAppTransportSecurity"]) {
        return @{ @"NSAllowsArbitraryLoads": @YES };
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
            UIImageView *vcam = [p viewWithTag:9999];
            if (!vcam) {
                vcam = [[UIImageView alloc] initWithFrame:p.bounds];
                vcam.tag = 9999;
                vcam.contentMode = UIViewContentModeScaleAspectFill;
                [p insertSubview:vcam atIndex:0];
            }
            vcam.image = globalLastImage;
        }
    }
}
%end

%hook AVCapturePhoto
- (NSData *)fileDataRepresentation {
    if (enabled && globalLastImage) return UIImageJPEGRepresentation(globalLastImage, 0.85);
    return %orig;
}
%end

%hook CAMImageWell
- (void)setThumbnailImage:(UIImage *)image {
    if (enabled && globalLastImage) %orig(globalLastImage);
    else %orig(image);
}
%end

%ctor {
    load_prefs();
    if (enabled) {
        fetcher = [[VCAMFetcher alloc] init];
        [fetcher start];
    }
}
