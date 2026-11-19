/// 2D sprite renderer, orthographic camera, texture-atlas regions, and frame animation.
///
/// Supports both the HDR scene pass (before `App.resolvePost`, enabling bloom
/// and tone mapping on emissive/glowing sprites) and the LDR present pass
/// (after `App.resolvePost`, for crisp HUD/2D overlays). All per-frame paths
/// are `@nogc` and engine storage types satisfy `isPod`.
module engine.graphics.sprite;

import std.math : cos, sin;

import bindings.wgpu;
import engine.core.log;
import engine.core.pod : isPod, Pod;
import engine.gpu.buffer : createDynamicVertexBuffer, createIndexBuffer,
    createUniformBuffer, createVertexBuffer, destroyBuffer, updateBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : sprite2dShaderSource;
import engine.graphics.texture : Texture, TextureFilter;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec2;

@safe:

/// Alpha blending mode for 2D sprites.
enum SpriteBlendMode : ubyte {
    alpha = 0,
    additive = 1,
}

/// 2D orthographic camera with position, zoom, rotation, and coordinate helpers.
///
/// By default (`yDown = true`), `(0, 0)` is top-left and `+Y` points down,
/// matching screen coordinates and `UiBatchRenderer`. Use `Camera2D.world(...)`
/// for Y-up world coordinates centered on the camera position.
struct Camera2D {
    Vec2 position = Vec2(0.0f, 0.0f);
    Vec2 viewportSize = Vec2(1280.0f, 720.0f);
    float zoom = 1.0f;
    float rotation = 0.0f; /// Clockwise (when yDown) / CCW (when yUp) angle in radians.
    float near = -1000.0f;
    float far = 1000.0f;
    bool yDown = true;

    /// Top-left `(0, 0)` to `(width, height)` pixel-space 2D camera.
    static Camera2D screen(float width, float height) pure nothrow @nogc {
        Camera2D c;
        immutable float w = width > 0.0f ? width : 1.0f;
        immutable float h = height > 0.0f ? height : 1.0f;
        c.position = Vec2(w * 0.5f, h * 0.5f);
        c.viewportSize = Vec2(w, h);
        c.zoom = 1.0f;
        c.rotation = 0.0f;
        c.yDown = true;
        return c;
    }

    /// World-centered 2D camera. Defaults to Y-up (`yDown = false`).
    static Camera2D world(
        float viewWidth,
        float viewHeight,
        Vec2 center = Vec2(0.0f, 0.0f),
        float zoom = 1.0f,
        bool yDown = false
    ) pure nothrow @nogc {
        Camera2D c;
        c.position = center;
        c.viewportSize = Vec2(viewWidth > 0.0f ? viewWidth : 1.0f,
                              viewHeight > 0.0f ? viewHeight : 1.0f);
        c.zoom = zoom > 0.0001f ? zoom : 0.0001f;
        c.rotation = 0.0f;
        c.yDown = yDown;
        return c;
    }

    /// Orthographic view-projection matrix matching WebGPU clip space (`Z in [0, 1]`).
    Mat4 viewProjection() const pure nothrow @nogc {
        immutable float z = zoom > 0.0001f ? zoom : 0.0001f;
        immutable float vw = viewportSize.x > 0.0f ? viewportSize.x : 1.0f;
        immutable float vh = viewportSize.y > 0.0f ? viewportSize.y : 1.0f;
        immutable float halfW = (vw * 0.5f) / z;
        immutable float halfH = (vh * 0.5f) / z;
        immutable float sx = 1.0f / halfW;
        immutable float sy = yDown ? (-1.0f / halfH) : (1.0f / halfH);
        immutable float dz = (far - near) != 0.0f ? (far - near) : 1.0f;
        immutable float sz = -1.0f / dz;
        immutable float tz = -near / dz;
        immutable float c = cos(rotation);
        immutable float s = sin(rotation);
        immutable float px = position.x;
        immutable float py = position.y;

        Mat4 r;
        r.m[] = 0.0f;
        r.m[0]  =  c * sx;
        r.m[1]  = -s * sy;
        r.m[4]  =  s * sx;
        r.m[5]  =  c * sy;
        r.m[10] =  sz;
        r.m[12] = -(px * c + py * s) * sx;
        r.m[13] =  (px * s - py * c) * sy;
        r.m[14] =  tz;
        r.m[15] =  1.0f;
        return r;
    }

    /// Convert a screen pixel coordinate (`(0, 0)` top-left) into 2D world coordinates.
    Vec2 screenToWorld(Vec2 screenPx) const pure nothrow @nogc {
        immutable float z = zoom > 0.0001f ? zoom : 0.0001f;
        immutable float rx = (screenPx.x - viewportSize.x * 0.5f) / z;
        immutable float rawY = (screenPx.y - viewportSize.y * 0.5f) / z;
        immutable float ry = yDown ? rawY : -rawY;
        immutable float c = cos(rotation);
        immutable float s = sin(rotation);
        return Vec2(
            position.x + rx * c - ry * s,
            position.y + rx * s + ry * c
        );
    }

    /// Convert a 2D world coordinate into screen pixel coordinates (`(0, 0)` top-left).
    Vec2 worldToScreen(Vec2 worldPos) const pure nothrow @nogc {
        immutable float z = zoom > 0.0001f ? zoom : 0.0001f;
        immutable float dx = worldPos.x - position.x;
        immutable float dy = worldPos.y - position.y;
        immutable float c = cos(rotation);
        immutable float s = sin(rotation);
        immutable float rx = dx * c + dy * s;
        immutable float ry = -dx * s + dy * c;
        immutable float sy = yDown ? ry : -ry;
        return Vec2(
            rx * z + viewportSize.x * 0.5f,
            sy * z + viewportSize.y * 0.5f
        );
    }
}
static assert(isPod!Camera2D);

/// POD 2D transform component suitable for ECS `World!(...)`.
struct Transform2D {
    Vec2 position = Vec2(0.0f, 0.0f);
    Vec2 scale = Vec2(1.0f, 1.0f);
    float rotation = 0.0f;
}
static assert(isPod!Transform2D);

/// Normalized UV sub-rectangle inside a texture or spritesheet.
struct SpriteRegion {
    float u0 = 0.0f;
    float v0 = 0.0f;
    float u1 = 1.0f;
    float v1 = 1.0f;

    static SpriteRegion full() pure nothrow @nogc {
        return SpriteRegion(0.0f, 0.0f, 1.0f, 1.0f);
    }

    /// Build a UV region from pixel coordinates in a `(texW × texH)` texture.
    static SpriteRegion fromPixels(
        float x, float y, float w, float h,
        uint texW, uint texH
    ) pure nothrow @nogc {
        if (texW == 0 || texH == 0) return full();
        immutable float invW = 1.0f / cast(float) texW;
        immutable float invH = 1.0f / cast(float) texH;
        return SpriteRegion(
            x * invW,
            y * invH,
            (x + w) * invW,
            (y + h) * invH
        );
    }

    /// Build a UV region for cell `(col, row)` in a uniform `(cols × rows)` grid.
    static SpriteRegion fromGrid(uint col, uint row, uint cols, uint rows) pure nothrow @nogc {
        if (cols == 0 || rows == 0) return full();
        immutable uint c = col < cols ? col : (cols - 1);
        immutable uint r = row < rows ? row : (rows - 1);
        immutable float cw = 1.0f / cast(float) cols;
        immutable float ch = 1.0f / cast(float) rows;
        return SpriteRegion(
            c * cw,
            r * ch,
            (c + 1) * cw,
            (r + 1) * ch
        );
    }

    /// Build a UV region for a row-major linear `frameIdx` in a `(cols × rows)` grid.
    static SpriteRegion fromFrameIndex(uint frameIdx, uint cols, uint rows) pure nothrow @nogc {
        if (cols == 0 || rows == 0) return full();
        immutable uint total = cols * rows;
        immutable uint idx = frameIdx < total ? frameIdx : (total - 1);
        return fromGrid(idx % cols, idx / cols, cols, rows);
    }

    /// Return a copy of this region with U and/or V coordinates mirrored.
    SpriteRegion flipped(bool flipX, bool flipY) const pure nothrow @nogc {
        return SpriteRegion(
            flipX ? u1 : u0,
            flipY ? v1 : v0,
            flipX ? u0 : u1,
            flipY ? v0 : v1
        );
    }
}
static assert(isPod!SpriteRegion);

/// POD flipbook animation state for grid-based spritesheets.
struct SpriteAnim {
    uint startFrame = 0;
    uint frameCount = 1;
    uint columns = 1;
    uint rows = 1;
    float fps = 12.0f;
    bool loop = true;
    float elapsed = 0.0f;

    static SpriteAnim create(
        uint columns,
        uint rows,
        uint startFrame,
        uint frameCount,
        float fps = 12.0f,
        bool loop = true
    ) pure nothrow @nogc {
        SpriteAnim a;
        a.columns = columns > 0 ? columns : 1;
        a.rows = rows > 0 ? rows : 1;
        a.startFrame = startFrame;
        a.frameCount = frameCount > 0 ? frameCount : 1;
        a.fps = fps >= 0.0f ? fps : 0.0f;
        a.loop = loop;
        a.elapsed = 0.0f;
        return a;
    }

    void update(float dt) pure nothrow @nogc {
        if (dt > 0.0f) elapsed += dt;
    }

    void reset() pure nothrow @nogc {
        elapsed = 0.0f;
    }

    /// Current linear frame index within the spritesheet grid.
    uint currentFrame() const pure nothrow @nogc {
        if (frameCount <= 1 || fps <= 0.0f) return startFrame;
        immutable double rawStep = cast(double) elapsed * cast(double) fps;
        if (rawStep <= 0.0) return startFrame;
        immutable uint step = cast(uint) rawStep;
        if (loop) {
            return startFrame + (step % frameCount);
        }
        immutable uint clamped = step >= frameCount ? (frameCount - 1) : step;
        return startFrame + clamped;
    }

    /// Normalized UV region for the current frame.
    SpriteRegion currentRegion() const pure nothrow @nogc {
        return SpriteRegion.fromFrameIndex(currentFrame(), columns, rows);
    }

    /// `true` once a non-looping animation has reached its final frame.
    bool finished() const pure nothrow @nogc {
        if (loop || frameCount <= 1 || fps <= 0.0f) return false;
        return elapsed * fps >= cast(float)(frameCount - 1);
    }
}
static assert(isPod!SpriteAnim);

/// POD 2D sprite descriptor / ECS component.
struct Sprite {
    Vec2 position = Vec2(0.0f, 0.0f);
    Vec2 size = Vec2(32.0f, 32.0f);
    Vec2 origin = Vec2(0.5f, 0.5f); /// Normalized pivot: `(0, 0)` corner, `(0.5, 0.5)` center.
    float rotation = 0.0f;
    Color4 tint = Color4(1.0f, 1.0f, 1.0f, 1.0f);
    SpriteRegion region = SpriteRegion(0.0f, 0.0f, 1.0f, 1.0f);
    int layer = 0;
    float zOrder = 0.0f;
    bool flipX = false;
    bool flipY = false;
    SpriteBlendMode blend = SpriteBlendMode.alpha;

    /// Return a copy offset, scaled, and rotated by `xf`.
    Sprite transformed(in Transform2D xf) const pure nothrow @nogc {
        Sprite s = this;
        immutable float c = cos(xf.rotation);
        immutable float sn = sin(xf.rotation);
        immutable float px = position.x * xf.scale.x;
        immutable float py = position.y * xf.scale.y;
        s.position = Vec2(
            xf.position.x + px * c - py * sn,
            xf.position.y + px * sn + py * c
        );
        s.size = Vec2(size.x * xf.scale.x, size.y * xf.scale.y);
        s.rotation = rotation + xf.rotation;
        return s;
    }
}
static assert(isPod!Sprite);

/// Per-instance GPU payload uploaded to Buffer 1 (64 bytes, 16-byte aligned).
struct SpriteInstance {
    float[4] posSize = [0.0f, 0.0f, 0.0f, 0.0f];
    float[4] uvRect = [0.0f, 0.0f, 1.0f, 1.0f];
    float[4] color = [1.0f, 1.0f, 1.0f, 1.0f];
    float[4] originSinCos = [0.5f, 0.5f, 0.0f, 1.0f];
}
static assert(SpriteInstance.sizeof == 64);
static assert(isPod!SpriteInstance);

package struct SpriteCmd {
    size_t viewKey = 0; // Opaque key from WGPUTextureView pointer to keep SpriteCmd POD.
    float[4] posSize = [0.0f, 0.0f, 0.0f, 0.0f];
    float[4] uvRect = [0.0f, 0.0f, 1.0f, 1.0f];
    float[4] color = [1.0f, 1.0f, 1.0f, 1.0f];
    float[4] originSinCos = [0.5f, 0.5f, 0.0f, 1.0f];
    int layer = 0;
    float zOrder = 0.0f;
    uint sequence = 0;
    SpriteBlendMode blend = SpriteBlendMode.alpha;
    TextureFilter filter = TextureFilter.linear;
}
static assert(isPod!SpriteCmd);

/// Strict total ordering by `(layer, zOrder, sequence)` for deterministic painter's order.
package bool spriteCmdLess(in SpriteCmd a, in SpriteCmd b) pure nothrow @nogc {
    if (a.layer != b.layer) return a.layer < b.layer;
    if (a.zOrder != b.zOrder) return a.zOrder < b.zOrder;
    return a.sequence < b.sequence;
}

/// In-place `@nogc` ShellSort over `order` indices into `cmds`.
package void sortSpriteOrder(const(SpriteCmd)[] cmds, uint[] order) pure nothrow @nogc {
    immutable size_t n = order.length;
    if (n <= 1) return;

    for (size_t gap = n / 2; gap > 0; gap /= 2) {
        foreach (i; gap .. n) {
            immutable uint keyIdx = order[i];
            size_t j = i;
            while (j >= gap && spriteCmdLess(cmds[keyIdx], cmds[order[j - gap]])) {
                order[j] = order[j - gap];
                j -= gap;
            }
            order[j] = keyIdx;
        }
    }
}

/// Count how many coalesced draw calls `order` produces across consecutive matching state.
package uint countSpriteDrawRuns(const(SpriteCmd)[] cmds, const(uint)[] order) pure nothrow @nogc {
    if (order.length == 0) return 0;
    uint runs = 1;
    auto prev = &cmds[order[0]];
    foreach (idx; order[1 .. $]) {
        auto cur = &cmds[idx];
        if (cur.viewKey != prev.viewKey || cur.blend != prev.blend || cur.filter != prev.filter) {
            runs++;
            prev = cur;
        }
    }
    return runs;
}

/// Batched, instanced 2D sprite renderer with sorting and texture bind-group caching.
///
/// Typical usage inside `App`:
/// ---
/// // After app.resolvePost(frame) for crisp LDR 2D, or before resolvePost for HDR bloom:
/// sprites.begin(cam2d);
/// sprites.draw(sheetTex, playerSprite);
/// sprites.end(frame);
/// ---
struct SpriteRenderer {
    private enum MAX_TEXTURE_BINDGROUPS = 128;

    private struct TexBgEntry {
        size_t viewKey = 0;
        TextureFilter filter = TextureFilter.linear;
        WGPUBindGroup bg = null;
    }

    private WGPUDevice device;
    private WGPUQueue queue;
    private WGPUTextureFormat ldrFormat;
    private WGPUTextureFormat hdrFormat;

    private WGPUShaderModule shaderModule;
    private WGPUBindGroupLayout bindGroupLayout;
    private WGPUPipelineLayout pipelineLayout;
    private WGPURenderPipeline ldrAlphaPipeline;
    private WGPURenderPipeline ldrAdditivePipeline;
    private WGPURenderPipeline hdrAlphaPipeline;
    private WGPURenderPipeline hdrAdditivePipeline;

    private WGPUBuffer quadVertexBuffer;
    private WGPUBuffer quadIndexBuffer;
    private WGPUBuffer uniformBuffer;
    private WGPUBuffer instanceBuffer;

    private WGPUSampler samplerNearest;
    private WGPUSampler samplerLinear;
    private Texture whiteTexture;

    private TexBgEntry[MAX_TEXTURE_BINDGROUPS] textureBgs;
    private uint textureBgCount = 0;
    private uint nextEvictSlot = 0;

    private Pod!SpriteCmd[] commands;
    private Pod!uint[] sortOrder;
    private Pod!SpriteInstance[] instances;
    private uint maxSprites = 0;
    private uint commandCount = 0;
    private uint lastDrawCalls = 0;

    private TextureFilter activeFilter = TextureFilter.linear;
    private bool sortEnabled = true;
    private bool needsSort = false;
    private bool flipVForYUp = false;
    private bool capacityWarned = false;
    private Mat4 activeViewProj = Mat4.init;

    @disable this(this);

    /// Initialize GPU pipelines, buffers, samplers, and pre-allocated command storage.
    static SpriteRenderer create(
        ref GpuContext gpu,
        uint maxSprites = 16_384,
        TextureFilter defaultFilter = TextureFilter.linear
    ) @trusted {
        SpriteRenderer r;
        r.device = gpu.getDevice();
        r.queue = gpu.getQueue();
        r.ldrFormat = gpu.getFormat();
        r.hdrFormat = Renderer.sceneFormat();
        r.maxSprites = maxSprites > 0 ? maxSprites : 1;
        r.activeFilter = defaultFilter;

        r.commands.length = r.maxSprites;
        r.sortOrder.length = r.maxSprites;
        r.instances.length = r.maxSprites;

        r.shaderModule = createShaderModule(r.device, sprite2dShaderSource, "sprite2d");
        if (r.shaderModule is null) {
            fatal("SpriteRenderer: failed to create shader module");
        }

        WGPUBindGroupLayoutEntry[3] bglEntries;
        bglEntries[0].binding = 0;
        bglEntries[0].visibility = WGPUShaderStage.vertex;
        bglEntries[0].buffer.type = WGPUBufferBindingType.uniform;
        bglEntries[0].buffer.minBindingSize = 64;

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
        r.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(r.device, &bglDesc);

        WGPUPipelineLayoutDescriptor plDesc;
        plDesc.bindGroupLayoutCount = 1;
        plDesc.bindGroupLayouts = &r.bindGroupLayout;
        r.pipelineLayout = wgpuDeviceCreatePipelineLayout(r.device, &plDesc);

        if (!buildAllPipelines(
            r.device, r.pipelineLayout, r.shaderModule, r.ldrFormat, r.hdrFormat,
            r.ldrAlphaPipeline, r.ldrAdditivePipeline, r.hdrAlphaPipeline, r.hdrAdditivePipeline
        )) {
            fatal("SpriteRenderer: failed to create render pipelines");
        }

        static immutable float[8] quadVerts = [
            0.0f, 0.0f,
            1.0f, 0.0f,
            1.0f, 1.0f,
            0.0f, 1.0f,
        ];
        static immutable ushort[6] quadIndices = [0, 1, 2, 2, 3, 0];

        r.quadVertexBuffer = createVertexBuffer(r.device, r.queue, quadVerts[]);
        r.quadIndexBuffer = createIndexBuffer(r.device, r.queue, quadIndices[]);
        r.uniformBuffer = createUniformBuffer(r.device, 64);
        r.instanceBuffer = createDynamicVertexBuffer(r.device, cast(ulong) r.maxSprites * SpriteInstance.sizeof);

        r.samplerNearest = createSpriteSampler(r.device, WGPUFilterMode.nearest);
        r.samplerLinear = createSpriteSampler(r.device, WGPUFilterMode.linear);
        r.whiteTexture = Texture.solid(gpu, 255, 255, 255, 255);

        info("SpriteRenderer ready (capacity=", r.maxSprites, ")");
        return r;
    }

    void setFilter(TextureFilter filter) nothrow @nogc {
        activeFilter = filter;
    }

    TextureFilter filter() const nothrow @nogc pure {
        return activeFilter;
    }

    void setSorting(bool enabled) nothrow @nogc {
        sortEnabled = enabled;
    }

    bool sorting() const nothrow @nogc pure {
        return sortEnabled;
    }

    /// Release cached texture bind groups (call after destroying textures in long-lived scenes).
    void clearTextureCache() nothrow @nogc @trusted {
        foreach (i; 0 .. textureBgCount) {
            if (textureBgs[i].bg !is null) {
                wgpuBindGroupRelease(textureBgs[i].bg);
            }
            textureBgs[i] = TexBgEntry.init;
        }
        textureBgCount = 0;
        nextEvictSlot = 0;
    }

    /// Begin a 2D sprite batch using `camera`.
    void begin(ref const Camera2D camera) nothrow @nogc {
        beginMat(camera.viewProjection(), !camera.yDown);
    }

    /// Convenience: begin a top-left `(0, 0)` to `(width, height)` pixel-space batch.
    void beginScreen(uint width, uint height) nothrow @nogc {
        auto cam = Camera2D.screen(cast(float) width, cast(float) height);
        begin(cam);
    }

    /// Begin a batch with an explicit view-projection matrix (`yUp = true` flips sprite V for Y-up worlds).
    void beginMat(Mat4 viewProj, bool yUp = false) nothrow @nogc {
        activeViewProj = viewProj;
        flipVForYUp = yUp;
        commandCount = 0;
        lastDrawCalls = 0;
        needsSort = false;
        capacityWarned = false;
    }

    /// Queue a `Sprite` drawn with `tex`.
    void draw(ref const Texture tex, in Sprite sprite) nothrow @nogc {
        if (!tex.valid || tex.view is null) return;
        immutable auto r = sprite.region.flipped(sprite.flipX, sprite.flipY);
        pushCommand(
            viewPtrToKey(tex.view),
            sprite.position,
            sprite.size,
            r,
            sprite.tint,
            sprite.rotation,
            sprite.origin,
            sprite.layer,
            sprite.zOrder,
            sprite.blend
        );
    }

    /// Queue a full texture quad.
    void draw(
        ref const Texture tex,
        Vec2 pos,
        Vec2 size,
        in Color4 tint = Color4.white(),
        float rotation = 0.0f,
        Vec2 origin = Vec2(0.5f, 0.5f),
        int layer = 0,
        float zOrder = 0.0f,
        SpriteBlendMode blend = SpriteBlendMode.alpha
    ) nothrow @nogc {
        drawRegion(tex, SpriteRegion.full(), pos, size, tint, rotation, origin,
                   false, false, layer, zOrder, blend);
    }

    /// Queue a sub-region of `tex` (e.g. from a spritesheet or texture atlas).
    void drawRegion(
        ref const Texture tex,
        in SpriteRegion region,
        Vec2 pos,
        Vec2 size,
        in Color4 tint = Color4.white(),
        float rotation = 0.0f,
        Vec2 origin = Vec2(0.5f, 0.5f),
        bool flipX = false,
        bool flipY = false,
        int layer = 0,
        float zOrder = 0.0f,
        SpriteBlendMode blend = SpriteBlendMode.alpha
    ) nothrow @nogc {
        if (!tex.valid || tex.view is null) return;
        immutable auto r = region.flipped(flipX, flipY);
        pushCommand(
            viewPtrToKey(tex.view),
            pos, size, r, tint, rotation, origin, layer, zOrder, blend
        );
    }

    /// Queue the current frame of a `SpriteAnim`.
    void drawAnim(
        ref const Texture tex,
        ref const SpriteAnim anim,
        Vec2 pos,
        Vec2 size,
        in Color4 tint = Color4.white(),
        float rotation = 0.0f,
        Vec2 origin = Vec2(0.5f, 0.5f),
        bool flipX = false,
        bool flipY = false,
        int layer = 0,
        float zOrder = 0.0f,
        SpriteBlendMode blend = SpriteBlendMode.alpha
    ) nothrow @nogc {
        drawRegion(tex, anim.currentRegion(), pos, size, tint, rotation, origin,
                   flipX, flipY, layer, zOrder, blend);
    }

    /// Queue a solid colored rectangle using the internal 1×1 white texture.
    void drawRect(
        Vec2 pos,
        Vec2 size,
        in Color4 color,
        float rotation = 0.0f,
        Vec2 origin = Vec2(0.5f, 0.5f),
        int layer = 0,
        float zOrder = 0.0f,
        SpriteBlendMode blend = SpriteBlendMode.alpha
    ) nothrow @nogc {
        if (!whiteTexture.valid || whiteTexture.view is null) return;
        pushCommand(
            viewPtrToKey(whiteTexture.view),
            pos, size, SpriteRegion.full(), color, rotation, origin, layer, zOrder, blend
        );
    }

    /// Sort (if enabled), upload instances, and emit coalesced instanced draws into `frame`.
    void end(ref FrameContext frame) nothrow @nogc @trusted {
        if (!frame.valid || frame.pass is null || commandCount == 0) {
            lastDrawCalls = 0;
            return;
        }
        if (device is null || queue is null) return;

        // Upload active view-projection matrix once per flush.
        updateBuffer(queue, uniformBuffer, activeViewProj.m.ptr, 64);

        auto orderSlice = sortOrder[0 .. commandCount];
        if (sortEnabled && needsSort && commandCount > 1) {
            sortSpriteOrder(commands[0 .. commandCount], orderSlice);
        }

        foreach (i; 0 .. commandCount) {
            immutable auto cmd = commands[orderSlice[i]];
            instances[i] = SpriteInstance(cmd.posSize, cmd.uvRect, cmd.color, cmd.originSinCos);
        }

        updateBuffer(queue, instanceBuffer, instances.ptr, cast(size_t) commandCount * SpriteInstance.sizeof);

        frame.setVertexBuffer(0, quadVertexBuffer, 32);
        frame.setIndexBuffer(quadIndexBuffer, WGPUIndexFormat.uint16, 12);

        immutable bool isLdr = frame.postResolved;
        uint runs = 0;
        uint runStart = 0;
        while (runStart < commandCount) {
            immutable auto firstCmd = commands[orderSlice[runStart]];
            uint runEnd = runStart + 1;
            while (runEnd < commandCount) {
                immutable auto nextCmd = commands[orderSlice[runEnd]];
                if (nextCmd.viewKey != firstCmd.viewKey
                    || nextCmd.blend != firstCmd.blend
                    || nextCmd.filter != firstCmd.filter)
                {
                    break;
                }
                runEnd++;
            }

            immutable uint runCount = runEnd - runStart;
            auto pipe = selectPipeline(isLdr, firstCmd.blend);
            auto bg = getOrCreateBindGroup(firstCmd.viewKey, firstCmd.filter);
            if (pipe !is null && bg !is null) {
                frame.setPipeline(pipe);
                frame.setBindGroup(0, bg);
                frame.setVertexBuffer(
                    1,
                    instanceBuffer,
                    cast(ulong) runCount * SpriteInstance.sizeof,
                    cast(ulong) runStart * SpriteInstance.sizeof
                );
                frame.drawIndexed(6, runCount);
                runs++;
            }

            runStart = runEnd;
        }
        lastDrawCalls = runs;
    }

    /// Transactional shader hot-reload: keeps existing pipelines if compilation fails.
    bool reloadShader(scope const(char)[] newWgsl) nothrow @nogc @trusted {
        if (device is null || pipelineLayout is null || newWgsl.length == 0) return false;
        auto newModule = createShaderModule(device, newWgsl, "reload_sprite2d");
        if (newModule is null) return false;

        WGPURenderPipeline nLdrAlpha, nLdrAdd, nHdrAlpha, nHdrAdd;
        if (!buildAllPipelines(
            device, pipelineLayout, newModule, ldrFormat, hdrFormat,
            nLdrAlpha, nLdrAdd, nHdrAlpha, nHdrAdd
        )) {
            if (nLdrAlpha !is null) wgpuRenderPipelineRelease(nLdrAlpha);
            if (nLdrAdd !is null)   wgpuRenderPipelineRelease(nLdrAdd);
            if (nHdrAlpha !is null) wgpuRenderPipelineRelease(nHdrAlpha);
            if (nHdrAdd !is null)   wgpuRenderPipelineRelease(nHdrAdd);
            wgpuShaderModuleRelease(newModule);
            return false;
        }

        if (ldrAlphaPipeline !is null)    wgpuRenderPipelineRelease(ldrAlphaPipeline);
        if (ldrAdditivePipeline !is null) wgpuRenderPipelineRelease(ldrAdditivePipeline);
        if (hdrAlphaPipeline !is null)    wgpuRenderPipelineRelease(hdrAlphaPipeline);
        if (hdrAdditivePipeline !is null) wgpuRenderPipelineRelease(hdrAdditivePipeline);
        if (shaderModule !is null)        wgpuShaderModuleRelease(shaderModule);

        shaderModule = newModule;
        ldrAlphaPipeline = nLdrAlpha;
        ldrAdditivePipeline = nLdrAdd;
        hdrAlphaPipeline = nHdrAlpha;
        hdrAdditivePipeline = nHdrAdd;
        return true;
    }

    uint spriteCount() const nothrow @nogc pure { return commandCount; }
    uint drawCallCount() const nothrow @nogc pure { return lastDrawCalls; }
    uint capacity() const nothrow @nogc pure { return maxSprites; }

    void destroy() nothrow @nogc @trusted {
        clearTextureCache();
        whiteTexture.destroy();

        if (samplerNearest !is null) { wgpuSamplerRelease(samplerNearest); samplerNearest = null; }
        if (samplerLinear !is null)  { wgpuSamplerRelease(samplerLinear); samplerLinear = null; }

        destroyBuffer(instanceBuffer);
        instanceBuffer = null;
        destroyBuffer(uniformBuffer);
        uniformBuffer = null;
        destroyBuffer(quadIndexBuffer);
        quadIndexBuffer = null;
        destroyBuffer(quadVertexBuffer);
        quadVertexBuffer = null;

        if (ldrAlphaPipeline !is null)    { wgpuRenderPipelineRelease(ldrAlphaPipeline); ldrAlphaPipeline = null; }
        if (ldrAdditivePipeline !is null) { wgpuRenderPipelineRelease(ldrAdditivePipeline); ldrAdditivePipeline = null; }
        if (hdrAlphaPipeline !is null)    { wgpuRenderPipelineRelease(hdrAlphaPipeline); hdrAlphaPipeline = null; }
        if (hdrAdditivePipeline !is null) { wgpuRenderPipelineRelease(hdrAdditivePipeline); hdrAdditivePipeline = null; }
        if (pipelineLayout !is null)      { wgpuPipelineLayoutRelease(pipelineLayout); pipelineLayout = null; }
        if (bindGroupLayout !is null)     { wgpuBindGroupLayoutRelease(bindGroupLayout); bindGroupLayout = null; }
        if (shaderModule !is null)        { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }

        commands = null;
        sortOrder = null;
        instances = null;
        commandCount = 0;
        lastDrawCalls = 0;
        device = null;
        queue = null;
    }

    // --- internals ---

    private void pushCommand(
        size_t viewKey,
        Vec2 pos,
        Vec2 size,
        in SpriteRegion region,
        in Color4 tint,
        float rotation,
        Vec2 origin,
        int layer,
        float zOrder,
        SpriteBlendMode blend
    ) nothrow @nogc {
        if (commandCount >= maxSprites || commands.length == 0) {
            if (!capacityWarned) {
                capacityWarned = true;
                warn("SpriteRenderer: batch capacity reached (maxSprites=", maxSprites, ")");
            }
            return;
        }

        immutable float v0 = flipVForYUp ? region.v1 : region.v0;
        immutable float v1 = flipVForYUp ? region.v0 : region.v1;

        SpriteCmd cmd;
        cmd.viewKey = viewKey;
        cmd.posSize = [pos.x, pos.y, size.x, size.y];
        cmd.uvRect = [region.u0, v0, region.u1, v1];
        cmd.color = [tint.r, tint.g, tint.b, tint.a];
        cmd.originSinCos = [origin.x, origin.y, sin(rotation), cos(rotation)];
        cmd.layer = layer;
        cmd.zOrder = zOrder;
        cmd.sequence = commandCount;
        cmd.blend = blend;
        cmd.filter = activeFilter;

        if (commandCount > 0 && spriteCmdLess(cmd, commands[commandCount - 1])) {
            needsSort = true;
        }
        commands[commandCount] = cmd;
        sortOrder[commandCount] = commandCount;
        commandCount++;
    }

    private static size_t viewPtrToKey(const WGPUTextureView view) nothrow @nogc @trusted {
        return cast(size_t) view;
    }

    private WGPURenderPipeline selectPipeline(bool isLdr, SpriteBlendMode blend) nothrow @nogc pure {
        if (isLdr) {
            return blend == SpriteBlendMode.additive ? ldrAdditivePipeline : ldrAlphaPipeline;
        }
        return blend == SpriteBlendMode.additive ? hdrAdditivePipeline : hdrAlphaPipeline;
    }

    private WGPUBindGroup getOrCreateBindGroup(size_t viewKey, TextureFilter filter) nothrow @nogc @trusted {
        if (viewKey == 0 || device is null || bindGroupLayout is null || uniformBuffer is null) {
            return null;
        }
        foreach (i; 0 .. textureBgCount) {
            if (textureBgs[i].viewKey == viewKey && textureBgs[i].filter == filter) {
                return textureBgs[i].bg;
            }
        }

        auto samp = filter == TextureFilter.nearest ? samplerNearest : samplerLinear;
        auto view = cast(WGPUTextureView) viewKey;
        if (samp is null || view is null) return null;

        WGPUBindGroupEntry[3] bgEntries;
        bgEntries[0].binding = 0;
        bgEntries[0].buffer = uniformBuffer;
        bgEntries[0].size = 64;

        bgEntries[1].binding = 1;
        bgEntries[1].sampler = samp;

        bgEntries[2].binding = 2;
        bgEntries[2].textureView = view;

        WGPUBindGroupDescriptor bgDesc;
        bgDesc.layout = bindGroupLayout;
        bgDesc.entryCount = 3;
        bgDesc.entries = bgEntries.ptr;
        auto bg = wgpuDeviceCreateBindGroup(device, &bgDesc);
        if (bg is null) return null;

        if (textureBgCount < MAX_TEXTURE_BINDGROUPS) {
            textureBgs[textureBgCount++] = TexBgEntry(viewKey, filter, bg);
        } else {
            if (textureBgs[nextEvictSlot].bg !is null) {
                wgpuBindGroupRelease(textureBgs[nextEvictSlot].bg);
            }
            textureBgs[nextEvictSlot] = TexBgEntry(viewKey, filter, bg);
            nextEvictSlot = (nextEvictSlot + 1) % MAX_TEXTURE_BINDGROUPS;
        }
        return bg;
    }

    private static WGPUSampler createSpriteSampler(WGPUDevice device, WGPUFilterMode mode) nothrow @nogc @trusted {
        WGPUSamplerDescriptor desc;
        desc.addressModeU = WGPUAddressMode.clampToEdge;
        desc.addressModeV = WGPUAddressMode.clampToEdge;
        desc.addressModeW = WGPUAddressMode.clampToEdge;
        desc.magFilter = mode;
        desc.minFilter = mode;
        desc.mipmapFilter = mode == WGPUFilterMode.nearest
            ? WGPUMipmapFilterMode.nearest : WGPUMipmapFilterMode.linear;
        auto s = wgpuDeviceCreateSampler(device, &desc);
        if (s is null) fatal("SpriteRenderer: failed to create sampler");
        return s;
    }

    private static bool buildAllPipelines(
        WGPUDevice device,
        WGPUPipelineLayout layout,
        WGPUShaderModule mod,
        WGPUTextureFormat ldrFmt,
        WGPUTextureFormat hdrFmt,
        out WGPURenderPipeline outLdrAlpha,
        out WGPURenderPipeline outLdrAdd,
        out WGPURenderPipeline outHdrAlpha,
        out WGPURenderPipeline outHdrAdd
    ) nothrow @nogc @trusted {
        outLdrAlpha = buildSpritePipeline(device, layout, mod, ldrFmt, SpriteBlendMode.alpha, false);
        if (outLdrAlpha is null) return false;

        outLdrAdd = buildSpritePipeline(device, layout, mod, ldrFmt, SpriteBlendMode.additive, false);
        if (outLdrAdd is null) return false;

        outHdrAlpha = buildSpritePipeline(device, layout, mod, hdrFmt, SpriteBlendMode.alpha, true);
        if (outHdrAlpha is null) return false;

        outHdrAdd = buildSpritePipeline(device, layout, mod, hdrFmt, SpriteBlendMode.additive, true);
        return outHdrAdd !is null;
    }

    private static WGPURenderPipeline buildSpritePipeline(
        WGPUDevice device,
        WGPUPipelineLayout layout,
        WGPUShaderModule mod,
        WGPUTextureFormat format,
        SpriteBlendMode blend,
        bool withDepth
    ) nothrow @nogc @trusted {
        WGPUVertexAttribute[1] vertAttr = [
            { format: WGPUVertexFormat.float32x2, offset: 0, shaderLocation: 0 },
        ];
        WGPUVertexAttribute[4] instAttrs = [
            { format: WGPUVertexFormat.float32x4, offset: 0,  shaderLocation: 1 },
            { format: WGPUVertexFormat.float32x4, offset: 16, shaderLocation: 2 },
            { format: WGPUVertexFormat.float32x4, offset: 32, shaderLocation: 3 },
            { format: WGPUVertexFormat.float32x4, offset: 48, shaderLocation: 4 },
        ];

        WGPUVertexBufferLayout[2] bufferLayouts = [
            {
                arrayStride: 8,
                stepMode: WGPUVertexStepMode.vertex,
                attributeCount: 1,
                attributes: vertAttr.ptr,
            },
            {
                arrayStride: SpriteInstance.sizeof,
                stepMode: WGPUVertexStepMode.instance_,
                attributeCount: 4,
                attributes: instAttrs.ptr,
            },
        ];

        WGPUBlendState blendState;
        blendState.color.operation = WGPUBlendOperation.add;
        blendState.color.srcFactor = WGPUBlendFactor.srcAlpha;
        blendState.color.dstFactor = blend == SpriteBlendMode.additive
            ? WGPUBlendFactor.one : WGPUBlendFactor.oneMinusSrcAlpha;
        blendState.alpha.operation = WGPUBlendOperation.add;
        blendState.alpha.srcFactor = WGPUBlendFactor.one;
        blendState.alpha.dstFactor = blend == SpriteBlendMode.additive
            ? WGPUBlendFactor.one : WGPUBlendFactor.oneMinusSrcAlpha;

        WGPUColorTargetState colorTarget;
        colorTarget.format = format;
        colorTarget.blend = &blendState;
        colorTarget.writeMask = WGPUColorWriteMask.all;

        WGPUFragmentState fragState;
        fragState.module_ = mod;
        fragState.entryPoint = wgpuStringView("fs_sprite");
        fragState.targetCount = 1;
        fragState.targets = &colorTarget;

        WGPUDepthStencilState depthState;
        if (withDepth) {
            depthState.format = WGPUTextureFormat.depth24Plus;
            depthState.depthWriteEnabled = WGPUOptionalBool.false_;
            depthState.depthCompare = WGPUCompareFunction.always;
        }

        WGPURenderPipelineDescriptor pipeDesc;
        pipeDesc.layout = layout;
        pipeDesc.vertex.module_ = mod;
        pipeDesc.vertex.entryPoint = wgpuStringView("vs_sprite");
        pipeDesc.vertex.bufferCount = 2;
        pipeDesc.vertex.buffers = bufferLayouts.ptr;
        pipeDesc.primitive.topology = WGPUPrimitiveTopology.triangleList;
        pipeDesc.primitive.frontFace = WGPUFrontFace.ccw;
        pipeDesc.primitive.cullMode = WGPUCullMode.none;
        pipeDesc.depthStencil = withDepth ? &depthState : null;
        pipeDesc.fragment = &fragState;

        return wgpuDeviceCreateRenderPipeline(device, &pipeDesc);
    }
}

@safe pure nothrow @nogc unittest {
    import std.math : fabs, PI;

    bool approx(float a, float b, float eps = 1e-3f) {
        return fabs(a - b) <= eps;
    }

    Vec2 mulPoint2D(in Mat4 m, float x, float y) {
        return Vec2(
            m.m[0] * x + m.m[4] * y + m.m[12],
            m.m[1] * x + m.m[5] * y + m.m[13]
        );
    }

    // 1. Camera2D.screen maps corners accurately into WebGPU NDC.
    {
        auto cam = Camera2D.screen(1280.0f, 720.0f);
        immutable vp = cam.viewProjection();

        immutable tl = mulPoint2D(vp, 0.0f, 0.0f);
        assert(approx(tl.x, -1.0f) && approx(tl.y, 1.0f));

        immutable br = mulPoint2D(vp, 1280.0f, 720.0f);
        assert(approx(br.x, 1.0f) && approx(br.y, -1.0f));

        immutable center = mulPoint2D(vp, 640.0f, 360.0f);
        assert(approx(center.x, 0.0f) && approx(center.y, 0.0f));
    }

    // 2. Camera2D.world (Y-up) + zoom + rotation round-trip screenToWorld <-> worldToScreen.
    {
        auto cam = Camera2D.world(800.0f, 600.0f, Vec2(100.0f, -50.0f), 2.5f);
        cam.rotation = cast(float)(PI / 6.0);

        immutable Vec2[3] samples = [Vec2(0.0f, 0.0f), Vec2(400.0f, 300.0f), Vec2(612.5f, 123.25f)];
        foreach (sp; samples) {
            immutable wp = cam.screenToWorld(sp);
            immutable back = cam.worldToScreen(wp);
            assert(approx(back.x, sp.x, 1e-2f) && approx(back.y, sp.y, 1e-2f));
        }

        // Verify worldToScreen agrees with viewProjection() clip-space mapping.
        immutable vp = cam.viewProjection();
        immutable wp = Vec2(137.0f, -22.0f);
        immutable clip = mulPoint2D(vp, wp.x, wp.y);
        immutable sxFromClip = (clip.x * 0.5f + 0.5f) * cam.viewportSize.x;
        immutable syFromClip = (0.5f - clip.y * 0.5f) * cam.viewportSize.y;
        immutable sxDirect = cam.worldToScreen(wp);
        assert(approx(sxDirect.x, sxFromClip, 1e-2f) && approx(sxDirect.y, syFromClip, 1e-2f));
    }

    // 3. SpriteRegion pixel/grid/frame/flip helpers.
    {
        immutable rPix = SpriteRegion.fromPixels(32, 64, 32, 64, 128, 256);
        assert(approx(rPix.u0, 0.25f) && approx(rPix.v0, 0.25f));
        assert(approx(rPix.u1, 0.50f) && approx(rPix.v1, 0.50f));

        immutable rGrid = SpriteRegion.fromGrid(2, 1, 4, 2);
        assert(approx(rGrid.u0, 0.50f) && approx(rGrid.v0, 0.50f));
        assert(approx(rGrid.u1, 0.75f) && approx(rGrid.v1, 1.00f));

        immutable rIdx = SpriteRegion.fromFrameIndex(6, 4, 2); // col=2, row=1
        assert(approx(rIdx.u0, rGrid.u0) && approx(rIdx.v0, rGrid.v0));
        assert(approx(rIdx.u1, rGrid.u1) && approx(rIdx.v1, rGrid.v1));

        immutable rFlip = rGrid.flipped(true, true);
        assert(approx(rFlip.u0, rGrid.u1) && approx(rFlip.u1, rGrid.u0));
        assert(approx(rFlip.v0, rGrid.v1) && approx(rFlip.v1, rGrid.v0));
    }

    // 4. SpriteAnim looping and non-looping progression.
    {
        auto anim = SpriteAnim.create(4, 2, 2, 3, 10.0f, true);
        assert(anim.currentFrame() == 2);
        anim.update(0.15f); // step = 1
        assert(anim.currentFrame() == 3);
        anim.update(0.20f); // elapsed=0.35 -> step=3 -> wraps to 2
        assert(anim.currentFrame() == 2);
        assert(!anim.finished());

        auto once = SpriteAnim.create(4, 2, 1, 3, 10.0f, false);
        assert(!once.finished());
        once.update(0.5f);
        assert(once.finished());
        assert(once.currentFrame() == 3);
        once.reset();
        assert(!once.finished());
        assert(once.currentFrame() == 1);
    }

    // 5. Sprite.transformed(Transform2D) composition.
    {
        Sprite s;
        s.position = Vec2(10.0f, 0.0f);
        s.size = Vec2(20.0f, 10.0f);
        s.rotation = 0.25f;

        Transform2D xf;
        xf.position = Vec2(100.0f, 50.0f);
        xf.scale = Vec2(2.0f, 3.0f);
        xf.rotation = cast(float)(PI * 0.5);

        immutable outSprite = s.transformed(xf);
        assert(approx(outSprite.position.x, 100.0f, 1e-2f));
        assert(approx(outSprite.position.y, 70.0f, 1e-2f));
        assert(approx(outSprite.size.x, 40.0f));
        assert(approx(outSprite.size.y, 30.0f));
        assert(approx(outSprite.rotation, 0.25f + xf.rotation));
    }

    // 6. Command sorting by (layer, zOrder, sequence) and draw-call run coalescing.
    {
        SpriteCmd[5] cmds;
        cmds[0] = SpriteCmd(viewKey: 1, layer: 1, zOrder: 0.0f, sequence: 0, blend: SpriteBlendMode.alpha);
        cmds[1] = SpriteCmd(viewKey: 2, layer: 0, zOrder: 5.0f, sequence: 1, blend: SpriteBlendMode.alpha);
        cmds[2] = SpriteCmd(viewKey: 1, layer: 0, zOrder: 1.0f, sequence: 2, blend: SpriteBlendMode.alpha);
        cmds[3] = SpriteCmd(viewKey: 1, layer: 0, zOrder: 1.0f, sequence: 3, blend: SpriteBlendMode.alpha);
        cmds[4] = SpriteCmd(viewKey: 1, layer: 1, zOrder: 0.0f, sequence: 4, blend: SpriteBlendMode.additive);

        uint[5] order = [0, 1, 2, 3, 4];
        sortSpriteOrder(cmds[], order[]);

        // Expected sorted sequence:
        // layer 0, z 1.0, seq 2 (tex 1, alpha)
        // layer 0, z 1.0, seq 3 (tex 1, alpha) -> coalesces with seq 2
        // layer 0, z 5.0, seq 1 (tex 2, alpha) -> new run
        // layer 1, z 0.0, seq 0 (tex 1, alpha) -> new run
        // layer 1, z 0.0, seq 4 (tex 1, add)   -> new run (different blend)
        assert(order[0] == 2);
        assert(order[1] == 3);
        assert(order[2] == 1);
        assert(order[3] == 0);
        assert(order[4] == 4);
        assert(countSpriteDrawRuns(cmds[], order[]) == 4);
    }
}
