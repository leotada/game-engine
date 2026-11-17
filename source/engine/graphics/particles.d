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

import std.math : sqrt;

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

struct ParticleSystem {
    private Pod!Particle[] pool;
    private size_t live = 0;

    /// Pool size allocated once; `spawn` is refused (returns false) when full.
    static ParticleSystem create(size_t capacity) {
        ParticleSystem s;
        s.pool = new Particle[capacity];
        return s;
    }

    size_t count() const pure nothrow @nogc { return live; }
    size_t capacity() const pure nothrow @nogc { return pool.length; }
    void clear() pure nothrow @nogc { live = 0; }

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
            immutable color = Color4(
                p.colorStart.r + (p.colorEnd.r - p.colorStart.r) * k,
                p.colorStart.g + (p.colorEnd.g - p.colorStart.g) * k,
                p.colorStart.b + (p.colorEnd.b - p.colorStart.b) * k,
                p.colorStart.a + (p.colorEnd.a - p.colorStart.a) * k);
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
