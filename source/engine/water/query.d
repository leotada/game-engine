/// Gameplay water queries on the CPU: surface height, normal and current at a
/// world XZ point. They evaluate the same `WaveSet` the GPU draws, so a
/// floating object sits on the visible waves.
module engine.water.query;

import engine.math.vec : Vec3;
import engine.water.water_body : WaterBody, WaterStyle;
import engine.water.waves : sampleWaves, waveHeightAt;

@safe:

/// Water surface at one point.
struct WaterSurfacePoint {
    /// World Y of the surface (rest level + waves).
    float height = 0.0f;
    /// Surface normal (approximate: from the Lagrangian sample at the point).
    Vec3 normal = Vec3(0.0f, 1.0f, 0.0f);
    /// Water current (m/s, world). Rivers flow along their channel with a
    /// center-fast profile; ocean bodies report zero (their `flow` is a
    /// visual drift of foam and caustics).
    Vec3 current = Vec3(0.0f, 0.0f, 0.0f);
}

/// True when world `xz` is inside the body's area (the same bounds the GPU
/// uses for wet marks and caustics).
bool waterBodyContains(ref const WaterBody b, float x, float z) pure nothrow @nogc {
    immutable p = b.gpuParams();
    return x >= p.bounds[0] && z >= p.bounds[1] && x <= p.bounds[2] && z <= p.bounds[3];
}

/// World Y of the water surface above `xz` at `time`. `iterations` refines
/// the horizontal Gerstner pullback (1 = the GPU wetline, 3 = gameplay).
float waterSurfaceHeight(ref const WaterBody b, float x, float z, float time,
                         uint iterations = 3) pure nothrow @nogc {
    return b.level + waveHeightAt(b.waves, x, z, time, iterations);
}

/// Height, normal and current of `b` above `xz` at `time`.
WaterSurfacePoint waterSurfaceAt(ref const WaterBody b, float x, float z, float time,
                                 uint iterations = 3) pure nothrow @nogc {
    WaterSurfacePoint p;
    p.height = waterSurfaceHeight(b, x, z, time, iterations);
    p.normal = sampleWaves(b.waves, x, z, time).normal;
    if (b.style == WaterStyle.river) {
        immutable ch = b.waves.channel;
        immutable across = (z - ch.originZ) * ch.dirX - (x - ch.originX) * ch.dirZ;
        immutable w = b.flowProfileWidth > 0.1f ? b.flowProfileWidth : 0.1f;
        immutable r = across / w;
        float f = 1.0f - r * r * 0.55f;
        f = f < 0.35f ? 0.35f : (f > 1.05f ? 1.05f : f);
        p.current = Vec3(b.flow[0] * f, 0.0f, b.flow[1] * f);
    }
    return p;
}

/// CPU-only set of water bodies (servers, tools, tests). `WaterRenderer`
/// offers the same `surfaceAt` over the bodies it draws.
struct WaterQuery {
    const(WaterBody)[] bodies;

    /// Surface of the first body containing `xz` (GPU order). False when the
    /// point is outside every body.
    bool surfaceAt(float x, float z, float time, out WaterSurfacePoint result,
                   uint iterations = 3) const scope pure nothrow @nogc {
        foreach (ref b; bodies) {
            if (!waterBodyContains(b, x, z)) continue;
            result = waterSurfaceAt(b, x, z, time, iterations);
            return true;
        }
        return false;
    }
}

unittest {
    import std.math : fabs;

    WaterBody b = WaterBody.river();
    b.level = 2.0f;
    immutable h = waterSurfaceHeight(b, 1.0f, 0.5f, 3.0f);
    assert(fabs(h - 2.0f) < 0.5f);
    assert(fabs(h - (2.0f + waveHeightAt(b.waves, 1.0f, 0.5f, 3.0f, 3))) < 1e-6f);

    immutable centre = waterSurfaceAt(b, 0.0f, 0.0f, 0.0f);
    immutable bank = waterSurfaceAt(b, 0.0f, 6.8f, 0.0f);
    assert(centre.current.x > bank.current.x && bank.current.x > 0.0f);
    assert(fabs(centre.current.x - 1.35f) < 1e-5f);
    assert(centre.normal.y > 0.8f);

    immutable oceanBody = WaterBody.ocean();
    immutable ocean = waterSurfaceAt(oceanBody, 3.0f, 4.0f, 1.0f);
    assert(ocean.current.x == 0.0f && ocean.current.z == 0.0f);

    WaterBody[2] set = [b, WaterBody.ocean()];
    set[1].centerX = 500.0f;
    const q = WaterQuery(set[]);
    WaterSurfacePoint p;
    assert(q.surfaceAt(0.0f, 0.0f, 0.0f, p) && p.height > 1.5f);
    assert(q.surfaceAt(500.0f, 0.0f, 0.0f, p) && p.height < 1.0f);
    assert(!q.surfaceAt(5000.0f, 0.0f, 0.0f, p));
}
