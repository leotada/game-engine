/// Screen-space LOD selection shared by `lodSelectSystem`, `Scene3DTextured`
/// (automatic LOD) and `StaticInstanceBuffer` (per-cell LOD).
module engine.graphics.lod;

@safe:

/// `selectLod` `current` value meaning "no previous level" (no hysteresis).
enum ubyte LOD_NONE = ubyte.max;

/// Projected size in pixels of a world-space length at `distance`.
float projectedPixels(float worldSize, float distance, float fovYRadians, float screenHeight) nothrow @nogc {
    if (distance < 1e-4f)
        distance = 1e-4f;
    immutable denom = 2.0f * distance * tanF(fovYRadians * 0.5f);
    if (!(denom > 0))
        return float.max;
    return worldSize * screenHeight / denom;
}

/// Pixels covered by a mesh-relative simplifier error (`buildLodChain` output).
/// `error * meshScale * worldScale` is the world-space tolerance.
float lodPixels(float relativeError, float meshScale, float worldScale, float distance,
                float fovYRadians, float screenHeight) nothrow @nogc {
    return projectedPixels(relativeError * meshScale * worldScale, distance, fovYRadians, screenHeight);
}

/**
 * Pick the coarsest level whose projected error stays under one pixel
 * (scaled by `bias`). When `current` is a valid level, a 20% band keeps it
 * near the boundary to avoid popping; pass `LOD_NONE` for stateless callers.
 */
ubyte selectLod(scope const(float)[] errors, ubyte current, float meshScale, float worldScale,
                float distance, float fovYRadians, float screenHeight, float bias = 1) nothrow @nogc {
    if (errors.length <= 1)
        return 0;
    ubyte chosen = 0;
    foreach (i; 0 .. errors.length) {
        if (lodPixels(errors[i], meshScale, worldScale, distance, fovYRadians, screenHeight) * bias <= 1)
            chosen = cast(ubyte) i;
    }
    if (current == LOD_NONE || current >= errors.length)
        return chosen;
    if (chosen > current) {
        immutable px = lodPixels(errors[chosen], meshScale, worldScale, distance, fovYRadians, screenHeight) * bias;
        if (px > 0.8f)
            chosen = current;
    } else if (chosen < current) {
        immutable px = lodPixels(errors[current], meshScale, worldScale, distance, fovYRadians, screenHeight) * bias;
        if (px < 1.2f)
            chosen = current;
    }
    return chosen;
}

private float tanF(float x) nothrow @nogc @trusted {
    import core.stdc.math : tanf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &tanf)(x);
}

@("lod.select") nothrow @nogc unittest {
    immutable float[3] errors = [0.0f, 0.01f, 0.05f];
    enum fov = 1.0f, h = 1000.0f;
    // Near: only LOD0 keeps the error under a pixel.
    assert(selectLod(errors[], LOD_NONE, 1, 1, 1, fov, h) == 0);
    // Far: the coarsest level fits.
    assert(selectLod(errors[], LOD_NONE, 1, 1, 1000, fov, h) == 2);
    // Middle: 0.01 error at 20 m ≈ 0.46 px, 0.05 ≈ 2.3 px → LOD1.
    assert(selectLod(errors[], LOD_NONE, 1, 1, 20, fov, h) == 1);
    // Larger world scale needs more distance for the same level.
    assert(selectLod(errors[], LOD_NONE, 1, 10, 20, fov, h) == 0);
    // No chain.
    assert(selectLod(errors[0 .. 1], LOD_NONE, 1, 1, 1000, fov, h) == 0);
}

@("lod.hysteresis") nothrow @nogc unittest {
    immutable float[2] errors = [0.0f, 0.01f];
    enum fov = 1.0f, h = 1000.0f;
    // px = 0.01 * 1000 / (2 d tan 0.5): the 1 px boundary for LOD1 is at d ≈ 9.15.
    // At d = 10 (≈0.915 px) a fresh pick is LOD1, but coming from LOD0 the
    // 0.8 px band keeps LOD0 until the error drops further.
    assert(selectLod(errors[], LOD_NONE, 1, 1, 10, fov, h) == 1);
    assert(selectLod(errors[], 0, 1, 1, 10, fov, h) == 0);
    assert(selectLod(errors[], 0, 1, 1, 20, fov, h) == 1);
    // Coming back from LOD1 at d = 8.5 (≈1.08 px) stays on LOD1 until 1.2 px.
    assert(selectLod(errors[], 1, 1, 1, 8.5f, fov, h) == 1);
    assert(selectLod(errors[], 1, 1, 1, 5, fov, h) == 0);
}
