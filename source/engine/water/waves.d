/// Gerstner wave model shared by water rendering, wetness, caustics and
/// gameplay queries.
///
/// A `WaveSet` is plain POD data: up to `MAX_WAVE_COMPONENTS` directional
/// Gerstner components plus three optional modifiers that the old water demo
/// hard-coded:
///
/// - `WaveModulation` — slow wave-group envelope and phase warp, so the swell
///   does not look like a perfectly periodic sum of sines.
/// - `WaveChannel` — tapers the amplitude away from a channel center line
///   (river banks).
/// - `amplitudeScale` — global runtime scale (calm / moderate / stormy).
///
/// Two CPU evaluators are provided:
///
/// - `sampleWaves` evaluates the displaced (Lagrangian) surface point of an
///   undisplaced grid coordinate — what the water vertex shader does.
/// - `waveHeightAt` answers "how high is the water above this world XZ?" by
///   undoing the horizontal displacement with fixed-point iterations. One
///   iteration matches the PBR wetline shader exactly; more iterations
///   converge on the true surface height for gameplay (buoyancy, splashes).
///
/// The same data is uploaded to the GPU (see `docs/water-guide.md`), so the
/// CPU and every shader agree on where the water is.
module engine.water.waves;

import std.math : cos, fabs, sin, sqrt, PI;

import engine.math.vec : Vec3;

@safe:

/// Maximum number of Gerstner components in one `WaveSet` (GPU buffer size).
enum uint MAX_WAVE_COMPONENTS = 8;

/// Standard gravity used for the deep-water dispersion relation.
enum float WAVE_GRAVITY = 9.81f;

/// One directional Gerstner wave.
struct WaveComponent {
    /// Unit propagation direction on the XZ plane.
    float dirX = 1.0f;
    float dirZ = 0.0f;
    /// Crest-to-crest distance in meters (clamped to >= 0.1).
    float wavelength = 4.0f;
    /// Vertical amplitude in meters before `WaveSet.amplitudeScale`.
    float amplitude = 0.1f;
    /// Gerstner steepness Q in [0, 1]: horizontal crest sharpening.
    float steepness = 0.4f;
    /// Multiplier on the deep-water phase speed `sqrt(g / k)`.
    float speedScale = 1.0f;
}

/// Wave-group envelope and phase warp.
///
/// envelope = groupBase + groupAmp0 * sin(0.62 t - 0.13 x + 0.16 z)
///                      + groupAmp1 * cos(0.41 t + 0.19 x + 0.11 z)
/// warp     = warpAmp0 * sin(0.21 x - 0.17 z + 0.29 t)
///          + warpAmp1 * cos(0.14 x + 0.25 z - 0.22 t)
///
/// The warp is added to each component's phase, scaled by min(0.45 k, 1) so
/// long swells are barely affected. The defaults disable both (envelope 1,
/// warp 0), giving a pure sum of Gerstner waves.
struct WaveModulation {
    float groupBase = 1.0f;
    float groupAmp0 = 0.0f;
    float groupAmp1 = 0.0f;
    float warpAmp0 = 0.0f;
    float warpAmp1 = 0.0f;
}

/// Amplitude taper away from a channel center line (river banks).
///
/// Distance is measured perpendicular to the line through
/// (`originX`, `originZ`) with direction (`dirX`, `dirZ`). Inside
/// `halfWidth` the scale is 1; it falls linearly to `edgeScale` over
/// `falloff` meters and stays there. `halfWidth <= 0` disables the taper.
struct WaveChannel {
    float originX = 0.0f;
    float originZ = 0.0f;
    float dirX = 1.0f;
    float dirZ = 0.0f;
    float halfWidth = 0.0f;
    float falloff = 1.0f;
    float edgeScale = 1.0f;

    /// Amplitude multiplier at world XZ.
    float scaleAt(float x, float z) const pure nothrow @nogc {
        if (halfWidth <= 0.0f) return 1.0f;
        immutable d = fabs((x - originX) * dirZ - (z - originZ) * dirX);
        if (d <= halfWidth) return 1.0f;
        immutable f = falloff > 1e-4f ? falloff : 1e-4f;
        immutable t = (d - halfWidth) / f;
        return t >= 1.0f ? edgeScale : 1.0f - t * (1.0f - edgeScale);
    }
}

/// A complete wave description (POD; safe for engine storage and GPU upload).
struct WaveSet {
    WaveComponent[MAX_WAVE_COMPONENTS] components;
    uint count;
    /// Global runtime amplitude multiplier (e.g. 0.35 calm, 1 moderate, 1.75 stormy).
    float amplitudeScale = 1.0f;
    WaveModulation modulation;
    WaveChannel channel;

    /// Active components.
    const(WaveComponent)[] active() const return pure nothrow @nogc {
        return components[0 .. count];
    }

    /// Append a component. Returns false when the set is full.
    bool add(WaveComponent c) pure nothrow @nogc {
        if (count >= MAX_WAVE_COMPONENTS) return false;
        components[count++] = c;
        return true;
    }

    /// Open-ocean swell (Beaufort ~5 at `amplitudeScale = 1`), six octaves
    /// from 9.5 m to 1.15 m with wave-group modulation.
    static WaveSet ocean() pure nothrow @nogc {
        WaveSet s;
        s.add(WaveComponent( 0.86f,  0.51f, 9.5f,  0.24f,  0.52f, 1.00f));
        s.add(WaveComponent( 0.42f, -0.91f, 6.2f,  0.14f,  0.48f, 1.15f));
        s.add(WaveComponent(-0.68f,  0.73f, 4.1f,  0.08f,  0.44f, 1.25f));
        s.add(WaveComponent( 0.96f, -0.28f, 2.7f,  0.045f, 0.40f, 1.35f));
        s.add(WaveComponent(-0.22f, -0.97f, 1.8f,  0.025f, 0.35f, 1.50f));
        s.add(WaveComponent( 0.61f,  0.79f, 1.15f, 0.015f, 0.30f, 1.65f));
        s.modulation = defaultModulation();
        return s;
    }

    /// Fast stream flowing toward +X: short, quick ripples, tapered toward
    /// the banks (|z| > 4.5 m, down to 15% at 8 m).
    static WaveSet river() pure nothrow @nogc {
        WaveSet s;
        s.add(WaveComponent(0.96f,  0.28f, 4.4f,  0.075f, 0.40f, 1.65f));
        s.add(WaveComponent(0.92f, -0.39f, 3.1f,  0.055f, 0.42f, 1.80f));
        s.add(WaveComponent(0.78f,  0.62f, 2.1f,  0.038f, 0.44f, 1.95f));
        s.add(WaveComponent(0.85f, -0.52f, 1.45f, 0.024f, 0.38f, 2.15f));
        s.add(WaveComponent(0.99f,  0.14f, 0.95f, 0.014f, 0.34f, 2.30f));
        s.add(WaveComponent(0.72f, -0.69f, 0.68f, 0.009f, 0.28f, 2.45f));
        s.modulation = defaultModulation();
        s.channel = WaveChannel(0.0f, 0.0f, 1.0f, 0.0f, 4.5f, 3.5f, 0.15f);
        return s;
    }

    private static WaveModulation defaultModulation() pure nothrow @nogc {
        return WaveModulation(0.68f, 0.26f, 0.18f, 0.85f, 0.55f);
    }
}

static assert(WaveComponent.sizeof == 24);

/// Result of `sampleWaves`.
struct WaveSample {
    /// Displaced surface point (water level 0).
    Vec3 position;
    /// Unit surface normal.
    Vec3 normal;
    /// Unit tangent along +X, orthogonal to `normal`.
    Vec3 tangent;
    /// Crest factor in [0, 1]: high on wave peaks and where the surface
    /// folds (Jacobian < 0.88), usable for foam and spray.
    float crest;
}

/// Envelope × channel × global amplitude multiplier at world XZ.
float waveAmplitudeScale(ref const WaveSet set, float x, float z, float time) pure nothrow @nogc {
    return set.amplitudeScale * set.channel.scaleAt(x, z) * waveGroupEnvelope(set.modulation, x, z, time);
}

/// Wave-group envelope of `WaveModulation` at world XZ.
float waveGroupEnvelope(ref const WaveModulation m, float x, float z, float time) pure nothrow @nogc {
    return m.groupBase
        + m.groupAmp0 * sin(time * 0.62f - x * 0.13f + z * 0.16f)
        + m.groupAmp1 * cos(time * 0.41f + x * 0.19f + z * 0.11f);
}

/// Phase warp of `WaveModulation` at world XZ (before the per-wave k scale).
float wavePhaseWarp(ref const WaveModulation m, float x, float z, float time) pure nothrow @nogc {
    return m.warpAmp0 * sin(x * 0.21f - z * 0.17f + time * 0.29f)
         + m.warpAmp1 * cos(x * 0.14f + z * 0.25f - time * 0.22f);
}

/// Per-component constants derived from a `WaveComponent` (also uploaded to
/// the GPU by `packWaterBody`).
package struct WaveTerms {
    float k;
    float omega;
    float warpScale;
}

package WaveTerms waveTerms(ref const WaveComponent w) pure nothrow @nogc {
    immutable len = w.wavelength > 0.1f ? w.wavelength : 0.1f;
    immutable k = (2.0f * cast(float) PI) / len;
    immutable c = sqrt(WAVE_GRAVITY / k) * w.speedScale;
    immutable ws = k * 0.45f < 1.0f ? k * 0.45f : 1.0f;
    return WaveTerms(k, k * c, ws);
}

/// Displaced surface point, normal, tangent and crest factor for the
/// undisplaced coordinate (`x`, `z`) at `time` seconds.
WaveSample sampleWaves(ref const WaveSet set, float x, float z, float time) pure nothrow @nogc {
    Vec3 p = Vec3(x, 0.0f, z);
    Vec3 dPdx = Vec3(1.0f, 0.0f, 0.0f);
    Vec3 dPdz = Vec3(0.0f, 0.0f, 1.0f);

    immutable scale = waveAmplitudeScale(set, x, z, time);
    immutable warp = wavePhaseWarp(set.modulation, x, z, time);
    float crestAccum = 0.0f;

    foreach (ref w; set.active) {
        immutable t = waveTerms(w);
        immutable a = w.amplitude * scale;
        immutable q = w.steepness;
        immutable phase = t.k * (w.dirX * x + w.dirZ * z) - t.omega * time + warp * t.warpScale;
        immutable sn = sin(phase);
        immutable cs = cos(phase);

        immutable qa = q * a;
        p.x += qa * w.dirX * cs;
        p.y += a * sn;
        p.z += qa * w.dirZ * cs;
        crestAccum += (sn * 0.5f + 0.5f) * (0.65f + 0.35f * q);

        immutable ka = t.k * a;
        immutable qka = q * ka;
        dPdx.x -= qka * w.dirX * w.dirX * sn;
        dPdx.y += ka * w.dirX * cs;
        dPdx.z -= qka * w.dirX * w.dirZ * sn;

        dPdz.x -= qka * w.dirX * w.dirZ * sn;
        dPdz.y += ka * w.dirZ * cs;
        dPdz.z -= qka * w.dirZ * w.dirZ * sn;
    }

    WaveSample s;
    s.position = p;
    s.normal = dPdz.cross(dPdx).normalized();
    immutable tx = dPdx.normalized();
    s.tangent = (tx - s.normal * s.normal.dot(tx)).normalized();

    immutable n = set.count > 0 ? cast(float) set.count : 1.0f;
    immutable jacobian = dPdx.x * dPdz.z - dPdx.z * dPdz.x;
    immutable fold = clamp01((0.88f - jacobian) * 1.35f);
    immutable peak = crestAccum / n;
    s.crest = clamp01(peak > fold ? peak : fold);
    return s;
}

/// Water surface height above world (`x`, `z`) at `time` seconds (water
/// level 0).
///
/// Gerstner waves move surface points horizontally, so the point above
/// (`x`, `z`) comes from a different undisplaced coordinate. This undoes the
/// horizontal displacement with `iterations` fixed-point steps; the wave
/// envelope and phase warp are evaluated once at (`x`, `z`).
/// `iterations = 1` matches the GPU wetline (`evalExactWaveY`); 3–4 is
/// accurate to millimeters for steepness <= 0.6.
float waveHeightAt(ref const WaveSet set, float x, float z, float time, uint iterations = 1) pure nothrow @nogc {
    immutable scale = waveAmplitudeScale(set, x, z, time);
    immutable warp = wavePhaseWarp(set.modulation, x, z, time);

    float ux = x;
    float uz = z;
    foreach (_; 0 .. iterations) {
        float dx = 0.0f;
        float dz = 0.0f;
        foreach (ref w; set.active) {
            immutable t = waveTerms(w);
            immutable a = w.amplitude * scale;
            immutable phase = t.k * (w.dirX * ux + w.dirZ * uz) - t.omega * time + warp * t.warpScale;
            immutable h = w.steepness * a * cos(phase);
            dx += h * w.dirX;
            dz += h * w.dirZ;
        }
        ux = x - dx;
        uz = z - dz;
    }

    float y = 0.0f;
    foreach (ref w; set.active) {
        immutable t = waveTerms(w);
        immutable a = w.amplitude * scale;
        y += a * sin(t.k * (w.dirX * ux + w.dirZ * uz) - t.omega * time + warp * t.warpScale);
    }
    return y;
}

private float clamp01(float v) pure nothrow @nogc {
    return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
    private bool near(float a, float b, float eps) pure nothrow @nogc {
        return fabs(a - b) <= eps;
    }

    // Verbatim copy of the pre-port `sampleGerstner` from source/demo/water.d
    // (position + normal only), used as the golden reference for the presets.
    private Vec3[2] legacyGerstner(scope const(WaveComponent)[] waves, float x, float z,
                                   float time, bool riverMode, float waveScale) pure nothrow @nogc {
        Vec3 p = Vec3(x, 0.0f, z);
        Vec3 dPdx = Vec3(1.0f, 0.0f, 0.0f);
        Vec3 dPdz = Vec3(0.0f, 0.0f, 1.0f);
        float bankMask = 1.0f;
        if (riverMode) {
            immutable absZ = fabs(z);
            if (absZ > 4.5f) {
                immutable t = (absZ - 4.5f) / 3.5f;
                bankMask = t >= 1.0f ? 0.15f : 1.0f - t * 0.85f;
            }
        }
        immutable float waveSet = 0.68f
            + 0.26f * sin(time * 0.62f - x * 0.13f + z * 0.16f)
            + 0.18f * cos(time * 0.41f + x * 0.19f + z * 0.11f);
        immutable float phaseWarp = 0.85f * sin(x * 0.21f - z * 0.17f + time * 0.29f)
            + 0.55f * cos(x * 0.14f + z * 0.25f - time * 0.22f);
        foreach (ref w; waves) {
            immutable k = (2.0f * cast(float) PI) / w.wavelength;
            immutable c = sqrt(9.81f / k) * w.speedScale;
            immutable a = w.amplitude * waveScale * bankMask * waveSet;
            immutable q = w.steepness;
            immutable warpScale = k * 0.45f < 1.0f ? k * 0.45f : 1.0f;
            immutable phase = k * (w.dirX * x + w.dirZ * z) - k * c * time + phaseWarp * warpScale;
            immutable sn = sin(phase);
            immutable cs = cos(phase);
            immutable qa = q * a;
            p.x += qa * w.dirX * cs;
            p.y += a * sn;
            p.z += qa * w.dirZ * cs;
            immutable wa = k * a;
            immutable qwa = q * wa;
            dPdx.x -= qwa * w.dirX * w.dirX * sn;
            dPdx.y += wa * w.dirX * cs;
            dPdx.z -= qwa * w.dirX * w.dirZ * sn;
            dPdz.x -= qwa * w.dirX * w.dirZ * sn;
            dPdz.y += wa * w.dirZ * cs;
            dPdz.z -= qwa * w.dirZ * w.dirZ * sn;
        }
        return [p, dPdz.cross(dPdx).normalized()];
    }
}

@("waves: empty set is a flat plane")
unittest {
    WaveSet s;
    immutable w = sampleWaves(s, 3.0f, -2.0f, 1.5f);
    assert(w.position == Vec3(3.0f, 0.0f, -2.0f));
    assert(near(w.normal.y, 1.0f, 1e-6f));
    assert(near(w.tangent.x, 1.0f, 1e-6f));
    assert(waveHeightAt(s, 3.0f, -2.0f, 1.5f, 4) == 0.0f);
}

@("waves: presets match the legacy water demo sampler")
unittest {
    immutable float[3] scales = [0.35f, 1.0f, 1.75f];
    foreach (river; [false, true]) {
        foreach (scale; scales) {
            WaveSet s = river ? WaveSet.river() : WaveSet.ocean();
            s.amplitudeScale = scale;
            foreach (i; 0 .. 40) {
                immutable x = -13.0f + i * 0.67f;
                immutable z = 9.0f - i * 0.45f;
                immutable t = 0.25f + i * 0.37f;
                immutable ref_ = legacyGerstner(s.active, x, z, t, river, scale);
                immutable got = sampleWaves(s, x, z, t);
                assert(near(got.position.x, ref_[0].x, 1e-5f));
                assert(near(got.position.y, ref_[0].y, 1e-5f));
                assert(near(got.position.z, ref_[0].z, 1e-5f));
                assert(near(got.normal.x, ref_[1].x, 1e-5f));
                assert(near(got.normal.y, ref_[1].y, 1e-5f));
                assert(near(got.normal.z, ref_[1].z, 1e-5f));
            }
        }
    }
}

@("waves: normal and tangent are unit and orthogonal; crest in [0,1]")
unittest {
    auto s = WaveSet.ocean();
    s.amplitudeScale = 1.75f;
    foreach (i; 0 .. 64) {
        immutable w = sampleWaves(s, i * 0.31f - 10.0f, 5.0f - i * 0.23f, i * 0.11f);
        assert(near(w.normal.length, 1.0f, 1e-4f));
        assert(near(w.tangent.length, 1.0f, 1e-4f));
        assert(near(w.normal.dot(w.tangent), 0.0f, 1e-4f));
        assert(w.normal.y > 0.0f);
        assert(w.crest >= 0.0f && w.crest <= 1.0f);
    }
}

@("waves: waveHeightAt converges to the displaced surface")
unittest {
    // No modulation/channel: the envelope is uniform, so the fixed point is exact.
    WaveSet s = WaveSet.ocean();
    s.modulation = WaveModulation.init;
    foreach (i; 0 .. 32) {
        immutable ux = i * 0.53f - 8.0f;
        immutable uz = 6.0f - i * 0.41f;
        immutable t = i * 0.19f;
        immutable surf = sampleWaves(s, ux, uz, t);
        immutable h = waveHeightAt(s, surf.position.x, surf.position.z, t, 8);
        assert(near(h, surf.position.y, 1e-3f));
    }
}

@("waves: single iteration matches the PBR wetline formula")
unittest {
    // `evalExactWaveY` in textured3d_pbr.wgsl: one horizontal pullback with
    // envelope and warp evaluated at the query point.
    auto s = WaveSet.river();
    immutable x = 1.7f, z = -2.3f, t = 4.2f;
    immutable scale = waveAmplitudeScale(s, x, z, t);
    immutable warp = wavePhaseWarp(s.modulation, x, z, t);
    float dx = 0, dz = 0;
    foreach (ref w; s.active) {
        immutable k = 6.2831853f / w.wavelength;
        immutable c = sqrt(9.81f / k) * w.speedScale;
        immutable a = w.amplitude * scale;
        immutable ph = k * (w.dirX * x + w.dirZ * z) - k * c * t + warp * (k * 0.45f < 1 ? k * 0.45f : 1);
        dx += w.steepness * a * w.dirX * cos(ph);
        dz += w.steepness * a * w.dirZ * cos(ph);
    }
    float y = 0;
    foreach (ref w; s.active) {
        immutable k = 6.2831853f / w.wavelength;
        immutable c = sqrt(9.81f / k) * w.speedScale;
        immutable a = w.amplitude * scale;
        y += a * sin(k * (w.dirX * (x - dx) + w.dirZ * (z - dz)) - k * c * t + warp * (k * 0.45f < 1 ? k * 0.45f : 1));
    }
    assert(near(waveHeightAt(s, x, z, t, 1), y, 1e-5f));
}

@("waves: channel taper")
unittest {
    immutable ch = WaveSet.river().channel;
    assert(ch.scaleAt(10.0f, 0.0f) == 1.0f);
    assert(ch.scaleAt(-3.0f, 4.5f) == 1.0f);
    assert(near(ch.scaleAt(0.0f, -6.25f), 1.0f - 0.5f * 0.85f, 1e-6f));
    assert(near(ch.scaleAt(0.0f, 20.0f), 0.15f, 1e-6f));
    assert(WaveChannel.init.scaleAt(100.0f, 100.0f) == 1.0f);

    // Rotated channel: center line along +Z through x = 2.
    immutable rot = WaveChannel(2.0f, 0.0f, 0.0f, 1.0f, 1.0f, 1.0f, 0.0f);
    assert(rot.scaleAt(2.5f, 50.0f) == 1.0f);
    assert(near(rot.scaleAt(4.0f, -7.0f), 0.0f, 1e-6f));
}

@("waves: add respects capacity")
unittest {
    WaveSet s;
    foreach (i; 0 .. MAX_WAVE_COMPONENTS) assert(s.add(WaveComponent.init));
    assert(!s.add(WaveComponent.init));
    assert(s.active.length == MAX_WAVE_COMPONENTS);
}
