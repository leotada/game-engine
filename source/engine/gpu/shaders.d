/// WGSL shader source strings for render pipelines.
/// All sources are loaded from modular .wgsl files in assets/shaders/ with #include preprocessing.
module engine.gpu.shaders;

import engine.hotreload.shader_source : preprocessShader;

@safe:

enum fullscreenVsSource = import("common/fullscreen_vs.wgsl");
/// Scene depth / camera inputs of custom post passes (`PostPassDesc.sceneInputs`).
enum postSceneSource = import("common/post_scene.wgsl");

enum cube3dShaderSource = import("cube3d.wgsl");

enum colored3dShaderSource = import("colored3d.wgsl");

enum text2dShaderSource = import("text2d.wgsl");

immutable string textured3dShaderSource = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl").code;
immutable string textured3dTangentShaderSource = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl", ["MESH_TANGENT"]).code;
immutable string textured3dSkinnedShaderSource = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl", ["MESH_TANGENT", "SKINNED"]).code;

/// PBR shader variants with the custom-surface hook enabled. They still hold
/// the splice markers; build the final source with `composeSurfaceShader`.
enum textured3dSurfaceTemplate = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl", ["CUSTOM_SURFACE"]).code;
enum textured3dSurfaceTangentTemplate = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl", ["CUSTOM_SURFACE", "MESH_TANGENT"]).code;

private enum SURFACE_CODE_MARKER = "//@@SURFACE_CODE@@";
private enum DISPLACE_FN_MARKER = "//@@DISPLACE_FN@@";

private immutable string kTextured3dSurfaceTemplate = textured3dSurfaceTemplate;
private immutable string kTextured3dSurfaceTangentTemplate = textured3dSurfaceTangentTemplate;

/// Enable the vertex-color lines (`//#VC`) of a composed PBR shader.
string withVertexColor(scope const(char)[] code) {
    import std.array : replace;
    return code.replace("//#VC ", "").idup;
}

@("shaders.withVertexColor") unittest {
    import std.algorithm.searching : canFind, count;
    auto code = withVertexColor(textured3dTangentShaderSource);
    assert(code.canFind("\n    @location(12) vertexColor: vec4<f32>,"));
    assert(!code.canFind("//#VC "));
    assert(textured3dTangentShaderSource.count("//#VC ") >= 5);
}

/// Which vertex hook a surface snippet defines.
enum DisplaceKind : ubyte {
    /// No vertex hook: geometry is static (shadow passes use the stock pipeline).
    none,
    /// `fn displace(localPos, localNormal) -> vec3<f32>` (original signature).
    basic,
    /// `fn displaceEx(d: DisplaceIn) -> vec3<f32>` (instance + UV data).
    extended,
}

/// Detect the vertex hook in a surface snippet. `displaceEx` wins over `displace`.
DisplaceKind surfaceDisplaceKind(scope const(char)[] surfaceWgsl) pure {
    import std.algorithm.searching : canFind;
    if (surfaceWgsl.canFind("fn displaceEx(")) return DisplaceKind.extended;
    if (surfaceWgsl.canFind("fn displace(")) return DisplaceKind.basic;
    return DisplaceKind.none;
}

/// Splice game WGSL into the PBR shader. `surfaceWgsl` must define
/// `fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut`. It may also
/// define `fn displace(localPos: vec3<f32>, localNormal: vec3<f32>) -> vec3<f32>`
/// or the richer `fn displaceEx(d: DisplaceIn) -> vec3<f32>`; the vertex stage
/// and the depth-only shadow stage (`vs_shadow`) call it before the model
/// transform through the generated `engineDisplace` wrapper.
string composeSurfaceShader(scope const(char)[] surfaceWgsl, bool tangent = false) {
    import std.array : replace;

    string code = tangent ? kTextured3dSurfaceTangentTemplate : kTextured3dSurfaceTemplate;
    final switch (surfaceDisplaceKind(surfaceWgsl)) {
        case DisplaceKind.none:
            enum body_ = "    return localPos;";
            code = code.replace(DISPLACE_FN_MARKER, displaceWrapper(body_));
            break;
        case DisplaceKind.basic:
            code = code.replace(DISPLACE_FN_MARKER, displaceWrapper("    return displace(localPos, localNormal);"));
            break;
        case DisplaceKind.extended:
            code = code.replace(DISPLACE_FN_MARKER, displaceWrapper(
                "    var d: DisplaceIn;\n"
                ~ "    d.localPos = localPos;\n"
                ~ "    d.localNormal = localNormal;\n"
                ~ "    d.uv = uv;\n"
                ~ "    d.custom = custom;\n"
                ~ "    d.instancePos = model[3].xyz;\n"
                ~ "    d.objectScale = vec3<f32>(length(model[0].xyz), length(model[1].xyz), length(model[2].xyz));\n"
                ~ "    return displaceEx(d);"));
            break;
    }
    return code.replace(SURFACE_CODE_MARKER, surfaceWgsl.idup);
}

private enum SURFACE_PARAMS_UNIFORM = "@group(1) @binding(7) var<uniform> surfaceParams: SurfaceParams;";

/// `@binding`s (group 1) of the batched shadow stage: the material surface
/// parameter chunk and the per-instance slot index.
enum uint SHADOW_TABLE_PARAMS_BINDING = 30;
enum uint SHADOW_TABLE_INDEX_BINDING = 31;

/// True when the vertex hook of `surfaceWgsl` only reads `surfaceParams`,
/// `frame` and its inputs, so shadow casters of different materials sharing
/// the shader can be drawn together (`composeSurfaceShadowTableShader`). Any
/// mention of `mat.`, a texture or a sampler outside `fn surface` keeps the
/// per-material path.
bool surfaceDisplaceBatchable(scope const(char)[] surfaceWgsl) pure {
    import std.algorithm.searching : canFind;
    if (surfaceDisplaceKind(surfaceWgsl) == DisplaceKind.none) return false;
    const(char)[] rest = withoutFunction(surfaceWgsl.idup, "fn surface(");
    foreach (word; ["mat.", "texture", "Sampler", "sampler", "Map"])
        if (rest.canFind(word)) return false;
    return true;
}

/// `src` with the body of the function starting at `head` removed.
private const(char)[] withoutFunction(const(char)[] src, string head) pure {
    import std.string : indexOf;
    immutable start = src.indexOf(head);
    if (start < 0) return src;
    immutable open = src[start .. $].indexOf('{');
    if (open < 0) return src;
    size_t i = start + open, depth = 0;
    for (; i < src.length; i++) {
        if (src[i] == '{') depth++;
        else if (src[i] == '}' && --depth == 0) break;
    }
    return i >= src.length ? src[0 .. start] : (src[0 .. start] ~ src[i + 1 .. $]);
}

/// `composeSurfaceShader` plus a `vs_shadow_table` entry point: `surfaceParams`
/// becomes a per-invocation copy loaded from the material chunk
/// (`@binding(30)`, 256-byte slots) at the slot stored for the instance
/// (`@binding(31)`, indexed by `instance_index`). One draw then covers the
/// casters of every material that shares the surface shader.
string composeSurfaceShadowTableShader(scope const(char)[] surfaceWgsl, bool tangent = false) {
    import std.array : replace;
    import std.conv : to;
    auto code = composeSurfaceShader(surfaceWgsl, tangent);
    code = code.replace(SURFACE_PARAMS_UNIFORM,
        "struct SurfaceParamSlot {\n    p: SurfaceParams,\n    pad: array<vec4<f32>, 12>,\n};\n"
        ~ "@group(1) @binding(" ~ SHADOW_TABLE_PARAMS_BINDING.to!string
        ~ ") var<storage, read> surfaceParamTable: array<SurfaceParamSlot>;\n"
        ~ "@group(1) @binding(" ~ SHADOW_TABLE_INDEX_BINDING.to!string
        ~ ") var<storage, read> surfaceParamIndex: array<u32>;\n"
        ~ "var<private> surfaceParams: SurfaceParams;");
    return code ~ "\n@vertex\n"
        ~ "fn vs_shadow_table(in: ShadowVertexInput, @builtin(instance_index) instance: u32) -> @builtin(position) vec4<f32> {\n"
        ~ "    surfaceParams = surfaceParamTable[surfaceParamIndex[instance]].p;\n"
        ~ "    let model = mat4x4<f32>(in.model0, in.model1, in.model2, in.model3);\n"
        ~ "    let localPos = engineDisplace(in.position, in.normal, in.uv, in.custom, model);\n"
        ~ "    return shadowLight.viewProj * model * vec4<f32>(localPos, 1.0);\n"
        ~ "}\n";
}

@("shaders.surfaceShadowTable") unittest {
    import std.algorithm.searching : canFind;
    enum surf = "fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut { var o = base; o.baseColor = textureSample(albedoMap, texSampler, in.uv).rgb * mat.baseColor; return o; }\n";
    enum disp = "fn displaceEx(d: DisplaceIn) -> vec3<f32> { return d.localPos + surfaceParams.p0.xyz * sin(frame.time); }\n";
    // Textures and material fields used by `surface` only: batchable.
    assert(surfaceDisplaceBatchable(surf ~ disp));
    // No vertex hook: nothing to batch.
    assert(!surfaceDisplaceBatchable(surf));
    // A hook reading the material or a texture keeps the per-material path.
    assert(!surfaceDisplaceBatchable(surf ~ "fn displaceEx(d: DisplaceIn) -> vec3<f32> { return d.localPos * mat.thinRadius; }"));
    assert(!surfaceDisplaceBatchable("fn displace(p: vec3<f32>, n: vec3<f32>) -> vec3<f32> { return p + textureSampleLevel(albedoMap, texSampler, vec2<f32>(0.0), 0.0).xyz; }"));
    static assert(textured3dSurfaceTemplate.canFind(SURFACE_PARAMS_UNIFORM));
    auto code = composeSurfaceShadowTableShader(surf ~ disp);
    assert(code.canFind("fn vs_shadow_table("));
    assert(code.canFind("var<private> surfaceParams: SurfaceParams;"));
    assert(!code.canFind(SURFACE_PARAMS_UNIFORM));
    assert(code.canFind("@binding(30) var<storage, read> surfaceParamTable"));
}

private string displaceWrapper(string body_) pure {
    return "fn engineDisplace(localPos: vec3<f32>, localNormal: vec3<f32>, uv: vec2<f32>,\n"
        ~ "                   custom: vec4<f32>, model: mat4x4<f32>) -> vec3<f32> {\n"
        ~ body_ ~ "\n}";
}

unittest {
    import std.algorithm.searching : canFind;

    static assert(textured3dSurfaceTemplate.canFind(SURFACE_CODE_MARKER));
    static assert(textured3dSurfaceTemplate.canFind(DISPLACE_FN_MARKER));
    static assert(textured3dSurfaceTemplate.canFind("fn vs_shadow("));
    static assert(!textured3dShaderSource.canFind("surfaceParams"));
    static assert(!textured3dShaderSource.canFind("vs_shadow"));

    enum snippet = "fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut { return base; }";
    auto plain = composeSurfaceShader(snippet);
    assert(plain.canFind(snippet));
    assert(!plain.canFind("@@"));
    assert(plain.canFind("fn engineDisplace("));
    assert(plain.canFind("return localPos;"));
    assert(!plain.canFind("return displace("));
    assert(!plain.canFind("@location(8) tangent"));
    assert(surfaceDisplaceKind(snippet) == DisplaceKind.none);

    enum basicSrc = snippet ~ "\nfn displace(localPos: vec3<f32>, localNormal: vec3<f32>) -> vec3<f32> { return localPos; }";
    auto displaced = composeSurfaceShader(basicSrc, true);
    assert(displaced.canFind("return displace(localPos, localNormal);"));
    assert(displaced.canFind("@location(8) tangent"));
    assert(surfaceDisplaceKind(basicSrc) == DisplaceKind.basic);

    enum exSrc = snippet ~ "\nfn displaceEx(d: DisplaceIn) -> vec3<f32> { return d.localPos; }";
    auto ex = composeSurfaceShader(exSrc);
    assert(ex.canFind("return displaceEx(d);"));
    assert(ex.canFind("d.instancePos = model[3].xyz;"));
    assert(!ex.canFind("@@"));
    assert(surfaceDisplaceKind(exSrc) == DisplaceKind.extended);
    // Both defined: the extended hook wins.
    assert(surfaceDisplaceKind(basicSrc ~ exSrc) == DisplaceKind.extended);
}

immutable string shadowDepthShaderSource = preprocessShader(import("shadow_depth.wgsl"), "shadow_depth.wgsl").code;
/// Alpha-masked shadow casters (discard below the material cutoff).
immutable string shadowDepthMaskShaderSource = preprocessShader(import("shadow_depth.wgsl"), "shadow_depth.wgsl", ["ALPHA_MASK"]).code;
immutable string shadowDepthSkinnedMaskShaderSource = preprocessShader(import("shadow_depth.wgsl"), "shadow_depth.wgsl", ["ALPHA_MASK", "SKINNED"]).code;
immutable string shadowDepthSkinnedShaderSource = preprocessShader(import("shadow_depth.wgsl"), "shadow_depth.wgsl", ["SKINNED"]).code;

enum gizmoLineShaderSource = import("gizmo_line.wgsl");

enum ui2dShaderSource = import("ui2d.wgsl");

enum sprite2dShaderSource = import("sprite2d.wgsl");

immutable string bloomThresholdShaderSource = preprocessShader(import("post_bloom_threshold.wgsl"), "post_bloom_threshold.wgsl").code;

immutable string bloomDownsampleKarisShaderSource = preprocessShader(import("post_bloom_down_karis.wgsl"), "post_bloom_down_karis.wgsl").code;

immutable string bloomDownsampleShaderSource = preprocessShader(import("post_bloom_down.wgsl"), "post_bloom_down.wgsl").code;

immutable string bloomUpsampleShaderSource = preprocessShader(import("post_bloom_up.wgsl"), "post_bloom_up.wgsl").code;

immutable string tonemapShaderSource = preprocessShader(import("post_tonemap.wgsl"), "post_tonemap.wgsl").code;
/// Tone map with auto exposure and the 3D color table.
immutable string tonemapGradedShaderSource = preprocessShader(import("post_tonemap.wgsl"), "post_tonemap.wgsl", ["GRADED"]).code;

/// Auto exposure — `engine.gpu.auto_exposure.AutoExposurePass`.
enum autoExposureShaderSource = import("auto_exposure.wgsl");

immutable string fxaaShaderSource = preprocessShader(import("post_fxaa.wgsl"), "post_fxaa.wgsl").code;

immutable string fxaaHqShaderSource = preprocessShader(import("post_fxaa_hq.wgsl"), "post_fxaa_hq.wgsl").code;
/// Volumetric light — `engine.gpu.volumetric.VolumetricPass`.
immutable string volumetricShaderSource = preprocessShader(import("volumetric.wgsl"), "volumetric.wgsl").code;
/// SMAA 1x — `engine.gpu.post_smaa.SmaaPass`.
immutable string smaaShaderSource = import("post_smaa.wgsl");
/// CMAA2 — `engine.gpu.post_cmaa2.Cmaa2Pass`.
immutable string cmaa2ShaderSource = import("post_cmaa2.wgsl");
immutable string casShaderSource = preprocessShader(import("post_cas.wgsl"), "post_cas.wgsl").code;

immutable string blitShaderSource = preprocessShader(import("post_blit.wgsl"), "post_blit.wgsl").code;

enum skinnedShaderSource = import("skinned.wgsl");

/// Engine sky (fullscreen, far plane) — `engine.gpu.sky.SkyRenderer`.
immutable string skyShaderSource = preprocessShader(import("sky.wgsl"), "sky.wgsl").code;
/// Runtime HDR IBL compute passes — `engine.gpu.ibl_dynamic.DynamicIbl`.
immutable string iblSkyCsShaderSource = preprocessShader(import("ibl_sky_cs.wgsl"), "ibl_sky_cs.wgsl").code;
/// Chunked terrain — `engine.terrain.renderer.TerrainRenderer`.
immutable string terrainPbrShaderSource = preprocessShader(import("terrain_pbr.wgsl"), "terrain_pbr.wgsl").code;
immutable string terrainShadowShaderSource = preprocessShader(import("terrain_shadow.wgsl"), "terrain_shadow.wgsl").code;
/// Projected decals — `engine.graphics.decals.DecalRenderer`.
immutable string decalPbrShaderSource = preprocessShader(import("decal_pbr.wgsl"), "decal_pbr.wgsl").code;
immutable string waterSurfaceShaderSource = preprocessShader(import("water_surface.wgsl"), "water_surface.wgsl").code;
immutable string depthCopyShaderSource = preprocessShader(import("depth_copy.wgsl"), "depth_copy.wgsl").code;
immutable string waterSimCsShaderSource = preprocessShader(import("water_sim_cs.wgsl"), "water_sim_cs.wgsl").code;
/// Clustered Forward compute light culling — `engine.gpu.clustered.ClusteredLightCuller`.
/// Ground-truth ambient occlusion — `engine.gpu.gtao.GtaoPass`.
immutable string gtaoShaderSource = import("gtao.wgsl");
/// GPU culling of `StaticInstanceBuffer` — `engine.gpu.static_cull.StaticCuller`.
immutable string staticCullCsShaderSource = preprocessShader(import("static_cull_cs.wgsl"), "static_cull_cs.wgsl").code;
immutable string clusterCullCsShaderSource = preprocessShader(import("clustered_cull_cs.wgsl"), "clustered_cull_cs.wgsl").code;
