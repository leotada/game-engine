#include "common/fullscreen_vs.wgsl"

@group(0) @binding(0) var srcSamp: sampler;
@group(0) @binding(1) var srcTex: texture_2d<f32>;

fn luma(c: vec3<f32>) -> f32 {
    return max(c.r, max(c.g, c.b));
}

fn karisGroup(c0: vec3<f32>, c1: vec3<f32>, c2: vec3<f32>, c3: vec3<f32>) -> vec3<f32> {
    let w0 = 1.0 / (1.0 + luma(c0));
    let w1 = 1.0 / (1.0 + luma(c1));
    let w2 = 1.0 / (1.0 + luma(c2));
    let w3 = 1.0 / (1.0 + luma(c3));
    return (c0 * w0 + c1 * w1 + c2 * w2 + c3 * w3) / (w0 + w1 + w2 + w3);
}

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let texSize = vec2<f32>(textureDimensions(srcTex));
    let texel = 1.0 / texSize;
    let x = texel.x;
    let y = texel.y;

    // 4×4 tap grid centered on uv (offsets ±0.5 and ±1.5 texels)
    let s00 = textureSample(srcTex, srcSamp, uv + vec2<f32>(-1.5*x, -1.5*y)).rgb;
    let s10 = textureSample(srcTex, srcSamp, uv + vec2<f32>(-0.5*x, -1.5*y)).rgb;
    let s20 = textureSample(srcTex, srcSamp, uv + vec2<f32>( 0.5*x, -1.5*y)).rgb;
    let s30 = textureSample(srcTex, srcSamp, uv + vec2<f32>( 1.5*x, -1.5*y)).rgb;

    let s01 = textureSample(srcTex, srcSamp, uv + vec2<f32>(-1.5*x, -0.5*y)).rgb;
    let s11 = textureSample(srcTex, srcSamp, uv + vec2<f32>(-0.5*x, -0.5*y)).rgb;
    let s21 = textureSample(srcTex, srcSamp, uv + vec2<f32>( 0.5*x, -0.5*y)).rgb;
    let s31 = textureSample(srcTex, srcSamp, uv + vec2<f32>( 1.5*x, -0.5*y)).rgb;

    let s02 = textureSample(srcTex, srcSamp, uv + vec2<f32>(-1.5*x,  0.5*y)).rgb;
    let s12 = textureSample(srcTex, srcSamp, uv + vec2<f32>(-0.5*x,  0.5*y)).rgb;
    let s22 = textureSample(srcTex, srcSamp, uv + vec2<f32>( 0.5*x,  0.5*y)).rgb;
    let s32 = textureSample(srcTex, srcSamp, uv + vec2<f32>( 1.5*x,  0.5*y)).rgb;

    let s03 = textureSample(srcTex, srcSamp, uv + vec2<f32>(-1.5*x,  1.5*y)).rgb;
    let s13 = textureSample(srcTex, srcSamp, uv + vec2<f32>(-0.5*x,  1.5*y)).rgb;
    let s23 = textureSample(srcTex, srcSamp, uv + vec2<f32>( 0.5*x,  1.5*y)).rgb;
    let s33 = textureSample(srcTex, srcSamp, uv + vec2<f32>( 1.5*x,  1.5*y)).rgb;

    let g0 = karisGroup(s00, s10, s01, s11); // top-left
    let g1 = karisGroup(s20, s30, s21, s31); // top-right
    let g2 = karisGroup(s02, s12, s03, s13); // bottom-left
    let g3 = karisGroup(s22, s32, s23, s33); // bottom-right

    let result = (g0 + g1 + g2 + g3) * 0.25;
    return vec4<f32>(result, 1.0);
}
