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

#include "common/pbr_brdf.wgsl"

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
    pbrIn.coatWeight = mat.coatWeight;
    pbrIn.coatColor = mat.coatColor;
    pbrIn.coatRoughness = mat.coatRoughness;
    pbrIn.coatIor = mat.coatIor;
    pbrIn.coatDarkening = mat.coatDarkening;
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
        mat.specularIor, mat.coatIor, mat.coatWeight, mat.specularWeight, mat.specularColor
    );
    let f0Base = mix(f0Dielectric, baseColor, metalness);
    var F_ibl = fresnelSchlickRoughness(NdotV, f0Base, effectiveRoughness);
    if (mat.thinFilmWeight > 0.001) {
        let fFilmIbl = evalThinFilmIridescence(NdotV, mat.thinFilmThickness, mat.thinFilmIor, f0Base);
        F_ibl = mix(F_ibl, fFilmIbl, clamp(mat.thinFilmWeight, 0.0, 1.0));
    }

    let kD_ibl = (vec3<f32>(1.0) - F_ibl) * (1.0 - metalness);
    let baseAlbedoIbl = applyCoatDarkening(baseColor, mat.coatIor, mat.coatWeight, mat.coatDarkening);
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
    if (mat.coatWeight > 0.001) {
        let coatW = clamp(mat.coatWeight, 0.0, 1.0);
        let coatR = clamp(mat.coatRoughness, 0.04, 1.0);
        let f0Coat = vec3<f32>(dielectricF0Scalar(mat.coatIor));
        let Fc_ibl = fresnelSchlickRoughness(NdotV, f0Coat, coatR) * coatW;
        let coatLut = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, coatR)).rg;
        let coatRefl = reflect(-V, N);
        let coatPrefiltered = textureSampleLevel(specularMap, iblSampler, coatRefl, coatR * SPECULAR_MIPS).rgb;
        let coatSpecIbl = coatPrefiltered * (Fc_ibl * coatLut.r + coatLut.g) * ao;
        let coatTransIbl = mix(
            vec3<f32>(1.0),
            pow(max(mat.coatColor, vec3<f32>(0.001)), vec3<f32>(1.0 / max(NdotV, 0.05))),
            coatW
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
    return vec4<f32>(color, albedoSample.a * mat.geometryOpacity);
}
