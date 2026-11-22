/// Water surface uniforms plus bed depth, flow-frame and noise helpers shared
/// by the water surface and simulation shaders.

/// Per-body water surface uniforms (`engine.water.renderer.WaterSurfaceUniforms`).
struct WaterUniforms {
    params0: vec4<f32>,       // x = time, y = amplitudeScale, z = nearPlane, w = farPlane
    flags0: vec4<u32>,        // x = style (0 ocean, 1 river), y = useOpenPbr, z = transparent, w = grid resolution
    counts: vec4<u32>,        // x = obstacleCount, y = water body index (common/waves.wgsl), z = enableRefraction, w = enableSsr
    area: vec4<f32>,          // xy = center XZ, z = halfExtent, w = level
    flow: vec4<f32>,          // xy = surface current (m/s), z = flow profile half width, w = bedDepth
    channel: vec4<f32>,       // xy = channel origin, zw = channel direction (river profile / wakes)
    absorption: vec4<f32>,    // rgb = Beer-Lambert sigma, w = roughness
    shallowColor: vec4<f32>,  // rgb, w = anisotropy
    deepColor: vec4<f32>,     // rgb, w = 0
    coatColor: vec4<f32>,     // rgb, w = causticsStrength
    sssTint: vec4<f32>,       // rgb, w = 0
    obstacles: array<vec4<f32>, 16>, // x, z, radius, strength
};

/// Distance across the river channel (0 on the center line).
fn waterChannelAcross(ch: vec4<f32>, xz: vec2<f32>) -> f32 {
    let d = xz - ch.xy;
    return abs(d.y * ch.z - d.x * ch.w);
}

/// `rel` expressed in the flow frame: x = downstream, y = across.
fn waterFlowFrame(rel: vec2<f32>, flowDir: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(dot(rel, flowDir), rel.y * flowDir.x - rel.x * flowDir.y);
}

/// Reconstructs positive camera-space linear Z from hardware [0, 1] NDC depth.
fn linearizeDepth(ndcZ: f32, nearZ: f32, farZ: f32) -> f32 {
    return (nearZ * farZ) / max(farZ - ndcZ * (farZ - nearZ), 1e-4);
}

fn hash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * vec3<f32>(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

fn valueNoise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    let a = hash21(i);
    let b = hash21(i + vec2<f32>(1.0, 0.0));
    let c = hash21(i + vec2<f32>(0.0, 1.0));
    let d = hash21(i + vec2<f32>(1.0, 1.0));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

fn fbm2(pInit: vec2<f32>) -> f32 {
    var p = pInit;
    var sum = 0.0;
    var amp = 0.5;
    // Slight rotation per octave breaks axis-aligned grid artifacts.
    let rot = mat2x2<f32>(0.80, -0.60, 0.60, 0.80);
    for (var i = 0; i < 4; i++) {
        sum += amp * valueNoise2(p);
        p = rot * p * 2.04 + vec2<f32>(17.3, 9.7);
        amp *= 0.5;
    }
    return sum;
}

/// Fallback bed height (`bedDepth` below `level`) used where the depth buffer
/// gives no answer, with gentle shoaling right under obstacles.
fn evalWaterBedY(xz: vec2<f32>, level: f32, bedDepth: f32,
                 obstacles: array<vec4<f32>, 16>, obstacleCount: u32) -> f32 {
    let deepY = level - bedDepth;
    var bedY = deepY;
    let cnt = min(obstacleCount, 16u);
    for (var i = 0u; i < cnt; i++) {
        let ob = obstacles[i];
        let d = length(xz - ob.xy);
        let collar = 1.0 - smoothstep(ob.z * 0.35, ob.z * 1.05, d);
        bedY = max(bedY, mix(deepY, level - bedDepth * 0.42, collar * ob.w));
    }
    return bedY;
}
