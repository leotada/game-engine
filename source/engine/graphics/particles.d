/// Billboard particle system: CPU-simulated pool drawn as camera-facing quads
/// through `Scene3DTextured` (one instanced draw per system).
///
/// Pair it with an additive, unlit, non-depth-writing material whose albedo is
/// a soft disc (`Texture.softDisc`): the per-particle color and its alpha
/// curve ride in the instance tint (`tint.a` scales the surface opacity).
///
/// ---
/// auto particles = ParticleSystem.create(2000);
/// particles.spawn(ParticleDesc(pos: p, vel: v, life: 0.4f, sizeStart: 0.2f,
///                              colorStart: Color4(0.3f, 0.9f, 1, 1)));
/// particles.update(dt);
/// particles.draw(scene, quadMesh, glowMaterial, camera);
/// ---
module engine.graphics.particles;

import std.math : cbrt, cos, floor, sin, sqrt, PI;

import engine.core.pod : Pod, isPod;
import engine.graphics.material : Material;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

/// Parameters of one spawned particle. Size and color interpolate linearly
/// from `start` to `end` over the lifetime; fade by ending at alpha 0.
struct ParticleDesc {
    Vec3 pos = Vec3(0, 0, 0);
    Vec3 vel = Vec3(0, 0, 0);
    /// Seconds to live.
    float life = 1.0f;
    float sizeStart = 0.1f;
    float sizeEnd = 0.0f;
    Color4 colorStart = Color4(1, 1, 1, 1);
    Color4 colorEnd = Color4(1, 1, 1, 0);
    /// Speed lost per second (drag), never reverses the velocity.
    float damping = 0.0f;
    /// Constant acceleration (world units / s²).
    Vec3 gravity = Vec3(0, 0, 0);
}

struct Particle {
    Vec3 pos;
    Vec3 vel;
    Vec3 gravity;
    float age = 0.0f;
    float life = 1.0f;
    float sizeStart = 0.1f;
    float sizeEnd = 0.0f;
    float damping = 0.0f;
    Color4 colorStart;
    Color4 colorEnd;
}
static assert(isPod!Particle);

/// World matrix of a unit XZ quad (`TexMesh.quad`) turned to face the camera.
Mat4 billboardMatrix(Vec3 center, Vec3 right, Vec3 up, Vec3 toCamera, float size) pure nothrow @nogc {
    Mat4 r;
    r.m[0] = right.x * size;     r.m[1] = right.y * size;     r.m[2] = right.z * size;
    r.m[4] = toCamera.x;         r.m[5] = toCamera.y;         r.m[6] = toCamera.z;
    r.m[8] = up.x * size;        r.m[9] = up.y * size;        r.m[10] = up.z * size;
    r.m[12] = center.x;          r.m[13] = center.y;          r.m[14] = center.z;
    return r;
}

private float abs1(float v) pure nothrow @nogc { return v < 0.0f ? -v : v; }

/// Wrap `v` into [center - half, center + half).
private float wrapAxis(float v, float center, float half) pure nothrow @nogc {
    immutable span = half * 2.0f;
    immutable d = v - center + half;
    return center - half + (d - span * floor(d / span));
}

/// Continuous or burst particle source. Owns no particles: it feeds a
/// `ParticleSystem`. Everything is in world space; move/aim it by setting
/// `position` and `direction` before `emit`.
///
/// ---
/// ParticleEmitter plume;
/// plume.rate = 90;  plume.coneDeg = 8;  plume.speedMin = 10;  plume.speedMax = 20;
/// plume.lifeMin = 0.2f;  plume.lifeMax = 0.4f;  plume.sizeStart = 0.2f;
/// plume.colorStart = Color4(0.3f, 1.1f, 1.5f, 1);
/// // each frame:
/// plume.position = shipTail;  plume.direction = -shipForward;
/// plume.emit(particles, dt);
/// ---
struct ParticleEmitter {
    /// Particles per second for `emit`.
    float rate = 0.0f;
    Vec3 position = Vec3(0, 0, 0);
    /// Emission axis (need not be normalized).
    Vec3 direction = Vec3(0, 1, 0);
    /// Half-angle of the emission cone in degrees (0 = straight line, 180 = sphere).
    float coneDeg = 0.0f;
    /// Spawn point scatter: uniform inside a sphere of this radius.
    float spawnRadius = 0.0f;
    float speedMin = 1.0f, speedMax = 1.0f;
    float lifeMin = 1.0f, lifeMax = 1.0f;
    /// Size at birth is random in [sizeMin, sizeMax]; at death it is
    /// `sizeEndScale` times that.
    float sizeMin = 0.1f, sizeMax = 0.1f;
    float sizeEndScale = 0.0f;
    Color4 colorStart = Color4(1, 1, 1, 1);
    Color4 colorEnd = Color4(1, 1, 1, 0);
    float damping = 0.0f;
    Vec3 gravity = Vec3(0, 0, 0);
    /// Added to every particle velocity (e.g. the emitter's own motion).
    Vec3 inheritVelocity = Vec3(0, 0, 0);
    /// Set 0 to pause `emit` without losing the fractional carry.
    bool enabled = true;

    private float carry = 0.0f;
    private uint rngState = 0x9E3779B9u;

    /// Seed the emitter's random stream (deterministic effects, tests).
    void seed(uint value) pure nothrow @nogc { rngState = value == 0 ? 0x9E3779B9u : value; }

    /// Spawn `rate * dt` particles (the remainder carries to the next call, so
    /// low rates and variable frame times stay exact on average). Returns how
    /// many were actually added (the pool may be full).
    uint emit(ref ParticleSystem system, float dt) pure nothrow @nogc {
        if (!enabled || rate <= 0.0f || dt <= 0.0f) return 0;
        carry += rate * dt;
        immutable whole = cast(uint) carry;
        carry -= whole;
        return burst(system, whole);
    }

    /// Spawn exactly `count` particles now (explosions, muzzle flashes).
    uint burst(ref ParticleSystem system, uint count) pure nothrow @nogc {
        uint added = 0;
        foreach (_; 0 .. count) {
            if (system.spawn(makeParticle())) added++;
            else break;
        }
        return added;
    }

    private float next01() pure nothrow @nogc {
        rngState ^= rngState << 13;
        rngState ^= rngState >> 17;
        rngState ^= rngState << 5;
        return (rngState & 0xFFFFFF) * (1.0f / 16_777_216.0f);
    }

    private float between(float a, float b) pure nothrow @nogc { return a + (b - a) * next01(); }

    private ParticleDesc makeParticle() pure nothrow @nogc {
        immutable axis = direction.lengthSquared() > 1e-8f ? direction.normalized() : Vec3(0, 1, 0);
        immutable helper = abs1(axis.y) < 0.99f ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
        immutable t = axis.cross(helper).normalized();
        immutable b = axis.cross(t);
        // Uniform direction on the spherical cap.
        immutable cosCone = cos(coneDeg * (PI / 180.0f));
        immutable cosT = 1.0f - next01() * (1.0f - cosCone);
        immutable sinT = sqrt(1.0f - cosT * cosT);
        immutable phi = next01() * 2.0f * PI;
        immutable dir = axis * cosT + (t * cos(phi) + b * sin(phi)) * sinT;

        Vec3 offset = Vec3(0, 0, 0);
        if (spawnRadius > 0.0f) {
            // Rejection-free: cube-root radius inside a sphere.
            immutable u = next01();
            immutable v = next01() * 2.0f - 1.0f;
            immutable a = next01() * 2.0f * PI;
            immutable r = spawnRadius * cbrt(u);
            immutable ring = sqrt(1.0f - v * v);
            offset = Vec3(ring * cos(a), v, ring * sin(a)) * r;
        }

        ParticleDesc d;
        d.pos = position + offset;
        d.vel = dir * between(speedMin, speedMax) + inheritVelocity;
        d.life = between(lifeMin, lifeMax);
        immutable size = between(sizeMin, sizeMax);
        d.sizeStart = size;
        d.sizeEnd = size * sizeEndScale;
        d.colorStart = colorStart;
        d.colorEnd = colorEnd;
        d.damping = damping;
        d.gravity = gravity;
        return d;
    }
}

struct ParticleSystem {
    private Pod!Particle[] pool;
    private size_t live = 0;
    private Vec3 volumeCenter = Vec3(0, 0, 0);
    private Vec3 volumeHalf = Vec3(0, 0, 0);

    /// Pool size allocated once; `spawn` is refused (returns false) when full.
    static ParticleSystem create(size_t capacity) {
        ParticleSystem s;
        s.pool = new Particle[capacity];
        return s;
    }

    size_t count() const pure nothrow @nogc { return live; }
    size_t capacity() const pure nothrow @nogc { return pool.length; }
    void clear() pure nothrow @nogc { live = 0; }

    /// Confine particles to a box around `center` (half sizes per axis; 0 =
    /// unbounded on that axis). Particles that leave it wrap around to the
    /// opposite side, and fade near the XZ edges so the wrap never pops. Move
    /// the center every frame (e.g. to the camera) for an endless field of
    /// dust that streams past. Use a very long `life` for such particles.
    void setVolume(Vec3 center, Vec3 halfExtent) pure nothrow @nogc {
        volumeCenter = center;
        volumeHalf = halfExtent;
    }

    void clearVolume() pure nothrow @nogc { volumeHalf = Vec3(0, 0, 0); }

    bool spawn(in ParticleDesc d) pure nothrow @nogc {
        if (live >= pool.length || d.life <= 0.0f) return false;
        Particle p;
        p.pos = d.pos;
        p.vel = d.vel;
        p.gravity = d.gravity;
        p.life = d.life;
        p.sizeStart = d.sizeStart;
        p.sizeEnd = d.sizeEnd;
        p.damping = d.damping;
        p.colorStart = d.colorStart;
        p.colorEnd = d.colorEnd;
        pool[live++] = p;
        return true;
    }

    /// Advance every particle by `dt` seconds and drop the expired ones.
    void update(float dt) nothrow @nogc {
        size_t n = 0;
        foreach (i; 0 .. live) {
            auto p = pool[i];
            p.age += dt;
            if (p.age >= p.life) continue;
            p.vel += p.gravity * dt;
            immutable speed = p.vel.length();
            if (speed > 0.0f && p.damping > 0.0f) {
                immutable slowed = speed - p.damping * dt;
                p.vel = slowed > 0.0f ? p.vel * (slowed / speed) : Vec3(0, 0, 0);
            }
            p.pos += p.vel * dt;
            if (volumeHalf.x > 0.0f) p.pos.x = wrapAxis(p.pos.x, volumeCenter.x, volumeHalf.x);
            if (volumeHalf.y > 0.0f) p.pos.y = wrapAxis(p.pos.y, volumeCenter.y, volumeHalf.y);
            if (volumeHalf.z > 0.0f) p.pos.z = wrapAxis(p.pos.z, volumeCenter.z, volumeHalf.z);
            pool[n++] = p;
        }
        live = n;
    }

    /// Queue every live particle as a camera-facing quad. `material` should be
    /// additive/alpha, unlit, double sided, with a soft disc albedo.
    void draw(ref Scene3DTextured scene, ref TexMesh quad, ref Material material,
              in Camera camera) {
        if (live == 0) return;
        immutable toCamera = (camera.position - camera.target).normalized();
        immutable right = camera.up.cross(toCamera).normalized();
        immutable up = toCamera.cross(right);
        foreach (ref p; pool[0 .. live]) {
            immutable k = p.age / p.life;
            immutable size = p.sizeStart + (p.sizeEnd - p.sizeStart) * k;
            if (size <= 0.0f) continue;
            float fade = 1.0f;
            if (volumeHalf.x > 0.0f || volumeHalf.z > 0.0f) {
                immutable ex = volumeHalf.x > 0.0f ? abs1(p.pos.x - volumeCenter.x) / volumeHalf.x : 0.0f;
                immutable ez = volumeHalf.z > 0.0f ? abs1(p.pos.z - volumeCenter.z) / volumeHalf.z : 0.0f;
                immutable edge = ex > ez ? ex : ez;
                immutable t = edge <= 0.75f ? 0.0f : (edge >= 1.0f ? 1.0f : (edge - 0.75f) / 0.25f);
                fade = 1.0f - t * t * (3.0f - 2.0f * t);
                if (fade <= 0.0f) continue;
            }
            immutable color = Color4(
                p.colorStart.r + (p.colorEnd.r - p.colorStart.r) * k,
                p.colorStart.g + (p.colorEnd.g - p.colorStart.g) * k,
                p.colorStart.b + (p.colorEnd.b - p.colorStart.b) * k,
                (p.colorStart.a + (p.colorEnd.a - p.colorStart.a) * k) * fade);
            scene.drawMatrix(quad, material, billboardMatrix(p.pos, right, up, toCamera, size), color);
        }
    }
}

unittest {
    auto s = ParticleSystem.create(4);
    ParticleDesc d;
    d.life = 1.0f;
    d.vel = Vec3(2, 0, 0);
    d.damping = 1.0f;
    assert(s.spawn(d));
    d.life = 0.25f;
    assert(s.spawn(d));
    assert(s.count == 2);

    s.update(0.5f); // the short one expired
    assert(s.count == 1);
    assert(s.pool[0].pos.x > 0.7f && s.pool[0].pos.x < 1.0f); // dragged below 2 * 0.5

    foreach (_; 0 .. 8) s.spawn(d);
    assert(s.count == s.capacity); // full pool refuses extra spawns
    assert(!s.spawn(d));
    s.update(10.0f);
    assert(s.count == 0);
}

unittest {
    // Facing the camera: the quad normal (local Y) maps to the camera direction.
    immutable m = billboardMatrix(Vec3(1, 2, 3), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1), 2.0f);
    assert(m.m[4] == 0 && m.m[6] == 1);
    assert(m.m[0] == 2 && m.m[9] == 2);
    assert(m.m[12] == 1 && m.m[14] == 3);
}

unittest {
    ParticleEmitter e;
    e.seed(7);
    e.rate = 100.0f;
    e.lifeMin = e.lifeMax = 10.0f;
    auto s = ParticleSystem.create(1000);

    // 100/s for 10 frames of 16.6 ms: the fractional carry keeps it exact.
    foreach (_; 0 .. 10) e.emit(s, 1.0f / 60.0f);
    assert(s.count == 16 || s.count == 17);
    foreach (_; 0 .. 50) e.emit(s, 1.0f / 60.0f);
    assert(s.count >= 98 && s.count <= 101);

    e.enabled = false;
    immutable before = s.count;
    e.emit(s, 1.0f);
    assert(s.count == before);

    // A full pool stops the burst instead of overrunning.
    auto tiny = ParticleSystem.create(3);
    e.enabled = true;
    assert(e.burst(tiny, 10) == 3);
}

unittest {
    // Cone emission: every velocity stays within the half-angle of the axis.
    ParticleEmitter e;
    e.seed(3);
    e.direction = Vec3(0, 0, -1);
    e.coneDeg = 10.0f;
    e.speedMin = e.speedMax = 5.0f;
    e.lifeMin = e.lifeMax = 5.0f;
    e.spawnRadius = 0.5f;
    auto s = ParticleSystem.create(500);
    e.burst(s, 500);
    immutable cosLimit = cos(10.0f * (PI / 180.0f)) - 1e-3f;
    foreach (ref p; s.pool[0 .. s.count]) {
        immutable dir = p.vel.normalized();
        assert(dir.z <= -cosLimit);
        assert(p.pos.length() <= 0.5f + 1e-3f);
    }
}

unittest {
    // Volume: particles wrap to the other side of the box.
    auto s = ParticleSystem.create(2);
    s.setVolume(Vec3(0, 0, 0), Vec3(10, 0, 10));
    ParticleDesc d;
    d.life = 100.0f;
    d.pos = Vec3(9, 3, 0);
    d.vel = Vec3(4, 0, 0);
    s.spawn(d);
    s.update(1.0f);   // x = 13 -> wraps to -7
    assert(s.pool[0].pos.x > -7.01f && s.pool[0].pos.x < -6.99f);
    assert(s.pool[0].pos.y == 3.0f); // unbounded axis untouched
}
