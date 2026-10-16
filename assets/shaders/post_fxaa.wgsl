#include "common/fullscreen_vs.wgsl"

@group(0) @binding(0) var srcSamp: sampler;
@group(0) @binding(1) var srcTex: texture_2d<f32>;

fn luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.299, 0.587, 0.114));
}

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let texSize = vec2<f32>(textureDimensions(srcTex));
    let texel = 1.0 / texSize;

    let rgbM = textureSample(srcTex, srcSamp, uv).rgb;
    let rgbNW = textureSample(srcTex, srcSamp, uv + vec2<f32>(-texel.x, -texel.y)).rgb;
    let rgbNE = textureSample(srcTex, srcSamp, uv + vec2<f32>( texel.x, -texel.y)).rgb;
    let rgbSW = textureSample(srcTex, srcSamp, uv + vec2<f32>(-texel.x,  texel.y)).rgb;
    let rgbSE = textureSample(srcTex, srcSamp, uv + vec2<f32>( texel.x,  texel.y)).rgb;

    let lumaM = luma(rgbM);
    let lumaMin = min(lumaM, min(min(luma(rgbNW), luma(rgbNE)), min(luma(rgbSW), luma(rgbSE))));
    let lumaMax = max(lumaM, max(max(luma(rgbNW), luma(rgbNE)), max(luma(rgbSW), luma(rgbSE))));
    let range = lumaMax - lumaMin;
    if (range < max(0.0312, lumaMax * 0.125)) {
        return vec4<f32>(rgbM, 1.0);
    }

    let dir = vec2<f32>(
        -((luma(rgbNW) + luma(rgbNE)) - (luma(rgbSW) + luma(rgbSE))),
         ((luma(rgbNW) + luma(rgbSW)) - (luma(rgbNE) + luma(rgbSE))),
    );
    let dirReduce = max((luma(rgbNW) + luma(rgbNE) + luma(rgbSW) + luma(rgbSE)) * 0.03125, 0.0078125);
    let rcpDir = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    var d = clamp(dir * rcpDir, vec2<f32>(-8.0), vec2<f32>(8.0)) * texel;

    let rgbA = 0.5 * (
        textureSample(srcTex, srcSamp, uv + d * (1.0 / 3.0 - 0.5)).rgb +
        textureSample(srcTex, srcSamp, uv + d * (2.0 / 3.0 - 0.5)).rgb);
    let rgbB = rgbA * 0.5 + 0.25 * (
        textureSample(srcTex, srcSamp, uv + d * -0.5).rgb +
        textureSample(srcTex, srcSamp, uv + d *  0.5).rgb);
    let lumaB = luma(rgbB);
    if (lumaB < lumaMin || lumaB > lumaMax) {
        return vec4<f32>(rgbA, 1.0);
    }
    return vec4<f32>(rgbB, 1.0);
}
