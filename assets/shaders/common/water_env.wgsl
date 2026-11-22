/// Water surface uniforms plus riverbed depth, Voronoi caustics and noise helpers
/// shared by the water surface, caustics and simulation shaders.

struct WaterUniforms {
    camForward: vec4<f32>,    // xyz = forward, w = tanHalfFov
    camRight: vec4<f32>,      // xyz = right,   w = aspect
    camUp: vec4<f32>,         // xyz = up,      w = waterHalf
    params0: vec4<f32>,       // x = time, y = waveScale, z = nearPlane, w = farPlane
    flags0: vec4<u32>,        // x = riverMode, y = useOpenPbr, z = transparent, w = 0
    counts: vec4<u32>,        // x = obstacleCount, y = water body index (common/waves.wgsl), z = enableRefraction, w = enableSsr
    obstacles: array<vec4<f32>, 16>, // x, z, radius, strength
};

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

/// Analytical terrain / riverbed height matching `buildTiledBedMesh` (y = -1.15)
/// and `buildRiverBankMesh` so Beer-Lambert water absorption aligns with geometry.
fn evalRiverBedY(xz: vec2<f32>, riverMode: u32,
                 obstacles: array<vec4<f32>, 16>, obstacleCount: u32) -> f32 {
    var bedY = -1.15;
    if (riverMode != 0u) {
        let az = abs(xz.y);
        if (az > 4.6) {
            let tz = clamp((az - 4.6) / 11.4, 0.0, 1.0);
            let s = tz * tz * (3.0 - 2.0 * tz);
            bedY = max(bedY, -0.85 + s * 3.10);
        }
    }
    // Gentle localized shoaling right under emergent rocks/piers (keeps real depth everywhere else).
    let cnt = min(obstacleCount, 16u);
    for (var i = 0u; i < cnt; i++) {
        let ob = obstacles[i];
        let d = length(xz - ob.xy);
        let collar = 1.0 - smoothstep(ob.z * 0.35, ob.z * 1.05, d);
        bedY = max(bedY, mix(-1.15, -0.48, collar * ob.w));
    }
    return bedY;
}

/// Dual-layer Voronoi cell-edge caustics (single sample -> organic light web).
fn voronoiCausticLayer(uv: vec2<f32>) -> f32 {
    let i = floor(uv);
    let f = fract(uv);
    var md1 = 8.0;
    var md2 = 8.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let g = vec2<f32>(f32(x), f32(y));
            let o = 0.5 + 0.42 * sin(hash22(i + g) * 6.283185 + vec2<f32>(0.0, 1.57));
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
    let edge = sqrt(md2) - sqrt(md1);
    let soft = smoothstep(0.0, 0.72, 1.0 - edge * 1.05);
    return pow(soft, 2.2) * 0.75 + soft * 0.25;
}

/// Chromatically dispersed RGB solar caustics projected onto submerged terrain.
fn evalCausticsRgb(worldPos: vec3<f32>, sunDir: vec3<f32>, time: f32, riverMode: u32) -> vec3<f32> {
    let refractShift = (sunDir.xz / max(abs(sunDir.y) + 0.35, 0.35)) * (-worldPos.y * 0.45);
    let flow = select(vec2<f32>(time * 0.22, time * 0.14),
                      vec2<f32>(-time * 0.88, sin(time * 0.7) * 0.08),
                      riverMode != 0u);
    let p = worldPos.xz + refractShift;
    // Smooth organic wave distortion breaks rigid straight Voronoi cell walls.
    let warp = vec2<f32>(
        sin(p.y * 1.25 + time * 1.15) + cos(p.x * 0.80 - time * 0.85),
        cos(p.x * 1.20 - time * 1.05) + sin(p.y * 0.85 + time * 0.75)
    ) * 0.30;

    let baseUv = (p + warp) * 1.35 + flow;
    let uv2    = (p - warp * 0.7) * 2.05 - flow * vec2<f32>(0.65, 1.15);

    let disp = vec2<f32>(0.014, 0.009);
    let cR = 0.58 * voronoiCausticLayer(baseUv + disp) + 0.42 * voronoiCausticLayer(uv2 - disp);
    let cG = 0.58 * voronoiCausticLayer(baseUv)        + 0.42 * voronoiCausticLayer(uv2);
    let cB = 0.58 * voronoiCausticLayer(baseUv - disp) + 0.42 * voronoiCausticLayer(uv2 + disp);
    return max(vec3<f32>(cR, cG, cB) - vec3<f32>(0.30), vec3<f32>(0.0)) * 1.15;
}
