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

// H.264 passthrough (NDI Advanced SDK builds only). Forwards the phone's already-compressed
// frame instead of re-encoding to SpeedHQ. Returns NO if this build has no Advanced SDK.
- (BOOL)sendCompressed:(NSData *)frame
                 extra:(NSData *)parameterSets
              keyframe:(BOOL)isKeyframe
                 width:(int)width
                height:(int)height;

// YES if this build can do H.264 passthrough at all.
+ (BOOL)supportsCompressed;

// Frame rate declared on every outgoing NDI frame. Receivers clock off this, so it has to
// follow the phone's actual capture rate rather than a hardcoded 30 — a 60fps stream
// announced as 30 makes the consumer pace frames at half speed. Defaults to 30.
- (void)setDeclaredFrameRate:(int)fps;

- (void)stop;

@end
