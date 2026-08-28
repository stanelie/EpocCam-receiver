#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

// Publishes decoded frames as an NDI source, alongside (not instead of) Syphon.
//
// Syphon binds the frame's IOSurface directly as a GL texture — zero-copy, and the right
// answer for a consumer that speaks it. NDI exists for consumers that don't: it re-encodes
// (SpeedHQ) so the receiver can decode again, which costs real latency even on one machine.
// Kept behind a toggle so it costs nothing when unused.
@interface NDIBridge : NSObject

// Returns nil if the NDI runtime is unavailable or the sender can't be created.
- (instancetype)initWithName:(NSString *)name;

// Safe to call from any thread; internally serialised. Expects 32BGRA, which is what
// VideoDecoder already produces, so there is no pixel conversion on this path.
- (void)sendPixelBuffer:(CVPixelBufferRef)pixelBuffer;

- (void)stop;

@end
