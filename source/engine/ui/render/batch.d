/// Retained 2D UI batch renderer, vertex layout, and GPU drawing.
module engine.ui.render.batch;

import bindings.wgpu;
import core.stdc.math : cosf, sinf, sqrtf, fabsf;
import engine.core.log : info, warn, err, fatal;
import engine.core.pod : isPod, Pod;
import engine.graphics.texture : Texture;
import engine.graphics.types : Color4;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : ui2dShaderSource;
import engine.ui.style;
import engine.ui.text.font;
import engine.ui.tree;

@safe:

import engine.devtools.profiler : profileZone;

/// Single 2D UI vertex layout (80 bytes, POD).
struct UiVertex {
    float x = 0, y = 0;                  // 0..8: position in pixels
    float u = 0, v = 0;                  // 8..16: UV coordinates
    float r = 1, g = 1, b = 1, a = 1;    // 16..32: RGBA color
    float rectW = 0, rectH = 0;          // 32..40: rect dimensions
    float radius = 0, borderW = 0;       // 40..48: corner radius and border width
    float localX = 0, localY = 0;        // 48..56: position relative to center of rect
    float br = 0, bg = 0, bb = 0, ba = 0;// 56..72: border color RGBA
    float mode = 0;                      // 72..76: 0 = solid/rounded, 1 = text glyph, 2 = textured quad
    float _pad = 0;                      // 76..80: padding to 16-byte alignment
}

static assert(UiVertex.sizeof == 80);
static assert(isPod!UiVertex);

/// Scissor rectangle in pixels.
struct ScissorRect {
    uint x = 0;
    uint y = 0;
    uint w = 0;
    uint h = 0;
}

static assert(isPod!ScissorRect);

/// Analytical circular clip region in pixels.
struct CircleClip {
    float cx = 0;
    float cy = 0;
    float radius = 0;
}

static assert(isPod!CircleClip);

private struct UiUniformData {
    float screenW = 0, screenH = 0, pad0 = 0, pad1 = 0;
    float clipCx = 0, clipCy = 0, clipRadius = 0, clipActive = 0;
}

static assert(UiUniformData.sizeof == 32);
static assert(isPod!UiUniformData);

/// 2D Batch drawer managing pre-allocated GPU buffers and command generation.
struct UiBatchRenderer {
    private enum MAX_VERTICES = 32_768; // 8,192 quads
    private enum MAX_INDICES  = 49_152;

    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPURenderPipeline pipeline;
    private WGPUBindGroupLayout bindGroupLayout;
    private WGPUPipelineLayout pipelineLayout;
    private WGPUShaderModule shaderModule;

    private WGPUBuffer vertexBuffer;
    private WGPUBuffer indexBuffer;
    private WGPUBuffer uniformBuffer;
    private WGPUSampler sampler;
    private WGPUTextureFormat surfaceFormat;

    // Font atlas texture resources
    private WGPUTexture fontTexture;
    private WGPUTextureView fontTextureView;
    private WGPUBindGroup defaultBindGroup;
    private int uploadedFontW = 0;
    private int uploadedFontH = 0;
    private uint uploadedFontVer = 0;

    // Cached bind groups for RGBA images drawn via drawImage / UiNode.textureHandle
    private enum MAX_TEXTURE_BINDGROUPS = 64;
    private struct TexBgEntry {
        WGPUTextureView view;
        WGPUBindGroup bg;
    }
    private TexBgEntry[MAX_TEXTURE_BINDGROUPS] textureBgs;
    private uint textureBgCount = 0;
    private uint nextEvictSlot = 0;

    // CPU-side staging buffers
    private Pod!UiVertex[] vertices;
    private Pod!uint[] indices;
    private uint vertexCount = 0;
    private uint indexCount = 0;

    // Scissor clipping, analytical circular clipping, and bind-group batch segments
    private enum MAX_CLIP_DEPTH = 16;
    private enum MAX_SEGMENTS = 512;
    private enum UNIFORM_STRIDE = 256;
    private struct Segment {
        uint indexStart;
        uint indexCount;
        bool clipped;
        ScissorRect rect;
        bool circleClipped;
        CircleClip circle;
        WGPUBindGroup bindGroup; // null => active defaultBindGroup (font atlas)
    }
    private struct ClipState { bool clipped; ScissorRect rect; }
    private struct CircleClipState { bool clipped; CircleClip circle; }
    private ClipState[MAX_CLIP_DEPTH] clipStack;
    private uint clipDepth = 0;
    private CircleClipState[MAX_CLIP_DEPTH] circleClipStack;
    private uint circleClipDepth = 0;
    private Segment[MAX_SEGMENTS] segments;
    private uint segmentCount = 0;
    private uint segmentStart = 0;
    private bool curClipped = false;
    private ScissorRect curClip;
    private bool curCircleClipped = false;
    private CircleClip curCircleClip;
    private WGPUBindGroup curBindGroup = null;
    private Pod!ubyte[] uniformStaging;

    /// Initialize the UI batch renderer with GPU pipeline and buffers.
    void init(WGPUDevice dev, WGPUQueue q, WGPUTextureFormat surfFormat, ref Font font) @trusted {
        device = dev;
        queue = q;
        surfaceFormat = surfFormat;

        vertices.length = MAX_VERTICES;
        indices.length = MAX_INDICES;
        uniformStaging.length = MAX_SEGMENTS * UNIFORM_STRIDE;

        // Create shader module
        shaderModule = createShaderModule(device, ui2dShaderSource);
        if (shaderModule is null) {
            fatal("Failed to create UI shader module");
        }

        // Bind group layout: 0 = dynamic uniform(screenSize + clipCircle), 1 = sampler, 2 = texture2d
        WGPUBindGroupLayoutEntry[3] bglEntries;
        bglEntries[0].binding = 0;
        bglEntries[0].visibility = WGPUShaderStage.vertex | WGPUShaderStage.fragment;
        bglEntries[0].buffer.type = WGPUBufferBindingType.uniform;
        bglEntries[0].buffer.hasDynamicOffset = 1;
        bglEntries[0].buffer.minBindingSize = UiUniformData.sizeof;

        bglEntries[1].binding = 1;
        bglEntries[1].visibility = WGPUShaderStage.fragment;
        bglEntries[1].sampler.type = WGPUSamplerBindingType.filtering;

        bglEntries[2].binding = 2;
        bglEntries[2].visibility = WGPUShaderStage.fragment;
        bglEntries[2].texture.sampleType = WGPUTextureSampleType.float_;
        bglEntries[2].texture.viewDimension = WGPUTextureViewDimension.dim2D;

        WGPUBindGroupLayoutDescriptor bglDesc;
        bglDesc.entryCount = 3;
        bglDesc.entries = bglEntries.ptr;
        bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &bglDesc);

        // Pipeline layout
        WGPUPipelineLayoutDescriptor plDesc;
        plDesc.bindGroupLayoutCount = 1;
        plDesc.bindGroupLayouts = &bindGroupLayout;
        pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &plDesc);

        // Vertex layout
        WGPUVertexAttribute[7] attrs = [
            { format: WGPUVertexFormat.float32x2, offset: 0,  shaderLocation: 0 }, // position
            { format: WGPUVertexFormat.float32x2, offset: 8,  shaderLocation: 1 }, // uv
            { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 2 }, // color
            { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 3 }, // rectParams
            { format: WGPUVertexFormat.float32x2, offset: 48, shaderLocation: 4 }, // localPos
            { format: WGPUVertexFormat.float32x4, offset: 56, shaderLocation: 5 }, // borderColor
            { format: WGPUVertexFormat.float32,   offset: 72, shaderLocation: 6 }, // mode
        ];

        WGPUVertexBufferLayout bufLayout;
        bufLayout.arrayStride = UiVertex.sizeof;
        bufLayout.stepMode = WGPUVertexStepMode.vertex;
        bufLayout.attributeCount = 7;
        bufLayout.attributes = attrs.ptr;

        // Blend state: premultiplied / standard alpha blend
        WGPUBlendState blendState;
        blendState.color.operation = WGPUBlendOperation.add;
        blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
        blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
        blendState.alpha.operation = WGPUBlendOperation.add;
        blendState.alpha.srcFactor = WGPUBlendFactor.one;
        blendState.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;

        WGPUColorTargetState colorTarget;
        colorTarget.format = surfaceFormat;
        colorTarget.blend = &blendState;
        colorTarget.writeMask = WGPUColorWriteMask.all;

        WGPUFragmentState fragState;
        fragState.module_ = shaderModule;
        fragState.entryPoint = wgpuStringView("fs_ui");
        fragState.targetCount = 1;
        fragState.targets = &colorTarget;

        WGPURenderPipelineDescriptor pipeDesc;
        pipeDesc.layout = pipelineLayout;
        pipeDesc.vertex.module_ = shaderModule;
        pipeDesc.vertex.entryPoint = wgpuStringView("vs_ui");
        pipeDesc.vertex.bufferCount = 1;
        pipeDesc.vertex.buffers = &bufLayout;
        pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
        pipeDesc.fragment = &fragState;

        pipeline = wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
        if (pipeline is null) {
            fatal("Failed to create UI render pipeline");
        }

        // Create GPU buffers
        WGPUBufferDescriptor vbDesc;
        vbDesc.size = MAX_VERTICES * UiVertex.sizeof;
        vbDesc.usage = WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst;
        vertexBuffer = wgpuDeviceCreateBuffer(device, &vbDesc);

        WGPUBufferDescriptor ibDesc;
        ibDesc.size = MAX_INDICES * uint.sizeof;
        ibDesc.usage = WGPUBufferUsage.index | WGPUBufferUsage.copyDst;
        indexBuffer = wgpuDeviceCreateBuffer(device, &ibDesc);

        WGPUBufferDescriptor ubDesc;
        ubDesc.size = MAX_SEGMENTS * UNIFORM_STRIDE;
        ubDesc.usage = WGPUBufferUsage.uniform | WGPUBufferUsage.copyDst;
        uniformBuffer = wgpuDeviceCreateBuffer(device, &ubDesc);

        // Sampler (linear / clamp)
        WGPUSamplerDescriptor sampDesc;
        sampDesc.minFilter = WGPUFilterMode.linear;
        sampDesc.magFilter = WGPUFilterMode.linear;
        sampDesc.addressModeU = WGPUAddressMode.clampToEdge;
        sampDesc.addressModeV = WGPUAddressMode.clampToEdge;
        sampler = wgpuDeviceCreateSampler(device, &sampDesc);

        // Create font texture (or 1x1 fallback so defaultBindGroup is never null)
        uploadFontAtlas(font);
        if (defaultBindGroup is null) {
            ensureFallbackDefaultTexture();
        }

        info("UiBatchRenderer initialized");
    }

    private void ensureFallbackDefaultTexture() @trusted {
        if (defaultBindGroup !is null || device is null || queue is null) return;
        WGPUTextureDescriptor texDesc;
        texDesc.size.width = 1;
        texDesc.size.height = 1;
        texDesc.size.depthOrArrayLayers = 1;
        texDesc.format = WGPUTextureFormat.r8Unorm;
        texDesc.usage = WGPUTextureUsage.textureBinding | WGPUTextureUsage.copyDst;
        texDesc.dimension = WGPUTextureDimension.dim2D;
        texDesc.mipLevelCount = 1;
        texDesc.sampleCount = 1;

        fontTexture = wgpuDeviceCreateTexture(device, &texDesc);
        fontTextureView = wgpuTextureCreateView(fontTexture, null);
        defaultBindGroup = createTextureBindGroup(fontTextureView);
        uploadedFontW = 1;
        uploadedFontH = 1;

        ubyte[1] white = [255];
        WGPUImageCopyTexture dst;
        dst.texture = fontTexture;
        WGPUTextureDataLayout layout;
        layout.bytesPerRow = 1;
        layout.rowsPerImage = 1;
        WGPUExtent3D writeSize = WGPUExtent3D(1, 1, 1);
        wgpuQueueWriteTexture(queue, &dst, white.ptr, 1, &layout, &writeSize);
    }

    private WGPUBindGroup createTextureBindGroup(WGPUTextureView view) nothrow @nogc @trusted {
        if (view is null || device is null || bindGroupLayout is null || uniformBuffer is null || sampler is null) {
            return null;
        }
        WGPUBindGroupEntry[3] bgEntries;
        bgEntries[0].binding = 0;
        bgEntries[0].buffer = uniformBuffer;
        bgEntries[0].size = UiUniformData.sizeof;

        bgEntries[1].binding = 1;
        bgEntries[1].sampler = sampler;

        bgEntries[2].binding = 2;
        bgEntries[2].textureView = view;

        WGPUBindGroupDescriptor bgDesc;
        bgDesc.layout = bindGroupLayout;
        bgDesc.entryCount = 3;
        bgDesc.entries = bgEntries.ptr;
        return wgpuDeviceCreateBindGroup(device, &bgDesc);
    }

    private WGPUBindGroup getOrCreateBindGroup(WGPUTextureView view) nothrow @nogc @trusted {
        if (view is null) return null;
        foreach (i; 0 .. textureBgCount) {
            if (textureBgs[i].view is view) {
                return textureBgs[i].bg;
            }
        }
        auto bg = createTextureBindGroup(view);
        if (bg is null) return null;
        if (textureBgCount < MAX_TEXTURE_BINDGROUPS) {
            textureBgs[textureBgCount++] = TexBgEntry(view, bg);
        } else {
            if (textureBgs[nextEvictSlot].bg !is null) {
                wgpuBindGroupRelease(textureBgs[nextEvictSlot].bg);
            }
            textureBgs[nextEvictSlot] = TexBgEntry(view, bg);
            nextEvictSlot = (nextEvictSlot + 1) % MAX_TEXTURE_BINDGROUPS;
        }
        return bg;
    }

    /// Pre-register an RGBA `Texture` for UI drawing and return its `UiNode.textureHandle`.
    ulong registerTexture(ref const Texture tex) nothrow @nogc @trusted {
        if (!tex.valid) return 0;
        if (device !is null) getOrCreateBindGroup(cast(WGPUTextureView) tex.view);
        return tex.uiHandle();
    }

    /// Release cached bind group associated with a destroyed `Texture`.
    void unregisterTexture(ref const Texture tex) nothrow @nogc @trusted {
        if (tex.view is null) return;
        foreach (i; 0 .. textureBgCount) {
            if (textureBgs[i].view is cast(WGPUTextureView) tex.view) {
                if (textureBgs[i].bg !is null) wgpuBindGroupRelease(textureBgs[i].bg);
                textureBgs[i] = textureBgs[textureBgCount - 1];
                textureBgs[--textureBgCount] = TexBgEntry.init;
                return;
            }
        }
    }

    /// Upload / sync font texture to GPU (recreating it automatically if the atlas grew).
    void uploadFontAtlas(ref Font font) nothrow @nogc @trusted {
        if (!font.isLoaded || device is null || queue is null) return;

        immutable bool needRecreate = fontTexture is null
            || font.atlasW != uploadedFontW
            || font.atlasH != uploadedFontH
            || font.atlasVersion != uploadedFontVer;

        if (needRecreate) {
            if (defaultBindGroup !is null) { wgpuBindGroupRelease(defaultBindGroup); defaultBindGroup = null; }
            if (fontTextureView !is null)  { wgpuTextureViewRelease(fontTextureView); fontTextureView = null; }
            if (fontTexture !is null)      { wgpuTextureRelease(fontTexture); fontTexture = null; }

            WGPUTextureDescriptor texDesc;
            texDesc.size.width = font.atlasW;
            texDesc.size.height = font.atlasH;
            texDesc.size.depthOrArrayLayers = 1;
            texDesc.format = WGPUTextureFormat.r8Unorm;
            texDesc.usage = WGPUTextureUsage.textureBinding | WGPUTextureUsage.copyDst;
            texDesc.dimension = WGPUTextureDimension.dim2D;
            texDesc.mipLevelCount = 1;
            texDesc.sampleCount = 1;

            fontTexture = wgpuDeviceCreateTexture(device, &texDesc);
            fontTextureView = wgpuTextureCreateView(fontTexture, null);
            defaultBindGroup = createTextureBindGroup(fontTextureView);
            uploadedFontW = font.atlasW;
            uploadedFontH = font.atlasH;
            uploadedFontVer = font.atlasVersion;
        }

        // Copy pixels into texture
        WGPUImageCopyTexture dst;
        dst.texture = fontTexture;
        dst.mipLevel = 0;

        WGPUTextureDataLayout layout;
        layout.bytesPerRow = font.atlasW;
        layout.rowsPerImage = font.atlasH;

        WGPUExtent3D writeSize;
        writeSize.width = font.atlasW;
        writeSize.height = font.atlasH;
        writeSize.depthOrArrayLayers = 1;

        wgpuQueueWriteTexture(queue, &dst, font.pixels.ptr, font.pixels.length, &layout, &writeSize);
        font.clearDirty();
    }

    /// Reset batches at the start of a UI frame.
    void begin() nothrow @nogc {
        vertexCount = 0;
        indexCount = 0;
        clipDepth = 0;
        circleClipDepth = 0;
        segmentCount = 0;
        segmentStart = 0;
        curClipped = false;
        curCircleClipped = false;
        curCircleClip = CircleClip.init;
        curBindGroup = null;
    }

    /// Close the segment of indices recorded under the current clip + bind-group state.
    private void closeSegment() nothrow @nogc {
        if (indexCount > segmentStart && segmentCount < MAX_SEGMENTS) {
            segments[segmentCount++] = Segment(
                segmentStart, indexCount - segmentStart, curClipped, curClip,
                curCircleClipped, curCircleClip, curBindGroup
            );
            segmentStart = indexCount;
        }
    }

    private void setBindGroup(WGPUBindGroup bg) nothrow @nogc {
        if (curBindGroup !is bg) {
            closeSegment();
            curBindGroup = bg;
        }
    }

    /// Restrict following draws to a pixel rect (intersected with the enclosing clip).
    void pushClip(float x, float y, float w, float h) nothrow @nogc {
        closeSegment();
        if (clipDepth < MAX_CLIP_DEPTH) clipStack[clipDepth++] = ClipState(curClipped, curClip);

        int x0 = x < 0 ? 0 : cast(int) x;
        int y0 = y < 0 ? 0 : cast(int) y;
        int x1 = cast(int)(x + w + 0.5f);
        int y1 = cast(int)(y + h + 0.5f);
        if (curClipped) {
            immutable int cx0 = cast(int) curClip.x;
            immutable int cy0 = cast(int) curClip.y;
            immutable int cx1 = cx0 + cast(int) curClip.w;
            immutable int cy1 = cy0 + cast(int) curClip.h;
            if (x0 < cx0) x0 = cx0;
            if (y0 < cy0) y0 = cy0;
            if (x1 > cx1) x1 = cx1;
            if (y1 > cy1) y1 = cy1;
        }
        curClip = ScissorRect(cast(uint) x0, cast(uint) y0,
                              x1 > x0 ? cast(uint)(x1 - x0) : 0,
                              y1 > y0 ? cast(uint)(y1 - y0) : 0);
        curClipped = true;
    }

    /// Leave the innermost clip region.
    void popClip() nothrow @nogc {
        closeSegment();
        if (clipDepth > 0) {
            immutable prev = clipStack[--clipDepth];
            curClipped = prev.clipped;
            curClip = prev.rect;
        } else {
            curClipped = false;
        }
    }

    /// Restrict following draws to an analytical circle centered at `(cx, cy)` with `radius` px
    /// and 1 px smoothstep antialiasing in `ui2d.wgsl` (AD-5).
    void pushCircleClip(float cx, float cy, float radius) nothrow @nogc {
        closeSegment();
        if (circleClipDepth < MAX_CLIP_DEPTH)
            circleClipStack[circleClipDepth++] = CircleClipState(curCircleClipped, curCircleClip);
        if (radius > 0.0f) {
            curCircleClip = CircleClip(cx, cy, radius);
            curCircleClipped = true;
        } else {
            curCircleClip = CircleClip.init;
            curCircleClipped = false;
        }
    }

    /// Leave the innermost circular clip region.
    void popCircleClip() nothrow @nogc {
        closeSegment();
        if (circleClipDepth > 0) {
            immutable prev = circleClipStack[--circleClipDepth];
            curCircleClipped = prev.clipped;
            curCircleClip = prev.circle;
        } else {
            curCircleClipped = false;
            curCircleClip = CircleClip.init;
        }
    }

    /// Draw a solid or rounded rectangle with optional border.
    void drawRect(
        float x, float y, float w, float h,
        in Color4 bg, in Color4 border,
        float borderW = 0, float cornerRadius = 0
    ) nothrow @nogc {
        if (w <= 0 || h <= 0) return;
        if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) return;

        immutable uint vStart = vertexCount;
        immutable float halfW = w * 0.5f;
        immutable float halfH = h * 0.5f;

        // Top-left
        vertices[vertexCount++] = UiVertex(
            x, y, 0, 0,
            bg.r, bg.g, bg.b, bg.a,
            w, h, cornerRadius, borderW,
            -halfW, -halfH,
            border.r, border.g, border.b, border.a,
            0.0f
        );

        // Top-right
        vertices[vertexCount++] = UiVertex(
            x + w, y, 1, 0,
            bg.r, bg.g, bg.b, bg.a,
            w, h, cornerRadius, borderW,
            halfW, -halfH,
            border.r, border.g, border.b, border.a,
            0.0f
        );

        // Bottom-right
        vertices[vertexCount++] = UiVertex(
            x + w, y + h, 1, 1,
            bg.r, bg.g, bg.b, bg.a,
            w, h, cornerRadius, borderW,
            halfW, halfH,
            border.r, border.g, border.b, border.a,
            0.0f
        );

        // Bottom-left
        vertices[vertexCount++] = UiVertex(
            x, y + h, 0, 1,
            bg.r, bg.g, bg.b, bg.a,
            w, h, cornerRadius, borderW,
            -halfW, halfH,
            border.r, border.g, border.b, border.a,
            0.0f
        );

        indices[indexCount++] = vStart + 0;
        indices[indexCount++] = vStart + 1;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 3;
        indices[indexCount++] = vStart + 0;
    }


    /// Draw a solid/rounded rectangle centered at `(cx, cy)` rotated by `angleRad` radians.
    void drawRectRotated(
        float cx, float cy, float w, float h, float angleRad,
        in Color4 bg, in Color4 border = Color4(0, 0, 0, 0),
        float borderW = 0, float cornerRadius = 0
    ) nothrow @nogc {
        if (w <= 0 || h <= 0) return;
        if (vertices.length == 0) return;
        if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) return;

        immutable float hw = w * 0.5f;
        immutable float hh = h * 0.5f;
        immutable float c = cosf(angleRad);
        immutable float s = sinf(angleRad);

        float[4] lx = [-hw,  hw, hw, -hw];
        float[4] ly = [-hh, -hh, hh,  hh];
        float[4] us = [0, 1, 1, 0];
        float[4] vs = [0, 0, 1, 1];

        immutable uint vStart = vertexCount;
        foreach (k; 0 .. 4) {
            immutable float px = cx + lx[k] * c - ly[k] * s;
            immutable float py = cy + lx[k] * s + ly[k] * c;
            vertices[vertexCount++] = UiVertex(
                px, py, us[k], vs[k],
                bg.r, bg.g, bg.b, bg.a,
                w, h, cornerRadius, borderW,
                lx[k], ly[k],
                border.r, border.g, border.b, border.a,
                0.0f
            );
        }

        indices[indexCount++] = vStart + 0;
        indices[indexCount++] = vStart + 1;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 3;
        indices[indexCount++] = vStart + 0;
    }


    /// Draw an antialiased line segment with rounded caps from `(x1, y1)` to `(x2, y2)`.
    void drawLine(
        float x1, float y1, float x2, float y2,
        float thickness, in Color4 color
    ) nothrow @nogc {
        if (thickness <= 0 || vertices.length == 0) return;
        immutable float dx = x2 - x1;
        immutable float dy = y2 - y1;
        immutable float len = sqrtf(dx * dx + dy * dy);
        if (len < 1e-4f) {
            drawCircle(x1, y1, thickness * 0.5f, color);
            return;
        }
        if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) return;

        immutable float capLen = len + thickness;
        immutable float hw = capLen * 0.5f;
        immutable float hh = thickness * 0.5f;
        immutable float radius = hh;
        immutable float tx = dx / len;
        immutable float ty = dy / len;
        immutable float nx = -ty;
        immutable float ny = tx;
        immutable float cx = (x1 + x2) * 0.5f;
        immutable float cy = (y1 + y2) * 0.5f;

        float[4] lx = [-hw,  hw, hw, -hw];
        float[4] ly = [-hh, -hh, hh,  hh];
        immutable uint vStart = vertexCount;
        foreach (k; 0 .. 4) {
            immutable float px = cx + lx[k] * tx + ly[k] * nx;
            immutable float py = cy + lx[k] * ty + ly[k] * ny;
            vertices[vertexCount++] = UiVertex(
                px, py, 0, 0,
                color.r, color.g, color.b, color.a,
                capLen, thickness, radius, 0.0f,
                lx[k], ly[k],
                0, 0, 0, 0,
                0.0f
            );
        }
        indices[indexCount++] = vStart + 0;
        indices[indexCount++] = vStart + 1;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 3;
        indices[indexCount++] = vStart + 0;
    }


    /// Draw a filled triangle (Mode 3 flat solid).
    void drawTriangle(
        float x0, float y0, float x1, float y1, float x2, float y2,
        in Color4 color
    ) nothrow @nogc {
        if (vertices.length == 0) return;
        if (vertexCount + 3 > MAX_VERTICES || indexCount + 3 > MAX_INDICES) return;

        immutable uint vStart = vertexCount;
        vertices[vertexCount++] = UiVertex(x0, y0, 0, 0, color.r, color.g, color.b, color.a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3.0f);
        vertices[vertexCount++] = UiVertex(x1, y1, 0, 0, color.r, color.g, color.b, color.a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3.0f);
        vertices[vertexCount++] = UiVertex(x2, y2, 0, 0, color.r, color.g, color.b, color.a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3.0f);
        indices[indexCount++] = vStart + 0;
        indices[indexCount++] = vStart + 1;
        indices[indexCount++] = vStart + 2;
    }

    /// Draw a filled simple polygon (convex or concave, up to 128 vertices) given `[x0, y0, x1, y1, ...]`.
    void drawPolygon(scope const(float)[] xyPairs, in Color4 color) nothrow @nogc {
        immutable size_t n = xyPairs.length / 2;
        if (n < 3 || vertices.length == 0) return;

        enum size_t MAX_POLY_VERTS = 128;
        immutable size_t count = n <= MAX_POLY_VERTS ? n : MAX_POLY_VERTS;
        immutable size_t triCount = count - 2;
        if (vertexCount + count > MAX_VERTICES || indexCount + triCount * 3 > MAX_INDICES) return;

        // Compute signed area to determine orientation
        float area2 = 0.0f;
        foreach (i; 0 .. count) {
            immutable size_t j = (i + 1) % count;
            area2 += xyPairs[i * 2] * xyPairs[j * 2 + 1] - xyPairs[j * 2] * xyPairs[i * 2 + 1];
        }
        immutable float orient = area2 >= 0.0f ? 1.0f : -1.0f;

        immutable uint vStart = vertexCount;
        foreach (i; 0 .. count) {
            vertices[vertexCount++] = UiVertex(
                xyPairs[i * 2], xyPairs[i * 2 + 1], 0, 0,
                color.r, color.g, color.b, color.a,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3.0f
            );
        }

        // Stack-based ear clipping
        uint[MAX_POLY_VERTS] rem;
        foreach (i; 0 .. count) rem[i] = cast(uint) i;
        size_t remCount = count;

        size_t guard = remCount * remCount + 4;
        size_t pos = 0;
        while (remCount > 2 && guard-- > 0) {
            immutable size_t iPrev = (pos + remCount - 1) % remCount;
            immutable size_t iCur  = pos % remCount;
            immutable size_t iNext = (pos + 1) % remCount;

            immutable uint ia = rem[iPrev];
            immutable uint ib = rem[iCur];
            immutable uint ic = rem[iNext];

            immutable float ax = xyPairs[ia * 2], ay = xyPairs[ia * 2 + 1];
            immutable float bx = xyPairs[ib * 2], by = xyPairs[ib * 2 + 1];
            immutable float cx = xyPairs[ic * 2], cy = xyPairs[ic * 2 + 1];

            immutable float cross = ((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) * orient;
            bool isEar = cross > 1e-5f;
            if (isEar) {
                foreach (k; 0 .. remCount) {
                    if (k == iPrev || k == iCur || k == iNext) continue;
                    immutable uint ik = rem[k];
                    immutable float px = xyPairs[ik * 2], py = xyPairs[ik * 2 + 1];
                    if (pointInTri(px, py, ax, ay, bx, by, cx, cy, orient)) {
                        isEar = false;
                        break;
                    }
                }
            }

            if (isEar) {
                indices[indexCount++] = vStart + ia;
                indices[indexCount++] = vStart + ib;
                indices[indexCount++] = vStart + ic;
                foreach (k; iCur .. remCount - 1) rem[k] = rem[k + 1];
                remCount--;
                if (pos >= remCount) pos = 0;
            } else {
                pos = (pos + 1) % remCount;
            }
        }

        // Fallback fan for remaining degenerate vertices if guard expired
        while (remCount >= 3 && indexCount + 3 <= MAX_INDICES) {
            indices[indexCount++] = vStart + rem[0];
            indices[indexCount++] = vStart + rem[1];
            indices[indexCount++] = vStart + rem[2];
            foreach (k; 1 .. remCount - 1) rem[k] = rem[k + 1];
            remCount--;
        }
    }

    private static bool pointInTri(
        float px, float py,
        float ax, float ay, float bx, float by, float cx, float cy,
        float orient
    ) nothrow @nogc pure {
        immutable float c0 = ((bx - ax) * (py - ay) - (by - ay) * (px - ax)) * orient;
        immutable float c1 = ((cx - bx) * (py - by) - (cy - by) * (px - bx)) * orient;
        immutable float c2 = ((ax - cx) * (py - cy) - (ay - cy) * (px - cx)) * orient;
        return c0 >= -1e-4f && c1 >= -1e-4f && c2 >= -1e-4f;
    }

    /// Draw a connected polyline `[x0, y0, x1, y1, ...]`.
    void drawPolyline(scope const(float)[] xyPairs, float thickness, in Color4 color, bool closed = false) nothrow @nogc {
        immutable size_t n = xyPairs.length / 2;
        if (n < 2) return;
        foreach (i; 0 .. n - 1) {
            drawLine(xyPairs[i * 2], xyPairs[i * 2 + 1], xyPairs[(i + 1) * 2], xyPairs[(i + 1) * 2 + 1], thickness, color);
        }
        if (closed && n >= 3) {
            drawLine(xyPairs[(n - 1) * 2], xyPairs[(n - 1) * 2 + 1], xyPairs[0], xyPairs[1], thickness, color);
        }
    }

    /// Draw an analytical SDF arc or annular sector (1 quad, crisp edges at any radius).
    /// `startAngleRad` is in radians (`0` = +X right, `PI/2` = +Y down).
    void drawArc(
        float cx, float cy,
        float innerRadius, float outerRadius,
        float startAngleRad, float sweepAngleRad,
        in Color4 color
    ) nothrow @nogc {
        if (outerRadius <= 0 || sweepAngleRad == 0 || vertices.length == 0) return;
        if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) return;

        immutable float innerR = innerRadius > 0 ? innerRadius : 0.0f;
        float start = startAngleRad;
        float sweep = sweepAngleRad;
        if (sweep < 0) {
            start += sweep;
            sweep = -sweep;
        }
        immutable float pad = outerRadius + 1.5f;
        immutable uint vStart = vertexCount;

        vertices[vertexCount++] = UiVertex(
            cx - pad, cy - pad, 0, 0,
            color.r, color.g, color.b, color.a,
            innerR, outerRadius, start, sweep,
            -pad, -pad,
            0, 0, 0, 0, 4.0f
        );
        vertices[vertexCount++] = UiVertex(
            cx + pad, cy - pad, 1, 0,
            color.r, color.g, color.b, color.a,
            innerR, outerRadius, start, sweep,
            pad, -pad,
            0, 0, 0, 0, 4.0f
        );
        vertices[vertexCount++] = UiVertex(
            cx + pad, cy + pad, 1, 1,
            color.r, color.g, color.b, color.a,
            innerR, outerRadius, start, sweep,
            pad, pad,
            0, 0, 0, 0, 4.0f
        );
        vertices[vertexCount++] = UiVertex(
            cx - pad, cy + pad, 0, 1,
            color.r, color.g, color.b, color.a,
            innerR, outerRadius, start, sweep,
            -pad, pad,
            0, 0, 0, 0, 4.0f
        );

        indices[indexCount++] = vStart + 0;
        indices[indexCount++] = vStart + 1;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 3;
        indices[indexCount++] = vStart + 0;
    }


    /// Draw a filled antialiased circle (analytical SDF, 1 quad).
    void drawCircle(float cx, float cy, float radius, in Color4 color) nothrow @nogc {
        enum float TWO_PI = 6.28318530718f;
        drawArc(cx, cy, 0.0f, radius, 0.0f, TWO_PI, color);
    }

    /// Draw an antialiased circle outline (ring) of given stroke `thickness` (1 quad).
    void drawCircleOutline(float cx, float cy, float radius, float thickness, in Color4 color) nothrow @nogc {
        enum float TWO_PI = 6.28318530718f;
        if (thickness <= 0 || radius <= 0) return;
        immutable float halfT = thickness * 0.5f;
        immutable float innerR = radius > halfT ? radius - halfT : 0.0f;
        drawArc(cx, cy, innerR, radius + halfT, 0.0f, TWO_PI, color);
    }

    /// Draw an RGBA `Texture` quad (Mode 2) with optional UV crop and rounded corners.
    void drawImage(
        ref const Texture tex,
        float x, float y, float w, float h,
        in Color4 tint = Color4(1, 1, 1, 1),
        float u0 = 0.0f, float v0 = 0.0f, float u1 = 1.0f, float v1 = 1.0f,
        float cornerRadius = 0.0f
    ) nothrow @nogc {
        if (!tex.valid) return;
        auto viewPtr = () @trusted { return cast(WGPUTextureView) tex.view; }();
        drawImage(viewPtr, x, y, w, h, tint, u0, v0, u1, v1, cornerRadius);
    }

    /// Draw a raw `WGPUTextureView` image quad (Mode 2) with optional UV crop and rounded corners.
    void drawImage(
        WGPUTextureView view,
        float x, float y, float w, float h,
        in Color4 tint = Color4(1, 1, 1, 1),
        float u0 = 0.0f, float v0 = 0.0f, float u1 = 1.0f, float v1 = 1.0f,
        float cornerRadius = 0.0f
    ) nothrow @nogc {
        if (view is null || w <= 0 || h <= 0 || vertices.length == 0) return;
        if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) return;

        auto bg = getOrCreateBindGroup(view);
        if (bg is null) return;
        setBindGroup(bg);

        immutable uint vStart = vertexCount;
        immutable float halfW = w * 0.5f;
        immutable float halfH = h * 0.5f;

        vertices[vertexCount++] = UiVertex(
            x, y, u0, v0, tint.r, tint.g, tint.b, tint.a,
            w, h, cornerRadius, 0, -halfW, -halfH, 0, 0, 0, 0, 2.0f
        );
        vertices[vertexCount++] = UiVertex(
            x + w, y, u1, v0, tint.r, tint.g, tint.b, tint.a,
            w, h, cornerRadius, 0, halfW, -halfH, 0, 0, 0, 0, 2.0f
        );
        vertices[vertexCount++] = UiVertex(
            x + w, y + h, u1, v1, tint.r, tint.g, tint.b, tint.a,
            w, h, cornerRadius, 0, halfW, halfH, 0, 0, 0, 0, 2.0f
        );
        vertices[vertexCount++] = UiVertex(
            x, y + h, u0, v1, tint.r, tint.g, tint.b, tint.a,
            w, h, cornerRadius, 0, -halfW, halfH, 0, 0, 0, 0, 2.0f
        );

        indices[indexCount++] = vStart + 0;
        indices[indexCount++] = vStart + 1;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 3;
        indices[indexCount++] = vStart + 0;
    }


    /// Draw an RGBA `Texture` quad centered at `(cx, cy)` rotated by `angleRad` radians (Mode 2).
    void drawImageRotated(
        ref const Texture tex,
        float cx, float cy, float w, float h, float angleRad,
        in Color4 tint = Color4(1, 1, 1, 1),
        float u0 = 0.0f, float v0 = 0.0f, float u1 = 1.0f, float v1 = 1.0f,
        float cornerRadius = 0.0f
    ) nothrow @nogc {
        if (!tex.valid) return;
        auto viewPtr = () @trusted { return cast(WGPUTextureView) tex.view; }();
        drawImageRotated(viewPtr, cx, cy, w, h, angleRad, tint, u0, v0, u1, v1, cornerRadius);
    }

    /// Draw a raw `WGPUTextureView` quad centered at `(cx, cy)` rotated by `angleRad` radians (Mode 2).
    void drawImageRotated(
        WGPUTextureView view,
        float cx, float cy, float w, float h, float angleRad,
        in Color4 tint = Color4(1, 1, 1, 1),
        float u0 = 0.0f, float v0 = 0.0f, float u1 = 1.0f, float v1 = 1.0f,
        float cornerRadius = 0.0f
    ) nothrow @nogc {
        if (w <= 0 || h <= 0 || vertices.length == 0) return;
        if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) return;
        if (view !is null) {
            auto bg = getOrCreateBindGroup(view);
            if (bg is null) return;
            setBindGroup(bg);
        }

        immutable float hw = w * 0.5f;
        immutable float hh = h * 0.5f;
        immutable float c = cosf(angleRad);
        immutable float s = sinf(angleRad);

        float[4] lx = [-hw,  hw, hw, -hw];
        float[4] ly = [-hh, -hh, hh,  hh];
        float[4] us = [u0, u1, u1, u0];
        float[4] vs = [v0, v0, v1, v1];

        immutable uint vStart = vertexCount;
        foreach (k; 0 .. 4) {
            immutable float px = cx + lx[k] * c - ly[k] * s;
            immutable float py = cy + lx[k] * s + ly[k] * c;
            vertices[vertexCount++] = UiVertex(
                px, py, us[k], vs[k],
                tint.r, tint.g, tint.b, tint.a,
                w, h, cornerRadius, 0.0f,
                lx[k], ly[k],
                0, 0, 0, 0,
                2.0f
            );
        }

        indices[indexCount++] = vStart + 0;
        indices[indexCount++] = vStart + 1;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 3;
        indices[indexCount++] = vStart + 0;
    }

    /// Draw a fixed-orientation `Texture` quad at `(x, y, w, h)` with UVs rotated by `angleRad`
    /// around `(uvCenterX, uvCenterY)` (e.g., rotating minimap texture inside a circular aperture).
    void drawImageUvRotated(
        ref const Texture tex,
        float x, float y, float w, float h,
        float uvCenterX, float uvCenterY, float uvWidth, float uvHeight, float angleRad,
        in Color4 tint = Color4(1, 1, 1, 1),
        float cornerRadius = -1.0f
    ) nothrow @nogc {
        if (!tex.valid) return;
        auto viewPtr = () @trusted { return cast(WGPUTextureView) tex.view; }();
        drawImageUvRotated(viewPtr, x, y, w, h, uvCenterX, uvCenterY, uvWidth, uvHeight,
                           angleRad, tint, cornerRadius);
    }

    /// Draw a fixed-orientation `WGPUTextureView` quad with rotated UVs (Mode 2).
    void drawImageUvRotated(
        WGPUTextureView view,
        float x, float y, float w, float h,
        float uvCenterX, float uvCenterY, float uvWidth, float uvHeight, float angleRad,
        in Color4 tint = Color4(1, 1, 1, 1),
        float cornerRadius = -1.0f
    ) nothrow @nogc {
        if (w <= 0 || h <= 0 || vertices.length == 0) return;
        if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) return;
        if (view !is null) {
            auto bg = getOrCreateBindGroup(view);
            if (bg is null) return;
            setBindGroup(bg);
        }

        immutable float halfW = w * 0.5f;
        immutable float halfH = h * 0.5f;
        immutable float effRadius = cornerRadius >= 0.0f ? cornerRadius : (w < h ? halfW : halfH);
        immutable float hu = uvWidth * 0.5f;
        immutable float hv = uvHeight * 0.5f;
        immutable float c = cosf(angleRad);
        immutable float s = sinf(angleRad);

        float[4] px = [x, x + w, x + w, x];
        float[4] py = [y, y,     y + h, y + h];
        float[4] lx = [-halfW,  halfW, halfW, -halfW];
        float[4] ly = [-halfH, -halfH, halfH,  halfH];
        float[4] du = [-hu,  hu, hu, -hu];
        float[4] dv = [-hv, -hv, hv,  hv];

        immutable uint vStart = vertexCount;
        foreach (k; 0 .. 4) {
            immutable float u = uvCenterX + du[k] * c - dv[k] * s;
            immutable float v = uvCenterY + du[k] * s + dv[k] * c;
            vertices[vertexCount++] = UiVertex(
                px[k], py[k], u, v,
                tint.r, tint.g, tint.b, tint.a,
                w, h, effRadius, 0.0f,
                lx[k], ly[k],
                0, 0, 0, 0,
                2.0f
            );
        }

        indices[indexCount++] = vStart + 0;
        indices[indexCount++] = vStart + 1;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 2;
        indices[indexCount++] = vStart + 3;
        indices[indexCount++] = vStart + 0;
    }

    /// Draw a UTF-8 text string using the font atlas at its default pixel height.
    void drawText(
        ref Font font,
        float x, float y,
        scope const(char)[] text,
        in Color4 color
    ) nothrow {
        drawText(font, x, y, text, 0.0f, color);
    }

    /// Draw a UTF-8 text string at `pixelHeight` with optional SDF outline.
    void drawText(
        ref Font font,
        float x, float y,
        scope const(char)[] text,
        float pixelHeight,
        in Color4 color,
        in Color4 outlineColor = Color4(0, 0, 0, 0),
        float outlineWidth = 0.0f
    ) nothrow {
        if (text.length == 0 || !font.isLoaded) return;

        setBindGroup(null);

        immutable float effectiveH = pixelHeight > 0 ? pixelHeight : font.defaultSize();
        immutable float lh = font.lineHeight(effectiveH);
        immutable float sdfScale = font.sdfScaleForSize(effectiveH);

        float curX = x;
        float curY = y + lh * 0.75f; // baseline offset

        size_t i = 0;
        int prevCp = 0;
        while (i < text.length) {
            immutable int cp = Font.decodeUtf8(text, i);

            if (cp == '\n') {
                curX = x;
                curY += lh;
                prevCp = 0;
                continue;
            }

            if (prevCp != 0) {
                curX += font.getKerning(prevCp, cp, effectiveH);
            }
            Glyph g = font.getGlyph(cp, effectiveH);
            if (g.width > 0 && g.height > 0 && vertices.length > 0) {
                if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) break;

                immutable float gx0 = curX + g.xOffset;
                immutable float gy0 = curY + g.yOffset;
                immutable float gx1 = gx0 + g.width;
                immutable float gy1 = gy0 + g.height;
                immutable uint vStart = vertexCount;

                // Mode 1 = Font glyph (SDF when rectW > 0, else bitmap)
                vertices[vertexCount++] = UiVertex(gx0, gy0, g.u0, g.v0, color.r, color.g, color.b, color.a, sdfScale, 0, 0, outlineWidth, 0, 0, outlineColor.r, outlineColor.g, outlineColor.b, outlineColor.a, 1.0f);
                vertices[vertexCount++] = UiVertex(gx1, gy0, g.u1, g.v0, color.r, color.g, color.b, color.a, sdfScale, 0, 0, outlineWidth, 0, 0, outlineColor.r, outlineColor.g, outlineColor.b, outlineColor.a, 1.0f);
                vertices[vertexCount++] = UiVertex(gx1, gy1, g.u1, g.v1, color.r, color.g, color.b, color.a, sdfScale, 0, 0, outlineWidth, 0, 0, outlineColor.r, outlineColor.g, outlineColor.b, outlineColor.a, 1.0f);
                vertices[vertexCount++] = UiVertex(gx0, gy1, g.u0, g.v1, color.r, color.g, color.b, color.a, sdfScale, 0, 0, outlineWidth, 0, 0, outlineColor.r, outlineColor.g, outlineColor.b, outlineColor.a, 1.0f);

                indices[indexCount++] = vStart + 0;
                indices[indexCount++] = vStart + 1;
                indices[indexCount++] = vStart + 2;
                indices[indexCount++] = vStart + 2;
                indices[indexCount++] = vStart + 3;
                indices[indexCount++] = vStart + 0;
            }

            curX += g.advance;
            prevCp = cp;
        }

        if (device !is null && (font.isDirty || font.atlasVersion != uploadedFontVer)) {
            uploadFontAtlas(font);
        }
    }

    /// Render retained tree nodes recursively.
    void renderTree(ref UiTree tree, UiNodeId rootId, ref Font font) nothrow {
        if (!tree.isValid(rootId)) return;

        const n = &tree.get(rootId);
        if (!n.visible) return;

        // Render background & border
        if (n.style.backgroundColor.a > 0 || n.style.borderWidth > 0) {
            Color4 bg = n.style.backgroundColor;
            // Only interactive (pointer-cursor) nodes light up; panels do not.
            immutable bool interactive = n.style.cursor == UiCursor.pointer
                || n.style.cursor == UiCursor.resizeH;
            if (interactive && n.pressed && n.enabled) {
                bg.r *= 0.85f; bg.g *= 0.85f; bg.b *= 0.85f;
            } else if (interactive && n.hovered && n.enabled) {
                bg.r = (bg.r + 0.1f < 1.0f) ? bg.r + 0.1f : 1.0f;
                bg.g = (bg.g + 0.1f < 1.0f) ? bg.g + 0.1f : 1.0f;
                bg.b = (bg.b + 0.1f < 1.0f) ? bg.b + 0.1f : 1.0f;
            }
            drawRect(
                n.layoutX, n.layoutY, n.layoutWidth, n.layoutHeight,
                bg, n.style.borderColor,
                n.style.borderWidth, n.style.cornerRadius
            );
        }

        // Render optional RGBA image handle
        if (n.textureHandle != 0) {
            auto texView = () @trusted { return cast(WGPUTextureView) cast(size_t) n.textureHandle; }();
            if (n.style.rotateImageUv) {
                drawImageUvRotated(
                    texView,
                    n.layoutX, n.layoutY, n.layoutWidth, n.layoutHeight,
                    n.imageUvRect[0], n.imageUvRect[1], n.imageUvRect[2], n.imageUvRect[3],
                    n.style.imageRotation, n.imageTint, n.style.cornerRadius
                );
            } else if (n.style.imageRotation != 0.0f) {
                drawImageRotated(
                    texView,
                    n.layoutX + n.layoutWidth * 0.5f, n.layoutY + n.layoutHeight * 0.5f,
                    n.layoutWidth, n.layoutHeight, n.style.imageRotation,
                    n.imageTint,
                    n.imageUvRect[0], n.imageUvRect[1], n.imageUvRect[2], n.imageUvRect[3],
                    n.style.cornerRadius
                );
            } else {
                drawImage(
                    texView,
                    n.layoutX, n.layoutY, n.layoutWidth, n.layoutHeight,
                    n.imageTint,
                    n.imageUvRect[0], n.imageUvRect[1], n.imageUvRect[2], n.imageUvRect[3],
                    n.style.cornerRadius
                );
            }
        }

        // Render inline text
        if (n.textLen > 0) {
            immutable float fs = n.style.fontSize > 0 ? n.style.fontSize : font.defaultSize();
            immutable float lh = n.textHeight > 0 ? n.textHeight : font.lineHeight(fs);
            float tx = n.layoutX + n.style.padding[3];
            float ty = n.layoutY + n.style.padding[0];
            if (n.layoutHeight > lh) ty = n.layoutY + (n.layoutHeight - lh) * 0.5f;
            if (n.style.justifyContent == UiJustify.center && n.textWidth > 0)
                tx = n.layoutX + (n.layoutWidth - n.textWidth) * 0.5f;
            drawText(font, tx, ty, n.text, fs, n.style.textColor);
        }

        // Render children (optionally clipped to this node's box or analytical circle)
        immutable bool clip = n.style.clipChildren;
        immutable bool circleClip = clip && n.style.clipCircle;
        if (circleClip) {
            immutable float r = (n.layoutWidth < n.layoutHeight ? n.layoutWidth : n.layoutHeight) * 0.5f;
            pushCircleClip(n.layoutX + n.layoutWidth * 0.5f, n.layoutY + n.layoutHeight * 0.5f, r);
        } else if (clip) {
            pushClip(n.layoutX, n.layoutY, n.layoutWidth, n.layoutHeight);
        }
        UiNodeId child = n.firstChild;
        while (child.isValid()) {
            renderTree(tree, child, font);
            child = tree.get(child).nextSibling;
        }
        if (circleClip) popCircleClip();
        else if (clip) popClip();
    }

    /// Flush the batch into GPU commands inside an active render pass.
    void flush(WGPURenderPassEncoder pass, float screenW, float screenH) nothrow @nogc @trusted {
        if (indexCount == 0 || vertexCount == 0) return;
        auto z = profileZone!"ui.flush"();

        closeSegment();
        if (segmentCount == 0) return;

        // Upload per-segment dynamic uniforms (screenSize + analytical circle clip)
        if (uniformStaging.length < segmentCount * UNIFORM_STRIDE) return;
        foreach (si; 0 .. segmentCount) {
            const seg = &segments[si];
            UiUniformData u = UiUniformData(
                screenW, screenH, 0.0f, 0.0f,
                seg.circle.cx, seg.circle.cy, seg.circle.radius,
                seg.circleClipped ? 1.0f : 0.0f
            );
            auto ptr = cast(UiUniformData*) (uniformStaging.ptr + si * UNIFORM_STRIDE);
            *ptr = u;
        }
        wgpuQueueWriteBuffer(queue, uniformBuffer, 0, uniformStaging.ptr, segmentCount * UNIFORM_STRIDE);

        // Upload vertices & indices
        wgpuQueueWriteBuffer(queue, vertexBuffer, 0, vertices.ptr, vertexCount * UiVertex.sizeof);
        wgpuQueueWriteBuffer(queue, indexBuffer, 0, indices.ptr, indexCount * uint.sizeof);

        // Bind pipeline and vertex/index buffers
        wgpuRenderPassEncoderSetPipeline(pass, pipeline);
        WGPUBindGroup activeBg = null;
        wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vertexBuffer, 0, vertexCount * UiVertex.sizeof);
        wgpuRenderPassEncoderSetIndexBuffer(pass, indexBuffer, WGPUIndexFormat.uint32, 0, indexCount * uint.sizeof);

        // One draw per clip + bind-group segment
        immutable uint sw = cast(uint) screenW;
        immutable uint sh = cast(uint) screenH;
        foreach (si; 0 .. segmentCount) {
            auto seg = &segments[si];
            WGPUBindGroup wantBg = seg.bindGroup !is null ? seg.bindGroup : defaultBindGroup;
            if (wantBg !is null) {
                uint dynOffset = cast(uint) (si * UNIFORM_STRIDE);
                wgpuRenderPassEncoderSetBindGroup(pass, 0, wantBg, 1, &dynOffset);
                activeBg = wantBg;
            }
            if (seg.clipped) {
                uint rx = seg.rect.x < sw ? seg.rect.x : sw;
                uint ry = seg.rect.y < sh ? seg.rect.y : sh;
                uint rw = seg.rect.w;
                uint rh = seg.rect.h;
                if (rx + rw > sw) rw = sw - rx;
                if (ry + rh > sh) rh = sh - ry;
                if (rw == 0 || rh == 0) continue;
                wgpuRenderPassEncoderSetScissorRect(pass, rx, ry, rw, rh);
            } else {
                wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, sw, sh);
            }
            wgpuRenderPassEncoderDrawIndexed(pass, seg.indexCount, 1, seg.indexStart, 0, 0);
        }

        // Reset counters for next pass
        vertexCount = 0;
        indexCount = 0;
        segmentCount = 0;
        segmentStart = 0;
        curBindGroup = null;
    }

    /// Safely hot-reload the 2D UI shader without interrupting UI interactions.
    bool reloadShader(scope const(char)[] newWgsl) nothrow @nogc @trusted {
        if (pipelineLayout is null || device is null) return false;
        auto newModule = createShaderModule(device, newWgsl, "reload_ui2d");
        if (newModule is null) return false;

        WGPUVertexAttribute[7] attrs = [
            { format: WGPUVertexFormat.float32x2, offset: 0,  shaderLocation: 0 },
            { format: WGPUVertexFormat.float32x2, offset: 8,  shaderLocation: 1 },
            { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 2 },
            { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 3 },
            { format: WGPUVertexFormat.float32x2, offset: 48, shaderLocation: 4 },
            { format: WGPUVertexFormat.float32x4, offset: 56, shaderLocation: 5 },
            { format: WGPUVertexFormat.float32,   offset: 72, shaderLocation: 6 },
        ];

        WGPUVertexBufferLayout bufLayout;
        bufLayout.arrayStride = UiVertex.sizeof;
        bufLayout.stepMode = WGPUVertexStepMode.vertex;
        bufLayout.attributeCount = 7;
        bufLayout.attributes = attrs.ptr;

        WGPUBlendState blendState;
        blendState.color.operation = WGPUBlendOperation.add;
        blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
        blendState.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
        blendState.alpha.operation = WGPUBlendOperation.add;
        blendState.alpha.srcFactor = WGPUBlendFactor.one;
        blendState.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;

        WGPUColorTargetState colorTarget;
        colorTarget.format = surfaceFormat;
        colorTarget.blend = &blendState;
        colorTarget.writeMask = WGPUColorWriteMask.all;

        WGPUFragmentState fragState;
        fragState.module_ = newModule;
        fragState.entryPoint = wgpuStringView("fs_ui");
        fragState.targetCount = 1;
        fragState.targets = &colorTarget;

        WGPURenderPipelineDescriptor pipeDesc;
        pipeDesc.layout = pipelineLayout;
        pipeDesc.vertex.module_ = newModule;
        pipeDesc.vertex.entryPoint = wgpuStringView("vs_ui");
        pipeDesc.vertex.bufferCount = 1;
        pipeDesc.vertex.buffers = &bufLayout;
        pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
        pipeDesc.fragment = &fragState;

        auto newPipeline = wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
        if (newPipeline is null) {
            wgpuShaderModuleRelease(newModule);
            return false;
        }

        if (pipeline !is null) wgpuRenderPipelineRelease(pipeline);
        if (shaderModule !is null) wgpuShaderModuleRelease(shaderModule);
        pipeline = newPipeline;
        shaderModule = newModule;
        return true;
    }

    /// Cleanup GPU resources.
    void release() nothrow @nogc @trusted {
        foreach (i; 0 .. textureBgCount) {
            if (textureBgs[i].bg !is null) wgpuBindGroupRelease(textureBgs[i].bg);
            textureBgs[i] = TexBgEntry.init;
        }
        textureBgCount = 0;
        if (defaultBindGroup !is null) { wgpuBindGroupRelease(defaultBindGroup); defaultBindGroup = null; }
        if (fontTextureView !is null)  { wgpuTextureViewRelease(fontTextureView); fontTextureView = null; }
        if (fontTexture !is null)      { wgpuTextureRelease(fontTexture); fontTexture = null; }
        if (sampler !is null)          { wgpuSamplerRelease(sampler); sampler = null; }
        if (uniformBuffer !is null)    { wgpuBufferDestroy(uniformBuffer); wgpuBufferRelease(uniformBuffer); uniformBuffer = null; }
        if (indexBuffer !is null)      { wgpuBufferDestroy(indexBuffer); wgpuBufferRelease(indexBuffer); indexBuffer = null; }
        if (vertexBuffer !is null)     { wgpuBufferDestroy(vertexBuffer); wgpuBufferRelease(vertexBuffer); vertexBuffer = null; }
        if (pipeline !is null)         { wgpuRenderPipelineRelease(pipeline); pipeline = null; }
        if (pipelineLayout !is null)   { wgpuPipelineLayoutRelease(pipelineLayout); pipelineLayout = null; }
        if (bindGroupLayout !is null)  { wgpuBindGroupLayoutRelease(bindGroupLayout); bindGroupLayout = null; }
        if (shaderModule !is null)     { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }
    }
}

unittest {
    UiBatchRenderer ui;
    ui.vertices.length = 256;
    ui.indices.length = 512;
    ui.begin();

    auto red = Color4(1, 0, 0, 1);
    ui.drawCircle(50, 50, 20, red);
    assert(ui.vertexCount == 4 && ui.indexCount == 6);
    assert(ui.vertices[0].mode == 4.0f);

    ui.drawCircleOutline(50, 50, 20, 4, red);
    assert(ui.vertexCount == 8 && ui.indexCount == 12);

    ui.drawArc(50, 50, 10, 20, 0.0f, 1.57f, red);
    assert(ui.vertexCount == 12 && ui.indexCount == 18);

    ui.drawLine(0, 0, 100, 0, 4, red);
    assert(ui.vertexCount == 16 && ui.indexCount == 24);
    assert(ui.vertices[12].mode == 0.0f);

    ui.drawRectRotated(50, 50, 20, 10, 0.5f, red);
    assert(ui.vertexCount == 20 && ui.indexCount == 30);

    // Concave L-shape polygon (6 vertices -> 4 triangles = 12 indices)
    immutable float[12] poly = [0, 0, 100, 0, 100, 30, 30, 30, 30, 100, 0, 100];
    ui.drawPolygon(poly, red);
    assert(ui.vertexCount == 26);
    assert(ui.indexCount == 42);

    // Clipping stack
    ui.pushClip(10, 10, 80, 80);
    ui.drawTriangle(20, 20, 60, 20, 40, 60, red);
    ui.popClip();
    assert(ui.segmentCount == 2);

    // Analytical circular clip stack + rotated image / rotated UV image
    ui.pushCircleClip(200, 200, 64);
    ui.drawImageRotated(cast(WGPUTextureView) null, 200, 200, 24, 24, 1.5707963f, red);
    ui.drawImageUvRotated(cast(WGPUTextureView) null, 136, 136, 128, 128, 0.5f, 0.5f, 0.25f, 0.25f, 0.785398f, red);
    ui.popCircleClip();
    assert(ui.segmentCount == 3);
    assert(ui.segments[2].circleClipped);
    assert(ui.segments[2].circle.cx == 200 && ui.segments[2].circle.radius == 64);
}
