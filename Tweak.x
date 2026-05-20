#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
static BOOL _en=YES;
static NSString *_url=@"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_p=nil;
static AVPlayerItemVideoOutput *_o=nil;
static CVPixelBufferRef _b=NULL;
static void _sync(){if(!_o||!_en||!_p)return;CMTime t=[_p.currentItem currentTime];if([_o hasNewPixelBufferForItemTime:t]){CVPixelBufferRef pb=[_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];if(pb){if(_b)CVPixelBufferRelease(_b);_b=pb;}}}
@interface VCPGhostPhoto:AVCapturePhoto @end
@implementation VCPGhostPhoto
-(CVPixelBufferRef)pixelBuffer{_sync();return _b?CVPixelBufferRetain(_b):NULL;}
-(NSData *)fileDataRepresentation{_sync();if(!_b)return nil;CGImageRef cg=[[CIContext contextWithOptions:nil] createCGImage:[CIImage imageWithCVPixelBuffer:_b] fromRect:CGRectMake(0,0,CVPixelBufferGetWidth(_b),CVPixelBufferGetHeight(_b))];NSData *d=UIImageJPEGRepresentation([UIImage imageWithCGImage:cg],0.9);CGImageRelease(cg);return d;}
@end
@interface VCPProxy:NSObject <AVCaptureVideoDataOutputSampleBufferDelegate,AVCapturePhotoCaptureDelegate>
@property(nonatomic,strong)id t;@end
@implementation VCPProxy
-(void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c{if(_en&&_b){_sync();CMSampleBufferRef nb=NULL;CMFormatDescriptionRef fd=NULL;CMVideoFormatDescriptionCreateForImageBuffer(NULL,_b,(CMVideoFormatDescriptionRef *)&fd);CMSampleTimingInfo ti;CMSampleBufferGetSampleTimingInfo(s,0,&ti);CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,_b,YES,NULL,NULL,fd,&ti,&nb);if(nb){if([self.t respondsToSelector:_cmd])[self.t captureOutput:o didOutputSampleBuffer:nb fromConnection:c];CFRelease(nb);if(fd)CFRelease(fd);return;}}if([self.t respondsToSelector:_cmd])[self.t captureOutput:o didOutputSampleBuffer:s fromConnection:c];}
-(void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e{if(_en&&p&&_b){_sync();object_setClass(p,[VCPGhostPhoto class]);}if([self.t respondsToSelector:_cmd])[self.t captureOutput:o didFinishProcessingPhoto:p error:e];}
-(BOOL)respondsToSelector:(SEL)a{return [self.t respondsToSelector:a];}
-(id)forwardingTargetForSelector:(SEL)a{return self.t;}
@end
%hook AVCapturePhotoOutput
-(void)capturePhotoWithSettings:(id)s delegate:(id)d{if(_en&&d&&![d isKindOfClass:[VCPProxy class]]){VCPProxy *p=[[VCPProxy alloc]init];p.t=d;objc_setAssociatedObject(self,@selector(capturePhotoWithSettings:delegate:),p,OBJC_ASSOCIATION_RETAIN_NONATOMIC);%orig(s,p);}else %orig;}
%end
%hook AVCaptureVideoPreviewLayer
-(void)layoutSublayers{%orig;if(!_en)return;self.hidden=YES;if(!_p){NSDictionary *prefs=[NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"];if(prefs){_en=[prefs[@"enabled"] boolValue];_url=prefs[@"rtspURL"]?:_url;}_p=[[AVPlayer alloc]initWithURL:[NSURL URLWithString:_url]];_o=[[AVPlayerItemVideoOutput alloc]initWithPixelBufferAttributes:@{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA)}];[_p.currentItem addOutput:_o];[_p play];AVPlayerLayer *l=[AVPlayerLayer playerLayerWithPlayer:_p];l.videoGravity=AVLayerVideoGravityResizeAspectFill;[self.superlayer insertSublayer:l above:self];objc_setAssociatedObject(self,"_l",l,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[NSTimer scheduledTimerWithTimeInterval:0.03 repeats:YES block:^(NSTimer *t){_sync();}];}AVPlayerLayer *l=objc_getAssociatedObject(self,"_l");if(l)l.frame=self.bounds;}
%end
%ctor{%init;}