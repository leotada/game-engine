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
    attenuation: f32,
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
    attenuation: f32,
    angleAttenuation: f32,
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
    /// Seconds, set by `Scene3DTextured.setTime` (0 when the game never sets it).
    time: f32,
    /// Global multiplier for IBL diffuse/specular/coat/fuzz ambient lighting.
    iblIntensity: f32,
    /// 0 = dry, 1 = soaked (rain-exposed surfaces, see `TexInstanceData.custom.w`).
    globalWetness: f32,
    rainIntensity: f32,
    cloudCoverage: f32,
    spots: array<SpotLight, 4>,

    // Cascaded shadow maps.
    cascadeViewProj: array<mat4x4<f32>, 4>,
    /// View depth where each cascade ends.
    cascadeSplits: vec4<f32>,
    /// x = count (0 = fixed legacy map), y = blend fraction, z = fade start, w = fade end.
    cascadeParams: vec4<f32>,
    /// Per cascade: x = texel world size, y = 1 / light depth range.
    cascadeTexel: array<vec4<f32>, 4>,

    // Camera.
    invViewProj: mat4x4<f32>,
    cameraForward: vec3<f32>,
    cameraNear: f32,
    viewportSize: vec2<f32>,
    cameraFar: f32,
    /// Bit 0: tint cascades.
    debugFlags: u32,

    // Atmosphere (see common/atmosphere.wgsl).
    fogColorDensity: vec4<f32>,
    fogHeight: vec4<f32>,
    fogSun: vec4<f32>,
    moonDir: vec4<f32>,
    skyParams: vec4<f32>,
};

@group(0) @binding(0) var<uniform> frame: FrameUniforms;
@group(0) @binding(1) var shadowSampler: sampler_comparison;
@group(0) @binding(2) var dirShadowMap: texture_depth_2d_array;
@group(0) @binding(3) var pointShadow0: texture_depth_cube;
@group(0) @binding(4) var pointShadow1: texture_depth_cube;
@group(0) @binding(5) var pointShadow2: texture_depth_cube;
@group(0) @binding(6) var pointShadow3: texture_depth_cube;
@group(0) @binding(7) var spotShadow0: texture_depth_2d;
@group(0) @binding(8) var spotShadow1: texture_depth_2d;
@group(0) @binding(9) var<storage, read> pointLights: array<PointLight>;

/// 3×3 PCF on one directional shadow layer (explicit LOD: valid in
/// non-uniform control flow).
fn sampleDirLayerPCF(layer: i32, uv: vec2<f32>, depth: f32) -> f32 {
    let texel = 1.0 / f32(textureDimensions(dirShadowMap).x);
    var shadow = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel;
            shadow += textureSampleCompareLevel(dirShadowMap, shadowSampler, uv + offset, layer, depth);
        }
    }
    return shadow / 9.0;
}

/// Fixed (non-cascaded) directional map: `frame.dirLight.viewProj`, layer 0.
fn sampleDirShadowFixed(worldPos: vec3<f32>, normal: vec3<f32>, L: vec3<f32>) -> f32 {
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
    let shadow = sampleDirLayerPCF(0, uv, depth - bias);
    return mix(1.0, shadow,
        smoothstep(0.0, 0.08, uv.x) * smoothstep(1.0, 0.92, uv.x)
      * smoothstep(0.0, 0.08, uv.y) * smoothstep(1.0, 0.92, uv.y));
}

/// One cascade: normal offset and depth bias scale with the cascade texel size.
fn sampleDirCascade(i: i32, worldPos: vec3<f32>, normal: vec3<f32>, L: vec3<f32>) -> f32 {
    let NdotL = clamp(dot(normal, L), 0.0, 1.0);
    let texel = frame.cascadeTexel[i].x;
    let samplePos = worldPos + normal * (texel * (0.75 + 1.5 * (1.0 - NdotL)));
    let p = frame.cascadeViewProj[i] * vec4<f32>(samplePos, 1.0);
    let ndc = p.xyz / p.w;
    let uv = ndc.xy * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5, 0.5);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || ndc.z >= 1.0) {
        return 1.0;
    }
    let bias = texel * frame.cascadeTexel[i].y * mix(2.0, 0.5, NdotL) + frame.shadowBias * 0.25;
    return sampleDirLayerPCF(i, uv, max(ndc.z, 0.0) - bias);
}

/// Cascade index containing `worldPos` (count − 1 past the last split).
fn dirCascadeIndex(worldPos: vec3<f32>) -> i32 {
    let count = i32(frame.cascadeParams.x);
    let viewDepth = dot(worldPos - frame.cameraPos, frame.cameraForward);
    var idx = count - 1;
    for (var i = 0; i < count; i++) {
        if (viewDepth < frame.cascadeSplits[i]) {
            idx = i;
            break;
        }
    }
    return idx;
}

/// Directional shadow factor (1 = lit). Uses cascades when
/// `frame.cascadeParams.x > 0`, otherwise the fixed legacy map.
fn sampleDirShadowPCF(worldPos: vec3<f32>, normal: vec3<f32>, L: vec3<f32>) -> f32 {
    let count = i32(frame.cascadeParams.x);
    if (count <= 0) {
        return sampleDirShadowFixed(worldPos, normal, L);
    }
    let viewDepth = dot(worldPos - frame.cameraPos, frame.cameraForward);
    if (viewDepth >= frame.cascadeParams.w) {
        return 1.0;
    }
    let idx = dirCascadeIndex(worldPos);
    var s = sampleDirCascade(idx, worldPos, normal, L);
    let splitFar = frame.cascadeSplits[idx];
    var splitNear = frame.cameraNear;
    if (idx > 0) {
        splitNear = frame.cascadeSplits[idx - 1];
    }
    let band = max((splitFar - splitNear) * frame.cascadeParams.y, 1e-3);
    if (idx + 1 < count && viewDepth > splitFar - band) {
        let t = clamp((viewDepth - (splitFar - band)) / band, 0.0, 1.0);
        s = mix(s, sampleDirCascade(idx + 1, worldPos, normal, L), t);
    }
    let fade = smoothstep(frame.cascadeParams.z, frame.cascadeParams.w, viewDepth);
    return mix(s, 1.0, fade);
}

/// Debug tint per cascade (identity unless `frame.debugFlags & 1`).
fn cascadeDebugTint(worldPos: vec3<f32>) -> vec3<f32> {
    if ((frame.debugFlags & 1u) == 0u || frame.cascadeParams.x < 0.5) {
        return vec3<f32>(1.0);
    }
    let tints = array<vec3<f32>, 4>(
        vec3<f32>(1.0, 0.45, 0.45), vec3<f32>(0.45, 1.0, 0.45),
        vec3<f32>(0.45, 0.6, 1.0), vec3<f32>(1.0, 1.0, 0.4));
    return tints[dirCascadeIndex(worldPos)];
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
    return mix(1.0, shadow / 9.0,
        smoothstep(0.0, 0.08, uv.x) * smoothstep(1.0, 0.92, uv.x)
      * smoothstep(0.0, 0.08, uv.y) * smoothstep(1.0, 0.92, uv.y));
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
