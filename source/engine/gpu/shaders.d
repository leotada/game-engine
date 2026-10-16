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

enum shadowDepthShaderSource = import("shadow_depth.wgsl");

enum gizmoLineShaderSource = import("gizmo_line.wgsl");

enum ui2dShaderSource = import("ui2d.wgsl");

enum bloomThresholdShaderSource = preprocessShader(import("post_bloom_threshold.wgsl"), "post_bloom_threshold.wgsl").code;

enum bloomDownsampleKarisShaderSource = preprocessShader(import("post_bloom_down_karis.wgsl"), "post_bloom_down_karis.wgsl").code;

enum bloomDownsampleShaderSource = preprocessShader(import("post_bloom_down.wgsl"), "post_bloom_down.wgsl").code;

enum bloomUpsampleShaderSource = preprocessShader(import("post_bloom_up.wgsl"), "post_bloom_up.wgsl").code;

enum tonemapShaderSource = preprocessShader(import("post_tonemap.wgsl"), "post_tonemap.wgsl").code;

enum fxaaShaderSource = preprocessShader(import("post_fxaa.wgsl"), "post_fxaa.wgsl").code;

enum blitShaderSource = preprocessShader(import("post_blit.wgsl"), "post_blit.wgsl").code;
