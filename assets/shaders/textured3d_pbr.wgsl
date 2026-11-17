#include "common/shadows.wgsl"

struct MaterialParams {
    baseColor: vec3<f32>,
    baseWeight: f32,

    baseMetalness: f32,
    baseDiffuseRoughness: f32,
    specularWeight: f32,
    specularRoughness: f32,

    specularColor: vec3<f32>,
    specularIor: f32,

    specularAnisotropy: f32,
    coatWeight: f32,
    coatRoughness: f32,
    coatIor: f32,

    coatColor: vec3<f32>,
    coatDarkening: f32,

    fuzzColor: vec3<f32>,
    fuzzWeight: f32,

    fuzzRoughness: f32,
    thinFilmWeight: f32,
    thinFilmThickness: f32,
    thinFilmIor: f32,

    emissionColor: vec3<f32>,
    emissionLuminance: f32,

    geometryOpacity: f32,
    flags: u32,
    _pad0: f32,
    _pad1: f32,
};
@group(1) @binding(0) var<uniform> mat: MaterialParams;
@group(1) @binding(1) var texSampler: sampler;
@group(1) @binding(2) var albedoMap: texture_2d<f32>;
@group(1) @binding(3) var mrMap: texture_2d<f32>;
@group(1) @binding(4) var normalMap: texture_2d<f32>;
@group(1) @binding(5) var occlusionMap: texture_2d<f32>;
@group(1) @binding(6) var emissiveMap: texture_2d<f32>;

@group(2) @binding(0) var irradianceMap: texture_cube<f32>;
@group(2) @binding(1) var specularMap: texture_cube<f32>;
@group(2) @binding(2) var brdfLut: texture_2d<f32>;
@group(2) @binding(3) var iblSampler: sampler;

const FLAG_MR: u32 = 1u;
const FLAG_NORMAL: u32 = 2u;
const FLAG_AO: u32 = 4u;
const FLAG_EMISSIVE: u32 = 8u;
const FLAG_WATER_WETLINE: u32 = 16u;
const FLAG_WATER_RIVER: u32 = 32u;

#include "common/pbr_brdf.wgsl"

#ifdef CUSTOM_SURFACE
/// Free per-material parameters for custom surface shaders
/// (`Material.updateSurfaceParams`).
struct SurfaceParams {
    p0: vec4<f32>,
    p1: vec4<f32>,
    p2: vec4<f32>,
    p3: vec4<f32>,
};
@group(1) @binding(7) var<uniform> surfaceParams: SurfaceParams;

/// What a custom `surface` function can read about the shaded point.
struct SurfaceIn {
    worldPos: vec3<f32>,
    localPos: vec3<f32>,
    worldNormal: vec3<f32>,
    localNormal: vec3<f32>,
    uv: vec2<f32>,
    tint: vec3<f32>,
    viewDir: vec3<f32>,
};

/// Surface description handed to the standard OpenPBR lighting. A custom
/// `surface` function receives the material defaults and returns its edits.
struct SurfaceOut {
    baseColor: vec3<f32>,
    metalness: f32,
    roughness: f32,
    emission: vec3<f32>,
    normal: vec3<f32>,
    opacity: f32,
    ao: f32,
};

// Game code is spliced in here by `composeSurfaceShader`. It must define
//   fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut
// and may define
//   fn displace(localPos: vec3<f32>, localNormal: vec3<f32>) -> vec3<f32>
//@@SURFACE_CODE@@
#endif

fn evalRiverBankMask(worldPos: vec3<f32>, isRiver: bool) -> f32 {
    if (!isRiver) {
        return 1.0;
    }
    let az = abs(worldPos.z);
    if (az <= 4.5) {
        return 1.0;
    }
    let t = clamp((az - 4.5) / 3.5, 0.0, 1.0);
    return 1.0 - t * 0.85;
}

/// Evaluates exact 6-octave Gerstner vertical elevation (with horizontal pullback and near-rock
/// chop) matching OCEAN_WAVES / RIVER_WAVES in water_surface.wgsl.
fn evalExactWaveY(worldPos: vec3<f32>, time: f32, waveScale: f32, isRiver: bool) -> f32 {
    let bankMask = evalRiverBankMask(worldPos, isRiver);

    var dirs: array<vec2<f32>, 6>;
    var lens: array<f32, 6>;
    var amps: array<f32, 6>;
    var stps: array<f32, 6>;
    var spds: array<f32, 6>;

    if (isRiver) {
        dirs = array<vec2<f32>, 6>(
            vec2<f32>(0.96, 0.28), vec2<f32>(0.92, -0.39), vec2<f32>(0.78, 0.62),
            vec2<f32>(0.85, -0.52), vec2<f32>(0.99, 0.14), vec2<f32>(0.72, -0.69)
        );
        lens = array<f32, 6>(4.4, 3.1, 2.1, 1.45, 0.95, 0.68);
        amps = array<f32, 6>(0.075, 0.055, 0.038, 0.024, 0.014, 0.009);
        stps = array<f32, 6>(0.40, 0.42, 0.44, 0.38, 0.34, 0.28);
        spds = array<f32, 6>(1.65, 1.80, 1.95, 2.15, 2.30, 2.45);
    } else {
        dirs = array<vec2<f32>, 6>(
            vec2<f32>(0.86, 0.51), vec2<f32>(0.42, -0.91), vec2<f32>(-0.68, 0.73),
            vec2<f32>(0.96, -0.28), vec2<f32>(-0.22, -0.97), vec2<f32>(0.61, 0.79)
        );
        lens = array<f32, 6>(9.5, 6.2, 4.1, 2.7, 1.8, 1.15);
        amps = array<f32, 6>(0.24, 0.14, 0.08, 0.045, 0.025, 0.015);
        stps = array<f32, 6>(0.52, 0.48, 0.44, 0.40, 0.35, 0.30);
        spds = array<f32, 6>(1.00, 1.15, 1.25, 1.35, 1.50, 1.65);
    }

    let rockChop = select(1.20, 1.38, isRiver);
    let waveSet = 0.68
                + 0.26 * sin(time * 0.62 - worldPos.x * 0.13 + worldPos.z * 0.16)
                + 0.18 * cos(time * 0.41 + worldPos.x * 0.19 + worldPos.z * 0.11);
    let phaseWarp = 0.85 * sin(worldPos.x * 0.21 - worldPos.z * 0.17 + time * 0.29)
                  + 0.55 * cos(worldPos.x * 0.14 + worldPos.z * 0.25 - time * 0.22);
    let scale = waveScale * bankMask * rockChop * waveSet;

    var dispXZ = vec2<f32>(0.0);
    for (var i = 0u; i < 6u; i++) {
        let k = 6.2831853 / lens[i];
        let c = sqrt(9.81 / k) * spds[i];
        let a = amps[i] * scale;
        let phase = k * dot(dirs[i], worldPos.xz) - k * c * time + phaseWarp * min(k * 0.45, 1.0);
        dispXZ += (stps[i] * a) * dirs[i] * cos(phase);
    }

    let xz = worldPos.xz - dispXZ;
    var y = 0.0;
    for (var i = 0u; i < 6u; i++) {
        let k = 6.2831853 / lens[i];
        let c = sqrt(9.81 / k) * spds[i];
        let a = amps[i] * scale;
        y += a * sin(k * dot(dirs[i], xz) - k * c * time + phaseWarp * min(k * 0.45, 1.0));
    }

    return y;
}

/// Evaluates water wetness [filmWet, poreWet] using fixed world-time snapshots (d(tau)/dt = 0):
/// - When a wave crest touches the rock, its imprint is locked at fixed world timestamp `tau`.
/// - As the wave recedes, the wet mark stays stationary at the peak height where water touched
///   (neither dropping with the trough nor sliding sideways) and dries in place over 4.8 seconds.
fn evalRecentWaterWetness(worldPos: vec3<f32>, time: f32, curScale: f32, recentPeakScale: f32,
                          isRiver: bool, wetNoise: f32) -> vec2<f32> {
    let yNow = evalExactWaveY(worldPos, time, curScale, isRiver);
    let nowMask = 1.0 - smoothstep(yNow - 0.015, yNow + 0.012 + wetNoise * 0.5, worldPos.y);
    var filmWet = nowMask;
    var poreWet = nowMask;

    let maxReachY = select(0.75, 0.38, isRiver) * max(curScale, recentPeakScale);
    if (worldPos.y > yNow - 0.005 && worldPos.y < maxReachY) {
        let dtStep = 0.20;
        let baseStep = floor(time / dtStep);
        for (var s = 0u; s < 24u; s++) {
            let tau = (baseStep - f32(s)) * dtStep;
            let age = max(time - tau, 0.0);
            let pastScale = mix(curScale, recentPeakScale, clamp(age / 1.5, 0.0, 1.0));
            let yPast = evalExactWaveY(worldPos, tau, pastScale, isRiver);
            let hitMask = 1.0 - smoothstep(yPast - 0.015, yPast + 0.015 + wetNoise, worldPos.y);

            let fd = clamp(1.0 - age / 3.4, 0.0, 1.0);
            let pd = clamp(1.0 - age / 4.8, 0.0, 1.0);
            let filmCurve = fd * fd * (3.0 - 2.0 * fd);
            let poreCurve = pd * pd * (3.0 - 2.0 * pd);

            filmWet = max(filmWet, hitMask * filmCurve * 0.95);
            poreWet = max(poreWet, hitMask * poreCurve * 0.96);
        }
    }
    return vec2<f32>(filmWet, poreWet);
}

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) model0: vec4<f32>,
    @location(4) model1: vec4<f32>,
    @location(5) model2: vec4<f32>,
    @location(6) model3: vec4<f32>,
    @location(7) tint: vec4<f32>,
#ifdef MESH_TANGENT
    @location(8) tangent: vec4<f32>,
#endif
};

struct VertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) worldPos: vec3<f32>,
    @location(1) worldNormal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) tint: vec3<f32>,
    @location(4) worldTangent: vec3<f32>,
    @location(5) worldBitangent: vec3<f32>,
    @location(6) localPos: vec3<f32>,
    @location(7) localNormal: vec3<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let model = mat4x4<f32>(in.model0, in.model1, in.model2, in.model3);
    var localPos = in.position;
#ifdef CUSTOM_SURFACE
//@@DISPLACE_CALL@@
#endif
    let worldPos4 = model * vec4<f32>(localPos, 1.0);
    let normalMat = mat3x3<f32>(model[0].xyz, model[1].xyz, model[2].xyz);
    var out: VertexOutput;
    out.clipPos = frame.viewProj * worldPos4;
    out.worldPos = worldPos4.xyz;
    let N = normalize(normalMat * in.normal);
    out.worldNormal = N;
#ifdef MESH_TANGENT
    let T = normalize(normalMat * in.tangent.xyz);
    out.worldTangent = T;
    out.worldBitangent = cross(N, T) * in.tangent.w;
#else
    var t = normalize(normalMat * vec3<f32>(1.0, 0.0, 0.0));
    if (abs(dot(t, N)) > 0.9) {
        t = normalize(normalMat * vec3<f32>(0.0, 0.0, 1.0));
    }
    out.worldTangent = normalize(t - N * dot(N, t));
    out.worldBitangent = cross(N, out.worldTangent);
#endif
    out.uv = in.uv;
    out.tint = in.tint.rgb;
    // Undisplaced object-space position: a stable domain for procedural noise.
    out.localPos = in.position;
    out.localNormal = in.normal;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let albedoSample = textureSample(albedoMap, texSampler, in.uv);
    var baseColor = albedoSample.rgb * mat.baseColor * in.tint * mat.baseWeight;
    var surfaceOpacity = albedoSample.a * mat.geometryOpacity;
    var metalness = mat.baseMetalness;
    var roughness = mat.specularRoughness;
    if ((mat.flags & FLAG_MR) != 0u) {
        let mr = textureSample(mrMap, texSampler, in.uv);
        roughness = clamp(roughness * mr.g, 0.04, 1.0);
        metalness = clamp(metalness * mr.b, 0.0, 1.0);
    } else {
        roughness = clamp(roughness, 0.04, 1.0);
        metalness = clamp(metalness, 0.0, 1.0);
    }

    var N = normalize(in.worldNormal);
    var T = normalize(in.worldTangent);
    var B = normalize(in.worldBitangent);
    if ((mat.flags & FLAG_NORMAL) != 0u) {
        let nSample = textureSample(normalMap, texSampler, in.uv).xyz * 2.0 - 1.0;
        let TBN = mat3x3<f32>(T, B, N);
        N = normalize(TBN * nSample);
        T = normalize(T - N * dot(N, T));
        B = cross(N, T);
    }

    var ao = 1.0;
    if ((mat.flags & FLAG_AO) != 0u) {
        ao = textureSample(occlusionMap, texSampler, in.uv).r;
    }

    var emissive = mat.emissionColor * mat.emissionLuminance;
    if ((mat.flags & FLAG_EMISSIVE) != 0u) {
        let emTex = textureSample(emissiveMap, texSampler, in.uv).rgb;
        emissive = emTex * mat.emissionColor * max(mat.emissionLuminance, 1.0);
    }

    let V = normalize(frame.cameraPos - in.worldPos);

#ifdef CUSTOM_SURFACE
    var surfIn: SurfaceIn;
    surfIn.worldPos = in.worldPos;
    surfIn.localPos = in.localPos;
    surfIn.worldNormal = N;
    surfIn.localNormal = normalize(in.localNormal);
    surfIn.uv = in.uv;
    surfIn.tint = in.tint;
    surfIn.viewDir = V;
    var surfBase: SurfaceOut;
    surfBase.baseColor = baseColor;
    surfBase.metalness = metalness;
    surfBase.roughness = roughness;
    surfBase.emission = emissive;
    surfBase.normal = N;
    surfBase.opacity = surfaceOpacity;
    surfBase.ao = ao;
    let surf = surface(surfIn, surfBase);
    baseColor = max(surf.baseColor, vec3<f32>(0.0));
    metalness = clamp(surf.metalness, 0.0, 1.0);
    roughness = clamp(surf.roughness, 0.04, 1.0);
    emissive = max(surf.emission, vec3<f32>(0.0));
    surfaceOpacity = surf.opacity;
    ao = clamp(surf.ao, 0.0, 1.0);
    N = normalize(surf.normal);
    T = normalize(T - N * dot(N, T));
    B = cross(N, T);
#endif

    let NdotV = max(dot(N, V), 0.001);

    let enableWaterFx = (mat.flags & FLAG_WATER_WETLINE) != 0u;
    let waterIsRiver = (mat.flags & FLAG_WATER_RIVER) != 0u;
    let waterTime = mat._pad0;
    let packedScale = mat._pad1;
    let waterScale = select(max(packedScale, 0.01), max(floor(packedScale) * 0.001, 0.01), packedScale >= 10.0);
    let recentPeakScale = select(waterScale, max(fract(packedScale) * 4.0, waterScale), packedScale >= 10.0);
    var coatW = mat.coatWeight;
    var coatR = mat.coatRoughness;
    var coatIor = mat.coatIor;
    var coatDark = mat.coatDarkening;
    var coatCol = mat.coatColor;
    var effectiveRoughness = coatRoughenBase(roughness, mat.coatRoughness, mat.coatWeight);

    if (enableWaterFx) {
        let wetNoise = (fract(sin(dot(in.worldPos.xz, vec2<f32>(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.015;
        let wetState = evalRecentWaterWetness(in.worldPos, waterTime, waterScale, recentPeakScale, waterIsRiver, wetNoise);
        let filmWet = wetState.x;
        let poreWet = wetState.y;
        let anyWet = max(filmWet, poreWet);
        // Apply water-film coat + damp darkening where waves touched within ~5 s; keep dry stone matte.
        coatW = max(mat.coatWeight, 0.92) * filmWet;
        coatDark = max(mat.coatDarkening, 0.76) * poreWet;
        coatR = mix(0.38, min(mat.coatRoughness, 0.055), filmWet);
        coatIor = mix(mat.coatIor, 1.333, anyWet);
        coatCol = mix(vec3<f32>(1.0), mix(mat.coatColor, vec3<f32>(0.84, 0.94, 0.95), 0.55), poreWet);
        let dryRough = clamp(max(roughness, 0.88), 0.04, 1.0);
        let dampRough = clamp(roughness * 0.58, 0.04, 1.0);
        let wetRough = coatRoughenBase(mix(dryRough, dampRough, poreWet), coatR, coatW);
        effectiveRoughness = mix(dryRough, wetRough, max(filmWet, poreWet * 0.65));
    }

    let lutBase = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, effectiveRoughness)).rgb;
    let directionalAlbedo = lutBase.r + lutBase.g;

    var fuzzE = 0.0;
    if (mat.fuzzWeight > 0.001) {
        let fuzzR = clamp(mat.fuzzRoughness, 0.04, 1.0);
        fuzzE = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, fuzzR)).b;
    }

    var pbrIn: OpenPbrEvalInput;
    pbrIn.N = N;
    pbrIn.T = T;
    pbrIn.B = B;
    pbrIn.V = V;
    pbrIn.baseColor = baseColor;
    pbrIn.metalness = metalness;
    pbrIn.diffuseRoughness = mat.baseDiffuseRoughness;
    pbrIn.specularWeight = mat.specularWeight;
    pbrIn.specularRoughness = effectiveRoughness;
    pbrIn.specularColor = mat.specularColor;
    pbrIn.specularIor = mat.specularIor;
    pbrIn.specularAnisotropy = mat.specularAnisotropy;
    pbrIn.coatWeight = coatW;
    pbrIn.coatColor = coatCol;
    pbrIn.coatRoughness = coatR;
    pbrIn.coatIor = coatIor;
    pbrIn.coatDarkening = coatDark;
    pbrIn.fuzzWeight = mat.fuzzWeight;
    pbrIn.fuzzColor = mat.fuzzColor;
    pbrIn.fuzzRoughness = mat.fuzzRoughness;
    pbrIn.thinFilmWeight = mat.thinFilmWeight;
    pbrIn.thinFilmThickness = mat.thinFilmThickness;
    pbrIn.thinFilmIor = mat.thinFilmIor;
    pbrIn.directionalAlbedo = directionalAlbedo;
    pbrIn.fuzzAlbedo = fuzzE;

    var direct = vec3<f32>(0.0);

    // --- Directional ---
    if (frame.dirEnabled != 0u) {
        let L = normalize(frame.dirLight.direction);
        let radiance = frame.dirLight.color * frame.dirLight.intensity;
        var shadow = 1.0;
        if (frame.dirLight.castShadows != 0u) {
            shadow = sampleDirShadowPCF(in.worldPos, N, L);
        }
        direct += evalOpenPbrDirect(pbrIn, L, radiance) * shadow;
    }

    // --- Point lights ---
    let pc = min(frame.pointCount, 8u);
    for (var i = 0u; i < pc; i++) {
        let pl = frame.points[i];
        let toLight = pl.position - in.worldPos;
        let dist = length(toLight);
        if (dist >= pl.range) {
            continue;
        }
        let L = toLight / dist;
        let atten = rangeAttenuation(dist, pl.range);
        let radiance = pl.color * pl.intensity * atten;
        let shadow = samplePointShadowPCF(pl.shadowSlot, pl.position, in.worldPos, N, pl.range);
        direct += evalOpenPbrDirect(pbrIn, L, radiance) * shadow;
    }

    // --- Spot lights ---
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
        let radiance = sl.color * sl.intensity * atten;
        let shadow = sampleSpotShadowPCF(sl.shadowSlot, sl.viewProj, in.worldPos, N, L);
        direct += evalOpenPbrDirect(pbrIn, L, radiance) * shadow;
    }

    // --- IBL ---
    let f0Dielectric = dielectricF0UnderCoat(
        mat.specularIor, coatIor, coatW, mat.specularWeight, mat.specularColor
    );
    let f0Base = mix(f0Dielectric, baseColor, metalness);
    var F_ibl = fresnelSchlickRoughness(NdotV, f0Base, effectiveRoughness);
    if (mat.thinFilmWeight > 0.001) {
        let fFilmIbl = evalThinFilmIridescence(NdotV, mat.thinFilmThickness, mat.thinFilmIor, f0Base);
        F_ibl = mix(F_ibl, fFilmIbl, clamp(mat.thinFilmWeight, 0.0, 1.0));
    }

    let kD_ibl = (vec3<f32>(1.0) - F_ibl) * (1.0 - metalness);
    let baseAlbedoIbl = applyCoatDarkening(baseColor, coatIor, coatW, coatDark);
    let irradiance = textureSample(irradianceMap, iblSampler, N).rgb;
    let diffuseIbl = kD_ibl * irradiance * baseAlbedoIbl;

    // Anisotropic bent reflection vector for IBL
    var iblNormal = N;
    if (abs(mat.specularAnisotropy) > 0.001) {
        let anisoDir = select(T, B, mat.specularAnisotropy >= 0.0);
        let anisoTangent = cross(anisoDir, V);
        let bentNormal = normalize(cross(anisoTangent, anisoDir));
        iblNormal = normalize(mix(N, bentNormal, abs(mat.specularAnisotropy) * 0.5));
    }
    let R = reflect(-V, iblNormal);
    let mip = effectiveRoughness * SPECULAR_MIPS;
    let prefiltered = textureSampleLevel(specularMap, iblSampler, R, mip).rgb;
    let E_o = clamp(directionalAlbedo, 0.05, 1.0);
    let msScale = vec3<f32>(1.0) + f0Base * ((1.0 - E_o) / E_o);
    let specularIbl = prefiltered * (F_ibl * lutBase.r + lutBase.g) * msScale;
    var ambient = (diffuseIbl + specularIbl) * ao;

    // Coat IBL
    var totalEmission = emissive;
    var coatFresnelMax = 0.0;
    if (coatW > 0.001) {
        let cW = clamp(coatW, 0.0, 1.0);
        let cR = clamp(coatR, 0.04, 1.0);
        let f0Coat = vec3<f32>(dielectricF0Scalar(coatIor));
        let Fc_ibl = fresnelSchlickRoughness(NdotV, f0Coat, cR) * cW;
        coatFresnelMax = max(Fc_ibl.r, max(Fc_ibl.g, Fc_ibl.b));
        let coatLut = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, cR)).rg;
        let coatRefl = reflect(-V, N);
        let coatPrefiltered = textureSampleLevel(specularMap, iblSampler, coatRefl, cR * SPECULAR_MIPS).rgb;
        let f90Coat = max(1.0 - cR, f0Coat.x);
        let coatEnvBrdf = (f0Coat * coatLut.r + vec3<f32>(f90Coat * coatLut.g)) * cW;
        let horizonOcclusion = clamp(coatRefl.y * 0.65 + 0.55, 0.18, 1.0);
        let coatSpecIbl = coatPrefiltered * coatEnvBrdf * horizonOcclusion * ao;
        let coatTransIbl = mix(
            vec3<f32>(1.0),
            pow(max(coatCol, vec3<f32>(0.001)), vec3<f32>(1.0 / max(NdotV, 0.05))),
            cW
        );
        ambient = ambient * coatTransIbl * (vec3<f32>(1.0) - Fc_ibl) + coatSpecIbl;
        totalEmission = totalEmission * coatTransIbl * (vec3<f32>(1.0) - Fc_ibl);
    }

    // Fuzz IBL
    if (mat.fuzzWeight > 0.001) {
        let fuzzW = clamp(mat.fuzzWeight, 0.0, 1.0);
        let fuzzTrans = clamp(1.0 - fuzzW * fuzzE, 0.0, 1.0);
        let fuzzIbl = fuzzW * irradiance * mat.fuzzColor * fuzzE * ao;
        ambient = ambient * fuzzTrans + fuzzIbl;
        totalEmission = totalEmission * fuzzTrans;
    }

    var color = direct + ambient + totalEmission;
    color = max(color, vec3<f32>(0.0));
    let rawAlpha = clamp(surfaceOpacity, 0.0, 1.0);
    let baseFresnelMax = max(F_ibl.r, max(F_ibl.g, F_ibl.b));
    let viewReflectance = clamp(baseFresnelMax + coatFresnelMax * (1.0 - baseFresnelMax), 0.0, 1.0);
    let outAlpha = select(rawAlpha, mix(rawAlpha, 1.0, viewReflectance), rawAlpha < 0.999);
    return vec4<f32>(color, outAlpha);
}
