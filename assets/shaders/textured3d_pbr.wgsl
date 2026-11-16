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
const FLAG_WATER_CAUSTICS: u32 = 16u;
const FLAG_WATER_RIVER: u32 = 32u;

#include "common/pbr_brdf.wgsl"

fn propHash22(p: vec2<f32>) -> vec2<f32> {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

fn propVoronoiCaustic(uv: vec2<f32>) -> f32 {
    let i = floor(uv);
    let f = fract(uv);
    var md1 = 8.0;
    var md2 = 8.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let g = vec2<f32>(f32(x), f32(y));
            let o = 0.5 + 0.42 * sin(propHash22(i + g) * 6.283185 + vec2<f32>(0.0, 1.57));
            let r = g + o - f;
            let d = dot(r, r);
            if (d < md1) {
                md2 = md1;
                md1 = d;
            } else if (d < md2) {
                md2 = d;
            }
        }
    }
    return pow(clamp(1.0 - (sqrt(md2) - sqrt(md1)) * 1.55, 0.0, 1.0), 2.4);
}

fn evalPropWaveY(worldPos: vec3<f32>, time: f32, waveScale: f32, isRiver: bool) -> f32 {
    let freq = select(0.75, 1.35, isRiver);
    let amp = select(0.16, 0.055, isRiver) * waveScale;
    return amp * sin(worldPos.x * freq - time * 2.1 + worldPos.z * 0.45)
         + amp * 0.55 * cos(worldPos.z * (freq * 1.15) + time * 1.6);
}

fn evalPropWaterCaustics(worldPos: vec3<f32>, sunL: vec3<f32>, time: f32, isRiver: bool) -> vec3<f32> {
    let refractShift = (sunL.xz / max(abs(sunL.y) + 0.35, 0.35)) * (max(-worldPos.y, 0.0) * 0.45);
    let flow = select(vec2<f32>(time * 0.24, time * 0.16), vec2<f32>(-time * 0.95, sin(time * 0.7) * 0.10), isRiver);
    let p = worldPos.xz + refractShift;
    let warp = vec2<f32>(
        sin(p.y * 1.35 + time * 1.25) + cos(p.x * 0.85 - time * 0.90),
        cos(p.x * 1.30 - time * 1.10) + sin(p.y * 0.90 + time * 0.80)
    ) * 0.26;
    let uv1 = (p + warp) * 1.75 + flow;
    let uv2 = (p - warp * 0.7) * 2.55 - flow * vec2<f32>(0.65, 1.15);
    let disp = vec2<f32>(0.032, 0.022);
    let cR = 0.55 * propVoronoiCaustic(uv1 + disp) + 0.45 * propVoronoiCaustic(uv2 - disp);
    let cG = 0.55 * propVoronoiCaustic(uv1)        + 0.45 * propVoronoiCaustic(uv2);
    let cB = 0.55 * propVoronoiCaustic(uv1 - disp) + 0.45 * propVoronoiCaustic(uv2 + disp);
    return vec3<f32>(cR, cG, cB);
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
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let model = mat4x4<f32>(in.model0, in.model1, in.model2, in.model3);
    let worldPos4 = model * vec4<f32>(in.position, 1.0);
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
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let albedoSample = textureSample(albedoMap, texSampler, in.uv);
    let baseColor = albedoSample.rgb * mat.baseColor * in.tint * mat.baseWeight;
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
    let NdotV = max(dot(N, V), 0.001);

    let effectiveRoughness = coatRoughenBase(roughness, mat.coatRoughness, mat.coatWeight);
    let lutBase = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, effectiveRoughness)).rgb;
    let directionalAlbedo = lutBase.r + lutBase.g;

    var fuzzE = 0.0;
    if (mat.fuzzWeight > 0.001) {
        let fuzzR = clamp(mat.fuzzRoughness, 0.04, 1.0);
        fuzzE = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, fuzzR)).b;
    }

    let enableWaterFx = (mat.flags & FLAG_WATER_CAUSTICS) != 0u;
    let waterIsRiver = (mat.flags & FLAG_WATER_RIVER) != 0u;
    let waterTime = mat._pad0;
    let waterScale = max(mat._pad1, 0.01);
    var waterSurfY = -999.0;
    var coatW = mat.coatWeight;
    var coatR = mat.coatRoughness;
    var coatDark = mat.coatDarkening;
    var coatCol = mat.coatColor;
    if (enableWaterFx) {
        waterSurfY = evalPropWaveY(in.worldPos, waterTime, waterScale, waterIsRiver);
        if (in.worldPos.y < waterSurfY + 0.28) {
            let wetBand = 1.0 - smoothstep(waterSurfY - 0.04, waterSurfY + 0.28, in.worldPos.y);
            coatW = max(coatW, wetBand * 0.88);
            coatR = min(coatR, mix(0.24, 0.055, wetBand));
            coatDark = max(coatDark, wetBand * 0.68);
            coatCol = mix(coatCol, vec3<f32>(0.84, 0.94, 0.95), wetBand * 0.65);
        }
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
    pbrIn.coatIor = mat.coatIor;
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
        if (enableWaterFx && in.worldPos.y < waterSurfY) {
            let subDepth = clamp(waterSurfY - in.worldPos.y, 0.0, 3.0);
            let cRgb = evalPropWaterCaustics(in.worldPos, L, waterTime, waterIsRiver);
            let caustAtten = shadow * max(dot(N, L), 0.05) * exp(-subDepth * 0.72) * smoothstep(0.0, 0.06, subDepth);
            direct += baseColor * cRgb * radiance * caustAtten * 0.85;
        }
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
        mat.specularIor, mat.coatIor, coatW, mat.specularWeight, mat.specularColor
    );
    let f0Base = mix(f0Dielectric, baseColor, metalness);
    var F_ibl = fresnelSchlickRoughness(NdotV, f0Base, effectiveRoughness);
    if (mat.thinFilmWeight > 0.001) {
        let fFilmIbl = evalThinFilmIridescence(NdotV, mat.thinFilmThickness, mat.thinFilmIor, f0Base);
        F_ibl = mix(F_ibl, fFilmIbl, clamp(mat.thinFilmWeight, 0.0, 1.0));
    }

    let kD_ibl = (vec3<f32>(1.0) - F_ibl) * (1.0 - metalness);
    let baseAlbedoIbl = applyCoatDarkening(baseColor, mat.coatIor, coatW, coatDark);
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
        let f0Coat = vec3<f32>(dielectricF0Scalar(mat.coatIor));
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
    let rawAlpha = clamp(albedoSample.a * mat.geometryOpacity, 0.0, 1.0);
    let baseFresnelMax = max(F_ibl.r, max(F_ibl.g, F_ibl.b));
    let viewReflectance = clamp(baseFresnelMax + coatFresnelMax * (1.0 - baseFresnelMax), 0.0, 1.0);
    let outAlpha = select(rawAlpha, mix(rawAlpha, 1.0, viewReflectance), rawAlpha < 0.999);
    return vec4<f32>(color, outAlpha);
}
