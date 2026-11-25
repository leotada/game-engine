#include "common/fullscreen_vs.wgsl"

struct Params {
    exposure: f32,
    bloomStrength: f32,
    tonemapMode: f32,
    bloomScreen: f32,
    saturation: f32,
    contrast: f32,
    outputTransfer: f32,
    _pad1: f32,
#ifdef GRADED
    // color table: domain min, strength | 1 / domain size, entries per side
    lutMin: vec4<f32>,
    lutScale: vec4<f32>,
#endif
};
@group(0) @binding(0) var<uniform> p: Params;
@group(0) @binding(1) var srcSamp: sampler;
@group(0) @binding(2) var sceneTex: texture_2d<f32>;
@group(0) @binding(3) var bloomTex: texture_2d<f32>;
#ifdef GRADED
// [0] = auto exposure (`auto_exposure.wgsl`)
@group(0) @binding(4) var<storage, read> autoExposure: array<f32>;
@group(0) @binding(5) var lutTex: texture_3d<f32>;

fn colorTable(c: vec3<f32>) -> vec3<f32> {
    if (p.lutMin.w <= 0.0) { return c; }
    let n = p.lutScale.w;
    let t = clamp((c - p.lutMin.xyz) * p.lutScale.xyz, vec3<f32>(0.0), vec3<f32>(1.0));
    let v = textureSampleLevel(lutTex, srcSamp, (t * (n - 1.0) + 0.5) / n, 0.0).rgb;
    return clamp(mix(c, v, p.lutMin.w), vec3<f32>(0.0), vec3<f32>(1.0));
}
#endif

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

fn agxDefaultContrastApprox(x: vec3<f32>) -> vec3<f32> {
    let x2 = x * x;
    let x4 = x2 * x2;
    return 15.5 * x4 * x2
        - 40.14 * x4 * x
        + 31.96 * x4
        - 6.868 * x2 * x
        + 0.4298 * x2
        + 0.1191 * x
        - 0.00232;
}

fn agx(val: vec3<f32>) -> vec3<f32> {
    let agx_mat = mat3x3<f32>(
        vec3<f32>(0.842479062253094, 0.0423282422610123, 0.0423756549057051),
        vec3<f32>(0.0784335999999992, 0.878468636469772, 0.0784336),
        vec3<f32>(0.0792237451477643, 0.0791661274605434, 0.879142973793104)
    );
    let agx_mat_inv = mat3x3<f32>(
        vec3<f32>( 1.19687900512017,  -0.0528968517574562, -0.0529716355144438),
        vec3<f32>(-0.0980208811401368, 1.15190312990417,   -0.0980434501171241),
        vec3<f32>(-0.0990297440797205, -0.0989611768448433,  1.15107367264116)
    );
    let min_ev = -12.47393;
    let max_ev = 4.026069;
    var v = max(agx_mat * max(val, vec3<f32>(0.0)), vec3<f32>(1e-10));
    v = clamp((log2(v) - min_ev) / (max_ev - min_ev), vec3<f32>(0.0), vec3<f32>(1.0));
    v = agxDefaultContrastApprox(v);
    v = agx_mat_inv * v;
    return clamp(v, vec3<f32>(0.0), vec3<f32>(1.0));
}

@fragment
fn fs_main(@location(0) uv: vec2<f32>) -> @location(0) vec4<f32> {
    var hdr = textureSample(sceneTex, srcSamp, uv).rgb;
    let bloom = textureSample(bloomTex, srcSamp, uv).rgb;
    let screenBloom = p.bloomScreen > 0.5;
    if (!screenBloom) {
        hdr = hdr + bloom * p.bloomStrength;
    }
    hdr = hdr * p.exposure;
#ifdef GRADED
    hdr = hdr * autoExposure[0];
#endif
    var ldr: vec3<f32>;
    if (p.tonemapMode < 0.5) {
        ldr = acesNarkowicz(hdr);
    } else if (p.tonemapMode < 1.5) {
        ldr = reinhard(hdr);
    } else if (p.tonemapMode < 2.5) {
        ldr = clamp(hdr, vec3<f32>(0.0), vec3<f32>(1.0));
    } else {
        ldr = agx(hdr);
    }
    if (screenBloom) {
        let glow = clamp(bloom * p.bloomStrength, vec3<f32>(0.0), vec3<f32>(1.0));
        ldr = vec3<f32>(1.0) - (vec3<f32>(1.0) - ldr) * (vec3<f32>(1.0) - glow);
    }
    ldr = clamp((ldr - vec3<f32>(0.5)) * p.contrast + vec3<f32>(0.5), vec3<f32>(0.0), vec3<f32>(1.0));
    let luma = dot(ldr, vec3<f32>(0.2126, 0.7152, 0.0722));
    ldr = clamp(mix(vec3<f32>(luma), ldr, p.saturation), vec3<f32>(0.0), vec3<f32>(1.0));
    if (p.outputTransfer > 0.5) {
        ldr = select(1.055 * pow(ldr, vec3<f32>(1.0 / 2.4)) - 0.055, ldr * 12.92, ldr <= vec3<f32>(0.0031308));
    } else {
        // Approximate linear → sRGB
        ldr = pow(max(ldr, vec3<f32>(0.0)), vec3<f32>(1.0 / 2.2));
    }
#ifdef GRADED
    ldr = colorTable(ldr);
#endif
    return vec4<f32>(ldr, 1.0);
}
