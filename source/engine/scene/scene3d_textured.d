/// Scene3DTextured — batched textured-mesh renderer with multi-light PBR +
/// shadows + IBL. Batches keyed by (TexMesh, Material). Frame uniforms and
/// shadow/IBL bind groups are owned by the scene (group 0 / group 2);
/// materials own group 1.
module engine.scene.scene3d_textured;

import std.math : cos, PI;

import bindings.wgpu;
import engine.core.log;
import engine.core.podbuf : PodBuffer;
import engine.editor.components : MAX_REFLECTION_PROBES, ReflectionProbe;
import engine.gpu.buffer;
import engine.gpu.clustered : ClusteredLightCuller, computeClusterZParams;
import engine.gpu.context : GpuContext;
import engine.gpu.ibl : IblEnvironment;
import engine.gpu.pipeline : BlendMode, Pipeline3D, RenderState, SurfacePipelines, TexInstanceData,
    createSkinnedTexturedDrawPipeline, createSurfacePipelines, createTexturedDrawPipeline,
    createTexturedPipeline3D, FRAME_UNIFORMS_SIZE;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.skinned : SkinnedMesh;
import engine.gpu.sky : SkyRenderer;
import engine.gpu.shaders : DisplaceKind;
import engine.gpu.shadow : SURFACE_SHADOW_LIGHT_BINDING, createSurfaceShadowPipeline,
    beginShadowPassView, createTexShadowPipeline, endShadowPass,
    pointLightFaceVPs, PointShadowMap, ShadowMap, SpotShadowMap,
    spotLightVPFromCone, TexShadowPipeline;
import engine.graphics.types : Color4;
import engine.graphics.texmesh : ShadowLodDraw, TexMesh;
import engine.graphics.material : Material;
import engine.graphics.lod : LOD_NONE, projectedPixels, selectLod;
import engine.math.bounds : Aabb, BoundingSphere, maxAxisScale;
import engine.math.frustum : Frustum;
import engine.meshopt.internal.bits : bitsFloat, floatBits;
import engine.scene.static_instances : collectVisibleRuns, StaticInstanceBuffer, StaticRun, StaticViewParams;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.atmosphere : FogSettings, packFog;
import engine.scene.cascades : buildCascades, CascadeSet, MAX_CASCADES;
import engine.scene.light :
    DIR_SHADOW_RESOLUTION, GpuDirLight, GpuPointLight, GpuSpotLight,
    LIGHT_SHADOW_NEAR, LightList, LightSet,
    MAX_POINT_LIGHTS, MAX_POINT_SHADOW_CASTERS,
    MAX_SPOT_LIGHTS, MAX_SPOT_SHADOW_CASTERS,
    POINT_SHADOW_RESOLUTION, SPOT_SHADOW_RESOLUTION;
import engine.gpu.pipeline : FRAME_BINDING_COUNT;
import engine.water.gpu_data : GpuWaterData, WATER_DATA_SIZE;
import engine.devtools.profiler : profileZone;
import engine.gpu.gpu_profiler : gpuScope, gpuFrameScope;

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

/// Opaque renderer drawn inside `Scene3DTextured.end` (see `addOpaqueHook`).
alias OpaqueDrawHook = void delegate(ref FrameContext frame) nothrow @nogc;

/// `drawMatrix` LOD argument: pick the level from the camera distance and the
/// mesh's simplifier errors (LOD0 for meshes without a chain).
enum ubyte LOD_AUTO = 0xFF;
private enum ubyte SKINNED_BATCH_LOD = 0xFE;
private enum size_t INITIAL_SKIN_PALETTE_MATRICES = 4096;
private enum size_t MAX_SKIN_PALETTE_MATRICES = 65536;

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
    /// Draws dropped because the batch table hit `MAX_BATCHES_HARD`
    /// (always 0 below that ceiling: the table grows instead).
    uint droppedDraws;
}

/// Occupancy of the `Scene3DTextured` (mesh, material, lod) batch table, for
/// perf overlays and headless budget gates (`Scene3DTextured.batchStats`).
struct BatchStats {
    /// Batches used by the frame recorded since the last `begin`, including
    /// batches whose instances were all culled (`RenderStats.batches` counts
    /// only the drawn ones).
    uint used;
    /// Highest `used` since the scene was created.
    uint peak;
    /// Current table size; it doubles on demand up to `MAX_BATCHES_HARD`.
    uint capacity;
    /// Times the table grew past its initial `create` capacity.
    uint growths;
    /// Draws dropped at `MAX_BATCHES_HARD` since the scene was created.
    ulong droppedDraws;
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
                        ref PodBuffer!uint candScratch, ref PodBuffer!BoundingSphere sphereScratch,
                        bool isSkinned = false) nothrow @nogc {
    assert(outRanges.length >= views.length);
    candScratch.clear();
    sphereScratch.clear();
    foreach (i, ref inst; items) {
        BoundingSphere ws;
        if (isSkinned) {
            ws = unpackSkinnedWorldSphere(inst);
        } else {
            Mat4 model;
            model.m = inst.model;
            ws = localSphere.transformed(model);
        }
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

/// GPU mirror of WGSL `ReflectionProbeData` (48 bytes = 3 × vec4<f32>).
struct GpuReflectionProbeUbo {
    float[4] posRadius = [0, 1, 0, 8];    // xyz = center, |w| = radius (w > 0 => box projection)
    float[4] boxBlend = [8, 4, 8, 2];     // xyz = half-extents, w = blend distance
    float[4] tintIntensity = [1, 1, 1, 0]; // rgb = tint, w = intensity (0 = disabled)
}
static assert(GpuReflectionProbeUbo.sizeof == 48);

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
    /// xyz = true sun direction for the sky (surface → sun), w = 1 when set
    /// (otherwise the sky uses the directional light — which may be the moon).
    float[4] skySunDir = [0, 1, 0, 0];
    /// rgb = sun color for the sky.
    float[4] skySunColor = [1, 0.97f, 0.92f, 0];

    // --- OPBR-9: Local Reflection Probes & Screen-Space Reflections ---
    /// x = enabled (0/1), y = maxDistance (m), z = thickness (m), w = intensity.
    float[4] ssrParams = [0.0f, 16.0f, 0.35f, 1.0f];
    uint probeCount = 0;
    /// Bit 0: clustered forward culling enabled (1 = cluster lookup, 0 = linear fallback).
    uint clusteredFlags = 1;
    uint _probePad1 = 0;
    uint _probePad2 = 0;
    GpuReflectionProbeUbo[MAX_REFLECTION_PROBES] probes;

    // --- Clustered Forward ---
    /// Active viewport rectangle in pixels `(vpX, vpY, vpW, vpH)` for tile lookup.
    float[4] viewportRect = [0.0f, 0.0f, 1920.0f, 1080.0f];
    /// `(zScale, zBias, nearZ, farZ)` for logarithmic cluster slice lookup.
    float[4] clusterZParams = [0.0f, 0.0f, 0.1f, 100.0f];
}
static assert(FrameUniforms.sizeof == FRAME_UNIFORMS_SIZE);

/// Batched renderer for textured instanced 3D meshes (PBR path).
struct Scene3DTextured {
    private Pipeline3D pipeline;
    private WGPUBuffer frameUniformBuf;
    private WGPUBuffer pointLightsBuf;
    private WGPUBuffer spotLightsBuf;
    /// Shared water data (frame binding 10, `common/waves.wgsl`).
    private WGPUBuffer waterDataBuf;
    private ClusteredLightCuller clusterCuller;
    private bool clusteredEnabled = true;
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
    private enum uint INITIAL_POINT_LIGHT_CAP = MAX_POINT_LIGHTS;
    private enum uint INITIAL_SPOT_LIGHT_CAP = MAX_SPOT_LIGHTS;
    private PodBuffer!GpuPointLightUbo pointLightsStaging;
    private PodBuffer!GpuSpotLightUbo spotLightsStaging;
    private uint pointLightBufCap = 0;
    private uint spotLightBufCap = 0;
    private uint lightBufGen = 0;
    private uint boundLightBufGen = uint.max;
    private bool localLightsDirty = false;
    private WGPUBuffer boundPointLightsBuf;
    private WGPUBuffer boundSpotLightsBuf;

    private enum DEFAULT_MAX_BATCHES = 256;
    /// Hard ceiling on (mesh, material, lod) batches per frame. The batch
    /// table doubles on demand up to this size; past it draws are dropped and
    /// counted in `RenderStats.droppedDraws`.
    enum uint MAX_BATCHES_HARD = 1u << 16;
    /// Initial instance capacity; a batch's buffer doubles when exceeded.
    private enum INITIAL_INSTANCES_PER_BATCH = 512;

    /// One (mesh, material, lod) draw list. `instances` is malloc-backed and
    /// keeps its capacity across frames, so steady-state submission never
    /// allocates. All-zero bytes are a valid empty batch (see `reserveBatches`);
    /// `instanceBuf` is created on first upload.
    private struct Batch {
        TexMesh*     mesh;
        SkinnedMesh* skinnedMesh;
        Material*    material;
        ubyte        lod;
        PodBuffer!TexInstanceData instances;
        WGPUBuffer   instanceBuf;
        size_t       capacity;
        bool         uploaded = false;
        /// Culling partition (see `prepareBatch`): color pass draws
        /// `[colorFirst, colorFirst + colorCount)`, the directional shadow
        /// pass `[dirFirst, dirFirst + dirCount)`; point / spot shadows draw all.
        bool         prepared = false;
        uint         colorFirst, colorCount, dirFirst, dirCount;
    }
    private BatchMap batchMap;

    // Concatenated joint palettes for `drawSkinned` batches (@group(3) / shadow @group(1)).
    private PodBuffer!Mat4 skinPaletteStaging;
    private WGPUBuffer skinPaletteBuf;
    private size_t skinPaletteCapacity;
    private WGPUBindGroup skinPaletteBg;
    private bool skinPalettesUploaded = false;
    private bool warnedSkinPaletteOverflow = false;

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
    /// Group 0 for displaced-surface shadow pipelines: frame uniforms + light VP.
    private WGPUBindGroup shadowSurfaceBg;
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
        WGPURenderPipeline pipelineSkinned;
    }
    private enum MAX_VARIANTS = 64;
    private PipelineVariant[MAX_VARIANTS] variants;
    private uint variantCount = 0;

    private enum MAX_SURFACE_SHADERS = 16;
    private SurfacePipelines[MAX_SURFACE_SHADERS] surfaceShaders;
    private uint surfaceShaderCount = 0;

    /// malloc-backed batch table (see `reserveBatches`); `length` is the
    /// capacity, `batchCount` the batches used this frame.
    private Batch[] batches;
    private PodBuffer!uint sortOrder;
    private PodBuffer!float sortFarthest;
    private uint batchCount = 0;
    private uint batchPeak = 0;
    private uint batchGrowths = 0;
    private ulong droppedDrawsTotal = 0;

    // Automatic LOD inputs, captured in `begin`.
    private Vec3 lodCameraPos;
    private float lodFovY = 0.9f;
    private float lodScreenHeight = 1080.0f;
    private float lodBias = 1.0f;

    // Last views bound into `frameBindGroup`; rebuild only when one changes.
    private WGPUSampler boundShadowSampler;
    private WGPUTextureView[7] boundShadowViews;
    private WGPUTextureView defaultShadowArrayView;
    private WGPUTexture defaultSceneColorTex;
    private WGPUTextureView defaultSceneColorView;
    private WGPUTextureView boundSceneColorView;
    private WGPUTextureView boundSceneDepthView;

    // Camera captured in `begin` (cascade fitting).
    private Camera frameCamera;
    // Cascades fitted by the automatic `renderShadows(frame, lights)` path;
    // consumed by `setLightsImpl` when `cascadesPending` is set.
    private CascadeSet cascadeSet;
    private bool cascadesPending = false;
    private bool debugCascades = false;

    // Engine sky (lazily created by `setSkyEnabled`).
    private SkyRenderer sky;
    private bool skyEnabled = false;

    // Extra shadow casters (terrain, …) drawn into every directional view.
    private enum MAX_SHADOW_HOOKS = 4;
    private ShadowCasterHook[MAX_SHADOW_HOOKS] shadowHooks;
    private uint shadowHookCount = 0;
    private OpaqueDrawHook[MAX_SHADOW_HOOKS] opaqueHooks;
    private uint opaqueHookCount = 0;
    private OpaqueDrawHook[MAX_SHADOW_HOOKS] postOpaqueHooks;
    private uint postOpaqueHookCount = 0;
    private OpaqueDrawHook[MAX_SHADOW_HOOKS] transparentHooks;
    private uint transparentHookCount = 0;

    @disable this(this);

    /// `createIbl = false` skips the procedural sky + IBL prefilter (~1 s in debug builds) and
    /// starts with a cheap flat-grey environment instead. Use it for scenes that bind their own
    /// environment right after creation (`setEnvironment` / `setEnvironmentBindGroup`, e.g. a
    /// second scene for unlit particle pools sharing the main scene's `DynamicIbl`).
    ///
    /// `maxBatches` is the initial capacity of the (mesh, material, lod) batch
    /// table. The table doubles on demand (up to `MAX_BATCHES_HARD`), so a low
    /// value costs a reallocation, never dropped draws; see `batchStats`.
    static Scene3DTextured create(ref GpuContext gpu, uint maxBatches = DEFAULT_MAX_BATCHES,
                                  bool createIbl = true) @trusted {
        if (maxBatches == 0) maxBatches = DEFAULT_MAX_BATCHES;
        Scene3DTextured s;
        s.device = gpu.getDevice();
        s.queue = gpu.getQueue();
        auto device = s.device;

        s.pipeline = createTexturedPipeline3D(device, Renderer.sceneFormat());
        s.frameUniformBuf = createUniformBuffer(device, FRAME_UNIFORMS_SIZE);
        s.pointLightBufCap = INITIAL_POINT_LIGHT_CAP;
        s.spotLightBufCap = INITIAL_SPOT_LIGHT_CAP;
        s.pointLightsBuf = createStorageBuffer(device, s.pointLightBufCap * GpuPointLightUbo.sizeof);
        s.spotLightsBuf = createStorageBuffer(device, s.spotLightBufCap * GpuSpotLightUbo.sizeof);
        s.pointLightsStaging.reserve(INITIAL_POINT_LIGHT_CAP);
        s.spotLightsStaging.reserve(INITIAL_SPOT_LIGHT_CAP);
        {
            GpuPointLightUbo[1] zeroP;
            updateBuffer(s.queue, s.pointLightsBuf, zeroP[]);
            GpuSpotLightUbo[1] zeroS;
            updateBuffer(s.queue, s.spotLightsBuf, zeroS[]);
        }
        s.waterDataBuf = createStorageBuffer(device, WATER_DATA_SIZE);
        GpuWaterData noWater;
        updateBuffer(s.queue, s.waterDataBuf, &noWater, WATER_DATA_SIZE);
        s.clusterCuller = ClusteredLightCuller.create(device, s.queue);

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
            s.defaultShadow2dView, s.defaultShadow2dView,
            s.defaultSceneColorView, s.defaultShadow2dView);

        s.ownedIbl = createIbl
            ? IblEnvironment.create(gpu, s.pipeline.iblBindGroupLayout)
            : IblEnvironment.createSolid(gpu, s.pipeline.iblBindGroupLayout, [0.25f, 0.25f, 0.25f], [0.25f, 0.25f, 0.25f]);
        s.iblBindGroup = s.ownedIbl.bindGroup;
        s.ownsIbl = true;

        s.reserveBatches(maxBatches < MAX_BATCHES_HARD ? maxBatches : MAX_BATCHES_HARD);
        s.skinPaletteCapacity = INITIAL_SKIN_PALETTE_MATRICES;
        s.skinPaletteBuf = createStorageBuffer(device, s.skinPaletteCapacity * Mat4.sizeof);
        s.rebuildSkinPaletteBindGroup();
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
    ///
    /// Instead of `displace` the snippet may define
    /// `fn displaceEx(d: DisplaceIn) -> vec3<f32>` to also receive the
    /// instance `custom` vec4, the instance translation / scale and the mesh
    /// UV. Either hook also runs in the shadow passes (cascades, point and
    /// spot), with the same `surfaceParams` and `frame.time`, so cast shadows
    /// follow the animated geometry.
    uint createSurfaceShader(scope const(char)[] surfaceWgsl) @trusted {
        import engine.gpu.shaders : composeSurfaceShader, surfaceDisplaceKind;
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
        built.displace = surfaceDisplaceKind(surfaceWgsl);
        surfaceShaders[surfaceShaderCount] = built;
        return ++surfaceShaderCount;
    }

    /// Recompile an existing surface shader in place (hot reload). The old
    /// pipelines stay active when the new source fails.
    bool reloadSurfaceShader(uint id, scope const(char)[] surfaceWgsl) @trusted {
        import engine.gpu.shaders : composeSurfaceShader, surfaceDisplaceKind;
        if (id == 0 || id > surfaceShaderCount) return false;
        auto built = createSurfacePipelines(pipeline, device, Renderer.sceneFormat(),
            composeSurfaceShader(surfaceWgsl, false), composeSurfaceShader(surfaceWgsl, true));
        if (!built.valid) return false;
        built.displace = surfaceDisplaceKind(surfaceWgsl);
        surfaceShaders[id - 1].release();
        surfaceShaders[id - 1] = built;
        releaseVariants(id);
        return true;
    }

    /// Seconds exposed to shaders as `frame.time`; call before `begin`.
    void setTime(float seconds) nothrow @nogc { frameData.time = seconds; }

    /// Upload the shared water data (frame binding 10): water bodies with
    /// their levels, bounds and wave sets, read by the water surface, the
    /// PBR wetline and caustics. `engine.water.WaterRenderer` calls this;
    /// scenes without water keep the default (no bodies). Wave animation
    /// uses the frame time (`setTime`).
    void setWaterData(ref const GpuWaterData data) nothrow @nogc @trusted {
        updateBuffer(queue, waterDataBuf, &data, WATER_DATA_SIZE);
    }

    /// Global multiplier for IBL diffuse/specular/coat/fuzz ambient lighting.
    void setIblIntensity(float intensity) nothrow @nogc {
        frameData.iblIntensity = intensity < 0.0f ? 0.0f : intensity;
    }

    /// Atmospheric height fog applied in linear HDR by the PBR, water,
    /// terrain and decal shaders. Call before `begin` (uploaded there).
    void setFog(ref const FogSettings fog) nothrow @nogc {
        packFog(fog, frameData.fogColorDensity, frameData.fogHeight, frameData.fogSun);
    }

    /// Enable or disable Clustered Forward GPU compute culling (true by default).
    void setClusteredCulling(bool enabled) nothrow @nogc {
        clusteredEnabled = enabled;
        frameData.clusteredFlags = enabled ? 1u : 0u;
    }

    bool clusteredCullingEnabled() const nothrow @nogc { return clusteredEnabled; }

    /// Append an extra unshadowed point light for this frame after `setLights`/`renderShadows`
    /// and before `end`. Zero stack bloat and zero GC allocation.
    void addPointLight(GpuPointLight pl) nothrow @nogc {
        if (pointLightsStaging.length >= MAX_POINT_LIGHTS) return;
        GpuPointLightUbo gpu;
        gpu.position = [pl.position.x, pl.position.y, pl.position.z];
        gpu.range = pl.range;
        gpu.color = [pl.color.x, pl.color.y, pl.color.z];
        gpu.intensity = pl.intensity;
        gpu.attenuation = pl.attenuation;
        gpu.shadowSlot = -1;
        pointLightsStaging.put(gpu);
        frameData.pointCount = cast(uint) pointLightsStaging.length;
        localLightsDirty = true;
    }

    /// Append an extra unshadowed spot light for this frame after `setLights`/`renderShadows`
    /// and before `end`. Zero stack bloat and zero GC allocation.
    void addSpotLight(GpuSpotLight sl) nothrow @nogc {
        if (spotLightsStaging.length >= MAX_SPOT_LIGHTS) return;
        spotLightsStaging.put(packSpotLightUbo(sl, -1));
        frameData.spotCount = cast(uint) spotLightsStaging.length;
        localLightsDirty = true;
    }

    private static GpuSpotLightUbo packSpotLightUbo(ref const GpuSpotLight sl, int shadowSlot) pure nothrow @nogc {
        immutable dir = sl.direction.normalized();
        immutable innerRad = sl.innerConeDeg * (PI / 180.0f);
        immutable outerRad = sl.outerConeDeg * (PI / 180.0f);
        GpuSpotLightUbo u;
        u.position = [sl.position.x, sl.position.y, sl.position.z];
        u.range = sl.range;
        u.direction = [dir.x, dir.y, dir.z];
        u.intensity = sl.intensity;
        u.attenuation = sl.attenuation;
        u.angleAttenuation = sl.angleAttenuation;
        u.color = [sl.color.x, sl.color.y, sl.color.z];
        u.innerConeCos = cos(innerRad);
        u.outerConeCos = cos(outerRad);
        u.viewProj = sl.viewProj.m;
        u.shadowSlot = shadowSlot;
        return u;
    }

    private void ensureLocalLightStorageUploaded() @trusted {
        bool rebuiltBuf = false;
        if (pointLightsStaging.length > pointLightBufCap) {
            uint newCap = pointLightBufCap > 0 ? pointLightBufCap : INITIAL_POINT_LIGHT_CAP;
            while (newCap < pointLightsStaging.length && newCap < MAX_POINT_LIGHTS)
                newCap *= 2;
            if (newCap > MAX_POINT_LIGHTS) newCap = MAX_POINT_LIGHTS;
            destroyBuffer(pointLightsBuf);
            pointLightBufCap = newCap;
            pointLightsBuf = createStorageBuffer(device, pointLightBufCap * GpuPointLightUbo.sizeof);
            lightBufGen++;
            rebuiltBuf = true;
        }
        if (pointLightsStaging.length > 0) {
            updateBuffer(queue, pointLightsBuf, pointLightsStaging[]);
        }

        if (spotLightsStaging.length > spotLightBufCap) {
            uint newCap = spotLightBufCap > 0 ? spotLightBufCap : INITIAL_SPOT_LIGHT_CAP;
            while (newCap < spotLightsStaging.length && newCap < MAX_SPOT_LIGHTS)
                newCap *= 2;
            if (newCap > MAX_SPOT_LIGHTS) newCap = MAX_SPOT_LIGHTS;
            destroyBuffer(spotLightsBuf);
            spotLightBufCap = newCap;
            spotLightsBuf = createStorageBuffer(device, spotLightBufCap * GpuSpotLightUbo.sizeof);
            lightBufGen++;
            rebuiltBuf = true;
        }
        if (spotLightsStaging.length > 0) {
            updateBuffer(queue, spotLightsBuf, spotLightsStaging[]);
        }
        localLightsDirty = false;
        if (rebuiltBuf && frameBindGroup !is null) {
            rebuildFrameBindGroup(
                boundShadowSampler,
                boundShadowViews[0],
                boundShadowViews[1], boundShadowViews[2],
                boundShadowViews[3], boundShadowViews[4],
                boundShadowViews[5], boundShadowViews[6],
                boundSceneColorView, boundSceneDepthView);
        }
    }

    /// Update multi-light UBO + storage + bind shadow maps for the next draws.
    void setLights(ref const LightSet lights,
                   scope ShadowMap* dirShadow,
                   scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                   scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows) @trusted {
        cascadesPending = false;
        setLightsSlices(lights.dir, lights.dirEnabled, lights.shadowBias,
            lights.points[0 .. (lights.pointCount < lights.points.length ? lights.pointCount : lights.points.length)],
            lights.spots[0 .. (lights.spotCount < lights.spots.length ? lights.spotCount : lights.spots.length)],
            dirShadow, pointShadows, spotShadows);
    }

    /// `LightList` overload supporting up to `MAX_POINT_LIGHTS` / `MAX_SPOT_LIGHTS`.
    void setLights(ref const LightList lights,
                   scope ShadowMap* dirShadow,
                   scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                   scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows) @trusted {
        cascadesPending = false;
        setLightsSlices(lights.dir, lights.dirEnabled, lights.shadowBias,
            lights.points[], lights.spots[],
            dirShadow, pointShadows, spotShadows);
    }

    private void setLightsSlices(
        ref const GpuDirLight dirLight,
        bool dirEnabled,
        float shadowBias,
        scope const(GpuPointLight)[] points,
        scope const(GpuSpotLight)[] spots,
        scope ShadowMap* dirShadow,
        scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
        scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows) @trusted
    {
        frameData.shadowBias = shadowBias;
        frameData.dirEnabled = dirEnabled ? 1 : 0;
        debugCascades = dirLight.debugCascades;
        if (debugCascades) frameData.debugFlags |= 1u;
        else frameData.debugFlags &= ~1u;

        if (dirEnabled) {
            immutable d = dirLight.direction.normalized();
            frameData.dirLight.direction = [d.x, d.y, d.z];
            frameData.dirLight.color = [
                dirLight.color.x, dirLight.color.y, dirLight.color.z
            ];
            frameData.dirLight.intensity = dirLight.intensity;
            frameData.dirLight.viewProj = dirLight.viewProj.m;
            immutable wantDirShadow = dirLight.castShadows && dirShadow !is null;
            frameData.dirLight.castShadows = wantDirShadow ? 1 : 0;
            if (dirLight.castShadows && dirShadow is null)
                warn("Directional castShadows requested but no ShadowMap provided");
        }
        applyCascadeUniforms(cascadesPending && dirShadow !is null);

        immutable uint pc = points.length > MAX_POINT_LIGHTS
            ? MAX_POINT_LIGHTS : cast(uint) points.length;
        if (points.length > MAX_POINT_LIGHTS)
            warn("Point light buffer overflow: ", points.length, " > ", MAX_POINT_LIGHTS);
        frameData.pointCount = pc;
        pointLightsStaging.clear();

        WGPUTextureView[MAX_POINT_SHADOW_CASTERS] boundPoints = [
            defaultShadowCubeView, defaultShadowCubeView,
            defaultShadowCubeView, defaultShadowCubeView,
        ];
        uint pointShadowUsed = 0;
        foreach (i; 0 .. pc) {
            immutable pl = points[i];
            GpuPointLightUbo gpu;
            gpu.position = [pl.position.x, pl.position.y, pl.position.z];
            gpu.range = pl.range;
            gpu.color = [pl.color.x, pl.color.y, pl.color.z];
            gpu.intensity = pl.intensity;
            gpu.attenuation = pl.attenuation;
            gpu.shadowSlot = -1;
            if (pl.castShadows) {
                if (pointShadowUsed >= MAX_POINT_SHADOW_CASTERS
                    || pointShadows[pointShadowUsed] is null) {
                    warn("Point shadow caster budget exceeded (MAX_POINT_SHADOW_CASTERS=",
                         MAX_POINT_SHADOW_CASTERS, "); light ", i, " stays unshadowed");
                } else {
                    gpu.shadowSlot = cast(int) pointShadowUsed;
                    boundPoints[pointShadowUsed] = pointShadows[pointShadowUsed].cubeView;
                    pointShadowUsed++;
                }
            }
            pointLightsStaging.put(gpu);
        }

        immutable uint sc = spots.length > MAX_SPOT_LIGHTS
            ? MAX_SPOT_LIGHTS : cast(uint) spots.length;
        if (spots.length > MAX_SPOT_LIGHTS)
            warn("Spot light buffer overflow: ", spots.length, " > ", MAX_SPOT_LIGHTS);
        frameData.spotCount = sc;
        spotLightsStaging.clear();

        WGPUTextureView[MAX_SPOT_SHADOW_CASTERS] boundSpots = [
            defaultShadow2dView, defaultShadow2dView,
        ];
        uint spotShadowUsed = 0;
        foreach (i; 0 .. sc) {
            immutable sl = spots[i];
            int sSlot = -1;
            if (sl.castShadows) {
                if (spotShadowUsed >= MAX_SPOT_SHADOW_CASTERS
                    || spotShadows[spotShadowUsed] is null) {
                    warn("Spot shadow caster budget exceeded (MAX_SPOT_SHADOW_CASTERS=",
                         MAX_SPOT_SHADOW_CASTERS, "); light ", i, " stays unshadowed");
                } else {
                    sSlot = cast(int) spotShadowUsed;
                    boundSpots[spotShadowUsed] = spotShadows[spotShadowUsed].depthView;
                    spotShadowUsed++;
                }
            }
            spotLightsStaging.put(packSpotLightUbo(sl, sSlot));
        }

        ensureLocalLightStorageUploaded();

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
            boundSpots[0], boundSpots[1],
            defaultSceneColorView, defaultShadow2dView);
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

    /// Register a renderer drawn inside `end` right after the opaque batches
    /// and static buffers (before the sky and transparent batches) — terrain.
    /// The frame (`@group(0)`) and IBL (`@group(2)`) bind groups are bound;
    /// the hook must re-bind them if it changes pipeline layouts.
    void addOpaqueHook(OpaqueDrawHook hook) nothrow @nogc {
        if (opaqueHookCount >= MAX_SHADOW_HOOKS) {
            warn("Scene3DTextured: opaque hook table full");
            return;
        }
        opaqueHooks[opaqueHookCount++] = hook;
    }

    /// Remove every registered opaque draw hook.
    void clearOpaqueHooks() nothrow @nogc {
        opaqueHookCount = 0;
        postOpaqueHookCount = 0;
        transparentHookCount = 0;
    }

    /// Register a renderer drawn after the sky and before the alpha-blended
    /// batches — refractive surfaces such as water that need the sky in the
    /// opaque snapshot (`Renderer.snapshotOpaque`) and must still sort under
    /// particles and other transparent batches.
    void addTransparentHook(OpaqueDrawHook hook) nothrow @nogc {
        if (transparentHookCount >= MAX_SHADOW_HOOKS) {
            warn("Scene3DTextured: transparent hook table full");
            return;
        }
        transparentHooks[transparentHookCount++] = hook;
    }

    /// Register a renderer drawn after every opaque hook and before the sky
    /// and transparent batches — screen-space decals that read the opaque
    /// depth (they may call `Renderer.snapshotOpaque`, which restarts the
    /// scene pass; the scene re-binds its groups afterwards).
    void addPostOpaqueHook(OpaqueDrawHook hook) nothrow @nogc {
        if (postOpaqueHookCount >= MAX_SHADOW_HOOKS) {
            warn("Scene3DTextured: post-opaque hook table full");
            return;
        }
        postOpaqueHooks[postOpaqueHookCount++] = hook;
    }

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

    /// Bind an IBL bind group built with `iblLayout()` (e.g. `DynamicIbl.bindGroup()`,
    /// which changes when a runtime update completes — set it every frame).
    void setEnvironmentBindGroup(WGPUBindGroup group) nothrow @nogc {
        if (group !is null) iblBindGroup = group;
    }

    /// Draw the engine sky (`assets/shaders/sky.wgsl`) after the opaque
    /// batches in `end`. The sun follows the directional light.
    void setSkyEnabled(bool enabled) @trusted {
        skyEnabled = enabled;
        if (enabled && !sky.valid) sky = SkyRenderer.create(device, pipeline.frameBindGroupLayout);
    }

    /// Night-sky and exposure inputs of the engine sky (call before `begin`).
    /// `moonDir` is surface → moon.
    void setSkyState(Vec3 moonDir, float moonIntensity, float starIntensity,
                     float exposure = 1.0f) nothrow @nogc {
        immutable m = moonDir.normalized();
        frameData.moonDir = [m.x, m.y, m.z, moonIntensity > 0 ? moonIntensity : 0];
        frameData.skyParams[0] = starIntensity > 0 ? starIntensity : 0;
        frameData.skyParams[1] = exposure > 0 ? exposure : 0;
    }

    /// Sun seen by the sky when it differs from the directional light (at
    /// night the directional light is usually the moon). Call before `begin`.
    void setSkySun(Vec3 sunDir, Vec3 sunColor) nothrow @nogc {
        immutable d = sunDir.normalized();
        frameData.skySunDir = [d.x, d.y, d.z, 1];
        frameData.skySunColor = [sunColor.x, sunColor.y, sunColor.z, 0];
    }

    /// Make the sky follow the directional light again.
    void clearSkySun() nothrow @nogc { frameData.skySunDir[3] = 0; }

    /// Configure Screen-Space Reflections (`OPBR-9`) for materials with `MaterialFlags.ssr`.
    void setSsr(bool enabled, float maxDistance = 16.0f, float thickness = 0.35f, float intensity = 1.0f) nothrow @nogc {
        frameData.ssrParams = [
            enabled ? 1.0f : 0.0f,
            maxDistance > 1.0f ? maxDistance : 1.0f,
            thickness > 0.01f ? thickness : 0.01f,
            intensity > 0.0f ? intensity : 0.0f,
        ];
    }

    /// Upload up to `MAX_REFLECTION_PROBES` parallax-corrected local reflection probes (`OPBR-9`).
    void setReflectionProbes(scope const(ReflectionProbe)[] probes) nothrow @nogc {
        uint count = 0;
        foreach (ref const p; probes) {
            if (count >= MAX_REFLECTION_PROBES) break;
            if (p.enabled == 0 || p.intensity <= 0.0f) continue;
            immutable float rad = p.radius > 0.01f ? p.radius : 0.01f;
            auto gpu = &frameData.probes[count];
            gpu.posRadius = [p.position.x, p.position.y, p.position.z, p.boxProjection != 0 ? rad : -rad];
            gpu.boxBlend = [
                p.boxExtents.x > 0.01f ? p.boxExtents.x : 0.01f,
                p.boxExtents.y > 0.01f ? p.boxExtents.y : 0.01f,
                p.boxExtents.z > 0.01f ? p.boxExtents.z : 0.01f,
                p.blendDistance > 0.001f ? p.blendDistance : 0.001f,
            ];
            gpu.tintIntensity = [p.tint[0], p.tint[1], p.tint[2], p.intensity];
            count++;
        }
        frameData.probeCount = count;
    }

    /// Weather inputs (call before `begin`): `wetness` darkens and glosses
    /// rain-exposed surfaces (instances with `custom.w = 1` are sheltered),
    /// `rain` scales rain effects, `clouds` drives sky cloud coverage. All 0..1.
    void setWeather(float wetness, float rain, float clouds) nothrow @nogc {
        static float sat(float v) pure nothrow @nogc { return v < 0 ? 0 : (v > 1 ? 1 : v); }
        frameData.globalWetness = sat(wetness);
        frameData.rainIntensity = sat(rain);
        frameData.cloudCoverage = sat(clouds);
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

    /// Batch-table occupancy: this frame's batches, the peak since `create`,
    /// the current capacity, growth count and total dropped draws.
    BatchStats batchStats() const nothrow @nogc {
        return BatchStats(batchCount, batchPeak, cast(uint) batches.length,
                          batchGrowths, droppedDrawsTotal);
    }

    /// Camera frustum of the current frame (valid after `begin`).
    ref const(Frustum) frustum() const return nothrow @nogc { return cameraFrustum; }

    void begin(ref const Camera camera) @trusted {
        auto zBegin = profileZone!"scene.begin"();
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
        frameData.viewportRect = [0.0f, 0.0f, frameData.viewportSize[0], frameData.viewportSize[1]];
        frameData.clusterZParams = computeClusterZParams(camera.near, camera.far);
        frameData.clusteredFlags = clusteredEnabled ? 1u : 0u;
        updateBuffer(queue, frameUniformBuf, (&frameData)[0 .. 1]);

        batchCount = 0;
        batchMap.reset();
        staticCount = 0;
        skinPaletteStaging.clear();
        skinPalettesUploaded = false;
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
        immutable pc = lights.pointCount < lights.points.length ? lights.pointCount : cast(uint) lights.points.length;
        immutable sc = lights.spotCount < lights.spots.length ? lights.spotCount : cast(uint) lights.spots.length;
        renderShadowsAuto(frame, lights.dir, lights.dirEnabled, lights.shadowBias,
            lights.points[0 .. pc], lights.spots[0 .. sc]);
    }

    /// `LightList` overload scaling shadows + clustered active lights up to `MAX_POINT_LIGHTS`/`MAX_SPOT_LIGHTS`.
    void renderShadows(ref FrameContext frame, ref const LightList lights) @trusted {
        renderShadowsAuto(frame, lights.dir, lights.dirEnabled, lights.shadowBias,
            lights.points[], lights.spots[]);
    }

    private void renderShadowsAuto(ref FrameContext frame,
                                   ref const GpuDirLight dirLight,
                                   bool dirEnabled,
                                   float shadowBias,
                                   scope const(GpuPointLight)[] points,
                                   scope const(GpuSpotLight)[] spots) @trusted {
        ShadowMap* dirPtr = null;
        bool cascaded = false;
        if (dirEnabled && dirLight.castShadows) {
            immutable cs = dirLight.cascades;
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
                cascadeSet = buildCascades(frameCamera, dirLight.direction, cs);
                cascadeBlend = cs.blendFraction;
            }
        }

        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointPtrs;
        uint pUsed = 0;
        immutable uint pc = points.length > MAX_POINT_LIGHTS ? MAX_POINT_LIGHTS : cast(uint) points.length;
        foreach (i; 0 .. pc) {
            if (!points[i].castShadows) continue;
            if (pUsed >= MAX_POINT_SHADOW_CASTERS) break;
            if (!hasOwnedPointShadow[pUsed]) {
                immutable farP = points[i].range > LIGHT_SHADOW_NEAR ? points[i].range : 25.0f;
                ownedPointShadows[pUsed] = PointShadowMap.createForDevice(
                    device, POINT_SHADOW_RESOLUTION, LIGHT_SHADOW_NEAR, farP);
                hasOwnedPointShadow[pUsed] = true;
            } else if (points[i].range > LIGHT_SHADOW_NEAR) {
                ownedPointShadows[pUsed].farPlane = points[i].range;
            }
            pointPtrs[pUsed] = &ownedPointShadows[pUsed];
            pUsed++;
        }

        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotPtrs;
        uint sUsed = 0;
        immutable uint sc = spots.length > MAX_SPOT_LIGHTS ? MAX_SPOT_LIGHTS : cast(uint) spots.length;
        foreach (i; 0 .. sc) {
            if (!spots[i].castShadows) continue;
            if (sUsed >= MAX_SPOT_SHADOW_CASTERS) break;
            if (!hasOwnedSpotShadow[sUsed]) {
                ownedSpotShadows[sUsed] = SpotShadowMap.createForDevice(device, SPOT_SHADOW_RESOLUTION);
                hasOwnedSpotShadow[sUsed] = true;
            }
            spotPtrs[sUsed] = &ownedSpotShadows[sUsed];
            sUsed++;
        }

        renderShadowsImpl(frame, dirLight, dirEnabled, shadowBias, points, spots,
            dirPtr, pointPtrs, spotPtrs, cascaded);
    }

    /// Automatic batch shadow rendering using caller-provided shadow maps.
    /// The directional map is rendered as one fixed view (`lights.dir.viewProj`).
    void renderShadows(ref FrameContext frame,
                       ref const LightSet lights,
                       scope ShadowMap* dirShadow,
                       scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                       scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows) @trusted {
        immutable pc = lights.pointCount < lights.points.length ? lights.pointCount : cast(uint) lights.points.length;
        immutable sc = lights.spotCount < lights.spots.length ? lights.spotCount : cast(uint) lights.spots.length;
        renderShadowsImpl(frame, lights.dir, lights.dirEnabled, lights.shadowBias,
            lights.points[0 .. pc], lights.spots[0 .. sc],
            dirShadow, pointShadows, spotShadows, false);
    }

    private static Mat4 resolvedSpotVP(ref const GpuSpotLight sl) {
        if (!sl.castShadows || sl.viewProj.m != Mat4.init.m)
            return sl.viewProj;
        immutable farP = sl.range > LIGHT_SHADOW_NEAR ? sl.range : 25.0f;
        return spotLightVPFromCone(sl.position, sl.direction, sl.outerConeDeg, LIGHT_SHADOW_NEAR, farP);
    }

    private void renderShadowsImpl(ref FrameContext frame,
                       ref const GpuDirLight dirLight,
                       bool dirEnabled,
                       float shadowBias,
                       scope const(GpuPointLight)[] points,
                       scope const(GpuSpotLight)[] spots,
                       scope ShadowMap* dirShadow,
                       scope PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointShadows,
                       scope SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotShadows,
                       bool cascaded) @trusted {
        if (!frame.valid || frame.postResolved) return;
        auto zShadows = profileZone!"scene.shadows"();
        auto zLights = profileZone!"scene.shadows.lights"();

        cascadesPending = cascaded && dirShadow !is null;
        setLightsSlices(dirLight, dirEnabled, shadowBias, points, spots, dirShadow, pointShadows, spotShadows);
        // Resolve spot projection matrices for shadow-casting spots without copying large arrays.
        bool fixedSpotVp = false;
        foreach (i; 0 .. frameData.spotCount) {
            if (!spots[i].castShadows) continue;
            immutable vp = resolvedSpotVP(spots[i]);
            if (vp.m != spotLightsStaging[i].viewProj) {
                spotLightsStaging[i].viewProj = vp.m;
                fixedSpotVp = true;
            }
        }
        if (fixedSpotVp && frameData.spotCount > 0) {
            updateBuffer(queue, spotLightsBuf, spotLightsStaging[]);
        }
        updateBuffer(queue, frameUniformBuf, (&frameData)[0 .. 1]);
        immutable uint cascadeCount = cascadesPending ? cascadeSet.count : 0;

        bool anyCast = (dirEnabled && dirLight.castShadows && dirShadow !is null);
        if (!anyCast) {
            foreach (i; 0 .. frameData.pointCount) {
                if (pointLightsStaging[i].shadowSlot >= 0) { anyCast = true; break; }
            }
        }
        if (!anyCast) {
            foreach (i; 0 .. frameData.spotCount) {
                if (spotLightsStaging[i].shadowSlot >= 0) { anyCast = true; break; }
            }
        }
        if (!anyCast) return;
        zLights.close();
        auto zPrepare = profileZone!"scene.shadows.prepare"();

        ensureShadowResources();

        // Fixed directional map: cull casters through the batch partition.
        // Cascades cull per view through the caster lists, like point / spot views.
        Frustum dirFrustum;
        immutable bool cullDir = dirEnabled && dirLight.castShadows && dirShadow !is null
            && cascadeCount == 0;
        if (cullDir)
            dirFrustum = Frustum.fromViewProj(dirLight.viewProj);
        uint casterBatches = 0;
        foreach (ref b; batches[0 .. batchCount]) {
            if (b.instances.length == 0 || !b.material.renderState.depthWrite) continue;
            prepareBatch(b, cullDir ? &dirFrustum : null);
            ensureBatchUploaded(b);
            casterBatches++;
        }

        zPrepare.close();
        auto zUpload = profileZone!"scene.shadows.upload"();
        // Pack all light VP matrices into aligned 256-byte dynamic-offset slots.
        import core.stdc.string : memcpy;
        void storeVp(uint slot, ref const float[16] m) {
            memcpy(shadowVpStaging.ptr + slot * SHADOW_VP_STRIDE, m.ptr, 64);
        }

        uint maxSlotUsed = 0;
        if (cascadeCount > 0) {
            foreach (c; 0 .. cascadeCount) storeVp(c, cascadeSet.viewProj[c].m);
            maxSlotUsed = cascadeCount;
        } else if (dirEnabled && dirLight.castShadows && dirShadow !is null) {
            storeVp(0, dirLight.viewProj.m);
            maxSlotUsed = 1;
        }
        foreach (i; 0 .. frameData.pointCount) {
            immutable int slot = pointLightsStaging[i].shadowSlot;
            if (slot < 0 || slot >= cast(int) MAX_POINT_SHADOW_CASTERS || pointShadows[slot] is null) continue;
            immutable vps = pointLightFaceVPs(
                points[i].position,
                pointShadows[slot].nearPlane,
                pointShadows[slot].farPlane);
            foreach (face; 0 .. 6) {
                immutable uSlot = DIR_SLOTS + cast(uint) slot * 6 + face;
                storeVp(uSlot, vps[face].m);
                if (uSlot + 1 > maxSlotUsed) maxSlotUsed = uSlot + 1;
            }
        }
        foreach (i; 0 .. frameData.spotCount) {
            immutable int slot = spotLightsStaging[i].shadowSlot;
            if (slot < 0 || slot >= cast(int) MAX_SPOT_SHADOW_CASTERS || spotShadows[slot] is null) continue;
            immutable uSlot = DIR_SLOTS + MAX_POINT_SHADOW_CASTERS * 6 + cast(uint) slot;
            storeVp(uSlot, spotLightsStaging[i].viewProj);
            if (uSlot + 1 > maxSlotUsed) maxSlotUsed = uSlot + 1;
        }

        if (maxSlotUsed == 0) return;
        wgpuQueueWriteBuffer(queue, shadowVpBuf, 0, shadowVpStaging.ptr, maxSlotUsed * SHADOW_VP_STRIDE);
        ensureSkinPalettesUploaded();

        zUpload.close();
        auto zCasters = profileZone!"scene.shadows.casters"();
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
                immutable int slot = pointLightsStaging[i].shadowSlot;
                if (slot < 0 || slot >= cast(int) MAX_POINT_SHADOW_CASTERS || pointShadows[slot] is null) continue;
                uint[6] slots;
                foreach (face; 0 .. 6) slots[face] = DIR_SLOTS + cast(uint) slot * 6 + face;
                gatherLocalCasters(slots[], points[i].position, pointShadows[slot].farPlane);
            }
            foreach (i; 0 .. frameData.spotCount) {
                immutable int slot = spotLightsStaging[i].shadowSlot;
                if (slot < 0 || slot >= cast(int) MAX_SPOT_SHADOW_CASTERS || spotShadows[slot] is null) continue;
                uint[1] slots = [DIR_SLOTS + MAX_POINT_SHADOW_CASTERS * 6 + cast(uint) slot];
                gatherLocalCasters(slots[], spots[i].position, spots[i].range);
            }
            uploadCasterStaging();
        }

        zCasters.close();
        auto zEncode = profileZone!"scene.shadows.encode"();
        frame.suspendScenePass();
        scope(exit) frame.resumeScenePass();
        auto gShadows = gpuScope!"gpu.shadows"(frame.encoder); // ends before the resume (LIFO)

        immutable bool anyGeometry = casterBatches > 0 || staticCount > 0;
        if (cascadeCount > 0) {
            auto g = gpuScope!"gpu.shadows.cascades"(frame.encoder);
            foreach (c; 0 .. cascadeCount)
                encodeShadowView(frame.encoder, dirShadow.layerViews[c], c, anyGeometry,
                                 ShadowViewKind.cascade);
        } else if (dirEnabled && dirLight.castShadows && dirShadow !is null) {
            auto g = gpuScope!"gpu.shadows.directional"(frame.encoder);
            encodeShadowView(frame.encoder, dirShadow.depthView, 0, anyGeometry, ShadowViewKind.fixedDir);
        }
        auto gPoints = gpuScope!"gpu.shadows.points"(frame.encoder);
        foreach (i; 0 .. frameData.pointCount) {
            immutable int slot = pointLightsStaging[i].shadowSlot;
            if (slot < 0 || slot >= cast(int) MAX_POINT_SHADOW_CASTERS || pointShadows[slot] is null) continue;
            foreach (face; 0 .. 6) {
                encodeShadowView(
                    frame.encoder,
                    pointShadows[slot].faceViews[face],
                    DIR_SLOTS + cast(uint) slot * 6 + face,
                    anyGeometry, ShadowViewKind.local);
            }
        }
        gPoints.close();
        auto gSpots = gpuScope!"gpu.shadows.spots"(frame.encoder);
        foreach (i; 0 .. frameData.spotCount) {
            immutable int slot = spotLightsStaging[i].shadowSlot;
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
        immutable sc = resolved.spotCount < resolved.spots.length
            ? resolved.spotCount : cast(uint) resolved.spots.length;
        foreach (i; 0 .. sc) {
            resolved.spots[i].viewProj = resolvedSpotVP(resolved.spots[i]);
        }
        return resolved;
    }

    private void ensureShadowResources() @trusted {
        if (shadowPipeReady) return;
        shadowPipe = createTexShadowPipeline(device, pipeline.skinBindGroupLayout, pipeline.bindGroupLayout);
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

        WGPUBindGroupEntry[2] sbe;
        sbe[0].binding = 0;
        sbe[0].buffer  = frameUniformBuf;
        sbe[0].size    = FRAME_UNIFORMS_SIZE;
        sbe[1].binding = SURFACE_SHADOW_LIGHT_BINDING;
        sbe[1].buffer  = shadowVpBuf;
        sbe[1].size    = 64;
        WGPUBindGroupDescriptor sbd;
        sbd.layout     = shadowPipe.surfaceBindGroupLayout;
        sbd.entryCount = 2;
        sbd.entries    = sbe.ptr;
        shadowSurfaceBg = wgpuDeviceCreateBindGroup(device, &sbd);
        if (shadowSurfaceBg is null) fatal("Failed to create scene shadow surface bind group");
        shadowPipeReady = true;
    }

    /// Depth-only pipeline running the surface shader's `displace` hook, or
    /// null when the material has no hook (use the stock shadow pipeline).
    /// Built on first use and cached in the surface shader entry.
    private WGPURenderPipeline displacedShadowPipeline(uint shaderId, uint vertexStride,
                                                       bool doubleSided) nothrow @nogc @trusted {
        if (shaderId == 0 || shaderId > surfaceShaderCount) return null;
        auto custom = &surfaceShaders[shaderId - 1];
        if (custom.displace == DisplaceKind.none) return null;
        immutable tangent = vertexStride == 48;
        immutable idx = (tangent ? 2u : 0u) + (doubleSided ? 1u : 0u);
        if (custom.shadowPipelines[idx] is null) {
            custom.shadowPipelines[idx] = createSurfaceShadowPipeline(
                device, shadowPipe.surfacePipelineLayout, tangent ? custom.shaderModuleTangent : custom.shaderModule,
                tangent ? 48 : 32, doubleSided);
            if (custom.shadowPipelines[idx] is null) return null;
        }
        return custom.shadowPipelines[idx];
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
            bool groupZeroIsSurface = false;
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
                if (b.skinnedMesh !is null) {
                    if (groupZeroIsSurface) {
                        wgpuRenderPassEncoderSetBindGroup(pass, 0, shadowVpBg, 1, &dynOffset);
                        groupZeroIsSurface = false;
                    }
                    auto p = shadowPipe.skinnedPipelineFor(b.material.renderState.doubleSided);
                    wgpuRenderPassEncoderSetPipeline(pass, p);
                    wgpuRenderPassEncoderSetBindGroup(pass, 1, skinPaletteBg, 0, null);
                    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, b.skinnedMesh.vertexBuffer, 0, b.skinnedMesh.vertexBufSize);
                    wgpuRenderPassEncoderSetVertexBuffer(pass, 1, instBuf, 0, instBytes);
                    wgpuRenderPassEncoderSetIndexBuffer(pass, b.skinnedMesh.indexBuffer, b.skinnedMesh.indexFormat, 0, b.skinnedMesh.indexBufSize);
                    wgpuRenderPassEncoderDrawIndexed(pass, b.skinnedMesh.indexCount, count, 0, 0, first);
                    frameStats.shadowDrawCalls++;
                    frameStats.shadowInstancesDrawn += count;
                    continue;
                }
                auto p = shadowPipe.pipelineFor(b.mesh.vertexStride, b.material.renderState.doubleSided);
                auto dp = displacedShadowPipeline(b.material.surfaceShader, b.mesh.vertexStride,
                                                  b.material.renderState.doubleSided);
                if (dp !is null) {
                    p = dp;
                    wgpuRenderPassEncoderSetBindGroup(pass, 0, shadowSurfaceBg, 1, &dynOffset);
                    wgpuRenderPassEncoderSetBindGroup(pass, 1, b.material.bindGroup, 0, null);
                    groupZeroIsSurface = true;
                } else if (groupZeroIsSurface) {
                    wgpuRenderPassEncoderSetBindGroup(pass, 0, shadowVpBg, 1, &dynOffset);
                    groupZeroIsSurface = false;
                }
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
            if (groupZeroIsSurface) {
                wgpuRenderPassEncoderSetBindGroup(pass, 0, shadowVpBg, 1, &dynOffset);
                groupZeroIsSurface = false;
            }
            if (staticCount > 0) {
                foreach (sib; staticBufs[0 .. staticCount])
                    encodeStaticShadow(pass, *sib, lightFrustum, distanceCull, dynOffset);
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
            immutable bool hasBounds = b.skinnedMesh !is null
                ? b.skinnedMesh.hasBounds : (b.mesh !is null && b.mesh.hasBounds);
            if (!cullingEnabled || !hasBounds) {
                foreach (slot; slots) casterRanges[slot * batchCount + bi] = CasterRange(0, 0, true);
                continue;
            }
            immutable localSphere = b.mesh !is null ? b.mesh.localSphere : BoundingSphere.init;
            gatherLightCasters(b.instances[], localSphere, lightPos, range, views[0 .. slots.length],
                               casterStaging, ranges[0 .. slots.length], casterCandidates, casterSpheres,
                               b.skinnedMesh !is null);
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
                                    ref const Frustum lightFrustum, bool dirView,
                                    uint dynOffset) nothrow @nogc @trusted {
        immutable n = collectStaticRuns(sib, lightFrustum, dirView);
        bool groupZeroIsSurface = false;
        scope(exit) if (groupZeroIsSurface)
            wgpuRenderPassEncoderSetBindGroup(pass, 0, shadowVpBg, 1, &dynOffset);
        foreach (ref run; staticRuns[0 .. n]) {
            auto g = &sib.groups[run.group];
            auto mesh = sib.meshes[g.mesh];
            auto mat = sib.materials[g.material];
            if (!mat.renderState.depthWrite) continue;
            auto p = shadowPipe.pipelineFor(mesh.vertexStride, mat.renderState.doubleSided);
            auto dp = displacedShadowPipeline(mat.surfaceShader, mesh.vertexStride, mat.renderState.doubleSided);
            if (dp !is null) {
                p = dp;
                wgpuRenderPassEncoderSetBindGroup(pass, 0, shadowSurfaceBg, 1, &dynOffset);
                wgpuRenderPassEncoderSetBindGroup(pass, 1, mat.bindGroup, 0, null);
                groupZeroIsSurface = true;
            } else if (groupZeroIsSurface) {
                wgpuRenderPassEncoderSetBindGroup(pass, 0, shadowVpBg, 1, &dynOffset);
                groupZeroIsSurface = false;
            }
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

    /// Draw a GPU-skinned mesh through the full OpenPBR pipeline (IBL, CSM, local lights,
    /// fog, rain wetness, bloom) and shadow passes, instanced per `(SkinnedMesh, Material)`.
    /// `modelPoseSphere` is the character's current model-space bounding sphere
    /// (e.g. from `poseBoundingSphere(pose.model)`), used for frustum/shadow culling.
    void drawSkinned(ref SkinnedMesh mesh, ref Material material, Mat4 model, Color4 tint,
                     scope const(Mat4)[] palette, BoundingSphere modelPoseSphere,
                     float[4] custom = [1.0f, 0.0f, 0.0f, 0.0f]) nothrow @nogc {
        if (!mesh.valid) return;
        auto b = findOrAddSkinned(mesh, material);
        if (b is null) return;

        immutable size_t need = palette.length > 0 ? palette.length : 1;
        uint palOffset = 0;
        if (skinPaletteStaging.length + need <= MAX_SKIN_PALETTE_MATRICES) {
            palOffset = cast(uint) skinPaletteStaging.length;
            if (palette.length > 0) {
                foreach (ref m; palette)
                    skinPaletteStaging.put(m);
            } else {
                skinPaletteStaging.put(Mat4.identity());
            }
        } else if (!warnedSkinPaletteOverflow) {
            warn("Scene3DTextured: skin palette buffer exceeded ", MAX_SKIN_PALETTE_MATRICES, " matrices");
            warnedSkinPaletteOverflow = true;
        }

        immutable ws = modelPoseSphere.transformed(model);
        TexInstanceData inst = TexInstanceData(model.m, tint.toArray(), custom);
        inst.model[3] = packSkinnedOffsetAndRadius(palOffset, ws.radius);
        inst.model[7] = ws.center.x;
        inst.model[11] = ws.center.y;
        inst.model[15] = ws.center.z;
        b.instances.put(inst);
    }

    /// Overload deriving the current pose's bounding sphere from `mesh.localSphere` and `palette`.
    void drawSkinned(ref SkinnedMesh mesh, ref Material material, Mat4 model, Color4 tint,
                     scope const(Mat4)[] palette,
                     float[4] custom = [1.0f, 0.0f, 0.0f, 0.0f]) nothrow @nogc {
        drawSkinned(mesh, material, model, tint, palette,
                    estimatePoseSphereFromPalette(mesh.localSphere, palette), custom);
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
        auto zEnd = profileZone!"scene.end"();
        auto zUniforms = profileZone!"scene.end.uniforms"();

        immutable float[4] vpRect = frame.activeViewportRect();
        frameData.viewportRect = vpRect;
        frameData.clusterZParams = computeClusterZParams(frameCamera.near, frameCamera.far);
        frameData.clusteredFlags = clusteredEnabled ? 1u : 0u;
        if (localLightsDirty) {
            ensureLocalLightStorageUploaded();
        }
        updateBuffer(queue, frameUniformBuf, (&frameData)[0 .. 1]);
        zUniforms.close();

        if (clusteredEnabled && (frameData.pointCount > 0 || frameData.spotCount > 0)) {
            auto zCluster = profileZone!"scene.end.clusterCull"();
            frame.suspendScenePass();
            auto gCluster = gpuScope!"gpu.clusterCull"(frame.encoder);
            clusterCuller.encode(
                frame.encoder, queue,
                pointLightsBuf, pointLightBufCap * GpuPointLightUbo.sizeof,
                spotLightsBuf, spotLightBufCap * GpuSpotLightUbo.sizeof,
                lightBufGen,
                frameCamera, frameData.pointCount, frameData.spotCount);
            gCluster.close();
            frame.resumeScenePass();
        }

        auto zSkin = profileZone!"scene.end.skinUpload"();
        ensureSkinPalettesUploaded();
        zSkin.close();
        setSceneSnapshotViews(defaultSceneColorView, defaultShadow2dView);
        frame.setBindGroup(0, frameBindGroup);
        frame.setBindGroup(2, iblBindGroup);

        immutable cam = Vec3(frameData.cameraPos[0], frameData.cameraPos[1], frameData.cameraPos[2]);
        static float distSq(ref const TexInstanceData d, Vec3 c) pure nothrow @nogc {
            immutable dx = d.model[12] - c.x, dy = d.model[13] - c.y, dz = d.model[14] - c.z;
            return dx * dx + dy * dy + dz * dz;
        }

        // Pass 0: standard opaque batches + hooks + sky.
        // Pass 1: SSR-enabled opaque batches (after opaque snapshot) + transparentHooks (water).
        // Pass 2: alpha/transmissive batches back-to-front (re-snapshots if pass 1/water drew).
        // Pass 3: additive.
        auto zPrepare = profileZone!"scene.end.prepare"();
        foreach (ref b; batches[0 .. batchCount]) {
            if (b.instances.length == 0) continue;
            prepareBatch(b, null);
            frameStats.batches++;
            frameStats.instancesSubmitted += cast(uint) b.instances.length;
            frameStats.instancesVisible += b.colorCount;
        }
        zPrepare.close();

        uint orderCount = 0;
        bool snapshotTaken = false;
        bool sceneDirtySinceSnapshot = false;
        // Unrolled so every pass gets its own compile-time zone names.
        static foreach (pass; 0 .. 4) {{
            enum string passName = ["opaque", "ssr", "alpha", "additive"][pass];
            auto zPass = profileZone!("scene.end." ~ passName)();
            auto gPass = gpuFrameScope!("gpu.scene." ~ passName)(frame);
            auto zSort = profileZone!("scene.end." ~ passName ~ ".sort")();
            orderCount = 0;
            foreach (i, ref b; batches[0 .. batchCount]) {
                if (b.colorCount == 0) continue;
                immutable p = renderPassOf(*b.material);
                if (p != pass) continue;
                if (pass == 2) {
                    b.instances[b.colorFirst .. b.colorFirst + b.colorCount]
                        .sort!((x, y) => distSq(x, cam) > distSq(y, cam));
                    b.uploaded = false;
                    sortFarthest[i] = distSq(b.instances[b.colorFirst], cam);
                }
                sortOrder[orderCount++] = cast(uint) i;
            }
            if (pass == 1 && orderCount > 0 && frame.owner !is null) {
                frame.owner.snapshotOpaque(frame);
                snapshotTaken = true;
                sceneDirtySinceSnapshot = false;
                setSceneSnapshotViews(frame.owner.opaqueColorView(), frame.owner.opaqueDepthView());
                frame.setBindGroup(0, frameBindGroup);
                frame.setBindGroup(2, iblBindGroup);
            } else if (pass == 2) {
                sortOrder[0 .. orderCount].sort!((x, y) => sortFarthest[x] > sortFarthest[y]);
                bool hasTransmissive = false;
                foreach (idx; sortOrder[0 .. orderCount]) {
                    if (batches[idx].material.transmissive) {
                        hasTransmissive = true;
                        break;
                    }
                }
                if (hasTransmissive && frame.owner !is null && (!snapshotTaken || sceneDirtySinceSnapshot)) {
                    frame.owner.snapshotOpaque(frame);
                    snapshotTaken = true;
                    sceneDirtySinceSnapshot = false;
                    setSceneSnapshotViews(frame.owner.opaqueColorView(), frame.owner.opaqueDepthView());
                    frame.setBindGroup(0, frameBindGroup);
                    frame.setBindGroup(2, iblBindGroup);
                }
            }
            zSort.close();
            {
                auto zDraw = profileZone!("scene.end." ~ passName ~ ".batches")();
                auto gDraw = gpuFrameScope!("gpu.scene." ~ passName ~ ".batches")(frame);
                foreach (idx; sortOrder[0 .. orderCount]) {
                    drawBatch(frame, batches[idx]);
                    sceneDirtySinceSnapshot = true;
                }
            }
            if (pass == 0) {
                {
                    auto zStatic = profileZone!"scene.end.opaque.static"();
                    auto gStatic = gpuFrameScope!"gpu.scene.opaque.static"(frame);
                    foreach (sib; staticBufs[0 .. staticCount]) {
                        drawStatic(frame, *sib);
                        sceneDirtySinceSnapshot = true;
                    }
                }
                {
                    auto zHooks = profileZone!"scene.end.opaque.hooks"();
                    auto gHooks = gpuFrameScope!"gpu.scene.opaque.hooks"(frame);
                    foreach (hook; opaqueHooks[0 .. opaqueHookCount]) {
                        hook(frame);
                        sceneDirtySinceSnapshot = true;
                    }
                }
                {
                    auto zHooks = profileZone!"scene.end.opaque.postHooks"();
                    auto gHooks = gpuFrameScope!"gpu.scene.opaque.postHooks"(frame);
                    foreach (hook; postOpaqueHooks[0 .. postOpaqueHookCount]) {
                        hook(frame);
                        sceneDirtySinceSnapshot = true;
                    }
                }
                if (skyEnabled) {
                    auto zSky = profileZone!"scene.end.opaque.sky"();
                    auto gSky = gpuFrameScope!"gpu.scene.opaque.sky"(frame);
                    sky.draw(frame, frameBindGroup);
                    sceneDirtySinceSnapshot = true;
                }
                if (opaqueHookCount > 0 || postOpaqueHookCount > 0) {
                    frame.setBindGroup(0, frameBindGroup);
                    frame.setBindGroup(2, iblBindGroup);
                }
            } else if (pass == 1) {
                auto zHooks = profileZone!"scene.end.ssr.transparentHooks"();
                auto gHooks = gpuFrameScope!"gpu.scene.ssr.transparentHooks"(frame);
                foreach (hook; transparentHooks[0 .. transparentHookCount]) {
                    hook(frame);
                    sceneDirtySinceSnapshot = true;
                }
                if (transparentHookCount > 0) {
                    frame.setBindGroup(0, frameBindGroup);
                    frame.setBindGroup(2, iblBindGroup);
                }
            }
        }}
        setSceneSnapshotViews(defaultSceneColorView, defaultShadow2dView);
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
        immutable bool isSkinned = b.skinnedMesh !is null;
        immutable bool hasBounds = isSkinned ? b.skinnedMesh.hasBounds : (b.mesh !is null && b.mesh.hasBounds);
        if (!cullingEnabled || !hasBounds || n == 0) {
            b.colorFirst = 0;
            b.colorCount = n;
            b.dirFirst = 0;
            b.dirCount = n;
            return;
        }
        immutable local = isSkinned ? BoundingSphere.init : b.mesh.localSphere;
        partitionClasses.resize(n);
        partitionScratch.resize(n);
        foreach (i, ref inst; b.instances[]) {
            BoundingSphere ws;
            if (isSkinned) {
                ws = unpackSkinnedWorldSphere(inst);
            } else {
                Mat4 model;
                model.m = inst.model;
                ws = local.transformed(model);
            }
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
        if (b.instanceBuf is null || b.instances.length > b.capacity) {
            size_t cap = b.capacity > 0 ? b.capacity : INITIAL_INSTANCES_PER_BATCH;
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

        if (b.skinnedMesh !is null) {
            auto pipe = skinnedPipelineFor(b.material.renderState);
            if (pipe is null) return;
            frame.setPipeline(pipe);
            frame.setBindGroup(1, b.material.bindGroup);
            frame.setBindGroup(3, skinPaletteBg);
            frame.setVertexBuffer(0, b.skinnedMesh.vertexBuffer, b.skinnedMesh.vertexBufSize);
            frame.setVertexBuffer(1, b.instanceBuf, b.instances.length * TexInstanceData.sizeof);
            frame.setIndexBuffer(b.skinnedMesh.indexBuffer, b.skinnedMesh.indexFormat, b.skinnedMesh.indexBufSize);
            frame.drawIndexed(b.skinnedMesh.indexCount, b.colorCount, 0, 0, b.colorFirst);
            frameStats.drawCalls++;
            frameStats.lodHistogram[0] += b.colorCount;
            return;
        }

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
        auto module32 = shaderId == 0 ? pipeline.shaderModule : surfaceShaders[shaderId - 1].shaderModule;
        auto module48 = shaderId == 0 ? pipeline.shaderModuleTangent : surfaceShaders[shaderId - 1].shaderModuleTangent;
        foreach (ref v; variants[0 .. variantCount]) {
            if (v.shaderId == shaderId && v.state == state) {
                if (v.pipeline is null)
                    v.pipeline = createTexturedDrawPipeline(device, module32, pipeline.pipelineLayout,
                                                            Renderer.sceneFormat(), 32, false, state);
                if (v.pipelineTangent is null)
                    v.pipelineTangent = createTexturedDrawPipeline(device, module48, pipeline.pipelineLayout,
                                                                   Renderer.sceneFormat(), 48, true, state);
                return tangent ? v.pipelineTangent : v.pipeline;
            }
        }
        if (variantCount >= MAX_VARIANTS) {
            warn("Textured pipeline variant table full; drawing with the default render state");
            return pipelineFor(shaderId, RenderState.init, tangent);
        }
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

    /// Skinned PBR pipeline for `state`, built on first use.
    private WGPURenderPipeline skinnedPipelineFor(RenderState state) @trusted {
        if (state.isDefault) return pipeline.pipelineSkinned;
        foreach (ref v; variants[0 .. variantCount]) {
            if (v.shaderId == 0 && v.state == state) {
                if (v.pipelineSkinned is null)
                    v.pipelineSkinned = createSkinnedTexturedDrawPipeline(
                        device, pipeline.shaderModuleSkinned, pipeline.skinnedPipelineLayout,
                        Renderer.sceneFormat(), state);
                return v.pipelineSkinned;
            }
        }
        if (variantCount >= MAX_VARIANTS) {
            warn("Textured pipeline variant table full; drawing skinned mesh with default render state");
            return pipeline.pipelineSkinned;
        }
        PipelineVariant v;
        v.shaderId = 0;
        v.state = state;
        v.pipelineSkinned = createSkinnedTexturedDrawPipeline(
            device, pipeline.shaderModuleSkinned, pipeline.skinnedPipelineLayout,
            Renderer.sceneFormat(), state);
        variants[variantCount++] = v;
        return v.pipelineSkinned;
    }

    /// Drop cached variants of one shader (after a hot reload).
    private void releaseVariants(uint shaderId) nothrow @nogc @trusted {
        uint kept = 0;
        foreach (ref v; variants[0 .. variantCount]) {
            if (v.shaderId == shaderId) {
                if (v.pipeline !is null) wgpuRenderPipelineRelease(v.pipeline);
                if (v.pipelineTangent !is null) wgpuRenderPipelineRelease(v.pipelineTangent);
                if (v.pipelineSkinned !is null) wgpuRenderPipelineRelease(v.pipelineSkinned);
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
            if (v.pipelineSkinned !is null) wgpuRenderPipelineRelease(v.pipelineSkinned);
        }
        variantCount = 0;
        if (skinPaletteBg !is null) { wgpuBindGroupRelease(skinPaletteBg); skinPaletteBg = null; }
        destroyBuffer(skinPaletteBuf); skinPaletteBuf = null;
        skinPaletteCapacity = 0;
        skinPaletteStaging.release();
        foreach (ref s; surfaceShaders[0 .. surfaceShaderCount]) s.release();
        surfaceShaderCount = 0;
        releaseBatches();
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
        destroyBuffer(spotLightsBuf);
        spotLightsBuf = null;
        pointLightsStaging.release();
        spotLightsStaging.release();
        clusterCuller.destroy();
        destroyBuffer(waterDataBuf);
        waterDataBuf = null;
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
        if (defaultSceneColorView !is null) {
            wgpuTextureViewRelease(defaultSceneColorView);
            defaultSceneColorView = null;
        }
        if (defaultSceneColorTex !is null) {
            wgpuTextureRelease(defaultSceneColorTex);
            defaultSceneColorTex = null;
        }
        if (hasOwnedDirShadow) { ownedDirShadow.destroy(); hasOwnedDirShadow = false; }
        foreach (i; 0 .. MAX_POINT_SHADOW_CASTERS) {
            if (hasOwnedPointShadow[i]) { ownedPointShadows[i].destroy(); hasOwnedPointShadow[i] = false; }
        }
        foreach (i; 0 .. MAX_SPOT_SHADOW_CASTERS) {
            if (hasOwnedSpotShadow[i]) { ownedSpotShadows[i].destroy(); hasOwnedSpotShadow[i] = false; }
        }
        sky.destroy();
        skyEnabled = false;
        if (shadowVpBg !is null) { wgpuBindGroupRelease(shadowVpBg); shadowVpBg = null; }
        if (shadowSurfaceBg !is null) { wgpuBindGroupRelease(shadowSurfaceBg); shadowSurfaceBg = null; }
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

        // 1×1 rgba16Float opaque scene color placeholder until snapshotOpaque provides the pyramid.
        {
            WGPUTextureDescriptor td;
            td.usage = WGPUTextureUsage.textureBinding | WGPUTextureUsage.copyDst;
            td.dimension = WGPUTextureDimension.dim2D;
            td.size = WGPUExtent3D(1, 1, 1);
            td.format = Renderer.sceneFormat();
            defaultSceneColorTex = wgpuDeviceCreateTexture(device, &td);

            WGPUImageCopyTexture dst;
            dst.texture = defaultSceneColorTex;
            WGPUTextureDataLayout layout;
            layout.bytesPerRow = 8;
            layout.rowsPerImage = 1;
            WGPUExtent3D extent = WGPUExtent3D(1, 1, 1);
            immutable ubyte[8] zeroColor = 0;
            wgpuQueueWriteTexture(queue, &dst, zeroColor.ptr, zeroColor.sizeof, &layout, &extent);

            WGPUTextureViewDescriptor vd;
            vd.format = Renderer.sceneFormat();
            vd.dimension = WGPUTextureViewDimension.dim2D;
            defaultSceneColorView = wgpuTextureCreateView(defaultSceneColorTex, &vd);
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
        WGPUTextureView spot0, WGPUTextureView spot1,
        WGPUTextureView sceneColorView = null,
        WGPUTextureView sceneDepthView = null) @trusted
    {
        WGPUTextureView[7] views = [dirView, point0, point1, point2, point3, spot0, spot1];
        WGPUTextureView resolvedSceneColor = sceneColorView !is null ? sceneColorView : defaultSceneColorView;
        WGPUTextureView resolvedSceneDepth = sceneDepthView !is null ? sceneDepthView : defaultShadow2dView;
        if (frameBindGroup !is null && shadowSampler is boundShadowSampler
            && views == boundShadowViews && resolvedSceneColor is boundSceneColorView
            && resolvedSceneDepth is boundSceneDepthView
            && lightBufGen == boundLightBufGen
            && pointLightsBuf is boundPointLightsBuf && spotLightsBuf is boundSpotLightsBuf)
            return;
        boundShadowSampler = shadowSampler;
        boundShadowViews = views;
        boundSceneColorView = resolvedSceneColor;
        boundSceneDepthView = resolvedSceneDepth;
        boundPointLightsBuf = pointLightsBuf;
        boundSpotLightsBuf = spotLightsBuf;
        boundLightBufGen = lightBufGen;
        if (frameBindGroup !is null) {
            wgpuBindGroupRelease(frameBindGroup);
            frameBindGroup = null;
        }
        WGPUBindGroupEntry[FRAME_BINDING_COUNT] entries;
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
        entries[9].size = pointLightBufCap * GpuPointLightUbo.sizeof;
        entries[10].binding = 10;
        entries[10].buffer = waterDataBuf;
        entries[10].offset = 0;
        entries[10].size = WATER_DATA_SIZE;
        entries[11].binding = 11;
        entries[11].textureView = resolvedSceneColor;
        entries[12].binding = 12;
        entries[12].textureView = resolvedSceneDepth;
        entries[13].binding = 13;
        entries[13].buffer = spotLightsBuf;
        entries[13].offset = 0;
        entries[13].size = spotLightBufCap * GpuSpotLightUbo.sizeof;
        entries[14].binding = 14;
        entries[14].buffer = clusterCuller.gridBuffer();
        entries[14].offset = 0;
        entries[14].size = ClusteredLightCuller.gridBufferSize();
        entries[15].binding = 15;
        entries[15].buffer = clusterCuller.indicesBuffer();
        entries[15].offset = 0;
        entries[15].size = ClusteredLightCuller.indicesBufferSize();

        WGPUBindGroupDescriptor desc;
        desc.layout = pipeline.frameBindGroupLayout;
        desc.entryCount = FRAME_BINDING_COUNT;
        desc.entries = entries.ptr;
        frameBindGroup = wgpuDeviceCreateBindGroup(device, &desc);
        if (frameBindGroup is null) fatal("Failed to create frame bind group");
    }

    private void setSceneSnapshotViews(WGPUTextureView sceneColorView, WGPUTextureView sceneDepthView) @trusted {
        rebuildFrameBindGroup(
            boundShadowSampler,
            boundShadowViews[0],
            boundShadowViews[1], boundShadowViews[2],
            boundShadowViews[3], boundShadowViews[4],
            boundShadowViews[5], boundShadowViews[6],
            sceneColorView !is null ? sceneColorView : defaultSceneColorView,
            sceneDepthView !is null ? sceneDepthView : defaultShadow2dView);
    }

    private Batch* findOrAdd(ref TexMesh mesh, ref Material material, ubyte lod) nothrow @nogc @trusted {
        auto b = findOrAddKey(cast(size_t) &mesh, cast(size_t) &material, lod);
        if (b !is null && b.material is null) {
            b.mesh = &mesh;
            b.material = &material;
        }
        return b;
    }

    private Batch* findOrAddSkinned(ref SkinnedMesh mesh, ref Material material) nothrow @nogc @trusted {
        auto b = findOrAddKey(cast(size_t) &mesh, cast(size_t) &material, SKINNED_BATCH_LOD);
        if (b !is null && b.material is null) {
            b.skinnedMesh = &mesh;
            b.material = &material;
        }
        return b;
    }

    /// Batch for a (mesh, material, lod) key, appending a fresh one (with
    /// `material is null`, for the caller to fill) when absent. Doubles the
    /// table when full; `null` only past `MAX_BATCHES_HARD`.
    private Batch* findOrAddKey(size_t meshKey, size_t matKey, ubyte lod) nothrow @nogc {
        immutable found = batchMap.find(meshKey, matKey, lod);
        if (found != BatchMap.none) return &batches[found];
        if (batchCount >= batches.length) {
            if (batches.length >= MAX_BATCHES_HARD) {
                // Warn on the first drop of every frame that drops; the
                // per-frame and lifetime counts are in the stats.
                if (frameStats.droppedDraws == 0)
                    warn("Scene3DTextured: batch table at its ", batches.length,
                         " (mesh, material, lod) ceiling; dropping draws this frame",
                         " (see RenderStats.droppedDraws)");
                frameStats.droppedDraws++;
                droppedDrawsTotal++;
                return null;
            }
            immutable size_t want = batches.length < 8 ? 16 : batches.length * 2;
            reserveBatches(want < MAX_BATCHES_HARD ? want : MAX_BATCHES_HARD);
            batchGrowths++;
        }
        auto b = &batches[batchCount];
        b.mesh = null;
        b.skinnedMesh = null;
        b.material = null;
        b.lod = lod;
        b.instances.clear();
        b.uploaded = false;
        b.prepared = false;
        batchMap.insert(meshKey, matKey, lod, batchCount);
        batchCount++;
        if (batchCount > batchPeak) batchPeak = batchCount;
        return b;
    }

    /// Grow the batch table to `cap` entries (no-op when already that large).
    /// Existing batches move bitwise, keeping their instance storage and GPU
    /// buffers; the lookup map is rebuilt from this frame's live batches.
    /// `@nogc`, so it may run inside the frame loop; no `Batch*` may be held
    /// across a call (`draw*` only use the pointer for one append).
    private void reserveBatches(size_t cap) nothrow @nogc @trusted {
        import core.stdc.stdlib : abort, realloc;
        import core.stdc.string : memset;
        immutable old = batches.length;
        if (cap <= old) return;
        auto p = cast(Batch*) realloc(batches.ptr, cap * Batch.sizeof);
        if (p is null) abort();
        memset(p + old, 0, (cap - old) * Batch.sizeof);
        batches = p[0 .. cap];
        sortOrder.resize(cap);
        sortFarthest.resize(cap);
        batchMap.reserve(cap);
        foreach (i, ref b; batches[0 .. batchCount]) {
            immutable meshKey = b.skinnedMesh !is null
                ? cast(size_t) b.skinnedMesh : cast(size_t) b.mesh;
            batchMap.insert(meshKey, cast(size_t) b.material, b.lod, cast(uint) i);
        }
    }

    /// Free the batch table with every batch's instance storage and buffer.
    private void releaseBatches() nothrow @nogc @trusted {
        import core.stdc.stdlib : free;
        foreach (ref b; batches) {
            destroyBuffer(b.instanceBuf);
            b.instances.release();
        }
        free(batches.ptr);
        batches = null;
        batchCount = 0;
        sortOrder.release();
        sortFarthest.release();
        batchMap.release();
    }

    private void rebuildSkinPaletteBindGroup() nothrow @nogc @trusted {
        if (skinPaletteBg !is null) {
            wgpuBindGroupRelease(skinPaletteBg);
            skinPaletteBg = null;
        }
        WGPUBindGroupEntry entry;
        entry.binding = 0;
        entry.buffer = skinPaletteBuf;
        entry.offset = 0;
        entry.size = skinPaletteCapacity * Mat4.sizeof;
        WGPUBindGroupDescriptor desc;
        desc.layout = pipeline.skinBindGroupLayout;
        desc.entryCount = 1;
        desc.entries = &entry;
        skinPaletteBg = wgpuDeviceCreateBindGroup(device, &desc);
        if (skinPaletteBg is null) fatal("Failed to create skin palette bind group");
    }

    private void ensureSkinPalettesUploaded() nothrow @nogc @trusted {
        if (skinPalettesUploaded || skinPaletteStaging.length == 0) return;
        if (skinPaletteStaging.length > skinPaletteCapacity) {
            size_t cap = skinPaletteCapacity ? skinPaletteCapacity : INITIAL_SKIN_PALETTE_MATRICES;
            while (cap < skinPaletteStaging.length) cap *= 2;
            destroyBuffer(skinPaletteBuf);
            skinPaletteBuf = createStorageBuffer(device, cap * Mat4.sizeof);
            skinPaletteCapacity = cap;
            rebuildSkinPaletteBindGroup();
        }
        wgpuQueueWriteBuffer(queue, skinPaletteBuf, 0, skinPaletteStaging[].ptr,
                             skinPaletteStaging.length * Mat4.sizeof);
        skinPalettesUploaded = true;
    }
}

/// Packs a 16-bit palette base offset (low 16 bits) and a rounded-up bfloat16
/// bounding-sphere radius (high 16 bits) into `TexInstanceData.model[3]`.
package(engine) float packSkinnedOffsetAndRadius(uint paletteOffset, float worldRadius) pure nothrow @nogc {
    uint bf16 = 0;
    if (worldRadius > 0.0f) {
        immutable rBits = floatBits(worldRadius);
        bf16 = (rBits + 0x7FFFu) >> 16;
        if (bf16 == 0) bf16 = 1;
        if (bf16 > 0x7F7Fu) bf16 = 0x7F7Fu;
    }
    return bitsFloat((paletteOffset & 0xFFFFu) | (bf16 << 16));
}

package(engine) uint unpackSkinnedPaletteOffset(ref const TexInstanceData inst) pure nothrow @nogc {
    return floatBits(inst.model[3]) & 0xFFFFu;
}

package(engine) BoundingSphere unpackSkinnedWorldSphere(ref const TexInstanceData inst) pure nothrow @nogc {
    immutable packed = floatBits(inst.model[3]);
    immutable float radius = bitsFloat(packed & 0xFFFF_0000u);
    return BoundingSphere(Vec3(inst.model[7], inst.model[11], inst.model[15]), radius);
}

/// Estimates a model-space pose sphere when the caller does not pass `poseBoundingSphere`.
package(engine) BoundingSphere estimatePoseSphereFromPalette(BoundingSphere bindSphere,
                                                             scope const(Mat4)[] palette) pure nothrow @nogc {
    if (palette.length == 0) return bindSphere;
    Aabb centers;
    immutable c = bindSphere.center;
    foreach (ref m; palette) {
        centers.extend(Vec3(
            m.m[0] * c.x + m.m[4] * c.y + m.m[8]  * c.z + m.m[12],
            m.m[1] * c.x + m.m[5] * c.y + m.m[9]  * c.z + m.m[13],
            m.m[2] * c.x + m.m[6] * c.y + m.m[10] * c.z + m.m[14]
        ));
    }
    return BoundingSphere(centers.center(), centers.halfExtents().length() + bindSphere.radius);
}

/**
 * Open-addressed `(mesh, material, lod) → batch index` table with linear
 * probing. `reset` bumps an epoch instead of clearing slots, so starting a
 * frame is O(1). Capacity is a power of two ≥ 2× the batch capacity, which
 * keeps probes short and guarantees `insert` finds a free slot. Slots are
 * malloc-backed so `reserve` may run inside the frame loop (`@nogc`); it
 * forgets every entry, so the owner re-inserts the live batches after growing.
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
    private PodBuffer!Slot slots;
    private uint epoch = 1;

    /// Size the table for `maxBatches` entries and forget every entry.
    void reserve(size_t maxBatches) nothrow @nogc {
        size_t cap = 16;
        while (cap < maxBatches * 2) cap <<= 1;
        slots.resize(cap); // zero epochs: every slot reads as free
        slots[][] = Slot.init;
        epoch = 1;
    }

    /// Batches the table holds before `reserve` must grow it.
    size_t batchCapacity() const nothrow @nogc { return slots.length / 2; }

    /// Free the slot storage.
    void release() nothrow @nogc {
        slots.release();
        epoch = 1;
    }

    /// Forget every entry (O(1) except on epoch wrap).
    void reset() nothrow @nogc {
        epoch++;
        if (epoch == 0) {
            foreach (ref sl; slots[]) sl.epoch = 0;
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

    // Growing forgets entries; the owner re-inserts them into the larger table.
    assert(map.batchCapacity == 8);
    map.reserve(64);
    assert(map.batchCapacity == 64);
    assert(map.find(0, 0, 0) == BatchMap.none);
    foreach (uint k; 0 .. 64)
        assert(map.insert(k * 16, 0, 0, k));
    foreach (uint k; 0 .. 64)
        assert(map.find(k * 16, 0, 0) == k);
    map.release();
    assert(map.find(0, 0, 0) == BatchMap.none);
}

@("scene3dTextured.batchTableGrows") unittest {
    // No GPU needed: batches create their instance buffer on first upload.
    auto s = new Scene3DTextured;
    s.reserveBatches(4);
    auto meshes = new TexMesh[40];
    auto mats = new Material[3];
    foreach (i; 0 .. 40) {
        auto b = s.findOrAdd(meshes[i], mats[i % 3], cast(ubyte)(i % 2));
        assert(b !is null, "a full table must grow, not drop the draw");
        b.instances.put(TexInstanceData.init);
    }
    assert(s.batchCount == 40);
    assert(s.batches.length == 64);   // 4 -> 16 -> 32 -> 64
    assert(s.sortOrder.length == 64 && s.sortFarthest.length == 64);

    // Batches created before a growth keep their key and instances.
    foreach (i; 0 .. 40) {
        auto b = s.findOrAdd(meshes[i], mats[i % 3], cast(ubyte)(i % 2));
        assert(b is &s.batches[i]);
        assert(b.mesh is &meshes[i] && b.material is &mats[i % 3]);
        assert(b.instances.length == 1);
    }

    // Skinned and static batches share the table.
    SkinnedMesh skinned;
    auto sb = s.findOrAddSkinned(skinned, mats[0]);
    assert(sb !is null && sb.skinnedMesh is &skinned && sb.mesh is null);
    assert(s.findOrAddSkinned(skinned, mats[0]) is sb);
    assert(s.batchCount == 41);

    auto st = s.batchStats();
    assert(st.used == 41 && st.peak == 41 && st.capacity == 64);
    assert(st.growths == 3 && st.droppedDraws == 0);

    // A new frame (what `begin` does to the table) keeps peak and capacity.
    s.batchCount = 0;
    s.batchMap.reset();
    assert(s.findOrAdd(meshes[0], mats[0], 0) !is null);
    st = s.batchStats();
    assert(st.used == 1 && st.peak == 41 && st.capacity == 64);
    s.releaseBatches();
    assert(s.batches.length == 0);
}

@("scene3dTextured.batchTableHardCeiling") unittest {
    auto s = new Scene3DTextured;
    s.reserveBatches(Scene3DTextured.MAX_BATCHES_HARD);
    foreach (size_t k; 1 .. Scene3DTextured.MAX_BATCHES_HARD + 1)
        assert(s.findOrAddKey(k, 0, 0) !is null);
    // Existing keys still resolve at the ceiling; new ones are dropped and counted.
    assert(s.findOrAddKey(1, 0, 0) is &s.batches[0]);
    assert(s.findOrAddKey(0, 0, 0) is null);
    assert(s.findOrAddKey(0, 1, 0) is null);
    assert(s.stats().droppedDraws == 2);
    immutable st = s.batchStats();
    assert(st.used == Scene3DTextured.MAX_BATCHES_HARD && st.capacity == Scene3DTextured.MAX_BATCHES_HARD);
    assert(st.growths == 0 && st.droppedDraws == 2);
    s.releaseBatches();
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

@("scene3dTextured.skinnedPackingAndPoseCulling") @safe unittest {
    import std.math : abs;

    TexInstanceData inst;
    inst.model = Mat4.translation(1.0f, 2.0f, 3.0f).m;
    immutable worldPose = BoundingSphere(Vec3(12.0f, 0.5f, -4.0f), 1.75f);
    inst.model[3] = packSkinnedOffsetAndRadius(1340u, worldPose.radius);
    inst.model[7] = worldPose.center.x;
    inst.model[11] = worldPose.center.y;
    inst.model[15] = worldPose.center.z;

    assert(unpackSkinnedPaletteOffset(inst) == 1340u);
    immutable unpacked = unpackSkinnedWorldSphere(inst);
    assert(unpacked.center == worldPose.center);
    assert(unpacked.radius >= worldPose.radius && unpacked.radius < worldPose.radius + 0.05f);

    // Pose sphere estimate tracks palette translation (e.g. ragdoll/root motion away from bind origin).
    Mat4[2] pal = [Mat4.translation(0, 0, 0), Mat4.translation(10, 0, 0)];
    immutable est = estimatePoseSphereFromPalette(BoundingSphere(Vec3(0, 1, 0), 1.0f), pal[]);
    assert(abs(est.center.x - 5.0f) < 1e-4f);
    assert(est.radius >= 6.0f);

    // Light caster culling uses the unpacked pose sphere, not bind-pose origin (model[12..14]).
    // Instance 0 has model origin at (50, 0, 0) (far outside light) but posed sphere at (2, 0, 0) (inside +X).
    // Instance 1 has model origin at (0, 0, 0) (inside light) but posed sphere at (40, 0, 0) (outside range 10).
    TexInstanceData[2] items;
    items[0].model = Mat4.translation(50, 0, 0).m;
    items[0].model[3] = packSkinnedOffsetAndRadius(0, 1.0f);
    items[0].model[7] = 2.0f; items[0].model[11] = 0.0f; items[0].model[15] = 0.0f;

    items[1].model = Mat4.translation(0, 0, 0).m;
    items[1].model[3] = packSkinnedOffsetAndRadius(64, 1.0f);
    items[1].model[7] = 40.0f; items[1].model[11] = 0.0f; items[1].model[15] = 0.0f;

    import engine.gpu.shadow : pointLightFaceVPs;
    immutable vps = pointLightFaceVPs(Vec3(0, 0, 0), 0.1f, 10.0f);
    Frustum[6] views;
    foreach (f; 0 .. 6) views[f] = Frustum.fromViewProj(vps[f]);

    PodBuffer!TexInstanceData staging;
    PodBuffer!uint cand;
    PodBuffer!BoundingSphere spheres;
    CasterRange[6] ranges;
    gatherLightCasters(items[], BoundingSphere.init, Vec3(0, 0, 0), 10.0f, views[],
                       staging, ranges[], cand, spheres, true);

    bool saw0 = false, saw1 = false;
    foreach (ref it; staging[]) {
        immutable off = unpackSkinnedPaletteOffset(it);
        if (off == 0) saw0 = true;
        if (off == 64) saw1 = true;
    }
    assert(saw0 && !saw1);
    staging.release();
    cand.release();
    spheres.release();
}

/// Classify a material into Scene3DTextured's 4 draw passes:
/// 0 = opaque depth-writing, 1 = SSR opaque depth-writing,
/// 2 = alpha / transmissive (back-to-front after snapshot), 3 = additive.
package(engine) uint renderPassOf(ref const Material m) pure nothrow @nogc {
    immutable st = m.renderState;
    if (m.transmissive) return st.blend == BlendMode.additive ? 3 : 2;
    if (st.depthWrite) return m.ssr ? 1 : 0;
    return st.blend == BlendMode.additive ? 3 : 2;
}

@("scene3d.transmissivePassClassification") @safe unittest {
    Material opaqueMat;
    assert(renderPassOf(opaqueMat) == 0);

    Material ssrMat;
    ssrMat.ssr = true;
    assert(renderPassOf(ssrMat) == 1);

    Material glassMat;
    glassMat.transmissive = true;
    assert(glassMat.renderState.depthWrite);
    assert(renderPassOf(glassMat) == 2);

    Material alphaMat;
    alphaMat.renderState = RenderState(BlendMode.alpha, false);
    assert(renderPassOf(alphaMat) == 2);

    Material additiveMat;
    additiveMat.renderState = RenderState(BlendMode.additive, false);
    assert(renderPassOf(additiveMat) == 3);
}
