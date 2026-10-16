struct DirLight {
    direction: vec3<f32>,
    intensity: f32,
    color: vec3<f32>,
    castShadows: u32,
    viewProj: mat4x4<f32>,
};

struct PointLight {
    position: vec3<f32>,
    range: f32,
    color: vec3<f32>,
    intensity: f32,
    shadowSlot: i32,
    _pad0: f32,
    _pad1: f32,
    _pad2: f32,
};

struct SpotLight {
    position: vec3<f32>,
    range: f32,
    direction: vec3<f32>,
    intensity: f32,
    color: vec3<f32>,
    innerConeCos: f32,
    outerConeCos: f32,
    shadowSlot: i32,
    _pad0: f32,
    _pad1: f32,
    viewProj: mat4x4<f32>,
};

struct FrameUniforms {
    viewProj: mat4x4<f32>,
    cameraPos: vec3<f32>,
    shadowBias: f32,
    dirLight: DirLight,
    pointCount: u32,
    spotCount: u32,
    dirEnabled: u32,
    _padCounts: u32,
    points: array<PointLight, 8>,
    spots: array<SpotLight, 4>,
};

@group(0) @binding(0) var<uniform> frame: FrameUniforms;
@group(0) @binding(1) var shadowSampler: sampler_comparison;
@group(0) @binding(2) var dirShadowMap: texture_depth_2d;
@group(0) @binding(3) var pointShadow0: texture_depth_cube;
@group(0) @binding(4) var pointShadow1: texture_depth_cube;
@group(0) @binding(5) var pointShadow2: texture_depth_cube;
@group(0) @binding(6) var pointShadow3: texture_depth_cube;
@group(0) @binding(7) var spotShadow0: texture_depth_2d;
@group(0) @binding(8) var spotShadow1: texture_depth_2d;

fn sampleDirShadowPCF(worldPos: vec3<f32>, normal: vec3<f32>, L: vec3<f32>) -> f32 {
    let NdotL = clamp(dot(normal, L), 0.0, 1.0);
    let bias = mix(frame.shadowBias * 5.0, frame.shadowBias, NdotL);
    let samplePos = worldPos + normal * (frame.shadowBias * 8.0 * (1.0 - NdotL));
    var shadowPos = frame.dirLight.viewProj * vec4<f32>(samplePos, 1.0);
    let ndc = shadowPos.xyz / shadowPos.w;
    let uv = ndc.xy * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5, 0.5);
    let depth = ndc.z;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || depth <= 0.0 || depth >= 1.0) {
        return 1.0;
    }
    let texel = 1.0 / f32(textureDimensions(dirShadowMap).x);
    var shadow = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel;
            shadow += textureSampleCompare(dirShadowMap, shadowSampler, uv + offset, depth - bias);
        }
    }
    return shadow / 9.0;
}

fn cubeRefDepth(fragToLight: vec3<f32>, nearP: f32, farP: f32) -> f32 {
    let m = max(max(abs(fragToLight.x), abs(fragToLight.y)), abs(fragToLight.z));
    let d = max(m, nearP);
    return farP * (d - nearP) / ((farP - nearP) * d);
}

fn sampleCubeCompare(tex: texture_depth_cube, dir: vec3<f32>, refDepth: f32) -> f32 {
    return textureSampleCompare(tex, shadowSampler, dir, refDepth);
}

fn samplePointShadowPCF(slot: i32, lightPos: vec3<f32>, worldPos: vec3<f32>,
                        normal: vec3<f32>, range: f32) -> f32 {
    if (slot < 0) {
        return 1.0;
    }
    let fragToLight = worldPos - lightPos;
    let dist = length(fragToLight);
    if (dist >= range) {
        return 1.0;
    }
    let L = normalize(-fragToLight);
    let NdotL = clamp(dot(normal, L), 0.0, 1.0);
    let bias = mix(frame.shadowBias * 5.0, frame.shadowBias, NdotL);
    let samplePos = worldPos + normal * (frame.shadowBias * 8.0 * (1.0 - NdotL));
    let toLight = samplePos - lightPos;
    let refDepth = cubeRefDepth(toLight, SHADOW_NEAR, range) - bias;
    let dir = normalize(toLight);
    // Soften with a few direction offsets (cubemap PCF).
    let disk = 0.012;
    var shadow = 0.0;
    let offsets = array<vec3<f32>, 5>(
        dir,
        normalize(dir + vec3<f32>( disk, 0.0, 0.0)),
        normalize(dir + vec3<f32>(-disk, 0.0, 0.0)),
        normalize(dir + vec3<f32>(0.0,  disk, 0.0)),
        normalize(dir + vec3<f32>(0.0, -disk, 0.0)),
    );
    for (var i = 0; i < 5; i++) {
        switch (slot) {
            case 0: { shadow += sampleCubeCompare(pointShadow0, offsets[i], refDepth); }
            case 1: { shadow += sampleCubeCompare(pointShadow1, offsets[i], refDepth); }
            case 2: { shadow += sampleCubeCompare(pointShadow2, offsets[i], refDepth); }
            case 3: { shadow += sampleCubeCompare(pointShadow3, offsets[i], refDepth); }
            default: { shadow += 1.0; }
        }
    }
    return shadow / 5.0;
}

fn sampleSpotMapPCF(tex: texture_depth_2d, lightVP: mat4x4<f32>,
                    worldPos: vec3<f32>, normal: vec3<f32>, L: vec3<f32>) -> f32 {
    let NdotL = clamp(dot(normal, L), 0.0, 1.0);
    let bias = mix(frame.shadowBias * 5.0, frame.shadowBias, NdotL);
    let samplePos = worldPos + normal * (frame.shadowBias * 8.0 * (1.0 - NdotL));
    var shadowPos = lightVP * vec4<f32>(samplePos, 1.0);
    let ndc = shadowPos.xyz / shadowPos.w;
    let uv = ndc.xy * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5, 0.5);
    let depth = ndc.z;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || depth <= 0.0 || depth >= 1.0) {
        return 1.0;
    }
    let texel = 1.0 / f32(textureDimensions(tex).x);
    var shadow = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel;
            shadow += textureSampleCompare(tex, shadowSampler, uv + offset, depth - bias);
        }
    }
    return shadow / 9.0;
}

fn sampleSpotShadowPCF(slot: i32, lightVP: mat4x4<f32>, worldPos: vec3<f32>,
                       normal: vec3<f32>, L: vec3<f32>) -> f32 {
    if (slot < 0) {
        return 1.0;
    }
    if (slot == 0) {
        return sampleSpotMapPCF(spotShadow0, lightVP, worldPos, normal, L);
    }
    return sampleSpotMapPCF(spotShadow1, lightVP, worldPos, normal, L);
}
