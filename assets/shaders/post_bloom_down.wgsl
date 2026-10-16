#include "common/fullscreen_vs.wgsl"

@group(0) @binding(0) var srcSamp: sampler;
@group(0) @binding(1) var srcTex: texture_2d<f32>;

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let texSize = vec2<f32>(textureDimensions(srcTex));
    let texel = 1.0 / texSize;
    let x = texel.x;
    let y = texel.y;

    let a = textureSample(srcTex, srcSamp, uv + vec2<f32>(-2.0*x,  2.0*y)).rgb;
    let b = textureSample(srcTex, srcSamp, uv + vec2<f32>( 0.0,    2.0*y)).rgb;
    let c = textureSample(srcTex, srcSamp, uv + vec2<f32>( 2.0*x,  2.0*y)).rgb;
    let d = textureSample(srcTex, srcSamp, uv + vec2<f32>(-2.0*x,  0.0  )).rgb;
    let e = textureSample(srcTex, srcSamp, uv).rgb;
    let f = textureSample(srcTex, srcSamp, uv + vec2<f32>( 2.0*x,  0.0  )).rgb;
    let g = textureSample(srcTex, srcSamp, uv + vec2<f32>(-2.0*x, -2.0*y)).rgb;
    let h = textureSample(srcTex, srcSamp, uv + vec2<f32>( 0.0,   -2.0*y)).rgb;
    let i = textureSample(srcTex, srcSamp, uv + vec2<f32>( 2.0*x, -2.0*y)).rgb;
    let j = textureSample(srcTex, srcSamp, uv + vec2<f32>(-x,  y)).rgb;
    let k = textureSample(srcTex, srcSamp, uv + vec2<f32>( x,  y)).rgb;
    let l = textureSample(srcTex, srcSamp, uv + vec2<f32>(-x, -y)).rgb;
    let m = textureSample(srcTex, srcSamp, uv + vec2<f32>( x, -y)).rgb;

    var result = e * 0.125;
    result += (a + c + g + i) * 0.03125;
    result += (b + d + f + h) * 0.0625;
    result += (j + k + l + m) * 0.125;
    return vec4<f32>(result, 1.0);
}
