/// Engine procedural sky: continuous day / dusk / night gradient, Mie sun
/// scatter, drifting clouds driven by `cloudCoverage`, stars, moon disc and
/// HDR sun disc. Self-contained (no bindings): used by the visible sky
/// (`sky.wgsl`) and by the runtime IBL compute pass (`ibl_sky_cs.wgsl`).

struct SkyInputs {
    /// Surface → sun (normalized).
    sunDir: vec3<f32>,
    /// Sun radiance color (0 when the directional light is off).
    sunColor: vec3<f32>,
    /// Surface → moon (normalized).
    moonDir: vec3<f32>,
    moonIntensity: f32,
    starIntensity: f32,
    cloudCoverage: f32,
    time: f32,
    /// Final multiplier (HDR exposure of the sky).
    exposure: f32,
    /// Angular size of one output pixel in radians: stars never get smaller
    /// than it, so they do not flicker when the camera moves.
    pixelAngle: f32,
};

fn skyHash21(p: vec2<f32>) -> f32 {
    var p3 = fract(vec3<f32>(p.x, p.y, p.x) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

fn skyHash31(p: vec3<f32>) -> f32 {
    var p3 = fract(p * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

/// Star brightness in [0, 1] along `d` (normalized): round dots with a jittered
/// center and a radial falloff. The sphere is split into equiangular cube-face
/// cells, one star per cell at most; the disc stays inside its cell, so a
/// single cell is enough and no star is clipped.
fn skyStars(d: vec3<f32>, pixelAngle: f32) -> f32 {
    const CELLS: f32 = 110.0;
    const DENSITY: f32 = 0.045;
    const QUARTER_PI: f32 = 0.78539816;
    let a = abs(d);
    var face = 0.0;
    var uvw = vec3<f32>(d.z, d.y, d.x);
    if (a.y >= a.x && a.y >= a.z) {
        face = 2.0;
        uvw = vec3<f32>(d.x, d.z, d.y);
    } else if (a.z > a.x) {
        face = 4.0;
        uvw = vec3<f32>(d.x, d.y, d.z);
    }
    face += select(0.0, 1.0, uvw.z < 0.0);
    let grid = (atan(uvw.xy / abs(uvw.z)) / QUARTER_PI * 0.5 + 0.5) * CELLS;
    let cell = vec3<f32>(min(floor(grid), vec2<f32>(CELLS - 1.0)), face * 157.0);
    if (skyHash31(cell) >= DENSITY) {
        return 0.0;
    }
    let jitter = vec2<f32>(skyHash31(cell + vec3<f32>(3.0, 17.0, 29.0)),
                           skyHash31(cell + vec3<f32>(41.0, 5.0, 11.0)));
    let center = cell.xy + 0.25 + 0.5 * jitter;
    let tanUv = tan((center / CELLS * 2.0 - 1.0) * QUARTER_PI);
    let starDir = normalize(vec3<f32>(tanUv, 1.0));
    let dist = distance(normalize(vec3<f32>(uvw.xy, abs(uvw.z))), starDir);

    // Bright stars are slightly larger; widened stars keep their energy.
    let mag = skyHash31(cell + vec3<f32>(7.0));
    let base = mix(0.0008, 0.0014, mag * mag);
    let radius = clamp(base, pixelAngle, 0.0024);
    let t = saturate(1.0 - dist / (radius * 1.5));
    return t * t * (3.0 - 2.0 * t) * (0.25 + 0.75 * mag * mag) * (base * base) / (radius * radius);
}

fn skyNoise2(p: vec2<f32>) -> f32 {
    let i = floor(p);
    let f = fract(p);
    let u = f * f * (3.0 - 2.0 * f);
    return mix(mix(skyHash21(i), skyHash21(i + vec2<f32>(1.0, 0.0)), u.x),
               mix(skyHash21(i + vec2<f32>(0.0, 1.0)), skyHash21(i + vec2<f32>(1.0, 1.0)), u.x), u.y);
}

fn skyFbm2(pInit: vec2<f32>) -> f32 {
    var p = pInit;
    var sum = 0.0;
    var amp = 0.5;
    let rot = mat2x2<f32>(0.80, -0.60, 0.60, 0.80);
    for (var i = 0; i < 5; i++) {
        sum += amp * skyNoise2(p);
        p = rot * p * 2.03 + vec2<f32>(17.3, 9.7);
        amp *= 0.5;
    }
    return sum;
}

/// Cloud density in [0, 1] along `d` (0 below the horizon).
fn skyCloudDensity(d: vec3<f32>, coverage: f32, time: f32) -> f32 {
    if (d.y <= 0.005) {
        return 0.0;
    }
    let proj = d.xz / (d.y + 0.14);
    let uv = proj * 0.48 + vec2<f32>(time * 0.014, time * 0.006);
    let n = skyFbm2(uv) * 0.72 + skyFbm2(uv * 2.3 - vec2<f32>(time * 0.011, 4.2)) * 0.28;
    let lo = mix(0.62, 0.18, coverage);
    let hi = mix(0.86, 0.48, coverage);
    return smoothstep(lo, hi, n) * smoothstep(0.01, 0.20, d.y);
}

/// Sky radiance without the sun corona/disc (unexposed), plus the cloud
/// clearance the sun term needs. Split from `evalSky` so reflective surfaces
/// can evaluate the expensive part once and the direction-sensitive sun disc
/// along several directions.
struct SkyBase {
    color: vec3<f32>,
    clear: f32,   // 1 - cloud density
    cov: f32,     // cloud coverage
};

fn evalSkyBase(dirIn: vec3<f32>, s: SkyInputs) -> SkyBase {
    let d = normalize(dirIn);
    let sunDir = normalize(s.sunDir);
    let e = sunDir.y;
    let up = clamp(d.y, 0.0, 1.0);
    let horizBand = exp(-abs(d.y) * 5.2);

    // Gradient keyframes: night → dusk → day, by sun elevation.
    let nightZ = vec3<f32>(0.004, 0.007, 0.018);
    let nightH = vec3<f32>(0.018, 0.026, 0.050);
    let duskZ = vec3<f32>(0.11, 0.19, 0.42);
    let duskH = vec3<f32>(0.98, 0.55, 0.30);
    let dayZ = vec3<f32>(0.10, 0.29, 0.74);
    let dayM = vec3<f32>(0.34, 0.58, 0.90);
    let dayH = vec3<f32>(0.74, 0.86, 0.97);
    let tDusk = smoothstep(-0.20, -0.02, e);
    let tDay = smoothstep(0.02, 0.30, e);
    let zen = mix(mix(nightZ, duskZ, tDusk), dayZ, tDay);
    let hor = mix(mix(nightH, duskH, tDusk), dayH, tDay);
    let mid = mix(mix(nightZ, duskZ, tDusk), dayM, tDay);

    var sky: vec3<f32>;
    if (d.y >= 0.0) {
        sky = mix(hor, mid, smoothstep(0.0, 0.36, up));
        sky = mix(sky, zen, smoothstep(0.24, 0.92, up));
    } else {
        let ground = hor * 0.18;
        sky = mix(hor, ground, smoothstep(0.0, 0.30, -d.y));
    }

    // Overcast skies flatten toward grey.
    let cov = clamp(s.cloudCoverage, 0.0, 1.0);
    let lum = dot(sky, vec3<f32>(0.2126, 0.7152, 0.0722));
    sky = mix(sky, vec3<f32>(lum) * 0.85, cov * 0.65);

    // Mie scatter toward the sun azimuth (strongest at dusk).
    let sunCos = max(dot(d, sunDir), 0.0);
    let scatter = pow(sunCos, 6.0) * (0.28 + 0.72 * horizBand);
    sky += s.sunColor * scatter * mix(0.22, 0.65, tDusk * (1.0 - tDay)) * (1.0 - cov * 0.7);

    // Stars and moon behind the clouds.
    let clouds = skyCloudDensity(d, cov, s.time);
    let clearSky = 1.0 - clouds;
    if (s.starIntensity > 0.0 && d.y > 0.0) {
        let star = skyStars(d, s.pixelAngle);
        sky += vec3<f32>(0.9, 0.95, 1.0) * star * s.starIntensity * clearSky * smoothstep(0.0, 0.15, d.y);
    }
    if (s.moonIntensity > 0.0) {
        let moonCos = max(dot(d, normalize(s.moonDir)), 0.0);
        let disc = smoothstep(0.99950, 0.99975, moonCos);
        let glow = pow(moonCos, 200.0) * 0.15;
        sky += vec3<f32>(0.85, 0.9, 1.0) * (disc * 2.5 + glow) * s.moonIntensity * mix(1.0, 0.25, clouds);
    }

    // Clouds lit by the sun by day, faint grey by night.
    if (clouds > 0.0) {
        let dayCloud = mix(vec3<f32>(0.80, 0.85, 0.92), s.sunColor * 1.3 + vec3<f32>(0.30),
                           0.30 + 0.70 * pow(sunCos, 3.0));
        let overcastCloud = vec3<f32>(0.55, 0.58, 0.62);
        var cloudCol = mix(dayCloud, overcastCloud, cov) * mix(0.03, 1.0, tDay);
        cloudCol = mix(cloudCol, duskH * 0.9, tDusk * (1.0 - tDay) * 0.6);
        sky = mix(sky, cloudCol, clouds * 0.85);
    }

    return SkyBase(sky, clearSky, cov);
}

/// Sun corona and HDR disc along `dirIn` (unexposed), hidden below the
/// horizon and behind the clouds of `base`.
fn evalSkySun(dirIn: vec3<f32>, s: SkyInputs, base: SkyBase) -> vec3<f32> {
    let d = normalize(dirIn);
    let sunCos = max(dot(d, normalize(s.sunDir)), 0.0);
    let horizonVis = smoothstep(-0.04, 0.04, d.y);
    let halo = pow(sunCos, 64.0) * 1.35 + pow(sunCos, 12.0) * 0.16;
    let disc = smoothstep(0.99935, 0.99978, sunCos) * 20.0;
    return s.sunColor * (halo * (1.0 - base.cov * 0.6) + disc * base.clear) * horizonVis;
}

fn evalSky(dirIn: vec3<f32>, s: SkyInputs) -> vec3<f32> {
    let base = evalSkyBase(dirIn, s);
    return max(base.color + evalSkySun(dirIn, s, base), vec3<f32>(0.0)) * s.exposure;
}
