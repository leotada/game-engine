/// Golden generator and live diff for the M0 quantize functions.
/// extern(C) entry points live in `capi.d` in this directory, not in the engine.
module meshopt_oracle;

import engine.meshopt.internal.bits : bitsFloat, floatBits;
import engine.meshopt.quantize;
import meshopt_oracle_capi;

import std.stdio : File, stderr, writeln, writefln;

@safe:

int main(string[] args) @trusted {
    string cmd = args.length > 1 ? args[1] : "generate";
    if (cmd == "generate") {
        generate();
        return 0;
    }
    if (cmd == "diff") {
        return diff();
    }
    if (cmd == "exhaustive") {
        version (MeshoptExhaustive)
            return exhaustive();
        else {
            stderr.writeln("rebuild the oracle with -version=MeshoptExhaustive");
            return 1;
        }
    }
    stderr.writeln("usage: meshopt-oracle [generate|diff|exhaustive]");
    return 2;
}

private void generate() {
    uint[] bits = sampleBits();
    writeHalf(bits);
    writeFloat(bits);
    writeDehalf(bits);
    writeNorm("quantizeUnorm", bits);
    writeNorm("quantizeSnorm", bits);
    writeExponent();
    writeln("wrote tests/meshopt/golden/*.bin");
}

private int diff() {
    uint[] bits = sampleBits();
    int mismatches;
    foreach (u; bits) {
        float f = bitsFloat(u);
        if (refQuantizeHalf(f) != quantizeHalf(f)) {
            report("quantizeHalf", u);
            if (++mismatches > 8)
                return 1;
        }
        foreach (n; [0, 1, 4, 8, 16, 23]) {
            if (floatBits(refQuantizeFloat(f, n)) != floatBits(quantizeFloat(f, n))) {
                report("quantizeFloat", u);
                if (++mismatches > 8)
                    return 1;
            }
        }
        if (floatBits(refDequantizeHalf(cast(ushort) u)) != floatBits(dequantizeHalf(cast(ushort) u))) {
            report("dequantizeHalf", u);
            if (++mismatches > 8)
                return 1;
        }
        foreach (n; [8, 10, 16]) {
            if (refQuantizeUnorm(f, n) != quantizeUnorm(f, n)
                || refQuantizeSnorm(f, n) != quantizeSnorm(f, n)) {
                report("quantizeNorm", u);
                if (++mismatches > 8)
                    return 1;
            }
        }
    }
    foreach (c; exponentCases()) {
        int got = refPositionExponent(c.minv, c.maxv, c.minExp, c.maxBits);
        int mine = computePositionExponent(c.minv, c.maxv, c.minExp, c.maxBits);
        if (got != mine) {
            writefln("mismatch computePositionExponent exp %s vs %s", got, mine);
            if (++mismatches > 8)
                return 1;
        }
    }
    if (mismatches) {
        writefln("%s mismatches", mismatches);
        return 1;
    }
    writeln("diff: quantize functions match the C++ oracle");
    return 0;
}

version (MeshoptExhaustive)
private int exhaustive() {
    import std.stdio : writefln;
    uint bits = 0;
    ulong n = 0;
    do {
        float f = bitsFloat(bits);
        if (refQuantizeHalf(f) != quantizeHalf(f)) {
            writefln("exhaustive mismatch at %08x", bits);
            return 1;
        }
        n++;
        if ((bits & 0x00ff_ffff) == 0)
            writefln("... %08x", bits);
        if (bits == uint.max)
            break;
        bits++;
    } while (true);
    writefln("exhaustive quantizeHalf: %s values match", n);
    return 0;
}

private void report(string name, uint bits) {
    writefln("mismatch %s bits %08x", name, bits);
}

private struct ExpCase {
    float[3] minv;
    float[3] maxv;
    int minExp;
    int maxBits;
}

private ExpCase[] exponentCases() {
    ExpCase[] c;
    void add(float[3] a, float[3] b, int e, int bits) {
        c ~= ExpCase(a, b, e, bits);
    }
    add([-1, 2, 10], [1, 2.5f, 20], -16, 16);
    add([-1, 2, 10], [1, 2.5f, 20], -10, 16);
    add([-3.14159265f, -2.7182818f, -1.41321356f], [3.14159265f, 2.7182818f, 1.41321356f], -16, 16);
    add([1_000_000, 0, 0], [1_000_000, 0, 0], -16, 16);
    add([-1_000_000, 0, 0], [-1_000_000, 0, 0], -16, 16);
    add([0, -1000, 0], [1e-3f, 1000, 1], -16, 16);
    add([0, 0, 0], [0, 0, 0], -16, 16);
    add([0, 0, 0], [65535, 0, 0], 0, 16);
    add([0, 0, 0], [65536, 0, 0], 0, 16);
    add([0.4f, 0, 0], [65535.5625f, 0, 0], 0, 16);
    add([-1, 0, 0], [131069, 0, 0], 0, 16);
    add([8388607, 0, 0], [8388607, 0, 0], 0, 16);
    add([8388608, 0, 0], [8388608, 0, 0], 0, 16);
    add([-8388608, 0, 0], [-8388608, 0, 0], 0, 16);
    add([1, 0, 0], [1, 0, 0], -23, 16);
    add([-1, 0, 0], [-1, 0, 0], -23, 16);
    add([0.5f, -0.5f, 2.5f], [0.5f, -0.5f, 2.5f], 0, 16);
    add([-0.5f, 0, 0], [0.5f, 0, 0], 0, 16);
    add([0, 0, 0], [2097151, 0, 0], 0, 21);
    add([8388607.5f, 0, 0], [8388607.5f, 0, 0], 0, 16);
    uint s = 7;
    foreach (_; 0 .. 64) {
        float[3] a, b;
        foreach (k; 0 .. 3) {
            s = s * 1664525u + 1013904223u;
            int mag = cast(int)(s % 2000) - 1000;
            a[k] = mag * 0.25f;
            s = s * 1664525u + 1013904223u;
            b[k] = a[k] + cast(int)(s % 500) * 0.1f;
        }
        add(a, b, -16, 16);
        add(a, b, 0, 24);
    }
    return c;
}

private uint[] sampleBits() {
    bool[uint] seen;
    uint[] out_;
    void add(uint u) {
        if (u in seen)
            return;
        seen[u] = true;
        out_ ~= u;
    }
    float[] specials = [
        0, -0.0f, 1, -1, 0.5f, -0.5f, 0.25f, 1.2345f,
        65535, -65535, 65000, -65000, 0.125f, -0.125f,
        1e-4f, -1e-4f, 1e-5f, -1e-5f, 1e-20f, -1e-20f, 1e20f, -1e20f,
        float.infinity, -float.infinity, float.nan, -float.nan,
        float.min_normal, float.epsilon, 65504, -65504,
    ];
    foreach (f; specials)
        add(floatBits(f));
    add(0x7f80_0001);
    add(0xff80_0001);
    add(0x0000_0001);
    add(0x8000_0001);
    add(0x7fc0_0000);
    add(0xffc0_0000);
    foreach (exp; 0 .. 256) {
        foreach (mant; [0u, 1, 0x7_ffff, 0x40_0000]) {
            add((exp << 23) | mant);
            add(0x8000_0000 | (exp << 23) | mant);
        }
    }
    uint s = 1;
    foreach (_; 0 .. 2048) {
        s = s * 1664525u + 1013904223u;
        add(s);
    }
    foreach (i; 0 .. 64) {
        float t = i / 63.0f;
        add(floatBits(t));
        add(floatBits(t * 2 - 1));
    }
    return out_;
}

private void writeHeader(ref ubyte[] buf, string name, uint count) {
    buf.length = 52;
    foreach (i, char c; "MOPTGLD1")
        buf[i] = cast(ubyte) c;
    storeU32(buf, 8, 1030);
    buf[12 .. 44] = 0;
    foreach (i, char c; name)
        buf[12 + i] = cast(ubyte) c;
    storeU32(buf, 44, goldenParamsHash(name));
    storeU32(buf, 48, count);
}

private void writeHalf(uint[] bits) {
    ubyte[] buf;
    writeHeader(buf, "quantizeHalf", cast(uint) bits.length);
    foreach (u; bits) {
        storeU32(buf, buf.length, u);
        storeU32(buf, buf.length, refQuantizeHalf(bitsFloat(u)));
    }
    writeFile("tests/meshopt/golden/quantizeHalf.bin", buf);
}

private void writeFloat(uint[] bits) {
    int[6] ns = [0, 1, 4, 8, 16, 23];
    ubyte[] buf;
    writeHeader(buf, "quantizeFloat", cast(uint)(bits.length * ns.length));
    foreach (u; bits) {
        foreach (n; ns) {
            storeU32(buf, buf.length, u);
            storeU32(buf, buf.length, cast(uint) n);
            storeU32(buf, buf.length, floatBits(refQuantizeFloat(bitsFloat(u), n)));
        }
    }
    writeFile("tests/meshopt/golden/quantizeFloat.bin", buf);
}

private void writeDehalf(uint[] bits) {
    ubyte[] buf;
    writeHeader(buf, "dequantizeHalf", cast(uint) bits.length);
    foreach (u; bits) {
        storeU32(buf, buf.length, u & 0xffff);
        storeU32(buf, buf.length, floatBits(refDequantizeHalf(cast(ushort) u)));
    }
    writeFile("tests/meshopt/golden/dequantizeHalf.bin", buf);
}

private void writeNorm(string name, uint[] bits) {
    int[3] ns = [8, 10, 16];
    ubyte[] buf;
    writeHeader(buf, name, cast(uint)(bits.length * ns.length));
    foreach (u; bits) {
        float f = bitsFloat(u);
        foreach (n; ns) {
            int q = name == "quantizeUnorm" ? refQuantizeUnorm(f, n) : refQuantizeSnorm(f, n);
            storeU32(buf, buf.length, u);
            storeU32(buf, buf.length, cast(uint) n);
            storeU32(buf, buf.length, cast(uint) q);
        }
    }
    writeFile("tests/meshopt/golden/" ~ name ~ ".bin", buf);
}

private void writeExponent() {
    ExpCase[] cases = exponentCases();
    ubyte[] buf;
    writeHeader(buf, "computePositionExponent", cast(uint) cases.length);
    foreach (c; cases) {
        foreach (k; 0 .. 3)
            storeU32(buf, buf.length, floatBits(c.minv[k]));
        foreach (k; 0 .. 3)
            storeU32(buf, buf.length, floatBits(c.maxv[k]));
        storeU32(buf, buf.length, cast(uint) c.minExp);
        storeU32(buf, buf.length, cast(uint) c.maxBits);
        storeU32(buf, buf.length, cast(uint) refPositionExponent(c.minv, c.maxv, c.minExp, c.maxBits));
    }
    writeFile("tests/meshopt/golden/computePositionExponent.bin", buf);
}

private void storeU32(ref ubyte[] buf, size_t at, uint v) {
    if (at + 4 > buf.length)
        buf.length = at + 4;
    buf[at] = cast(ubyte) v;
    buf[at + 1] = cast(ubyte)(v >> 8);
    buf[at + 2] = cast(ubyte)(v >> 16);
    buf[at + 3] = cast(ubyte)(v >> 24);
}

private void writeFile(string path, const(ubyte)[] buf) @trusted {
    import std.file : mkdirRecurse, exists;
    import std.path : dirName;
    string dir = dirName(path);
    if (!exists(dir))
        mkdirRecurse(dir);
    File f = File(path, "wb");
    f.rawWrite(buf);
}
