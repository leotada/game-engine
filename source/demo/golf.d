/// Emerald Dunes 3D Championship Golf — Realistic Wind Aerodynamics & PBR Rendering.
/// Controls:
///   A / D or Left / Right: Aim Heading
///   W / S or Up / Down: Adjust Loft Angle
///   1 .. 5: Select Club (Driver, 5-Iron, 9-Iron, Sand Wedge, Putter)
///   Space or Left Mouse: Hold to charge backswing power, release to strike
///   Mouse drag: Orbit camera around ball
///   Q / E or Mouse Wheel: Zoom camera
///   C: Toggle Camera (Chase / Green / Aerial follow / Full-hole aerial)
///   R: Restart Hole
///   Esc: Quit
module demo.golf;

import std.format : sformat;
import std.math : PI, atan2, cos, exp, fabs, log, sin, sqrt;

import bindings.box3d : b3BodyId;
import bindings.wgpu;
import engine.app : App;
import engine.audio : AudioClip, AudioEngine;
import engine.core.log : info, warn;
import engine.core.gc : UseSteadyGC;
import engine.devtools.gizmos : GizmoRenderer;
import engine.ecs.store : EntityId;
import engine.gpu.buffer :
    createDynamicVertexBuffer, createUniformBindGroup, createUniformBuffer,
    destroyBuffer, releaseBindGroup, updateBuffer;
import engine.gpu.shadow :
    ShadowMap, ShadowPipeline, createShadowPipeline,
    directionalLightVP, submitShadowPass,
    PointShadowMap, SpotShadowMap;
import engine.gpu.context : GpuContext;
import engine.gpu.renderer : FrameContext;
import engine.gpu.shader : createShaderModule;
import engine.gpu.text : FpsCounter, TextRenderer;
import engine.graphics.material : Material, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, Texture, TextureFilter, TextureWrap;
import engine.graphics.types : Color4, InstanceData, TexVert;
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics;
import engine.platform.input : Key, MouseButton;
import engine.scene.camera : Camera;
import engine.scene.light :
    GpuPointLight, GpuSpotLight, LightSet,
    MAX_POINT_SHADOW_CASTERS, MAX_SPOT_SHADOW_CASTERS;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

// Selects the steadygc collector when built with version SteadyGC (see engine.core.gc).
mixin UseSteadyGC;

// ---------------------------------------------------------------------------
// Simulation & Aerodynamic Constants
// ---------------------------------------------------------------------------

private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;
private enum PHYS_STEP = 1.0f / 60.0f;
private enum MAX_SUBSTEPS = 5;
private enum SOLVER_SUBSTEPS = 8;

// USGA Regulation Golf Ball Specifications
private enum float BALL_R = 0.02135f;            // 42.7 mm diameter
private enum float BALL_DENSITY = 1130.0f;       // ~45.9 grams
private enum float AIR_RHO = 1.225f;             // Sea-level standard air density (kg/m^3)
private enum float BALL_CD = 0.285f;             // Aerodynamic drag coefficient for dimpled sphere
private enum float BALL_AREA = 3.14159265f * BALL_R * BALL_R;
private enum float DRAG_K = 0.5f * AIR_RHO * BALL_CD * BALL_AREA;
private enum float LIFT_K = 0.5f * AIR_RHO * BALL_AREA;

// Course Geometry Layout
private enum float TEE_X = 0.0f;
private enum float TEE_Z = 0.0f;
private enum float CUP_X = 1.6f;
private enum float CUP_Z = 133.5f;
private enum float CUP_RADIUS = 0.11f;
private enum int PAR = 3;

// Rolling resistance (Deceleration = mu * g)
private enum float FRIC_TEE     = 1.40f;
private enum float FRIC_FAIRWAY = 2.10f;
private enum float FRIC_ROUGH   = 8.50f; // Tall grass: the ball should die in a couple of meters
private enum float FRIC_BUNKER  = 3.40f;
private enum float FRIC_GREEN   = 0.28f; // Still a true roll, but the ball stops instead of coasting

private enum EntityId BALL_ENTITY  = 1;
private enum EntityId WATER_ENTITY = 2;

// ---------------------------------------------------------------------------
// Game States & Club Definitions
// ---------------------------------------------------------------------------

private enum GameState {
    aim,
    flight,
    holed
}

private enum Lie {
    tee,
    fairway,
    rough,
    bunker,
    green
}

private enum ClubKind {
    driver,
    iron5,
    iron9,
    wedge,
    putter
}

private struct ClubSpec {
    ClubKind kind;
    string name;
    float defaultLoft;
    float fullSpeed;  // m/s on 100% swing
    float backspinRpm;
    float carryEstimateM;
}

private immutable ClubSpec[5] CLUBS = [
    ClubSpec(ClubKind.driver, "1W Driver",    11.5f, 54.0f, 2400.0f, 185.0f),
    ClubSpec(ClubKind.iron5,  "5-Iron",       24.0f, 43.5f, 3800.0f, 142.0f),
    ClubSpec(ClubKind.iron9,  "9-Iron",       38.0f, 34.0f, 5600.0f, 105.0f),
    ClubSpec(ClubKind.wedge,  "Sand Wedge",   54.0f, 26.5f, 7800.0f,  68.0f),
    ClubSpec(ClubKind.putter, "Pro Putter",    2.5f,  6.4f,   80.0f,  16.0f),
];

// ---------------------------------------------------------------------------
// Continuous Sculpted Course Elevation Model
// ---------------------------------------------------------------------------

/// C1-continuous course elevation function: evaluated for terrain geometry,
/// normal vectors, ball physics, and trajectory prediction.
private float courseElevation(float x, float z) pure nothrow @nogc {
    // 1. Natural rolling countryside undulations
    float h = 0.22f * sin(0.045f * x + 0.052f * z) + 0.14f * cos(0.088f * x - 0.038f * z);

    // 2. Rolling perimeter dunes that frame the golf hole
    if (x < -12.0f) {
        immutable d = (-12.0f - x);
        h += 0.09f * d * d;
        if (h > 3.4f) h = 3.4f;
    }
    if (x > 26.0f) {
        immutable d = (x - 26.0f);
        h += 0.08f * d * d;
        if (h > 3.0f) h = 3.0f;
    }
    if (z > 144.0f) {
        immutable d = (z - 144.0f);
        h += 0.10f * d * d;
        if (h > 3.6f) h = 3.6f;
    }

    // 3. Coastal Water Hazard Basin (sloping down to -0.85m)
    if (x > 13.0f && x < 37.0f && z > 16.0f && z < 112.0f) {
        immutable cx = 25.0f;
        immutable cz = 64.0f;
        immutable dx = (x - cx) / 11.0f;
        immutable dz = (z - cz) / 47.0f;
        immutable r2 = dx * dx + dz * dz;
        if (r2 < 1.0f) {
            immutable depth = (1.0f - r2) * (1.0f - r2) * 1.05f;
            h -= depth;
        }
    }

    // 4. Fairway Pot Bunker (Scooped bowl at x = -8.5, z = 66.0)
    {
        immutable bx = (x - (-8.5f)) / 3.8f;
        immutable bz = (z - 66.0f) / 6.2f;
        immutable br2 = bx * bx + bz * bz;
        if (br2 < 1.0f) {
            immutable bDepth = (1.0f - br2) * (1.0f - br2) * 0.68f;
            h -= bDepth;
        }
    }

    // 5. Greenside Bunker (Scooped bowl at x = 8.4, z = 130.5)
    {
        immutable gbx = (x - 8.4f) / 4.0f;
        immutable gbz = (z - 130.5f) / 7.2f;
        immutable gbr2 = gbx * gbx + gbz * gbz;
        if (gbr2 < 1.0f) {
            immutable gbDepth = (1.0f - gbr2) * (1.0f - gbr2) * 0.72f;
            h -= gbDepth;
        }
    }

    // 6. Sculpted Plateau Green (Elevated +0.38m with gentle 1.2% slope toward front-left)
    {
        immutable gx = (x - 1.6f) / 7.2f;
        immutable gz = (z - 133.5f) / 9.4f;
        immutable gr2 = gx * gx + gz * gz;
        if (gr2 < 1.0f) {
            immutable blend = (1.0f - gr2) * (1.0f - gr2);
            immutable greenSlope = (x - 1.6f) * 0.015f + (z - 133.5f) * 0.011f;
            h = h * (1.0f - blend) + (0.38f + greenSlope) * blend;
        }
    }

    // 7. Elevated Tee Box Platform
    if (x >= -3.5f && x <= 3.5f && z >= -3.5f && z <= 4.0f) {
        immutable tx = x / 3.5f;
        immutable tz = (z - 0.25f) / 3.75f;
        immutable tr2 = tx * tx + tz * tz;
        if (tr2 < 1.0f) {
            immutable blend = (1.0f - tr2);
            h = h * (1.0f - blend) + 0.25f * blend;
        }
    }

    return h;
}

/// Analytical terrain surface normal computed via central difference
private Vec3 surfaceNormal(float x, float z) pure nothrow @nogc {
    enum float eps = 0.12f;
    immutable dhdx = (courseElevation(x + eps, z) - courseElevation(x - eps, z)) / (2.0f * eps);
    immutable dhdz = (courseElevation(x, z + eps) - courseElevation(x, z - eps)) / (2.0f * eps);
    return Vec3(-dhdx, 1.0f, -dhdz).normalized();
}

private bool inWaterHazard(float x, float z) pure nothrow @nogc {
    if (x <= 13.5f || x >= 36.0f || z <= 18.0f || z >= 110.0f)
        return false;
    immutable cx = 25.0f;
    immutable cz = 64.0f;
    immutable dx = (x - cx) / 10.5f;
    immutable dz = (z - cz) / 45.0f;
    return (dx * dx + dz * dz) <= 0.88f;
}

private Lie lieAt(Vec3 p) pure nothrow @nogc {
    // Putting Green
    immutable gx = (p.x - 1.6f) / 6.5f;
    immutable gz = (p.z - 133.5f) / 8.5f;
    if (gx * gx + gz * gz <= 1.0f)
        return Lie.green;

    // Sand Bunkers
    immutable bx = (p.x - (-8.5f)) / 3.5f;
    immutable bz = (p.z - 66.0f) / 5.8f;
    if (bx * bx + bz * bz <= 1.0f)
        return Lie.bunker;

    immutable gbx = (p.x - 8.4f) / 3.6f;
    immutable gbz = (p.z - 130.5f) / 6.4f;
    if (gbx * gbx + gbz * gbz <= 1.0f)
        return Lie.bunker;

    // Tee Box
    if (p.x >= -2.8f && p.x <= 2.8f && p.z >= -2.5f && p.z <= 3.5f)
        return Lie.tee;

    // Fairway
    immutable curFairwayX = 1.8f * sin(p.z * 0.035f);
    if (p.z >= 3.5f && p.z <= 126.0f && fabs(p.x - curFairwayX) <= 9.2f)
        return Lie.fairway;

    return Lie.rough;
}

private const(char)[] lieName(Lie lie) pure nothrow @nogc {
    final switch (lie) {
        case Lie.tee:     return "Tee Box (100% Lie)";
        case Lie.fairway: return "Fairway (100% Clean)";
        case Lie.rough:   return "Rough (82% Carry)";
        case Lie.bunker:  return "Sand Trap (60% Explosive)";
        case Lie.green:   return "Green (Putting Surface)";
    }
}

private bool outOfBounds(Vec3 p) pure nothrow @nogc {
    if (p.y < -1.8f)
        return true;
    if (p.x < -30.0f || p.x > 40.0f || p.z < -14.0f || p.z > 160.0f)
        return true;
    if (inWaterHazard(p.x, p.z) && p.y < -0.15f)
        return true;
    return false;
}

// ---------------------------------------------------------------------------
// Atmospheric Wind Simulation
// ---------------------------------------------------------------------------

private struct WindField {
    float time = 0.0f;
    float baseHeading = 0.48f; // Radians (~27 deg, blowing gently cross-tail)
    float baseSpeed = 6.4f;    // Nominal speed at 10m altitude (m/s)
}

/// Compass wind direction drifts with natural atmospheric oscillation
private float windHeading(WindField w) pure nothrow @nogc {
    return w.baseHeading
        + 0.36f * sin(w.time * 0.048f)
        + 0.16f * sin(w.time * 0.021f + 1.25f);
}

/// Baseline speed fluctuations
private float windSpeedAtRef(WindField w) pure nothrow @nogc {
    return w.baseSpeed
        + 1.35f * sin(w.time * 0.055f)
        + 0.60f * sin(w.time * 0.15f + 0.7f);
}

/// Atmospheric Boundary Layer (Logarithmic wind shear profile)
/// Ground putting experiences calm breeze (<18% wind speed), while high wedge apogee
/// experiences the full atmospheric gale (+22% speed).
private float logShearProfile(float altitude) pure nothrow @nogc {
    immutable y = altitude < 0.06f ? 0.06f : altitude;
    enum float y0 = 0.03f;
    enum float yRef = 10.0f;
    immutable factor = cast(float)(log(y / y0) / log(yRef / y0));
    return factor < 0.14f ? 0.14f : factor;
}

private Vec3 headingForward(float heading) pure nothrow @nogc {
    return Vec3(sin(heading), 0.0f, cos(heading));
}

/// Mean / steady wind profile across altitude
private Vec3 steadyWind(WindField w, Vec3 pos) pure nothrow @nogc {
    return headingForward(windHeading(w)) * (windSpeedAtRef(w) * logShearProfile(pos.y));
}

/// Live turbulent wind field with travelling sinusoidal gust fronts
private Vec3 liveWind(WindField w, Vec3 pos) pure nothrow @nogc {
    immutable heading = windHeading(w);
    immutable fwd = headingForward(heading);
    immutable right = Vec3(-fwd.z, 0.0f, fwd.x);
    immutable spd0 = windSpeedAtRef(w) * logShearProfile(pos.y);
    immutable base = fwd * spd0;

    // Spatial travelling wave packets downwind and crosswind vortex eddies
    immutable along = 0.36f * sin(0.26f * pos.x + 0.16f * pos.z - 2.20f * w.time)
        + 0.20f * sin(0.09f * pos.x - 0.11f * pos.z + 0.90f * w.time);
    immutable cross = 0.30f * sin(0.18f * pos.x - 0.24f * pos.z + 1.50f * w.time)
        + 0.16f * sin(0.07f * pos.z + 0.60f * w.time + 0.4f);
    immutable vert  = 0.12f * sin(0.12f * pos.x + 0.10f * pos.z + 1.15f * w.time);

    return base * (1.0f + along) + right * (spd0 * cross) + Vec3(0.0f, spd0 * vert, 0.0f);
}

// ---------------------------------------------------------------------------
// Ball Aerodynamics & Trajectory
// ---------------------------------------------------------------------------

private float ballMass() pure nothrow @nogc {
    return BALL_DENSITY * (4.0f / 3.0f) * 3.14159265f * BALL_R * BALL_R * BALL_R;
}

/// Compute quadratic aerodynamic drag + Magnus lift from backspin
private Vec3 aeroForce(Vec3 velocity, Vec3 omega, Vec3 wind) pure nothrow @nogc {
    immutable vr = velocity - wind;
    immutable sp = vr.length();
    if (sp < 0.05f)
        return Vec3(0.0f, 0.0f, 0.0f);

    // Quadratic air drag
    immutable drag = vr * (-DRAG_K * sp);

    // Magnus lift
    immutable wlen = omega.length();
    if (wlen < 1.0f)
        return drag;

    immutable spinParam = BALL_R * wlen / sp;
    immutable cl = 0.30f * spinParam / (0.16f + spinParam);
    immutable wh = omega * (1.0f / wlen);

    immutable magnus = wh.cross(vr) * (LIFT_K * cl * sp);
    return drag + magnus;
}

private Vec3 aimForward(float yaw) pure nothrow @nogc {
    return Vec3(sin(yaw), 0.0f, cos(yaw));
}

private Vec3 aimRight(float yaw) pure nothrow @nogc {
    immutable f = aimForward(yaw);
    return Vec3(-f.z, 0.0f, f.x);
}

private struct ShotLaunch {
    Vec3 velocity;
    Vec3 spin;
}

private ShotLaunch planShot(ClubSpec club, float aimYaw, float customLoft, float power, Lie lie, float distToCup = 100.0f) pure nothrow @nogc {
    float loft = customLoft;
    float speed = club.fullSpeed * power;
    float rpm = club.backspinRpm * power;

    if (club.kind == ClubKind.putter || lie == Lie.green) {
        loft = 2.0f;
        // Putter Calibration: Scale max putt speed based on distance to pin.
        // On a level green, rolling distance s ≈ v^2 / (2 * mu * g).
        // With mu ≈ 0.16, v = sqrt(2 * 0.16 * 9.81 * dist) ≈ 1.77 * sqrt(dist).
        // At 50% power, the putt reaches the pin. 100% power reaches double distance.
        immutable float safeDist = distToCup < 1.0f ? 1.0f : (distToCup > 35.0f ? 35.0f : distToCup);
        immutable float perfectSpeed = cast(float) sqrt(2.0 * FRIC_GREEN * 9.81 * safeDist);
        immutable float maxPuttSpeed = perfectSpeed * 2.0f; // 50% power = exact cup distance!
        speed = maxPuttSpeed * power;
        rpm = 60.0f * power;
    } else {
        final switch (lie) {
            case Lie.tee:
            case Lie.fairway:
                break;
            case Lie.rough:
                speed *= 0.82f;
                rpm *= 0.65f;
                break;
            case Lie.bunker:
                speed *= 0.60f;
                loft += 4.5f;
                rpm *= 0.78f;
                break;
            case Lie.green:
                break;
        }
    }

    immutable lr = loft * cast(float) PI / 180.0f;
    immutable fwd = aimForward(aimYaw);
    immutable dir = Vec3(fwd.x * cos(lr), sin(lr), fwd.z * cos(lr));
    immutable omega = rpm * (2.0f * cast(float) PI / 60.0f);

    return ShotLaunch(dir * speed, aimRight(aimYaw) * omega);
}

// ---------------------------------------------------------------------------
// Procedural PBR Texture Synthesis
// ---------------------------------------------------------------------------

private struct FastRng {
    uint state = 0x937c41aeu;

    float next01() nothrow @nogc {
        state = state * 1664525u + 1013904223u;
        return (state >> 8) * (1.0f / 16777216.0f);
    }

    float range(float minVal, float maxVal) nothrow @nogc {
        return minVal + (maxVal - minVal) * next01();
    }
}

/// Create a procedural RGBA8 texture with custom per-pixel synthesis
private Texture makeProceduralTexture(ref App app, uint width, uint height,
                                     scope void delegate(ubyte[] buf, uint w, uint h) @safe filler) {
    auto pixels = new ubyte[width * height * 4];
    filler(pixels, width, height);
    return Texture.fromPixels(app.gpu, pixels, width, height);
}

// ---------------------------------------------------------------------------
// Procedural 3D Mesh Builders
// ---------------------------------------------------------------------------

/// Sculpted terrain. `roughPatch` keeps only the tall grass outside the fairway
/// and lifts it a couple of centimeters so the cut reads as a different surface.
private TexMesh buildTerrainMesh(ref App app, bool roughPatch) {
    enum int NX = 72;
    enum int NZ = 144;
    enum float X_MIN = -32.0f;
    enum float X_MAX =  38.0f;
    enum float Z_MIN = -16.0f;
    enum float Z_MAX = 156.0f;

    auto verts = new TexVert[(NX + 1) * (NZ + 1)];
    auto indices = new ushort[NX * NZ * 6];

    uint vi = 0;
    foreach (iz; 0 .. NZ + 1) {
        immutable tz = cast(float) iz / cast(float) NZ;
        immutable z = Z_MIN + (Z_MAX - Z_MIN) * tz;
        foreach (ix; 0 .. NX + 1) {
            immutable tx = cast(float) ix / cast(float) NX;
            immutable x = X_MIN + (X_MAX - X_MIN) * tx;
            float y = courseElevation(x, z);
            if (roughPatch)
                y += 0.02f;
            immutable n = surfaceNormal(x, z);
            immutable u = (x - X_MIN) * 0.18f;
            immutable v = (z - Z_MIN) * 0.18f;

            verts[vi++] = TexVert([x, y, z], [n.x, n.y, n.z], [u, v]);
        }
    }

    uint ii = 0;
    foreach (iz; 0 .. NZ) {
        immutable tz = (cast(float) iz + 0.5f) / cast(float) NZ;
        immutable z = Z_MIN + (Z_MAX - Z_MIN) * tz;
        foreach (ix; 0 .. NX) {
            immutable tx = (cast(float) ix + 0.5f) / cast(float) NX;
            immutable x = X_MIN + (X_MAX - X_MIN) * tx;
            immutable tall = lieAt(Vec3(x, 0.0f, z)) == Lie.rough;
            if (tall != roughPatch)
                continue;

            immutable ushort a = cast(ushort)(iz * (NX + 1) + ix);
            immutable ushort b = cast(ushort)(a + NX + 1);
            indices[ii++] = a;
            indices[ii++] = b;
            indices[ii++] = cast(ushort)(b + 1);

            indices[ii++] = a;
            indices[ii++] = cast(ushort)(b + 1);
            indices[ii++] = cast(ushort)(a + 1);
        }
    }

    return TexMesh.fromData(app.gpu, verts, indices[0 .. ii]);
}

/// Generate coastal lagoon water plane with wave UV coordinates
private TexMesh buildWaterMesh(ref App app) {
    enum int WX = 24;
    enum int WZ = 56;
    enum float X0 = 13.5f;
    enum float X1 = 36.5f;
    enum float Z0 = 18.0f;
    enum float Z1 = 110.0f;
    enum float WATER_Y = -0.28f;

    auto verts = new TexVert[(WX + 1) * (WZ + 1)];
    auto indices = new ushort[WX * WZ * 6];

    uint vi = 0;
    foreach (iz; 0 .. WZ + 1) {
        immutable tz = cast(float) iz / cast(float) WZ;
        immutable z = Z0 + (Z1 - Z0) * tz;
        foreach (ix; 0 .. WX + 1) {
            immutable tx = cast(float) ix / cast(float) WX;
            immutable x = X0 + (X1 - X0) * tx;
            immutable u = tx * 6.0f;
            immutable v = tz * 18.0f;
            verts[vi++] = TexVert([x, WATER_Y, z], [0.0f, 1.0f, 0.0f], [u, v]);
        }
    }

    uint ii = 0;
    foreach (iz; 0 .. WZ) {
        foreach (ix; 0 .. WX) {
            immutable ushort a = cast(ushort)(iz * (WX + 1) + ix);
            immutable ushort b = cast(ushort)(a + WX + 1);
            indices[ii++] = a;
            indices[ii++] = b;
            indices[ii++] = cast(ushort)(b + 1);

            indices[ii++] = a;
            indices[ii++] = cast(ushort)(b + 1);
            indices[ii++] = cast(ushort)(a + 1);
        }
    }

    return TexMesh.fromData(app.gpu, verts, indices);
}

/// Sculpted putting green mesh overlay with velvety green material
private TexMesh buildGreenOverlayMesh(ref App app) {
    enum int RINGS = 14;
    enum int SEGS = 32;
    enum float CX = 1.6f;
    enum float CZ = 133.5f;
    enum float RX = 6.4f;
    enum float RZ = 8.6f;

    TexVert[] verts;
    ushort[] indices;

    immutable cy = courseElevation(CX, CZ) + 0.007f;
    immutable cn = surfaceNormal(CX, CZ);
    verts ~= TexVert([CX, cy, CZ], [cn.x, cn.y, cn.z], [0.5f, 0.5f]);

    foreach (r; 1 .. RINGS + 1) {
        immutable tr = cast(float) r / cast(float) RINGS;
        foreach (s; 0 .. SEGS) {
            immutable a = cast(float) s / cast(float) SEGS * 2.0f * cast(float) PI;
            immutable x = CX + cos(a) * RX * tr;
            immutable z = CZ + sin(a) * RZ * tr;
            immutable y = courseElevation(x, z) + 0.007f;
            immutable n = surfaceNormal(x, z);
            // Same world scale as the fairway so the mower stripes keep one direction.
            verts ~= TexVert([x, y, z], [n.x, n.y, n.z], [(x + 32.0f) * 0.18f, (z + 16.0f) * 0.18f]);
        }
    }

    foreach (s; 0 .. SEGS) {
        immutable ushort s0 = cast(ushort)(1 + s);
        immutable ushort s1 = cast(ushort)(1 + (s + 1) % SEGS);
        indices ~= [0, s1, s0];
    }

    foreach (r; 1 .. RINGS) {
        immutable ushort r0 = cast(ushort)(1 + (r - 1) * SEGS);
        immutable ushort r1 = cast(ushort)(1 + r * SEGS);
        foreach (s; 0 .. SEGS) {
            immutable ushort a = cast(ushort)(r0 + s);
            immutable ushort b = cast(ushort)(r0 + (s + 1) % SEGS);
            immutable ushort c = cast(ushort)(r1 + s);
            immutable ushort d = cast(ushort)(r1 + (s + 1) % SEGS);
            indices ~= [a, b, c];
            indices ~= [b, d, c];
        }
    }

    return TexMesh.fromData(app.gpu, verts, indices);
}

/// Scooped Sand Bunker mesh overlay dipping down into the bowl
private TexMesh buildBunkerMesh(ref App app, float cx, float cz, float rx, float rz) {
    enum int RINGS = 10;
    enum int SEGS = 24;

    TexVert[] verts;
    ushort[] indices;

    immutable cy = courseElevation(cx, cz) + 0.006f;
    immutable cn = surfaceNormal(cx, cz);
    verts ~= TexVert([cx, cy, cz], [cn.x, cn.y, cn.z], [0.5f, 0.5f]);

    foreach (r; 1 .. RINGS + 1) {
        immutable tr = cast(float) r / cast(float) RINGS;
        foreach (s; 0 .. SEGS) {
            immutable a = cast(float) s / cast(float) SEGS * 2.0f * cast(float) PI;
            immutable x = cx + cos(a) * rx * tr;
            immutable z = cz + sin(a) * rz * tr;
            immutable y = courseElevation(x, z) + 0.006f;
            immutable n = surfaceNormal(x, z);
            immutable u = 0.5f + cos(a) * 0.5f * tr;
            immutable v = 0.5f + sin(a) * 0.5f * tr;
            verts ~= TexVert([x, y, z], [n.x, n.y, n.z], [u * 2.4f, v * 2.4f]);
        }
    }

    foreach (s; 0 .. SEGS) {
        immutable ushort s0 = cast(ushort)(1 + s);
        immutable ushort s1 = cast(ushort)(1 + (s + 1) % SEGS);
        indices ~= [0, s1, s0];
    }

    foreach (r; 1 .. RINGS) {
        immutable ushort r0 = cast(ushort)(1 + (r - 1) * SEGS);
        immutable ushort r1 = cast(ushort)(1 + r * SEGS);
        foreach (s; 0 .. SEGS) {
            immutable ushort a = cast(ushort)(r0 + s);
            immutable ushort b = cast(ushort)(r0 + (s + 1) % SEGS);
            immutable ushort c = cast(ushort)(r1 + s);
            immutable ushort d = cast(ushort)(r1 + (s + 1) % SEGS);
            indices ~= [a, b, c];
            indices ~= [b, d, c];
        }
    }

    return TexMesh.fromData(app.gpu, verts, indices);
}

/// Manicured rectangular Tee Box pad
private TexMesh buildTeePadMesh(ref App app) {
    enum int QX = 12;
    enum int QZ = 14;
    enum float X0 = -2.6f;
    enum float X1 =  2.6f;
    enum float Z0 = -2.2f;
    enum float Z1 =  3.2f;

    auto verts = new TexVert[(QX + 1) * (QZ + 1)];
    auto indices = new ushort[QX * QZ * 6];

    uint vi = 0;
    foreach (iz; 0 .. QZ + 1) {
        immutable tz = cast(float) iz / cast(float) QZ;
        immutable z = Z0 + (Z1 - Z0) * tz;
        foreach (ix; 0 .. QX + 1) {
            immutable tx = cast(float) ix / cast(float) QX;
            immutable x = X0 + (X1 - X0) * tx;
            immutable y = courseElevation(x, z) + 0.007f;
            immutable n = surfaceNormal(x, z);
            verts[vi++] = TexVert([x, y, z], [n.x, n.y, n.z], [(x + 32.0f) * 0.18f, (z + 16.0f) * 0.18f]);
        }
    }

    uint ii = 0;
    foreach (iz; 0 .. QZ) {
        foreach (ix; 0 .. QX) {
            immutable ushort a = cast(ushort)(iz * (QX + 1) + ix);
            immutable ushort b = cast(ushort)(a + QX + 1);
            indices[ii++] = a;
            indices[ii++] = b;
            indices[ii++] = cast(ushort)(b + 1);

            indices[ii++] = a;
            indices[ii++] = cast(ushort)(b + 1);
            indices[ii++] = cast(ushort)(a + 1);
        }
    }

    return TexMesh.fromData(app.gpu, verts, indices);
}

/// Wooden boundary curb surrounding the tee box
private TexMesh buildTeeCurbMesh(ref App app) {
    TexVert[] verts;
    ushort[] indices;

    enum float X0 = -2.7f;
    enum float X1 =  2.7f;
    enum float Z0 = -2.3f;
    enum float Z1 =  3.3f;
    enum float THICK = 0.12f;
    enum float HEIGHT = 0.08f;

    void addCurbBeam(Vec3 a, Vec3 b) {
        immutable base = cast(ushort) verts.length;
        immutable Vec3 diff = b - a;
        immutable Vec3 fwd = diff.normalized();
        immutable Vec3 up = Vec3(0, 1, 0);
        immutable Vec3 side = fwd.cross(up) * THICK;

        immutable Vec3 p0 = a - side * 0.5f;
        immutable Vec3 p1 = a + side * 0.5f;
        immutable Vec3 p2 = b + side * 0.5f;
        immutable Vec3 p3 = b - side * 0.5f;

        verts ~= TexVert([p0.x, p0.y + HEIGHT, p0.z], [0, 1, 0], [0, 0]);
        verts ~= TexVert([p1.x, p1.y + HEIGHT, p1.z], [0, 1, 0], [1, 0]);
        verts ~= TexVert([p2.x, p2.y + HEIGHT, p2.z], [0, 1, 0], [1, 1]);
        verts ~= TexVert([p3.x, p3.y + HEIGHT, p3.z], [0, 1, 0], [0, 1]);

        indices ~= [base, cast(ushort)(base + 1), cast(ushort)(base + 2)];
        indices ~= [base, cast(ushort)(base + 2), cast(ushort)(base + 3)];
    }

    immutable yNW = courseElevation(X0, Z1);
    immutable yNE = courseElevation(X1, Z1);
    immutable ySE = courseElevation(X1, Z0);
    immutable ySW = courseElevation(X0, Z0);

    addCurbBeam(Vec3(X0, ySW, Z0), Vec3(X1, ySE, Z0));
    addCurbBeam(Vec3(X1, ySE, Z0), Vec3(X1, yNE, Z1));
    addCurbBeam(Vec3(X1, yNE, Z1), Vec3(X0, yNW, Z1));
    addCurbBeam(Vec3(X0, yNW, Z1), Vec3(X0, ySW, Z0));

    return TexMesh.fromData(app.gpu, verts, indices);
}

/// Detailed 3D Conifer Pine Tree (Cylindrical trunk + 4 stacked conical needle skirts)
private TexMesh buildPineTreeMesh(ref App app) {
    enum int SEGS = 12;
    enum int TIERS = 4;
    TexVert[] verts;
    ushort[] indices;

    void addCylinder(float r, float h0, float h1) {
        immutable base = cast(ushort) verts.length;
        foreach (i; 0 .. SEGS) {
            immutable a = cast(float) i / cast(float) SEGS * 2.0f * cast(float) PI;
            immutable nx = cos(a);
            immutable nz = sin(a);
            immutable u = cast(float) i / cast(float) SEGS;
            verts ~= TexVert([nx * r, h0, nz * r], [nx, 0.0f, nz], [u, 0.0f]);
            verts ~= TexVert([nx * r, h1, nz * r], [nx, 0.0f, nz], [u, 1.0f]);
        }
        foreach (i; 0 .. SEGS) {
            immutable ushort i0 = cast(ushort)(base + i * 2);
            immutable ushort i1 = cast(ushort)(base + ((i + 1) % SEGS) * 2);
            indices ~= [i0, cast(ushort)(i0 + 1), i1];
            indices ~= [i1, cast(ushort)(i0 + 1), cast(ushort)(i1 + 1)];
        }
    }

    void addCone(float rBottom, float rTop, float y0, float y1) {
        immutable base = cast(ushort) verts.length;
        immutable float slopeY = (rBottom - rTop) / (y1 - y0);
        foreach (i; 0 .. SEGS) {
            immutable a = cast(float) i / cast(float) SEGS * 2.0f * cast(float) PI;
            immutable nx = cos(a);
            immutable nz = sin(a);
            immutable u = cast(float) i / cast(float) SEGS;
            immutable n = Vec3(nx, slopeY, nz).normalized();
            verts ~= TexVert([nx * rBottom, y0, nz * rBottom], [n.x, n.y, n.z], [u, 0.0f]);
            verts ~= TexVert([nx * rTop,    y1, nz * rTop],    [n.x, n.y, n.z], [u, 1.0f]);
        }
        foreach (i; 0 .. SEGS) {
            immutable ushort i0 = cast(ushort)(base + i * 2);
            immutable ushort i1 = cast(ushort)(base + ((i + 1) % SEGS) * 2);
            indices ~= [i0, cast(ushort)(i0 + 1), i1];
            indices ~= [i1, cast(ushort)(i0 + 1), cast(ushort)(i1 + 1)];
        }
    }

    // Wooden Trunk
    addCylinder(0.22f, 0.0f, 2.4f);

    // 4 Layered Pine Needle Skirts
    addCone(1.85f, 0.90f, 1.4f, 2.8f);
    addCone(1.50f, 0.65f, 2.5f, 3.8f);
    addCone(1.15f, 0.35f, 3.5f, 4.7f);
    addCone(0.75f, 0.02f, 4.4f, 5.5f);

    return TexMesh.fromData(app.gpu, verts, indices);
}

/// Detailed 3D Deciduous Shade Tree (Trunk + 5 Organic Leaf Clusters)
private TexMesh buildDecidTreeMesh(ref App app) {
    TexVert[] verts;
    ushort[] indices;

    void addSphereCluster(Vec3 center, float r, uint segs, uint rings) {
        immutable base = cast(ushort) verts.length;
        foreach (y; 0 .. rings + 1) {
            immutable v = cast(float) y / cast(float) rings;
            immutable phi = v * cast(float) PI;
            immutable sy = cos(phi);
            immutable sr = sin(phi);
            foreach (x; 0 .. segs + 1) {
                immutable u = cast(float) x / cast(float) segs;
                immutable theta = u * 2.0f * cast(float) PI;
                immutable nx = sr * cos(theta);
                immutable nz = sr * sin(theta);
                verts ~= TexVert(
                    [center.x + nx * r, center.y + sy * r, center.z + nz * r],
                    [nx, sy, nz],
                    [u, 1.0f - v]
                );
            }
        }
        foreach (y; 0 .. rings) {
            foreach (x; 0 .. segs) {
                immutable ushort a = cast(ushort)(base + y * (segs + 1) + x);
                immutable ushort b = cast(ushort)(a + segs + 1);
                indices ~= [a, cast(ushort)(a + 1), b];
                indices ~= [cast(ushort)(a + 1), cast(ushort)(b + 1), b];
            }
        }
    }

    // Main canopy clusters
    addSphereCluster(Vec3( 0.0f, 3.6f,  0.0f), 1.70f, 12, 8);
    addSphereCluster(Vec3( 0.8f, 3.8f,  0.5f), 1.25f, 10, 6);
    addSphereCluster(Vec3(-0.7f, 3.7f, -0.4f), 1.30f, 10, 6);
    addSphereCluster(Vec3( 0.2f, 4.4f, -0.3f), 1.20f, 10, 6);
    addSphereCluster(Vec3(-0.3f, 4.3f,  0.6f), 1.15f, 10, 6);

    return TexMesh.fromData(app.gpu, verts, indices);
}

/// Faceted Coastal Granite Boulder
private TexMesh buildBoulderMesh(ref App app) {
    TexVert[] verts;
    ushort[] indices;

    // Low-poly sculpted rock dome
    enum int RINGS = 4;
    enum int SEGS = 8;
    FastRng rng;
    rng.state = 0x8a21f73eu;

    foreach (y; 0 .. RINGS + 1) {
        immutable v = cast(float) y / cast(float) RINGS;
        immutable phi = v * (cast(float) PI * 0.5f);
        immutable sy = cos(phi);
        immutable sr = sin(phi);
        foreach (x; 0 .. SEGS + 1) {
            immutable u = cast(float) x / cast(float) SEGS;
            immutable theta = u * 2.0f * cast(float) PI;
            immutable jitter = 0.85f + 0.30f * rng.next01();
            immutable nx = sr * cos(theta);
            immutable nz = sr * sin(theta);
            verts ~= TexVert(
                [nx * 1.2f * jitter, sy * 0.9f * jitter, nz * 1.4f * jitter],
                [nx, sy, nz],
                [u * 2.0f, v * 2.0f]
            );
        }
    }
    foreach (y; 0 .. RINGS) {
        foreach (x; 0 .. SEGS) {
            immutable ushort a = cast(ushort)(y * (SEGS + 1) + x);
            immutable ushort b = cast(ushort)(a + SEGS + 1);
            indices ~= [a, cast(ushort)(a + 1), b];
            indices ~= [cast(ushort)(a + 1), cast(ushort)(b + 1), b];
        }
    }

    return TexMesh.fromData(app.gpu, verts, indices);
}

/// Tournament Pin Pole & Brass Cup Rim
private TexMesh buildPinMesh(ref App app) {
    TexVert[] verts;
    ushort[] indices;
    enum int SEGS = 10;
    enum float POLE_R = 0.022f;
    enum float POLE_H = 2.45f;

    // Slender Metallic Pole
    foreach (i; 0 .. SEGS) {
        immutable a = cast(float) i / cast(float) SEGS * 2.0f * cast(float) PI;
        immutable nx = cos(a);
        immutable nz = sin(a);
        verts ~= TexVert([nx * POLE_R, 0.0f, nz * POLE_R],   [nx, 0.0f, nz], [0.0f, 0.0f]);
        verts ~= TexVert([nx * POLE_R, POLE_H, nz * POLE_R], [nx, 0.0f, nz], [1.0f, 1.0f]);
    }
    foreach (i; 0 .. SEGS) {
        immutable ushort i0 = cast(ushort)(i * 2);
        immutable ushort i1 = cast(ushort)(((i + 1) % SEGS) * 2);
        indices ~= [i0, cast(ushort)(i0 + 1), i1];
        indices ~= [i1, cast(ushort)(i0 + 1), cast(ushort)(i1 + 1)];
    }

    // Cup Liner Ring
    immutable base = cast(ushort) verts.length;
    enum float CUP_R = CUP_RADIUS;
    foreach (i; 0 .. SEGS * 2) {
        immutable a = cast(float) i / cast(float)(SEGS * 2) * 2.0f * cast(float) PI;
        immutable nx = cos(a);
        immutable nz = sin(a);
        verts ~= TexVert([nx * CUP_R, 0.008f, nz * CUP_R], [0.0f, 1.0f, 0.0f], [0.5f, 0.5f]);
        verts ~= TexVert([nx * (CUP_R - 0.025f), 0.008f, nz * (CUP_R - 0.025f)], [0.0f, 1.0f, 0.0f], [0.0f, 0.0f]);
    }
    foreach (i; 0 .. SEGS * 2) {
        immutable ushort i0 = cast(ushort)(base + i * 2);
        immutable ushort i1 = cast(ushort)(base + ((i + 1) % (SEGS * 2)) * 2);
        indices ~= [i0, i1, cast(ushort)(i0 + 1)];
        indices ~= [i1, cast(ushort)(i1 + 1), cast(ushort)(i0 + 1)];
    }

    return TexMesh.fromData(app.gpu, verts, indices);
}

// ---------------------------------------------------------------------------
// 3D Procedural Audio Engine
// ---------------------------------------------------------------------------

private enum int SFX_RATE = 48000;

private float[] synthTone(float freqHz, float durationSec, float volume,
                          float attack = 0.004f, float release = 0.04f, float pitchDrop = 0.0f) {
    immutable n = cast(int)(durationSec * SFX_RATE);
    if (n <= 0) return null;
    auto pcm = new float[](n * 2);
    foreach (i; 0 .. n) {
        immutable t = cast(float) i / SFX_RATE;
        float env = 1.0f;
        if (t < attack) env = t / attack;
        immutable rem = durationSec - t;
        if (rem < release) env *= rem / release;

        immutable curFreq = freqHz * (1.0f - pitchDrop * (t / durationSec));
        immutable sample = sin(2.0f * cast(float) PI * curFreq * t) * volume * env;
        pcm[i * 2 + 0] = sample;
        pcm[i * 2 + 1] = sample;
    }
    return pcm;
}

private float[] synthNoise(float durationSec, float volume, float attack = 0.01f, float release = 0.08f) {
    immutable n = cast(int)(durationSec * SFX_RATE);
    if (n <= 0) return null;
    auto pcm = new float[](n * 2);
    FastRng rng;
    rng.state = 0x4a1829e1u;
    foreach (i; 0 .. n) {
        immutable t = cast(float) i / SFX_RATE;
        float env = 1.0f;
        if (t < attack) env = t / attack;
        immutable rem = durationSec - t;
        if (rem < release) env *= rem / release;

        immutable noise = (rng.next01() * 2.0f - 1.0f) * volume * env;
        pcm[i * 2 + 0] = noise;
        pcm[i * 2 + 1] = noise;
    }
    return pcm;
}

private float[] synthFanfare() {
    return synthTone(523.25f, 0.14f, 0.42f) ~
           synthTone(659.25f, 0.16f, 0.44f) ~
           synthTone(783.99f, 0.32f, 0.48f, 0.005f, 0.14f);
}

private float[] synthWindRush(float durationSec, float volume) {
    immutable n = cast(int)(durationSec * SFX_RATE);
    if (n <= 0) return null;
    auto pcm = new float[](n * 2);
    FastRng rng;
    rng.state = 0x5b2910c2u;
    float filter = 0.0f;
    foreach (i; 0 .. n) {
        immutable t = cast(float) i / SFX_RATE;
        immutable env = sin(cast(float) PI * (t / durationSec));
        immutable raw = rng.next01() * 2.0f - 1.0f;
        filter += 0.040f * (raw - filter);
        immutable sample = filter * volume * env;
        pcm[i * 2 + 0] = sample;
        pcm[i * 2 + 1] = sample;
    }
    return pcm;
}

private struct GolfAudio {
    AudioClip driverCrack;
    AudioClip ironThwack;
    AudioClip wedgeThump;
    AudioClip putterClick;
    AudioClip cupRattle;
    AudioClip victoryFanfare;
    AudioClip waterSplash;
    AudioClip sandThud;
    AudioClip windGust;

    static GolfAudio create() {
        GolfAudio a;
        // Driver: Titanium pop + hollow reverberation ping
        a.driverCrack = AudioClip.fromInterleavedF32(
            synthTone(155.0f, 0.08f, 0.48f, 0.002f, 0.06f, 0.35f) ~
            synthTone(880.0f, 0.07f, 0.25f, 0.001f, 0.05f));
        // Forged Iron: Solid crisp metallic impact
        a.ironThwack = AudioClip.fromInterleavedF32(
            synthTone(310.0f, 0.065f, 0.40f, 0.002f, 0.045f, 0.22f));
        // Sand Wedge: Turf compression thump
        a.wedgeThump = AudioClip.fromInterleavedF32(
            synthTone(175.0f, 0.07f, 0.35f, 0.004f, 0.05f));
        // Putter: Pure solid click
        a.putterClick = AudioClip.fromInterleavedF32(
            synthTone(490.0f, 0.04f, 0.28f, 0.001f, 0.03f));
        // Ball dropping and spinning inside the cup
        a.cupRattle = AudioClip.fromInterleavedF32(
            synthTone(380.0f, 0.06f, 0.36f) ~ synthTone(460.0f, 0.10f, 0.32f));
        // Celebratory fanfare
        a.victoryFanfare = AudioClip.fromInterleavedF32(synthFanfare());
        // Environmental water hazard splash
        a.waterSplash = AudioClip.fromInterleavedF32(synthNoise(0.42f, 0.35f, 0.02f, 0.26f));
        // Sand bunker compression thud
        a.sandThud = AudioClip.fromInterleavedF32(synthNoise(0.20f, 0.30f, 0.01f, 0.14f));
        // Ambient wind rush
        a.windGust = AudioClip.fromInterleavedF32(synthWindRush(1.6f, 0.28f));
        return a;
    }

    void destroy() {
        driverCrack.destroy();
        ironThwack.destroy();
        wedgeThump.destroy();
        putterClick.destroy();
        cupRattle.destroy();
        victoryFanfare.destroy();
        waterSplash.destroy();
        sandThud.destroy();
        windGust.destroy();
    }
}

// ---------------------------------------------------------------------------
// Dynamic Foliage & Course Prop Structures
// ---------------------------------------------------------------------------

private struct PropInstance {
    Vec3 pos;
    Vec3 scale;
    float rotY;
    bool isCanopy;
}

// ---------------------------------------------------------------------------
// 2D Hardware-Accelerated Graphical UI Pipeline
// ---------------------------------------------------------------------------

private enum string uiShaderSource = `
struct UiUniforms {
    screenSize: vec2<f32>,
};
@group(0) @binding(0) var<uniform> u: UiUniforms;

struct UiVertexInput {
    @location(0) position: vec2<f32>,
    @location(1) color: vec4<f32>,
};

struct UiVertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_ui(in: UiVertexInput) -> UiVertexOutput {
    let ndc = vec2<f32>(
        in.position.x / u.screenSize.x * 2.0 - 1.0,
        1.0 - in.position.y / u.screenSize.y * 2.0,
    );
    var out: UiVertexOutput;
    out.clipPos = vec4<f32>(ndc, 0.0, 1.0);
    out.color = in.color;
    return out;
}

@fragment
fn fs_ui(in: UiVertexOutput) -> @location(0) vec4<f32> {
    return in.color;
}
`;

struct UiVert {
    float[2] pos;
    float[4] color;
}

struct UiRenderer {
    private WGPURenderPipeline pipeline;
    private WGPUBindGroupLayout bindGroupLayout;
    private WGPUPipelineLayout pipelineLayout;
    private WGPUShaderModule shaderModule;
    private WGPUBuffer vertexBuf;
    private WGPUBuffer uniformBuf;
    private WGPUBindGroup bindGroup;
    private WGPUDevice device;
    private WGPUQueue queue;

    enum size_t MAX_UI_VERTS = 16384;
    private UiVert[MAX_UI_VERTS] verts;
    private size_t vertCount = 0;

    @disable this(this);

    static UiRenderer create(ref GpuContext gpu, uint screenW, uint screenH) @trusted {
        UiRenderer r;
        r.device = gpu.getDevice();
        r.queue = gpu.getQueue();
        auto surfFmt = gpu.getFormat();

        r.shaderModule = createShaderModule(r.device, uiShaderSource.ptr);

        WGPUBindGroupLayoutEntry bgle;
        bgle.binding = 0;
        bgle.visibility = WGPUShaderStage.vertex;
        bgle.buffer.type = WGPUBufferBindingType.uniform;
        bgle.buffer.minBindingSize = 8;

        WGPUBindGroupLayoutDescriptor bglDesc;
        bglDesc.entryCount = 1;
        bglDesc.entries = &bgle;
        r.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(r.device, &bglDesc);

        WGPUPipelineLayoutDescriptor plDesc;
        plDesc.bindGroupLayoutCount = 1;
        plDesc.bindGroupLayouts = &r.bindGroupLayout;
        r.pipelineLayout = wgpuDeviceCreatePipelineLayout(r.device, &plDesc);

        WGPUVertexAttribute[2] attrs = [
            { format: WGPUVertexFormat.float32x2, offset: 0, shaderLocation: 0 },
            { format: WGPUVertexFormat.float32x4, offset: 8, shaderLocation: 1 },
        ];

        WGPUVertexBufferLayout bufLayout;
        bufLayout.arrayStride = UiVert.sizeof;
        bufLayout.stepMode = WGPUVertexStepMode.vertex;
        bufLayout.attributeCount = 2;
        bufLayout.attributes = attrs.ptr;

        WGPUBlendState blend;
        blend.color.operation = WGPUBlendOperation.add;
        blend.color.srcFactor = WGPUBlendFactor.srcAlpha;
        blend.color.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;
        blend.alpha.operation = WGPUBlendOperation.add;
        blend.alpha.srcFactor = WGPUBlendFactor.one;
        blend.alpha.dstFactor = WGPUBlendFactor.oneMinusSrcAlpha;

        WGPUColorTargetState colorTarget;
        colorTarget.format = surfFmt;
        colorTarget.blend = &blend;
        colorTarget.writeMask = WGPUColorWriteMask.all;

        WGPUFragmentState frag;
        frag.module_ = r.shaderModule;
        frag.entryPoint = wgpuStringView("fs_ui");
        frag.targetCount = 1;
        frag.targets = &colorTarget;

        WGPURenderPipelineDescriptor pd;
        pd.layout = r.pipelineLayout;
        pd.vertex.module_ = r.shaderModule;
        pd.vertex.entryPoint = wgpuStringView("vs_ui");
        pd.vertex.bufferCount = 1;
        pd.vertex.buffers = &bufLayout;
        pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
        pd.primitive.cullMode = WGPUCullMode.none;
        pd.fragment = &frag;

        r.pipeline = wgpuDeviceCreateRenderPipeline(r.device, &pd);

        r.vertexBuf = createDynamicVertexBuffer(r.device, MAX_UI_VERTS * UiVert.sizeof);
        r.uniformBuf = createUniformBuffer(r.device, 8);
        float[2] ss = [cast(float) screenW, cast(float) screenH];
        wgpuQueueWriteBuffer(r.queue, r.uniformBuf, 0, ss.ptr, 8);

        WGPUBindGroupEntry bge;
        bge.binding = 0;
        bge.buffer = r.uniformBuf;
        bge.offset = 0;
        bge.size = 8;

        WGPUBindGroupDescriptor bgd;
        bgd.layout = r.bindGroupLayout;
        bgd.entryCount = 1;
        bgd.entries = &bge;
        r.bindGroup = wgpuDeviceCreateBindGroup(r.device, &bgd);

        return r;
    }

    void begin() nothrow @nogc {
        vertCount = 0;
    }

    void rect(float x, float y, float w, float h, Color4 c) nothrow @nogc {
        if (vertCount + 6 > MAX_UI_VERTS) return;
        immutable float[4] col = [c.r, c.g, c.b, c.a];
        verts[vertCount++] = UiVert([x, y], col);
        verts[vertCount++] = UiVert([x + w, y], col);
        verts[vertCount++] = UiVert([x + w, y + h], col);

        verts[vertCount++] = UiVert([x, y], col);
        verts[vertCount++] = UiVert([x + w, y + h], col);
        verts[vertCount++] = UiVert([x, y + h], col);
    }

    void rectGradientH(float x, float y, float w, float h, Color4 cLeft, Color4 cRight) nothrow @nogc {
        if (vertCount + 6 > MAX_UI_VERTS) return;
        immutable float[4] cl = [cLeft.r, cLeft.g, cLeft.b, cLeft.a];
        immutable float[4] cr = [cRight.r, cRight.g, cRight.b, cRight.a];

        verts[vertCount++] = UiVert([x, y], cl);
        verts[vertCount++] = UiVert([x + w, y], cr);
        verts[vertCount++] = UiVert([x + w, y + h], cr);

        verts[vertCount++] = UiVert([x, y], cl);
        verts[vertCount++] = UiVert([x + w, y + h], cr);
        verts[vertCount++] = UiVert([x, y + h], cl);
    }

    void frameBorder(float x, float y, float w, float h, float thickness, Color4 c) nothrow @nogc {
        rect(x, y, w, thickness, c); // top
        rect(x, y + h - thickness, w, thickness, c); // bottom
        rect(x, y, thickness, h, c); // left
        rect(x + w - thickness, y, thickness, h, c); // right
    }

    void glassCard(float x, float y, float w, float h, Color4 bg, Color4 border, float borderThick = 1.5f) nothrow @nogc {
        rect(x, y, w, h, bg);
        frameBorder(x, y, w, h, borderThick, border);
    }

    /// Quarter-circle fan. Angle 0 points right; Y grows downward, so angles increase clockwise.
    private void cornerFan(float cx, float cy, float radius, float a0, float a1, Color4 c, int segments = 8) nothrow @nogc {
        if (radius <= 0.0f || segments < 1) return;
        if (vertCount + segments * 3 > MAX_UI_VERTS) return;
        immutable float[4] col = [c.r, c.g, c.b, c.a];
        foreach (i; 0 .. segments) {
            immutable t0 = cast(float) i / cast(float) segments;
            immutable t1 = cast(float)(i + 1) / cast(float) segments;
            immutable ang0 = a0 + (a1 - a0) * t0;
            immutable ang1 = a0 + (a1 - a0) * t1;
            verts[vertCount++] = UiVert([cx, cy], col);
            verts[vertCount++] = UiVert([cx + cos(ang0) * radius, cy + sin(ang0) * radius], col);
            verts[vertCount++] = UiVert([cx + cos(ang1) * radius, cy + sin(ang1) * radius], col);
        }
    }

    void roundedRect(float x, float y, float w, float h, float radius, Color4 c) nothrow @nogc {
        if (w <= 0.0f || h <= 0.0f) return;
        float r = radius;
        if (r < 0.0f) r = 0.0f;
        immutable maxR = (w < h ? w : h) * 0.5f;
        if (r > maxR) r = maxR;
        if (r < 0.75f) {
            rect(x, y, w, h, c);
            return;
        }
        rect(x + r, y, w - r * 2.0f, h, c);
        rect(x, y + r, r, h - r * 2.0f, c);
        rect(x + w - r, y + r, r, h - r * 2.0f, c);
        immutable float halfPi = cast(float) PI * 0.5f;
        cornerFan(x + r,         y + r,         r, cast(float) PI, cast(float) PI + halfPi, c);
        cornerFan(x + w - r,     y + r,         r, cast(float) PI + halfPi, cast(float) PI * 2.0f, c);
        cornerFan(x + w - r,     y + h - r,     r, 0.0f, halfPi, c);
        cornerFan(x + r,         y + h - r,     r, halfPi, cast(float) PI, c);
    }

    void pill(float x, float y, float w, float h, Color4 c) nothrow @nogc {
        roundedRect(x, y, w, h, h * 0.5f, c);
    }

    /// Floating surface: soft drop shadow, fill, and a 1 px specular lip.
    void elevatedCard(float x, float y, float w, float h, float radius, Color4 fill) nothrow @nogc {
        immutable shade = fill.a;
        roundedRect(x, y + 10.0f, w, h, radius, Color4(0.0f, 0.0f, 0.0f, 0.28f * shade));
        roundedRect(x, y + 4.0f, w, h, radius, Color4(0.0f, 0.0f, 0.0f, 0.16f * shade));
        roundedRect(x, y, w, h, radius, fill);
        if (w > radius * 2.0f + 8.0f)
            rect(x + radius, y + 1.0f, w - radius * 2.0f, 1.0f, Color4(1.0f, 1.0f, 1.0f, 0.14f * shade));
    }

    void circleFill(float cx, float cy, float radius, Color4 c, int segments = 24) nothrow @nogc {
        if (vertCount + segments * 3 > MAX_UI_VERTS) return;
        immutable float[4] col = [c.r, c.g, c.b, c.a];
        foreach (i; 0 .. segments) {
            immutable a0 = cast(float) i / cast(float) segments * 2.0f * cast(float) PI;
            immutable a1 = cast(float)(i + 1) / cast(float) segments * 2.0f * cast(float) PI;
            verts[vertCount++] = UiVert([cx, cy], col);
            verts[vertCount++] = UiVert([cx + cos(a0) * radius, cy + sin(a0) * radius], col);
            verts[vertCount++] = UiVert([cx + cos(a1) * radius, cy + sin(a1) * radius], col);
        }
    }

    void circleRing(float cx, float cy, float radius, float thickness, Color4 c, int segments = 24) nothrow @nogc {
        if (vertCount + segments * 6 > MAX_UI_VERTS) return;
        immutable float[4] col = [c.r, c.g, c.b, c.a];
        immutable rIn = radius - thickness * 0.5f;
        immutable rOut = radius + thickness * 0.5f;
        foreach (i; 0 .. segments) {
            immutable a0 = cast(float) i / cast(float) segments * 2.0f * cast(float) PI;
            immutable a1 = cast(float)(i + 1) / cast(float) segments * 2.0f * cast(float) PI;

            immutable float[2] p0In  = [cx + cos(a0) * rIn,  cy + sin(a0) * rIn];
            immutable float[2] p0Out = [cx + cos(a0) * rOut, cy + sin(a0) * rOut];
            immutable float[2] p1In  = [cx + cos(a1) * rIn,  cy + sin(a1) * rIn];
            immutable float[2] p1Out = [cx + cos(a1) * rOut, cy + sin(a1) * rOut];

            verts[vertCount++] = UiVert(p0In,  col);
            verts[vertCount++] = UiVert(p0Out, col);
            verts[vertCount++] = UiVert(p1Out, col);

            verts[vertCount++] = UiVert(p0In,  col);
            verts[vertCount++] = UiVert(p1Out, col);
            verts[vertCount++] = UiVert(p1In,  col);
        }
    }

    void needle(float cx, float cy, float angleRad, float len, float width, Color4 c) nothrow @nogc {
        if (vertCount + 3 > MAX_UI_VERTS) return;
        immutable float[4] col = [c.r, c.g, c.b, c.a];
        immutable float fwdX = sin(angleRad);
        immutable float fwdY = -cos(angleRad);
        immutable float rightX = -fwdY;
        immutable float rightY = fwdX;

        immutable float[2] tip = [cx + fwdX * len, cy + fwdY * len];
        immutable float[2] bL  = [cx - rightX * width, cy - rightY * width];
        immutable float[2] bR  = [cx + rightX * width, cy + rightY * width];

        verts[vertCount++] = UiVert(bL, col);
        verts[vertCount++] = UiVert(tip, col);
        verts[vertCount++] = UiVert(bR, col);
    }

    void render(ref FrameContext frame) nothrow @nogc @trusted {
        if (!frame.valid || vertCount == 0) return;
        immutable byteCount = vertCount * UiVert.sizeof;
        wgpuQueueWriteBuffer(queue, vertexBuf, 0, verts.ptr, byteCount);

        wgpuRenderPassEncoderSetPipeline(frame.pass, pipeline);
        wgpuRenderPassEncoderSetBindGroup(frame.pass, 0, bindGroup, 0, null);
        wgpuRenderPassEncoderSetVertexBuffer(frame.pass, 0, vertexBuf, 0, byteCount);
        wgpuRenderPassEncoderDraw(frame.pass, cast(uint) vertCount, 1, 0, 0);
    }

    void destroy() nothrow @nogc @trusted {
        if (bindGroup !is null) { wgpuBindGroupRelease(bindGroup); bindGroup = null; }
        if (uniformBuf !is null) { destroyBuffer(uniformBuf); uniformBuf = null; }
        if (vertexBuf !is null) { destroyBuffer(vertexBuf); vertexBuf = null; }
        if (pipeline !is null) { wgpuRenderPipelineRelease(pipeline); pipeline = null; }
        if (pipelineLayout !is null) { wgpuPipelineLayoutRelease(pipelineLayout); pipelineLayout = null; }
        if (bindGroupLayout !is null) { wgpuBindGroupLayoutRelease(bindGroupLayout); bindGroupLayout = null; }
        if (shaderModule !is null) { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }
    }
}

// ---------------------------------------------------------------------------
// 3D Visual Wind Streaks
// ---------------------------------------------------------------------------

private struct WindStreak {
    Vec3 pos;
    float life = 0.0f;
    float maxLife = 1.0f;
    float speedMultiplier = 1.0f;
}

private struct WindStreakSystem {
    WindStreak[64] streaks;
    FastRng rng;

    void respawn(ref WindStreak s, Vec3 focus) nothrow @nogc {
        s.pos = Vec3(
            focus.x + rng.range(-22.0f, 22.0f),
            rng.range(0.4f, 18.0f),
            focus.z + rng.range(-26.0f, 26.0f),
        );
        s.maxLife = rng.range(1.2f, 2.8f);
        s.life = s.maxLife;
        s.speedMultiplier = rng.range(0.9f, 1.3f);
    }

    void init(Vec3 focus) nothrow @nogc {
        rng.state = 0x76b2c93du;
        foreach (ref s; streaks)
            respawn(s, focus);
    }

    void update(float dt, WindField wind, Vec3 focus) nothrow @nogc {
        foreach (ref s; streaks) {
            s.life -= dt;
            if (s.life <= 0.0f) {
                respawn(s, focus);
                continue;
            }
            immutable w = liveWind(wind, s.pos);
            s.pos = s.pos + w * (dt * s.speedMultiplier);
        }
    }

    void draw(ref GizmoRenderer gizmos, WindField wind) {
        foreach (ref s; streaks) {
            immutable w = liveWind(wind, s.pos);
            immutable spd = w.length();
            if (spd < 0.2f) continue;
            immutable dir = w * (1.0f / spd);
            immutable streakLen = 0.45f + spd * 0.14f;
            immutable fade = s.life / s.maxLife;
            immutable c = Color4(0.65f * fade, 0.90f * fade, 1.25f * fade, 0.85f * fade);
            gizmos.line(s.pos, s.pos + dir * streakLen, c);
        }
    }
}

// ---------------------------------------------------------------------------
// Dynamic Flag & Cloth Billow Renderer
// ---------------------------------------------------------------------------

private void drawBillowingFlag(ref GizmoRenderer gizmos, WindField wind, Vec3 pinPos) {
    immutable poleTop = pinPos + Vec3(0.0f, 2.45f, 0.0f);
    immutable w = liveWind(wind, poleTop);
    immutable spd = Vec3(w.x, 0.0f, w.z).length();
    immutable yaw = atan2(w.x, w.z);

    // Dynamic flutter math
    immutable float clothFreq = 7.5f + spd * 0.6f;
    immutable float flagLen = 0.95f;
    immutable float flagH = 0.42f;

    enum int SLICES = 12;
    Vec3 prevTop = poleTop;
    Vec3 prevBot = poleTop - Vec3(0.0f, flagH, 0.0f);

    immutable Color4 colCrimson = Color4(0.95f, 0.15f, 0.12f, 1.0f);
    immutable Color4 colGold    = Color4(1.05f, 0.85f, 0.20f, 1.0f);

    foreach (i; 1 .. SLICES + 1) {
        immutable t = cast(float) i / cast(float) SLICES;
        immutable sDist = t * flagLen;
        immutable wave = 0.08f * sin(wind.time * clothFreq - sDist * 4.5f) * t;

        // Along wind vector
        immutable alongX = sin(yaw) * sDist + cos(yaw) * wave;
        immutable alongZ = cos(yaw) * sDist - sin(yaw) * wave;
        immutable droopY = -0.15f * (1.0f / (1.0f + spd * 0.35f)) * t * t;

        immutable curTop = poleTop + Vec3(alongX, droopY, alongZ);
        // Flag tapers toward the fly tip
        immutable curBot = poleTop + Vec3(alongX, droopY - flagH * (1.0f - t * 0.45f), alongZ);

        gizmos.line(prevTop, curTop, colGold);
        gizmos.line(prevBot, curBot, colCrimson);
        gizmos.line(curTop, curBot, colCrimson);
        // Cross diagonal for cloth weave
        gizmos.line(prevTop, curBot, colCrimson);

        prevTop = curTop;
        prevBot = curBot;
    }
}

// ---------------------------------------------------------------------------
// Trajectory Forecast & Green Slope Visualization
// ---------------------------------------------------------------------------

private void drawTrajectoryForecast(ref GizmoRenderer gizmos, Vec3 origin, ShotLaunch launch, WindField wind) {
    immutable mass = ballMass();
    enum float dt = 1.0f / 120.0f;
    Vec3 pos = origin;
    Vec3 vel = launch.velocity;
    Vec3 omega = launch.spin;
    Vec3 prev = pos;

    immutable Color4 cGold = Color4(1.15f, 0.95f, 0.30f, 1.0f);
    immutable Color4 cOrange = Color4(1.10f, 0.55f, 0.15f, 1.0f);

    foreach (n; 0 .. 120 * 6) {
        immutable f = aeroForce(vel, omega, steadyWind(wind, pos));
        vel = vel + f * (dt / mass);
        vel.y -= 9.81f * dt;
        pos = pos + vel * dt;
        omega = omega * (1.0f / (1.0f + 0.035f * dt));

        if ((n % 5) == 4) {
            immutable blend = cast(float) n / (120.0f * 4.0f);
            immutable col = Color4(
                cGold.r * (1.0f - blend) + cOrange.r * blend,
                cGold.g * (1.0f - blend) + cOrange.g * blend,
                cGold.b * (1.0f - blend) + cOrange.b * blend,
                1.0f
            );
            gizmos.line(prev, pos, col);
            prev = pos;
        }
        if (n > 30 && pos.y <= courseElevation(pos.x, pos.z) + BALL_R)
            break;
    }
    gizmos.line(prev, pos, cOrange);
}

private void drawGreenPuttingContours(ref GizmoRenderer gizmos, Vec3 ballPos) {
    enum int R = 7;
    immutable int cx = cast(int)(ballPos.x + 0.5f);
    immutable int cz = cast(int)(ballPos.z + 0.5f);
    immutable Color4 colGrid = Color4(0.35f, 0.92f, 0.45f, 0.40f);
    immutable Color4 colFlow = Color4(1.05f, 1.05f, 0.25f, 0.75f);

    foreach (ix; -R .. R) {
        foreach (iz; -R .. R) {
            immutable x0 = cast(float)(cx + ix);
            immutable z0 = cast(float)(cz + iz);
            immutable x1 = x0 + 1.0f;
            immutable z1 = z0 + 1.0f;

            if (lieAt(Vec3(x0, 0, z0)) == Lie.green && lieAt(Vec3(x1, 0, z1)) == Lie.green) {
                immutable y00 = courseElevation(x0, z0) + 0.008f;
                immutable y10 = courseElevation(x1, z0) + 0.008f;
                immutable y01 = courseElevation(x0, z1) + 0.008f;

                gizmos.line(Vec3(x0, y00, z0), Vec3(x1, y10, z0), colGrid);
                gizmos.line(Vec3(x0, y00, z0), Vec3(x0, y01, z1), colGrid);

                // Slope break arrow down gradient
                immutable n = surfaceNormal(x0 + 0.5f, z0 + 0.5f);
                immutable slopeVec = Vec3(-n.x, 0.0f, -n.z);
                if (slopeVec.length() > 0.001f) {
                    immutable mid = Vec3(x0 + 0.5f, courseElevation(x0 + 0.5f, z0 + 0.5f) + 0.012f, z0 + 0.5f);
                    gizmos.line(mid, mid + slopeVec * 16.0f, colFlow);
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Physical Turf Contact & Ball Control
// ---------------------------------------------------------------------------

private void placeBall(b3BodyId ball, Vec3 pos) {
    writeBodyTransform(ball, pos, Quat.init);
    setLinearVelocity(ball, Vec3(0.0f, 0.0f, 0.0f));
    setAngularVelocity(ball, Vec3(0.0f, 0.0f, 0.0f));
}

private bool checkCupCapture(Vec3 pos, Vec3 vel) pure nothrow @nogc {
    if (pos.y > 0.38f + 0.16f || pos.y < 0.38f - 0.12f)
        return false;
    if (vel.length() > 2.35f)
        return false; // Skimmed over the cup at excessive speed
    immutable dx = pos.x - CUP_X;
    immutable dz = pos.z - CUP_Z;
    return (dx * dx + dz * dz) <= (CUP_RADIUS * 1.15f) * (CUP_RADIUS * 1.15f);
}

private void applyGroundPhysics(b3BodyId ball, float dt, GameState state) {
    auto pos = getPosition(ball);
    immutable groundY = courseElevation(pos.x, pos.z);
    immutable contactY = groundY + BALL_R;

    if (state == GameState.aim) {
        // While aiming, the ball is firmly seated on the turf / tee
        if (pos.y < contactY || fabs(pos.y - contactY) > 0.002f) {
            pos.y = contactY;
            immutable rot = readBodyTransform(ball).rotation;
            writeBodyTransform(ball, pos, rot);
        }
        setLinearVelocity(ball, Vec3(0.0f, 0.0f, 0.0f));
        setAngularVelocity(ball, Vec3(0.0f, 0.0f, 0.0f));
        return;
    }

    if (pos.y <= contactY + 0.035f) {
        // Position clamp: can NEVER fall through the ground
        if (pos.y < contactY) {
            pos.y = contactY;
            immutable rot = readBodyTransform(ball).rotation;
            writeBodyTransform(ball, pos, rot);
        }

        immutable lie = lieAt(pos);
        float mu = FRIC_FAIRWAY;
        float restitution = 0.25f;
        final switch (lie) {
            case Lie.tee:
                mu = FRIC_TEE;
                restitution = 0.30f;
                break;
            case Lie.fairway:
                mu = FRIC_FAIRWAY;
                restitution = 0.25f;
                break;
            case Lie.rough:
                mu = FRIC_ROUGH;
                restitution = 0.10f;
                break;
            case Lie.bunker:
                mu = FRIC_BUNKER;
                restitution = 0.02f;
                break;
            case Lie.green:
                mu = FRIC_GREEN;
                restitution = 0.40f;
                break;
        }

        auto v = getLinearVelocity(ball);
        auto w = getAngularVelocity(ball);
        immutable n = surfaceNormal(pos.x, pos.z);

        // Decompose velocity into normal and tangential components
        immutable vn = v.dot(n);

        if (vn < -0.7f) {
            // Rebound. Tall grass and sand grab the skip; the green lets it bounce.
            immutable vTangent = v - n * vn;
            float skim = 0.62f;
            if (lie == Lie.rough)
                skim = 0.18f;
            else if (lie == Lie.bunker)
                skim = 0.15f;
            else if (lie == Lie.green)
                skim = 0.88f;
            v = vTangent * skim - n * (vn * restitution);
        } else {
            // Rolling contact: eliminate normal velocity into ground
            v = v - n * vn;

            // Slope roll acceleration along the terrain gradient
            immutable slopeAccel = Vec3(n.x, 0.0f, n.z) * (9.81f * dt);
            v = v + slopeAccel;

            // Cup Lip In Suction: gravitational funnel within 0.28m of the hole
            immutable dx = CUP_X - pos.x;
            immutable dz = CUP_Z - pos.z;
            immutable distToCup = sqrt(dx * dx + dz * dz);
            if (distToCup < 0.28f && distToCup > 0.01f && v.length() < 2.4f) {
                immutable pullDir = Vec3(dx / distToCup, 0.0f, dz / distToCup);
                immutable pullStrength = (1.0f - distToCup / 0.28f) * 4.2f * dt;
                v = v + pullDir * pullStrength;
            }

            // Rolling resistance deceleration
            immutable speed = v.length();
            immutable decel = mu * 9.81f * dt;
            if (speed <= decel) {
                v = Vec3(0.0f, 0.0f, 0.0f);
            } else {
                v = v * ((speed - decel) / speed);
            }
        }

        setLinearVelocity(ball, v);

        // Angular velocity deceleration
        immutable wlen = w.length();
        immutable wdecel = (mu * 9.81f * dt) / BALL_R;
        if (wlen <= wdecel)
            setAngularVelocity(ball, Vec3(0.0f, 0.0f, 0.0f));
        else
            setAngularVelocity(ball, w * ((wlen - wdecel) / wlen));
    }
}

// ---------------------------------------------------------------------------
// Main Game Demo Execution
// ---------------------------------------------------------------------------

int main() {
    auto app = App.create("Emerald Dunes 3D Championship Golf", SCREEN_W, SCREEN_H, WGPUPresentMode.fifo);

    // Enable high-end post processing: Bloom + ACES Tonemapper + FXAA
    app.post.bloom = true;
    app.post.bloomThreshold = 1.35f;
    app.post.bloomStrength = 0.12f;
    app.post.tonemapMode = 0; // ACES filmic
    app.post.fxaa = true;
    app.post.exposure = 1.0f;

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();

    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto layout = scene.materialLayout();

    // Directional Shadow Map (2048x2048)
    auto shadowPipe = createShadowPipeline(app.gpu.getDevice());
    scope(exit) shadowPipe.release();
    auto lightBuf = createUniformBuffer(app.gpu.getDevice(), 64);
    scope(exit) destroyBuffer(lightBuf);
    auto lightBg = createUniformBindGroup(app.gpu.getDevice(), shadowPipe.bindGroupLayout, lightBuf, 64);
    scope(exit) releaseBindGroup(lightBg);
    auto shadowInstanceBuf = createDynamicVertexBuffer(app.gpu.getDevice(), 512 * InstanceData.sizeof);
    scope(exit) destroyBuffer(shadowInstanceBuf);

    auto dirShadow = ShadowMap.create(app.gpu, 2048);
    scope(exit) dirShadow.destroy();

    // -----------------------------------------------------------------------
    // Procedural PBR Textures (256x256 High-Resolution Multi-Octave Synthesis)
    // -----------------------------------------------------------------------

    ubyte clampByte(int v) {
        if (v < 0) return 0;
        if (v > 255) return 255;
        return cast(ubyte) v;
    }

    // Fairway: two flat mower passes per tile (~2.8 m each). Light lime, dark forest.
    // Blade flecks run along the stripe, not across it.
    auto fairwayTex = makeProceduralTexture(app, 256, 256, (ubyte[] buf, uint w, uint h) {
        FastRng rng; rng.state = 0x4a1829e1u;
        foreach (y; 0 .. h) {
            immutable t = cast(float) y / cast(float) h * 2.0f;
            immutable cell = cast(int) t;
            immutable f = t - cast(float) cell;
            enum edge = 0.08f;
            float edgeBlend = 1.0f;
            if (f < edge) edgeBlend = f / edge;
            else if (f > 1.0f - edge) edgeBlend = (1.0f - f) / edge;
            immutable stripe = ((cell % 2) == 0) ? edgeBlend : (1.0f - edgeBlend);
            immutable blade = (y % 3 == 1) ? -6 : ((y % 5 == 0) ? 3 : 0);
            foreach (x; 0 .. w) {
                immutable grain = cast(int)(rng.next01() * 5.0f - 2.0f);
                immutable shade = blade + grain;
                immutable int r = cast(int)(26.0f + stripe * 32.0f) + shade / 4;
                immutable int g = cast(int)(84.0f + stripe * 70.0f) + shade;
                immutable int b = cast(int)(20.0f + stripe * 24.0f) + shade / 5;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = clampByte(r);
                buf[idx + 1] = clampByte(g);
                buf[idx + 2] = clampByte(b);
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) fairwayTex.destroy();

    // Green: same colors, one pass tighter, so the hole still reads as short grass.
    auto greenTex = makeProceduralTexture(app, 256, 256, (ubyte[] buf, uint w, uint h) {
        FastRng rng; rng.state = 0x6e91f032u;
        foreach (y; 0 .. h) {
            immutable t = cast(float) y / cast(float) h * 4.0f;
            immutable cell = cast(int) t;
            immutable f = t - cast(float) cell;
            enum edge = 0.10f;
            float edgeBlend = 1.0f;
            if (f < edge) edgeBlend = f / edge;
            else if (f > 1.0f - edge) edgeBlend = (1.0f - f) / edge;
            immutable stripe = ((cell % 2) == 0) ? edgeBlend : (1.0f - edgeBlend);
            immutable blade = (y % 2 == 0) ? -4 : 2;
            foreach (x; 0 .. w) {
                immutable grain = cast(int)(rng.next01() * 4.0f - 2.0f);
                immutable shade = blade + grain;
                immutable int r = cast(int)(30.0f + stripe * 28.0f) + shade / 4;
                immutable int g = cast(int)(108.0f + stripe * 58.0f) + shade;
                immutable int b = cast(int)(28.0f + stripe * 18.0f) + shade / 5;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = clampByte(r);
                buf[idx + 1] = clampByte(g);
                buf[idx + 2] = clampByte(b);
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) greenTex.destroy();

    // Tall grass: brown thatch between long vertical blades, in large clumps.
    auto roughTex = makeProceduralTexture(app, 256, 256, (ubyte[] buf, uint w, uint h) {
        FastRng rng; rng.state = 0x128ab837u;
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                immutable col = x / 3;
                immutable bladeOn = ((col * 17 + 5) % 7) >= 2;
                immutable phase = (col * 29) % 56;
                immutable along = (y + phase) % 56;
                immutable inBlade = bladeOn && along < 38;
                immutable clump = sin(cast(float) x * 0.045f) * cos(cast(float) y * 0.038f);
                immutable grain = cast(int)(rng.next01() * 10.0f - 5.0f);
                immutable idx = (y * w + x) * 4;
                if (inBlade && clump > -0.35f) {
                    immutable tip = along < 8 ? 22 : 0;
                    buf[idx + 0] = clampByte(22 + grain / 3 + (clump > 0.4f ? 18 : 0));
                    buf[idx + 1] = clampByte(96 + tip + grain + cast(int)(clump * 28.0f));
                    buf[idx + 2] = clampByte(18 + grain / 4);
                } else {
                    buf[idx + 0] = clampByte(92 + grain + cast(int)(clump * 12.0f));
                    buf[idx + 1] = clampByte(68 + grain / 2);
                    buf[idx + 2] = clampByte(32 + grain / 3);
                }
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) roughTex.destroy();

    auto sandTex = makeProceduralTexture(app, 256, 256, (ubyte[] buf, uint w, uint h) {
        FastRng rng; rng.state = 0x59c3a104u;
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                immutable fx = cast(float) x;
                immutable fy = cast(float) y;
                immutable ripple = sin(fy * 0.055f + fx * 0.02f) * 26.0f
                    + sin(fy * 0.14f) * 8.0f;
                immutable patch = sin(fx * 0.03f) * cos(fy * 0.025f) * 14.0f;
                immutable grain = rng.next01() * 18.0f - 9.0f;
                immutable pebble = rng.next01() < 0.035f ? -36.0f : 0.0f;
                immutable shade = ripple + patch + grain + pebble;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = clampByte(cast(int)(138 + shade));
                buf[idx + 1] = clampByte(cast(int)(104 + shade * 0.75f));
                buf[idx + 2] = clampByte(cast(int)(58 + shade * 0.35f));
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) sandTex.destroy();

    auto needleTex = makeProceduralTexture(app, 128, 128, (ubyte[] buf, uint w, uint h) {
        FastRng rng; rng.state = 0x91c0aa21u;
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                immutable layer = ((y / 8) % 2) == 0 ? 8 : -12;
                immutable grain = cast(int)(rng.next01() * 16.0f - 8.0f);
                immutable shade = layer + grain;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = clampByte(12 + shade / 5);
                buf[idx + 1] = clampByte(58 + shade);
                buf[idx + 2] = clampByte(18 + shade / 6);
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) needleTex.destroy();

    auto leafTex = makeProceduralTexture(app, 128, 128, (ubyte[] buf, uint w, uint h) {
        FastRng rng; rng.state = 0x33e19b07u;
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                immutable blob = cast(int)(sin(cast(float) x * 0.18f) * cos(cast(float) y * 0.15f) * 20.0f);
                immutable grain = cast(int)(rng.next01() * 12.0f - 6.0f);
                immutable shade = blob + grain;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = clampByte(20 + shade / 4);
                buf[idx + 1] = clampByte(78 + shade);
                buf[idx + 2] = clampByte(16 + shade / 7);
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) leafTex.destroy();

    // 5. Water Surface Texture (Deep turquoise with specular wave highlights)
    auto waterTex = makeProceduralTexture(app, 128, 128, (ubyte[] buf, uint w, uint h) {
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                immutable fx = cast(float) x / 16.0f;
                immutable fy = cast(float) y / 16.0f;
                immutable wave = sin(fx) * cos(fy) * 20.0f;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = cast(ubyte)(24 + cast(int) wave);
                buf[idx + 1] = cast(ubyte)(128 + cast(int) wave);
                buf[idx + 2] = cast(ubyte)(208 + cast(int) wave);
                buf[idx + 3] = 240;
            }
        }
    });
    scope(exit) waterTex.destroy();

    auto rockTex = makeProceduralTexture(app, 128, 128, (ubyte[] buf, uint w, uint h) {
        FastRng rng; rng.state = 0x738b109au;
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                immutable crack = (x % 17 == 0 || y % 23 == 0) ? -28 : 0;
                immutable vein = cast(int)(sin(cast(float) x * 0.11f + cast(float) y * 0.04f) * 12.0f);
                immutable noise = cast(int)(rng.next01() * 18.0f - 9.0f);
                immutable shade = crack + vein + noise;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = clampByte(92 + shade);
                buf[idx + 1] = clampByte(96 + shade);
                buf[idx + 2] = clampByte(100 + shade);
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) rockTex.destroy();

    auto woodTex = makeProceduralTexture(app, 128, 128, (ubyte[] buf, uint w, uint h) {
        FastRng rng; rng.state = 0x2719a584u;
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                immutable furrow = cast(int)(sin(cast(float) x * 0.55f) * 18.0f);
                immutable knot = (x > 50 && x < 78 && y > 40 && y < 70) ? -22 : 0;
                immutable noise = cast(int)(rng.next01() * 10.0f);
                immutable shade = furrow + knot + noise;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = clampByte(72 + shade);
                buf[idx + 1] = clampByte(42 + shade / 2);
                buf[idx + 2] = clampByte(18 + shade / 4);
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) woodTex.destroy();

    // 8. Glossy Dimpled Golf Ball Texture
    auto ballTex = makeProceduralTexture(app, 64, 64, (ubyte[] buf, uint w, uint h) {
        foreach (y; 0 .. h) {
            foreach (x; 0 .. w) {
                immutable dx = ((x % 8) - 4);
                immutable dy = ((y % 8) - 4);
                immutable d2 = dx * dx + dy * dy;
                immutable dimple = d2 <= 9 ? 232 : 255;
                immutable idx = (y * w + x) * 4;
                buf[idx + 0] = cast(ubyte) dimple;
                buf[idx + 1] = cast(ubyte) dimple;
                buf[idx + 2] = cast(ubyte)(dimple + (dimple < 255 ? 4 : 0));
                buf[idx + 3] = 255;
            }
        }
    });
    scope(exit) ballTex.destroy();

    // 9. Metallic Brass / Pole Texture
    auto metalTex = Texture.solid(app.gpu, 240, 240, 245, 255);
    scope(exit) metalTex.destroy();

    // -----------------------------------------------------------------------
    // PBR Materials Setup
    // -----------------------------------------------------------------------

    MaterialParams matP;

    // Fairway Material
    matP.baseColorFactor = [1.0f, 1.0f, 1.0f, 1.0f];
    matP.roughness = 0.94f; matP.metallic = 0.0f;
    auto fairwayMat = Material.create(app.gpu, layout, sampler, fairwayTex, matP, null, null, null, null);
    scope(exit) fairwayMat.destroy();

    matP.roughness = 0.86f; matP.metallic = 0.0f;
    auto greenMat = Material.create(app.gpu, layout, sampler, greenTex, matP, null, null, null, null);
    scope(exit) greenMat.destroy();

    matP.roughness = 1.0f; matP.metallic = 0.0f;
    auto roughMat = Material.create(app.gpu, layout, sampler, roughTex, matP, null, null, null, null);
    scope(exit) roughMat.destroy();

    matP.baseColorFactor = [0.92f, 0.78f, 0.55f, 1.0f];
    matP.roughness = 1.0f; matP.metallic = 0.0f;
    auto sandMat = Material.create(app.gpu, layout, sampler, sandTex, matP, null, null, null, null);
    scope(exit) sandMat.destroy();

    // Water Material (Glossy specular mirror)
    matP.baseColorFactor = [1.0f, 1.0f, 1.0f, 1.0f];
    matP.roughness = 0.04f; matP.metallic = 0.06f;
    auto waterMat = Material.create(app.gpu, layout, sampler, waterTex, matP, null, null, null, null);
    scope(exit) waterMat.destroy();

    // Rock Material
    matP.roughness = 0.88f; matP.metallic = 0.0f;
    auto rockMat = Material.create(app.gpu, layout, sampler, rockTex, matP, null, null, null, null);
    scope(exit) rockMat.destroy();

    matP.baseColorFactor = [1.0f, 1.0f, 1.0f, 1.0f];
    matP.roughness = 0.82f; matP.metallic = 0.0f;
    auto woodMat = Material.create(app.gpu, layout, sampler, woodTex, matP, null, null, null, null);
    scope(exit) woodMat.destroy();

    matP.roughness = 0.92f; matP.metallic = 0.0f;
    auto needleMat = Material.create(app.gpu, layout, sampler, needleTex, matP, null, null, null, null);
    scope(exit) needleMat.destroy();

    matP.roughness = 0.88f; matP.metallic = 0.0f;
    auto leafMat = Material.create(app.gpu, layout, sampler, leafTex, matP, null, null, null, null);
    scope(exit) leafMat.destroy();

    // Golf Ball Material (High-specular gloss white with subtle metallic sheen)
    matP.roughness = 0.15f; matP.metallic = 0.12f;
    auto ballMat = Material.create(app.gpu, layout, sampler, ballTex, matP, null, null, null, null);
    scope(exit) ballMat.destroy();

    // Metallic Flagpole Material
    matP.roughness = 0.22f; matP.metallic = 0.85f;
    auto metalMat = Material.create(app.gpu, layout, sampler, metalTex, matP, null, null, null, null);
    scope(exit) metalMat.destroy();

    // Red Tee Marker Material
    auto redTex = Texture.solid(app.gpu, 225, 45, 45, 255);
    scope(exit) redTex.destroy();
    matP.roughness = 0.35f; matP.metallic = 0.1f;
    auto redMat = Material.create(app.gpu, layout, sampler, redTex, matP, null, null, null, null);
    scope(exit) redMat.destroy();

    // -----------------------------------------------------------------------
    // Procedural 3D Meshes Creation
    // -----------------------------------------------------------------------

    auto terrainMesh = buildTerrainMesh(app, false);
    scope(exit) terrainMesh.destroy();
    auto roughMesh = buildTerrainMesh(app, true);
    scope(exit) roughMesh.destroy();
    auto greenMesh = buildGreenOverlayMesh(app);
    scope(exit) greenMesh.destroy();
    auto potBunkerMesh = buildBunkerMesh(app, -8.5f, 66.0f, 3.6f, 6.0f);
    scope(exit) potBunkerMesh.destroy();
    auto greenBunkerMesh = buildBunkerMesh(app, 8.4f, 130.5f, 3.8f, 6.6f);
    scope(exit) greenBunkerMesh.destroy();
    auto teePadMesh = buildTeePadMesh(app);
    scope(exit) teePadMesh.destroy();
    auto teeCurbMesh = buildTeeCurbMesh(app);
    scope(exit) teeCurbMesh.destroy();
    auto waterMesh = buildWaterMesh(app);
    scope(exit) waterMesh.destroy();
    auto pineMesh = buildPineTreeMesh(app);
    scope(exit) pineMesh.destroy();
    auto decidMesh = buildDecidTreeMesh(app);
    scope(exit) decidMesh.destroy();
    auto boulderMesh = buildBoulderMesh(app);
    scope(exit) boulderMesh.destroy();
    auto pinMesh = buildPinMesh(app);
    scope(exit) pinMesh.destroy();
    auto ballMesh = TexMesh.sphere(app.gpu, 32, 16);
    scope(exit) ballMesh.destroy();
    auto stakeMesh = TexMesh.cube(app.gpu);
    scope(exit) stakeMesh.destroy();

    auto text = TextRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) text.destroy();
    auto ui = UiRenderer.create(app.gpu, SCREEN_W, SCREEN_H);
    scope(exit) ui.destroy();
    auto fps = FpsCounter.create();
    auto gizmos = GizmoRenderer.create(app.gpu);
    scope(exit) gizmos.destroy();

    auto audio = AudioEngine.create();
    scope(exit) audio.destroy();
    auto sfx = GolfAudio.create();
    scope(exit) sfx.destroy();

    // -----------------------------------------------------------------------
    // Physics World & Level Entities
    // -----------------------------------------------------------------------

    auto physics = PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f), true, true, 1);

    // Solid physical collision foundation in Box3D under the course
    createStaticBox(physics, Vec3(3.0f, -0.6f, 70.0f), Vec3(38.0f, 0.6f, 92.0f), noPhysicsEntity, 0.7f, 0.1f);
    createStaticBox(physics, Vec3(0.0f, -0.1f, 0.0f), Vec3(5.0f, 0.4f, 6.0f), noPhysicsEntity, 0.8f, 0.1f);
    createStaticBox(physics, Vec3(1.6f, 0.0f, 133.5f), Vec3(9.0f, 0.4f, 11.0f), noPhysicsEntity, 0.6f, 0.2f);

    immutable spawnPoint = Vec3(TEE_X, courseElevation(TEE_X, TEE_Z) + BALL_R + 0.005f, TEE_Z);
    immutable b3BodyId ball = createDynamicSphere(
        physics, spawnPoint, BALL_R, BALL_DENSITY, BALL_ENTITY, 0.88f, 0.12f);
    setLinearDamping(ball, 0.0f);
    setAngularDamping(ball, 0.035f);

    // Populate Course Trees & Boulders
    PropInstance[] pineTrees;
    PropInstance[] shadeTrees;
    PropInstance[] boulders;

    void spawnPine(float x, float z, float s = 1.0f) {
        immutable y = courseElevation(x, z);
        pineTrees ~= PropInstance(Vec3(x, y, z), Vec3(s, s, s), 0.0f, true);
        createStaticBox(physics, Vec3(x, y + 1.2f * s, z), Vec3(0.35f * s, 1.2f * s, 0.35f * s), Quat.init, noPhysicsEntity, 0.7f, 0.2f);
    }

    void spawnDecid(float x, float z, float s = 1.0f) {
        immutable y = courseElevation(x, z);
        shadeTrees ~= PropInstance(Vec3(x, y, z), Vec3(s, s, s), 0.0f, true);
        createStaticSphere(physics, Vec3(x, y + 3.2f * s, z), 1.6f * s, noPhysicsEntity, 0.65f, 0.15f);
    }

    void spawnBoulder(float x, float z, Vec3 s, float rot) {
        immutable y = courseElevation(x, z);
        boulders ~= PropInstance(Vec3(x, y, z), s, rot, false);
        createStaticSphere(physics, Vec3(x, y + s.y * 0.5f, z), s.x * 0.85f, noPhysicsEntity, 0.85f, 0.2f);
    }

    // Coastal Pine Forest framing left flank
    spawnPine(-17.0f,  12.0f, 1.35f);
    spawnPine(-19.5f,  28.0f, 1.45f);
    spawnDecid(-16.0f, 44.0f, 1.20f);
    spawnPine(-18.5f,  62.0f, 1.30f);
    spawnDecid(-17.0f, 82.0f, 1.25f);
    spawnPine(-19.0f, 104.0f, 1.40f);
    spawnPine(-16.5f, 126.0f, 1.30f);
    spawnPine(-13.0f, 142.0f, 1.35f);
    spawnPine( -6.0f, 150.0f, 1.40f);
    spawnDecid( 2.0f, 152.0f, 1.30f);
    spawnPine( 10.0f, 149.0f, 1.35f);

    // Right flank foliage past the lagoon
    spawnDecid( 35.0f,  32.0f, 1.35f);
    spawnPine(  36.5f,  58.0f, 1.40f);
    spawnPine(  37.0f,  84.0f, 1.35f);
    spawnDecid( 23.0f, 124.0f, 1.15f);

    // Coastal Rocks along the water's edge
    spawnBoulder(13.8f, 26.0f, Vec3(1.4f, 0.9f, 1.6f), 0.4f);
    spawnBoulder(13.6f, 48.0f, Vec3(1.7f, 1.1f, 1.5f), 1.1f);
    spawnBoulder(13.7f, 72.0f, Vec3(1.5f, 0.85f, 1.8f), 0.8f);
    spawnBoulder(13.9f, 94.0f, Vec3(1.6f, 1.0f, 1.4f), 1.9f);

    auto camera = Camera.create(0.85f, SCREEN_W, SCREEN_H, 0.05f, 450.0f);
    WindField wind;
    WindStreakSystem streakSystem;
    streakSystem.init(spawnPoint);

    // Gameplay state
    GameState state = GameState.aim;
    int clubIdx = 1; // 5-Iron default
    float aimYaw = 0.012f;
    float customLoft = CLUBS[clubIdx].defaultLoft;
    int strokes = 0;
    bool charging = false;
    float powerPhase = 0.0f;
    float power = 0.0f;
    float flightAge = 0.0f;
    float restTimer = 0.0f;
    float accumulator = 0.0f;
    Vec3 lastSafePos = spawnPoint;
    bool celebrationPlayed = false;
    float windSoundTimer = 3.5f;

    // Camera controller
    float camYaw = 0.0f;
    float camPitch = 0.32f;
    float zoom = 1.0f;
    int camMode = 0; // 0 orbit, 1 green, 2 aerial follow, 3 full-hole aerial

    info("Emerald Dunes 3D Championship Golf Initialized");

    // Directional Sun Light Vector
    immutable Vec3 sunDir = Vec3(0.48f, 0.88f, 0.36f).normalized();
    immutable Vec3 sceneCenter = Vec3(0.0f, 0.0f, 68.0f);
    immutable float sceneRadius = 88.0f;

    while (app.running()) {
        app.pollEvents();
        immutable rawDt = fps.tick();
        immutable float dt = rawDt > 0.1f ? 0.1f : rawDt;
        wind.time += dt;

        if (app.input.keyPressed(Key.escape))
            break;

        // Restart Hole
        if (app.input.keyPressed(Key.r)) {
            placeBall(ball, spawnPoint);
            lastSafePos = spawnPoint;
            strokes = 0;
            state = GameState.aim;
            charging = false;
            powerPhase = 0.0f;
            power = 0.0f;
            flightAge = 0.0f;
            restTimer = 0.0f;
            aimYaw = 0.012f;
            clubIdx = 1;
            customLoft = CLUBS[clubIdx].defaultLoft;
            celebrationPlayed = false;
        }

        // Camera mode toggle
        if (app.input.keyPressed(Key.c)) {
            camMode = (camMode + 1) % 4;
        }

        // Camera controls
        if (app.input.mouseDown(MouseButton.left) && !charging || app.input.mouseDown(MouseButton.right)) {
            camYaw   += app.input.mdx() * 0.004f;
            camPitch -= app.input.mdy() * 0.003f;
        }
        if (app.input.keyDown(Key.q)) zoom -= 0.85f * dt;
        if (app.input.keyDown(Key.e)) zoom += 0.85f * dt;
        zoom -= app.input.wheelY() * 0.08f;
        if (camPitch < 0.08f) camPitch = 0.08f;
        if (camPitch > 1.35f) camPitch = 1.35f;
        if (zoom < 0.35f) zoom = 0.35f;
        if (zoom > 4.5f) zoom = 4.5f;

        immutable Vec3 ballNow = getPosition(ball);
        immutable Lie currentLie = lieAt(ballNow);
        immutable bool onGreen = currentLie == Lie.green && state == GameState.aim;

        // Automatic putter selection on green
        if (onGreen && clubIdx != 4) {
            clubIdx = 4;
            customLoft = CLUBS[clubIdx].defaultLoft;
        }

        // Player Aiming & Swing Controls
        if (state == GameState.aim) {
            // Club switching (1 .. 5)
            if (app.input.keyPressed(Key.digit1)) { clubIdx = 0; customLoft = CLUBS[clubIdx].defaultLoft; }
            if (app.input.keyPressed(Key.digit2)) { clubIdx = 1; customLoft = CLUBS[clubIdx].defaultLoft; }
            if (app.input.keyPressed(Key.digit3)) { clubIdx = 2; customLoft = CLUBS[clubIdx].defaultLoft; }
            if (app.input.keyPressed(Key.digit4)) { clubIdx = 3; customLoft = CLUBS[clubIdx].defaultLoft; }
            if (app.input.keyPressed(Key.digit5)) { clubIdx = 4; customLoft = CLUBS[clubIdx].defaultLoft; }

            // Aiming heading
            if (app.input.keyDown(Key.a) || app.input.keyDown(Key.left))
                aimYaw -= 1.15f * dt;
            if (app.input.keyDown(Key.d) || app.input.keyDown(Key.right))
                aimYaw += 1.15f * dt;

            // Loft tuning
            if (clubIdx != 4) {
                if (app.input.keyDown(Key.w) || app.input.keyDown(Key.up))
                    customLoft += 20.0f * dt;
                if (app.input.keyDown(Key.s) || app.input.keyDown(Key.down))
                    customLoft -= 20.0f * dt;
                if (customLoft < 8.0f) customLoft = 8.0f;
                if (customLoft > 62.0f) customLoft = 62.0f;
            }

            // Power Charging: Human-scale 1.8s backswing
            immutable bool wantSwing = app.input.keyDown(Key.space) || app.input.mouseDown(MouseButton.left);
            if (wantSwing) {
                if (!charging)
                    powerPhase = 0.0f;
                charging = true;
                powerPhase += (cast(float) PI / 1.80f) * dt;
                power = fabs(sin(powerPhase));
            } else if (charging) {
                // Strike Ball!
                immutable float currentDistToCup = sqrt((ballNow.x - CUP_X) * (ballNow.x - CUP_X) +
                                                        (ballNow.z - CUP_Z) * (ballNow.z - CUP_Z));
                immutable launch = planShot(CLUBS[clubIdx], aimYaw, customLoft, power, currentLie, currentDistToCup);
                setLinearVelocity(ball, launch.velocity);
                setAngularVelocity(ball, launch.spin);
                strokes += 1;
                state = GameState.flight;
                flightAge = 0.0f;
                restTimer = 0.0f;
                charging = false;

                // Play strike acoustics
                final switch (CLUBS[clubIdx].kind) {
                    case ClubKind.driver: audio.play(sfx.driverCrack);  break;
                    case ClubKind.iron5:
                    case ClubKind.iron9:  audio.play(sfx.ironThwack);   break;
                    case ClubKind.wedge:  audio.play(sfx.wedgeThump);   break;
                    case ClubKind.putter: audio.play(sfx.putterClick);  break;
                }
            }
        }

        // Fixed Physics Simulation Loop
        accumulator += dt;
        if (accumulator > PHYS_STEP * MAX_SUBSTEPS)
            accumulator = PHYS_STEP * MAX_SUBSTEPS;
        uint subSteps = 0;

        while (accumulator >= PHYS_STEP && subSteps < MAX_SUBSTEPS) {
            immutable p = getPosition(ball);
            if (state == GameState.flight) {
                immutable gY = courseElevation(p.x, p.z) + BALL_R;
                if (p.y > gY + 0.035f) {
                    immutable v = getLinearVelocity(ball);
                    immutable w = getAngularVelocity(ball);
                    applyForceToCenter(ball, aeroForce(v, w, liveWind(wind, p)), true);
                }
            }

            if (state == GameState.aim) {
                applyGroundPhysics(ball, PHYS_STEP, state);
            } else {
                physics.step(PHYS_STEP, SOLVER_SUBSTEPS);
                applyGroundPhysics(ball, PHYS_STEP, state);

                // Substep cup capture test to prevent speed tunneling past the hole
                immutable curPos = getPosition(ball);
                immutable curVel = getLinearVelocity(ball);
                if (state == GameState.flight && checkCupCapture(curPos, curVel)) {
                    placeBall(ball, Vec3(CUP_X, courseElevation(CUP_X, CUP_Z) + BALL_R, CUP_Z));
                    state = GameState.holed;
                    if (!celebrationPlayed) {
                        audio.play(sfx.cupRattle);
                        audio.play(sfx.victoryFanfare);
                        celebrationPlayed = true;
                    }
                }
            }
            accumulator -= PHYS_STEP;
            ++subSteps;
        }

        immutable Vec3 physPos = getPosition(ball);
        immutable Vec3 physVel = getLinearVelocity(ball);

        if (state == GameState.holed) {
            placeBall(ball, Vec3(CUP_X, courseElevation(CUP_X, CUP_Z) + BALL_R, CUP_Z));
        }

        // Flight & Settlement Logic
        if (state == GameState.flight) {
            flightAge += dt;

            if (outOfBounds(physPos)) {
                if (inWaterHazard(physPos.x, physPos.z))
                    audio.play(sfx.waterSplash);
                placeBall(ball, lastSafePos);
                strokes += 1;
                state = GameState.aim;
                restTimer = 0.0f;
                flightAge = 0.0f;
            } else if (checkCupCapture(physPos, physVel)) {
                placeBall(ball, Vec3(CUP_X, courseElevation(CUP_X, CUP_Z) + BALL_R, CUP_Z));
                state = GameState.holed;
                if (!celebrationPlayed) {
                    audio.play(sfx.cupRattle);
                    audio.play(sfx.victoryFanfare);
                    celebrationPlayed = true;
                }
            } else if (flightAge > 0.25f &&
                       Vec3(physVel.x, 0.0f, physVel.z).length() < 0.22f && fabs(physVel.y) < 0.35f) {
                restTimer += dt;
                if (restTimer > 0.25f) {
                    setLinearVelocity(ball, Vec3(0.0f, 0.0f, 0.0f));
                    setAngularVelocity(ball, Vec3(0.0f, 0.0f, 0.0f));
                    lastSafePos = getPosition(ball);
                    state = GameState.aim;
                    restTimer = 0.0f;

                    if (lieAt(lastSafePos) == Lie.bunker)
                        audio.play(sfx.sandThud);
                }
            } else {
                restTimer = 0.0f;
            }
        }

        // Update wind streamlines
        immutable Vec3 ballFocus = getPosition(ball);
        streakSystem.update(dt, wind, ballFocus);

        // Ambient wind rush sound modulation
        immutable Vec3 curWindAtPin = liveWind(wind, Vec3(CUP_X, 3.0f, CUP_Z));
        immutable float curGustSpeed = curWindAtPin.length();
        windSoundTimer -= dt;
        if (windSoundTimer <= 0.0f && curGustSpeed > wind.baseSpeed + 1.4f) {
            audio.play(sfx.windGust);
            windSoundTimer = 4.2f;
        }

        // Dynamic Camera Setup
        if (camMode == 1) {
            immutable Vec3 greenCenter = Vec3(CUP_X, courseElevation(CUP_X, CUP_Z), CUP_Z);
            camera.lookAt(greenCenter + Vec3(0.0f, 18.0f, -6.0f) * zoom, greenCenter);
        } else if (camMode == 2) {
            // Bird's-eye follow: high above the ball, slight tilt so the hole stays ahead
            immutable float height = 36.0f * zoom;
            camera.lookAt(
                Vec3(ballFocus.x, ballFocus.y + height, ballFocus.z - 7.0f * zoom),
                Vec3(ballFocus.x, ballFocus.y, ballFocus.z + 4.0f));
        } else if (camMode == 3) {
            // Fixed aerial of the whole hole
            camera.lookAt(
                Vec3(6.0f, 72.0f * zoom, 48.0f),
                Vec3(2.0f, 0.0f, 72.0f));
        } else {
            // Player Orbit / Cinematic Chase Camera
            immutable float baseDist = (state == GameState.flight) ? 6.2f : (onGreen ? 1.8f : 3.2f);
            immutable float camDist = baseDist * zoom;
            immutable float orbitHeading = aimYaw + camYaw;
            immutable float cp = cos(camPitch);
            immutable float sp = sin(camPitch);
            immutable Vec3 backDir = aimForward(orbitHeading);
            immutable Vec3 eye = Vec3(
                ballFocus.x - backDir.x * cp * camDist,
                ballFocus.y + sp * camDist + 0.15f,
                ballFocus.z - backDir.z * cp * camDist,
            );
            camera.lookAt(eye, Vec3(ballFocus.x, ballFocus.y + 0.06f, ballFocus.z));
        }

        // -------------------------------------------------------------------
        // Directional Shadow Pass
        // -------------------------------------------------------------------

        immutable lightVP = directionalLightVP(sunDir, sceneCenter, sceneRadius);

        immutable ballScale = Vec3(BALL_R * 2.0f, BALL_R * 2.0f, BALL_R * 2.0f);
        immutable ballTransform = readBodyTransform(ball);
        auto ballModel = Mat4.translation(ballTransform.position.x, ballTransform.position.y, ballTransform.position.z)
                       * ballTransform.rotation.toMat4()
                       * Mat4.scaling(ballScale.x, ballScale.y, ballScale.z);

        // 1. Pine Trees Shadow Pass
        InstanceData[] pineCasters;
        foreach (ref p; pineTrees) {
            auto model = Mat4.translation(p.pos.x, p.pos.y, p.pos.z) * Mat4.scaling(p.scale.x, p.scale.y, p.scale.z);
            pineCasters ~= InstanceData(model.m, Color4.white.toArray());
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, pineCasters);
        submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                         pineMesh, shadowInstanceBuf, cast(uint) pineTrees.length, /*clear=*/true);

        // 2. Deciduous Trees Shadow Pass
        InstanceData[] shadeCasters;
        foreach (ref p; shadeTrees) {
            auto model = Mat4.translation(p.pos.x, p.pos.y, p.pos.z) * Mat4.scaling(p.scale.x, p.scale.y, p.scale.z);
            shadeCasters ~= InstanceData(model.m, Color4.white.toArray());
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, shadeCasters);
        submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                         decidMesh, shadowInstanceBuf, cast(uint) shadeTrees.length, /*clear=*/false);

        // 3. Coastal Boulders Shadow Pass
        InstanceData[] rockCasters;
        foreach (ref b; boulders) {
            auto model = Mat4.translation(b.pos.x, b.pos.y, b.pos.z)
                       * Mat4.rotationY(b.rotY)
                       * Mat4.scaling(b.scale.x, b.scale.y, b.scale.z);
            rockCasters ~= InstanceData(model.m, Color4.white.toArray());
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, rockCasters);
        submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                         boulderMesh, shadowInstanceBuf, cast(uint) boulders.length, /*clear=*/false);

        // 4. Golf Ball Shadow Pass
        InstanceData[1] ballCaster;
        ballCaster[0] = InstanceData(ballModel.m, Color4.white.toArray());
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, ballCaster[]);
        submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                         ballMesh, shadowInstanceBuf, 1, /*clear=*/false);

        // -------------------------------------------------------------------
        // Main 3D PBR Scene Pass
        // -------------------------------------------------------------------

        LightSet lights;
        lights.dirEnabled = true;
        lights.dir.direction = sunDir;
        lights.dir.viewProj = lightVP;
        lights.dir.color = Vec3(1.0f, 0.95f, 0.84f); // Warm natural afternoon sunlight
        lights.dir.intensity = 1.6f;
        lights.dir.castShadows = true;
        lights.shadowBias = 0.0004f;

        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointMaps;
        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotMaps;
        scene.setLights(lights, &dirShadow, pointMaps, spotMaps);

        auto frame = app.beginFrame(Color4(0.42f, 0.68f, 0.92f, 1.0f)); // Clear sky
        if (!frame.valid) continue;

        scene.begin(camera);

        // 1. Cut fairway, then the taller rough around it
        scene.draw(terrainMesh, fairwayMat, Vec3(0, 0, 0), Vec3(1, 1, 1));
        scene.draw(roughMesh, roughMat, Vec3(0, 0, 0), Vec3(1, 1, 1));

        // 2. Sculpted Putting Green (Velvety Emerald Finish)
        scene.draw(greenMesh, greenMat, Vec3(0, 0, 0), Vec3(1, 1, 1));

        // 3. Golden Sand Bunkers
        scene.draw(potBunkerMesh, sandMat, Vec3(0, 0, 0), Vec3(1, 1, 1));
        scene.draw(greenBunkerMesh, sandMat, Vec3(0, 0, 0), Vec3(1, 1, 1));

        // 4. Tee Box Pad & Timber Curb
        scene.draw(teePadMesh, greenMat, Vec3(0, 0, 0), Vec3(1, 1, 1));
        scene.draw(teeCurbMesh, woodMat, Vec3(0, 0, 0), Vec3(1, 1, 1));

        // Tee stakes — posts with colored caps, not extra balls
        void drawStake(Vec3 xz, ref Material cap) {
            immutable groundY = courseElevation(xz.x, xz.z);
            scene.draw(stakeMesh, woodMat,
                Vec3(xz.x, groundY + 0.22f, xz.z),
                Vec3(0.045f, 0.44f, 0.045f));
            scene.draw(stakeMesh, cap,
                Vec3(xz.x, groundY + 0.47f, xz.z),
                Vec3(0.09f, 0.07f, 0.09f));
        }
        drawStake(Vec3(-2.15f, 0.0f, -0.9f), redMat);
        drawStake(Vec3( 2.15f, 0.0f, -0.9f), metalMat);

        // Granite Tee Yardage Monument
        immutable plaquePos = Vec3(-2.2f, courseElevation(-2.2f, -1.8f) + 0.30f, -1.8f);
        scene.draw(boulderMesh, rockMat, plaquePos, Vec3(0.55f, 0.65f, 0.40f));

        // 5. Coastal Lagoon Water Plane
        scene.draw(waterMesh, waterMat, Vec3(0, 0, 0), Vec3(1, 1, 1));

        // 3. 3D Trees with Dynamic Wind Sway
        foreach (ref p; pineTrees) {
            immutable w = liveWind(wind, p.pos);
            immutable swayPhase = wind.time * 2.2f + p.pos.x * 0.25f + p.pos.z * 0.15f;
            immutable swayAmt = 0.045f + w.length() * 0.015f;
            auto model = Mat4.translation(
                p.pos.x + w.x * 0.04f + sin(swayPhase) * swayAmt,
                p.pos.y,
                p.pos.z + w.z * 0.04f + cos(swayPhase) * swayAmt
            ) * Mat4.scaling(p.scale.x, p.scale.y, p.scale.z);
            scene.drawMatrix(pineMesh, needleMat, model, Color4.white);
        }

        foreach (ref p; shadeTrees) {
            immutable w = liveWind(wind, p.pos);
            immutable swayPhase = wind.time * 1.8f + p.pos.x * 0.20f + p.pos.z * 0.18f;
            immutable swayAmt = 0.055f + w.length() * 0.018f;
            auto model = Mat4.translation(
                p.pos.x + w.x * 0.05f + sin(swayPhase) * swayAmt,
                p.pos.y,
                p.pos.z + w.z * 0.05f + cos(swayPhase) * swayAmt
            ) * Mat4.scaling(p.scale.x, p.scale.y, p.scale.z);
            scene.drawMatrix(decidMesh, leafMat, model, Color4.white);
        }

        // 4. Coastal Boulders
        foreach (ref b; boulders) {
            auto model = Mat4.translation(b.pos.x, b.pos.y, b.pos.z)
                       * Mat4.rotationY(b.rotY)
                       * Mat4.scaling(b.scale.x, b.scale.y, b.scale.z);
            scene.drawMatrix(boulderMesh, rockMat, model, Color4.white);
        }

        // 5. Tournament Pin & Hole
        immutable pinBase = Vec3(CUP_X, courseElevation(CUP_X, CUP_Z), CUP_Z);
        scene.draw(pinMesh, metalMat, pinBase, Vec3(1, 1, 1));

        // 6. Golf Ball (Glossy Dimpled PBR Sphere)
        scene.drawMatrix(ballMesh, ballMat, ballModel, Color4.white);

        // -------------------------------------------------------------------
        // 3D Visual Gizmos (Forecast Arc, Wind Streamlines, Flag Flutter)
        // -------------------------------------------------------------------

        gizmos.begin(camera.viewProjection());

        // Dynamic 3D Billowing Flag
        drawBillowingFlag(gizmos, wind, pinBase);

        // 3D Luminous Wind Streamlines
        streakSystem.draw(gizmos, wind);

        // Putting Slope Grid
        if (onGreen) {
            drawGreenPuttingContours(gizmos, ballFocus);
        }

        // 3D Hole Target Beacon
        gizmos.line(pinBase, pinBase + Vec3(0, 9.0f, 0), Color4(1.10f, 0.20f, 0.15f, 1.0f));
        enum int BEACON_N = 18;
        enum float BEACON_R = 1.35f;
        Vec3 prevRing = pinBase + Vec3(BEACON_R, 0.02f, 0.0f);
        foreach (i; 1 .. BEACON_N + 1) {
            immutable a = cast(float) i / BEACON_N * 2.0f * cast(float) PI;
            immutable nextRing = pinBase + Vec3(cos(a) * BEACON_R, 0.02f, sin(a) * BEACON_R);
            gizmos.line(prevRing, nextRing, Color4(1.15f, 0.90f, 0.20f, 1.0f));
            prevRing = nextRing;
        }

        // 3D Aim Forecast Arc
        if (state == GameState.aim) {
            immutable float currentDistToCup = sqrt((ballFocus.x - CUP_X) * (ballFocus.x - CUP_X) +
                                                    (ballFocus.z - CUP_Z) * (ballFocus.z - CUP_Z));
            immutable previewPower = charging ? power : (currentLie == Lie.green ? 0.50f : 1.0f);
            immutable preview = planShot(CLUBS[clubIdx], aimYaw, customLoft, previewPower, currentLie, currentDistToCup);
            drawTrajectoryForecast(gizmos, ballFocus, preview, wind);
        }

        scene.end(frame);
        gizmos.render(frame);

        // Resolve HDR pass -> Run Bloom, ACES Tone Map, FXAA
        app.resolvePost(frame);

        // -------------------------------------------------------------------
        // Brand New Modern Graphical Golf UI Layer (Hardware-Accelerated 2D)
        // -------------------------------------------------------------------

        ui.begin();

        // Neutral dark surfaces, one emerald accent, pill geometry.
        immutable Color4 uiSurface   = Color4(0.11f, 0.12f, 0.15f, 0.84f);
        immutable Color4 uiInset     = Color4(0.05f, 0.06f, 0.08f, 0.92f);
        immutable Color4 uiChip      = Color4(1.00f, 1.00f, 1.00f, 0.08f);
        immutable Color4 uiHairline  = Color4(1.00f, 1.00f, 1.00f, 0.10f);
        immutable Color4 uiAccent     = Color4(0.20f, 0.74f, 0.48f, 1.0f);
        immutable Color4 uiAccentSoft = Color4(0.20f, 0.74f, 0.48f, 0.22f);
        immutable Color4 uiGold       = Color4(0.98f, 0.80f, 0.32f, 1.0f);
        immutable Color4 uiDanger     = Color4(0.93f, 0.34f, 0.31f, 1.0f);
        immutable Color4 uiMuted      = Color4(0.55f, 0.58f, 0.64f, 0.90f);

        immutable float margin = 20.0f;
        immutable float headerX = margin;
        immutable float headerY = 16.0f;
        immutable float headerW = SCREEN_W - margin * 2.0f;
        immutable float headerH = 52.0f;

        immutable float infoX = margin;
        immutable float infoY = 80.0f;
        immutable float infoW = 280.0f;
        immutable float infoH = 132.0f;

        immutable float windCardW = 300.0f;
        immutable float windCardH = infoH;
        immutable float windCardX = SCREEN_W - margin - windCardW;
        immutable float windCardY = infoY;

        immutable float mapW = 168.0f;
        immutable float mapH = 228.0f;
        immutable float mapX = SCREEN_W - margin - mapW;
        immutable float mapY = windCardY + windCardH + 12.0f;

        immutable float dockW = 820.0f;
        immutable float dockH = 122.0f;
        immutable float dockX = (SCREEN_W - dockW) * 0.5f;
        immutable float dockY = SCREEN_H - dockH - 14.0f;

        immutable float segX = dockX + 16.0f;
        immutable float segY = dockY + 12.0f;
        immutable float segW = dockW - 32.0f;
        immutable float segH = 44.0f;
        immutable float segPad = 4.0f;
        immutable float segGap = 4.0f;
        immutable float segInnerW = (segW - segPad * 2.0f - segGap * 4.0f) / 5.0f;

        immutable float meterX = dockX + 16.0f;
        immutable float meterY = dockY + 80.0f;
        immutable float meterW = dockW - 32.0f;
        immutable float meterH = 12.0f;

        immutable Vec3 wMean = steadyWind(wind, ballFocus + Vec3(0.0f, 2.0f, 0.0f));
        immutable float meanSpd = Vec3(wMean.x, 0.0f, wMean.z).length();
        immutable float meanDeg = cast(float)(atan2(wMean.x, wMean.z) * 180.0 / PI);
        immutable Vec3 wGust = liveWind(wind, ballFocus + Vec3(0.0f, 2.0f, 0.0f));
        immutable float gustSpd = wGust.length();
        immutable float shownPower = charging ? power : 0.0f;
        immutable float targetPowerNorm = (currentLie == Lie.green || clubIdx == 4) ? 0.50f : 0.85f;
        immutable float notchX = meterX + meterW * targetPowerNorm;

        immutable float distM = cast(float) sqrt(cast(double)((ballFocus.x - CUP_X) * (ballFocus.x - CUP_X) +
                                                              (ballFocus.z - CUP_Z) * (ballFocus.z - CUP_Z)));
        immutable float elevM = courseElevation(CUP_X, CUP_Z) - ballFocus.y;

        if (state == GameState.holed) {
            ui.rect(0, 0, SCREEN_W, SCREEN_H, Color4(0.02f, 0.03f, 0.05f, 0.62f));
            immutable float modalW = 440.0f;
            immutable float modalH = 168.0f;
            immutable float modalX = (SCREEN_W - modalW) * 0.5f;
            immutable float modalY = (SCREEN_H - modalH) * 0.5f;
            ui.elevatedCard(modalX, modalY, modalW, modalH, 24.0f, Color4(0.12f, 0.13f, 0.16f, 0.96f));
            ui.pill(modalX + modalW * 0.5f - 22.0f, modalY + 14.0f, 44.0f, 4.0f, uiHairline);
            ui.pill(modalX + (modalW - 248.0f) * 0.5f, modalY + modalH - 52.0f, 248.0f, 32.0f, uiAccent);
        } else {
        ui.elevatedCard(headerX, headerY, headerW, headerH, 18.0f, uiSurface);
        ui.pill((SCREEN_W - 236.0f) * 0.5f, headerY + 12.0f, 236.0f, 28.0f, uiChip);
        ui.pill(headerX + headerW - 124.0f, headerY + 12.0f, 108.0f, 28.0f, uiAccentSoft);

        ui.elevatedCard(infoX, infoY, infoW, infoH, 18.0f, uiSurface);
        ui.rect(infoX + 18.0f, infoY + 46.0f, infoW - 36.0f, 1.0f, uiHairline);

        ui.elevatedCard(windCardX, windCardY, windCardW, windCardH, 18.0f, uiSurface);

        immutable float dialCX = windCardX + 58.0f;
        immutable float dialCY = windCardY + windCardH * 0.5f;
        immutable float dialR = 40.0f;
        ui.circleFill(dialCX, dialCY, dialR, uiInset);
        ui.circleRing(dialCX, dialCY, dialR, 1.5f, uiHairline);
        ui.circleFill(dialCX, dialCY - dialR + 3.0f, 2.2f, uiGold);
        ui.circleFill(dialCX, dialCY + dialR - 3.0f, 1.6f, uiMuted);
        ui.circleFill(dialCX - dialR + 3.0f, dialCY, 1.6f, uiMuted);
        ui.circleFill(dialCX + dialR - 3.0f, dialCY, 1.6f, uiMuted);

        immutable float needleAngleRad = (meanDeg - 90.0f) * (cast(float) PI / 180.0f);
        ui.needle(dialCX, dialCY, needleAngleRad, dialR - 8.0f, 4.0f, uiAccent);
        ui.circleFill(dialCX, dialCY, 4.0f, Color4.white);

        ui.elevatedCard(mapX, mapY, mapW, mapH, 18.0f, uiSurface);

        immutable float plotX = mapX + 14.0f;
        immutable float plotY = mapY + 36.0f;
        immutable float plotW = mapW - 28.0f;
        immutable float plotH = mapH - 52.0f;
        immutable float zMinMap = -10.0f;
        immutable float zMaxMap = 150.0f;
        immutable float xMinMap = -25.0f;
        immutable float xMaxMap =  35.0f;

        float mapToScreenX(float wx) {
            immutable normX = (wx - xMinMap) / (xMaxMap - xMinMap);
            return plotX + normX * plotW;
        }
        float mapToScreenY(float wz) {
            immutable normZ = (wz - zMinMap) / (zMaxMap - zMinMap);
            return plotY + plotH - normZ * plotH;
        }

        immutable float waterX0 = mapToScreenX(14.0f);
        immutable float waterX1 = mapToScreenX(34.0f);
        immutable float waterY0 = mapToScreenY(105.0f);
        immutable float waterY1 = mapToScreenY(22.0f);
        ui.roundedRect(waterX0, waterY0, waterX1 - waterX0, waterY1 - waterY0, 8.0f,
            Color4(0.18f, 0.48f, 0.78f, 0.70f));

        immutable float fairX0 = mapToScreenX(-8.0f);
        immutable float fairX1 = mapToScreenX(10.0f);
        immutable float fairY0 = mapToScreenY(122.0f);
        immutable float fairY1 = mapToScreenY(4.0f);
        ui.roundedRect(fairX0, fairY0, fairX1 - fairX0, fairY1 - fairY0, 10.0f,
            Color4(0.22f, 0.55f, 0.32f, 0.55f));

        ui.pill(mapToScreenX(-11.5f), mapToScreenY(72.0f), 16.0f, 20.0f, Color4(0.86f, 0.74f, 0.46f, 0.90f));
        ui.pill(mapToScreenX(7.0f), mapToScreenY(136.0f), 18.0f, 20.0f, Color4(0.86f, 0.74f, 0.46f, 0.90f));
        ui.circleFill(mapToScreenX(1.6f), mapToScreenY(133.5f), 13.0f, Color4(0.32f, 0.78f, 0.42f, 0.95f));
        ui.circleFill(mapToScreenX(CUP_X), mapToScreenY(CUP_Z), 3.5f, uiDanger);

        immutable float ballMapX = mapToScreenX(ballFocus.x);
        immutable float ballMapY = mapToScreenY(ballFocus.z);
        ui.circleRing(ballMapX, ballMapY, 7.0f, 1.5f, uiAccent);
        ui.circleFill(ballMapX, ballMapY, 3.0f, Color4.white);

        if (state == GameState.flight) {
            ui.pill((SCREEN_W - 420.0f) * 0.5f, infoY, 420.0f, 28.0f, uiSurface);
        }

        ui.elevatedCard(dockX, dockY, dockW, dockH, 22.0f, uiSurface);
        ui.pill(segX, segY, segW, segH, uiInset);
        immutable float selX = segX + segPad + clubIdx * (segInnerW + segGap);
        ui.pill(selX, segY + segPad, segInnerW, segH - segPad * 2.0f, uiAccent);

        ui.pill(meterX, meterY, meterW, meterH, uiInset);
        if (shownPower > 0.01f) {
            Color4 fillCol = uiAccent;
            if (shownPower > 0.75f) fillCol = uiDanger;
            else if (shownPower > 0.45f) fillCol = uiGold;
            immutable float fillW = meterW * shownPower;
            ui.pill(meterX, meterY, fillW < meterH ? meterH : fillW, meterH, fillCol);
        }
        ui.circleFill(notchX, meterY + meterH * 0.5f, 5.0f, uiGold);
        ui.circleFill(notchX, meterY + meterH * 0.5f, 2.2f, Color4(0.12f, 0.10f, 0.04f, 1.0f));
        if (shownPower > 0.01f) {
            immutable float cursorX = meterX + meterW * shownPower;
            ui.circleFill(cursorX, meterY + meterH * 0.5f, 7.0f, Color4.white);
        }
        } // playing HUD

        ui.render(frame);

        // -------------------------------------------------------------------
        // High-Typography Text Layer (Drawn inside Cards & Badges)
        // -------------------------------------------------------------------

        text.beginFrame();

        if (state == GameState.holed) {
            string scoreName;
            if (strokes == 1) scoreName = "HOLE IN ONE";
            else if (strokes == PAR - 2) scoreName = "EAGLE";
            else if (strokes == PAR - 1) scoreName = "BIRDIE";
            else if (strokes == PAR) scoreName = "PAR";
            else if (strokes == PAR + 1) scoreName = "BOGEY";
            else scoreName = "DOUBLE BOGEY";

            immutable float modalW = 440.0f;
            immutable float modalH = 168.0f;
            immutable float modalX = (SCREEN_W - modalW) * 0.5f;
            immutable float modalY = (SCREEN_H - modalH) * 0.5f;

            immutable float titleW = scoreName.length * 16.0f;
            text.drawText(frame, scoreName, modalX + (modalW - titleW) * 0.5f, modalY + 40.0f, 2);

            char[64] strokeBuf = void;
            auto strokeLine = sformat(strokeBuf[], "%d STROKES", strokes);
            immutable float subW = strokeLine.length * 8.0f;
            text.drawText(frame, strokeLine, modalX + (modalW - subW) * 0.5f, modalY + 68.0f, 1);

            immutable string again = "R    PLAY AGAIN";
            immutable float btnW = again.length * 8.0f;
            text.drawText(frame, again, modalX + (modalW - btnW) * 0.5f, modalY + modalH - 44.0f, 1);
        } else {
            text.drawText(frame, "EMERALD DUNES", headerX + 22.0f, headerY + 18.0f, 2);

            immutable string holeMeta = "HOLE 1    PAR 3    132 M";
            immutable float metaW = holeMeta.length * 8.0f;
            text.drawText(frame, holeMeta, (SCREEN_W - metaW) * 0.5f, headerY + 22.0f, 1);

            char[32] strkBuf = void;
            auto strkStr = sformat(strkBuf[], "STROKE %d", strokes + 1);
            immutable float badgeX = headerX + headerW - 124.0f;
            immutable float badgeTextX = badgeX + (108.0f - strkStr.length * 8.0f) * 0.5f;
            text.drawText(frame, strkStr, badgeTextX, headerY + 22.0f, 1);

            char[64] tDistBuf = void;
            auto tDistStr = sformat(tDistBuf[], "%.0f m", distM);
            text.drawText(frame, "TO PIN", infoX + 18.0f, infoY + 16.0f, 1);
            text.drawText(frame, tDistStr, infoX + 18.0f, infoY + 28.0f, 2);

            char[48] tYdsBuf = void;
            auto tYdsStr = sformat(tYdsBuf[], "%.0f YDS", distM * 1.09361f);
            text.drawText(frame, tYdsStr, infoX + infoW - 18.0f - tYdsStr.length * 8.0f, infoY + 34.0f, 1);

            char[48] tElevBuf = void;
            auto tElevStr = sformat(tElevBuf[], "%+.1f m", elevM);
            text.drawText(frame, "ELEV", infoX + 18.0f, infoY + 62.0f, 1);
            text.drawText(frame, tElevStr, infoX + 18.0f, infoY + 76.0f, 1);

            string lieShort;
            final switch (currentLie) {
                case Lie.tee:     lieShort = "Tee"; break;
                case Lie.fairway: lieShort = "Fairway"; break;
                case Lie.rough:   lieShort = "Rough"; break;
                case Lie.bunker:  lieShort = "Bunker"; break;
                case Lie.green:   lieShort = "Green"; break;
            }
            text.drawText(frame, "LIE", infoX + 130.0f, infoY + 62.0f, 1);
            text.drawText(frame, lieShort, infoX + 130.0f, infoY + 76.0f, 1);

            if (currentLie == Lie.green)
                text.drawText(frame, "STIMP 10.5", infoX + 18.0f, infoY + 100.0f, 1);

            immutable string[16] compassLabels = [
                "N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"
            ];
            float cDeg = meanDeg;
            while (cDeg < 0.0f) cDeg += 360.0f;
            while (cDeg >= 360.0f) cDeg -= 360.0f;
            immutable int cIdx = cast(int)((cDeg + 11.25f) / 22.5f) % 16;

            immutable float windTextX = windCardX + 112.0f;
            text.drawText(frame, "WIND", windTextX, windCardY + 28.0f, 1);
            char[32] wSpdBuf = void;
            auto wSpdStr = sformat(wSpdBuf[], "%.1f", meanSpd);
            text.drawText(frame, wSpdStr, windTextX, windCardY + 40.0f, 2);
            char[32] wDirBuf = void;
            auto wDirStr = sformat(wDirBuf[], "m/s  %s", compassLabels[cIdx]);
            text.drawText(frame, wDirStr, windTextX + wSpdStr.length * 16.0f + 8.0f, windCardY + 48.0f, 1);

            char[48] wGustBuf = void;
            auto wGustStr = sformat(wGustBuf[], "GUST %.1f", gustSpd);
            text.drawText(frame, wGustStr, windTextX, windCardY + 68.0f, 1);

            immutable float relDeg = meanDeg - (aimYaw * 180.0f / cast(float) PI);
            string windTactics;
            if (fabs(relDeg) < 25.0f)
                windTactics = "Tailwind";
            else if (fabs(relDeg) > 155.0f)
                windTactics = "Headwind";
            else if (relDeg > 0.0f)
                windTactics = "Cross from right";
            else
                windTactics = "Cross from left";
            text.drawText(frame, windTactics, windTextX, windCardY + 86.0f, 1);

            text.drawText(frame, "COURSE", mapX + 14.0f, mapY + 14.0f, 1);
            text.drawText(frame, "132 M", mapX + mapW - 14.0f - 5.0f * 8.0f, mapY + 14.0f, 1);

            if (state == GameState.flight) {
                char[96] trkBuf = void;
                auto trkLine = sformat(trkBuf[], "ALT %.1f m     %.1f m/s     CARRY %.0f m",
                    physPos.y - courseElevation(physPos.x, physPos.z),
                    physVel.length(),
                    (physPos - spawnPoint).length());
                immutable float trkW = trkLine.length * 8.0f;
                text.drawText(frame, trkLine, (SCREEN_W - trkW) * 0.5f, infoY + 10.0f, 1);
            }

            foreach (i; 0 .. 5) {
                immutable curX = segX + segPad + i * (segInnerW + segGap);
                immutable nameW = CLUBS[i].name.length * 8.0f;
                text.drawText(frame, CLUBS[i].name, curX + (segInnerW - nameW) * 0.5f, segY + 8.0f, 1);

                char[32] clbDetailBuf = void;
                auto clbDetailStr = sformat(clbDetailBuf[], "%.0f deg   %.0f m",
                    (i == clubIdx ? customLoft : CLUBS[i].defaultLoft), CLUBS[i].carryEstimateM);
                immutable float detW = clbDetailStr.length * 8.0f;
                text.drawText(frame, clbDetailStr, curX + (segInnerW - detW) * 0.5f, segY + 24.0f, 1);
            }

            char[24] pwrValBuf = void;
            auto pwrValStr = sformat(pwrValBuf[], "%3.0f%%", shownPower * 100.0f);
            text.drawText(frame, "POWER", meterX, dockY + 64.0f, 1);
            text.drawText(frame, pwrValStr, meterX + 56.0f, dockY + 64.0f, 1);

            string hint = "A D AIM     W S LOFT     1-5 CLUB     SPACE SWING     C CAMERA";
            if (state == GameState.aim && charging) {
                if (currentLie == Lie.green || clubIdx == 4) {
                    hint = shownPower >= 0.46f && shownPower <= 0.54f
                        ? "ON THE PIN  —  RELEASE"
                        : (shownPower < 0.46f ? "CHARGE TOWARD THE MARK" : "PAST THE PIN  —  RELEASE");
                } else {
                    hint = shownPower > 0.88f ? "SWEET SPOT  —  RELEASE" : "CHARGING";
                }
            } else if (state == GameState.flight) {
                hint = "BALL IN FLIGHT";
            }
            immutable float hintW = hint.length * 8.0f;
            text.drawText(frame, hint, dockX + (dockW - hintW) * 0.5f, dockY + dockH - 22.0f, 1);
        }

        app.endFrame(frame);
    }

    return 0;
}
