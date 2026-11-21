/// Scene3DTextured — batched textured-mesh renderer with multi-light PBR +
/// shadows + IBL. Batches keyed by (TexMesh, Material). Frame uniforms and
/// shadow/IBL bind groups are owned by the scene (group 0 / group 2);
/// materials own group 1.
module engine.scene.scene3d_textured;

import std.math : cos, PI;

import bindings.wgpu;
import engine.core.log;
import engine.core.podbuf : PodBuffer;
import engine.core.pod : Pod;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.ibl : IblEnvironment;
import engine.gpu.pipeline : BlendMode, Pipeline3D, RenderState, SurfacePipelines, TexInstanceData,
    createSurfacePipelines, createTexturedDrawPipeline, createTexturedPipeline3D, FRAME_UNIFORMS_SIZE;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shadow :
    beginShadowPassView, createTexShadowPipeline, endShadowPass,
    pointLightFaceVPs, PointShadowMap, ShadowMap, SpotShadowMap,
    spotLightVPFromCone, TexShadowPipeline;
import engine.graphics.types : Color4;
import engine.graphics.texmesh : ShadowLodDraw, TexMesh;
import engine.graphics.material : Material;
import engine.graphics.lod : LOD_NONE, projectedPixels, selectLod;
import engine.math.bounds : BoundingSphere, maxAxisScale;
import engine.math.frustum : Frustum;
import engine.scene.static_instances : collectVisibleRuns, StaticInstanceBuffer, StaticRun, StaticViewParams;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.atmosphere : FogSettings, packFog;
import engine.scene.cascades : buildCascades, CascadeSet, MAX_CASCADES;
import engine.scene.light :
    DIR_SHADOW_RESOLUTION, LIGHT_SHADOW_NEAR, LightSet,
    MAX_POINT_LIGHTS, MAX_POINT_SHADOW_CASTERS,
    MAX_SPOT_LIGHTS, MAX_SPOT_SHADOW_CASTERS,
    POINT_SHADOW_RESOLUTION, SPOT_SHADOW_RESOLUTION;

@safe:

/// GPU mirror of WGSL `DirLight` (96 bytes).
struct GpuDirLightUbo {
    float[3] direction = [0.3f, 1.0f, 0.5f];
    float intensity = 3.5f;
    float[3] color = [1.0f, 0.98f, 0.92f];
    uint castShadows = 0;
    float[16] viewProj;
}
static assert(GpuDirLightUbo.sizeof == 96);

/// GPU mirror of WGSL `PointLight` (48 bytes).
struct GpuPointLightUbo {
    float[3] position = [0, 0, 0];
    float range = 10.0f;
    float[3] color = [1, 1, 1];
    float intensity = 1.0f;
    int shadowSlot = -1;
    float attenuation = 0.0f;
    float _pad1 = 0, _pad2 = 0;
}
static assert(GpuPointLightUbo.sizeof == 48);

/// GPU mirror of WGSL `SpotLight` (128 bytes).
struct GpuSpotLightUbo {
    float[3] position = [0, 0, 0];
    float range = 10.0f;
    float[3] direction = [0, -1, 0];
    float intensity = 1.0f;
    float[3] color = [1, 1, 1];
    float innerConeCos = 0.96f;
    float outerConeCos = 0.9f;
    int shadowSlot = -1;
    float attenuation = 0.0f;
    float angleAttenuation = 0.0f;
    float[16] viewProj;
}
static assert(GpuSpotLightUbo.sizeof == 128);

/**
 * Extra geometry drawn into shadow views (terrain, custom renderers). Called
 * inside each directional shadow pass (fixed map or every cascade) after the
 * batches. `vpBindGroup` + `dynamicOffset` bind the view's light VP with the
 * `shadowVpLayout()` layout at `@group(0)`; `view` is the light frustum for culling.
 */
alias ShadowCasterHook = void delegate(WGPURenderPassEncoder pass, WGPUBindGroup vpBindGroup,
                                       uint dynamicOffset, ref const Frustum view) nothrow @nogc;

/// `drawMatrix` LOD argument: pick the level from the camera distance and the
/// mesh's simplifier errors (LOD0 for meshes without a chain).
enum ubyte LOD_AUTO = 0xFF;

/// Maximum `StaticInstanceBuffer`s submitted per frame.
enum MAX_STATIC_SUBMISSIONS = 8;

/// Per-frame counters from `Scene3DTextured` (reset in `begin`).
struct RenderStats {
    /// (mesh, material, lod) batches with at least one instance.
    uint batches;
    /// Color-pass draw calls (dynamic batches + static ranges).
    uint drawCalls;
    /// Shadow-pass draw calls over every light view.
    uint shadowDrawCalls;
    /// Dynamic caster instances drawn over every shadow view (after culling).
    uint shadowInstancesDrawn;
    /// Dynamic instances submitted through `draw` / `drawMatrix`.
    uint instancesSubmitted;
    /// Dynamic instances that survived frustum / distance culling.
    uint instancesVisible;
    /// Static instances drawn in the color pass (`StaticInstanceBuffer`).
    uint staticInstancesVisible;
    /// Static ranges submitted after merging.
    uint staticRangesDrawn;
    /// Color-pass instances per LOD level (index 3 counts LOD3 and coarser).
    uint[4] lodHistogram;
}

/// Stable counting sort of `items` by `classes[i] ∈ 0..3` through `scratch`.
/// Returns the size of each class; classes end up contiguous in order 0..3.
uint[4] partitionByClass(TexInstanceData[] items, scope const(ubyte)[] classes,
                         TexInstanceData[] scratch) pure nothrow @nogc {
    assert(classes.length >= items.length && scratch.length >= items.length);
    uint[4] counts;
    foreach (c; classes[0 .. items.length]) counts[c & 3]++;
    uint[4] cursor = [0, counts[0], counts[0] + counts[1], counts[0] + counts[1] + counts[2]];
    foreach (i, ref it; items) scratch[cursor[classes[i] & 3]++] = it;
    items[] = scratch[0 .. items.length];
    return counts;
}

/// Instance range of one batch in one local (point face / spot) shadow view.
struct CasterRange {
    uint first;
    uint count;
    /// No culling possible (culling off or mesh without bounds): draw the
    /// batch's own instance buffer `[0, length)` instead of the caster buffer.
    bool all;
}

/**
 * Cull `items` for the shadow views of one local light. Instances whose
 * world sphere is outside the light's range sphere (`range <= 0` skips this
 * test) are rejected once; survivors are tested against each view frustum
 * and appended to `staging`, contiguously per view. `outRanges[k]` receives
 * the `staging` range of view `k`. Scratch buffers are reused across calls.
 */
void gatherLightCasters(scope const(TexInstanceData)[] items, BoundingSphere localSphere,
                        Vec3 lightPos, float range, scope const(Frustum)[] views,
                        ref PodBuffer!TexInstanceData staging, scope CasterRange[] outRanges,
                        ref PodBuffer!uint candScratch, ref PodBuffer!BoundingSphere sphereScratch) nothrow @nogc {
    assert(outRanges.length >= views.length);
    candScratch.clear();
    sphereScratch.clear();
    foreach (i, ref inst; items) {
        Mat4 model;
        model.m = inst.model;
        immutable ws = localSphere.transformed(model);
        if (range > 0 && (ws.center - lightPos).length() > range + ws.radius) continue;
        candScratch.put(cast(uint) i);
        sphereScratch.put(ws);
    }
    foreach (k, ref f; views) {
        immutable first = cast(uint) staging.length;
        foreach (c, idx; candScratch[])
            if (f.intersectsSphere(sphereScratch[c])) staging.put(items[idx]);
        outRanges[k] = CasterRange(first, cast(uint) staging.length - first, false);
    }
}

/// CPU mirror of WGSL FrameUniforms (`FRAME_UNIFORMS_SIZE` bytes).
struct FrameUniforms {
    float[16] viewProj;
    float[3] cameraPos = [0, 5, 10];
    float shadowBias = 0.0004f;
    GpuDirLightUbo dirLight;
    uint pointCount = 0;
    uint spotCount = 0;
    uint dirEnabled = 1;
    float time = 0.0f;
    float iblIntensity = 1.0f;
    /// 0 = dry, 1 = soaked: global OpenPBR wetness on rain-exposed surfaces.
    float globalWetness = 0.0f;
    /// 0..1 rain strength (ripples / streak intensity).
    float rainIntensity = 0.0f;
    /// 0..1 sky cloud coverage.
    float cloudCoverage = 0.0f;
    GpuSpotLightUbo[MAX_SPOT_LIGHTS] spots;

    // --- Cascaded shadow maps ---
    float[16][MAX_CASCADES] cascadeViewProj;
    /// View depth where each cascade ends.
    float[4] cascadeSplits = [0, 0, 0, 0];
    /// x = cascade count (0 = fixed legacy map), y = blend fraction,
    /// z = fade start, w = fade end (view depth).
    float[4] cascadeParams = [0, 0.1f, 0, 0];
    /// Per cascade: x = texel world size, y = 1 / light depth range.
    float[4][MAX_CASCADES] cascadeTexel;

    // --- Camera ---
    float[16] invViewProj;
    float[3] cameraForward = [0, 0, -1];
    float cameraNear = 0.1f;
    float[2] viewportSize = [1920, 1080];
    float cameraFar = 100.0f;
    /// Bit 0: tint cascades for debugging.
    uint debugFlags = 0;

    // --- Atmosphere ---
    /// rgb = fog color (linear HDR), w = density (1/m; 0 disables fog).
    float[4] fogColorDensity = [0.6f, 0.7f, 0.8f, 0.0f];
    /// x = height base, y = height falloff (1/m), z = start distance, w = max opacity.
    float[4] fogHeight = [0, 0.05f, 0, 1];
    /// rgb = sun in-scattering color, w = sun lobe power.
    float[4] fogSun = [1.0f, 0.9f, 0.7f, 8.0f];
    /// xyz = moon direction (surface → moon), w = moon intensity.
    float[4] moonDir = [0, -1, 0, 0];
    /// x = star intensity, y = sky exposure, z/w free.
    float[4] skyParams = [0, 1, 0, 0];
}
static assert(FrameUniforms.sizeof == FRAME_UNIFORMS_SIZE);

/// Batched renderer for textured instanced 3D meshes (PBR path).
struct Scene3DTextured {
    private Pipeline3D pipeline;
    private WGPUBuffer frameUniformBuf;
    private WGPUBuffer pointLightsBuf;
    private WGPUBindGroup frameBindGroup;
    private WGPUBindGroup iblBindGroup;
    private IblEnvironment ownedIbl;
    private bool ownsIbl = true;
    private WGPUDevice device;
    private WGPUQueue queue;

    // Default 1×1 depth resources so the pipeline is valid before setLights.
    private WGPUTexture defaultShadow2dTex;
    private WGPUTextureView defaultShadow2dView;
    private WGPUTexture defaultShadowCubeTex;
    private WGPUTextureView defaultShadowCubeView;
    private WGPUSampler defaultShadowSampler;

    private FrameUniforms frameData;
    private GpuPointLightUbo[MAX_POINT_LIGHTS] pointLightsData;

    private enum DEFAULT_MAX_BATCHES = 256;
    /// Initial instance capacity; a batch's buffer doubles when exceeded.
    private enum INITIAL_INSTANCES_PER_BATCH = 512;

    /// One (mesh, material, lod) draw list. `instances` is malloc-backed and
    /// keeps its capacity across frames, so steady-state submission never
    /// allocates.
    private struct Batch {
        TexMesh*   mesh;
        Material*  material;
        ubyte      lod;
        PodBuffer!TexInstanceData instances;
        WGPUBuffer instanceBuf;
        size_t     capacity;
        bool       uploaded = false;
        /// Culling partition (see `prepareBatch`): color pass draws
        /// `[colorFirst, colorFirst + colorCount)`, the directional shadow
        /// pass `[dirFirst, dirFirst + dirCount)`; point / spot shadows draw all.
        bool       prepared = false;
        uint       colorFirst, colorCount, dirFirst, dirCount;
    }
    private BatchMap batchMap;

    // Culling state, captured in `begin`.
    private Frustum cameraFrustum;
    private bool cullingEnabled = true;
    private float cullMaxDistance = 0;
    private float cullMinPixels = 0;
    private RenderStats frameStats;
    private PodBuffer!TexInstanceData partitionScratch;
    private PodBuffer!ubyte partitionClasses;

    // Per-view dynamic caster lists for point-face / spot shadow views,
    // indexed `[vpSlot * batchCount + batch]`; valid when `localCulled[vpSlot]`.
    private PodBuffer!TexInstanceData casterStaging;
    private PodBuffer!CasterRange casterRanges;
    private PodBuffer!uint casterCandidates;
    private PodBuffer!BoundingSphere casterSpheres;
    private bool[MAX_SHADOW_PASS_SLOTS] localCulled;
    private WGPUBuffer casterBuf;
    private size_t casterCapacity;

    // Retained static instance buffers submitted this frame.
    private StaticInstanceBuffer*[MAX_STATIC_SUBMISSIONS] staticBufs;
    private uint staticCount;
    private PodBuffer!StaticRun staticRuns;

    private enum uint SHADOW_VP_STRIDE = 256;
    /// Shadow VP slots reserved for the directional light (one per cascade).
    private enum uint DIR_SLOTS = MAX_CASCADES;
    private enum uint MAX_SHADOW_PASS_SLOTS = DIR_SLOTS + MAX_POINT_SHADOW_CASTERS * 6 + MAX_SPOT_SHADOW_CASTERS;
    private bool shadowPipeReady = false;
    private TexShadowPipeline shadowPipe;
    private WGPUBuffer shadowVpBuf;
    private WGPUBindGroup shadowVpBg;
    private ubyte[MAX_SHADOW_PASS_SLOTS * SHADOW_VP_STRIDE] shadowVpStaging;
    private ShadowMap ownedDirShadow;
    private bool hasOwnedDirShadow = false;
    private PointShadowMap[MAX_POINT_SHADOW_CASTERS] ownedPointShadows;
    private bool[MAX_POINT_SHADOW_CASTERS] hasOwnedPointShadow;
    private SpotShadowMap[MAX_SPOT_SHADOW_CASTERS] ownedSpotShadows;
    private bool[MAX_SPOT_SHADOW_CASTERS] hasOwnedSpotShadow;

    /// Pipelines for a (surface shader, render state) pair other than the default state.
    private struct PipelineVariant {
        uint shaderId;
        RenderState state;
        WGPURenderPipeline pipeline;
        WGPURenderPipeline pipelineTangent;
    }
    private enum MAX_VARIANTS = 64;
    private PipelineVariant[MAX_VARIANTS] variants;
    private uint variantCount = 0;
    private bool warnedBatchOverflow = false;

    private enum MAX_SURFACE_SHADERS = 16;
    private SurfacePipelines[MAX_SURFACE_SHADERS] surfaceShaders;
    private uint surfaceShaderCount = 0;

    private Batch[] batches;
    private uint[] sortOrder;
    private float[] sortFarthest;
    private uint batchCount = 0;

    // Automatic LOD inputs, captured in `begin`.
    private Vec3 lodCameraPos;
    private float lodFovY = 0.9f;
    private float lodScreenHeight = 1080.0f;
    private float lodBias = 1.0f;

    // Last views bound into `frameBindGroup`; rebuild only when one changes.
    private WGPUSampler boundShadowSampler;
    private WGPUTextureView[7] boundShadowViews;
    private WGPUTextureView defaultShadowArrayView;

    // Camera captured in `begin` (cascade fitting).
    private Camera frameCamera;
    // Cascades fitted by the automatic `renderShadows(frame, lights)` path;
    // consumed by `setLightsImpl` when `cascadesPending` is set.
    private CascadeSet cascadeSet;
    private bool cascadesPending = false;
    private bool debugCascades = false;

    // Extra shadow casters (terrain, …) drawn into every directional view.
    private enum MAX_SHADOW_HOOKS = 4;
    private ShadowCasterHook[MAX_SHADOW_HOOKS] shadowHooks;
    private uint shadowHookCount = 0;

    @disable this(this);

    static Scene3DTextured create(ref GpuContext gpu, uint maxBatches = DEFAULT_MAX_BATCHES) @trusted {
        if (maxBatches == 0) maxBatches = DEFAULT_MAX_BATCHES;
        Scene3DTextured s;
        s.device = gpu.getDevice();
        s.queue = gpu.getQueue();
        auto device = s.device;

        s.pipeline = createTexturedPipeline3D(device, Renderer.sceneFormat());
        s.frameUniformBuf = createUniformBuffer(device, FRAME_UNIFORMS_SIZE);
        s.pointLightsBuf = createStorageBuffer(device, MAX_POINT_LIGHTS * GpuPointLightUbo.sizeof);
        updateBuffer(s.queue, s.pointLightsBuf, s.pointLightsData[]);

        s.frameData = FrameUniforms.init;
        s.frameData.viewProj = Mat4.identity().m;
        s.frameData.dirEnabled = 1;
        s.frameData.dirLight.intensity = 3.5f;
        s.frameData.dirLight.color = [1.0f, 0.98f, 0.92f];
        s.frameData.dirLight.direction = [0.3f, 1.0f, 0.5f];
        s.frameData.dirLight.viewProj = Mat4.identity().m;
        s.frameData.shadowBias = 0.0004f;
        s.frameData.iblIntensity = 1.0f;

        s.frameData.invViewProj = Mat4.identity().m;
        foreach (ref m; s.frameData.cascadeViewProj) m = Mat4.identity().m;

        s.createDefaultShadows(device);
        s.rebuildFrameBindGroup(
            s.defaultShadowSampler,
            s.defaultShadowArrayView,
            s.defaultShadowCubeView, s.defaultShadowCubeView,
            s.defaultShadowCubeView, s.defaultShadowCubeView,
            s.defaultShadow2dView, s.defaultShadow2dView);

        s.ownedIbl = IblEnvironment.create(gpu, s.pipeline.iblBindGroupLayout);
        s.iblBindGroup = s.ownedIbl.bindGroup;
        s.ownsIbl = true;

        s.batches = new Batch[maxBatches];
        s.batchMap.reserve(maxBatches);
        s.sortOrder = new uint[maxBatches];
        s.sortFarthest = new float[maxBatches];
        foreach (ref b; s.batches) {
            b.instanceBuf = createDynamicVertexBuffer(
                device, INITIAL_INSTANCES_PER_BATCH * TexInstanceData.sizeof);
            b.capacity = INITIAL_INSTANCES_PER_BATCH;
        }
        return s;
    }

    /// Material bind group layout (@group(1)).
    auto materialLayout() nothrow @nogc { return pipeline.bindGroupLayout; }

    /// Alias kept for older call sites.
    auto bindGroupLayout() nothrow @nogc { return materialLayout(); }

    /// IBL layout (@group(2)) — for custom environment construction.
    auto iblLayout() nothrow @nogc { return pipeline.iblBindGroupLayout; }

    /// Frame bind group layout (@group(0)) — shared with custom scene-space passes.
    auto frameLayout() nothrow @nogc { return pipeline.frameBindGroupLayout; }

    /// Active frame bind group (@group(0)) populated by `begin(...)`.
    auto frameGroup() nothrow @nogc { return frameBindGroup; }

    /// Active IBL bind group (@group(2)) populated by `begin(...)` / `setIbl(...)`.
    auto iblGroup() nothrow @nogc { return iblBindGroup; }

    /// Safely hot-reload the textured 3D PBR pipeline without reallocating bind groups.
    bool reloadShader(scope const(char)[] newWgsl) nothrow @nogc {
        import engine.gpu.pipeline : reloadTexturedPipeline3D;
        if (!reloadTexturedPipeline3D(pipeline, device, Renderer.sceneFormat(), newWgsl, false)) return false;
        releaseVariants(0);
        return true;
    }

    /// Hot-reload the stride-48 variant (`MESH_TANGENT` already applied to `newWgsl`).
    bool reloadTangentShader(scope const(char)[] newWgsl) nothrow @nogc {
        import engine.gpu.pipeline : reloadTexturedPipeline3D;
        if (!reloadTexturedPipeline3D(pipeline, device, Renderer.sceneFormat(), newWgsl, true)) return false;
        releaseVariants(0);
        return true;
    }

    /// Compile a custom surface shader. `surfaceWgsl` defines
    /// `fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut` and
    /// optionally `fn displace(localPos, localNormal) -> vec3<f32>`; it can
    /// read `frame.time`, `surfaceParams.p0 .. p3` and the material bindings.
    /// Assign the returned id to `Material.surfaceShader`. Returns 0 (the
    /// stock shader) when compilation fails or the table is full.
    /// Shadow passes do not run `displace`.
    uint createSurfaceShader(scope const(char)[] surfaceWgsl) @trusted {
        import engine.gpu.shaders : composeSurfaceShader;
        if (surfaceShaderCount >= MAX_SURFACE_SHADERS) {
            warn("Surface shader table full (MAX_SURFACE_SHADERS=", MAX_SURFACE_SHADERS, ")");
            return 0;
        }
        auto built = createSurfacePipelines(pipeline, device, Renderer.sceneFormat(),
            composeSurfaceShader(surfaceWgsl, false), composeSurfaceShader(surfaceWgsl, true));
        if (!built.valid) {
            err("Custom surface shader failed to compile; using the stock PBR shader");
            return 0;
        }
        surfaceShaders[surfaceShaderCount] = built;
        return ++surfaceShaderCount;
    }

    /// Recompile an existing surface shader in place (hot reload). The old
    /// pipelines stay active when the new source fails.
    bool reloadSurfaceShader(uint id, scope const(char)[] surfaceWgsl) @trusted {
        import engine.gpu.shaders : composeSurfaceShader;
        if (id == 0 || id > surfaceShaderCount) return false;
        auto built = createSurfacePipelines(pipeline, device, Renderer.sceneFormat(),
            composeSurfaceShader(surfaceWgsl, false), composeSurfaceShader(surfaceWgsl, true));
        if (!built.valid) return false;
        surfaceShaders[id - 1].release();
        surfaceShaders[id - 1] = built;
        releaseVariants(id);
        return true;
    }

    /// Seconds exposed to shaders as `frame.time`; call before `begin`.
    void setTime(float seconds) nothrow @nogc { frameData.time = seconds; }

    /// Global multiplier for IBL diffuse/specular/coat/fuzz ambient lighting.
    void setIblIntensity(float intensity) nothrow @nogc {
        frameData.iblIntensity = intensity < 0.0f ? 0.0f : intensity;
    }

    /// Atmospheric height fog applied in linear HDR by the PBR, water,
    /// terrain and decal shaders. Call before `begin` (uploaded there).
    void setFog(ref const FogSettings fog) nothrow @nogc {
        packFog(fog, frameData.fogColorDensity, frameData.fogHeight, frameData.fogSun);
    }

    /// Update multi-light UBO + bind shadow maps for the next draws.
    ///
    /// `dirShadow` may be null (uses a fully-lit placeholder).
    /// Point/spot lights with `castShadows` consume maps from `pointShadows` /
    /// `spotShadows` in order; overflow warns and leaves those lights unshadowed.
    /// A caller-owned `dirShadow` is sampled as one fixed map with
    /// `lights.dir.viewProj` (cascades apply only to engine-owned maps, see
    /// `renderShadows(frame, lights)`).
    void setLights(ref const LightSet lights,
                   scope ShadowMap* dirShadow,
                   scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                   scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows) @trusted {
        cascadesPending = false;
        setLightsImpl(lights, dirShadow, pointShadows, spotShadows);
    }

    private void setLightsImpl(ref const LightSet lights,
                   scope ShadowMap* dirShadow,
                   scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                   scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows) @trusted {
        frameData.shadowBias = lights.shadowBias;
        frameData.dirEnabled = lights.dirEnabled ? 1 : 0;
        debugCascades = lights.dir.debugCascades;
        if (debugCascades) frameData.debugFlags |= 1u;
        else frameData.debugFlags &= ~1u;

        if (lights.dirEnabled) {
            immutable d = lights.dir.direction.normalized();
            frameData.dirLight.direction = [d.x, d.y, d.z];
            frameData.dirLight.color = [
                lights.dir.color.x, lights.dir.color.y, lights.dir.color.z
            ];
            frameData.dirLight.intensity = lights.dir.intensity;
            frameData.dirLight.viewProj = lights.dir.viewProj.m;
            immutable wantDirShadow = lights.dir.castShadows && dirShadow !is null;
            frameData.dirLight.castShadows = wantDirShadow ? 1 : 0;
            if (lights.dir.castShadows && dirShadow is null)
                warn("Directional castShadows requested but no ShadowMap provided");
        }
        applyCascadeUniforms(cascadesPending && dirShadow !is null);

        immutable pc = lights.pointCount > MAX_POINT_LIGHTS
            ? MAX_POINT_LIGHTS : lights.pointCount;
        if (lights.pointCount > MAX_POINT_LIGHTS)
            warn("Point light buffer overflow: ", lights.pointCount, " > ", MAX_POINT_LIGHTS);
        frameData.pointCount = pc;
        pointLightsData = GpuPointLightUbo.init;

        WGPUTextureView[MAX_POINT_SHADOW_CASTERS] boundPoints = [
            defaultShadowCubeView, defaultShadowCubeView,
            defaultShadowCubeView, defaultShadowCubeView,
        ];
        uint pointShadowUsed = 0;
        foreach (i; 0 .. pc) {
            immutable pl = lights.points[i];
            pointLightsData[i].position = [pl.position.x, pl.position.y, pl.position.z];
            pointLightsData[i].range = pl.range;
            pointLightsData[i].color = [pl.color.x, pl.color.y, pl.color.z];
            pointLightsData[i].intensity = pl.intensity;
            pointLightsData[i].attenuation = pl.attenuation;
            pointLightsData[i].shadowSlot = -1;
            if (!pl.castShadows) continue;
            if (pointShadowUsed >= MAX_POINT_SHADOW_CASTERS
                || pointShadows[pointShadowUsed] is null) {
                warn("Point shadow caster budget exceeded (MAX_POINT_SHADOW_CASTERS=",
                     MAX_POINT_SHADOW_CASTERS, "); light ", i, " stays unshadowed");
                continue;
            }
            pointLightsData[i].shadowSlot = cast(int) pointShadowUsed;
            boundPoints[pointShadowUsed] = pointShadows[pointShadowUsed].cubeView;
            pointShadowUsed++;
        }
        updateBuffer(queue, pointLightsBuf, pointLightsData[]);

        immutable sc = lights.spotCount > MAX_SPOT_LIGHTS
            ? MAX_SPOT_LIGHTS : lights.spotCount;
        if (lights.spotCount > MAX_SPOT_LIGHTS)
            warn("Spot light UBO overflow: ", lights.spotCount, " > ", MAX_SPOT_LIGHTS);
        frameData.spotCount = sc;
        frameData.spots = GpuSpotLightUbo.init;

        WGPUTextureView[MAX_SPOT_SHADOW_CASTERS] boundSpots = [
            defaultShadow2dView, defaultShadow2dView,
        ];
        uint spotShadowUsed = 0;
        foreach (i; 0 .. sc) {
            immutable sl = lights.spots[i];
            immutable dir = sl.direction.normalized();
            immutable innerRad = sl.innerConeDeg * (PI / 180.0f);
            immutable outerRad = sl.outerConeDeg * (PI / 180.0f);
            frameData.spots[i].position = [sl.position.x, sl.position.y, sl.position.z];
            frameData.spots[i].range = sl.range;
            frameData.spots[i].direction = [dir.x, dir.y, dir.z];
            frameData.spots[i].intensity = sl.intensity;
            frameData.spots[i].attenuation = sl.attenuation;
            frameData.spots[i].angleAttenuation = sl.angleAttenuation;
            frameData.spots[i].color = [sl.color.x, sl.color.y, sl.color.z];
            frameData.spots[i].innerConeCos = cos(innerRad);
            frameData.spots[i].outerConeCos = cos(outerRad);
            frameData.spots[i].viewProj = sl.viewProj.m;
            frameData.spots[i].shadowSlot = -1;
            if (!sl.castShadows) continue;
            if (spotShadowUsed >= MAX_SPOT_SHADOW_CASTERS
                || spotShadows[spotShadowUsed] is null) {
                warn("Spot shadow caster budget exceeded (MAX_SPOT_SHADOW_CASTERS=",
                     MAX_SPOT_SHADOW_CASTERS, "); light ", i, " stays unshadowed");
                continue;
            }
            frameData.spots[i].shadowSlot = cast(int) spotShadowUsed;
            boundSpots[spotShadowUsed] = spotShadows[spotShadowUsed].depthView;
            spotShadowUsed++;
        }

        auto dirView = (dirShadow !is null) ? dirShadow.arrayView : defaultShadowArrayView;
        auto sampler = defaultShadowSampler;
        if (dirShadow !is null)
            sampler = dirShadow.comparisonSampler;
        else if (pointShadowUsed > 0)
            sampler = pointShadows[0].comparisonSampler;
        else if (spotShadowUsed > 0)
            sampler = spotShadows[0].comparisonSampler;

        rebuildFrameBindGroup(
            sampler, dirView,
            boundPoints[0], boundPoints[1], boundPoints[2], boundPoints[3],
            boundSpots[0], boundSpots[1]);
    }

    /// Copy `cascadeSet` into the frame uniforms, or switch to the fixed map.
    private void applyCascadeUniforms(bool useCascades) nothrow @nogc {
        if (!useCascades || cascadeSet.count == 0) {
            frameData.cascadeParams[0] = 0;
            return;
        }
        immutable n = cascadeSet.count;
        foreach (i; 0 .. MAX_CASCADES) {
            immutable k = i < n ? i : n - 1;
            frameData.cascadeViewProj[i] = cascadeSet.viewProj[k].m;
            frameData.cascadeSplits[i] = cascadeSet.splitFar[k];
            frameData.cascadeTexel[i] = [cascadeSet.texelWorld[k],
                cascadeSet.depthRange[k] > 0 ? 1.0f / cascadeSet.depthRange[k] : 0.0f, 0, 0];
        }
        frameData.cascadeParams = [cast(float) n, cascadeBlend, cascadeSet.fadeStart, cascadeSet.fadeEnd];
        // Legacy consumers of `dirLight.viewProj` see the first cascade.
        frameData.dirLight.viewProj = cascadeSet.viewProj[0].m;
    }

    private float cascadeBlend = 0.1f;

    /// Cascades fitted for the current frame (valid after `renderShadows`).
    ref const(CascadeSet) cascades() const return nothrow @nogc { return cascadeSet; }

    /// Register geometry drawn into every directional shadow view (terrain
    /// renderers). Hooks persist across frames; `clearShadowCasterHooks` removes them.
    void addShadowCasterHook(ShadowCasterHook hook) nothrow @nogc {
        if (shadowHookCount >= MAX_SHADOW_HOOKS) {
            warn("Scene3DTextured: shadow caster hook table full");
            return;
        }
        shadowHooks[shadowHookCount++] = hook;
    }

    /// Remove every registered shadow caster hook.
    void clearShadowCasterHooks() nothrow @nogc { shadowHookCount = 0; }

    /// Bind group layout of the per-view light VP (`@group(0)`, one mat4
    /// with a dynamic offset) used by shadow caster hooks. Creates the
    /// shadow resources on first use.
    WGPUBindGroupLayout shadowVpLayout() @trusted {
        ensureShadowResources();
        return shadowPipe.bindGroupLayout;
    }

    /// Backward-compatible single directional light + shadow map.
    void setLighting(Vec3 lightDir, Mat4 lightVP, ref ShadowMap shadow,
                     float bias = 0.0004f) @trusted {
        LightSet ls;
        ls.dirEnabled = true;
        ls.dir.direction = lightDir;
        ls.dir.viewProj = lightVP;
        ls.dir.color = Vec3(1.0f, 0.98f, 0.92f);
        ls.dir.intensity = 3.5f;
        ls.dir.castShadows = true;
        ls.shadowBias = bias;
        ls.pointCount = 0;
        ls.spotCount = 0;
        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pts;
        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spts;
        setLights(ls, &shadow, pts, spts);
    }

    /// Bind a custom IBL environment (replaces the default procedural one for draws).
    /// The scene does not take ownership — caller must keep `ibl` alive.
    void setEnvironment(ref IblEnvironment ibl) nothrow @nogc {
        iblBindGroup = ibl.bindGroup;
    }

    /// Viewport height in pixels used by automatic LOD selection (default 1080).
    void setLodScreenHeight(float pixels) nothrow @nogc {
        lodScreenHeight = pixels > 1 ? pixels : 1;
    }

    /// Multiplier on projected LOD error: > 1 keeps finer levels longer, < 1 drops sooner.
    void setLodBias(float bias) nothrow @nogc {
        lodBias = bias > 0 ? bias : 1;
    }

    /// Enable / disable per-instance frustum culling (default on).
    void setCulling(bool enabled) nothrow @nogc { cullingEnabled = enabled; }

    /// Drop instances farther than `maxDistance` (0 = unlimited) or whose
    /// bounding sphere projects to fewer than `minPixelSize` pixels (0 = off).
    void setDistanceCull(float maxDistance, float minPixelSize = 0) nothrow @nogc {
        cullMaxDistance = maxDistance > 0 ? maxDistance : 0;
        cullMinPixels = minPixelSize > 0 ? minPixelSize : 0;
    }

    /// Counters of the frame recorded since the last `begin`.
    RenderStats stats() const nothrow @nogc { return frameStats; }

    /// Camera frustum of the current frame (valid after `begin`).
    ref const(Frustum) frustum() const return nothrow @nogc { return cameraFrustum; }

    void begin(ref const Camera camera) @trusted {
        lodCameraPos = camera.position;
        lodFovY = camera.fovY;
        frameCamera = camera;
        immutable vp = camera.viewProjection();
        cameraFrustum = Frustum.fromViewProj(vp);
        frameStats = RenderStats.init;
        frameData.viewProj = vp.m;
        frameData.invViewProj = vp.inverse().m;
        frameData.cameraPos = [camera.position.x, camera.position.y, camera.position.z];
        immutable fwd = (camera.target - camera.position).normalized();
        frameData.cameraForward = [fwd.x, fwd.y, fwd.z];
        frameData.cameraNear = camera.near;
        frameData.cameraFar = camera.far;
        frameData.viewportSize = [lodScreenHeight * camera.aspect, lodScreenHeight];
        updateBuffer(queue, frameUniformBuf, (&frameData)[0 .. 1]);

        batchCount = 0;
        batchMap.reset();
        staticCount = 0;
    }

    /**
     * Queue a retained `StaticInstanceBuffer` for this frame (between
     * `begin` and `end`). Its ranges are culled and LOD-selected per cell in
     * `renderShadows` / `end`; nothing is re-uploaded. Static buffers are
     * drawn with the opaque pass and must use depth-writing materials.
     * The buffer must stay alive until `end`. At most
     * `MAX_STATIC_SUBMISSIONS` per frame; extra submissions are ignored.
     */
    void submitStatic(ref StaticInstanceBuffer sib) nothrow @nogc @trusted {
        if (sib.instanceBuf is null || sib.ranges.length == 0) return;
        if (staticCount >= MAX_STATIC_SUBMISSIONS) {
            warn("Scene3DTextured: too many static submissions this frame");
            return;
        }
        staticBufs[staticCount++] = &sib;
    }

    /// Render depth shadow passes automatically for all queued `depthWrite`
    /// batches across any shadow-casting directional, point, or spot lights
    /// in `lights`. Lazily allocates and reuses internal shadow maps as needed.
    /// Spot lights with an identity `viewProj` automatically derive one from
    /// `position`, `direction`, `outerConeDeg`, and `range`.
    /// Must be called after `begin` / `draw*` and before `end`.
    void renderShadows(ref FrameContext frame, ref const LightSet lights) @trusted {
        LightSet resolved = resolveLightsForShadows(lights);

        ShadowMap* dirPtr = null;
        bool cascaded = false;
        if (resolved.dirEnabled && resolved.dir.castShadows) {
            immutable cs = resolved.dir.cascades;
            cascaded = cs.count > 0;
            immutable uint layers = cascaded ? (cs.count > MAX_CASCADES ? MAX_CASCADES : cs.count) : 1;
            immutable uint res = cascaded && cs.resolution ? cs.resolution : DIR_SHADOW_RESOLUTION;
            if (hasOwnedDirShadow && (ownedDirShadow.layers != layers || ownedDirShadow.resolution != res)) {
                ownedDirShadow.destroy();
                hasOwnedDirShadow = false;
            }
            if (!hasOwnedDirShadow) {
                ownedDirShadow = ShadowMap.createForDevice(device, res, layers);
                hasOwnedDirShadow = true;
            }
            dirPtr = &ownedDirShadow;
            if (cascaded) {
                cascadeSet = buildCascades(frameCamera, resolved.dir.direction, cs);
                cascadeBlend = cs.blendFraction;
            }
        }

        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointPtrs;
        uint pUsed = 0;
        foreach (i; 0 .. resolved.pointCount < MAX_POINT_LIGHTS ? resolved.pointCount : MAX_POINT_LIGHTS) {
            if (!resolved.points[i].castShadows) continue;
            if (pUsed >= MAX_POINT_SHADOW_CASTERS) break;
            if (!hasOwnedPointShadow[pUsed]) {
                immutable farP = resolved.points[i].range > LIGHT_SHADOW_NEAR ? resolved.points[i].range : 25.0f;
                ownedPointShadows[pUsed] = PointShadowMap.createForDevice(
                    device, POINT_SHADOW_RESOLUTION, LIGHT_SHADOW_NEAR, farP);
                hasOwnedPointShadow[pUsed] = true;
            } else if (resolved.points[i].range > LIGHT_SHADOW_NEAR) {
                ownedPointShadows[pUsed].farPlane = resolved.points[i].range;
            }
            pointPtrs[pUsed] = &ownedPointShadows[pUsed];
            pUsed++;
        }

        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotPtrs;
        uint sUsed = 0;
        foreach (i; 0 .. resolved.spotCount < MAX_SPOT_LIGHTS ? resolved.spotCount : MAX_SPOT_LIGHTS) {
            if (!resolved.spots[i].castShadows) continue;
            if (sUsed >= MAX_SPOT_SHADOW_CASTERS) break;
            if (!hasOwnedSpotShadow[sUsed]) {
                ownedSpotShadows[sUsed] = SpotShadowMap.createForDevice(device, SPOT_SHADOW_RESOLUTION);
                hasOwnedSpotShadow[sUsed] = true;
            }
            spotPtrs[sUsed] = &ownedSpotShadows[sUsed];
            sUsed++;
        }

        renderShadowsImpl(frame, resolved, dirPtr, pointPtrs, spotPtrs, cascaded);
    }

    /// Automatic batch shadow rendering using caller-provided shadow maps.
    /// The directional map is rendered as one fixed view (`lights.dir.viewProj`).
    void renderShadows(ref FrameContext frame,
                       ref const LightSet lights,
                       scope ShadowMap* dirShadow,
                       scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                       scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows) @trusted {
        renderShadowsImpl(frame, lights, dirShadow, pointShadows, spotShadows, false);
    }

    private void renderShadowsImpl(ref FrameContext frame,
                       ref const LightSet lights,
                       scope ShadowMap* dirShadow,
                       scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                       scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows,
                       bool cascaded) @trusted {
        if (!frame.valid || frame.postResolved) return;
        LightSet resolved = resolveLightsForShadows(lights);

        cascadesPending = cascaded && dirShadow !is null;
        setLightsImpl(resolved, dirShadow, pointShadows, spotShadows);
        updateBuffer(queue, frameUniformBuf, (&frameData)[0 .. 1]);
        immutable uint cascadeCount = cascadesPending ? cascadeSet.count : 0;

        bool anyCast = (resolved.dirEnabled && resolved.dir.castShadows && dirShadow !is null);
        if (!anyCast) {
            foreach (i; 0 .. frameData.pointCount) {
                if (pointLightsData[i].shadowSlot >= 0) { anyCast = true; break; }
            }
        }
        if (!anyCast) {
            foreach (i; 0 .. frameData.spotCount) {
                if (frameData.spots[i].shadowSlot >= 0) { anyCast = true; break; }
            }
        }
        if (!anyCast) return;

        ensureShadowResources();

        // Fixed directional map: cull casters through the batch partition.
        // Cascades cull per view through the caster lists, like point / spot views.
        Frustum dirFrustum;
        immutable bool cullDir = resolved.dirEnabled && resolved.dir.castShadows && dirShadow !is null
            && cascadeCount == 0;
        if (cullDir)
            dirFrustum = Frustum.fromViewProj(resolved.dir.viewProj);
        uint casterBatches = 0;
        foreach (ref b; batches[0 .. batchCount]) {
            if (b.instances.length == 0 || !b.material.renderState.depthWrite) continue;
            prepareBatch(b, cullDir ? &dirFrustum : null);
            ensureBatchUploaded(b);
            casterBatches++;
        }

        // Pack all light VP matrices into aligned 256-byte dynamic-offset slots.
        import core.stdc.string : memcpy;
        void storeVp(uint slot, ref const float[16] m) {
            memcpy(shadowVpStaging.ptr + slot * SHADOW_VP_STRIDE, m.ptr, 64);
        }

        uint maxSlotUsed = 0;
        if (cascadeCount > 0) {
            foreach (c; 0 .. cascadeCount) storeVp(c, cascadeSet.viewProj[c].m);
            maxSlotUsed = cascadeCount;
        } else if (resolved.dirEnabled && resolved.dir.castShadows && dirShadow !is null) {
            storeVp(0, resolved.dir.viewProj.m);
            maxSlotUsed = 1;
        }
        foreach (i; 0 .. frameData.pointCount) {
            immutable int slot = pointLightsData[i].shadowSlot;
            if (slot < 0 || slot >= cast(int) MAX_POINT_SHADOW_CASTERS || pointShadows[slot] is null) continue;
            immutable vps = pointLightFaceVPs(
                resolved.points[i].position,
                pointShadows[slot].nearPlane,
                pointShadows[slot].farPlane);
            foreach (face; 0 .. 6) {
                immutable uSlot = DIR_SLOTS + cast(uint) slot * 6 + face;
                storeVp(uSlot, vps[face].m);
                if (uSlot + 1 > maxSlotUsed) maxSlotUsed = uSlot + 1;
            }
        }
        foreach (i; 0 .. frameData.spotCount) {
            immutable int slot = frameData.spots[i].shadowSlot;
            if (slot < 0 || slot >= cast(int) MAX_SPOT_SHADOW_CASTERS || spotShadows[slot] is null) continue;
            immutable uSlot = DIR_SLOTS + MAX_POINT_SHADOW_CASTERS * 6 + cast(uint) slot;
            storeVp(uSlot, resolved.spots[i].viewProj.m);
            if (uSlot + 1 > maxSlotUsed) maxSlotUsed = uSlot + 1;
        }

        if (maxSlotUsed == 0) return;
        wgpuQueueWriteBuffer(queue, shadowVpBuf, 0, shadowVpStaging.ptr, maxSlotUsed * SHADOW_VP_STRIDE);

        // Cull dynamic casters per point-face / spot view (the directional
        // view uses the batch partition from `prepareBatch`).
        localCulled[] = false;
        casterStaging.clear();
        if (casterBatches > 0) {
            casterRanges.resize(MAX_SHADOW_PASS_SLOTS * batchCount);
            if (cascadeCount > 0) {
                uint[MAX_CASCADES] slots;
                foreach (c; 0 .. cascadeCount) slots[c] = c;
                gatherLocalCasters(slots[0 .. cascadeCount], Vec3(0, 0, 0), 0);
            }
            foreach (i; 0 .. frameData.pointCount) {
                immutable int slot = pointLightsData[i].shadowSlot;
                if (slot < 0 || slot >= cast(int) MAX_POINT_SHADOW_CASTERS || pointShadows[slot] is null) continue;
                uint[6] slots;
                foreach (face; 0 .. 6) slots[face] = DIR_SLOTS + cast(uint) slot * 6 + face;
                gatherLocalCasters(slots[], resolved.points[i].position, pointShadows[slot].farPlane);
            }
            foreach (i; 0 .. frameData.spotCount) {
                immutable int slot = frameData.spots[i].shadowSlot;
                if (slot < 0 || slot >= cast(int) MAX_SPOT_SHADOW_CASTERS || spotShadows[slot] is null) continue;
                uint[1] slots = [DIR_SLOTS + MAX_POINT_SHADOW_CASTERS * 6 + cast(uint) slot];
                gatherLocalCasters(slots[], resolved.spots[i].position, resolved.spots[i].range);
            }
            uploadCasterStaging();
        }

        frame.suspendScenePass();
        scope(exit) frame.resumeScenePass();

        immutable bool anyGeometry = casterBatches > 0 || staticCount > 0;
        if (cascadeCount > 0) {
            foreach (c; 0 .. cascadeCount)
                encodeShadowView(frame.encoder, dirShadow.layerViews[c], c, anyGeometry,
                                 ShadowViewKind.cascade);
        } else if (resolved.dirEnabled && resolved.dir.castShadows && dirShadow !is null) {
            encodeShadowView(frame.encoder, dirShadow.depthView, 0, anyGeometry, ShadowViewKind.fixedDir);
        }
        foreach (i; 0 .. frameData.pointCount) {
            immutable int slot = pointLightsData[i].shadowSlot;
            if (slot < 0 || slot >= cast(int) MAX_POINT_SHADOW_CASTERS || pointShadows[slot] is null) continue;
            foreach (face; 0 .. 6) {
                encodeShadowView(
                    frame.encoder,
                    pointShadows[slot].faceViews[face],
                    DIR_SLOTS + cast(uint) slot * 6 + face,
                    anyGeometry, ShadowViewKind.local);
            }
        }
        foreach (i; 0 .. frameData.spotCount) {
            immutable int slot = frameData.spots[i].shadowSlot;
            if (slot < 0 || slot >= cast(int) MAX_SPOT_SHADOW_CASTERS || spotShadows[slot] is null) continue;
            encodeShadowView(
                frame.encoder,
                spotShadows[slot].depthView,
                DIR_SLOTS + MAX_POINT_SHADOW_CASTERS * 6 + cast(uint) slot,
                anyGeometry, ShadowViewKind.local);
        }
    }

    private enum ShadowViewKind : ubyte {
        /// Fixed directional map: batch partition + distance culling + hooks.
        fixedDir,
        /// One directional cascade: per-view caster lists + distance culling + hooks.
        cascade,
        /// Point face / spot view: per-view caster lists.
        local,
    }

    private static LightSet resolveLightsForShadows(ref const LightSet lights) {
        LightSet resolved = lights;
        immutable sc = resolved.spotCount < MAX_SPOT_LIGHTS ? resolved.spotCount : MAX_SPOT_LIGHTS;
        foreach (i; 0 .. sc) {
            if (!resolved.spots[i].castShadows) continue;
            if (resolved.spots[i].viewProj.m == Mat4.init.m) {
                immutable farP = resolved.spots[i].range > LIGHT_SHADOW_NEAR
                    ? resolved.spots[i].range : 25.0f;
                resolved.spots[i].viewProj = spotLightVPFromCone(
                    resolved.spots[i].position,
                    resolved.spots[i].direction,
                    resolved.spots[i].outerConeDeg,
                    LIGHT_SHADOW_NEAR,
                    farP);
            }
        }
        return resolved;
    }

    private void ensureShadowResources() @trusted {
        if (shadowPipeReady) return;
        shadowPipe = createTexShadowPipeline(device);
        shadowVpBuf = createUniformBuffer(device, MAX_SHADOW_PASS_SLOTS * SHADOW_VP_STRIDE);

        WGPUBindGroupEntry bge;
        bge.binding = 0;
        bge.buffer  = shadowVpBuf;
        bge.offset  = 0;
        bge.size    = 64;
        WGPUBindGroupDescriptor bgd;
        bgd.layout     = shadowPipe.bindGroupLayout;
        bgd.entryCount = 1;
        bgd.entries    = &bge;
        shadowVpBg = wgpuDeviceCreateBindGroup(device, &bgd);
        if (shadowVpBg is null) fatal("Failed to create scene shadow VP bind group");
        shadowPipeReady = true;
    }

    private void encodeShadowView(WGPUCommandEncoder encoder, WGPUTextureView targetView,
                                  uint vpSlot, bool drawBatches, ShadowViewKind kind) nothrow @nogc @trusted {
        auto pass = beginShadowPassView(encoder, targetView, /*clear=*/true);
        immutable bool dirView = kind == ShadowViewKind.fixedDir;
        immutable bool distanceCull = kind != ShadowViewKind.local;
        immutable uint dynOffset = vpSlot * SHADOW_VP_STRIDE;
        Mat4 lightVp;
        {
            import core.stdc.string : memcpy;
            memcpy(lightVp.m.ptr, shadowVpStaging.ptr + vpSlot * SHADOW_VP_STRIDE, 64);
        }
        immutable lightFrustum = Frustum.fromViewProj(lightVp);
        if (drawBatches) {
            wgpuRenderPassEncoderSetBindGroup(pass, 0, shadowVpBg, 1, &dynOffset);
            foreach (bi, ref b; batches[0 .. batchCount]) {
                if (b.instances.length == 0 || !b.material.renderState.depthWrite) continue;
                uint first = 0, count = cast(uint) b.instances.length;
                WGPUBuffer instBuf = b.instanceBuf;
                ulong instBytes = b.instances.length * TexInstanceData.sizeof;
                if (dirView) {
                    first = b.dirFirst;
                    count = b.dirCount;
                } else if (localCulled[vpSlot]) {
                    immutable r = casterRanges[vpSlot * batchCount + bi];
                    if (!r.all) {
                        first = r.first;
                        count = r.count;
                        instBuf = casterBuf;
                        instBytes = casterStaging.length * TexInstanceData.sizeof;
                    }
                }
                if (count == 0) continue;
                auto p = shadowPipe.pipelineFor(b.mesh.vertexStride, b.material.renderState.doubleSided);
                wgpuRenderPassEncoderSetPipeline(pass, p);
                wgpuRenderPassEncoderSetVertexBuffer(pass, 0, b.mesh.vertexBuffer, 0, b.mesh.vertexBufSize);
                wgpuRenderPassEncoderSetVertexBuffer(pass, 1, instBuf, 0, instBytes);
                ShadowLodDraw lod = b.mesh.shadowLodDraw(b.lod);
                WGPUBuffer indexBuf = lod.useLodRange ? b.mesh.indexBuffer : b.mesh.shadowDrawBuffer();
                ulong indexBytes = lod.useLodRange ? b.mesh.indexBufSize : b.mesh.shadowDrawBytes();
                wgpuRenderPassEncoderSetIndexBuffer(pass, indexBuf, b.mesh.indexFormat, 0, indexBytes);
                wgpuRenderPassEncoderDrawIndexed(pass, lod.count, count, lod.first, 0, first);
                frameStats.shadowDrawCalls++;
                frameStats.shadowInstancesDrawn += count;
            }
            if (staticCount > 0) {
                foreach (sib; staticBufs[0 .. staticCount])
                    encodeStaticShadow(pass, *sib, lightFrustum, distanceCull);
            }
        }
        if (kind != ShadowViewKind.local) {
            foreach (hook; shadowHooks[0 .. shadowHookCount])
                hook(pass, shadowVpBg, dynOffset, lightFrustum);
        }
        endShadowPass(pass);
    }

    /// Fill `casterRanges` for the views `slots` of one local light.
    private void gatherLocalCasters(scope const(uint)[] slots, Vec3 lightPos, float range) nothrow @nogc {
        Frustum[6] views;
        foreach (k, slot; slots) {
            Mat4 vp;
            import core.stdc.string : memcpy;
            () @trusted { memcpy(vp.m.ptr, shadowVpStaging.ptr + slot * SHADOW_VP_STRIDE, 64); }();
            views[k] = Frustum.fromViewProj(vp);
            localCulled[slot] = true;
        }
        CasterRange[6] ranges;
        foreach (bi, ref b; batches[0 .. batchCount]) {
            if (b.instances.length == 0 || !b.material.renderState.depthWrite) continue;
            if (!cullingEnabled || !b.mesh.hasBounds) {
                foreach (slot; slots) casterRanges[slot * batchCount + bi] = CasterRange(0, 0, true);
                continue;
            }
            gatherLightCasters(b.instances[], b.mesh.localSphere, lightPos, range, views[0 .. slots.length],
                               casterStaging, ranges[0 .. slots.length], casterCandidates, casterSpheres);
            foreach (k, slot; slots) casterRanges[slot * batchCount + bi] = ranges[k];
        }
    }

    /// Upload this frame's per-view caster lists into one shared buffer.
    private void uploadCasterStaging() nothrow @nogc @trusted {
        if (casterStaging.length == 0) return;
        if (casterStaging.length > casterCapacity) {
            size_t cap = casterCapacity ? casterCapacity : 256;
            while (cap < casterStaging.length) cap *= 2;
            destroyBuffer(casterBuf);
            casterBuf = createDynamicVertexBuffer(device, cap * TexInstanceData.sizeof);
            casterCapacity = cap;
        }
        wgpuQueueWriteBuffer(queue, casterBuf, 0, casterStaging[].ptr,
                             casterStaging.length * TexInstanceData.sizeof);
    }

    private StaticViewParams staticView(bool distanceCull) const nothrow @nogc {
        StaticViewParams v;
        v.cameraPos = lodCameraPos;
        v.fovY = lodFovY;
        v.screenHeight = lodScreenHeight;
        v.lodBias = lodBias;
        v.distanceCull = distanceCull;
        return v;
    }

    private size_t collectStaticRuns(ref StaticInstanceBuffer sib, ref const Frustum f,
                                     bool distanceCull) nothrow @nogc {
        if (staticRuns.length < sib.ranges.length) staticRuns.resize(sib.ranges.length);
        return collectVisibleRuns(sib.groups, sib.ranges, f, staticView(distanceCull), staticRuns[]);
    }

    /// Static shadow casters: culled against the light view; LOD still from
    /// the camera so shadows match the visible geometry. Distance culling
    /// applies only to the directional view (props beyond the cull distance
    /// are not drawn and should not cast either).
    private void encodeStaticShadow(WGPURenderPassEncoder pass, ref StaticInstanceBuffer sib,
                                    ref const Frustum lightFrustum, bool dirView) nothrow @nogc @trusted {
        immutable n = collectStaticRuns(sib, lightFrustum, dirView);
        foreach (ref run; staticRuns[0 .. n]) {
            auto g = &sib.groups[run.group];
            auto mesh = sib.meshes[g.mesh];
            auto mat = sib.materials[g.material];
            if (!mat.renderState.depthWrite) continue;
            auto p = shadowPipe.pipelineFor(mesh.vertexStride, mat.renderState.doubleSided);
            wgpuRenderPassEncoderSetPipeline(pass, p);
            wgpuRenderPassEncoderSetVertexBuffer(pass, 0, mesh.vertexBuffer, 0, mesh.vertexBufSize);
            wgpuRenderPassEncoderSetVertexBuffer(
                pass, 1, sib.instanceBuf, 0, sib.instanceCount * TexInstanceData.sizeof);
            ShadowLodDraw lod = mesh.shadowLodDraw(run.lod);
            WGPUBuffer indexBuf = lod.useLodRange ? mesh.indexBuffer : mesh.shadowDrawBuffer();
            ulong indexBytes = lod.useLodRange ? mesh.indexBufSize : mesh.shadowDrawBytes();
            wgpuRenderPassEncoderSetIndexBuffer(pass, indexBuf, mesh.indexFormat, 0, indexBytes);
            wgpuRenderPassEncoderDrawIndexed(pass, lod.count, run.count, lod.first, 0, run.firstInstance);
            frameStats.shadowDrawCalls++;
        }
    }

    /// Static color draws (opaque pass). Instance buffers are shared by all
    /// runs of one `StaticInstanceBuffer`; only `firstInstance` changes.
    private void drawStatic(ref FrameContext frame, ref StaticInstanceBuffer sib) @trusted {
        immutable n = collectStaticRuns(sib, cameraFrustum, true);
        foreach (ref run; staticRuns[0 .. n]) {
            auto g = &sib.groups[run.group];
            auto mesh = sib.meshes[g.mesh];
            auto mat = sib.materials[g.material];
            immutable tangent = mesh.vertexStride == 48;
            auto pipe = pipelineFor(mat.surfaceShader, mat.renderState, tangent);
            if (pipe is null) continue;
            frame.setPipeline(pipe);
            frame.setBindGroup(1, mat.bindGroup);
            frame.setVertexBuffer(0, mesh.vertexBuffer, mesh.vertexBufSize);
            frame.setVertexBuffer(1, sib.instanceBuf, sib.instanceCount * TexInstanceData.sizeof);
            frame.setIndexBuffer(mesh.indexBuffer, mesh.indexFormat, mesh.indexBufSize);
            immutable range = mesh.colorLodRange(run.lod);
            frame.drawIndexed(range.count, run.count, range.first, 0, run.firstInstance);
            frameStats.drawCalls++;
            frameStats.staticRangesDrawn++;
            frameStats.staticInstancesVisible += run.count;
            frameStats.lodHistogram[run.lod < 3 ? run.lod : 3] += run.count;
        }
    }

    void draw(ref TexMesh mesh, ref Material material,
              Vec3 pos, Vec3 scale, Color4 tint = Color4.white, float rotationY = 0) {
        auto model = Mat4.translation(pos.x, pos.y, pos.z)
                   * Mat4.rotationY(rotationY)
                   * Mat4.scaling(scale.x, scale.y, scale.z);
        drawMatrix(mesh, material, model, tint);
    }

    void drawMatrix(ref TexMesh mesh, ref Material material, Mat4 model, Color4 tint) {
        drawMatrix(mesh, material, model, tint, [1.0f, 0.0f, 0.0f, 0.0f]);
    }

    /// Draw with a per-instance `custom` vec4. Stock meaning: x = emission
    /// multiplier (1 = material value), y = white flash [0..1], z = dissolve
    /// threshold [0..1, 0 = intact]; w is free for custom surface shaders.
    void drawMatrix(ref TexMesh mesh, ref Material material, Mat4 model, Color4 tint, float[4] custom) nothrow @nogc {
        drawMatrix(mesh, material, model, tint, custom, LOD_AUTO);
    }

    /// Draw a LOD level of `mesh`: an explicit level (`MeshLod.current`;
    /// levels past the chain clamp to the last) or `LOD_AUTO`.
    void drawMatrix(ref TexMesh mesh, ref Material material, Mat4 model, Color4 tint,
                    float[4] custom, ubyte lod) nothrow @nogc {
        if (lod == LOD_AUTO)
            lod = autoLod(mesh, model);
        else if (mesh.lodLevels <= 1)
            lod = 0;
        auto b = findOrAdd(mesh, material, lod);
        if (b is null) return;
        b.instances.put(TexInstanceData(model.m, tint.toArray(), custom));
    }

    /// Screen-space LOD for one instance (stateless: no hysteresis).
    private ubyte autoLod(ref const TexMesh mesh, ref const Mat4 model) const nothrow @nogc {
        auto errors = mesh.lodErrorList();
        if (errors.length == 0) return 0;
        immutable c = mesh.localSphere.transformed(model).center;
        immutable d = Vec3(c.x - lodCameraPos.x, c.y - lodCameraPos.y, c.z - lodCameraPos.z).length();
        return selectLod(errors, LOD_NONE, mesh.lodMeshScale, maxAxisScale(model), d,
                         lodFovY, lodScreenHeight, lodBias);
    }

    void end(ref FrameContext frame) @trusted {
        import std.algorithm.sorting : sort;

        if (!frame.valid) return;

        frame.setBindGroup(0, frameBindGroup);
        frame.setBindGroup(2, iblBindGroup);

        immutable cam = Vec3(frameData.cameraPos[0], frameData.cameraPos[1], frameData.cameraPos[2]);
        static float distSq(ref const TexInstanceData d, Vec3 c) pure nothrow @nogc {
            immutable dx = d.model[12] - c.x, dy = d.model[13] - c.y, dz = d.model[14] - c.z;
            return dx * dx + dy * dy + dz * dz;
        }

        // Pass 0: depth-writing batches in submission order. Pass 1: alpha
        // batches without depth write, back to front. Pass 2: additive.
        foreach (ref b; batches[0 .. batchCount]) {
            if (b.instances.length == 0) continue;
            prepareBatch(b, null);
            frameStats.batches++;
            frameStats.instancesSubmitted += cast(uint) b.instances.length;
            frameStats.instancesVisible += b.colorCount;
        }

        uint orderCount = 0;
        foreach (pass; 0 .. 3) {
            orderCount = 0;
            foreach (i, ref b; batches[0 .. batchCount]) {
                if (b.colorCount == 0) continue;
                immutable st = b.material.renderState;
                immutable p = st.depthWrite ? 0 : (st.blend == BlendMode.additive ? 2 : 1);
                if (p != pass) continue;
                if (pass == 1) {
                    b.instances[b.colorFirst .. b.colorFirst + b.colorCount]
                        .sort!((x, y) => distSq(x, cam) > distSq(y, cam));
                    b.uploaded = false;
                    sortFarthest[i] = distSq(b.instances[b.colorFirst], cam);
                }
                sortOrder[orderCount++] = cast(uint) i;
            }
            if (pass == 1)
                sortOrder[0 .. orderCount].sort!((x, y) => sortFarthest[x] > sortFarthest[y]);
            foreach (idx; sortOrder[0 .. orderCount]) drawBatch(frame, batches[idx]);
            if (pass == 0)
                foreach (sib; staticBufs[0 .. staticCount]) drawStatic(frame, *sib);
        }
    }

    /**
     * Cull a batch once per frame. Instances are reordered into
     * `[camera only | camera + light | light only | culled]` so the color
     * pass and the directional shadow pass each draw one contiguous range
     * of the single uploaded instance buffer.
     */
    private void prepareBatch(ref Batch b, scope const(Frustum)* light) nothrow @nogc {
        if (b.prepared) return;
        b.prepared = true;
        b.uploaded = false;
        immutable n = cast(uint) b.instances.length;
        if (!cullingEnabled || !b.mesh.hasBounds || n == 0) {
            b.colorFirst = 0;
            b.colorCount = n;
            b.dirFirst = 0;
            b.dirCount = n;
            return;
        }
        immutable local = b.mesh.localSphere;
        partitionClasses.resize(n);
        partitionScratch.resize(n);
        foreach (i, ref inst; b.instances[]) {
            Mat4 model;
            model.m = inst.model;
            immutable ws = local.transformed(model);
            immutable bool cam = cameraFrustum.intersectsSphere(ws) && passesDistanceCull(ws);
            immutable bool lit = light !is null && light.intersectsSphere(ws);
            partitionClasses[i] = cam ? (lit ? 1 : 0) : (lit ? 2 : 3);
        }
        immutable counts = partitionByClass(b.instances[], partitionClasses[], partitionScratch[]);
        b.colorFirst = 0;
        b.colorCount = counts[0] + counts[1];
        if (light !is null) {
            b.dirFirst = counts[0];
            b.dirCount = counts[1] + counts[2];
        } else {
            b.dirFirst = 0;
            b.dirCount = n;
        }
    }

    private bool passesDistanceCull(BoundingSphere ws) const nothrow @nogc {
        if (cullMaxDistance <= 0 && cullMinPixels <= 0) return true;
        immutable d = (ws.center - lodCameraPos).length();
        if (cullMaxDistance > 0 && d - ws.radius > cullMaxDistance) return false;
        if (cullMinPixels > 0 && d > ws.radius
                && projectedPixels(2 * ws.radius, d, lodFovY, lodScreenHeight) < cullMinPixels)
            return false;
        return true;
    }

    private void ensureBatchUploaded(ref Batch b) @trusted {
        if (b.uploaded) return;
        if (b.instances.length > b.capacity) {
            size_t cap = b.capacity;
            while (cap < b.instances.length) cap *= 2;
            destroyBuffer(b.instanceBuf);
            b.instanceBuf = createDynamicVertexBuffer(device, cap * TexInstanceData.sizeof);
            b.capacity = cap;
        }
        updateBuffer(queue, b.instanceBuf, b.instances[]);
        b.uploaded = true;
    }

    private void drawBatch(ref FrameContext frame, ref Batch b) @trusted {
        ensureBatchUploaded(b);

        immutable tangent = b.mesh.vertexStride == 48;
        auto pipe = pipelineFor(b.material.surfaceShader, b.material.renderState, tangent);
        if (pipe is null) return;
        frame.setPipeline(pipe);
        frame.setBindGroup(1, b.material.bindGroup);
        frame.setVertexBuffer(0, b.mesh.vertexBuffer, b.mesh.vertexBufSize);
        frame.setVertexBuffer(1, b.instanceBuf, b.instances.length * TexInstanceData.sizeof);
        frame.setIndexBuffer(b.mesh.indexBuffer, b.mesh.indexFormat, b.mesh.indexBufSize);
        immutable range = b.mesh.colorLodRange(b.lod);
        frame.drawIndexed(range.count, b.colorCount, range.first, 0, b.colorFirst);
        frameStats.drawCalls++;
        frameStats.lodHistogram[b.lod < 3 ? b.lod : 3] += b.colorCount;
    }

    /// Pipeline for a surface shader id + render state, built on first use.
    private WGPURenderPipeline pipelineFor(uint shaderId, RenderState state, bool tangent) @trusted {
        if (shaderId > surfaceShaderCount) shaderId = 0;
        if (state.isDefault) {
            if (shaderId == 0) return tangent ? pipeline.pipelineTangent : pipeline.pipeline;
            auto custom = &surfaceShaders[shaderId - 1];
            return tangent ? custom.pipelineTangent : custom.pipeline;
        }
        foreach (ref v; variants[0 .. variantCount]) {
            if (v.shaderId == shaderId && v.state == state)
                return tangent ? v.pipelineTangent : v.pipeline;
        }
        if (variantCount >= MAX_VARIANTS) {
            warn("Textured pipeline variant table full; drawing with the default render state");
            return pipelineFor(shaderId, RenderState.init, tangent);
        }
        auto module32 = shaderId == 0 ? pipeline.shaderModule : surfaceShaders[shaderId - 1].shaderModule;
        auto module48 = shaderId == 0 ? pipeline.shaderModuleTangent : surfaceShaders[shaderId - 1].shaderModuleTangent;
        PipelineVariant v;
        v.shaderId = shaderId;
        v.state = state;
        v.pipeline = createTexturedDrawPipeline(device, module32, pipeline.pipelineLayout,
                                                Renderer.sceneFormat(), 32, false, state);
        v.pipelineTangent = createTexturedDrawPipeline(device, module48, pipeline.pipelineLayout,
                                                       Renderer.sceneFormat(), 48, true, state);
        variants[variantCount++] = v;
        return tangent ? v.pipelineTangent : v.pipeline;
    }

    /// Drop cached variants of one shader (after a hot reload).
    private void releaseVariants(uint shaderId) nothrow @nogc @trusted {
        uint kept = 0;
        foreach (ref v; variants[0 .. variantCount]) {
            if (v.shaderId == shaderId) {
                if (v.pipeline !is null) wgpuRenderPipelineRelease(v.pipeline);
                if (v.pipelineTangent !is null) wgpuRenderPipelineRelease(v.pipelineTangent);
            } else {
                variants[kept++] = v;
            }
        }
        variantCount = kept;
    }

    void destroy() nothrow @nogc @trusted {
        foreach (ref v; variants[0 .. variantCount]) {
            if (v.pipeline !is null) wgpuRenderPipelineRelease(v.pipeline);
            if (v.pipelineTangent !is null) wgpuRenderPipelineRelease(v.pipelineTangent);
        }
        variantCount = 0;
        foreach (ref s; surfaceShaders[0 .. surfaceShaderCount]) s.release();
        surfaceShaderCount = 0;
        foreach (ref b; batches) {
            destroyBuffer(b.instanceBuf);
            b.instances.release();
        }
        partitionScratch.release();
        partitionClasses.release();
        staticRuns.release();
        destroyBuffer(casterBuf);
        casterBuf = null;
        casterCapacity = 0;
        casterStaging.release();
        casterRanges.release();
        casterCandidates.release();
        casterSpheres.release();
        if (frameBindGroup !is null) {
            wgpuBindGroupRelease(frameBindGroup);
            frameBindGroup = null;
        }
        destroyBuffer(frameUniformBuf);
        destroyBuffer(pointLightsBuf);
        pointLightsBuf = null;
        if (ownsIbl) ownedIbl.destroy();
        if (defaultShadowSampler !is null) {
            wgpuSamplerRelease(defaultShadowSampler);
            defaultShadowSampler = null;
        }
        if (defaultShadow2dView !is null) {
            wgpuTextureViewRelease(defaultShadow2dView);
            defaultShadow2dView = null;
        }
        if (defaultShadowArrayView !is null) {
            wgpuTextureViewRelease(defaultShadowArrayView);
            defaultShadowArrayView = null;
        }
        if (defaultShadow2dTex !is null) {
            wgpuTextureRelease(defaultShadow2dTex);
            defaultShadow2dTex = null;
        }
        if (defaultShadowCubeView !is null) {
            wgpuTextureViewRelease(defaultShadowCubeView);
            defaultShadowCubeView = null;
        }
        if (defaultShadowCubeTex !is null) {
            wgpuTextureRelease(defaultShadowCubeTex);
            defaultShadowCubeTex = null;
        }
        if (hasOwnedDirShadow) { ownedDirShadow.destroy(); hasOwnedDirShadow = false; }
        foreach (i; 0 .. MAX_POINT_SHADOW_CASTERS) {
            if (hasOwnedPointShadow[i]) { ownedPointShadows[i].destroy(); hasOwnedPointShadow[i] = false; }
        }
        foreach (i; 0 .. MAX_SPOT_SHADOW_CASTERS) {
            if (hasOwnedSpotShadow[i]) { ownedSpotShadows[i].destroy(); hasOwnedSpotShadow[i] = false; }
        }
        if (shadowVpBg !is null) { wgpuBindGroupRelease(shadowVpBg); shadowVpBg = null; }
        destroyBuffer(shadowVpBuf); shadowVpBuf = null;
        if (shadowPipeReady) { shadowPipe.release(); shadowPipeReady = false; }
        pipeline.release();
    }

    private void createDefaultShadows(WGPUDevice device) @trusted {
        // 1×1 2D depth (dir / spot placeholders)
        {
            WGPUTextureDescriptor td;
            td.usage = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
            td.dimension = WGPUTextureDimension.dim2D;
            td.size = WGPUExtent3D(1, 1, 1);
            td.format = WGPUTextureFormat.depth32Float;
            defaultShadow2dTex = wgpuDeviceCreateTexture(device, &td);

            WGPUTextureViewDescriptor vd;
            vd.format = WGPUTextureFormat.depth32Float;
            vd.dimension = WGPUTextureViewDimension.dim2D;
            vd.aspect = WGPUTextureAspect.depthOnly;
            defaultShadow2dView = wgpuTextureCreateView(defaultShadow2dTex, &vd);

            WGPUTextureViewDescriptor avd;
            avd.format = WGPUTextureFormat.depth32Float;
            avd.dimension = WGPUTextureViewDimension.dim2DArray;
            avd.aspect = WGPUTextureAspect.depthOnly;
            avd.baseArrayLayer = 0;
            avd.arrayLayerCount = 1;
            defaultShadowArrayView = wgpuTextureCreateView(defaultShadow2dTex, &avd);
        }
        // 1×1×6 depth cube (point placeholders)
        {
            WGPUTextureDescriptor td;
            td.usage = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding;
            td.dimension = WGPUTextureDimension.dim2D;
            td.size = WGPUExtent3D(1, 1, 6);
            td.format = WGPUTextureFormat.depth32Float;
            defaultShadowCubeTex = wgpuDeviceCreateTexture(device, &td);

            WGPUTextureViewDescriptor vd;
            vd.format = WGPUTextureFormat.depth32Float;
            vd.dimension = WGPUTextureViewDimension.cube;
            vd.aspect = WGPUTextureAspect.depthOnly;
            vd.baseArrayLayer = 0;
            vd.arrayLayerCount = 6;
            defaultShadowCubeView = wgpuTextureCreateView(defaultShadowCubeTex, &vd);
        }

        WGPUSamplerDescriptor sd;
        sd.addressModeU = WGPUAddressMode.clampToEdge;
        sd.addressModeV = WGPUAddressMode.clampToEdge;
        sd.addressModeW = WGPUAddressMode.clampToEdge;
        sd.magFilter = WGPUFilterMode.linear;
        sd.minFilter = WGPUFilterMode.linear;
        sd.mipmapFilter = WGPUMipmapFilterMode.nearest;
        sd.compare = WGPUCompareFunction.lessEqual;
        sd.maxAnisotropy = 1;
        defaultShadowSampler = wgpuDeviceCreateSampler(device, &sd);

        // Clear depths to 1 so PCF comparisons pass (fully lit) until setLights.
        clearDepthView(device, defaultShadow2dView);
        foreach (face; 0 .. 6) {
            WGPUTextureViewDescriptor faceVd;
            faceVd.format = WGPUTextureFormat.depth32Float;
            faceVd.dimension = WGPUTextureViewDimension.dim2D;
            faceVd.aspect = WGPUTextureAspect.depthOnly;
            faceVd.baseArrayLayer = face;
            faceVd.arrayLayerCount = 1;
            auto faceView = wgpuTextureCreateView(defaultShadowCubeTex, &faceVd);
            clearDepthView(device, faceView);
            wgpuTextureViewRelease(faceView);
        }
    }

    private void clearDepthView(WGPUDevice device, WGPUTextureView view) @trusted {
        WGPUCommandEncoderDescriptor encDesc;
        auto enc = wgpuDeviceCreateCommandEncoder(device, &encDesc);
        WGPURenderPassDepthStencilAttachment depthAtt;
        depthAtt.view = view;
        depthAtt.depthLoadOp = WGPULoadOp.clear;
        depthAtt.depthStoreOp = WGPUStoreOp.store;
        depthAtt.depthClearValue = 1.0f;
        WGPURenderPassDescriptor pd;
        pd.depthStencilAttachment = &depthAtt;
        auto pass = wgpuCommandEncoderBeginRenderPass(enc, &pd);
        wgpuRenderPassEncoderEnd(pass);
        wgpuRenderPassEncoderRelease(pass);
        WGPUCommandBufferDescriptor cbDesc;
        auto cmd = wgpuCommandEncoderFinish(enc, &cbDesc);
        wgpuCommandEncoderRelease(enc);
        wgpuQueueSubmit(queue, 1, &cmd);
        wgpuCommandBufferRelease(cmd);
    }

    private void rebuildFrameBindGroup(
        WGPUSampler shadowSampler,
        WGPUTextureView dirView,
        WGPUTextureView point0, WGPUTextureView point1,
        WGPUTextureView point2, WGPUTextureView point3,
        WGPUTextureView spot0, WGPUTextureView spot1) @trusted
    {
        WGPUTextureView[7] views = [dirView, point0, point1, point2, point3, spot0, spot1];
        if (frameBindGroup !is null && shadowSampler is boundShadowSampler && views == boundShadowViews)
            return;
        boundShadowSampler = shadowSampler;
        boundShadowViews = views;
        if (frameBindGroup !is null) {
            wgpuBindGroupRelease(frameBindGroup);
            frameBindGroup = null;
        }
        WGPUBindGroupEntry[10] entries;
        entries[0].binding = 0;
        entries[0].buffer = frameUniformBuf;
        entries[0].offset = 0;
        entries[0].size = FRAME_UNIFORMS_SIZE;
        entries[1].binding = 1;
        entries[1].sampler = shadowSampler;
        entries[2].binding = 2;
        entries[2].textureView = dirView;
        entries[3].binding = 3;
        entries[3].textureView = point0;
        entries[4].binding = 4;
        entries[4].textureView = point1;
        entries[5].binding = 5;
        entries[5].textureView = point2;
        entries[6].binding = 6;
        entries[6].textureView = point3;
        entries[7].binding = 7;
        entries[7].textureView = spot0;
        entries[8].binding = 8;
        entries[8].textureView = spot1;
        entries[9].binding = 9;
        entries[9].buffer = pointLightsBuf;
        entries[9].offset = 0;
        entries[9].size = MAX_POINT_LIGHTS * GpuPointLightUbo.sizeof;

        WGPUBindGroupDescriptor desc;
        desc.layout = pipeline.frameBindGroupLayout;
        desc.entryCount = 10;
        desc.entries = entries.ptr;
        frameBindGroup = wgpuDeviceCreateBindGroup(device, &desc);
        if (frameBindGroup is null) fatal("Failed to create frame bind group");
    }

    private Batch* findOrAdd(ref TexMesh mesh, ref Material material, ubyte lod) nothrow @nogc @trusted {
        immutable meshKey = cast(size_t) &mesh;
        immutable matKey = cast(size_t) &material;
        immutable found = batchMap.find(meshKey, matKey, lod);
        if (found != BatchMap.none) return &batches[found];
        if (batchCount >= batches.length) {
            if (!warnedBatchOverflow)
                warn("Scene3DTextured: more than ", batches.length, " (mesh, material, lod) batches; extra draws are dropped");
            warnedBatchOverflow = true;
            return null;
        }
        auto b = &batches[batchCount];
        b.mesh = &mesh;
        b.material = &material;
        b.lod = lod;
        b.instances.clear();
        b.uploaded = false;
        b.prepared = false;
        batchMap.insert(meshKey, matKey, lod, batchCount);
        batchCount++;
        return b;
    }
}

/**
 * Open-addressed `(mesh, material, lod) → batch index` table with linear
 * probing. `reset` bumps an epoch instead of clearing slots, so starting a
 * frame is O(1). Capacity is a power of two ≥ 2× the batch limit, which keeps
 * probes short and guarantees `insert` finds a free slot.
 */
package(engine) struct BatchMap {
    enum uint none = uint.max;

    private static struct Slot {
        size_t mesh;
        size_t material;
        uint lod;
        uint epoch;
        uint batch;
    }
    private Pod!Slot[] slots;
    private uint epoch = 1;

    void reserve(size_t maxBatches) {
        size_t cap = 16;
        while (cap < maxBatches * 2) cap <<= 1;
        slots = new Slot[cap];
        epoch = 1;
    }

    /// Forget every entry (O(1) except on epoch wrap).
    void reset() pure nothrow @nogc {
        epoch++;
        if (epoch == 0) {
            foreach (ref sl; slots) sl.epoch = 0;
            epoch = 1;
        }
    }

    private size_t home(size_t mesh, size_t material, uint lod) const pure nothrow @nogc {
        ulong h = cast(ulong) mesh * 0x9E37_79B9_7F4A_7C15UL;
        h ^= (cast(ulong) material + 0x632B_E59B_D9B4_E019UL) * 0xC2B2_AE3D_27D4_EB4FUL;
        h ^= cast(ulong) lod * 0x1656_67B1_9E37_79F9UL;
        h ^= h >> 29;
        return cast(size_t) h & (slots.length - 1);
    }

    /// Batch index or `none`.
    uint find(size_t mesh, size_t material, uint lod) const pure nothrow @nogc {
        if (slots.length == 0) return none;
        size_t i = home(mesh, material, lod);
        foreach (_; 0 .. slots.length) {
            auto sl = &slots[i];
            if (sl.epoch != epoch) return none;
            if (sl.mesh == mesh && sl.material == material && sl.lod == lod) return sl.batch;
            i = (i + 1) & (slots.length - 1);
        }
        return none;
    }

    /// Insert a key known to be absent. False when the table is full.
    bool insert(size_t mesh, size_t material, uint lod, uint batch) pure nothrow @nogc {
        if (slots.length == 0) return false;
        size_t i = home(mesh, material, lod);
        foreach (_; 0 .. slots.length) {
            auto sl = &slots[i];
            if (sl.epoch != epoch) {
                *sl = Slot(mesh, material, lod, epoch, batch);
                return true;
            }
            i = (i + 1) & (slots.length - 1);
        }
        return false;
    }
}

@("scene3dTextured.batchMap") @safe unittest {
    BatchMap map;
    map.reserve(4); // 16 slots
    assert(map.find(1, 2, 0) == BatchMap.none);
    assert(map.insert(1, 2, 0, 0));
    assert(map.insert(1, 2, 1, 1));   // same mesh/material, other LOD
    assert(map.insert(3, 2, 0, 2));
    assert(map.find(1, 2, 0) == 0);
    assert(map.find(1, 2, 1) == 1);
    assert(map.find(3, 2, 0) == 2);
    assert(map.find(3, 4, 0) == BatchMap.none);

    // Epoch reset forgets everything without touching slots.
    map.reset();
    assert(map.find(1, 2, 0) == BatchMap.none);
    assert(map.insert(1, 2, 0, 7));
    assert(map.find(1, 2, 0) == 7);

    // Fill the table: colliding keys still resolve, then insert reports full.
    map.reset();
    foreach (uint k; 0 .. 16)
        assert(map.insert(k * 16, 0, 0, k));
    foreach (uint k; 0 .. 16)
        assert(map.find(k * 16, 0, 0) == k);
    assert(!map.insert(999, 0, 0, 99));
}

@safe unittest {
    LightSet ls;
    ls.spotCount = 2;
    ls.spots[0].position = Vec3(0, 5, 0);
    ls.spots[0].direction = Vec3(0, -1, 0);
    ls.spots[0].range = 40.0f;
    ls.spots[0].outerConeDeg = 30.0f;
    ls.spots[0].castShadows = true;
    // Identity viewProj must be auto-resolved for shadow-casting spots.
    ls.spots[1].castShadows = true;
    auto customVP = Mat4.translation(1, 2, 3);
    ls.spots[1].viewProj = customVP;

    auto resolved = Scene3DTextured.resolveLightsForShadows(ls);
    assert(resolved.spots[0].viewProj.m != Mat4.identity().m);
    assert(resolved.spots[1].viewProj.m == customVP.m);
}

@("scene3dTextured.partition") @safe nothrow @nogc unittest {
    TexInstanceData[6] items;
    foreach (i, ref it; items) it.model[12] = i;
    immutable ubyte[6] classes = [3, 0, 2, 1, 0, 2];
    TexInstanceData[6] scratch;
    immutable counts = partitionByClass(items[], classes[], scratch[]);
    assert(counts == [2, 1, 2, 1]);
    // Stable order inside each class: 1,4 | 3 | 2,5 | 0
    immutable float[6] expected = [1, 4, 3, 2, 5, 0];
    foreach (i; 0 .. 6) assert(items[i].model[12] == expected[i]);
}

@("scene3dTextured.lightCasters") unittest {
    import engine.gpu.shadow : pointLightFaceVPs;
    // Five unit spheres along +X from a point light at the origin, range 10.
    TexInstanceData[5] items;
    immutable float[5] xs = [3, 8, 12, 30, -4];
    foreach (i, ref it; items) {
        it.model[] = 0;
        it.model[0] = it.model[5] = it.model[10] = it.model[15] = 1;
        it.model[12] = xs[i];
    }
    immutable local = BoundingSphere(Vec3(0, 0, 0), 1);
    immutable vps = pointLightFaceVPs(Vec3(0, 0, 0), 0.1f, 10.0f);
    Frustum[6] views;
    foreach (f; 0 .. 6) views[f] = Frustum.fromViewProj(vps[f]);

    PodBuffer!TexInstanceData staging;
    PodBuffer!uint cand;
    PodBuffer!BoundingSphere spheres;
    CasterRange[6] ranges;
    gatherLightCasters(items[], local, Vec3(0, 0, 0), 10, views[], staging, ranges[], cand, spheres);

    // x = 12 is within range + radius? 12 > 11 → rejected; x = 30 rejected.
    // Faces are 90° frusta: +X face sees x = 3 and x = 8, -X face sees x = -4.
    uint total = 0, plusX = 0, minusX = 0;
    foreach (f; 0 .. 6) {
        total += ranges[f].count;
        foreach (ref it; staging[][ranges[f].first .. ranges[f].first + ranges[f].count]) {
            assert(it.model[12] != 12 && it.model[12] != 30);
            if (it.model[12] > 0) plusX++;
            else minusX++;
        }
        if (f > 0) assert(ranges[f].first == ranges[f - 1].first + ranges[f - 1].count);
    }
    assert(plusX >= 2 && minusX >= 1);
    // Unit spheres touch neighbouring faces at most along edges, so far
    // fewer copies than 6 faces × 5 instances.
    assert(total < 12 && total == staging.length);
    staging.release();
    cand.release();
    spheres.release();
}
