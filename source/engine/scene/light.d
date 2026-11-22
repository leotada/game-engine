/// POD Light component + multi-light / clustered / shadow budget constants.
///
/// Active lights: **1** directional + up to **1024** point + **256** spot
/// (Clustered Forward GPU culling). `LightSet` keeps compact inline arrays
/// (`32` point / `4` spot) for stack-allocated callers; use `LightList` or
/// `Scene3DTextured.addPointLight`/`addSpotLight` to scale above that without stack bloat.
/// Shadow casters: **1** dir @ 2048² + up to **4** point cubemaps @ 512²/face
/// + up to **2** spot maps @ 1024². Exceeding light limits is an error
/// (editor/UI); exceeding `castShadows` budget warns and leaves the light lit
/// without a shadow map.
///
/// Direction / position come from the entity `Transform` (or are packed into
/// `LightSet`/`LightList` for `Scene3DTextured.setLights`). IBL is a scene setting, not
/// a `Light`.
module engine.scene.light;

import engine.core.pod : isPod;
import engine.core.podbuf : PodBuffer;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
public import engine.scene.cascades : CascadeSettings, MAX_CASCADES;

@safe:

// ---------------------------------------------------------------------------
// Budget constants (document + enforce at setLights / editor)
// ---------------------------------------------------------------------------

/// Max directional lights in the frame UBO.
enum uint MAX_DIR_LIGHTS = 1;
/// Max active point lights supported by Clustered Forward storage & compute culling.
enum uint MAX_POINT_LIGHTS = 1024;
/// Max active spot lights supported by Clustered Forward storage & compute culling.
enum uint MAX_SPOT_LIGHTS = 256;

/// Stack-friendly inline array capacity of `LightSet`.
enum uint LIGHTSET_MAX_POINTS = 32;
/// Stack-friendly inline array capacity of `LightSet`.
enum uint LIGHTSET_MAX_SPOTS = 4;

/// Max directional shadow maps bound per frame (ortho PCF).
enum uint MAX_DIR_SHADOW_CASTERS = 1;
/// Max point shadow cubemaps bound per frame.
enum uint MAX_POINT_SHADOW_CASTERS = 4;
/// Max spot shadow maps bound per frame.
enum uint MAX_SPOT_SHADOW_CASTERS = 2;

/// Default directional shadow map resolution (square).
enum uint DIR_SHADOW_RESOLUTION = 2048;
/// Default point shadow cubemap face resolution.
enum uint POINT_SHADOW_RESOLUTION = 512;
/// Default spot shadow map resolution (square).
enum uint SPOT_SHADOW_RESOLUTION = 1024;

/// Near plane used when building point/spot shadow projections.
enum float LIGHT_SHADOW_NEAR = 0.1f;

// ---------------------------------------------------------------------------
// ECS component
// ---------------------------------------------------------------------------

enum LightType : uint {
    directional = 0,
    point = 1,
    spot = 2,
}

/// ECS light component. Position/orientation live on `Transform`.
struct Light {
    LightType type = LightType.directional;
    float[3] color = [1.0f, 1.0f, 1.0f];
    float intensity = 1.0f;
    /// Attenuation cutoff for point / spot (world units).
    float range = 10.0f;
    /// Spot inner cone half-angle in degrees (full intensity).
    float innerConeDeg = 15.0f;
    /// Spot outer cone half-angle in degrees (falloff end).
    float outerConeDeg = 25.0f;
    /// Request a shadow map (subject to caster budget).
    uint castShadows = 0;
}

static assert(isPod!Light);

// ---------------------------------------------------------------------------
// CPU frame packing (fed to Scene3DTextured.setLights)
// ---------------------------------------------------------------------------

/// Directional light GPU params. `direction` is surface→light (N·L).
struct GpuDirLight {
    Vec3 direction = Vec3(0.3f, 1.0f, 0.5f);
    Vec3 color = Vec3(1.0f, 0.98f, 0.92f);
    float intensity = 3.5f;
    /// Fixed shadow view-projection. Used when cascades are off
    /// (`cascades.count == 0`) or when a caller-owned `ShadowMap` is bound.
    Mat4 viewProj = Mat4.identity();
    bool castShadows = false;
    /// Cascaded shadow maps fitted to the camera by
    /// `Scene3DTextured.renderShadows(frame, lights)` (engine-owned maps).
    CascadeSettings cascades;
    /// Tint each cascade in the shaded image (debug).
    bool debugCascades = false;
}

/// Point light GPU params.
struct GpuPointLight {
    Vec3 position = Vec3(0, 0, 0);
    Vec3 color = Vec3(1, 1, 1);
    float intensity = 1.0f;
    float range = 10.0f;
    bool castShadows = false;
    /// 0 = engine default `(1 - (d/r)^4)^2 / (d^2 + 1)`. Above 0 = Godot-style
    /// `pow(1 - d/r, attenuation)`: intensity reaches the full `range` and
    /// ignores inverse-square falloff (1 = linear, >1 = tighter pool).
    float attenuation = 0.0f;
}

/// Spot light GPU params. `direction` points along the cone axis (light→scene).
struct GpuSpotLight {
    Vec3 position = Vec3(0, 0, 0);
    Vec3 direction = Vec3(0, -1, 0);
    Vec3 color = Vec3(1, 1, 1);
    float intensity = 1.0f;
    float range = 10.0f;
    float innerConeDeg = 15.0f;
    float outerConeDeg = 25.0f;
    Mat4 viewProj = Mat4.identity();
    bool castShadows = false;
    /// Same meaning as `GpuPointLight.attenuation`.
    float attenuation = 0.0f;
    /// 0 = default `cone^2` cone falloff; above 0 = `cone^angleAttenuation`
    /// (Godot `spot_attenuation`; below 1 widens the bright core).
    float angleAttenuation = 0.0f;
}

/// Compact stack-friendly per-frame light list for small scenes and backward-compatible demos.
struct LightSet {
    GpuDirLight dir;
    bool dirEnabled = true;
    GpuPointLight[LIGHTSET_MAX_POINTS] points;
    uint pointCount = 0;
    GpuSpotLight[LIGHTSET_MAX_SPOTS] spots;
    uint spotCount = 0;
    float shadowBias = 0.0004f;
}

/// Move-only, `@nogc` malloc-backed light container (`PodBuffer`) for scaling to
/// `MAX_POINT_LIGHTS` (1024) and `MAX_SPOT_LIGHTS` (256) without stack bloat or GC.
struct LightList {
    GpuDirLight dir;
    bool dirEnabled = true;
    PodBuffer!GpuPointLight points;
    PodBuffer!GpuSpotLight spots;
    float shadowBias = 0.0004f;

    @disable this(this);

    void clear() nothrow @nogc {
        dir = GpuDirLight.init;
        dirEnabled = false;
        points.clear();
        spots.clear();
        shadowBias = 0.0004f;
    }

    void addPoint(GpuPointLight p) nothrow @nogc {
        if (points.length < MAX_POINT_LIGHTS)
            points.put(p);
    }

    void addSpot(GpuSpotLight s) nothrow @nogc {
        if (spots.length < MAX_SPOT_LIGHTS)
            spots.put(s);
    }

    bool empty() const nothrow @nogc {
        return !dirEnabled && points.length == 0 && spots.length == 0;
    }

    void release() nothrow @nogc {
        points.release();
        spots.release();
    }
}

@("light.lightListNoGc") nothrow @nogc unittest {
    LightList list;
    list.clear();
    assert(list.empty());
    foreach (i; 0 .. 120) {
        GpuPointLight p;
        p.position = Vec3(cast(float) i, 1.0f, 0.0f);
        p.range = 10.0f;
        list.addPoint(p);
    }
    foreach (i; 0 .. 20) {
        GpuSpotLight s;
        s.position = Vec3(0.0f, 4.0f, cast(float) i);
        list.addSpot(s);
    }
    assert(list.points.length == 120);
    assert(list.spots.length == 20);
    assert(!list.empty());
    list.release();
}
