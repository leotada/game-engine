const PI: f32 = 3.14159265359;
const SPECULAR_MIPS: f32 = 4.0;
const SHADOW_NEAR: f32 = 0.1;

fn distributionGGX(NdotH: f32, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

fn geometrySchlickGGX(NdotX: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) / 8.0;
    return NdotX / (NdotX * (1.0 - k) + k);
}

fn geometrySmith(NdotV: f32, NdotL: f32, roughness: f32) -> f32 {
    return geometrySchlickGGX(NdotV, roughness) * geometrySchlickGGX(NdotL, roughness);
}

fn fresnelSchlick(cosTheta: f32, F0: vec3<f32>) -> vec3<f32> {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

fn fresnelSchlickRoughness(cosTheta: f32, F0: vec3<f32>, roughness: f32) -> vec3<f32> {
    return F0 + (max(vec3<f32>(1.0 - roughness), F0) - F0)
         * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

fn evalBRDF(N: vec3<f32>, V: vec3<f32>, L: vec3<f32>, albedo: vec3<f32>,
            metallic: f32, roughness: f32, radiance: vec3<f32>) -> vec3<f32> {
    let NdotL = max(dot(N, L), 0.0);
    if (NdotL <= 0.0) {
        return vec3<f32>(0.0);
    }
    let H = normalize(V + L);
    let NdotV = max(dot(N, V), 0.001);
    let NdotH = max(dot(N, H), 0.0);
    let HdotV = max(dot(H, V), 0.0);
    let F0 = mix(vec3<f32>(0.04), albedo, metallic);
    let D = distributionGGX(NdotH, roughness);
    let G = geometrySmith(NdotV, NdotL, roughness);
    let F = fresnelSchlick(HdotV, F0);
    let specular = min((D * G * F) / max(4.0 * NdotV * NdotL, 0.001), vec3<f32>(16.0));
    let kS = F;
    let kD = (vec3<f32>(1.0) - kS) * (1.0 - metallic);
    return (kD * albedo / PI + specular) * radiance * NdotL;
}

fn rangeAttenuation(distance: f32, range: f32) -> f32 {
    let x = clamp(1.0 - pow(distance / max(range, 0.001), 4.0), 0.0, 1.0);
    return (x * x) / (distance * distance + 1.0);
}
