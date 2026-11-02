// Ported from meshoptimizer v1.3 (src/simplifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Tiny float3 helpers for meshopt kernels. Not `engine.math.Vec3`.
module engine.meshopt.internal.vec;

import engine.core.pod : isPod;

@safe:

struct Vec3 {
    float x = 0;
    float y = 0;
    float z = 0;
}

static assert(isPod!Vec3);

Vec3 vec3(float x, float y, float z) pure nothrow @nogc {
    return Vec3(x, y, z);
}

Vec3 add(Vec3 a, Vec3 b) pure nothrow @nogc {
    return Vec3(a.x + b.x, a.y + b.y, a.z + b.z);
}

Vec3 sub(Vec3 a, Vec3 b) pure nothrow @nogc {
    return Vec3(a.x - b.x, a.y - b.y, a.z - b.z);
}

Vec3 scale(Vec3 a, float s) pure nothrow @nogc {
    return Vec3(a.x * s, a.y * s, a.z * s);
}

float dot(Vec3 a, Vec3 b) pure nothrow @nogc {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vec3 cross(Vec3 a, Vec3 b) pure nothrow @nogc {
    return Vec3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

float length2(Vec3 a) pure nothrow @nogc {
    return dot(a, a);
}

float length(Vec3 a) pure nothrow @nogc {
    import core.math : sqrt;
    return sqrt(length2(a));
}

@safe pure nothrow @nogc unittest {
    Vec3 x = vec3(1, 0, 0);
    Vec3 y = vec3(0, 1, 0);
    Vec3 z = cross(x, y);
    assert(z.x == 0 && z.y == 0 && z.z == 1);
    assert(dot(x, y) == 0);
    assert(length(vec3(3, 4, 0)) == 5);
    Vec3 d = sub(vec3(2, 2, 2), vec3(1, 0, -1));
    assert(d.x == 1 && d.y == 2 && d.z == 3);
}
