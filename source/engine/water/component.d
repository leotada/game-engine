/// `WaterSurface`: the scene / editor component for a water body.
///
/// A flat POD (scene files serialize it through reflection) that becomes a
/// full `WaterBody` with `toWaterBody`: the style picks the preset (waves,
/// optics, flow), the entity's `Transform` places it (position = center and
/// water level, rotation turns waves, channel and current around Y) and the
/// remaining fields tune it. `SceneRenderer` draws every entity with
/// `Transform` + `WaterSurface` (up to `MAX_WATER_BODIES`).
module engine.water.component;

import engine.core.pod : isPod;
import engine.math.vec : Vec3;
import engine.reflect.attrs : component, export_, range;
import engine.scene.graph : Transform;
import engine.water.water_body : WaterBody, WaterFeature, WaterStyle;

@safe:

@component
struct WaterSurface {
    /// Preset: ocean swell or river stream (flowing along local +X).
    @export_ WaterStyle style = WaterStyle.ocean;
    /// Half size of the simulated square (m). Oceans draw ~12× farther.
    @export_ @range(1, 1000) float halfExtent = 14.0f;
    /// Wave height multiplier (0 = flat, 1 = preset, 2 = storm).
    @export_ @range(0, 3) float waveScale = 1.0f;
    /// Current multiplier (river current, ocean foam/caustics drift).
    @export_ @range(0, 4) float flowScale = 1.0f;
    /// Caustics brightness multiplier on submerged surfaces (0 = off).
    @export_ @range(0, 4) float causticsScale = 1.0f;
    /// Depth of the fallback bed below the surface (m).
    @export_ @range(0, 20) float bedDepth = 1.15f;
    /// Surface grid cells per side (16..254).
    @export_ @range(16, 254) uint gridResolution = 192;
    /// `WaterFeature` bits (refraction, SSR, transparency, simulation,
    /// OpenPBR, wet marks).
    @export_ uint features = WaterFeature.all;
}

static assert(isPod!WaterSurface);

/// The `WaterBody` described by `c` on an entity at `t`.
WaterBody toWaterBody(ref const WaterSurface c, ref const Transform t) pure nothrow @nogc {
    WaterBody b = c.style == WaterStyle.river ? WaterBody.river() : WaterBody.ocean();
    b.centerX = t.position.x;
    b.centerZ = t.position.z;
    b.level = t.position.y;
    b.halfExtent = c.halfExtent > 1.0f ? c.halfExtent : 1.0f;
    b.gridResolution = c.gridResolution;
    b.waves.amplitudeScale = c.waveScale > 0.0f ? c.waveScale : 0.0f;
    b.features = c.features;
    b.bedDepth = c.bedDepth;
    b.causticsStrength *= c.causticsScale > 0.0f ? c.causticsScale : 0.0f;
    immutable flowK = c.flowScale > 0.0f ? c.flowScale : 0.0f;

    // Turn every direction by the entity's rotation (projected on XZ).
    float[2] turn(float x, float z) {
        immutable v = t.rotation.rotate(Vec3(x, 0.0f, z));
        immutable len = v.x * v.x + v.z * v.z;
        if (len < 1e-12f) return [x, z];
        import std.math : sqrt;
        immutable float s = sqrt((x * x + z * z) / len);
        return [v.x * s, v.z * s];
    }
    foreach (ref w; b.waves.components[0 .. b.waves.count]) {
        immutable d = turn(w.dirX, w.dirZ);
        w.dirX = d[0];
        w.dirZ = d[1];
    }
    immutable cd = turn(b.waves.channel.dirX, b.waves.channel.dirZ);
    b.waves.channel.dirX = cd[0];
    b.waves.channel.dirZ = cd[1];
    immutable co = turn(b.waves.channel.originX, b.waves.channel.originZ);
    b.waves.channel.originX = b.centerX + co[0];
    b.waves.channel.originZ = b.centerZ + co[1];
    immutable f = turn(b.flow[0], b.flow[1]);
    b.flow = [f[0] * flowK, f[1] * flowK];
    return b;
}

unittest {
    import std.math : fabs;
    import engine.math.quat : Quat;

    Transform t;
    t.position = Vec3(10.0f, 2.0f, -4.0f);
    WaterSurface c;
    immutable ocean = toWaterBody(c, t);
    assert(ocean.centerX == 10.0f && ocean.centerZ == -4.0f && ocean.level == 2.0f);
    assert(ocean.style == WaterStyle.ocean);
    assert(ocean.waves.components[0].dirX == WaterBody.ocean().waves.components[0].dirX);

    // A river turned 90° around Y flows along ±Z, with its channel through
    // the entity and its waves turned the same way.
    c.style = WaterStyle.river;
    c.flowScale = 2.0f;
    c.causticsScale = 0.0f;
    t.rotation = Quat.fromEulerYXZ(Vec3(0.0f, 90.0f, 0.0f));
    immutable river = toWaterBody(c, t);
    immutable preset = WaterBody.river();
    assert(fabs(river.flow[0]) < 1e-4f);
    assert(fabs(fabs(river.flow[1]) - preset.flow[0] * 2.0f) < 1e-4f);
    assert(fabs(river.waves.channel.originX - 10.0f) < 1e-4f);
    assert(fabs(fabs(river.waves.channel.dirZ) - 1.0f) < 1e-4f);
    assert(river.causticsStrength == 0.0f);
    immutable w0 = river.waves.components[0];
    immutable p0 = preset.waves.components[0];
    assert(fabs(w0.dirX * w0.dirX + w0.dirZ * w0.dirZ - (p0.dirX * p0.dirX + p0.dirZ * p0.dirZ)) < 1e-4f);
    assert(fabs(w0.dirX - p0.dirX) > 0.1f);
}
