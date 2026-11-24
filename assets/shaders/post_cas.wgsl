/// Contrast adaptive sharpening after antialiasing: the negative lobe of a
/// 5-tap filter follows the local headroom, so flat and already sharp areas
/// do not ring. Formulation after AMD FidelityFX CAS (MIT, see
/// docs/third-party-licenses.md).

#include "common/fullscreen_vs.wgsl"

struct AaParams {
    subpix: f32,
    sharpness: f32,
    edgeThreshold: f32,
    edgeThresholdMin: f32,
};
@group(0) @binding(0) var<uniform> p: AaParams;
@group(0) @binding(1) var srcSamp: sampler;
@group(0) @binding(2) var srcTex: texture_2d<f32>;

@fragment
fn fs_main(@builtin(position) pos: vec4<f32>) -> @location(0) vec4<f32> {
    let size = vec2<i32>(textureDimensions(srcTex));
    let c = vec2<i32>(pos.xy);
    let e = textureLoad(srcTex, c, 0).rgb;
    let b = textureLoad(srcTex, clamp(c + vec2<i32>(0, -1), vec2<i32>(0), size - 1), 0).rgb;
    let d = textureLoad(srcTex, clamp(c + vec2<i32>(-1, 0), vec2<i32>(0), size - 1), 0).rgb;
    let f = textureLoad(srcTex, clamp(c + vec2<i32>(1, 0), vec2<i32>(0), size - 1), 0).rgb;
    let h = textureLoad(srcTex, clamp(c + vec2<i32>(0, 1), vec2<i32>(0), size - 1), 0).rgb;

    let mn = min(e, min(min(b, d), min(f, h)));
    let mx = max(e, max(max(b, d), max(f, h)));
    let amp = sqrt(saturate(min(mn, vec3<f32>(1.0) - mx) / max(mx, vec3<f32>(1e-4))));
    let w = amp * (-0.2 * saturate(p.sharpness));
    let col = (w * (b + d + f + h) + e) / (4.0 * w + 1.0);
    return vec4<f32>(saturate(col), 1.0);
}
