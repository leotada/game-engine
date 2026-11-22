/// Water body description: a POD value that says where a body of water is,
/// how it moves and how it looks. `WaterRenderer` draws it, `GpuWaterData`
/// shares its waves with every shader, and the ECS stores it as a component.
module engine.water.water_body;

import engine.water.gpu_data : WaterSurfaceGpuParams;
import engine.water.waves : WaveSet;

@safe:

/// Surface type. Selects the surface algorithms (like HDRP's Ocean / River
/// water surface types); colors and absorption come from `WaterOptics`.
enum WaterStyle : uint {
    /// Open water: the grid stretches into a far skirt (12× the half extent),
    /// broad swells, crest whitecaps, horizon haze.
    ocean = 0,
    /// Channel flow: current along the wave channel, obstacle wakes, shore
    /// foam, no skirt.
    river = 1,
}

/// Feature switches for one body (`WaterBody.features`).
enum WaterFeature : uint {
    /// Screen-space refraction from the opaque snapshot (needs `Renderer.snapshotOpaque`).
    refraction  = 1 << 0,
    /// Screen-space reflections against the opaque snapshot.
    ssr         = 1 << 1,
    /// Alpha-blend the surface over the scene (off = opaque water).
    transparent = 1 << 2,
    /// GPU wave/foam simulation (256² compute ping-pong per body).
    simulation  = 1 << 3,
    /// OpenPBR coat + fuzz layering (off = plain GGX dielectric).
    openPbr     = 1 << 4,
    /// Wave-contact wet marks on props with `MaterialFlags.waterWetCaustics`.
    wetline     = 1 << 5,

    all = refraction | ssr | transparent | simulation | openPbr | wetline,
}

/// Optical look of the water volume and surface.
struct WaterOptics {
    /// Beer-Lambert absorption per meter (RGB); red should absorb fastest.
    float[3] absorption = [1.65f, 0.56f, 0.34f];
    /// Scattered color in shallow water.
    float[3] shallowColor = [0.03f, 0.20f, 0.26f];
    /// Scattered color in deep water.
    float[3] deepColor = [0.008f, 0.052f, 0.115f];
    /// OpenPBR coat absorption tint.
    float[3] coatColor = [0.70f, 0.92f, 1.00f];
    /// Subsurface tint of backlit wave crests.
    float[3] sssTint = [0.02f, 0.15f, 0.18f];
    /// Specular roughness of the liquid (OpenPBR path).
    float roughness = 0.075f;
    /// Specular anisotropy along the flow (OpenPBR path).
    float anisotropy = 0.20f;

    /// Deep-navy open ocean with turquoise shallows.
    static WaterOptics ocean() pure nothrow @nogc { return WaterOptics.init; }

    /// Clear mineral aqua river turning alpine emerald with depth.
    static WaterOptics river() pure nothrow @nogc {
        WaterOptics o;
        o.absorption = [1.35f, 0.44f, 0.52f];
        o.shallowColor = [0.05f, 0.24f, 0.20f];
        o.deepColor = [0.015f, 0.095f, 0.090f];
        o.coatColor = [0.76f, 0.96f, 0.92f];
        o.sssTint = [0.03f, 0.16f, 0.14f];
        o.roughness = 0.12f;
        o.anisotropy = 0.45f;
        return o;
    }
}

/// Up to `MAX_WATER_OBSTACLES` vertical cylinders (rocks, piers) that deflect
/// the current, raise chop and spawn wake/contact foam.
enum uint MAX_WATER_OBSTACLES = 16;

/// One obstacle: world XZ center, waterline radius, effect strength (0..1).
struct WaterObstacle {
    float x = 0.0f;
    float z = 0.0f;
    float radius = 0.5f;
    float strength = 1.0f;
}

/// A rectangular body of water centered at (`centerX`, `centerZ`).
struct WaterBody {
    /// World XZ center of the surface grid.
    float centerX = 0.0f;
    /// ditto
    float centerZ = 0.0f;
    /// Half size of the square surface grid (m). Ocean bodies stretch the
    /// outer ring of the grid to 12× this radius.
    float halfExtent = 14.0f;
    /// Rest water height (world Y).
    float level = 0.0f;
    /// Grid cells per side (2..254).
    uint gridResolution = 192;
    WaterStyle style = WaterStyle.ocean;
    WaveSet waves = WaveSet.ocean();
    WaterOptics optics;
    /// `WaterFeature` bits.
    uint features = WaterFeature.all;

    /// Water column depth used where the depth buffer gives no answer
    /// (refraction off): the bed is assumed `bedDepth` below `level`.
    float bedDepth = 1.15f;
    /// Surface current (m/s, world XZ). Rivers flow along their wave channel.
    float[2] flow = [0.22f, 0.14f];
    /// River only: half width of the current profile across the channel
    /// (fastest at the center line, ~45% slower at this distance).
    float flowProfileWidth = 6.8f;
    /// Extra margin (m) around the grid where props still get wet marks.
    float wetMargin = 2.0f;
    /// Wave height multiplier used for wet marks on props.
    float contactChop = 1.2f;
    /// Largest `waves.amplitudeScale` reached recently (wet marks dry out
    /// instead of vanishing when a storm calms). 0 = current scale.
    float recentPeakScale = 0.0f;
    /// Caustics brightness on submerged surfaces (0 disables them).
    float causticsStrength = 0.18f;

    /// Open ocean preset: ocean waves, deep-navy optics, 14 m grid + far skirt.
    static WaterBody ocean() pure nothrow @nogc { return WaterBody.init; }

    /// River preset: channel along +X (±4.5 m), 1.35 m/s current, clear
    /// mineral optics, stronger contact chop.
    static WaterBody river() pure nothrow @nogc {
        WaterBody b;
        b.style = WaterStyle.river;
        b.waves = WaveSet.river();
        b.optics = WaterOptics.river();
        b.flow = [1.35f, 0.0f];
        b.contactChop = 1.38f;
        b.causticsStrength = 0.09f;
        return b;
    }

    bool has(WaterFeature f) const pure nothrow @nogc { return (features & f) != 0; }

    /// Far radius of the visible surface around the center (skirt included).
    float visibleRadius() const pure nothrow @nogc {
        return style == WaterStyle.ocean ? halfExtent * 12.0f : halfExtent;
    }

    /// Shared-buffer parameters (`packWaterBody`) for this body.
    WaterSurfaceGpuParams gpuParams() const pure nothrow @nogc {
        WaterSurfaceGpuParams p;
        immutable r = visibleRadius() + wetMargin;
        p.bounds = [centerX - r, centerZ - r, centerX + r, centerZ + r];
        p.level = level;
        p.recentPeakScale = recentPeakScale;
        p.contactChop = contactChop;
        p.causticsStrength = causticsStrength;
        immutable fx = flow[0], fz = flow[1];
        p.flowSpeed = style == WaterStyle.river ? (fx * fx + fz * fz) ^^ 0.5f : 0.0f;
        p.wetline = has(WaterFeature.wetline);
        return p;
    }
}

unittest {
    import engine.core.pod : isPod;
    static assert(isPod!WaterBody);
    static assert(isPod!WaterObstacle);

    immutable o = WaterBody.ocean();
    assert(o.style == WaterStyle.ocean && o.has(WaterFeature.simulation));
    immutable op = o.gpuParams();
    assert(op.bounds[2] == 14.0f * 12.0f + 2.0f && op.flowSpeed == 0.0f && op.wetline);

    auto r = WaterBody.river();
    r.centerX = 10.0f;
    r.features &= ~WaterFeature.wetline;
    immutable rp = r.gpuParams();
    assert(rp.bounds[0] == 10.0f - 16.0f && rp.bounds[3] == 16.0f);
    assert(rp.flowSpeed > 1.34f && rp.flowSpeed < 1.36f);
    assert(!rp.wetline && rp.contactChop == 1.38f);
}
