- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
    if (!self.isRunning) return;

    [self.imageData appendData:data];

    static const unsigned char startBytes[2] = {0xFF, 0xD8};
    static const unsigned char endBytes[2]   = {0xFF, 0xD9};
    NSData *startMarker = [NSData dataWithBytesNoCopy:(void *)startBytes length:2 freeWhenDone:NO];
    NSData *endMarker   = [NSData dataWithBytesNoCopy:(void *)endBytes   length:2 freeWhenDone:NO];

    // Drain ALL complete JPEG frames in the buffer (a single recv() may contain >1 frame).
    while (YES) {
        NSRange sRange = [self.imageData rangeOfData:startMarker options:0
                                               range:NSMakeRange(0, self.imageData.length)];
        if (sRange.location == NSNotFound) {
            // No start marker yet — keep buffering (but trim if huge garbage prefix).
            if (self.imageData.length > 1 * 1024 * 1024) {
                [self.imageData setLength:0];
                NSLog(@\"[VCamStream] Garbage prefix overflow, cleared\");
            }
            break;
        }

        // Drop garbage before start marker (HTTP boundary headers etc.).
        if (sRange.location > 0) {
            [self.imageData replaceBytesInRange:NSMakeRange(0, sRange.location)
                                      withBytes:NULL length:0];
        }

        // Now start marker is at offset 0. Search end marker after it.
        NSRange eRange = [self.imageData rangeOfData:endMarker options:0
                                               range:NSMakeRange(2, self.imageData.length - 2)];
        if (eRange.location == NSNotFound) {
            break; // frame incomplete — wait for more data
        }

        NSUInteger frameEnd = eRange.location + endMarker.length;
        NSData *jpeg = [self.imageData subdataWithRange:NSMakeRange(0, frameEnd)];

        if (self.pixelBufferCallback) {
            CVPixelBufferRef pb = [self pixelBufferFromJPEGData:jpeg];
            if (pb) {
                self->_frameCount++;
                self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
                self.pixelBufferCallback(pb);
                CVPixelBufferRelease(pb);
            }
        } else if (self.frameCallback) {
            UIImage *image = [UIImage imageWithData:jpeg];
            if (image) {
                self->_frameCount++;
                self->_lastFrameTime = CFAbsoluteTimeGetCurrent();
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.frameCallback(image);
                });
            }
        }

        [self.imageData replaceBytesInRange:NSMakeRange(0, frameEnd)
                                  withBytes:NULL length:0];
    }

    if (self.imageData.length > 10 * 1024 * 1024) {
        [self.imageData setLength:0];
        NSLog(@\"[VCamStream] Buffer overflow, cleared\");
    }
}
