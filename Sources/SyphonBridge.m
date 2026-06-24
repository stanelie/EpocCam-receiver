#import "SyphonBridge.h"
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <IOSurface/IOSurface.h>
#import <Syphon/SyphonOpenGLServer.h>

@implementation SyphonBridge {
    CGLContextObj        _ctx;
    SyphonOpenGLServer  *_server;
    GLuint               _texture;
    NSUInteger           _texW, _texH;
}

- (instancetype)initWithServerName:(NSString *)name {
    self = [super init];
    if (!self) return nil;

    // Create a headless CGL context
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAAccelerated,
        kCGLPFAColorSize, 32,
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_3_2_Core,
        (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pf = NULL;
    GLint npix = 0;
    if (CGLChoosePixelFormat(attrs, &pf, &npix) != kCGLNoError) {
        NSLog(@"SyphonBridge: CGLChoosePixelFormat failed");
        return nil;
    }
    CGLCreateContext(pf, NULL, &_ctx);
    CGLDestroyPixelFormat(pf);

    CGLSetCurrentContext(_ctx);
    _server = [[SyphonOpenGLServer alloc] initWithName:name context:_ctx options:nil];
    CGLSetCurrentContext(NULL);

    if (!_server) {
        NSLog(@"SyphonBridge: SyphonOpenGLServer init failed");
        return nil;
    }
    NSLog(@"SyphonBridge: started server \"%@\"", name);
    return self;
}

- (void)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    if (!_server || !pixelBuffer) return;

    IOSurfaceRef surface = CVPixelBufferGetIOSurface(pixelBuffer);
    if (!surface) {
        NSLog(@"SyphonBridge: no IOSurface on pixel buffer – skipping");
        return;
    }

    NSUInteger w = CVPixelBufferGetWidth(pixelBuffer);
    NSUInteger h = CVPixelBufferGetHeight(pixelBuffer);

    CGLSetCurrentContext(_ctx);
    CGLLockContext(_ctx);

    // Recreate texture if dimensions changed
    if (_texture == 0 || _texW != w || _texH != h) {
        if (_texture) { glDeleteTextures(1, &_texture); _texture = 0; }
        glGenTextures(1, &_texture);
        _texW = w; _texH = h;
    }

    glBindTexture(GL_TEXTURE_RECTANGLE, _texture);
    CGLTexImageIOSurface2D(
        _ctx,
        GL_TEXTURE_RECTANGLE,
        GL_RGBA8,
        (GLsizei)w, (GLsizei)h,
        GL_BGRA,
        GL_UNSIGNED_INT_8_8_8_8_REV,
        surface, 0
    );
    glBindTexture(GL_TEXTURE_RECTANGLE, 0);

    [_server publishFrameTexture:_texture
                   textureTarget:GL_TEXTURE_RECTANGLE
                     imageRegion:NSMakeRect(0, 0, w, h)
               textureDimensions:NSMakeSize(w, h)
                         flipped:NO];

    CGLUnlockContext(_ctx);
    CGLSetCurrentContext(NULL);
}

- (void)stop {
    [_server stop];
    _server = nil;
    if (_texture) { glDeleteTextures(1, &_texture); _texture = 0; }
    if (_ctx) { CGLDestroyContext(_ctx); _ctx = NULL; }
}

@end
