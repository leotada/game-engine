/// Chunked heightmap terrain with PBR splatting (`engine.terrain.renderer`).
/// Group 0 = scene frame (CSM, lights, fog, wetness), group 1 = terrain,
/// group 2 = scene IBL. Up to 8 layers from two RGBA8 splat planes; the four
/// heaviest are height-blended per pixel, with triplanar projection on steep
/// slopes and a second, larger UV scale in the distance to hide tiling. Layers
/// may use hex-tiling (`common/hex_tiling.wgsl`) on flat ground, and a world-space
/// macro noise varies brightness, saturation and roughness over tens of meters.
/// Every layer fetch uses `textureSampleGrad` (derivatives taken up front),
/// so the data-dependent loop stays valid under WGSL uniformity rules.

#include "common/pbr_brdf.wgsl"
#include "common/shadows.wgsl"
#include "common/atmosphere.wgsl"
#include "common/simple_pbr.wgsl"
#include "common/terrain_common.wgsl"
#include "common/hex_tiling.wgsl"

@group(1) @binding(1) var layerSampler: sampler;
@group(1) @binding(3) var normalTex: texture_2d<f32>;
@group(1) @binding(4) var splatTex: texture_2d_array<f32>;
@group(1) @binding(5) var albedoArr: texture_2d_array<f32>;
@group(1) @binding(6) var normalArr: texture_2d_array<f32>;
@group(1) @binding(7) var ormArr: texture_2d_array<f32>;
@group(1) @binding(8) var clampSampler: sampler;


/// Write `1 - ambient share of the color` to alpha (GTAO).
override AMBIENT_ALPHA: bool = false;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) worldPos: vec3<f32>,
    @location(1) mapUv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) vi: u32, @location(0) inst: vec4<f32>) -> VsOut {
    let v = terrainVertex(vi, inst);
    var out: VsOut;
    out.pos = frame.viewProj * vec4<f32>(v.worldPos, 1.0);
    out.worldPos = v.shadePos;
    out.mapUv = (v.samplePos + vec2<f32>(0.5)) / tp.grid.xy;
    return out;
}

fn layerParam(a: vec4<f32>, b: vec4<f32>, i: u32) -> f32 {
    if (i < 4u) {
        return a[i];
    }
    return b[i - 4u];
}

struct LayerSample {
    albedo: vec4<f32>,
    normal: vec3<f32>,
    orm: vec3<f32>,
};

fn tangentToWorldY(tn: vec3<f32>, N: vec3<f32>) -> vec3<f32> {
    // Whiteout blend for the XZ (top-down) projection.
    return vec3<f32>(tn.x + N.x, abs(tn.z) * N.y, tn.y + N.z);
}

fn sampleLayer(i: u32, P: vec3<f32>, dPx: vec3<f32>, dPy: vec3<f32>, N: vec3<f32>, farK: f32) -> LayerSample {
    let sc = layerParam(tp.uvScale0, tp.uvScale1, i);
    let sharp = layerParam(tp.triplanar0, tp.triplanar1, i);
    let li = i32(i);
    var r: LayerSample;
    if (sharp > 0.0 && N.y < 0.8) {
        var bw = pow(abs(N), vec3<f32>(sharp));
        bw = bw / max(bw.x + bw.y + bw.z, 1e-4);
        let uvX = P.zy * sc;
        let uvY = P.xz * sc;
        let uvZ = P.xy * sc;
        let aX = textureSampleGrad(albedoArr, layerSampler, uvX, li, dPx.zy * sc, dPy.zy * sc);
        let aY = textureSampleGrad(albedoArr, layerSampler, uvY, li, dPx.xz * sc, dPy.xz * sc);
        let aZ = textureSampleGrad(albedoArr, layerSampler, uvZ, li, dPx.xy * sc, dPy.xy * sc);
        let nX = textureSampleGrad(normalArr, layerSampler, uvX, li, dPx.zy * sc, dPy.zy * sc).xyz * 2.0 - 1.0;
        let nY = textureSampleGrad(normalArr, layerSampler, uvY, li, dPx.xz * sc, dPy.xz * sc).xyz * 2.0 - 1.0;
        let nZ = textureSampleGrad(normalArr, layerSampler, uvZ, li, dPx.xy * sc, dPy.xy * sc).xyz * 2.0 - 1.0;
        let oX = textureSampleGrad(ormArr, layerSampler, uvX, li, dPx.zy * sc, dPy.zy * sc).rgb;
        let oY = textureSampleGrad(ormArr, layerSampler, uvY, li, dPx.xz * sc, dPy.xz * sc).rgb;
        let oZ = textureSampleGrad(ormArr, layerSampler, uvZ, li, dPx.xy * sc, dPy.xy * sc).rgb;
        r.albedo = aX * bw.x + aY * bw.y + aZ * bw.z;
        let wX = vec3<f32>(nX.xy + N.zy, abs(nX.z) * N.x).zyx;
        let wY = tangentToWorldY(nY, N);
        let wZ = vec3<f32>(nZ.xy + N.xy, abs(nZ.z) * N.z);
        r.normal = normalize(wX * bw.x + wY * bw.y + wZ * bw.z);
        r.orm = oX * bw.x + oY * bw.y + oZ * bw.z;
    } else {
        let uv = P.xz * sc;
        let gx = dPx.xz * sc;
        let gy = dPy.xz * sc;
        let hexRot = layerParam(tp.hexRotation0, tp.hexRotation1, i);
        if (hexRot >= 0.0) {
            let ht = hexTiles(uv, hexRot);
            let ar = hexSampleArray(albedoArr, layerSampler, li, ht, gx, gy);
            let hw = hexWeights(ht, ar.r0.rgb, ar.r1.rgb, ar.r2.rgb, 0.6);
            var a = hexBlend(ar, hw);
            if (farK > 0.001) {
                let ds = tp.misc.z;
                let aFar = textureSampleGrad(albedoArr, layerSampler, uv * ds, li, gx * ds, gy * ds);
                a = vec4<f32>(mix(a.rgb, aFar.rgb, farK * 0.6), a.a);
            }
            r.albedo = a;
            let tn = hexBlendNormal(hexSampleArray(normalArr, layerSampler, li, ht, gx, gy), ht, hw, false);
            r.normal = normalize(tangentToWorldY(tn, N));
            r.orm = hexBlend(hexSampleArray(ormArr, layerSampler, li, ht, gx, gy), hw).rgb;
            return r;
        }
        var a = textureSampleGrad(albedoArr, layerSampler, uv, li, gx, gy);
        if (farK > 0.001) {
            let ds = tp.misc.z;
            let aFar = textureSampleGrad(albedoArr, layerSampler, uv * ds, li, gx * ds, gy * ds);
            a = vec4<f32>(mix(a.rgb, aFar.rgb, farK * 0.6), a.a);
        }
        r.albedo = a;
        let tn = textureSampleGrad(normalArr, layerSampler, uv, li, gx, gy).xyz * 2.0 - 1.0;
        r.normal = normalize(tangentToWorldY(tn, N));
        r.orm = textureSampleGrad(ormArr, layerSampler, uv, li, gx, gy).rgb;
    }
    return r;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let P = in.worldPos;
    let dPx = dpdx(P);
    let dPy = dpdy(P);
    let Ng = normalize(textureSample(normalTex, clampSampler, in.mapUv).xyz * 2.0 - 1.0);
    let s0 = textureSample(splatTex, clampSampler, in.mapUv, 0);
    let s1 = textureSample(splatTex, clampSampler, in.mapUv, 1);
    var w = array<f32, 8>(s0.x, s0.y, s0.z, s0.w, s1.x, s1.y, s1.z, s1.w);
    let layerCount = min(u32(tp.misc.x), 8u);

    let V = normalize(frame.cameraPos - P);
    let dist = distance(frame.cameraPos, P);
    let farK = smoothstep(40.0, 220.0, dist);

    // Pick the four heaviest layers.
    var picked = array<u32, 4>(0u, 0u, 0u, 0u);
    var pw = array<f32, 4>(0.0, 0.0, 0.0, 0.0);
    for (var k = 0u; k < 4u; k++) {
        var best = 0u;
        var bv = -1.0;
        for (var i = 0u; i < layerCount; i++) {
            if (w[i] > bv) {
                bv = w[i];
                best = i;
            }
        }
        picked[k] = best;
        pw[k] = max(bv, 0.0);
        w[best] = -1.0;
    }

    // Height blend.
    var samples: array<LayerSample, 4>;
    var t = array<f32, 4>(-1.0, -1.0, -1.0, -1.0);
    var tmax = -1.0;
    for (var k = 0u; k < 4u; k++) {
        if (pw[k] < 0.004) {
            continue;
        }
        let ls = sampleLayer(picked[k], P, dPx, dPy, Ng, farK);
        samples[k] = ls;
        let hb = layerParam(tp.heightBlend0, tp.heightBlend1, picked[k]);
        t[k] = pw[k] + ls.albedo.a * hb * 0.5;
        tmax = max(tmax, t[k]);
    }
    let depth = max(tp.misc.y, 1e-3);
    var albedo = vec3<f32>(0.0);
    var nsum = vec3<f32>(0.0);
    var orm = vec3<f32>(0.0);
    var bsum = 0.0;
    for (var k = 0u; k < 4u; k++) {
        if (t[k] < 0.0) {
            continue;
        }
        let b = max(t[k] - (tmax - depth), 0.0);
        albedo += samples[k].albedo.rgb * b;
        nsum += samples[k].normal * b;
        orm += samples[k].orm * b;
        bsum += b;
    }
    bsum = max(bsum, 1e-4);
    albedo /= bsum;
    orm /= bsum;
    var N = normalize(mix(Ng, normalize(nsum), clamp(tp.misc.w, 0.0, 1.0)));

    var roughness = clamp(orm.g, 0.04, 1.0);
    if (tp.macroVar.z > 0.0) {
        // Two octaves for brightness and roughness, a third, offset field for saturation.
        let q = P.xz * tp.macroVar.z;
        let m = hexValueNoise(q) * 0.65 + hexValueNoise(q * 2.7 + vec2<f32>(17.3, 5.1)) * 0.35 - 0.5;
        let ms = hexValueNoise(q * 0.8 + vec2<f32>(-41.7, 23.9)) - 0.5;
        albedo *= 1.0 + m * 2.0 * tp.macroVar.x;
        let lum = dot(albedo, vec3<f32>(0.2126, 0.7152, 0.0722));
        albedo = max(mix(vec3<f32>(lum), albedo, 1.0 + ms * 2.0 * tp.macroVar.w), vec3<f32>(0.0));
        roughness = clamp(roughness - m * 2.0 * tp.macroVar.y, 0.04, 1.0);
    }
    let metallic = clamp(orm.b, 0.0, 1.0);
    let ao = orm.r;

    // Rain wetness: darker, glossier, flatter normals on rain-facing ground.
    let wet = clamp(frame.globalWetness, 0.0, 1.0) * smoothstep(0.3, 0.8, Ng.y);
    albedo *= mix(1.0, 0.55, wet);
    roughness = mix(roughness, 0.08, wet * 0.9);
    N = normalize(mix(N, Ng, wet * 0.6));
    // Grazing views: keep detail normals from facing away from the camera
    // (dark speckles along hill crests).
    let nv = dot(N, V);
    if (nv < 0.05) {
        N = normalize(N + V * (0.05 - nv));
    }

    let light = shadeSimplePbrParts(P, N, Ng, V, in.pos.xy, albedo, metallic, roughness, ao);
    var color = (light.direct + light.ambient) * cascadeDebugTint(P);
    color = applyFog(color, P);
    if (AMBIENT_ALPHA) {
        return vec4<f32>(color, ambientAlpha(attenuateByFog(light.ambient, P), color));
    }
    return vec4<f32>(color, 1.0);
}
