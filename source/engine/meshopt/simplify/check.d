// Ported checks from meshoptimizer v1.3 demo/tests.cpp (simplifier block).
module engine.meshopt.simplify.check;

import engine.meshopt.internal.bits : floatBits;
import engine.meshopt.simplify : simplify, simplifyPoints, simplifyPrune, simplifyScale, simplifySloppy, simplifyWithAttributes, simplifyWithUpdate;
import engine.meshopt.types : FloatStream, SimplifyOptions;

@safe:

private FloatStream fs(scope const(float)[] data, size_t count, size_t stride, size_t offset = 0) nothrow @nogc @trusted {
    FloatStream s;
    s.strideFloats = stride;
    s.count = count;
    if (count)
        s.address = cast(ulong)(data.ptr + offset);
    return s;
}

private bool near(float a, float b, float tol) pure nothrow @nogc {
    float d = a - b;
    if (d < 0)
        d = -d;
    return d < tol;
}

@("simplify.flip") nothrow @nogc unittest {
    float[27] vb = [
        1, 1, -1, 1, 1, 1, 1, -1, 1, 1, -0.2f, -0.2f, 1, 0.2f, -0.2f,
        1, -0.2f, 0.2f, 1, 0.2f, 0.2f, 1, 0.5f, -0.5f, 1, -1, 0
    ];
    uint[30] ib = [
        7, 4, 3, 1, 2, 5, 7, 1, 6, 7, 8, 0, 7, 6, 4, 8, 5, 2, 8, 7, 3, 8, 3, 5, 5, 6, 1, 7, 0, 1
    ];
    uint[24] expected = [
        0, 4, 3, 1, 2, 5, 0, 1, 6, 0, 6, 4, 8, 5, 2, 8, 0, 3, 8, 3, 5, 5, 6, 1
    ];
    assert(simplify(ib[], ib[], fs(vb[], 9, 3), 3, 1e-3f) == 24);
    assert(ib[0 .. 24] == expected[]);
}

@("simplify.degenerate") nothrow @nogc unittest {
    float[18] vb = [0, 0, 0, 0, 1, 0, 0, 2, 0, 1, 0, 0, 2, 0, 0, 1, 1, 0];
    uint[18] ib = [0, 1, 3, 3, 1, 5, 1, 2, 5, 3, 5, 4, 1, 0, 1, 0, 3, 0];
    uint[6] expected = [0, 1, 4, 4, 1, 2];
    assert(simplify(ib[], ib[], fs(vb[], 6, 3), 3, 1e-3f) == 6);
    assert(ib[0 .. 6] == expected[]);
}

@("simplify.lockBorder") nothrow @nogc unittest {
    float[27] vb = [
        0, 0, 0, 0, 1, 0, 0, 2, 0, 1, 0, 0, 1, 1, 0, 1, 2, 0, 2, 0, 0, 2, 1, 0, 2, 2, 0
    ];
    uint[24] ib = [
        0, 1, 3, 3, 1, 4, 1, 2, 4, 4, 2, 5, 3, 4, 6, 6, 4, 7, 4, 5, 7, 7, 5, 8
    ];
    uint[18] expected = [0, 1, 3, 1, 2, 3, 3, 2, 5, 6, 3, 7, 3, 5, 7, 7, 5, 8];
    assert(simplify(ib[], ib[], fs(vb[], 9, 3), 3, 1e-3f, SimplifyOptions.lockBorder) == 18);
    assert(ib[0 .. 18] == expected[]);
}

@("simplify.attributes") nothrow @nogc unittest {
    float[8 * 3 * 6] vb;
    foreach (y; 0 .. 8) {
        float r = (y < 4) ? 0.8f + y * 0.05f : 0.0f;
        float g = (y < 4) ? 0.8f + y * 0.05f : 0.0f;
        float b = (y < 4) ? 0.0f : 0.8f + (7 - y) * 0.05f;
        foreach (x; 0 .. 3) {
            size_t i = (y * 3 + x) * 6;
            vb[i + 0] = x;
            vb[i + 1] = y;
            vb[i + 2] = 0.03f * x + 0.03f * (y % 2) + (x == 2 && y == 7 ? 0.03f : 0);
            vb[i + 3] = r;
            vb[i + 4] = g;
            vb[i + 5] = b;
        }
    }
    uint[7 * 2 * 6] ib;
    foreach (y; 0 .. 7) {
        foreach (x; 0 .. 2) {
            size_t i = (y * 2 + x) * 6;
            ib[i + 0] = (y + 0) * 3 + (x + 0);
            ib[i + 1] = (y + 0) * 3 + (x + 1);
            ib[i + 2] = (y + 1) * 3 + (x + 0);
            ib[i + 3] = (y + 1) * 3 + (x + 0);
            ib[i + 4] = (y + 0) * 3 + (x + 1);
            ib[i + 5] = (y + 1) * 3 + (x + 1);
        }
    }
    uint[18] expected = [0, 2, 11, 0, 11, 9, 9, 11, 12, 12, 11, 14, 12, 14, 23, 12, 23, 21];
    uint[84] copy = ib;
    float[3] weights = [0.5f, 0.5f, 0.5f];
    assert(simplifyWithAttributes(ib[], ib[], fs(vb[], 24, 6), fs(vb[], 24, 6, 3), weights[], null, 18, 1e-2f) == 18);
    assert(ib[0 .. 18] == expected[]);
    weights[1] = 0;
    assert(simplifyWithAttributes(copy[], copy[], fs(vb[], 24, 6), fs(vb[], 24, 6, 3), weights[], null, 18, 1e-2f) == 18);
    assert(copy[0 .. 18] == expected[]);
}

@("simplify.lockFlags") nothrow @nogc unittest {
    float[27] vb = [
        0, 0, 0, 0, 1, 0, 0, 2, 0, 1, 0, 0, 1, 1, 0, 1, 2, 0, 2, 0, 0, 2, 1, 0, 2, 2, 0
    ];
    ubyte[9] lock = [1, 1, 1, 1, 0, 1, 1, 1, 1];
    uint[24] ib = [
        0, 1, 3, 3, 1, 4, 1, 2, 4, 4, 2, 5, 3, 4, 6, 6, 4, 7, 4, 5, 7, 7, 5, 8
    ];
    uint[18] expected = [0, 1, 3, 1, 2, 3, 3, 2, 5, 6, 3, 7, 3, 5, 7, 7, 5, 8];
    assert(simplifyWithAttributes(ib[], ib[], fs(vb[], 9, 3), FloatStream.init, null, lock[], 3, 1e-3f) == 18);
    assert(ib[0 .. 18] == expected[]);
}

@("simplify.lockFlagsSeam") nothrow @nogc unittest {
    float[36] vb = [
        0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 2, 0, 1, 0, 0, 1, 1, 0, 1, 1, 0, 1, 2, 0,
        2, 0, 0, 2, 1, 0, 2, 1, 0, 2, 2, 0
    ];
    ubyte[12] lock0 = [1, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 1];
    ubyte[12] lock1 = [1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1];
    ubyte[12] lock2 = [1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1];
    ubyte[12] lock3 = [1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1];
    uint[24] ib = [
        0, 1, 4, 4, 1, 5, 4, 5, 8, 8, 5, 9, 2, 3, 6, 6, 3, 7, 6, 7, 10, 10, 7, 11
    ];
    uint[24] res;
    assert(simplifyWithAttributes(res[], ib[], fs(vb[], 12, 3), FloatStream.init, null, null, 0, 1.0f) == 0);
    assert(simplifyWithAttributes(res[], ib[], fs(vb[], 12, 3), FloatStream.init, null, lock0[], 0, 1.0f) == 12);
    assert(simplifyWithAttributes(res[], ib[], fs(vb[], 12, 3), FloatStream.init, null, lock1[], 0, 1.0f) == 18);
    assert(simplifyWithAttributes(res[], ib[], fs(vb[], 12, 3), FloatStream.init, null, lock2[], 0, 1.0f) == 24);
    assert(simplifyWithAttributes(res[], ib[], fs(vb[], 12, 3), FloatStream.init, null, lock3[], 0, 1.0f) == 24);
}

@("simplify.sparse") nothrow @nogc unittest {
    float[27] vb = [
        0, 0, 100, 0, 1, 0, 0, 2, 100, 1, 0, 0.1f, 1, 1, 0.1f, 1, 2, 0.1f, 2, 0, 100, 2, 1, 0, 2, 2, 100
    ];
    float[9] vba = [100, 0.5f, 100, 0.5f, 0.5f, 0, 100, 0.5f, 100];
    ubyte[9] lock = [8, 1, 8, 1, 0, 1, 8, 1, 8];
    uint[12] ib = [3, 1, 4, 1, 5, 4, 3, 4, 7, 4, 5, 7];
    uint[12] res;
    uint[6] expected = [1, 5, 3, 3, 5, 7];
    uint[6] expectedA = [3, 1, 7, 1, 5, 7];
    assert(simplify(res[], ib[], fs(vb[], 9, 3), 6, 1e-3f, SimplifyOptions.sparse) == 6);
    assert(res[0 .. 6] == expected[]);
    float[1] aw = [0.5f];
    assert(simplifyWithAttributes(res[], ib[], fs(vb[], 9, 3), fs(vba[], 9, 1), aw[], lock[], 6, 1e-1f, SimplifyOptions.sparse) == 6);
    assert(res[0 .. 6] == expectedA[]);
    uint[12] aliasIb = ib;
    assert(simplify(aliasIb[], aliasIb[], fs(vb[], 9, 3), 6, 1e-3f, SimplifyOptions.sparse) == 6);
    assert(aliasIb[0 .. 6] == expected[]);
}

@("simplify.errorAbsolute") nothrow @nogc unittest {
    float[27] vb = [
        0, 0, 0, 0, 1, 0, 0, 2, 0, 1, 0, 0, 1, 1, 1, 1, 2, 0, 2, 0, 0, 2, 1, 0, 2, 2, 0
    ];
    uint[24] ib = [
        0, 1, 3, 3, 1, 4, 1, 2, 4, 4, 2, 5, 3, 4, 6, 6, 4, 7, 4, 5, 7, 7, 5, 8
    ];
    float[1] error;
    assert(simplify(ib[], ib[], fs(vb[], 9, 3), 18, 2.0f, SimplifyOptions.lockBorder | SimplifyOptions.errorAbsolute, error[]) == 18);
    assert(near(error[0], 0.85f, 0.01f));
}

@("simplify.seam") nothrow @nogc unittest {
    float[64] vb = [
        0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0, 2, 0, 1, 1, 0, 0, 0, 1, 1, 0.3f, 0, 1, 1, 0.3f, 1, 1, 2, 0, 1,
        2, 0, 0, 0, 2, 1, 0.1f, 0, 2, 1, 0.1f, 1, 2, 2, 0, 1, 3, 0, 0, 0, 3, 1, 0, 0, 3, 1, 0, 1, 3, 2, 0, 1
    ];
    uint[36] ib = [
        0, 1, 4, 4, 1, 5, 2, 3, 6, 6, 3, 7, 4, 5, 8, 8, 5, 9, 6, 7, 10, 10, 7, 11, 8, 9, 12, 12, 9, 13, 10, 11, 14, 14, 11, 15
    ];
    uint[12] expected = [0, 1, 13, 2, 3, 14, 0, 13, 12, 14, 3, 15];
    uint[36] res;
    float[1] error;
    assert(simplify(res[], ib[], fs(vb[], 16, 4), 12, 1.0f, SimplifyOptions.none, error[]) == 12);
    assert(res[0 .. 12] == expected[]);
    assert(near(error[0], 0.1f, 0.01f));
    float[1] aw = [1];
    assert(simplifyWithAttributes(res[], ib[], fs(vb[], 16, 4), fs(vb[], 16, 4, 3), aw[], null, 12, 2.0f, SimplifyOptions.none, error[]) == 12);
    assert(res[0 .. 12] == expected[]);
    assert(near(error[0], 0.1f, 0.01f));
}

@("simplify.seamFake") nothrow @nogc unittest {
    float[16] vb = [0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 2, 0, 0, 0, 3];
    uint[6] ib = [0, 1, 2, 2, 1, 3];
    assert(simplify(ib[], ib[], fs(vb[], 4, 4), 0, 1.0f) == 6);
}

@("simplify.seamAttr") nothrow @nogc unittest {
    float[48] vb = [
        0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 1, 0, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 2, 0, 1,
        4, 0, 0, 2, 4, 1, 0, 2, 4, 1, 0, 2, 4, 2, 0, 2
    ];
    uint[24] ib = [
        0, 1, 4, 4, 1, 5, 2, 3, 6, 6, 3, 7, 4, 5, 8, 8, 5, 9, 6, 7, 10, 10, 7, 11
    ];
    uint[18] expected = [0, 1, 4, 2, 3, 7, 4, 1, 8, 8, 1, 9, 2, 7, 10, 10, 7, 11];
    uint[24] res;
    float[1] error;
    float[1] aw = [1];
    assert(simplifyWithAttributes(res[], ib[], fs(vb[], 12, 4), fs(vb[], 12, 4, 3), aw[], null, 12, 2.0f, SimplifyOptions.lockBorder, error[]) == 18);
    assert(res[0 .. 18] == expected[]);
    assert(near(error[0], 0.35f, 0.01f));
}

@("simplify.prune") nothrow @nogc unittest {
    uint[15] ib = [3, 2, 4, 0, 2, 1, 1, 2, 3, 2, 5, 4, 6, 7, 8];
    float[27] vb = [
        0, 4, 0, 0, 1, 0, 2, 2, 0, 0, 0, 0, 1, 0, 0, 4, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1
    ];
    uint[3] expected = [0, 5, 3];
    float[1] error;
    assert(simplify(ib[], ib[], fs(vb[], 9, 3), 3, 1e-2f, SimplifyOptions.prune, error[]) == 3);
    assert(error[0] < 1e-4f);
    assert(ib[0 .. 3] == expected[]);
    assert(simplify(ib[0 .. 3], ib[0 .. 3], fs(vb[], 9, 3), 3, 1e-2f, SimplifyOptions.prune, error[]) == 3);
    assert(simplify(ib[0 .. 3], ib[0 .. 3], fs(vb[], 9, 3), 3, 1e-2f, SimplifyOptions.prune | SimplifyOptions.sparse, error[]) == 3);
    assert(ib[0 .. 3] == expected[]);
}

@("simplify.pruneCleanup") nothrow @nogc unittest {
    uint[9] ib = [0, 1, 2, 3, 4, 5, 6, 7, 8];
    float[27] vb = [0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 2, 1, 2, 0, 1, 0, 0, 2, 0, 4, 2, 4, 0, 2];
    float[1] error;
    assert(simplify(ib[], ib[], fs(vb[], 9, 3), 3, 1.0f, SimplifyOptions.lockBorder | SimplifyOptions.prune, error[]) == 3);
    assert(near(error[0], 0.37f, 0.01f));
    assert(ib[0 .. 3] == [6, 7, 8]);
}

@("simplify.update") nothrow @nogc unittest {
    float[20] vb = [0, 0, 0, 0, 1, 1, 0, 0, 2, 0, 0, 0, 0.9f, 0.2f, 0.1f, 0.2f, 1.1f, 0.2f, 0.1f, 0.1f];
    uint[15] ib = [0, 1, 3, 3, 1, 4, 4, 1, 2, 0, 3, 2, 3, 4, 2];
    float[1] aw = [1];
    assert(simplifyWithUpdate(ib[], fs(vb[], 5, 4), fs(vb[], 5, 4, 3), aw[], null, 9, 1.0f) == 9);
    assert(ib[0 .. 9] == [0, 1, 3, 3, 1, 2, 0, 3, 2]);
    foreach (i; 0 .. 3)
        assert(near(vb[i * 4 + 3], 0, 1e-6f));
    assert(near(vb[12], 0.88f, 1e-2f));
    assert(near(vb[13], 0.19f, 1e-2f));
    assert(near(vb[14], 0.11f, 1e-2f));
    assert(near(vb[15], 0.18f, 1e-2f));
}

@("simplify.updateLocked") nothrow @nogc unittest {
    void run(SimplifyOptions options) {
        float[20] vb = [0, 0, 0, 0, 1, 1, 0, 0, 2, 0, 0, 0, 0.9f, 0.2f, 0.1f, 0.2f, 1.1f, 0.2f, 0.1f, 0.1f];
        uint[15] ib = [0, 1, 3, 3, 1, 4, 4, 1, 2, 0, 3, 2, 3, 4, 2];
        float[1] aw = [1];
        ubyte[5] vertexLock = [0, 0, 0, 1, 0];
        assert(simplifyWithUpdate(ib[], fs(vb[], 5, 4), fs(vb[], 5, 4, 3), aw[], vertexLock[], 9, 1.0f, options) == 9);
        assert(ib[0 .. 9] == [0, 1, 3, 3, 1, 2, 0, 3, 2]);
        foreach (i; 0 .. 3)
            assert(near(vb[i * 4 + 3], 0, 1e-6f));
        assert(vb[12] == 0.9f);
        assert(vb[13] == 0.2f);
        assert(vb[14] == 0.1f);
        assert(vb[15] == 0.2f);
    }
    run(SimplifyOptions.none);
    run(SimplifyOptions.sparse);
}

@("simplify.folds") nothrow @nogc unittest {
    float[18] vb = [0, 0, 0, 1, 0, 0, 2, 0, 0, 0, 1, 0, 1, 1, 0, 2, 1, 0];
    uint[24] ib = [
        0, 1, 3, 3, 1, 4, 1, 2, 4, 4, 2, 5, 0, 3, 1, 3, 4, 1, 1, 4, 2, 4, 5, 2
    ];
    uint[24] result;
    assert(simplify(result[], ib[], fs(vb[], 6, 3), 0, 1e-3f) == 0);
    assert(simplify(result[], ib[], fs(vb[], 6, 3), 0, 1e-3f, SimplifyOptions.preserveFolds) == 12);
    assert(result[0 .. 12] == [0, 2, 3, 3, 2, 5, 0, 3, 2, 3, 5, 2]);
}

@("simplify.sloppy") nothrow @nogc unittest {
    float[9] vb = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    uint[6] ib = [0, 1, 2, 0, 1, 2];
    uint[6] dst;
    assert(simplifySloppy(dst[0 .. 3], ib[0 .. 3], fs(vb[], 3, 3), null, 0, 0.0f) == 0);
    assert(simplifySloppy(dst[], ib[], fs(vb[], 3, 3), null, 6, 0.0f) == 0);

    uint[12] tri = [0, 2, 1, 1, 2, 3, 3, 2, 4, 2, 5, 4];
    float[18] pos = [0, 4, 0, 0, 1, 0, 2, 2, 0, 0, 0, 0, 1, 0, 0, 4, 0, 0];
    ubyte[6] locks = [1, 0, 1, 0, 0, 1];
    float[1] error;
    assert(simplifySloppy(tri[], tri[], fs(pos[], 6, 3), locks[], 3, 1.0f, error[]) == 6);
    assert(error[0] == 0.0f);
    assert(tri[0 .. 6] == [0, 2, 1, 1, 2, 5]);
}

@("simplify.points") nothrow @nogc unittest {
    float[9] vb = [0, 0, 0, 0, 0, 0, 0, 0, 0];
    uint[1] dst;
    assert(simplifyPoints(dst[], fs(vb[], 3, 3), FloatStream.init, 0, 0) == 0);
}

@("simplify.scale") nothrow @nogc unittest {
    float[12] vb = [0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0, 3];
    assert(simplifyScale(fs(vb[], 4, 3)) == 3.0f);
}

@("simplify.pruneFunc") nothrow @nogc unittest {
    uint[9] ib = [0, 1, 2, 3, 4, 5, 6, 7, 8];
    float[27] vb = [0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 2, 1, 2, 0, 1, 0, 0, 2, 0, 4, 2, 4, 0, 2];
    assert(simplifyPrune(ib[], ib[], fs(vb[], 9, 3), 0.5f) == 3);
    assert(ib[0 .. 3] == [6, 7, 8]);
}

@("simplify.golden") @trusted unittest {
    import std.file : read;
    ubyte[] file = cast(ubyte[]) read("tests/meshopt/golden/simplify.bin");
    assert(file.length >= 16);
    assert(file[0 .. 8] == cast(const(ubyte)[]) "MOPTGLD1");
    uint ver = file[8] | (cast(uint) file[9] << 8) | (cast(uint) file[10] << 16) | (cast(uint) file[11] << 24);
    assert(ver == 1030);
    uint cases = file[12] | (cast(uint) file[13] << 8) | (cast(uint) file[14] << 16) | (cast(uint) file[15] << 24);
    assert(cases == 6);

    enum n = 8;
    enum vc = (n + 1) * (n + 1);
    float[vc * 3] pos;
    float[vc * 5] attr;
    pos[] = 0;
    attr[] = 0;
    uint[n * n * 6] idx;
    foreach (z; 0 .. n + 1) {
        foreach (x; 0 .. n + 1) {
            size_t i = z * (n + 1) + x;
            pos[i * 3 + 0] = x;
            pos[i * 3 + 2] = z;
            attr[i * 5 + 1] = 1;
            attr[i * 5 + 3] = cast(float) x / n;
            attr[i * 5 + 4] = cast(float) z / n;
        }
    }
    size_t t = 0;
    foreach (z; 0 .. n) {
        foreach (x; 0 .. n) {
            uint a = cast(uint)(z * (n + 1) + x);
            uint b = a + 1, c = a + n + 1, d = c + 1;
            idx[t++] = a;
            idx[t++] = c;
            idx[t++] = b;
            idx[t++] = b;
            idx[t++] = c;
            idx[t++] = d;
        }
    }
    float[5] weights = [0.5f, 0.5f, 0.5f, 0.25f, 0.25f];
    size_t at = 16;
    foreach (_; 0 .. cases) {
        uint nameLen = file[at] | (cast(uint) file[at + 1] << 8) | (cast(uint) file[at + 2] << 16) | (cast(uint) file[at + 3] << 24);
        at += 4;
        string name = cast(string)(cast(char[]) file[at .. at + nameLen]);
        at += nameLen;
        uint count = file[at] | (cast(uint) file[at + 1] << 8) | (cast(uint) file[at + 2] << 16) | (cast(uint) file[at + 3] << 24);
        at += 4;
        uint ebits = file[at] | (cast(uint) file[at + 1] << 8) | (cast(uint) file[at + 2] << 16) | (cast(uint) file[at + 3] << 24);
        at += 4;
        uint[] expect;
        expect.length = count;
        foreach (i; 0 .. count) {
            expect[i] = file[at] | (cast(uint) file[at + 1] << 8) | (cast(uint) file[at + 2] << 16) | (cast(uint) file[at + 3] << 24);
            at += 4;
        }
        uint[] dst = new uint[idx.length];
        float[1] err;
        size_t got;
        if (name == "simplify")
            got = simplify(dst, idx[], fs(pos[], vc, 3), idx.length / 2, 0.05f, SimplifyOptions.none, err[]);
        else if (name == "lockBorder")
            got = simplify(dst, idx[], fs(pos[], vc, 3), idx.length / 4, 0.05f, SimplifyOptions.lockBorder, err[]);
        else if (name == "attributes")
            got = simplifyWithAttributes(dst, idx[], fs(pos[], vc, 3), fs(attr[], vc, 5), weights[], null, idx.length / 2, 0.05f, SimplifyOptions.none, err[]);
        else if (name == "sloppy")
            got = simplifySloppy(dst, idx[], fs(pos[], vc, 3), null, idx.length / 4, 0.05f, err[]);
        else if (name == "prune") {
            got = simplifyPrune(dst, idx[], fs(pos[], vc, 3), 0.02f);
            err[0] = 0;
        } else if (name == "scale") {
            got = 0;
            err[0] = simplifyScale(fs(pos[], vc, 3));
        } else {
            assert(0, name);
        }
        assert(got == count, name);
        assert(dst[0 .. got] == expect[], name);
        assert(floatBits(err[0]) == ebits, name);
    }
    assert(at == file.length);
}

@("simplify.fuzz") nothrow unittest {
    uint state = 0x1234_5678;
    uint next() {
        state = state * 1664525u + 1013904223u;
        return state;
    }
    foreach (trial; 0 .. 32) {
        uint vc = 4 + (next() % 12);
        uint tc = 1 + (next() % 10);
        float[] pos;
        pos.length = vc * 3;
        foreach (i; 0 .. vc * 3)
            pos[i] = (cast(int)(next() % 17) - 8) * 0.1f;
        uint[] idx;
        idx.length = tc * 3;
        foreach (i; 0 .. idx.length)
            idx[i] = next() % vc;
        // Duplicate a vertex and insert a degenerate.
        if (vc > 1)
            pos[3 .. 6] = pos[0 .. 3];
        idx[0] = idx[1];
        uint[] dst = new uint[idx.length];
        float[1] err;
        size_t n = simplify(dst, idx, fs(pos, vc, 3), (tc / 2) * 3, 0.2f, SimplifyOptions.none, err[]);
        assert(n <= idx.length && n % 3 == 0);
        foreach (i; 0 .. n)
            assert(dst[i] < vc);
        size_t sn = simplifySloppy(dst, idx, fs(pos, vc, 3), null, (tc / 2) * 3, 0.2f, err[]);
        assert(sn <= idx.length && sn % 3 == 0);
        size_t pn = simplifyPrune(dst, idx, fs(pos, vc, 3), 0.5f);
        assert(pn <= idx.length && pn % 3 == 0);
        uint[] points = new uint[vc];
        size_t kn = simplifyPoints(points, fs(pos, vc, 3), FloatStream.init, 1, vc / 2 + 1);
        assert(kn <= vc / 2 + 1);
        foreach (i; 0 .. kn)
            assert(points[i] < vc);
    }
}

@("simplify.ushort") nothrow @nogc unittest {
    ushort[12] ib = [0, 2, 1, 1, 2, 3, 3, 2, 4, 2, 5, 4];
    float[18] vb = [0, 4, 0, 0, 1, 0, 2, 2, 0, 0, 0, 0, 1, 0, 0, 4, 0, 0];
    assert(simplify(ib[], ib[], fs(vb[], 6, 3), 3, 1e-2f) == 3);
    assert(ib[0 .. 3] == [0, 5, 3]);
}
