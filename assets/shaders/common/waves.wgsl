/// Shared water data (frame `@group(0) @binding(10)`): up to 4 water bodies,
/// each with XZ bounds, water level and its own Gerstner wave set. Mirrors
/// `engine.water.gpu_data` / `engine.water.waves`; every shader that needs to
/// know where the water is (water surface, PBR wetline, caustics) includes
/// this file so they all agree with the CPU queries.
///
/// Requires `common/shadows.wgsl` (frame bind group) to be included first.

struct WaveComp {
    /// dirX, dirZ, wavelength, amplitude.
    a: vec4<f32>,
    /// steepness, speedScale, 0, 0.
    b: vec4<f32>,
};

struct WaterBodyData {
    /// minX, minZ, maxX, maxZ.
    bounds: vec4<f32>,
    /// level, amplitudeScale, recentPeakScale, contactChop.
    surface: vec4<f32>,
    /// groupBase, groupAmp0, groupAmp1, warpAmp0.
    modulation: vec4<f32>,
    /// warpAmp1, channel halfWidth, falloff, edgeScale.
    channelA: vec4<f32>,
    /// channel originX, originZ, dirX, dirZ.
    channelB: vec4<f32>,
    /// x = max wave height per unit amplitude scale, y = caustics strength,
    /// z = flow speed (m/s).
    misc: vec4<f32>,
    /// x = wave count, y = flags.
    info: vec4<u32>,
    waves: array<WaveComp, 8>,
};

struct WaterData {
    /// x = body count.
    header: vec4<u32>,
    bodies: array<WaterBodyData, 4>,
};

@group(0) @binding(10) var<storage, read> waterData: WaterData;

const WATER_FLAG_WETLINE: u32 = 1u;
const WATER_FLAG_CAUSTICS: u32 = 2u;
const WATER_FLAG_RIVER_FLOW: u32 = 4u;
const WATER_TWO_PI: f32 = 6.2831853;

fn waterBodyCount() -> u32 {
    return min(waterData.header.x, 4u);
}

/// Index of the first body whose XZ bounds contain `xz`, or -1.
fn waterBodyAt(xz: vec2<f32>) -> i32 {
    let n = waterBodyCount();
    for (var i = 0u; i < n; i++) {
        let b = waterData.bodies[i].bounds;
        if (xz.x >= b.x && xz.y >= b.y && xz.x <= b.z && xz.y <= b.w) {
            return i32(i);
        }
    }
    return -1;
}

fn waterLevel(bi: u32) -> f32 {
    return waterData.bodies[bi].surface.x;
}

fn waterWaveCount(bi: u32) -> u32 {
    return min(waterData.bodies[bi].info.x, 8u);
}

fn waterFlags(bi: u32) -> u32 {
    return waterData.bodies[bi].info.y;
}

/// Wave-group envelope (`waveGroupEnvelope` in D).
fn waterEnvelope(bi: u32, xz: vec2<f32>, t: f32) -> f32 {
    let m = waterData.bodies[bi].modulation;
    return m.x
         + m.y * sin(t * 0.62 - xz.x * 0.13 + xz.y * 0.16)
         + m.z * cos(t * 0.41 + xz.x * 0.19 + xz.y * 0.11);
}

/// Phase warp (`wavePhaseWarp` in D).
fn waterPhaseWarp(bi: u32, xz: vec2<f32>, t: f32) -> f32 {
    let b = waterData.bodies[bi];
    return b.modulation.w * sin(xz.x * 0.21 - xz.y * 0.17 + t * 0.29)
         + b.channelA.x * cos(xz.x * 0.14 + xz.y * 0.25 - t * 0.22);
}

/// Channel taper (`WaveChannel.scaleAt` in D).
fn waterChannelScale(bi: u32, xz: vec2<f32>) -> f32 {
    let b = waterData.bodies[bi];
    let halfWidth = b.channelA.y;
    if (halfWidth <= 0.0) {
        return 1.0;
    }
    let o = b.channelB.xy;
    let dir = b.channelB.zw;
    let d = abs((xz.x - o.x) * dir.y - (xz.y - o.y) * dir.x);
    if (d <= halfWidth) {
        return 1.0;
    }
    let t = (d - halfWidth) / max(b.channelA.z, 1e-4);
    return select(1.0 - t * (1.0 - b.channelA.w), b.channelA.w, t >= 1.0);
}

/// Wavenumber of component `i`.
fn waterWaveK(w: WaveComp) -> f32 {
    return WATER_TWO_PI / max(w.a.z, 0.1);
}

/// Angular frequency of component `i` for wavenumber `k`.
fn waterWaveOmega(w: WaveComp, k: f32) -> f32 {
    return k * sqrt(9.81 / k) * w.b.y;
}

/// Wave height above the body level at world `xz` (one horizontal pullback,
/// envelope and warp evaluated at `xz`). `ampScale` replaces the body's
/// amplitude scale (wetline history uses past scales). Matches
/// `waveHeightAt(set, x, z, t, 1)` in D.
fn waterWaveY(bi: u32, xz: vec2<f32>, t: f32, ampScale: f32) -> f32 {
    let scale = ampScale * waterChannelScale(bi, xz) * waterEnvelope(bi, xz, t);
    let warp = waterPhaseWarp(bi, xz, t);
    let n = waterWaveCount(bi);

    var disp = vec2<f32>(0.0);
    for (var i = 0u; i < n; i++) {
        let w = waterData.bodies[bi].waves[i];
        let k = waterWaveK(w);
        let a = w.a.w * scale;
        let phase = k * dot(w.a.xy, xz) - waterWaveOmega(w, k) * t + warp * min(k * 0.45, 1.0);
        disp += (w.b.x * a) * w.a.xy * cos(phase);
    }

    let p = xz - disp;
    var y = 0.0;
    for (var i = 0u; i < n; i++) {
        let w = waterData.bodies[bi].waves[i];
        let k = waterWaveK(w);
        let a = w.a.w * scale;
        y += a * sin(k * dot(w.a.xy, p) - waterWaveOmega(w, k) * t + warp * min(k * 0.45, 1.0));
    }
    return y;
}

/// World-space water surface height at `xz` for body `bi` at time `t`.
fn waterSurfaceY(bi: u32, xz: vec2<f32>, t: f32) -> f32 {
    let s = waterData.bodies[bi].surface;
    return s.x + waterWaveY(bi, xz, t, s.y);
}
