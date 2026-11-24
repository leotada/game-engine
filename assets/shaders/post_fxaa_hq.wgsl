/// Quality FXAA: detects the edge direction, walks along the edge to find both
/// ends, shifts the sample by the sub-pixel coverage and blends a configurable
/// amount of sub-pixel smoothing. Written from the published description of
/// Timothy Lottes' FXAA 3.x algorithm. Input is display-encoded color.

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

const STEP_COUNT: i32 = 12;
const STEPS = array<f32, 12>(1.0, 1.0, 1.0, 1.0, 1.0, 1.5, 2.0, 2.0, 2.0, 2.0, 4.0, 8.0);

fn luma(c: vec3<f32>) -> f32 {
    return dot(c, vec3<f32>(0.299, 0.587, 0.114));
}

fn lumaAt(uv: vec2<f32>) -> f32 {
    return luma(textureSampleLevel(srcTex, srcSamp, uv, 0.0).rgb);
}

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    let texel = 1.0 / vec2<f32>(textureDimensions(srcTex));
    let rgbM = textureSampleLevel(srcTex, srcSamp, uv, 0.0).rgb;
    let m = luma(rgbM);
    let n = lumaAt(uv + vec2<f32>(0.0, -texel.y));
    let s = lumaAt(uv + vec2<f32>(0.0, texel.y));
    let w = lumaAt(uv + vec2<f32>(-texel.x, 0.0));
    let e = lumaAt(uv + vec2<f32>(texel.x, 0.0));
    let hi = max(m, max(max(n, s), max(w, e)));
    let lo = min(m, min(min(n, s), min(w, e)));
    let range = hi - lo;
    if (range < max(p.edgeThresholdMin, hi * p.edgeThreshold)) {
        return vec4<f32>(rgbM, 1.0);
    }

    let nw = lumaAt(uv + vec2<f32>(-texel.x, -texel.y));
    let ne = lumaAt(uv + vec2<f32>(texel.x, -texel.y));
    let sw = lumaAt(uv + vec2<f32>(-texel.x, texel.y));
    let se = lumaAt(uv + vec2<f32>(texel.x, texel.y));

    let edgeH = abs(nw + sw - 2.0 * w) + 2.0 * abs(n + s - 2.0 * m) + abs(ne + se - 2.0 * e);
    let edgeV = abs(nw + ne - 2.0 * n) + 2.0 * abs(w + e - 2.0 * m) + abs(sw + se - 2.0 * s);
    let horizontal = edgeH >= edgeV;

    // The side of the pixel the edge lies on.
    let l1 = select(w, n, horizontal);
    let l2 = select(e, s, horizontal);
    let g1 = abs(l1 - m);
    let g2 = abs(l2 - m);
    let first = g1 >= g2;
    var perp = select(vec2<f32>(texel.x, 0.0), vec2<f32>(0.0, texel.y), horizontal);
    if (first) {
        perp = -perp;
    }
    let edgeLuma = 0.5 * (m + select(l2, l1, first));
    let gradient = 0.25 * max(g1, g2);

    // Walk both ways along the edge, half a pixel off the center line.
    let along = select(vec2<f32>(0.0, texel.y), vec2<f32>(texel.x, 0.0), horizontal);
    let base = uv + 0.5 * perp;
    var uv1 = base;
    var uv2 = base;
    var d1 = 0.0;
    var d2 = 0.0;
    var done1 = false;
    var done2 = false;
    for (var i = 0; i < STEP_COUNT; i++) {
        if (!done1) {
            uv1 -= along * STEPS[i];
            d1 = lumaAt(uv1) - edgeLuma;
            done1 = abs(d1) >= gradient;
        }
        if (!done2) {
            uv2 += along * STEPS[i];
            d2 = lumaAt(uv2) - edgeLuma;
            done2 = abs(d2) >= gradient;
        }
        if (done1 && done2) {
            break;
        }
    }

    let dist1 = select(uv.y - uv1.y, uv.x - uv1.x, horizontal);
    let dist2 = select(uv2.y - uv.y, uv2.x - uv.x, horizontal);
    let nearFirst = dist1 < dist2;
    let endDelta = select(d2, d1, nearFirst);
    // Shift only when the luma at the closer end varies the right way.
    let correct = (endDelta < 0.0) != (m < edgeLuma);
    let edgeOffset = select(0.0, 0.5 - min(dist1, dist2) / (dist1 + dist2), correct);

    // Sub-pixel smoothing of thin features.
    let avg = (2.0 * (n + s + e + w) + nw + ne + sw + se) / 12.0;
    let sub = saturate(abs(avg - m) / range);
    let subS = (3.0 - 2.0 * sub) * sub * sub;
    let subOffset = subS * subS * p.subpix;

    let finalUv = uv + perp * max(edgeOffset, subOffset);
    return vec4<f32>(textureSampleLevel(srcTex, srcSamp, finalUv, 0.0).rgb, 1.0);
}
