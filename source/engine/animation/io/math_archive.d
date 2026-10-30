// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/base/maths/math_archive.cc @ 744eb9d (load side)
/// Readers for the math types stored inside ozz archives.
module engine.animation.io.math_archive;

import engine.animation.io.archive;
import engine.animation.math.simd;
import engine.animation.math.soa;

@safe pure nothrow:

SimdFloat4 readSimdFloat4(ref InputArchive ar) @nogc {
    immutable x = ar.read!float();
    immutable y = ar.read!float();
    immutable z = ar.read!float();
    immutable w = ar.read!float();
    return SimdFloat4(x, y, z, w);
}

/// A `SoaTransform` is stored as 40 floats: t.x t.y t.z, r.x r.y r.z r.w, s.x s.y s.z (4 each).
SoaTransform readSoaTransform(ref InputArchive ar) @nogc {
    SoaTransform t;
    t.translation.x = readSimdFloat4(ar);
    t.translation.y = readSimdFloat4(ar);
    t.translation.z = readSimdFloat4(ar);
    t.rotation.x = readSimdFloat4(ar);
    t.rotation.y = readSimdFloat4(ar);
    t.rotation.z = readSimdFloat4(ar);
    t.rotation.w = readSimdFloat4(ar);
    t.scale.x = readSimdFloat4(ar);
    t.scale.y = readSimdFloat4(ar);
    t.scale.z = readSimdFloat4(ar);
    return t;
}

unittest {
    // 40 little-endian floats 0..39 map onto the fields in order.
    ubyte[] file = [1];
    foreach (i; 0 .. 40) {
        union U { float f; ubyte[4] b; }
        U u = {f: cast(float) i};
        file ~= u.b[];
    }
    auto ar = InputArchive(file);
    auto t = readSoaTransform(ar);
    assert(ar.ok && ar.empty);
    assert(t.translation.x == SimdFloat4(0, 1, 2, 3));
    assert(t.rotation.w == SimdFloat4(24, 25, 26, 27));
    assert(t.scale.z == SimdFloat4(36, 37, 38, 39));

    auto trunc = InputArchive(file[0 .. 100]);
    readSoaTransform(trunc);
    assert(!trunc.ok);
}
