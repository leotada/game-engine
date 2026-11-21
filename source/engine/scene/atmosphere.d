/// Atmospheric fog settings (POD) consumed by `Scene3DTextured.setFog` and
/// evaluated in linear HDR by `assets/shaders/common/atmosphere.wgsl`.
module engine.scene.atmosphere;

import engine.core.pod : isPod;
import engine.math.vec : Vec3;

@safe:

/// Exponential height fog with a sun in-scattering lobe.
///
/// Fog density at height `h` is `density * exp(-heightFalloff * (h - heightBase))`
/// and is integrated analytically along each camera ray, so valleys fill
/// with fog while peaks stay clear. `enabled = false` (or `density = 0`)
/// leaves the image unchanged.
struct FogSettings {
    bool enabled = false;
    /// Fog color in linear HDR (multiply by the sky exposure for night scenes).
    Vec3 color = Vec3(0.62f, 0.72f, 0.84f);
    /// Extinction per metre at `heightBase` (0.002 ≈ 50 % at ~350 m).
    float density = 0.002f;
    /// World height where `density` applies.
    float heightBase = 0.0f;
    /// Density decay per metre of height (0 = uniform fog).
    float heightFalloff = 0.02f;
    /// No fog closer than this distance to the camera.
    float startDistance = 0.0f;
    /// Upper bound on fog opacity (keeps distant landmarks visible).
    float maxOpacity = 1.0f;
    /// Sun in-scattering color added toward the sun direction.
    Vec3 sunColor = Vec3(1.0f, 0.85f, 0.6f);
    /// Sharpness of the sun lobe (0 disables it).
    float sunPower = 8.0f;
}

static assert(isPod!FogSettings);

/// Pack `fog` into the four `FrameUniforms` fog vectors
/// (`fogColorDensity`, `fogHeight`, `fogSun`).
void packFog(ref const FogSettings fog, ref float[4] colorDensity, ref float[4] height,
             ref float[4] sun) pure nothrow @nogc {
    immutable bool on = fog.enabled && fog.density > 0;
    colorDensity = [fog.color.x, fog.color.y, fog.color.z, on ? fog.density : 0.0f];
    height = [fog.heightBase, fog.heightFalloff > 0 ? fog.heightFalloff : 0.0f,
              fog.startDistance > 0 ? fog.startDistance : 0.0f,
              fog.maxOpacity < 0 ? 0.0f : (fog.maxOpacity > 1 ? 1.0f : fog.maxOpacity)];
    sun = [fog.sunColor.x, fog.sunColor.y, fog.sunColor.z, fog.sunPower > 0 ? fog.sunPower : 0.0f];
}

/// CPU reference of the shader's fog opacity (tests, gameplay visibility checks).
float fogAmountCpu(ref const FogSettings fog, Vec3 cameraPos, Vec3 worldPos) pure nothrow @nogc {
    import std.math : exp, abs;
    if (!fog.enabled || fog.density <= 0) return 0;
    immutable toP = worldPos - cameraPos;
    immutable dist = toP.length();
    immutable fogged = dist - fog.startDistance;
    if (fogged <= 0) return 0;
    immutable falloff = fog.heightFalloff > 1e-5f ? fog.heightFalloff : 1e-5f;
    immutable t0 = 1.0f - fogged / (dist > 1e-4f ? dist : 1e-4f);
    immutable startH = cameraPos.y + toP.y * t0 - fog.heightBase;
    immutable rise = toP.y * (1.0f - t0);
    immutable k = falloff * rise;
    float e = -falloff * startH;
    if (e > 40) e = 40;
    if (e < -80) e = -80;
    float integral = fogged * fog.density * exp(e);
    if (abs(k) > 1e-4f) integral *= (1.0f - exp(-k)) / k;
    float f = 1.0f - exp(-integral);
    immutable maxO = fog.maxOpacity < 1 ? fog.maxOpacity : 1.0f;
    return f < maxO ? f : maxO;
}

unittest {
    FogSettings f;
    assert(fogAmountCpu(f, Vec3(0, 2, 0), Vec3(0, 2, 500)) == 0); // disabled
    f.enabled = true;
    f.heightFalloff = 0;
    // Uniform fog: 1 - exp(-density * d).
    import std.math : exp, abs;
    immutable a = fogAmountCpu(f, Vec3(0, 0, 0), Vec3(0, 0, 350));
    assert(abs(a - (1 - exp(-0.002f * 350))) < 1e-3f);
    // Height falloff: a ray at altitude sees less fog than one at the base.
    f.heightFalloff = 0.05f;
    assert(fogAmountCpu(f, Vec3(0, 100, 0), Vec3(0, 100, 300))
         < fogAmountCpu(f, Vec3(0, 0, 0), Vec3(0, 0, 300)));
    // Start distance and max opacity.
    f.startDistance = 1000;
    assert(fogAmountCpu(f, Vec3(0, 0, 0), Vec3(0, 0, 900)) == 0);
    f.startDistance = 0;
    f.maxOpacity = 0.4f;
    f.heightFalloff = 0;
    f.density = 1;
    assert(fogAmountCpu(f, Vec3(0, 0, 0), Vec3(0, 0, 900)) <= 0.4f);
}
