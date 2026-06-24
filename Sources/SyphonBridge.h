#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Wraps SyphonOpenGLServer: accepts decoded CVPixelBuffers and publishes them.
@interface SyphonBridge : NSObject
- (instancetype)initWithServerName:(NSString *)name;
- (void)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer;
- (void)stop;
@end
