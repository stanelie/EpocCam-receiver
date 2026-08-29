#import "NDIBridge.h"
#if NDI_ADVANCED
#import <Processing.NDI.Advanced.h>
#else
#import <Processing.NDI.Lib.h>
#endif

@implementation NDIBridge {
    NDIlib_send_instance_t _sender;
    NSLock *_lock;
    int64_t _frameIndex;   // drives monotonic pts/dts; only ordering matters to NDI
    // Async send hands NDI a pointer it reads after returning; the SDK documents the next
    // async send as the synchronizing event, so the previous frame is held until then.
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
    NSLog(@"NDIBridge: started NDI source \"%@\"%@", name,
          [NDIBridge supportsCompressed] ? @" (Advanced SDK build)" : @"");
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

    // Asynchronous, and that matters for latency: the SDK pipelines colour conversion,
    // compression and network send across its own threads, which it explicitly recommends
    // for BGRA. Sending synchronously here serialises all of that inline and measurably
    // added ~1s of lag versus Syphon. Per the SDK docs the next async send is a
    // synchronizing event, so the previous frame is safe to release at that point.
    CVPixelBufferRetain(pixelBuffer);
    NDIlib_send_send_video_async_v2(_sender, &frame);

    if (_inFlight) {
        CVPixelBufferUnlockBaseAddress(_inFlight, kCVPixelBufferLock_ReadOnly);
        CVPixelBufferRelease(_inFlight);
    }
    _inFlight = pixelBuffer;   // stays locked until the next send retires it

    [_lock unlock];
}

+ (BOOL)supportsCompressed {
#if NDI_ADVANCED
    return YES;
#else
    return NO;
#endif
}

- (BOOL)sendCompressed:(NSData *)frame
                 extra:(NSData *)parameterSets
              keyframe:(BOOL)isKeyframe
                 width:(int)width
                height:(int)height {
#if !NDI_ADVANCED
    (void)frame; (void)parameterSets; (void)isKeyframe; (void)width; (void)height;
    return NO;
#else
    if (!frame.length || width <= 0 || height <= 0) return NO;

    [_lock lock];
    if (!_sender) { [_lock unlock]; return NO; }

    // NDI wants 100ns units. Only ordering matters to it, so a monotonic counter at the
    // nominal frame rate is sufficient and avoids trusting the phone's timestamps (which
    // use a 0xFFFFFFFF "display immediately" sentinel).
    const int64_t step = 10000000LL * 1001 / 30000;
    int64_t ts = (_frameIndex++) * step;

    NDIlib_compressed_packet_t pkt;
    memset(&pkt, 0, sizeof(pkt));
    pkt.version         = sizeof(NDIlib_compressed_packet_t);
    pkt.fourCC          = NDIlib_compressed_FourCC_type_H264;
    pkt.pts             = ts;
    pkt.dts             = ts;
    pkt.flags           = isKeyframe ? 1 /* flags_keyframe */ : 0;
    pkt.data_size       = (uint32_t)frame.length;
    pkt.extra_data_size = (uint32_t)(isKeyframe ? parameterSets.length : 0);

    NDIlib_video_frame_v2_t v;
    memset(&v, 0, sizeof(v));
    v.xres                 = width;
    v.yres                 = height;
    v.FourCC               = (NDIlib_FourCC_video_type_e)NDIlib_FourCC_video_type_ex_H264_highest_bandwidth;
    v.frame_rate_N         = 30000;
    v.frame_rate_D         = 1001;
    v.picture_aspect_ratio = 0.0f;
    v.frame_format_type    = NDIlib_frame_format_type_progressive;
    v.timecode             = NDIlib_send_timecode_synthesize;
    v.p_data               = NULL;   // the scatter list below supplies the bytes
    v.data_size_in_bytes   = 0;

    // header + frame + (keyframe only) SPS/PPS, NULL-terminated as the SDK requires.
    const uint8_t* blocks[4];
    int            sizes[4];
    int n = 0;
    blocks[n] = (const uint8_t*)&pkt;         sizes[n++] = (int)sizeof(pkt);
    blocks[n] = (const uint8_t*)frame.bytes;  sizes[n++] = (int)frame.length;
    if (pkt.extra_data_size) {
        blocks[n] = (const uint8_t*)parameterSets.bytes; sizes[n++] = (int)parameterSets.length;
    }
    blocks[n] = NULL; sizes[n] = 0;

    NDIlib_frame_scatter_t scatter;
    scatter.p_data_blocks      = blocks;
    scatter.p_data_blocks_size = sizes;

    // Synchronous, for the same reason as above: the scatter blocks point at caller memory.
    NDIlib_send_send_video_scatter(_sender, &v, &scatter);

    [_lock unlock];
    return YES;
#endif
}

- (void)stop {
    [_lock lock];
    if (_sender) {
        // Flush the async pipeline before teardown so NDI isn't left reading a buffer we
        // are about to release.
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
