- (void)displayLinkCallback:(CADisplayLink *)sender {
    if (!self.isRunning) return;

    AVPlayer *player = self.hlsPlayer;
    AVPlayerItemVideoOutput *output = self.videoOutput;
    if (!player || !output) return;

    CMTime currentTime = [player currentTime];
    if (![output hasNewPixelBufferForItemTime:currentTime]) return;

    CVPixelBufferRef pixelBuffer = [output copyPixelBufferForItemTime:currentTime itemTimeForDisplay:nil];
    if (!pixelBuffer) return;

    self->_frameCount++;
    self->_lastFrameTime = CFAbsoluteTimeGetCurrent();

    if (self.pixelBufferCallback) {
        self.pixelBufferCallback(pixelBuffer);
        CVPixelBufferRelease(pixelBuffer);
        return;
    }

    if (self.frameCallback) {
        CIImage *ciImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
        CIContext *ctx = [CIContext contextWithOptions:nil];
        CGImageRef cgImage = [ctx createCGImage:ciImage fromRect:ciImage.extent];
        UIImage *image = cgImage ? [UIImage imageWithCGImage:cgImage] : nil;
        if (cgImage) CGImageRelease(cgImage);
        CVPixelBufferRelease(pixelBuffer);

        if (image) {
            self.frameCallback(image);
        }
    } else {
        CVPixelBufferRelease(pixelBuffer);
    }
}
