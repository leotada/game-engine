/// Compact PBR lighting shared by terrain and decals: directional light
/// with cascaded shadows, point and spot lights (with their shadows) and
/// split-sum IBL from `@group(2)`. Requires `common/pbr_brdf.wgsl` and
/// `common/shadows.wgsl`. `Ng` is the geometric normal used for shadow
/// offsets. Uses only explicit-LOD sampling (safe in non-uniform flow).
/// Submerged surfaces get sun caustics from the shared water data.

#include "waves.wgsl"
#include "caustics.wgsl"

@group(2) @binding(0) var irradianceMap: texture_cube<f32>;
@group(2) @binding(1) var specularMap: texture_cube<f32>;
@group(2) @binding(2) var brdfLut: texture_2d<f32>;
@group(2) @binding(3) var iblSampler: sampler;

fn evalSimplePoint(P: vec3<f32>, N: vec3<f32>, Ng: vec3<f32>, V: vec3<f32>,
                   albedo: vec3<f32>, metallic: f32, roughness: f32, pl: PointLight) -> vec3<f32> {
    let toLight = pl.position - P;
    let d = length(toLight);
    if (d >= pl.range || d <= 1e-6) {
        return vec3<f32>(0.0);
    }
    let L = toLight / d;
    let radiance = pl.color * pl.intensity * lightAttenuation(d, pl.range, pl.attenuation);
    let shadow = samplePointShadowPCF(pl.shadowSlot, pl.position, P, Ng, pl.range);
    return evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
}

fn evalSimpleSpot(P: vec3<f32>, N: vec3<f32>, Ng: vec3<f32>, V: vec3<f32>,
                  albedo: vec3<f32>, metallic: f32, roughness: f32, sl: SpotLight) -> vec3<f32> {
    let toLight = sl.position - P;
    let d = length(toLight);
    if (d >= sl.range || d <= 1e-6) {
        return vec3<f32>(0.0);
    }
    let L = toLight / d;
    let theta = dot(normalize(-sl.direction), L);
    let cone = clamp((theta - sl.outerConeCos) / max(sl.innerConeCos - sl.outerConeCos, 0.001), 0.0, 1.0);
    if (cone <= 0.0) {
        return vec3<f32>(0.0);
    }
    let coneFall = select(cone * cone, pow(cone, sl.angleAttenuation), sl.angleAttenuation > 0.0);
    let radiance = sl.color * sl.intensity * lightAttenuation(d, sl.range, sl.attenuation) * coneFall;
    let shadow = sampleSpotShadowPCF(sl.shadowSlot, sl.viewProj, P, Ng, L);
    return evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
}

fn shadeSimplePbr(P: vec3<f32>, N: vec3<f32>, Ng: vec3<f32>, V: vec3<f32>, screenXY: vec2<f32>,
                  albedo: vec3<f32>, metallic: f32, roughness: f32, ao: f32) -> vec3<f32> {
    var direct = vec3<f32>(0.0);
    if (frame.dirEnabled != 0u) {
        let L = normalize(frame.dirLight.direction);
        let radiance = frame.dirLight.color * frame.dirLight.intensity;
        var shadow = 1.0;
        if (frame.dirLight.castShadows != 0u) {
            shadow = sampleDirShadowPCF(P, Ng, L);
        }
        direct += evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
        direct += radiance * waterCausticsAt(P, N, L, shadow) * albedo * (1.0 - metallic);
    }
    if ((frame.pointCount | frame.spotCount) != 0u) {
        let pMax = arrayLength(&pointLights);
        let sMax = arrayLength(&spotLights);
        if ((frame.clusteredFlags & 1u) != 0u) {
            let rec = clusterGrid[clusterIndexAt(P, screenXY)];
            for (var k = 0u; k < rec.pointCount; k++) {
                let idx = clusterLightIndices[rec.offset + k];
                if (idx < pMax) {
                    direct += evalSimplePoint(P, N, Ng, V, albedo, metallic, roughness, pointLights[idx]);
                }
            }
            for (var k = 0u; k < rec.spotCount; k++) {
                let idx = clusterLightIndices[rec.offset + rec.pointCount + k];
                if (idx < sMax) {
                    direct += evalSimpleSpot(P, N, Ng, V, albedo, metallic, roughness, spotLights[idx]);
                }
            }
        } else {
            let pc = min(frame.pointCount, pMax);
            for (var i = 0u; i < pc; i++) {
                direct += evalSimplePoint(P, N, Ng, V, albedo, metallic, roughness, pointLights[i]);
            }
            let sc = min(frame.spotCount, sMax);
            for (var i = 0u; i < sc; i++) {
                direct += evalSimpleSpot(P, N, Ng, V, albedo, metallic, roughness, spotLights[i]);
            }
        }
    }

    let NdotV = max(dot(N, V), 1e-4);
    let f0 = mix(vec3<f32>(0.04), albedo, metallic);
    let F = fresnelSchlickRoughness(NdotV, f0, roughness);
    let kD = (vec3<f32>(1.0) - F) * (1.0 - metallic);
    let iblScale = max(frame.iblIntensity, 0.0);
    let irradiance = textureSampleLevel(irradianceMap, iblSampler, N, 0.0).rgb * iblScale;
    let R = reflect(-V, N);
    let prefiltered = textureSampleLevel(specularMap, iblSampler, R, roughness * SPECULAR_MIPS).rgb * iblScale;
    let lut = textureSampleLevel(brdfLut, iblSampler, vec2<f32>(NdotV, roughness), 0.0).rg;
    let ambient = (kD * irradiance * albedo + prefiltered * (F * lut.x + lut.y)) * ao;

    return direct + ambient;
}
