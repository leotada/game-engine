#include "common/fullscreen_vs.wgsl"

struct Params {
    threshold: f32,
    knee: f32,
    bloomClamp: f32,
    _pad: f32,
};
@group(0) @binding(0) var<uniform> p: Params;
@group(0) @binding(1) var srcSamp: sampler;
@group(0) @binding(2) var srcTex: texture_2d<f32>;

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let c = textureSample(srcTex, srcSamp, uv).rgb;
    let brightness = max(c.r, max(c.g, c.b));
    let soft = brightness - p.threshold + p.knee;
    let softClamped = clamp(soft, 0.0, 2.0 * p.knee);
    let softKnee = (softClamped * softClamped) / (4.0 * p.knee + 1e-4);
    let contribution = max(softKnee, brightness - p.threshold) / max(brightness, 1e-4);
    var outRgb = c * contribution;
    outRgb = min(outRgb, vec3<f32>(p.bloomClamp));
    return vec4<f32>(outRgb, 1.0);
}
