/// Bitmap font text rendering and FPS counter.
/// Embeds an 8×8 pixel font atlas covering ASCII 32-127.
module engine.gpu.text;

import bindings.wgpu;
import bindings.sdl3;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline;
import engine.gpu.renderer : FrameContext;
import engine.core.log;

@safe:

// ---------------------------------------------------------------------------
// Embedded 8×8 bitmap font — CP437-style, ASCII 32-127 (96 glyphs)
// Atlas layout: 16 chars/row × 6 rows = 128×48 pixels (R8Unorm)
// ---------------------------------------------------------------------------
private enum GLYPH_W  = 8;
private enum GLYPH_H  = 8;
private enum ATLAS_COLS = 16;
private enum ATLAS_ROWS = 6;
private enum ATLAS_W   = ATLAS_COLS * GLYPH_W; // 128
private enum ATLAS_H   = ATLAS_ROWS * GLYPH_H; // 48

// Each glyph is 8 bytes (8 rows of 8 bits each, MSB = leftmost pixel).
// 96 glyphs: ASCII 32 (space) through 127 (DEL).
private static immutable ubyte[8][96] fontData = [
    // 32 SPACE
    [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00],
    // 33 !
    [0x18,0x18,0x18,0x18,0x18,0x00,0x18,0x00],
    // 34 "
    [0x6C,0x6C,0x6C,0x00,0x00,0x00,0x00,0x00],
    // 35 #
    [0x6C,0x6C,0xFE,0x6C,0xFE,0x6C,0x6C,0x00],
    // 36 $
    [0x18,0x7E,0xC0,0x7C,0x06,0xFC,0x18,0x00],
    // 37 %
    [0x00,0xC6,0xCC,0x18,0x30,0x66,0xC6,0x00],
    // 38 &
    [0x38,0x6C,0x38,0x76,0xDC,0xCC,0x76,0x00],
    // 39 '
    [0x18,0x18,0x30,0x00,0x00,0x00,0x00,0x00],
    // 40 (
    [0x0C,0x18,0x30,0x30,0x30,0x18,0x0C,0x00],
    // 41 )
    [0x30,0x18,0x0C,0x0C,0x0C,0x18,0x30,0x00],
    // 42 *
    [0x00,0x66,0x3C,0xFF,0x3C,0x66,0x00,0x00],
    // 43 +
    [0x00,0x18,0x18,0x7E,0x18,0x18,0x00,0x00],
    // 44 ,
    [0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x30],
    // 45 -
    [0x00,0x00,0x00,0x7E,0x00,0x00,0x00,0x00],
    // 46 .
    [0x00,0x00,0x00,0x00,0x00,0x18,0x18,0x00],
    // 47 /
    [0x06,0x0C,0x18,0x30,0x60,0xC0,0x80,0x00],
    // 48 0
    [0x7C,0xC6,0xCE,0xD6,0xE6,0xC6,0x7C,0x00],
    // 49 1
    [0x18,0x38,0x18,0x18,0x18,0x18,0x7E,0x00],
    // 50 2
    [0x7C,0xC6,0x06,0x1C,0x30,0x66,0xFE,0x00],
    // 51 3
    [0x7C,0xC6,0x06,0x3C,0x06,0xC6,0x7C,0x00],
    // 52 4
    [0x1C,0x3C,0x6C,0xCC,0xFE,0x0C,0x1E,0x00],
    // 53 5
    [0xFE,0xC0,0xFC,0x06,0x06,0xC6,0x7C,0x00],
    // 54 6
    [0x38,0x60,0xC0,0xFC,0xC6,0xC6,0x7C,0x00],
    // 55 7
    [0xFE,0xC6,0x0C,0x18,0x30,0x30,0x30,0x00],
    // 56 8
    [0x7C,0xC6,0xC6,0x7C,0xC6,0xC6,0x7C,0x00],
    // 57 9
    [0x7C,0xC6,0xC6,0x7E,0x06,0x0C,0x78,0x00],
    // 58 :
    [0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x00],
    // 59 ;
    [0x00,0x18,0x18,0x00,0x00,0x18,0x18,0x30],
    // 60 <
    [0x06,0x0C,0x18,0x30,0x18,0x0C,0x06,0x00],
    // 61 =
    [0x00,0x00,0x7E,0x00,0x00,0x7E,0x00,0x00],
    // 62 >
    [0x60,0x30,0x18,0x0C,0x18,0x30,0x60,0x00],
    // 63 ?
    [0x7C,0xC6,0x0C,0x18,0x18,0x00,0x18,0x00],
    // 64 @
    [0x7C,0xC6,0xDE,0xDE,0xDE,0xC0,0x78,0x00],
    // 65 A
    [0x38,0x6C,0xC6,0xFE,0xC6,0xC6,0xC6,0x00],
    // 66 B
    [0xFC,0x66,0x66,0x7C,0x66,0x66,0xFC,0x00],
    // 67 C
    [0x3C,0x66,0xC0,0xC0,0xC0,0x66,0x3C,0x00],
    // 68 D
    [0xF8,0x6C,0x66,0x66,0x66,0x6C,0xF8,0x00],
    // 69 E
    [0xFE,0x62,0x68,0x78,0x68,0x62,0xFE,0x00],
    // 70 F
    [0xFE,0x62,0x68,0x78,0x68,0x60,0xF0,0x00],
    // 71 G
    [0x3C,0x66,0xC0,0xC0,0xCE,0x66,0x3E,0x00],
    // 72 H
    [0xC6,0xC6,0xC6,0xFE,0xC6,0xC6,0xC6,0x00],
    // 73 I
    [0x3C,0x18,0x18,0x18,0x18,0x18,0x3C,0x00],
    // 74 J
    [0x1E,0x0C,0x0C,0x0C,0xCC,0xCC,0x78,0x00],
    // 75 K
    [0xE6,0x66,0x6C,0x78,0x6C,0x66,0xE6,0x00],
    // 76 L
    [0xF0,0x60,0x60,0x60,0x62,0x66,0xFE,0x00],
    // 77 M
    [0xC6,0xEE,0xFE,0xFE,0xD6,0xC6,0xC6,0x00],
    // 78 N
    [0xC6,0xE6,0xF6,0xDE,0xCE,0xC6,0xC6,0x00],
    // 79 O
    [0x7C,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00],
    // 80 P
    [0xFC,0x66,0x66,0x7C,0x60,0x60,0xF0,0x00],
    // 81 Q
    [0x7C,0xC6,0xC6,0xC6,0xD6,0xDE,0x7C,0x0E],
    // 82 R
    [0xFC,0x66,0x66,0x7C,0x6C,0x66,0xE6,0x00],
    // 83 S
    [0x7C,0xC6,0xE0,0x7C,0x0E,0xC6,0x7C,0x00],
    // 84 T
    [0x7E,0x7E,0x5A,0x18,0x18,0x18,0x3C,0x00],
    // 85 U
    [0xC6,0xC6,0xC6,0xC6,0xC6,0xC6,0x7C,0x00],
    // 86 V
    [0xC6,0xC6,0xC6,0xC6,0x6C,0x38,0x10,0x00],
    // 87 W
    [0xC6,0xC6,0xD6,0xFE,0xFE,0xEE,0xC6,0x00],
    // 88 X
    [0xC6,0xC6,0x6C,0x38,0x6C,0xC6,0xC6,0x00],
    // 89 Y
    [0x66,0x66,0x66,0x3C,0x18,0x18,0x3C,0x00],
    // 90 Z
    [0xFE,0xC6,0x8C,0x18,0x32,0x66,0xFE,0x00],
    // 91 [
    [0x3C,0x30,0x30,0x30,0x30,0x30,0x3C,0x00],
    // 92 backslash
    [0xC0,0x60,0x30,0x18,0x0C,0x06,0x02,0x00],
    // 93 ]
    [0x3C,0x0C,0x0C,0x0C,0x0C,0x0C,0x3C,0x00],
    // 94 ^
    [0x10,0x38,0x6C,0xC6,0x00,0x00,0x00,0x00],
    // 95 _
    [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0xFF],
    // 96 `
    [0x30,0x18,0x0C,0x00,0x00,0x00,0x00,0x00],
    // 97 a
    [0x00,0x00,0x78,0x0C,0x7C,0xCC,0x76,0x00],
    // 98 b
    [0xE0,0x60,0x7C,0x66,0x66,0x66,0xDC,0x00],
    // 99 c
    [0x00,0x00,0x7C,0xC6,0xC0,0xC6,0x7C,0x00],
    // 100 d
    [0x1C,0x0C,0x7C,0xCC,0xCC,0xCC,0x76,0x00],
    // 101 e
    [0x00,0x00,0x7C,0xC6,0xFE,0xC0,0x7C,0x00],
    // 102 f
    [0x38,0x6C,0x60,0xF8,0x60,0x60,0xF0,0x00],
    // 103 g
    [0x00,0x00,0x76,0xCC,0xCC,0x7C,0x0C,0xF8],
    // 104 h
    [0xE0,0x60,0x6C,0x76,0x66,0x66,0xE6,0x00],
    // 105 i
    [0x18,0x00,0x38,0x18,0x18,0x18,0x3C,0x00],
    // 106 j
    [0x06,0x00,0x06,0x06,0x06,0x66,0x66,0x3C],
    // 107 k
    [0xE0,0x60,0x66,0x6C,0x78,0x6C,0xE6,0x00],
    // 108 l
    [0x38,0x18,0x18,0x18,0x18,0x18,0x3C,0x00],
    // 109 m
    [0x00,0x00,0xEC,0xFE,0xD6,0xD6,0xD6,0x00],
    // 110 n
    [0x00,0x00,0xDC,0x66,0x66,0x66,0x66,0x00],
    // 111 o
    [0x00,0x00,0x7C,0xC6,0xC6,0xC6,0x7C,0x00],
    // 112 p
    [0x00,0x00,0xDC,0x66,0x66,0x7C,0x60,0xF0],
    // 113 q
    [0x00,0x00,0x76,0xCC,0xCC,0x7C,0x0C,0x1E],
    // 114 r
    [0x00,0x00,0xDC,0x76,0x60,0x60,0xF0,0x00],
    // 115 s
    [0x00,0x00,0x7E,0xC0,0x7C,0x06,0xFC,0x00],
    // 116 t
    [0x30,0x30,0xFC,0x30,0x30,0x36,0x1C,0x00],
    // 117 u
    [0x00,0x00,0xCC,0xCC,0xCC,0xCC,0x76,0x00],
    // 118 v
    [0x00,0x00,0xC6,0xC6,0xC6,0x6C,0x38,0x00],
    // 119 w
    [0x00,0x00,0xC6,0xD6,0xD6,0xFE,0x6C,0x00],
    // 120 x
    [0x00,0x00,0xC6,0x6C,0x38,0x6C,0xC6,0x00],
    // 121 y
    [0x00,0x00,0xC6,0xC6,0xCE,0x76,0x06,0xFC],
    // 122 z
    [0x00,0x00,0xFC,0x98,0x30,0x64,0xFC,0x00],
    // 123 {
    [0x0E,0x18,0x18,0x70,0x18,0x18,0x0E,0x00],
    // 124 |
    [0x18,0x18,0x18,0x00,0x18,0x18,0x18,0x00],
    // 125 }
    [0x70,0x18,0x18,0x0E,0x18,0x18,0x70,0x00],
    // 126 ~
    [0x76,0xDC,0x00,0x00,0x00,0x00,0x00,0x00],
    // 127 DEL (blank)
    [0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00],
];

// ---------------------------------------------------------------------------
// TextRenderer — manages font atlas GPU resources and draws text
// ---------------------------------------------------------------------------
struct TextRenderer {
    private WGPUTexture  fontTexture;
    private WGPUTextureView fontTextureView;
    private WGPUSampler  fontSampler;
    private WGPUBuffer   textVertexBuf;
    private WGPUBuffer   textUniformBuf;
    private WGPUBindGroup textBindGroup;
    private PipelineText textPipeline;
    private WGPUDevice   device;
    private WGPUQueue    queue;
    private uint screenW, screenH;
    private size_t frameVertexOffset = 0;  // bytes used so far this frame

    enum MAX_CHARS = 256;
    // 6 vertices per char (2 triangles), 4 floats per vertex (x,y,u,v)
    enum VERTEX_BUF_SIZE = MAX_CHARS * 6 * 4 * float.sizeof;

    @disable this(this);

    /// Convenience: create from a GpuContext.
    static TextRenderer create(ref GpuContext gpu, uint screenW, uint screenH) @trusted {
        return create(gpu.getDevice(), gpu.getQueue(), gpu.getFormat(), screenW, screenH);
    }

    static TextRenderer create(WGPUDevice device, WGPUQueue queue,
                               WGPUTextureFormat surfaceFormat,
                               uint screenW, uint screenH) @trusted {
        TextRenderer t;
        t.device  = device;
        t.queue   = queue;
        t.screenW = screenW;
        t.screenH = screenH;

        // 1. Create font atlas texture (R8Unorm)
        t.createFontAtlas();

        // 2. Create sampler (nearest for pixel-perfect)
        WGPUSamplerDescriptor sampDesc;
        sampDesc.magFilter = WGPUFilterMode.nearest;
        sampDesc.minFilter = WGPUFilterMode.nearest;
        t.fontSampler = wgpuDeviceCreateSampler(device, &sampDesc);

        // 3. Create text pipeline
        t.textPipeline = createPipelineText(device, surfaceFormat);

        // 4. Create vertex buffer (dynamic, re-uploaded each frame)
        t.textVertexBuf = createDynamicVertexBuffer(device, VERTEX_BUF_SIZE);

        // 5. Create uniform buffer (screen size: 2 floats)
        t.textUniformBuf = createUniformBuffer(device, 8);
        float[2] screenSize = [cast(float) screenW, cast(float) screenH];
        wgpuQueueWriteBuffer(queue, t.textUniformBuf, 0,
                             screenSize.ptr, screenSize.sizeof);

        // 6. Create bind group
        WGPUBindGroupEntry[3] bgEntries;
        bgEntries[0].binding = 0;
        bgEntries[0].buffer = t.textUniformBuf;
        bgEntries[0].offset = 0;
        bgEntries[0].size   = 8;

        bgEntries[1].binding = 1;
        bgEntries[1].sampler = t.fontSampler;

        bgEntries[2].binding = 2;
        bgEntries[2].textureView = t.fontTextureView;

        WGPUBindGroupDescriptor bgDesc;
        bgDesc.layout = t.textPipeline.bindGroupLayout;
        bgDesc.entryCount = 3;
        bgDesc.entries = bgEntries.ptr;
        t.textBindGroup = wgpuDeviceCreateBindGroup(device, &bgDesc);

        info("TextRenderer initialized");
        return t;
    }

    /// Call once per frame before any drawText calls to reset the vertex offset.
    void beginFrame() nothrow @nogc {
        frameVertexOffset = 0;
    }

    private void createFontAtlas() nothrow @nogc @trusted {
        // Rasterize font data into pixel buffer
        ubyte[ATLAS_W * ATLAS_H] pixels = 0;

        foreach (glyphIdx; 0 .. 96) {
            immutable col = glyphIdx % ATLAS_COLS;
            immutable row = glyphIdx / ATLAS_COLS;

            foreach (py; 0 .. GLYPH_H) {
                immutable rowBits = fontData[glyphIdx][py];
                foreach (px; 0 .. GLYPH_W) {
                    immutable bit = (rowBits >> (7 - px)) & 1;
                    immutable x = col * GLYPH_W + px;
                    immutable y = row * GLYPH_H + py;
                    pixels[y * ATLAS_W + x] = bit ? 0xFF : 0x00;
                }
            }
        }

        // Create texture
        WGPUTextureDescriptor texDesc;
        texDesc.usage     = WGPUTextureUsage.textureBinding | WGPUTextureUsage.copyDst;
        texDesc.dimension = WGPUTextureDimension.dim2D;
        texDesc.size      = WGPUExtent3D(ATLAS_W, ATLAS_H, 1);
        texDesc.format    = WGPUTextureFormat.r8Unorm;
        fontTexture = wgpuDeviceCreateTexture(device, &texDesc);

        // Upload pixels
        WGPUImageCopyTexture dst;
        dst.texture = fontTexture;
        WGPUTextureDataLayout layout;
        layout.bytesPerRow = ATLAS_W;
        layout.rowsPerImage = ATLAS_H;
        WGPUExtent3D writeSize = WGPUExtent3D(ATLAS_W, ATLAS_H, 1);
        wgpuQueueWriteTexture(queue, &dst, pixels.ptr, pixels.length, &layout, &writeSize);

        // Create view
        WGPUTextureViewDescriptor viewDesc;
        viewDesc.format    = WGPUTextureFormat.r8Unorm;
        viewDesc.dimension = WGPUTextureViewDimension.dim2D;
        fontTextureView = wgpuTextureCreateView(fontTexture, &viewDesc);
    }

    /// Draw a text string at pixel position (x, y) using a FrameContext.
    void drawText(ref FrameContext frame, scope const(char)[] text,
                  float x, float y, int scale = 2) nothrow @nogc {
        if (frame.valid) drawText(frame.pass, text, x, y, scale);
    }

    /// Draw a text string at pixel position (x, y) using the given render pass.
    /// Scale controls glyph size multiplier (1 = 8px, 2 = 16px, etc.)
    void drawText(WGPURenderPassEncoder pass, scope const(char)[] text,
                  float x, float y, int scale = 2) nothrow @nogc @trusted {
        if (text.length == 0 || pass is null) return;

        immutable len = text.length > MAX_CHARS ? MAX_CHARS : text.length;
        immutable glyphW = cast(float)(GLYPH_W * scale);
        immutable glyphH = cast(float)(GLYPH_H * scale);

        // Build vertex data: 6 verts per char (2 triangles), 4 floats each (x,y,u,v)
        float[MAX_CHARS * 6 * 4] verts = void;
        size_t vi = 0;
        float curX = x;

        foreach (i; 0 .. len) {
            immutable ch = text[i];
            if (ch < 32 || ch > 127) continue;
            immutable glyphIdx = ch - 32;
            immutable col = glyphIdx % ATLAS_COLS;
            immutable row = glyphIdx / ATLAS_COLS;

            // UV coordinates in atlas
            immutable u0 = cast(float)(col * GLYPH_W) / cast(float) ATLAS_W;
            immutable v0 = cast(float)(row * GLYPH_H) / cast(float) ATLAS_H;
            immutable u1 = cast(float)((col + 1) * GLYPH_W) / cast(float) ATLAS_W;
            immutable v1 = cast(float)((row + 1) * GLYPH_H) / cast(float) ATLAS_H;

            immutable x0 = curX;
            immutable y0 = y;
            immutable x1 = curX + glyphW;
            immutable y1 = y + glyphH;

            // Triangle 1
            verts[vi++] = x0; verts[vi++] = y0; verts[vi++] = u0; verts[vi++] = v0;
            verts[vi++] = x1; verts[vi++] = y0; verts[vi++] = u1; verts[vi++] = v0;
            verts[vi++] = x0; verts[vi++] = y1; verts[vi++] = u0; verts[vi++] = v1;
            // Triangle 2
            verts[vi++] = x1; verts[vi++] = y0; verts[vi++] = u1; verts[vi++] = v0;
            verts[vi++] = x1; verts[vi++] = y1; verts[vi++] = u1; verts[vi++] = v1;
            verts[vi++] = x0; verts[vi++] = y1; verts[vi++] = u0; verts[vi++] = v1;

            curX += glyphW;
        }

        if (vi == 0) return;

        immutable vertexBytes = vi * float.sizeof;

        // Check we don't overflow the vertex buffer
        if (frameVertexOffset + vertexBytes > VERTEX_BUF_SIZE) return;

        wgpuQueueWriteBuffer(queue, textVertexBuf, frameVertexOffset, verts.ptr, vertexBytes);

        wgpuRenderPassEncoderSetPipeline(pass, textPipeline.pipeline);
        wgpuRenderPassEncoderSetBindGroup(pass, 0, textBindGroup, 0, null);
        wgpuRenderPassEncoderSetVertexBuffer(pass, 0, textVertexBuf, frameVertexOffset, vertexBytes);
        wgpuRenderPassEncoderDraw(pass, cast(uint)(vi / 4), 1, 0, 0);

        frameVertexOffset += vertexBytes;
    }

    void destroy() nothrow @nogc @trusted {
        if (textBindGroup !is null)   { wgpuBindGroupRelease(textBindGroup); textBindGroup = null; }
        if (textUniformBuf !is null)  { wgpuBufferDestroy(textUniformBuf); wgpuBufferRelease(textUniformBuf); textUniformBuf = null; }
        if (textVertexBuf !is null)   { wgpuBufferDestroy(textVertexBuf); wgpuBufferRelease(textVertexBuf); textVertexBuf = null; }
        textPipeline.release();
        if (fontSampler !is null)     { wgpuSamplerRelease(fontSampler); fontSampler = null; }
        if (fontTextureView !is null) { wgpuTextureViewRelease(fontTextureView); fontTextureView = null; }
        if (fontTexture !is null)     { wgpuTextureRelease(fontTexture); fontTexture = null; }
    }
}

// ---------------------------------------------------------------------------
// FPS Counter — high-resolution timing via SDL performance counter
// ---------------------------------------------------------------------------
struct FpsCounter {
    private ulong lastCounter;
    private ulong freq;
    private float accumTime = 0;
    private int   frameCount = 0;
    private float currentFps = 0;
    private float currentFrameTime = 0;
    private char[64] displayBuf = 0;
    private size_t displayLen = 0;

    static FpsCounter create() @trusted {
        FpsCounter f;
        f.freq = SDL_GetPerformanceFrequency();
        f.lastCounter = SDL_GetPerformanceCounter();
        f.displayBuf[0 .. 6] = "FPS: 0";
        f.displayLen = 6;
        return f;
    }

    /// Call once per frame. Returns delta time in seconds.
    float tick() @trusted {
        immutable now = SDL_GetPerformanceCounter();
        immutable delta = now - lastCounter;
        lastCounter = now;
        currentFrameTime = cast(float) delta / cast(float) freq;
        accumTime += currentFrameTime;
        frameCount++;

        if (accumTime >= 0.5f) {
            currentFps = cast(float) frameCount / accumTime;
            accumTime = 0;
            frameCount = 0;
            formatFps();
        }

        return currentFrameTime;
    }

    float fps() const nothrow @nogc { return currentFps; }
    float dt()  const nothrow @nogc { return currentFrameTime; }

    const(char)[] text() return const nothrow @nogc {
        return displayBuf[0 .. displayLen];
    }

    private void formatFps() nothrow @nogc {
        // Manual integer-to-string to stay @nogc
        int fpsInt = cast(int)(currentFps + 0.5f);
        displayBuf[0 .. 5] = "FPS: ";
        size_t pos = 5;

        if (fpsInt == 0) {
            displayBuf[pos++] = '0';
        } else {
            char[10] tmp = void;
            size_t tLen = 0;
            while (fpsInt > 0 && tLen < 10) {
                tmp[tLen++] = cast(char)('0' + fpsInt % 10);
                fpsInt /= 10;
            }
            foreach_reverse (i; 0 .. tLen) {
                displayBuf[pos++] = tmp[i];
            }
        }
        displayLen = pos;
    }
}
