/// Projected decals (skid marks, impacts, puddles, paint).
///
/// `DecalSystem` is a fixed-capacity POD ring buffer: `spawn` overwrites the
/// oldest decal when full, `update` ages decals and fades them out at the end
/// of their lifetime. `DecalRenderer` draws the visible ones as instanced
/// oriented boxes after the opaque pass (terrain included): it snapshots the
/// opaque depth, reconstructs the surface in the fragment shader, projects it
/// along the decal's local Z and lights it like the scene (CSM, lights, IBL,
/// fog, wetness). No allocation after creation.
///
///   auto decals = DecalSystem.create(1024);
///   auto dr = DecalRenderer.create(gpu, scene, albedoLayers, normalLayers, 256);
///   dr.attach(scene, app.renderer, decals);   // after dr reached its final address
///   decals.spawn(hit.point, hit.normal, Vec2(2, 2), 1.0f, angle, layer);
///   // per frame, before scene.end:  decals.update(dt); dr.update(decals, camera);
module engine.graphics.decals;

import std.math : cos, sin, sqrt, abs;

import bindings.wgpu;
import engine.core.log;
import engine.core.pod : isPod, Pod;
import engine.gpu.context : GpuContext;
import engine.gpu.renderer : FrameContext, Renderer, SnapshotParts;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : decalPbrShaderSource;
import engine.graphics.texture : Sampler, SamplerDesc, TextureArray, TextureDesc, TextureFilter, TextureWrap;
import engine.math.frustum : Frustum;
import engine.math.vec : Vec2, Vec3;
import engine.scene.camera : Camera;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

import engine.devtools.profiler : profileZone;
import engine.gpu.gpu_profiler : gpuFrameScope;

/// Per-instance GPU data (176 bytes, 11 vec4 attributes).
struct DecalInstanceGpu {
    float[16] model;
    float[16] invModel;
    float[4] tint = [1, 1, 1, 1];
    /// layer, opacity (after fades), angle-fade start (cos), normal strength.
    float[4] params = [0, 1, 0.3f, 1];
    /// roughness, metallic, wetness response, unused.
    float[4] params2 = [0.8f, 0, 1, 0];
}

static assert(isPod!DecalInstanceGpu && DecalInstanceGpu.sizeof == 176);

/// Optional spawn parameters.
struct DecalStyle {
    float[4] tint = [1, 1, 1, 1];
    float opacity = 1.0f;
    /// Faces whose normal is more than ~acos(angleFade) away from the
    /// projection axis fade out (prevents stretching on steep faces).
    float angleFade = 0.35f;
    float normalStrength = 1.0f;
    float roughness = 0.8f;
    float metallic = 0.0f;
    /// 0 = ignores rain wetness, 1 = darkens / glosses like the ground.
    float wetness = 1.0f;
    /// Seconds before fading starts (0 = permanent until overwritten).
    float lifetime = 0.0f;
    /// Fade-out duration after `lifetime`.
    float fadeOut = 2.0f;
}

struct Decal {
    DecalInstanceGpu gpu;
    Vec3 center;
    float radius = 0;
    float age = 0;
    float lifetime = 0;
    float fadeOut = 0;
    float baseOpacity = 1;
    bool alive = false;
}

static assert(isPod!Decal);

struct DecalSystem {
    Pod!Decal[] ring;
    /// Next slot to write (the oldest decal once the ring is full).
    uint head;
    uint liveCount;
    /// Visible instances for this frame (filled by `gather`).
    Pod!DecalInstanceGpu[] visible;
    uint visibleCount;

    static DecalSystem create(uint capacity) {
        assert(capacity > 0);
        DecalSystem s;
        s.ring = new Decal[capacity];
        s.visible = new DecalInstanceGpu[capacity];
        return s;
    }

    uint capacity() const pure nothrow @nogc { return cast(uint) ring.length; }

    /// Spawn a decal on a surface point. `normal` points out of the surface
    /// (projection axis), `size` is the footprint, `depth` the projection
    /// thickness, `rotation` spins it around the normal (radians). Returns
    /// the slot index. Overwrites the oldest decal when full.
    uint spawn(Vec3 position, Vec3 normal, Vec2 size, float depth, float rotation, uint layer,
               DecalStyle style = DecalStyle.init) pure nothrow @nogc {
        immutable slot = head;
        head = (head + 1) % capacity();
        auto d = &ring[slot];
        if (!d.alive) liveCount++;
        *d = Decal.init;
        d.alive = true;
        d.lifetime = style.lifetime;
        d.fadeOut = style.fadeOut > 0 ? style.fadeOut : 0.001f;
        d.baseOpacity = style.opacity;
        buildMatrices(position, normal, size, depth, rotation, d.gpu.model, d.gpu.invModel);
        d.gpu.tint = style.tint;
        d.gpu.params = [cast(float) layer, style.opacity, style.angleFade, style.normalStrength];
        d.gpu.params2 = [style.roughness, style.metallic, style.wetness, 0];
        d.center = position;
        d.radius = 0.5f * sqrt(size.x * size.x + size.y * size.y + depth * depth);
        return slot;
    }

    /// Remove a decal.
    void kill(uint slot) pure nothrow @nogc {
        if (slot < ring.length && ring[slot].alive) {
            ring[slot].alive = false;
            liveCount--;
        }
    }

    void clear() pure nothrow @nogc {
        foreach (ref d; ring) d.alive = false;
        liveCount = 0;
        head = 0;
    }

    /// Age decals; expired ones are removed, fading ones lose opacity.
    void update(float dt) pure nothrow @nogc {
        foreach (ref d; ring) {
            if (!d.alive) continue;
            d.age += dt;
            if (d.lifetime <= 0) continue;
            immutable t = (d.age - d.lifetime) / d.fadeOut;
            if (t >= 1.0f) {
                d.alive = false;
                liveCount--;
            } else if (t > 0) {
                d.gpu.params[1] = d.baseOpacity * (1.0f - t);
            }
        }
    }

    /// Fill `visible` with the decals intersecting `view`. Returns the count.
    uint gather(ref const Frustum view) pure nothrow @nogc {
        uint n = 0;
        foreach (ref d; ring) {
            if (!d.alive || !view.intersectsSphere(d.center, d.radius)) continue;
            visible[n++] = d.gpu;
        }
        visibleCount = n;
        return n;
    }
}

/// Column-major model matrix: X = tangent (rotated around `normal`),
/// Y = bitangent, Z = normal; scaled by (size.x, size.y, depth).
void buildMatrices(Vec3 pos, Vec3 normal, Vec2 size, float depth, float rotation,
                   out float[16] model, out float[16] inv) pure nothrow @nogc {
    immutable Z = normal.normalized();
    immutable ref_ = abs(Z.y) < 0.95f ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
    immutable X0 = ref_.cross(Z).normalized();
    immutable Y0 = Z.cross(X0);
    immutable c = cos(rotation), s = sin(rotation);
    immutable X = X0 * c + Y0 * s;
    immutable Y = Z.cross(X);
    immutable sx = size.x > 1e-4f ? size.x : 1e-4f;
    immutable sy = size.y > 1e-4f ? size.y : 1e-4f;
    immutable sz = depth > 1e-4f ? depth : 1e-4f;
    model = [X.x * sx, X.y * sx, X.z * sx, 0,
             Y.x * sy, Y.y * sy, Y.z * sy, 0,
             Z.x * sz, Z.y * sz, Z.z * sz, 0,
             pos.x, pos.y, pos.z, 1];
    // Inverse of an orthonormal basis with scale: rows = axis / scale.
    immutable Xi = X * (1.0f / sx), Yi = Y * (1.0f / sy), Zi = Z * (1.0f / sz);
    inv = [Xi.x, Yi.x, Zi.x, 0,
           Xi.y, Yi.y, Zi.y, 0,
           Xi.z, Yi.z, Zi.z, 0,
           -Xi.dot(pos), -Yi.dot(pos), -Zi.dot(pos), 1];
}

/// GPU side: pipeline, decal texture arrays, instance buffer.
struct DecalRenderer {
    private WGPUDevice device;
    private WGPUQueue queue;
    private TextureArray albedo, normal;
    private Sampler sampler;
    private WGPUShaderModule module_;
    private WGPUBindGroupLayout layout;
    private WGPUPipelineLayout pipeLayout;
    private WGPURenderPipeline pipeline;
    private WGPUBindGroup bindGroup;
    private WGPUTextureView boundDepth;
    private WGPUBuffer instanceBuf;
    private uint instanceCapacity;
    private uint drawCount;
    private Scene3DTextured* scene;
    private Renderer* renderer;
    private DecalSystem* system;

    @disable this(this);

    /// `albedoLayers` (RGBA, alpha = coverage) and `normalLayers` are
    /// `size²` RGBA8 each. `capacity` must be ≥ the system capacity.
    /// `srgbAlbedo` marks the albedo RGB as sRGB color (coverage alpha stays linear).
    static DecalRenderer create(ref GpuContext gpu, ref Scene3DTextured scene,
                                scope const(ubyte)[][] albedoLayers, scope const(ubyte)[][] normalLayers,
                                uint size, uint capacity, bool srgbAlbedo = false) @trusted {
        DecalRenderer r;
        r.device = gpu.getDevice();
        r.queue = gpu.getQueue();
        TextureDesc cd;
        cd.generateMips = true;
        TextureDesc nd = cd;
        nd.normalMap = true;
        cd.srgb = srgbAlbedo;
        r.albedo = TextureArray.fromLayers(gpu, albedoLayers, size, size, cd);
        r.normal = TextureArray.fromLayers(gpu, normalLayers, size, size, nd);
        r.sampler = Sampler.create(gpu, SamplerDesc(TextureFilter.linear, TextureWrap.clamp, 4));

        r.module_ = createShaderModule(r.device, decalPbrShaderSource);
        if (r.module_ is null) fatal("Decal shader compile failed");
        enum fs = WGPUShaderStage.fragment;
        WGPUBindGroupLayoutEntry[4] e;
        e[0].binding = 0; e[0].visibility = fs;
        e[0].texture.sampleType = WGPUTextureSampleType.depth;
        e[0].texture.viewDimension = WGPUTextureViewDimension.dim2D;
        e[1].binding = 1; e[1].visibility = fs; e[1].sampler.type = WGPUSamplerBindingType.filtering;
        foreach (k; 2 .. 4) {
            e[k].binding = k; e[k].visibility = fs;
            e[k].texture.sampleType = WGPUTextureSampleType.float_;
            e[k].texture.viewDimension = WGPUTextureViewDimension.dim2DArray;
        }
        WGPUBindGroupLayoutDescriptor ld;
        ld.entryCount = e.length;
        ld.entries = e.ptr;
        r.layout = wgpuDeviceCreateBindGroupLayout(r.device, &ld);
        WGPUBindGroupLayout[3] layouts = [scene.frameLayout(), r.layout, scene.iblLayout()];
        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 3;
        pld.bindGroupLayouts = layouts.ptr;
        r.pipeLayout = wgpuDeviceCreatePipelineLayout(r.device, &pld);

        WGPUVertexAttribute[11] attrs;
        foreach (i, ref a; attrs) {
            a.format = WGPUVertexFormat.float32x4;
            a.offset = i * 16;
            a.shaderLocation = cast(uint) i;
        }
        WGPUVertexBufferLayout vbl;
        vbl.arrayStride = DecalInstanceGpu.sizeof;
        vbl.stepMode = WGPUVertexStepMode.instance_;
        vbl.attributeCount = attrs.length;
        vbl.attributes = attrs.ptr;

        WGPUBlendState blend;
        blend.color.operation = WGPUBlendOperation.add;
        blend.color.srcFactor = WGPUBlendFactor.one;
        blend.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
        blend.alpha.operation = WGPUBlendOperation.add;
        blend.alpha.srcFactor = WGPUBlendFactor.zero;
        blend.alpha.dstFactor = WGPUBlendFactor.one;
        WGPUColorTargetState target;
        target.format = Renderer.sceneFormat();
        target.blend = &blend;
        target.writeMask = WGPUColorWriteMask.all;
        WGPUFragmentState fst;
        fst.module_ = r.module_;
        fst.entryPoint = wgpuStringView("fs_main");
        fst.targetCount = 1;
        fst.targets = &target;
        WGPUDepthStencilState depth;
        depth.format = WGPUTextureFormat.depth24Plus;
        depth.depthWriteEnabled = WGPUOptionalBool.false_;
        depth.depthCompare = WGPUCompareFunction.always;

        WGPURenderPipelineDescriptor pd;
        pd.layout = r.pipeLayout;
        pd.vertex.module_ = r.module_;
        pd.vertex.entryPoint = wgpuStringView("vs_main");
        pd.vertex.bufferCount = 1;
        pd.vertex.buffers = &vbl;
        pd.fragment = &fst;
        pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
        pd.primitive.frontFace = WGPUFrontFace.ccw;
        pd.primitive.cullMode = WGPUCullMode.front;
        pd.depthStencil = &depth;
        r.pipeline = wgpuDeviceCreateRenderPipeline(r.device, &pd);
        if (r.pipeline is null) fatal("Decal pipeline creation failed");

        r.instanceCapacity = capacity;
        WGPUBufferDescriptor bd;
        bd.size = cast(ulong) capacity * DecalInstanceGpu.sizeof;
        bd.usage = WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst;
        r.instanceBuf = wgpuDeviceCreateBuffer(r.device, &bd);
        info("Decal renderer: ", albedoLayers.length, " layers ", size, "², capacity ", capacity);
        return r;
    }

    /// Register the post-opaque hook. `this`, `scene`, `renderer` and
    /// `system` must not move afterwards.
    void attach(ref Scene3DTextured scene, ref Renderer renderer, ref DecalSystem system) @trusted {
        this.scene = &scene;
        this.renderer = &renderer;
        this.system = &system;
        scene.addPostOpaqueHook(&draw);
    }

    /// Instances drawn last frame.
    uint drawnCount() const nothrow @nogc { return drawCount; }

    /// Cull against the camera and upload the visible instances.
    void update(ref DecalSystem sys, ref const Camera camera) nothrow @nogc @trusted {
        auto z = profileZone!"decals.update"();
        immutable f = Frustum.fromViewProj(camera.viewProjection());
        uint n = sys.gather(f);
        if (n > instanceCapacity) n = instanceCapacity;
        if (n > 0) wgpuQueueWriteBuffer(queue, instanceBuf, 0, sys.visible.ptr, n * DecalInstanceGpu.sizeof);
        drawCount = n;
    }

    private void draw(ref FrameContext frame) nothrow @nogc @trusted {
        if (drawCount == 0 || renderer is null || scene is null || !frame.valid) return;
        auto z = profileZone!"decals.draw"();
        auto g = gpuFrameScope!"gpu.decals"(frame);
        renderer.snapshotOpaque(frame, SnapshotParts.depth); // the decals only read depth
        auto depthView = renderer.opaqueDepthView();
        if (depthView is null) return;
        if (depthView !is boundDepth) {
            if (bindGroup !is null) wgpuBindGroupRelease(bindGroup);
            WGPUBindGroupEntry[4] e;
            e[0].binding = 0; e[0].textureView = depthView;
            e[1].binding = 1; e[1].sampler = sampler.sampler;
            e[2].binding = 2; e[2].textureView = albedo.view;
            e[3].binding = 3; e[3].textureView = normal.view;
            WGPUBindGroupDescriptor d;
            d.layout = layout;
            d.entryCount = e.length;
            d.entries = e.ptr;
            bindGroup = wgpuDeviceCreateBindGroup(device, &d);
            boundDepth = depthView;
        }
        frame.setPipeline(pipeline);
        frame.setBindGroup(0, scene.frameGroup());
        frame.setBindGroup(1, bindGroup);
        frame.setBindGroup(2, scene.iblGroup());
        frame.setVertexBuffer(0, instanceBuf, cast(ulong) instanceCapacity * DecalInstanceGpu.sizeof);
        frame.draw(36, drawCount);
    }

    void detach() nothrow @nogc {
        scene = null;
        renderer = null;
        system = null;
    }

    void destroy() nothrow @nogc @trusted {
        detach();
        if (bindGroup !is null) { wgpuBindGroupRelease(bindGroup); bindGroup = null; }
        if (pipeline !is null) { wgpuRenderPipelineRelease(pipeline); pipeline = null; }
        if (pipeLayout !is null) { wgpuPipelineLayoutRelease(pipeLayout); pipeLayout = null; }
        if (layout !is null) { wgpuBindGroupLayoutRelease(layout); layout = null; }
        if (module_ !is null) { wgpuShaderModuleRelease(module_); module_ = null; }
        if (instanceBuf !is null) { wgpuBufferRelease(instanceBuf); instanceBuf = null; }
        albedo.destroy();
        normal.destroy();
        sampler.destroy();
    }
}

/// Procedural decal layers for demos and tests (`size²` RGBA8): 0 = tire
/// skid, 1 = impact crack, 2 = mud splat, 3 = painted arrow.
void proceduralDecalLayers(uint size, out ubyte[][4] albedo, out ubyte[][4] normal) {
    import engine.math.noise : valueNoise2D;
    static float valueNoise(float x, float y, uint seed) { return valueNoise2D(x, y, seed); }
    foreach (l; 0 .. 4) {
        albedo[l] = new ubyte[size * size * 4];
        normal[l] = new ubyte[size * size * 4];
        auto hgt = new float[size * size];
        foreach (y; 0 .. size)
            foreach (x; 0 .. size) {
                immutable u = (x + 0.5f) / size * 2 - 1, v = (y + 0.5f) / size * 2 - 1;
                immutable r = sqrt(u * u + v * v);
                immutable n = valueNoise(x * 0.11f, y * 0.11f, 17 + l) * 0.6f + valueNoise(x * 0.37f, y * 0.37f, 31 + l) * 0.4f;
                float a = 0, h = 0;
                float[3] c = [0.05f, 0.05f, 0.05f];
                final switch (l) {
                    case 0: // two tire tracks along V
                        immutable band = abs(abs(u) - 0.5f);
                        a = (1 - smoothstep(0.12f, 0.2f, band)) * (0.55f + 0.45f * n);
                        immutable tread = (cast(int)((v + 1) * 18) & 1) ? 0.85f : 1.0f;
                        a *= tread;
                        c = [0.03f, 0.03f, 0.03f];
                        h = a;
                        break;
                    case 1: // radial cracks + scorch
                        immutable ang = atan2Approx(v, u);
                        immutable crack = abs(sin(ang * 7 + n * 3));
                        a = (1 - smoothstep(0.2f, 0.95f, r)) * (0.5f + 0.5f * (crack < 0.15f ? 1 : 0)) + (1 - smoothstep(0, 0.25f, r)) * 0.5f;
                        c = [0.06f, 0.05f, 0.045f];
                        h = -(crack < 0.15f ? 1 : 0) * (1 - r);
                        break;
                    case 2: // mud splat
                        a = 1 - smoothstep(0.45f + 0.35f * n, 0.6f + 0.35f * n, r);
                        c = [0.16f, 0.11f, 0.06f];
                        h = a * n;
                        break;
                    case 3: // arrow pointing +V
                        immutable shaft = abs(u) < 0.12f && v > -0.7f && v < 0.3f;
                        immutable head = v >= 0.3f && v < 0.85f && abs(u) < (0.85f - v) * 0.9f;
                        a = (shaft || head) ? 0.92f * (0.8f + 0.2f * n) : 0;
                        c = [0.85f, 0.78f, 0.12f];
                        h = a * 0.2f;
                        break;
                }
                immutable i = (y * size + x) * 4;
                foreach (k; 0 .. 3) albedo[l][i + k] = toByte(c[k] * (0.8f + 0.4f * n));
                albedo[l][i + 3] = toByte(a < 0 ? 0 : (a > 1 ? 1 : a));
                hgt[y * size + x] = h;
            }
        foreach (y; 0 .. size)
            foreach (x; 0 .. size) {
                immutable hl = hgt[y * size + (x > 0 ? x - 1 : x)], hr = hgt[y * size + (x + 1 < size ? x + 1 : x)];
                immutable hd = hgt[(y > 0 ? y - 1 : y) * size + x], hu = hgt[(y + 1 < size ? y + 1 : y) * size + x];
                immutable nv = Vec3((hl - hr) * 4, (hd - hu) * 4, 1).normalized();
                immutable i = (y * size + x) * 4;
                normal[l][i] = toByte(nv.x * 0.5f + 0.5f);
                normal[l][i + 1] = toByte(nv.y * 0.5f + 0.5f);
                normal[l][i + 2] = toByte(nv.z * 0.5f + 0.5f);
                normal[l][i + 3] = 255;
            }
    }
}

private float smoothstep(float a, float b, float x) pure nothrow @nogc {
    float t = (x - a) / (b - a);
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return t * t * (3 - 2 * t);
}

private float atan2Approx(float y, float x) pure nothrow @nogc {
    import std.math : atan2;
    return atan2(y, x);
}

private ubyte toByte(float v) pure nothrow @nogc {
    v = v < 0 ? 0 : (v > 1 ? 1 : v);
    return cast(ubyte)(v * 255.0f + 0.5f);
}

unittest {
    auto s = DecalSystem.create(4);
    DecalStyle st;
    st.lifetime = 1.0f;
    st.fadeOut = 1.0f;
    foreach (i; 0 .. 4) s.spawn(Vec3(i, 0, 0), Vec3(0, 1, 0), Vec2(1, 1), 1, 0, 0, st);
    assert(s.liveCount == 4 && s.head == 0);
    // Wraparound overwrites the oldest (slot 0).
    immutable slot = s.spawn(Vec3(9, 0, 0), Vec3(0, 1, 0), Vec2(1, 1), 1, 0, 1);
    assert(slot == 0 && s.liveCount == 4 && s.ring[0].center.x == 9);
    // Fade then expire: slots 1..3 have lifetime 1 + fade 1; slot 0 is permanent.
    s.update(1.5f);
    assert(s.liveCount == 4 && abs(s.ring[1].gpu.params[1] - 0.5f) < 1e-4f);
    s.update(0.6f);
    assert(s.liveCount == 1 && s.ring[0].alive);
    s.kill(0);
    assert(s.liveCount == 0);
}

unittest {
    float[16] m, inv;
    buildMatrices(Vec3(1, 2, 3), Vec3(0, 1, 0), Vec2(2, 4), 0.5f, 0.3f, m, inv);
    // inv * m == identity on a test point.
    immutable float[3] p = [0.25f, -0.1f, 0.4f];
    float[3] w, back;
    foreach (r; 0 .. 3) w[r] = m[r] * p[0] + m[4 + r] * p[1] + m[8 + r] * p[2] + m[12 + r];
    foreach (r; 0 .. 3) back[r] = inv[r] * w[0] + inv[4 + r] * w[1] + inv[8 + r] * w[2] + inv[12 + r];
    foreach (k; 0 .. 3) assert(abs(back[k] - p[k]) < 1e-4f);
    // Local +Z maps to the surface normal.
    assert(abs(m[9] - 0.5f) < 1e-4f);

    auto s = DecalSystem.create(8);
    s.spawn(Vec3(0, 0, -10), Vec3(0, 1, 0), Vec2(1, 1), 1, 0, 0);
    s.spawn(Vec3(0, 0, 50), Vec3(0, 1, 0), Vec2(1, 1), 1, 0, 0);
    import engine.math.mat : Mat4;
    auto vp = Mat4.ortho(-5, 5, -5, 5, -20, 20);
    auto f = Frustum.fromViewProj(vp);
    assert(s.gather(f) == 1);
}
