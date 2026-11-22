/// Buoyancy for Box3D rigid bodies floating on a `WaterBody`.
///
/// A floating body is described by a few spherical probes in its local frame.
/// Each probe adds Archimedes' force (water density × gravity × submerged
/// volume) at its world position, plus a drag force against the water's
/// relative velocity (current included), scaled by how submerged it is.
/// Off-center probes make a body pitch and roll with the wave slope.
module engine.water.buoyancy;

import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics.body : applyForce, getAngularVelocity, getLinearVelocity, getMass,
    getPosition, getRotation, isBodyValid;
import engine.physics.world : PhysicsWorld;
import engine.water.query : WaterSurfacePoint;
import bindings.box3d : b3BodyId;

@safe:

/// A spherical volume sample in the body's local frame.
struct BuoyancyProbe {
    Vec3 offset = Vec3(0.0f, 0.0f, 0.0f);
    float radius = 0.5f;
}

/// Water and drag parameters shared by every probe of a body.
struct BuoyancySettings {
    /// kg/m³ (fresh water 1000, sea water 1025).
    float waterDensity = 1000.0f;
    /// Linear drag per unit submerged fraction, in 1/s (multiplied by the
    /// body mass, so it is independent of the body's size).
    float linearDrag = 1.6f;
    /// Extra damping of the vertical velocity (bobbing), in 1/s.
    float verticalDrag = 1.2f;
}

/// Submerged volume (m³) of a sphere of `radius` whose center is `depth`
/// meters below the surface (negative = above). Exact spherical cap.
float sphereSubmergedVolume(float radius, float depth) pure nothrow @nogc {
    import core.stdc.math : fminf, fmaxf;
    immutable h = fminf(fmaxf(depth + radius, 0.0f), 2.0f * radius);
    return 3.14159265f * h * h * (3.0f * radius - h) / 3.0f;
}

/// Force of one probe, before it is applied.
struct ProbeForce {
    Vec3 point;
    Vec3 force;
    /// Submerged fraction of the probe volume (0..1).
    float submerged = 0.0f;
}

/// Buoyancy and drag of one probe at world `point` moving with `pointVelocity`
/// over a water surface sample. `mass` is the whole body's mass and
/// `probeCount` the number of probes sharing the drag.
ProbeForce probeForce(Vec3 point, Vec3 pointVelocity, float radius,
                      ref const WaterSurfacePoint water, float gravity,
                      float mass, uint probeCount,
                      ref const BuoyancySettings s) pure nothrow @nogc {
    ProbeForce f;
    f.point = point;
    immutable volume = 4.18879020f * radius * radius * radius;
    immutable sub = sphereSubmergedVolume(radius, water.height - point.y);
    if (sub <= 0.0f || volume <= 0.0f) return f;
    f.submerged = sub / volume;
    immutable lift = s.waterDensity * gravity * sub;
    immutable rel = pointVelocity - water.current;
    immutable share = mass / cast(float)(probeCount > 0 ? probeCount : 1);
    immutable drag = rel * (-s.linearDrag * share * f.submerged);
    immutable bob = -rel.y * s.verticalDrag * share * f.submerged;
    f.force = Vec3(drag.x, lift + drag.y + bob, drag.z);
    return f;
}

/// Applies buoyancy to `bodyId` for this physics step. `surfaceAt` returns
/// the water surface at a world XZ point (false = no water there), e.g.
/// `(x, z, ref p) => water.surfaceAt(x, z, time, p)` with a `WaterRenderer`.
/// Call once per frame before `PhysicsWorld.step`. Returns the body's mean
/// submerged fraction (0 = out of the water).
float applyBuoyancy(SurfaceFn)(ref PhysicsWorld world, b3BodyId bodyId,
                               scope const(BuoyancyProbe)[] probes,
                               scope SurfaceFn surfaceAt,
                               auto ref const BuoyancySettings s = BuoyancySettings.init) {
    if (probes.length == 0 || !isBodyValid(bodyId)) return 0.0f;
    immutable pos = getPosition(bodyId);
    immutable rot = getRotation(bodyId);
    immutable v = getLinearVelocity(bodyId);
    immutable w = getAngularVelocity(bodyId);
    immutable mass = getMass(bodyId);
    immutable g = -world.gravity().y;
    float total = 0.0f;
    foreach (ref pr; probes) {
        immutable arm = rot.rotate(pr.offset);
        immutable point = pos + arm;
        WaterSurfacePoint water;
        if (!surfaceAt(point.x, point.z, water)) continue;
        immutable f = probeForce(point, v + w.cross(arm), pr.radius, water, g,
                                 mass, cast(uint) probes.length, s);
        if (f.submerged <= 0.0f) continue;
        applyForce(bodyId, f.force, f.point);
        total += f.submerged;
    }
    return total / cast(float) probes.length;
}

/// Five probes approximating a sphere of `radius`: one at the center and four
/// around it on the horizontal plane, with the same total volume. The ring
/// makes the body tilt with the wave slope.
BuoyancyProbe[5] sphereProbes(float radius) pure nothrow @nogc {
    immutable r = radius * 0.585f;   // 5 × r³ ≈ radius³
    immutable o = radius * 0.5f;
    return [
        BuoyancyProbe(Vec3(0.0f, 0.0f, 0.0f), r),
        BuoyancyProbe(Vec3(o, 0.0f, 0.0f), r),
        BuoyancyProbe(Vec3(-o, 0.0f, 0.0f), r),
        BuoyancyProbe(Vec3(0.0f, 0.0f, o), r),
        BuoyancyProbe(Vec3(0.0f, 0.0f, -o), r),
    ];
}

unittest {
    import std.math : fabs;

    // Fully above, half and fully submerged sphere.
    assert(sphereSubmergedVolume(1.0f, -2.0f) == 0.0f);
    assert(fabs(sphereSubmergedVolume(1.0f, 0.0f) - 2.0943951f) < 1e-4f);
    assert(fabs(sphereSubmergedVolume(1.0f, 5.0f) - 4.1887902f) < 1e-4f);

    // A half-submerged probe at rest lifts half its volume of water.
    WaterSurfacePoint water;
    water.height = 1.0f;
    BuoyancySettings s;
    immutable f = probeForce(Vec3(0, 1, 0), Vec3(0, 0, 0), 1.0f, water, 9.81f, 100.0f, 1, s);
    assert(fabs(f.submerged - 0.5f) < 1e-4f);
    assert(fabs(f.force.y - 1000.0f * 9.81f * 2.0943951f) < 1.0f);
    assert(f.force.x == 0.0f && f.force.z == 0.0f);

    // Drag pushes a stationary probe along with the river current.
    water.current = Vec3(1.35f, 0, 0);
    immutable d = probeForce(Vec3(0, 0, 0), Vec3(0, 0, 0), 1.0f, water, 9.81f, 100.0f, 1, s);
    assert(d.force.x > 0.0f);

    // Out of the water: no force.
    immutable n = probeForce(Vec3(0, 5, 0), Vec3(0, -3, 0), 1.0f, water, 9.81f, 100.0f, 1, s);
    assert(n.submerged == 0.0f && n.force.y == 0.0f);

    // The five sphere probes keep the sphere's volume (within 1%).
    float vol = 0.0f;
    foreach (ref p; sphereProbes(0.5f)) vol += 4.18879020f * p.radius * p.radius * p.radius;
    assert(fabs(vol / (4.18879020f * 0.125f) - 1.0f) < 0.01f);
}

unittest {
    // A sphere half as dense as water settles half submerged on flat water.
    import std.math : fabs;
    import engine.physics.body : BodyDesc, createSphereBody, destroyBody;

    auto world = PhysicsWorld.createDefault();
    BodyDesc desc;
    desc.position = Vec3(0.0f, 2.0f, 0.0f);
    desc.density = 500.0f;
    desc.enableSleep = false;
    auto ball = createSphereBody(world, desc, 0.5f);
    assert(isBodyValid(ball));
    immutable probes = sphereProbes(0.5f);
    bool flatWater(float x, float z, ref WaterSurfacePoint p) {
        p.height = 0.0f;
        return true;
    }
    foreach (i; 0 .. 600) {
        applyBuoyancy(world, ball, probes[], &flatWater);
        world.step(1.0f / 60.0f);
    }
    immutable y = getPosition(ball).y;
    assert(fabs(y) < 0.08f, "floating sphere should rest near the surface");
    destroyBody(ball);
}
