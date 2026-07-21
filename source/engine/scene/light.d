/// POD Light component + multi-light / shadow budget constants (GFX-L).
///
/// UBO slots: **1** directional + **8** point + **4** spot.
/// Shadow casters: **1** dir @ 2048² + up to **4** point cubemaps @ 512²/face
/// + up to **2** spot maps @ 1024². Exceeding UBO create limits is an error
/// (editor/UI); exceeding `castShadows` budget warns and leaves the light lit
/// without a shadow map.
///
/// Direction / position come from the entity `Transform` (or are packed into
/// `LightSet` for `Scene3DTextured.setLights`). IBL is a scene setting, not
/// a `Light`.
module engine.scene.light;

import engine.core.pod : isPod;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;

@safe:

// ---------------------------------------------------------------------------
// Budget constants (document + enforce at setLights / editor)
// ---------------------------------------------------------------------------

/// Max directional lights in the frame UBO.
enum uint MAX_DIR_LIGHTS = 1;
/// Max point lights in the frame UBO.
enum uint MAX_POINT_LIGHTS = 8;
/// Max spot lights in the frame UBO.
enum uint MAX_SPOT_LIGHTS = 4;

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
    Mat4 viewProj = Mat4.identity();
    bool castShadows = false;
}

/// Point light GPU params.
struct GpuPointLight {
    Vec3 position = Vec3(0, 0, 0);
    Vec3 color = Vec3(1, 1, 1);
    float intensity = 1.0f;
    float range = 10.0f;
    bool castShadows = false;
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
}

/// Per-frame light list for the textured PBR path.
struct LightSet {
    GpuDirLight dir;
    bool dirEnabled = true;
    GpuPointLight[MAX_POINT_LIGHTS] points;
    uint pointCount = 0;
    GpuSpotLight[MAX_SPOT_LIGHTS] spots;
    uint spotCount = 0;
    float shadowBias = 0.0004f;
}
