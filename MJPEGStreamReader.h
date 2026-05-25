// MJPEGStreamReader.h - VirtualCamPro V272.2 (Fixed)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^MJPEGFrameCallback)(UIImage *frame);
typedef void (^MJPEGPixelBufferCallback)(CVPixelBufferRef buffer);
typedef void (^MJPEGErrorCallback)(NSError *error);

@interface MJPEGStreamReader : NSObject <NSURLSessionDataDelegate>

@property (nonatomic, strong, readonly) NSURL *streamURL;
@property (nonatomic, assign, readonly) BOOL isConnecting;
@property (nonatomic, assign, readonly) NSUInteger frameCount;
@property (nonatomic, assign, readonly) CFAbsoluteTime lastFrameTime;

@property (nonatomic, copy, nullable) MJPEGFrameCallback frameCallback;
@property (nonatomic, copy, nullable) MJPEGPixelBufferCallback pixelBufferCallback;
@property (nonatomic, copy, nullable) MJPEGErrorCallback errorCallback;

- (instancetype)initWithURL:(NSURL *)url;
- (void)startStreaming;
- (void)stopStreaming;

@end
