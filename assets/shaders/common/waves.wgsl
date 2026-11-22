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
    /// steepness, k (2π/wavelength), omega (k·phase speed), phase-warp scale.
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
/// Note: read single fields (`waterData.bodies[bi].x`), never copy a whole
/// body into a local: that loads all 368 bytes per call.
fn waterPhaseWarp(bi: u32, xz: vec2<f32>, t: f32) -> f32 {
    return waterData.bodies[bi].modulation.w * sin(xz.x * 0.21 - xz.y * 0.17 + t * 0.29)
         + waterData.bodies[bi].channelA.x * cos(xz.x * 0.14 + xz.y * 0.25 - t * 0.22);
}

/// Channel taper (`WaveChannel.scaleAt` in D).
fn waterChannelScale(bi: u32, xz: vec2<f32>) -> f32 {
    let ca = waterData.bodies[bi].channelA;
    let halfWidth = ca.y;
    if (halfWidth <= 0.0) {
        return 1.0;
    }
    let cb = waterData.bodies[bi].channelB;
    let d = abs((xz.x - cb.x) * cb.w - (xz.y - cb.y) * cb.z);
    if (d <= halfWidth) {
        return 1.0;
    }
    let t = (d - halfWidth) / max(ca.z, 1e-4);
    return select(1.0 - t * (1.0 - ca.w), ca.w, t >= 1.0);
}


/// One body's wave data loaded once for a fixed point, for code that
/// evaluates the same point at many times (the wetline history samples 25
/// times per fragment): the buffer is read once instead of per sample.
struct WaterPoint {
    waves: array<WaveComp, 8>,
    modulation: vec4<f32>,   // groupBase, groupAmp0, groupAmp1, warpAmp0
    xz: vec2<f32>,
    channel: f32,            // channel taper at xz (time independent)
    warpAmp1: f32,
    n: u32,
};

fn waterPointAt(bi: u32, xz: vec2<f32>) -> WaterPoint {
    var p: WaterPoint;
    p.waves = waterData.bodies[bi].waves;
    p.modulation = waterData.bodies[bi].modulation;
    p.xz = xz;
    p.channel = waterChannelScale(bi, xz);
    p.warpAmp1 = waterData.bodies[bi].channelA.x;
    p.n = waterWaveCount(bi);
    return p;
}

/// Wave height above the body level at the point at time `t` (one
/// horizontal pullback, envelope and warp evaluated at the point).
/// `ampScale` replaces the body's amplitude scale. Matches
/// `waveHeightAt(set, x, z, t, 1)` in D.
fn waterPointY(p: WaterPoint, t: f32, ampScale: f32) -> f32 {
    let xz = p.xz;
    let m = p.modulation;
    let env = m.x
            + m.y * sin(t * 0.62 - xz.x * 0.13 + xz.y * 0.16)
            + m.z * cos(t * 0.41 + xz.x * 0.19 + xz.y * 0.11);
    let warp = m.w * sin(xz.x * 0.21 - xz.y * 0.17 + t * 0.29)
             + p.warpAmp1 * cos(xz.x * 0.14 + xz.y * 0.25 - t * 0.22);
    let scale = ampScale * p.channel * env;

    var disp = vec2<f32>(0.0);
    for (var i = 0u; i < 8u; i++) {
        if (i >= p.n) { break; }
        let w = p.waves[i];
        let a = w.a.w * scale;
        let phase = w.b.y * dot(w.a.xy, xz) - w.b.z * t + warp * w.b.w;
        disp += (w.b.x * a) * w.a.xy * cos(phase);
    }

    let q = xz - disp;
    var y = 0.0;
    for (var i = 0u; i < 8u; i++) {
        if (i >= p.n) { break; }
        let w = p.waves[i];
        y += w.a.w * scale * sin(w.b.y * dot(w.a.xy, q) - w.b.z * t + warp * w.b.w);
    }
    return y;
}

/// Wave height above body `bi`'s level at world `xz` and time `t`
/// (`ampScale` replaces the body's amplitude scale).
fn waterWaveY(bi: u32, xz: vec2<f32>, t: f32, ampScale: f32) -> f32 {
    return waterPointY(waterPointAt(bi, xz), t, ampScale);
}

/// World-space water surface height at `xz` for body `bi` at time `t`.
fn waterSurfaceY(bi: u32, xz: vec2<f32>, t: f32) -> f32 {
    let s = waterData.bodies[bi].surface;
    return s.x + waterWaveY(bi, xz, t, s.y);
}
