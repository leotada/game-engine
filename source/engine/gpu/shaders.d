/// WGSL shader source strings for render pipelines.
/// All sources are loaded from modular .wgsl files in assets/shaders/ with #include preprocessing.
module engine.gpu.shaders;

import engine.hotreload.shader_source : preprocessShader;

@safe:

enum fullscreenVsSource = import("common/fullscreen_vs.wgsl");

enum cube3dShaderSource = import("cube3d.wgsl");

enum colored3dShaderSource = import("colored3d.wgsl");

enum text2dShaderSource = import("text2d.wgsl");

enum textured3dShaderSource = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl").code;
enum textured3dTangentShaderSource = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl", ["MESH_TANGENT"]).code;

/// PBR shader variants with the custom-surface hook enabled. They still hold
/// the splice markers; build the final source with `composeSurfaceShader`.
enum textured3dSurfaceTemplate = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl", ["CUSTOM_SURFACE"]).code;
enum textured3dSurfaceTangentTemplate = preprocessShader(import("textured3d_pbr.wgsl"), "textured3d_pbr.wgsl", ["CUSTOM_SURFACE", "MESH_TANGENT"]).code;

private enum SURFACE_CODE_MARKER = "//@@SURFACE_CODE@@";
private enum DISPLACE_CALL_MARKER = "//@@DISPLACE_CALL@@";

/// Splice game WGSL into the PBR shader. `surfaceWgsl` must define
/// `fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut`; when it also
/// defines `fn displace(localPos: vec3<f32>, localNormal: vec3<f32>) -> vec3<f32>`
/// the vertex stage calls it before the model transform.
string composeSurfaceShader(scope const(char)[] surfaceWgsl, bool tangent = false) {
    import std.array : replace;
    import std.algorithm.searching : canFind;

    string code = tangent ? textured3dSurfaceTangentTemplate : textured3dSurfaceTemplate;
    immutable displaceCall = surfaceWgsl.canFind("fn displace(")
        ? "    localPos = displace(localPos, in.normal);" : "";
    code = code.replace(DISPLACE_CALL_MARKER, displaceCall);
    return code.replace(SURFACE_CODE_MARKER, surfaceWgsl.idup);
}

unittest {
    import std.algorithm.searching : canFind;

    static assert(textured3dSurfaceTemplate.canFind(SURFACE_CODE_MARKER));
    static assert(textured3dSurfaceTemplate.canFind(DISPLACE_CALL_MARKER));
    static assert(!textured3dShaderSource.canFind("surfaceParams"));

    enum snippet = "fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut { return base; }";
    auto plain = composeSurfaceShader(snippet);
    assert(plain.canFind(snippet));
    assert(!plain.canFind("@@"));
    assert(!plain.canFind("localPos = displace("));
    assert(!plain.canFind("@location(8) tangent"));

    auto displaced = composeSurfaceShader(
        snippet ~ "\nfn displace(localPos: vec3<f32>, localNormal: vec3<f32>) -> vec3<f32> { return localPos; }",
        true);
    assert(displaced.canFind("localPos = displace(localPos, in.normal);"));
    assert(displaced.canFind("@location(8) tangent"));
}

enum shadowDepthShaderSource = import("shadow_depth.wgsl");

enum gizmoLineShaderSource = import("gizmo_line.wgsl");

enum ui2dShaderSource = import("ui2d.wgsl");

enum sprite2dShaderSource = import("sprite2d.wgsl");

enum bloomThresholdShaderSource = preprocessShader(import("post_bloom_threshold.wgsl"), "post_bloom_threshold.wgsl").code;

enum bloomDownsampleKarisShaderSource = preprocessShader(import("post_bloom_down_karis.wgsl"), "post_bloom_down_karis.wgsl").code;

enum bloomDownsampleShaderSource = preprocessShader(import("post_bloom_down.wgsl"), "post_bloom_down.wgsl").code;

enum bloomUpsampleShaderSource = preprocessShader(import("post_bloom_up.wgsl"), "post_bloom_up.wgsl").code;

enum tonemapShaderSource = preprocessShader(import("post_tonemap.wgsl"), "post_tonemap.wgsl").code;

enum fxaaShaderSource = preprocessShader(import("post_fxaa.wgsl"), "post_fxaa.wgsl").code;

enum blitShaderSource = preprocessShader(import("post_blit.wgsl"), "post_blit.wgsl").code;

enum skinnedShaderSource = import("skinned.wgsl");

/// Engine sky (fullscreen, far plane) — `engine.gpu.sky.SkyRenderer`.
enum skyShaderSource = preprocessShader(import("sky.wgsl"), "sky.wgsl").code;
/// Runtime HDR IBL compute passes — `engine.gpu.ibl_dynamic.DynamicIbl`.
enum iblSkyCsShaderSource = preprocessShader(import("ibl_sky_cs.wgsl"), "ibl_sky_cs.wgsl").code;
enum skyDomeShaderSource = preprocessShader(import("sky_dome.wgsl"), "sky_dome.wgsl").code;
enum causticsBedShaderSource = preprocessShader(import("caustics_bed.wgsl"), "caustics_bed.wgsl").code;
enum waterSurfaceShaderSource = preprocessShader(import("water_surface.wgsl"), "water_surface.wgsl").code;
enum depthCopyShaderSource = preprocessShader(import("depth_copy.wgsl"), "depth_copy.wgsl").code;
enum waterSimCsShaderSource = preprocessShader(import("water_sim_cs.wgsl"), "water_sim_cs.wgsl").code;
