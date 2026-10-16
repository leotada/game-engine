#include "common/fullscreen_vs.wgsl"

struct Params {
    exposure: f32,
    bloomStrength: f32,
    tonemapMode: f32,
    _pad: f32,
};
@group(0) @binding(0) var<uniform> p: Params;
@group(0) @binding(1) var srcSamp: sampler;
@group(0) @binding(2) var sceneTex: texture_2d<f32>;
@group(0) @binding(3) var bloomTex: texture_2d<f32>;

fn acesNarkowicz(x: vec3<f32>) -> vec3<f32> {
    let a = 2.51;
    let b = 0.03;
    let c = 2.43;
    let d = 0.59;
    let e = 0.14;
    return clamp((x * (a * x + b)) / (x * (c * x + d) + e), vec3<f32>(0.0), vec3<f32>(1.0));
}

fn reinhard(x: vec3<f32>) -> vec3<f32> {
    return x / (x + vec3<f32>(1.0));
}

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    var hdr = textureSample(sceneTex, srcSamp, uv).rgb;
    let bloom = textureSample(bloomTex, srcSamp, uv).rgb;
    hdr = hdr + bloom * p.bloomStrength;
    hdr = hdr * p.exposure;
    var ldr: vec3<f32>;
    if (p.tonemapMode < 0.5) {
        ldr = acesNarkowicz(hdr);
    } else {
        ldr = reinhard(hdr);
    }
    // Approximate linear → sRGB
    ldr = pow(max(ldr, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    return vec4<f32>(ldr, 1.0);
}
