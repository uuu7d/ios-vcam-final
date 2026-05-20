#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>

static BOOL _en = YES;
static NSString *_url = @"http://192.168.1.44:8888/live/stream/index.m3u8";
static AVPlayer *_p = nil;
static AVPlayerItemVideoOutput *_o = nil;
static CVPixelBufferRef _b = NULL;
static CIContext *_c = nil;

static void _sync() {
    if (!_o || !_en || !_p) return;
    CMTime t = [_p currentItem currentTime];
    if ([_o hasNewPixelBufferForItemTime:t]) {
        CVPixelBufferRef pb = [_o copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
        if (pb) {
            if (_b) CVPixelBufferRelease(_b);
            _b = pb;
        }
    }
}

@interface VCPInternalPhoto : AVCapturePhoto
@end
@implementation VCPInternalPhoto
- (CVPixelBufferRef)pixelBuffer { _sync(); return _b ? CVPixelBufferRetain(_b) : NULL; }
- (CVPixelBufferRef)previewPixelBuffer { _sync(); return _b ? CVPixelBufferRetain(_b) : NULL; }
- (CGImageRef)CGImageRepresentation {
    _sync(); if (!_b) return NULL;
    if (!_c) _c = [[CIContext alloc] initWithOptions:nil];
    return [_c createCGImage:[CIImage imageWithCVPixelBuffer:_b] fromRect:CGRectMake(0,0,CVPixelBufferGetWidth(_b),CVPixelBufferGetHeight(_b))];}
- (CGImageRef)previewCGImageRepresentation { return [self CGImageRepresentation]; }
- (NSData *)fileDataRepresentation {
    _sync(); CGImageRef cg = [self CGImageRepresentation;
    if (!cg) return nil;
    NSData *d = UIImageJPEGRepresentation([UIImage imageWithCGImage:cg], 0.9);
    CGRelease(cg); return d;
}
- (NSDictionary *)metadata { return @{}; }
AEnd

@interface VCPInternalPrİxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate, AVCapturePhotoCaptureDelegate>
@property (nonatomic, strong) id _target;
AEnd
@implementation VCPInternalProxy
- (void)captureOutput:(id)o didOutputSampleBuffer:(CMSampleBufferRef)s fromConnection:(id)c {
    if (_en && _b) {
        _sync();
        CSSampleBufferRef nb = NULL; CMVideoFormatDescriptionRef fd = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(NULL, _b, &fd);
        CMSampleTimingInfo ti;#CMSampleBufferGetSampleTimingInfo(s, 0, &ti);
        CSSampleBufferCreateForImageBuffer(kCFAllocatorDefault, _b, YES, NULL, NULL, fd, &ti, &nb);
        if (nb) {
            if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didOutputSampleBuffer:nb fromConnection:c];
            CFRelease(nb); if (fd) CFRelease(fd); return;
        }
    }
    if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didOutputSampleBuffer:s fromConnection:c];
}
- (void)captureOutput:(id)o didFinishProcessingPhoto:(id)p error:(id)e {
    if (_en && p && _b) { _sync(); object_setClass(p, [VCPInternalPhoto class]); }
    if ([self._target respondsToSelector:_cmd]) [self._target captureOutput:o didFinishProcessingPhoto:p error:e];
}
- (BOOL)respondsToSelector:(SEL)a { return [self._target respondsToSelector:a]; }
- (id)forwardingTargetForSelector:(SEL)a { return self._target; }
@end

%hook AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id)d queue:(id)q {
    if (_en && d && ![d isKnindOfClass:[VCPInternalProxy class]]) {
        VCPInternalProxy *p = [[VCPInternalProxy alloc] init]; p._target = d;
        objc_setAssociatedObject(self, @selector(setSampleBufferDelegate:queue:), p, OBJC_ASSOCIATION_RETAIN_NONATONIC);
        %orig(p, q);
    } else { %orig; }
}
%end

%hook AVCapturePhotoOutput
- (void)capturePhotoWithSettings:(id)s delegate:(id)d {
    if (_en )¦XtnÈ	‰ˆVÙ\ÒÚ[™ÙÛ\ÜÎ–ÕÔ[\›˜[·^HÛ\Ü×WJHÂˆÔ[\›˜[·^H
œHÖÕÔ[\›˜[·^H[Ø×H[š]NÈ—İ\™Ù]HÂˆØš˜×ÜÙ]\ÜÛØÚX]YØš™Xİ
Ù[‹Ù[XİÜŠØ\\™TİÕÚ]Ù][™ÜÎ™[YØ]NŠKĞ’×ĞTÔÓĞÒPUSÓ—Ô‘URS—Ó“ÓUÓRPÊNÂˆ	[ÜšYÊË
NÂˆH[ÙHÈ	[ÜšYÎÈB‰Y[™‚‰ZÛÚÈUØ\\™UšY[Ô™]šY]Ó^Y\‚‹H
›ÚY
[^[İ]İX›^Y\œÈÂˆ	[ÜšYÎÈYˆ
WÙ[ŠH™]\›ÈÙ[‹šY[ˆHQTÎÂˆYˆ
WÜ
HÂˆ”ÑXİ[Û˜\H
œ™YœÈHÓ”ÑXİ[Û˜\HXİ[Û˜\UÚ]ÛÛ[ÓÙ‘š[N‹İ˜\‹Û[Øš[KÓXœ˜\KÔ™Y™\™[˜Ù\ËØÛÛK›]\šØ\ÚØKš\X[Ø[\›Ëœ\İ—NÂˆYˆ
™YœÊHÈÙ[ˆHÜ™YœÖĞ™[˜X›Y—H›ÛÛ˜[YWNÈİ\›H™YœÖĞœÜT“—HÎˆİ\›ÈBˆÜHÖĞ”^Y\ˆ[Ø×H[š]Ú]T“–Ó”ÕT“T“Ú]İš[™Î—İ\›WNÂˆÛÈHÖĞ”^Y\’][UšY[Óİ]][Ø×H[š]Ú]^[Y™™\]šX]\ÎÊY
ZĞÕOš^[Y™™\”^[›Ü›X]\RÙ^Nˆ
ĞÕ”^[›Ü›X]\WÌÌ‘ÔJ_WNÂˆ×Üİ\œ™[][HYİ]]—Û×NÈ×Ü^WNÂˆU”^Y\“^Y\ˆ
›HĞU”^Y\“^Y\ˆ^Y\“^Y\•Ú]^Y\—ÜNÂˆšY[ÑÜ˜]š]HHU“^Y\•šY[ÑÜX]š]T™\Ú^™P\ÜXİš[ÂˆÜÙ[‹œİ\\›^Y\ˆ[œÙ\İX›^Y\›X›İ™NœÙ[—NÂˆØš˜×ÜÙ]\ÜÛØÚX]YØš™Xİ
Ù[‹Ù[XİÜŠ^[İ]İX›^Y\œÊKĞ’×ĞTÔÓĞÒPUSÓ—Ô‘URS—Ó“ÓUÓ’PÊNÂˆÓ”Õ[Y\ˆØÚY[Y[Y\•Ú][YR[\˜[ŒŒÈ™\X]Î–QTÈ›ØÚÎ—Š”Õ[Y\ˆ

HÈÜŞ[˜Ê
NÈ];
    }
    AVPlayerLayer *l = objc_getAssociatedObject(self, @selector(layoutSublayers));
    if (l) l.frame = self.bounds;
}
%end

%ktost { %init; }
