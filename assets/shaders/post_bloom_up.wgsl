#include "common/fullscreen_vs.wgsl"

@group(0) @binding(0) var srcSamp: sampler;
@group(0) @binding(1) var srcTex: texture_2d<f32>;

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let texSize = vec2<f32>(textureDimensions(srcTex));
    let texel = 1.0 / texSize;
    let x = texel.x;
    let y = texel.y;

    let a = textureSample(srcTex, srcSamp, uv + vec2<f32>(-x,  y)).rgb;
    let b = textureSample(srcTex, srcSamp, uv + vec2<f32>( 0,  y)).rgb;
    let c = textureSample(srcTex, srcSamp, uv + vec2<f32>( x,  y)).rgb;
    let d = textureSample(srcTex, srcSamp, uv + vec2<f32>(-x,  0)).rgb;
    let e = textureSample(srcTex, srcSamp, uv).rgb;
    let f = textureSample(srcTex, srcSamp, uv + vec2<f32>( x,  0)).rgb;
    let g = textureSample(srcTex, srcSamp, uv + vec2<f32>(-x, -y)).rgb;
    let h = textureSample(srcTex, srcSamp, uv + vec2<f32>( 0, -y)).rgb;
    let i = textureSample(srcTex, srcSamp, uv + vec2<f32>( x, -y)).rgb;

    var result = e * 4.0;
    result += (b + d + f + h) * 2.0;
    result += (a + c + g + i);
    result *= 1.0 / 16.0;
    return vec4<f32>(result, 1.0);
}
