/// Shared procedural sky, riverbed depth, Voronoi caustics, and noise helpers
/// for the realistic water showcase (sky_dome, caustics_bed, water_surface).

struct WaterUniforms {
    camForward: vec4<f32>,    // xyz = forward, w = tanHalfFov
    camRight: vec4<f32>,      // xyz = right,   w = aspect
    camUp: vec4<f32>,         // xyz = up,      w = waterHalf
    params0: vec4<f32>,       // x = time, y = waveScale, z = nearPlane, w = farPlane
    flags0: vec4<u32>,        // x = riverMode, y = useOpenPbr, z = transparent, w = lowSun
    counts: vec4<u32>,        // x = obstacleCount, y = waveCount (6), z = enableRefraction, w = enableSsr
    wavesA: array<vec4<f32>, 6>,     // dirX, dirZ, wavelength, amplitude
    wavesB: array<vec4<f32>, 6>,     // steepness, speedScale, 0, 0
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

/// Evaluates the procedural atmosphere, clouds, solar corona, and sun disc
/// shared by both the visible sky dome and water mirror reflections.
fn evalWaterSky(dirIn: vec3<f32>, sunDirIn: vec3<f32>, sunCol: vec3<f32>,
                lowSun: u32, time: f32) -> vec3<f32> {
    let d = normalize(dirIn);
    let sunDir = normalize(sunDirIn);
    let upFactor = clamp(d.y, 0.0, 1.0);
    let horizBand = exp(-abs(d.y) * 5.2);

    var zenithCol = vec3<f32>(0.10, 0.29, 0.74);
    var midCol    = vec3<f32>(0.34, 0.58, 0.90);
    var horizCol  = vec3<f32>(0.74, 0.86, 0.97);
    var groundCol = vec3<f32>(0.02, 0.08, 0.15);

    if (lowSun != 0u) {
        zenithCol = vec3<f32>(0.11, 0.21, 0.44);
        midCol    = vec3<f32>(0.44, 0.49, 0.64);
        horizCol  = vec3<f32>(0.98, 0.62, 0.37);
        groundCol = vec3<f32>(0.03, 0.06, 0.10);
    }

    var sky: vec3<f32>;
    if (d.y >= 0.0) {
        let tMid = smoothstep(0.0, 0.36, upFactor);
        let tTop = smoothstep(0.24, 0.92, upFactor);
        sky = mix(horizCol, midCol, tMid);
        sky = mix(sky, zenithCol, tTop);
    } else {
        sky = mix(horizCol, groundCol, smoothstep(0.0, 0.30, -d.y));
    }

    // Warm horizon Mie scatter toward the solar azimuth.
    let sunCos = max(dot(d, sunDir), 0.0);
    let sunAzScatter = pow(sunCos, 6.0) * (0.28 + 0.72 * horizBand);
    sky += sunCol * sunAzScatter * select(0.22, 0.65, lowSun != 0u);

    // Drifting cirrus / cumulus clouds above the horizon.
    if (d.y > 0.005) {
        let cloudProj = d.xz / (d.y + 0.14);
        let cloudUv = cloudProj * 0.48 + vec2<f32>(time * 0.014, time * 0.006);
        let c1 = fbm2(cloudUv);
        let c2 = fbm2(cloudUv * 2.3 - vec2<f32>(time * 0.011, 4.2));
        let cloudDensity = smoothstep(0.50, 0.82, c1 * 0.72 + c2 * 0.28);
        let cloudFade = smoothstep(0.01, 0.20, d.y);

        let cloudBase = select(vec3<f32>(0.80, 0.87, 0.95), vec3<f32>(0.62, 0.56, 0.64), lowSun != 0u);
        let cloudLit  = mix(cloudBase, sunCol * 1.45 + vec3<f32>(0.35),
                            0.35 + 0.65 * pow(sunCos, 3.0) + 0.25 * (1.0 - c2));
        sky = mix(sky, cloudLit, cloudDensity * cloudFade * 0.72);
    }

    // Solar corona + crisp HDR sun disc.
    let halo = pow(sunCos, 64.0) * 1.35 + pow(sunCos, 12.0) * 0.16;
    let disc = smoothstep(0.99935, 0.99978, sunCos) * 20.0;
    let horizonVis = smoothstep(-0.04, 0.04, d.y);
    sky += sunCol * (halo + disc) * horizonVis;

    return max(sky, vec3<f32>(0.0));
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
    return pow(clamp(1.0 - edge * 1.55, 0.0, 1.0), 2.4);
}

/// Chromatically dispersed RGB solar caustics projected onto submerged terrain.
fn evalCausticsRgb(worldPos: vec3<f32>, sunDir: vec3<f32>, time: f32, riverMode: u32) -> vec3<f32> {
    let refractShift = (sunDir.xz / max(abs(sunDir.y) + 0.35, 0.35)) * (-worldPos.y * 0.55);
    let flow = select(vec2<f32>(time * 0.24, time * 0.16),
                      vec2<f32>(-time * 0.95, sin(time * 0.7) * 0.10),
                      riverMode != 0u);
    let p = worldPos.xz + refractShift;
    // Smooth organic wave distortion breaks rigid straight Voronoi cell walls.
    let warp = vec2<f32>(
        sin(p.y * 1.35 + time * 1.25) + cos(p.x * 0.85 - time * 0.90),
        cos(p.x * 1.30 - time * 1.10) + sin(p.y * 0.90 + time * 0.80)
    ) * 0.28;

    let baseUv = (p + warp) * 1.75 + flow;
    let uv2    = (p - warp * 0.7) * 2.55 - flow * vec2<f32>(0.65, 1.15);

    let disp = vec2<f32>(0.032, 0.022);
    let cR = 0.55 * voronoiCausticLayer(baseUv + disp) + 0.45 * voronoiCausticLayer(uv2 - disp);
    let cG = 0.55 * voronoiCausticLayer(baseUv)        + 0.45 * voronoiCausticLayer(uv2);
    let cB = 0.55 * voronoiCausticLayer(baseUv - disp) + 0.45 * voronoiCausticLayer(uv2 + disp);
    return vec3<f32>(cR, cG, cB);
}
