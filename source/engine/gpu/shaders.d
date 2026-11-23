/// WGSL shader source strings for render pipelines.
/// All sources are loaded from modular .wgsl files in assets/shaders/ with #include preprocessing.
module engine.gpu.shaders;

import engine.hotreload.shader_source : preprocessShader;

@safe:

enum fullscreenVsSource = import("common/fullscreen_vs.wgsl");

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
immutable string shadowDepthSkinnedShaderSource = preprocessShader(import("shadow_depth.wgsl"), "shadow_depth.wgsl", ["SKINNED"]).code;

enum gizmoLineShaderSource = import("gizmo_line.wgsl");

enum ui2dShaderSource = import("ui2d.wgsl");

enum sprite2dShaderSource = import("sprite2d.wgsl");

immutable string bloomThresholdShaderSource = preprocessShader(import("post_bloom_threshold.wgsl"), "post_bloom_threshold.wgsl").code;

immutable string bloomDownsampleKarisShaderSource = preprocessShader(import("post_bloom_down_karis.wgsl"), "post_bloom_down_karis.wgsl").code;

immutable string bloomDownsampleShaderSource = preprocessShader(import("post_bloom_down.wgsl"), "post_bloom_down.wgsl").code;

immutable string bloomUpsampleShaderSource = preprocessShader(import("post_bloom_up.wgsl"), "post_bloom_up.wgsl").code;

immutable string tonemapShaderSource = preprocessShader(import("post_tonemap.wgsl"), "post_tonemap.wgsl").code;

immutable string fxaaShaderSource = preprocessShader(import("post_fxaa.wgsl"), "post_fxaa.wgsl").code;

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
immutable string clusterCullCsShaderSource = preprocessShader(import("clustered_cull_cs.wgsl"), "clustered_cull_cs.wgsl").code;
