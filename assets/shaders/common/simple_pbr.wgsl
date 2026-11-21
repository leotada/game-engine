/// Compact PBR lighting shared by terrain and decals: directional light
/// with cascaded shadows, point and spot lights (with their shadows) and
/// split-sum IBL from `@group(2)`. Requires `common/pbr_brdf.wgsl` and
/// `common/shadows.wgsl`. `Ng` is the geometric normal used for shadow
/// offsets. Uses only explicit-LOD sampling (safe in non-uniform flow).

@group(2) @binding(0) var irradianceMap: texture_cube<f32>;
@group(2) @binding(1) var specularMap: texture_cube<f32>;
@group(2) @binding(2) var brdfLut: texture_2d<f32>;
@group(2) @binding(3) var iblSampler: sampler;

fn shadeSimplePbr(P: vec3<f32>, N: vec3<f32>, Ng: vec3<f32>, V: vec3<f32>, albedo: vec3<f32>,
                  metallic: f32, roughness: f32, ao: f32) -> vec3<f32> {
    var direct = vec3<f32>(0.0);
    if (frame.dirEnabled != 0u) {
        let L = normalize(frame.dirLight.direction);
        let radiance = frame.dirLight.color * frame.dirLight.intensity;
        var shadow = 1.0;
        if (frame.dirLight.castShadows != 0u) {
            shadow = sampleDirShadowPCF(P, Ng, L);
        }
        direct += evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
    }
    let pc = min(frame.pointCount, arrayLength(&pointLights));
    for (var i = 0u; i < pc; i++) {
        let pl = pointLights[i];
        let toLight = pl.position - P;
        let d = length(toLight);
        if (d >= pl.range) {
            continue;
        }
        let L = toLight / d;
        let radiance = pl.color * pl.intensity * lightAttenuation(d, pl.range, pl.attenuation);
        let shadow = samplePointShadowPCF(pl.shadowSlot, pl.position, P, Ng, pl.range);
        direct += evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
    }
    let sc = min(frame.spotCount, 4u);
    for (var i = 0u; i < sc; i++) {
        let sl = frame.spots[i];
        let toLight = sl.position - P;
        let d = length(toLight);
        if (d >= sl.range) {
            continue;
        }
        let L = toLight / d;
        let theta = dot(normalize(-sl.direction), L);
        let cone = clamp((theta - sl.outerConeCos) / max(sl.innerConeCos - sl.outerConeCos, 0.001), 0.0, 1.0);
        if (cone <= 0.0) {
            continue;
        }
        let radiance = sl.color * sl.intensity * lightAttenuation(d, sl.range, sl.attenuation) * cone * cone;
        let shadow = sampleSpotShadowPCF(sl.shadowSlot, sl.viewProj, P, Ng, L);
        direct += evalBRDF(N, V, L, albedo, metallic, roughness, radiance) * shadow;
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
