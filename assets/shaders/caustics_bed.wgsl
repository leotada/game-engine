/// Procedural submerged riverbed & seabed shader with animated RGB Voronoi caustics,
/// world-space multi-scale gravel/sandbar synthesis, and OpenPBR shadowed lighting.

#include "common/pbr_brdf.wgsl"
#include "common/shadows.wgsl"
#include "common/water_env.wgsl"

@group(1) @binding(0) var<uniform> wu: WaterUniforms;

@group(2) @binding(0) var irradianceMap: texture_cube<f32>;
@group(2) @binding(1) var specularMap: texture_cube<f32>;
@group(2) @binding(2) var brdfLut: texture_2d<f32>;
@group(2) @binding(3) var iblSampler: sampler;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
};

struct VertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) worldPos: vec3<f32>,
    @location(1) worldNormal: vec3<f32>,
};

@vertex
fn vs_main(v: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.worldPos = v.position;
    out.worldNormal = normalize(v.normal);
    out.clipPos = frame.viewProj * vec4<f32>(v.position, 1.0);
    return out;
}

/// Procedural heightfield of sand ripples and fine gravel for analytical bed normals.
fn evalBedHeight(xz: vec2<f32>, riverMode: u32) -> f32 {
    let coarse = fbm2(xz * 0.42);
    let gravel = fbm2(xz * 3.1 + vec2<f32>(4.2, 1.7));
    let rippleFreq = select(vec2<f32>(1.1, 0.4), vec2<f32>(0.55, 1.85), riverMode != 0u);
    let sandRipple = sin(dot(xz, rippleFreq) + coarse * 3.4) * 0.5 + 0.5;
    return coarse * 0.55 + gravel * 0.30 + sandRipple * 0.15;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let riverMode = wu.flags0.x;
    let time = wu.params0.x;
    let V = normalize(frame.cameraPos - in.worldPos);

    // Multi-scale procedural sand / river gravel palette + analytical bump normal.
    let xz = in.worldPos.xz;
    let eps = 0.04;
    let h0 = evalBedHeight(xz, riverMode);
    let hx = evalBedHeight(xz + vec2<f32>(eps, 0.0), riverMode);
    let hz = evalBedHeight(xz + vec2<f32>(0.0, eps), riverMode);
    let bumpStrength = 0.45;
    let N = normalize(vec3<f32>((h0 - hx) / eps * bumpStrength, 1.0, (h0 - hz) / eps * bumpStrength));

    let up = vec3<f32>(0.0, 0.0, 1.0);
    let T = normalize(cross(up, N));
    let B = cross(N, T);

    let pebbleMask = smoothstep(0.54, 0.72, valueNoise2(xz * 4.8));
    let siltNoise  = fbm2(xz * 0.65 + vec2<f32>(11.0, 3.5));

    var sandCol = vec3<f32>(0.18, 0.16, 0.12);
    var rockCol = vec3<f32>(0.09, 0.09, 0.085);
    if (riverMode != 0u) {
        sandCol = vec3<f32>(0.15, 0.13, 0.10);
        rockCol = vec3<f32>(0.08, 0.08, 0.075);
    }
    var baseColor = mix(sandCol, rockCol, pebbleMask * 0.78);
    baseColor *= 0.78 + 0.42 * siltNoise;

    let rough = clamp(mix(0.84, 0.62, pebbleMask), 0.30, 0.96);
    let NdotV = max(dot(N, V), 0.001);
    let lut = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, rough)).rg;

    var pbrIn: OpenPbrEvalInput;
    pbrIn.N = N;
    pbrIn.T = T;
    pbrIn.B = B;
    pbrIn.V = V;
    pbrIn.baseColor = baseColor;
    pbrIn.metalness = 0.0;
    pbrIn.diffuseRoughness = 0.88;
    pbrIn.specularWeight = 0.6;
    pbrIn.specularRoughness = rough;
    pbrIn.specularColor = vec3<f32>(1.0);
    pbrIn.specularIor = 1.48;
    pbrIn.specularAnisotropy = 0.0;
    pbrIn.coatWeight = 0.0;
    pbrIn.coatColor = vec3<f32>(1.0);
    pbrIn.coatRoughness = 0.2;
    pbrIn.coatIor = 1.333;
    pbrIn.coatDarkening = 0.0;
    pbrIn.fuzzWeight = 0.0;
    pbrIn.fuzzColor = vec3<f32>(1.0);
    pbrIn.fuzzRoughness = 0.5;
    pbrIn.thinFilmWeight = 0.0;
    pbrIn.thinFilmThickness = 500.0;
    pbrIn.thinFilmIor = 1.4;
    pbrIn.directionalAlbedo = clamp(lut.r + lut.g, 0.05, 1.0);
    pbrIn.fuzzAlbedo = 0.0;

    var direct = vec3<f32>(0.0);
    var dirShadow = 1.0;
    var sunL = vec3<f32>(0.0, 1.0, 0.0);
    var sunRad = vec3<f32>(1.0);
    if (frame.dirEnabled != 0u) {
        sunL = normalize(frame.dirLight.direction);
        sunRad = frame.dirLight.color * frame.dirLight.intensity;
        if (frame.dirLight.castShadows != 0u) {
            dirShadow = sampleDirShadowPCF(in.worldPos, N, sunL);
        }
        direct += evalOpenPbrDirect(pbrIn, sunL, sunRad) * dirShadow;
    }

    let sc = min(frame.spotCount, 4u);
    for (var i = 0u; i < sc; i++) {
        let sl = frame.spots[i];
        let toLight = sl.position - in.worldPos;
        let dist = length(toLight);
        if (dist >= sl.range) {
            continue;
        }
        let L = toLight / dist;
        let theta = dot(normalize(-sl.direction), L);
        let epsilon = max(sl.innerConeCos - sl.outerConeCos, 0.001);
        let cone = clamp((theta - sl.outerConeCos) / epsilon, 0.0, 1.0);
        if (cone <= 0.0) {
            continue;
        }
        let atten = rangeAttenuation(dist, sl.range) * cone * cone;
        let shadow = sampleSpotShadowPCF(sl.shadowSlot, sl.viewProj, in.worldPos, N, L);
        direct += evalOpenPbrDirect(pbrIn, L, sl.color * sl.intensity * atten) * shadow;
    }

    let irradiance = textureSample(irradianceMap, iblSampler, N).rgb;
    let ambient = irradiance * baseColor * 0.85;

    // Animated chromatically dispersed solar caustics gated by direct sun shadow & water channel.
    let caustics = evalCausticsRgb(in.worldPos, sunL, time, riverMode);
    let channelMask = select(1.0, smoothstep(7.2, 4.8, abs(xz.y)), riverMode != 0u);
    let waveEnergy = 0.65 + 0.35 * wu.params0.y;
    let causticLight = caustics * sunRad * dirShadow * max(N.y, 0.0) * channelMask * waveEnergy * 0.24;

    // Physical underwater Beer-Lambert column absorption from bed up to y=0.
    let bedDepth = max(-in.worldPos.y, 0.05) / max(abs(V.y), 0.30);
    let sigma = select(vec3<f32>(1.45, 0.52, 0.30), vec3<f32>(1.20, 0.42, 0.48), riverMode != 0u);
    let bedTrans = exp(-sigma * min(bedDepth, 3.2));
    let rawColor = max(direct + ambient + causticLight * (0.35 + baseColor), vec3<f32>(0.0));
    let scatterCol = select(vec3<f32>(0.012, 0.065, 0.115), vec3<f32>(0.018, 0.10, 0.09), riverMode != 0u);
    let color = mix(scatterCol, rawColor * bedTrans, 0.82);
    return vec4<f32>(color, 1.0);
}
