#import "NDIBridge.h"
#import <Processing.NDI.Lib.h>

@implementation NDIBridge {
    NDIlib_send_instance_t _sender;
    NSLock *_lock;
    // send_video_async_v2 returns immediately and reads our buffer afterwards, so the frame
    // must stay alive until the *next* send (or destroy). Hold the previous one until then.
    CVPixelBufferRef _inFlight;
}

+ (BOOL)ensureRuntime {
    static BOOL ok = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ok = NDIlib_initialize();
        if (!ok) NSLog(@"NDIBridge: NDIlib_initialize failed — CPU may be unsupported");
    });
    return ok;
}

- (instancetype)initWithName:(NSString *)name {
    self = [super init];
    if (!self) return nil;
    if (![NDIBridge ensureRuntime]) return nil;

    _lock = [NSLock new];

    NDIlib_send_create_t desc;
    memset(&desc, 0, sizeof(desc));
    desc.p_ndi_name = name.UTF8String;
    desc.clock_video = false;   // we are already paced by the phone; don't add a second clock
    desc.clock_audio = false;

    _sender = NDIlib_send_create(&desc);
    if (!_sender) {
        NSLog(@"NDIBridge: NDIlib_send_create failed for \"%@\"", name);
        return nil;
    }
    NSLog(@"NDIBridge: started NDI source \"%@\"", name);
    return self;
}

- (void)sendPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!pixelBuffer) return;

    [_lock lock];
    if (!_sender) { [_lock unlock]; return; }

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) {
        [_lock unlock];
        return;
    }

    NDIlib_video_frame_v2_t frame;
    memset(&frame, 0, sizeof(frame));
    frame.xres                 = (int)CVPixelBufferGetWidth(pixelBuffer);
    frame.yres                 = (int)CVPixelBufferGetHeight(pixelBuffer);
    frame.FourCC               = NDIlib_FourCC_type_BGRA;   // matches VideoDecoder's output
    frame.frame_rate_N         = 30000;
    frame.frame_rate_D         = 1001;
    frame.picture_aspect_ratio = 0.0f;                      // 0 = square pixels
    frame.frame_format_type    = NDIlib_frame_format_type_progressive;
    frame.timecode             = NDIlib_send_timecode_synthesize;
    frame.p_data               = (uint8_t *)CVPixelBufferGetBaseAddress(pixelBuffer);
    frame.line_stride_in_bytes = (int)CVPixelBufferGetBytesPerRow(pixelBuffer);

    // Retain before sending; NDI reads it after this call returns.
    CVPixelBufferRetain(pixelBuffer);
    NDIlib_send_send_video_async_v2(_sender, &frame);

    // The previous frame is now guaranteed done with, so release it.
    if (_inFlight) {
        CVPixelBufferUnlockBaseAddress(_inFlight, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(_inFlight);
    }
    _inFlight = pixelBuffer;   // stays locked until the next send retires it

    [_lock unlock];
}

- (void)stop {
    [_lock lock];
    if (_sender) {
        // Flush the async pipeline before tearing down, so NDI isn't left reading a buffer
        // we are about to release.
        NDIlib_send_send_video_async_v2(_sender, NULL);
        NDIlib_send_destroy(_sender);
        _sender = NULL;
    }
    if (_inFlight) {
        CVPixelBufferUnlockBaseAddress(_inFlight, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(_inFlight);
        _inFlight = NULL;
    }
    [_lock unlock];
}

- (void)dealloc {
    [self stop];
}

@end
