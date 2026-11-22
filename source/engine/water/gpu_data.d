/// GPU mirror of the shared water data bound at frame `@group(0) @binding(10)`
/// (`assets/shaders/common/waves.wgsl`).
///
/// One `GpuWaterData` per scene holds up to `MAX_WATER_BODIES` water bodies,
/// each with its XZ bounds, water level and its own `WaveSet`. The water
/// surface, the PBR wetline, generic caustics (PBR and terrain) and
/// `engine.water.query` all read the same numbers, so every system agrees on
/// where the water is.
///
/// `Scene3DTextured.setWaterData` uploads it; `WaterRenderer` fills it from
/// its registered `WaterBody`s.
module engine.water.gpu_data;

import engine.water.waves;

@safe:

/// Maximum water bodies visible to the shaders at once.
enum uint MAX_WATER_BODIES = 4;

/// `GpuWaterBody.info[1]` bits.
enum WaterBodyGpuFlags : uint {
    /// Materials flagged `MaterialFlags.waterWetCaustics` get wave-contact wet marks.
    wetline  = 1u << 0,
    /// Submerged PBR and terrain fragments receive animated sun caustics.
    caustics = 1u << 1,
    /// River-style caustics drift (fast along the flow) instead of the slow ocean drift.
    riverFlow = 1u << 2,
}

/// One Gerstner component (32 bytes, std430).
struct GpuWaveComponent {
    /// dirX, dirZ, wavelength, amplitude.
    float[4] a = [1, 0, 4, 0];
    /// steepness, speedScale, 0, 0.
    float[4] b = [0, 1, 0, 0];
}

/// One water body (368 bytes, std430). Field comments give the WGSL meaning.
struct GpuWaterBody {
    /// minX, minZ, maxX, maxZ (world).
    float[4] bounds = [0, 0, 0, 0];
    /// level (world Y), amplitudeScale, recentPeakScale, contactChop.
    float[4] surface = [0, 1, 1, 1];
    /// groupBase, groupAmp0, groupAmp1, warpAmp0.
    float[4] modulation = [1, 0, 0, 0];
    /// warpAmp1, channel halfWidth, channel falloff, channel edgeScale.
    float[4] channelA = [0, 0, 1, 1];
    /// channel originX, originZ, dirX, dirZ.
    float[4] channelB = [0, 0, 1, 0];
    /// x = highest possible wave height per unit amplitude scale (wetline
    /// early-out), y = caustics strength, z = flow speed (m/s, caustics
    /// drift), w = 0.
    float[4] misc = [0, 0, 0, 0];
    /// x = wave count, y = `WaterBodyGpuFlags`, z/w = 0.
    uint[4] info = [0, 0, 0, 0];
    GpuWaveComponent[MAX_WAVE_COMPONENTS] waves;
}

/// Whole binding (16 + 4 × 368 = 1488 bytes).
struct GpuWaterData {
    /// x = active body count.
    uint[4] header = [0, 0, 0, 0];
    GpuWaterBody[MAX_WATER_BODIES] bodies;

    /// Append a body; returns false when full.
    bool add()(auto ref const GpuWaterBody b) pure nothrow @nogc {
        if (header[0] >= MAX_WATER_BODIES) return false;
        bodies[header[0]++] = b;
        return true;
    }

    /// Remove every body.
    void clear() pure nothrow @nogc { header[0] = 0; }

    /// Active body count.
    uint count() const pure nothrow @nogc { return header[0]; }
}

/// Byte size of the binding (`minBindingSize` of frame binding 10).
enum size_t WATER_DATA_SIZE = GpuWaterData.sizeof;

static assert(GpuWaveComponent.sizeof == 32);
static assert(GpuWaterBody.sizeof == 368);
static assert(WATER_DATA_SIZE == 1488);
static assert(GpuWaterBody.sizeof % 16 == 0);

/// Per-body surface settings that are not part of the wave model.
struct WaterSurfaceGpuParams {
    /// World XZ rectangle: minX, minZ, maxX, maxZ.
    float[4] bounds = [-1e6f, -1e6f, 1e6f, 1e6f];
    /// Rest water height (world Y).
    float level = 0.0f;
    /// Largest amplitude scale reached in the last few seconds (wet marks
    /// left by a storm dry out instead of vanishing). 0 = use the current
    /// `WaveSet.amplitudeScale`.
    float recentPeakScale = 0.0f;
    /// Extra wave height assumed where water hits props (spray / run-up).
    float contactChop = 1.2f;
    /// Caustics brightness (0 disables them for this body).
    float causticsStrength = 0.18f;
    /// Caustics drift speed along the flow (m/s); 0 = slow ocean drift.
    float flowSpeed = 0.0f;
    /// Wet marks on `waterWetCaustics` materials.
    bool wetline = true;
}

/// Pack a body from its wave set and surface settings.
GpuWaterBody packWaterBody(ref const WaveSet waves, ref const WaterSurfaceGpuParams p) pure nothrow @nogc {
    GpuWaterBody g;
    g.bounds = p.bounds;
    immutable peak = p.recentPeakScale > waves.amplitudeScale ? p.recentPeakScale : waves.amplitudeScale;
    g.surface = [p.level, waves.amplitudeScale, peak, p.contactChop];
    immutable m = waves.modulation;
    g.modulation = [m.groupBase, m.groupAmp0, m.groupAmp1, m.warpAmp0];
    immutable c = waves.channel;
    g.channelA = [m.warpAmp1, c.halfWidth, c.falloff, c.edgeScale];
    g.channelB = [c.originX, c.originZ, c.dirX, c.dirZ];

    float ampSum = 0.0f;
    foreach (i, ref w; waves.active) {
        g.waves[i].a = [w.dirX, w.dirZ, w.wavelength, w.amplitude];
        g.waves[i].b = [w.steepness, w.speedScale, 0, 0];
        ampSum += w.amplitude > 0 ? w.amplitude : -w.amplitude;
    }
    immutable envMax = absf(m.groupBase) + absf(m.groupAmp0) + absf(m.groupAmp1);
    immutable chanMax = c.halfWidth > 0 && c.edgeScale > 1.0f ? c.edgeScale : 1.0f;
    g.misc = [ampSum * envMax * chanMax * p.contactChop, p.causticsStrength, p.flowSpeed, 0];

    uint flags = 0;
    if (p.wetline) flags |= WaterBodyGpuFlags.wetline;
    if (p.causticsStrength > 0) flags |= WaterBodyGpuFlags.caustics;
    if (p.flowSpeed > 0) flags |= WaterBodyGpuFlags.riverFlow;
    g.info = [waves.count, flags, 0, 0];
    return g;
}

private float absf(float v) pure nothrow @nogc { return v < 0 ? -v : v; }

@("water gpu_data: pack ocean preset")
unittest {
    auto waves = WaveSet.ocean();
    waves.amplitudeScale = 1.75f;
    WaterSurfaceGpuParams p;
    p.level = 2.0f;
    p.recentPeakScale = 1.0f;
    immutable g = packWaterBody(waves, p);
    assert(g.info[0] == 6);
    assert((g.info[1] & WaterBodyGpuFlags.wetline) != 0);
    assert((g.info[1] & WaterBodyGpuFlags.caustics) != 0);
    assert((g.info[1] & WaterBodyGpuFlags.riverFlow) == 0);
    assert(g.surface == [2.0f, 1.75f, 1.75f, 1.2f]);  // peak never below current
    assert(g.waves[0].a == [0.86f, 0.51f, 9.5f, 0.24f]);
    // Reach bound: amplitudes 0.545 m × envelope 1.12 × chop 1.2.
    assert(g.misc[0] > 0.73f && g.misc[0] < 0.74f);

    GpuWaterData d;
    foreach (_; 0 .. MAX_WATER_BODIES) assert(d.add(g));
    assert(!d.add(g));
    assert(d.count == MAX_WATER_BODIES);
    d.clear();
    assert(d.count == 0);
}
