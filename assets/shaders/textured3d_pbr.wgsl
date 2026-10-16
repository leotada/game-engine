#include "common/shadows.wgsl"

struct MaterialParams {
    baseColorFactor: vec4<f32>,
    metallic: f32,
    roughness: f32,
    flags: u32,
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
    out.worldNormal = normalize(normalMat * in.normal);
    var t = normalize(normalMat * vec3<f32>(1.0, 0.0, 0.0));
    if (abs(dot(t, out.worldNormal)) > 0.9) {
        t = normalize(normalMat * vec3<f32>(0.0, 0.0, 1.0));
    }
    out.worldTangent = normalize(t - out.worldNormal * dot(out.worldNormal, t));
    out.worldBitangent = cross(out.worldNormal, out.worldTangent);
    out.uv = in.uv;
    out.tint = in.tint.rgb;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let albedoSample = textureSample(albedoMap, texSampler, in.uv);
    var albedo = albedoSample.rgb * mat.baseColorFactor.rgb * in.tint;
    var metallic = mat.metallic;
    var roughness = mat.roughness;
    if ((mat.flags & FLAG_MR) != 0u) {
        let mr = textureSample(mrMap, texSampler, in.uv);
        roughness = clamp(roughness * mr.g, 0.04, 1.0);
        metallic = clamp(metallic * mr.b, 0.0, 1.0);
    } else {
        roughness = clamp(roughness, 0.04, 1.0);
        metallic = clamp(metallic, 0.0, 1.0);
    }

    var N = normalize(in.worldNormal);
    if ((mat.flags & FLAG_NORMAL) != 0u) {
        let nSample = textureSample(normalMap, texSampler, in.uv).xyz * 2.0 - 1.0;
        let TBN = mat3x3<f32>(normalize(in.worldTangent), normalize(in.worldBitangent), N);
        N = normalize(TBN * nSample);
    }

    var ao = 1.0;
    if ((mat.flags & FLAG_AO) != 0u) {
        ao = textureSample(occlusionMap, texSampler, in.uv).r;
    }

    var emissive = vec3<f32>(0.0);
    if ((mat.flags & FLAG_EMISSIVE) != 0u) {
        emissive = textureSample(emissiveMap, texSampler, in.uv).rgb;
    }

    let V = normalize(frame.cameraPos - in.worldPos);
    var direct = vec3<f32>(0.0);

    // --- Directional ---
    if (frame.dirEnabled != 0u) {
        let L = normalize(frame.dirLight.direction);
        let radiance = frame.dirLight.color * frame.dirLight.intensity;
        var shadow = 1.0;
        if (frame.dirLight.castShadows != 0u) {
            shadow = sampleDirShadowPCF(in.worldPos, N, L);
        }
        direct += evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
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
        direct += evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
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
        // Cone: direction is light→scene, so compare against -L (scene→light flipped).
        let theta = dot(normalize(-sl.direction), L);
        let epsilon = max(sl.innerConeCos - sl.outerConeCos, 0.001);
        let cone = clamp((theta - sl.outerConeCos) / epsilon, 0.0, 1.0);
        if (cone <= 0.0) {
            continue;
        }
        let atten = rangeAttenuation(dist, sl.range) * cone * cone;
        let radiance = sl.color * sl.intensity * atten;
        let shadow = sampleSpotShadowPCF(sl.shadowSlot, sl.viewProj, in.worldPos, N, L);
        direct += evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
    }

    // IBL
    let F0 = mix(vec3<f32>(0.04), albedo, metallic);
    let NdotV = max(dot(N, V), 0.001);
    let F_ibl = fresnelSchlickRoughness(NdotV, F0, roughness);
    let kD_ibl = (vec3<f32>(1.0) - F_ibl) * (1.0 - metallic);
    let irradiance = textureSample(irradianceMap, iblSampler, N).rgb;
    let diffuseIbl = kD_ibl * irradiance * albedo;
    let R = reflect(-V, N);
    let mip = roughness * SPECULAR_MIPS;
    let prefiltered = textureSampleLevel(specularMap, iblSampler, R, mip).rgb;
    let brdf = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, roughness)).rg;
    let specularIbl = prefiltered * (F_ibl * brdf.x + brdf.y);
    let ambient = (diffuseIbl + specularIbl) * ao;

    var color = direct + ambient + emissive;
    color = max(color, vec3<f32>(0.0));
    return vec4<f32>(color, albedoSample.a * mat.baseColorFactor.a);
}
