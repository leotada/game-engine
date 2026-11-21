/// Day/night cycle and weather (POD, `@nogc`). `TimeOfDay` turns a clock
/// time into sun / moon directions and colors; `Weather` blends cloud
/// coverage, rain and surface wetness toward a target over time.
/// `evaluateEnvironment` combines both into an `EnvironmentState`, and
/// `applyEnvironment` writes it into a `LightSet`, `FogSettings` and the
/// `Scene3DTextured` frame uniforms (sky, weather). `skyIblParams` feeds
/// `DynamicIbl` so ambient light follows the sky.
module engine.scene.time_of_day;

import std.math : asin, cos, sin, PI, exp;

import engine.core.pod : isPod;
import engine.math.vec : Vec3;
import engine.scene.atmosphere : FogSettings;
import engine.gpu.ibl_dynamic : SkyIblParams;
import engine.scene.light : LightSet;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

/// Clock and sun-path settings.
struct TimeOfDay {
    /// Hours in [0, 24).
    float hours = 10.0f;
    /// Observer latitude in degrees (+ north).
    float latitudeDeg = 38.0f;
    /// Solar declination in degrees (+23.4 summer solstice, 0 equinox).
    float declinationDeg = 15.0f;
    /// Real seconds per in-game day (0 freezes the clock).
    float dayLengthSec = 1200.0f;
    /// Rotate the sun path around the vertical axis (degrees).
    float northOffsetDeg = 0.0f;
    /// Noon sun intensity (directional light units).
    float sunIntensity = 3.2f;
    /// Full-moon intensity of the night directional light.
    float moonLightIntensity = 0.12f;

    /// Advance the clock by `dt` real seconds.
    void advance(float dt) pure nothrow @nogc {
        if (dayLengthSec <= 0) return;
        hours += dt * 24.0f / dayLengthSec;
        while (hours >= 24.0f) hours -= 24.0f;
        while (hours < 0.0f) hours += 24.0f;
    }
}

/// Weather state blended toward `target*` values.
struct Weather {
    float cloudCoverage = 0.15f;
    float rainIntensity = 0.0f;
    /// Surface wetness: rises while it rains, dries afterwards.
    float wetness = 0.0f;
    /// Extra fog density multiplier from weather (1 = clear).
    float fogScale = 1.0f;

    float targetCloudCoverage = 0.15f;
    float targetRain = 0.0f;
    /// Seconds to reach the target (exponential approach time constant).
    float transitionSec = 30.0f;
    /// Seconds for wetness to go from 0 to ~1 in heavy rain.
    float wettingSec = 40.0f;
    /// Seconds for a soaked surface to dry.
    float dryingSec = 180.0f;

    /// Set a new target state (e.g. `setTarget(0.9, 1.0)` for a storm).
    void setTarget(float clouds, float rain) pure nothrow @nogc {
        targetCloudCoverage = sat(clouds);
        targetRain = sat(rain);
    }

    void update(float dt) pure nothrow @nogc {
        if (dt <= 0) return;
        immutable k = transitionSec > 0 ? 1.0f - exp(-dt / transitionSec) : 1.0f;
        cloudCoverage += (targetCloudCoverage - cloudCoverage) * k;
        // Rain only starts once the sky has clouded over.
        immutable rainCap = sat((cloudCoverage - 0.45f) / 0.35f);
        immutable rainGoal = targetRain < rainCap ? targetRain : rainCap;
        rainIntensity += (rainGoal - rainIntensity) * k;
        if (rainIntensity > 0.02f)
            wetness += dt / (wettingSec > 0 ? wettingSec : 1) * rainIntensity;
        else
            wetness -= dt / (dryingSec > 0 ? dryingSec : 1);
        wetness = sat(wetness);
        fogScale = 1.0f + cloudCoverage * 0.8f + rainIntensity * 2.0f;
    }
}

/// Everything the renderer needs for one moment of the day.
struct EnvironmentState {
    /// Surface → sun / moon.
    Vec3 sunDir;
    Vec3 moonDir;
    Vec3 sunColor;
    float sunIntensity = 0;
    float moonIntensity = 0;
    float starIntensity = 0;
    /// Directional light actually used for shading (sun by day, moon by night).
    Vec3 lightDir;
    Vec3 lightColor;
    float lightIntensity = 0;
    /// Suggested fog / horizon color in linear HDR.
    Vec3 fogColor;
    /// Ambient (IBL) multiplier for static environments.
    float ambientScale = 1;
    float cloudCoverage = 0;
    float rainIntensity = 0;
    float wetness = 0;
    float fogScale = 1;
}

static assert(isPod!TimeOfDay && isPod!Weather && isPod!EnvironmentState);

private float sat(float v) pure nothrow @nogc { return v < 0 ? 0 : (v > 1 ? 1 : v); }

private float smooth(float a, float b, float x) pure nothrow @nogc {
    immutable t = sat((x - a) / (b - a));
    return t * t * (3 - 2 * t);
}

private Vec3 lerp(Vec3 a, Vec3 b, float t) pure nothrow @nogc { return a + (b - a) * t; }

/// Sun direction (surface → sun) for `t`: x = east, y = up, z = south.
Vec3 sunDirection(ref const TimeOfDay t) pure nothrow @nogc {
    enum float D2R = PI / 180.0f;
    immutable H = (t.hours - 12.0f) / 24.0f * 2.0f * PI; // hour angle
    immutable phi = t.latitudeDeg * D2R;
    immutable dec = t.declinationDeg * D2R;
    immutable east = -cos(dec) * sin(H);
    immutable north = cos(phi) * sin(dec) - sin(phi) * cos(dec) * cos(H);
    immutable up = sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(H);
    immutable rot = t.northOffsetDeg * D2R;
    immutable x = east * cos(rot) + north * sin(rot);
    immutable z = -north * cos(rot) + east * sin(rot);
    return Vec3(x, up, z).normalized();
}

/// Combine the clock and weather into an `EnvironmentState`.
EnvironmentState evaluateEnvironment(ref const TimeOfDay t, ref const Weather w) pure nothrow @nogc {
    EnvironmentState e;
    e.sunDir = sunDirection(t);
    // Moon roughly opposite the sun, tilted so it is not exactly antipodal.
    e.moonDir = (Vec3(-e.sunDir.x, -e.sunDir.y, -e.sunDir.z) + Vec3(0.15f, 0.25f, 0.1f)).normalized();
    immutable el = e.sunDir.y;
    immutable clouds = sat(w.cloudCoverage);

    immutable warm = Vec3(1.0f, 0.52f, 0.28f);
    immutable noon = Vec3(1.0f, 0.97f, 0.92f);
    e.sunColor = lerp(warm, noon, smooth(0.0f, 0.35f, el));
    e.sunIntensity = t.sunIntensity * smooth(-0.03f, 0.12f, el) * (1.0f - 0.75f * clouds);

    immutable night = 1.0f - smooth(-0.15f, 0.0f, el);
    e.starIntensity = night * (1.0f - clouds);
    e.moonIntensity = smooth(0.0f, 0.15f, e.moonDir.y) * (1.0f - smooth(-0.10f, 0.05f, el));

    if (el > -0.03f || e.moonIntensity <= 0.0f) {
        e.lightDir = e.sunDir;
        e.lightColor = e.sunColor;
        e.lightIntensity = e.sunIntensity;
    } else {
        e.lightDir = e.moonDir;
        e.lightColor = Vec3(0.55f, 0.65f, 0.95f);
        e.lightIntensity = t.moonLightIntensity * e.moonIntensity * (1.0f - 0.7f * clouds);
    }

    immutable fogNight = Vec3(0.015f, 0.022f, 0.04f);
    immutable fogDusk = Vec3(0.80f, 0.52f, 0.38f);
    immutable fogDay = Vec3(0.62f, 0.72f, 0.84f);
    Vec3 fog = lerp(lerp(fogNight, fogDusk, smooth(-0.20f, -0.02f, el)), fogDay, smooth(0.02f, 0.30f, el));
    immutable grey = (fog.x * 0.2126f + fog.y * 0.7152f + fog.z * 0.0722f) * 0.85f;
    e.fogColor = lerp(fog, Vec3(grey, grey, grey), clouds * 0.65f);

    e.ambientScale = (0.06f + 0.94f * smooth(-0.20f, 0.20f, el)) * (1.0f - 0.35f * clouds);
    e.cloudCoverage = clouds;
    e.rainIntensity = sat(w.rainIntensity);
    e.wetness = sat(w.wetness);
    e.fogScale = w.fogScale;
    return e;
}

/// Write `env` into the directional light of `lights` and the fog color /
/// density of `fog` (density is scaled from `baseFogDensity`).
void applyEnvironment(ref const EnvironmentState env, ref LightSet lights, ref FogSettings fog,
                      float baseFogDensity) pure nothrow @nogc {
    lights.dirEnabled = env.lightIntensity > 0.0005f;
    lights.dir.direction = env.lightDir;
    lights.dir.color = env.lightColor;
    lights.dir.intensity = env.lightIntensity;
    fog.color = env.fogColor;
    fog.density = baseFogDensity * env.fogScale;
    fog.sunColor = env.sunColor * (env.sunIntensity > 0 ? 1.0f : 0.0f);
}

/// Sky + weather frame inputs of `scene` (call before `scene.begin`).
void applyEnvironmentToScene(ref const EnvironmentState env, ref Scene3DTextured scene,
                             float skyExposure = 1.0f) nothrow @nogc {
    scene.setSkySun(env.sunDir, env.sunColor * (env.sunIntensity > 0 ? 1.0f : 0.0f));
    scene.setSkyState(env.moonDir, env.moonIntensity, env.starIntensity, skyExposure);
    scene.setWeather(env.wetness, env.rainIntensity, env.cloudCoverage);
}

/// Inputs for `DynamicIbl.request` matching the visible sky.
SkyIblParams skyIblParams(ref const EnvironmentState env, float time, float skyExposure = 1.0f) pure nothrow @nogc {
    SkyIblParams p;
    p.sunDir = env.sunDir;
    p.sunColor = env.sunIntensity > 0 ? env.sunColor : Vec3(0, 0, 0);
    p.moonDir = env.moonDir;
    p.moonIntensity = env.moonIntensity;
    p.starIntensity = env.starIntensity;
    p.cloudCoverage = env.cloudCoverage;
    p.time = time;
    p.exposure = skyExposure;
    return p;
}

unittest {
    TimeOfDay t;
    t.hours = 12;
    t.latitudeDeg = 0;
    t.declinationDeg = 0;
    auto s = sunDirection(t);
    assert(s.y > 0.999f); // equator, equinox, noon: zenith
    t.hours = 0;
    assert(sunDirection(t).y < -0.999f);
    t.hours = 6;
    assert(sunDirection(t).y > -0.01f && sunDirection(t).y < 0.01f);
    assert(sunDirection(t).x > 0.99f); // rises in the east

    Weather w;
    t.hours = 12;
    t.latitudeDeg = 38;
    auto day = evaluateEnvironment(t, w);
    assert(day.lightDir.y > 0 && day.lightIntensity > 1 && day.starIntensity == 0);
    t.hours = 0;
    auto nightEnv = evaluateEnvironment(t, w);
    assert(nightEnv.sunIntensity == 0 && nightEnv.starIntensity > 0.5f);
    assert(nightEnv.lightIntensity < 0.2f);

    t.advance(t.dayLengthSec / 2);
    assert(t.hours > 11.99f && t.hours < 12.01f);
}

unittest {
    Weather w;
    w.setTarget(1.0f, 1.0f);
    foreach (i; 0 .. 600) w.update(0.5f); // 5 minutes of storm
    assert(w.cloudCoverage > 0.95f && w.rainIntensity > 0.9f && w.wetness > 0.99f);
    w.setTarget(0.1f, 0.0f);
    foreach (i; 0 .. 2400) w.update(0.5f); // 20 minutes to clear and dry
    assert(w.rainIntensity < 0.02f && w.wetness < 0.01f && w.cloudCoverage < 0.15f);
}
