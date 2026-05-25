// MJPEGStreamReader.h - VirtualCamPro V272.0 (Stage 1 fixes)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MJPEGFrameCallback)(UIImage *frame);
typedef void (^MJPEGErrorCallback)(NSError *error);
// NEW: direct pixel-buffer delivery (caller MUST CVPixelBufferRelease)
typedef void (^MJPEGPixelBufferCallback)(CVPixelBufferRef pixelBuffer);

@interface MJPEGStreamReader : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong, readonly) NSURL *streamURL;
@property (nonatomic, assign, readonly) BOOL isConnecting;
@property (nonatomic, assign, readonly) NSUInteger frameCount;
@property (nonatomic, assign, readonly) CFAbsoluteTime lastFrameTime;
@property (nonatomic, copy, nullable) MJPEGFrameCallback frameCallback;
@property (nonatomic, copy, nullable) MJPEGErrorCallback errorCallback;
// NEW: preferred path - skips UIImage round-trip
@property (nonatomic, copy, nullable) MJPEGPixelBufferCallback pixelBufferCallback;

- (instancetype)initWithURL:(NSURL *)url;
- (void)startStreaming;
- (void)stopStreaming;
@end

NS_ASSUME_NONNULL_END
