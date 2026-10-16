/// Retained 2D UI batch renderer, vertex layout, and GPU drawing.
module engine.ui.render.batch;

import bindings.wgpu;
import engine.core.log : info, warn, err, fatal;
import engine.core.pod : isPod, Pod;
import engine.graphics.types : Color4;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : ui2dShaderSource;
import engine.ui.style;
import engine.ui.text.font;
import engine.ui.tree;

@safe:

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

    // CPU-side staging buffers
    private Pod!UiVertex[] vertices;
    private Pod!uint[] indices;
    private uint vertexCount = 0;
    private uint indexCount = 0;

    // Scissor clipping: the index buffer is cut into segments, one per clip state
    private enum MAX_CLIP_DEPTH = 16;
    private enum MAX_SEGMENTS = 512;
    private struct Segment {
        uint indexStart;
        uint indexCount;
        bool clipped;
        ScissorRect rect;
    }
    private struct ClipState { bool clipped; ScissorRect rect; }
    private ClipState[MAX_CLIP_DEPTH] clipStack;
    private uint clipDepth = 0;
    private Segment[MAX_SEGMENTS] segments;
    private uint segmentCount = 0;
    private uint segmentStart = 0;
    private bool curClipped = false;
    private ScissorRect curClip;

    /// Initialize the UI batch renderer with GPU pipeline and buffers.
    void init(WGPUDevice dev, WGPUQueue q, WGPUTextureFormat surfFormat, ref Font font) @trusted {
        device = dev;
        queue = q;
        surfaceFormat = surfFormat;

        vertices.length = MAX_VERTICES;
        indices.length = MAX_INDICES;

        // Create shader module
        shaderModule = createShaderModule(device, ui2dShaderSource.ptr);
        if (shaderModule is null) {
            fatal("Failed to create UI shader module");
        }

        // Bind group layout: 0 = uniform(screenSize), 1 = sampler, 2 = texture2d
        WGPUBindGroupLayoutEntry[3] bglEntries;
        bglEntries[0].binding = 0;
        bglEntries[0].visibility = WGPUShaderStage.vertex;
        bglEntries[0].buffer.type = WGPUBufferBindingType.uniform;
        bglEntries[0].buffer.minBindingSize = 8; // vec2<f32>

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
        ubDesc.size = 16; // 2 floats + padding
        ubDesc.usage = WGPUBufferUsage.uniform | WGPUBufferUsage.copyDst;
        uniformBuffer = wgpuDeviceCreateBuffer(device, &ubDesc);

        // Sampler (linear / clamp)
        WGPUSamplerDescriptor sampDesc;
        sampDesc.minFilter = WGPUFilterMode.linear;
        sampDesc.magFilter = WGPUFilterMode.linear;
        sampDesc.addressModeU = WGPUAddressMode.clampToEdge;
        sampDesc.addressModeV = WGPUAddressMode.clampToEdge;
        sampler = wgpuDeviceCreateSampler(device, &sampDesc);

        // Create font texture
        uploadFontAtlas(font);

        info("UiBatchRenderer initialized");
    }

    /// Upload / sync font texture to GPU.
    void uploadFontAtlas(ref Font font) @trusted {
        if (!font.isLoaded) return;

        if (fontTexture is null) {
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

            // Create default bind group
            WGPUBindGroupEntry[3] bgEntries;
            bgEntries[0].binding = 0;
            bgEntries[0].buffer = uniformBuffer;
            bgEntries[0].size = 16;

            bgEntries[1].binding = 1;
            bgEntries[1].sampler = sampler;

            bgEntries[2].binding = 2;
            bgEntries[2].textureView = fontTextureView;

            WGPUBindGroupDescriptor bgDesc;
            bgDesc.layout = bindGroupLayout;
            bgDesc.entryCount = 3;
            bgDesc.entries = bgEntries.ptr;
            defaultBindGroup = wgpuDeviceCreateBindGroup(device, &bgDesc);
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
        segmentCount = 0;
        segmentStart = 0;
        curClipped = false;
    }

    /// Close the segment of indices recorded under the current clip state.
    private void closeSegment() nothrow @nogc {
        if (indexCount > segmentStart && segmentCount < MAX_SEGMENTS) {
            segments[segmentCount++] = Segment(segmentStart, indexCount - segmentStart, curClipped, curClip);
            segmentStart = indexCount;
        }
    }

    /// Restrict following draws to a pixel rect (intersected with the enclosing clip).
    private void pushClip(float x, float y, float w, float h) nothrow @nogc {
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
    private void popClip() nothrow @nogc {
        closeSegment();
        if (clipDepth > 0) {
            immutable prev = clipStack[--clipDepth];
            curClipped = prev.clipped;
            curClip = prev.rect;
        } else {
            curClipped = false;
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

    /// Draw a UTF-8 text string using the font atlas.
    void drawText(
        ref Font font,
        float x, float y,
        scope const(char)[] text,
        in Color4 color
    ) nothrow {
        if (text.length == 0 || !font.isLoaded) return;

        float curX = x;
        float curY = y + font.lineHeight * 0.75f; // baseline offset

        size_t i = 0;
        while (i < text.length) {
            immutable ubyte b = cast(ubyte)text[i++];
            int cp = b;
            if (b >= 0xC0) {
                if ((b & 0xE0) == 0xC0 && i < text.length) {
                    cp = ((b & 0x1F) << 6) | (cast(ubyte)text[i++] & 0x3F);
                } else if ((b & 0xF0) == 0xE0 && i + 1 < text.length) {
                    cp = ((b & 0x0F) << 12) | ((cast(ubyte)text[i++] & 0x3F) << 6) | (cast(ubyte)text[i++] & 0x3F);
                }
            }

            if (cp == '\n') {
                curX = x;
                curY += font.lineHeight;
                continue;
            }

            Glyph g = font.getGlyph(cp);
            if (g.width > 0 && g.height > 0) {
                if (vertexCount + 4 > MAX_VERTICES || indexCount + 6 > MAX_INDICES) break;

                immutable float gx0 = curX + g.xOffset;
                immutable float gy0 = curY + g.yOffset;
                immutable float gx1 = gx0 + g.width;
                immutable float gy1 = gy0 + g.height;
                immutable uint vStart = vertexCount;

                // Mode 1 = Font glyph
                vertices[vertexCount++] = UiVertex(gx0, gy0, g.u0, g.v0, color.r, color.g, color.b, color.a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.0f);
                vertices[vertexCount++] = UiVertex(gx1, gy0, g.u1, g.v0, color.r, color.g, color.b, color.a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.0f);
                vertices[vertexCount++] = UiVertex(gx1, gy1, g.u1, g.v1, color.r, color.g, color.b, color.a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.0f);
                vertices[vertexCount++] = UiVertex(gx0, gy1, g.u0, g.v1, color.r, color.g, color.b, color.a, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.0f);

                indices[indexCount++] = vStart + 0;
                indices[indexCount++] = vStart + 1;
                indices[indexCount++] = vStart + 2;
                indices[indexCount++] = vStart + 2;
                indices[indexCount++] = vStart + 3;
                indices[indexCount++] = vStart + 0;
            }

            curX += g.advance;
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

        // Render inline text
        if (n.textLen > 0) {
            immutable float lh = n.textHeight > 0 ? n.textHeight : font.lineHeight();
            float tx = n.layoutX + n.style.padding[3];
            float ty = n.layoutY + n.style.padding[0];
            if (n.layoutHeight > lh) ty = n.layoutY + (n.layoutHeight - lh) * 0.5f;
            if (n.style.justifyContent == UiJustify.center && n.textWidth > 0)
                tx = n.layoutX + (n.layoutWidth - n.textWidth) * 0.5f;
            drawText(font, tx, ty, n.text, n.style.textColor);
        }

        // Render children (optionally clipped to this node's box)
        immutable bool clip = n.style.clipChildren;
        if (clip) pushClip(n.layoutX, n.layoutY, n.layoutWidth, n.layoutHeight);
        UiNodeId child = n.firstChild;
        while (child.isValid()) {
            renderTree(tree, child, font);
            child = tree.get(child).nextSibling;
        }
        if (clip) popClip();
    }

    /// Flush the batch into GPU commands inside an active render pass.
    void flush(WGPURenderPassEncoder pass, float screenW, float screenH) nothrow @nogc @trusted {
        if (indexCount == 0 || vertexCount == 0) return;

        // Upload screenSize uniform
        float[2] u = [screenW, screenH];
        wgpuQueueWriteBuffer(queue, uniformBuffer, 0, u.ptr, 8);

        // Upload vertices & indices
        wgpuQueueWriteBuffer(queue, vertexBuffer, 0, vertices.ptr, vertexCount * UiVertex.sizeof);
        wgpuQueueWriteBuffer(queue, indexBuffer, 0, indices.ptr, indexCount * uint.sizeof);

        // Bind pipeline, buffers, and textures
        wgpuRenderPassEncoderSetPipeline(pass, pipeline);
        wgpuRenderPassEncoderSetBindGroup(pass, 0, defaultBindGroup, 0, null);
        wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vertexBuffer, 0, vertexCount * UiVertex.sizeof);
        wgpuRenderPassEncoderSetIndexBuffer(pass, indexBuffer, WGPUIndexFormat.uint32, 0, indexCount * uint.sizeof);

        // One draw per clip segment, each with its own scissor rect
        closeSegment();
        immutable uint sw = cast(uint) screenW;
        immutable uint sh = cast(uint) screenH;
        foreach (ref seg; segments[0 .. segmentCount]) {
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
