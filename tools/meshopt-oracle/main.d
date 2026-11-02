/// Golden generator and live diff for quantize (M0) and indexing (M1).
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
        generateMesh();
        return 0;
    }
    if (cmd == "diff") {
        int quant = diff();
        if (quant)
            return quant;
        return diffMesh(randomCount(args));
    }
    if (cmd == "exhaustive") {
        version (MeshoptExhaustive)
            return exhaustive();
        else {
            stderr.writeln("rebuild the oracle with -version=MeshoptExhaustive");
            return 1;
        }
    }
    stderr.writeln("usage: meshopt-oracle [generate|diff|exhaustive] [--random=N]");
    return 2;
}

private int randomCount(string[] args) {
    import std.conv : to;
    int n = 256;
    foreach (a; args) {
        if (a.length > 9 && a[0 .. 9] == "--random=")
            n = to!int(a[9 .. $]);
    }
    return n;
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

// --- M1 index goldens and live diff ---
// Payload layouts are matched by the readers in `engine.meshopt.indexgen`.

private int meshMisses;

private void meshMiss(string what) {
    writefln("mismatch %s", what);
    meshMisses++;
}

private struct MeshCase {
    string name;
    float[] pos;
    float[] uv;
    uint[] idx;
}

private void eachCorpus(alias fn)() {
    import engine.meshopt.corpus;

    void one(string name, ProcMesh m) {
        fn(MeshCase(name, m.positions, m.uvs, m.indices));
    }

    one("grid2x3", makeGrid(2, 3));
    one("sphere8x4", makeSphere(8, 4));
    one("torus8x4", makeTorus(8, 4, 2, 0.4f));
    one("seam", makeSeam());
    one("soup", makeSoup());
    one("grid16", makeGrid(16, 16));
    fn(loadPirate());
    MeshCase z;
    z.name = "negzero";
    z.pos = [0, 0, 0, 0, -0.0f, 0, 1, 0, 0];
    z.idx = [0, 1, 2];
    fn(z);
}

private MeshCase loadPirate() @trusted {
    import std.conv : to;
    import std.file : readText;
    import std.string : split, splitLines, strip;

    MeshCase m;
    m.name = "pirate";
    foreach (raw; readText("assets/models/meshopt/pirate.obj").splitLines) {
        string line = raw.strip;
        if (line.length < 3 || line[0] == '#')
            continue;
        if (line.length >= 2 && line[0] == 'v' && line[1] == ' ') {
            auto p = line.split;
            m.pos ~= to!float(p[1]);
            m.pos ~= to!float(p[2]);
            m.pos ~= to!float(p[3]);
        } else if (line.length >= 2 && line[0] == 'f' && line[1] == ' ') {
            auto p = line.split;
            uint[] face;
            foreach (k; 1 .. p.length) {
                auto slash = p[k].split("/");
                int id = to!int(slash[0]);
                size_t n = m.pos.length / 3;
                uint u = id < 0 ? cast(uint)(n + id) : cast(uint)(id - 1);
                face ~= u;
            }
            if (face.length >= 3) {
                foreach (k; 1 .. face.length - 1) {
                    m.idx ~= face[0];
                    m.idx ~= face[k];
                    m.idx ~= face[k + 1];
                }
            }
        }
    }
    return m;
}

private bool sameBytes(const(ubyte)[] a, const(ubyte)[] b) {
    return a.length == b.length && a == b;
}

private bool sameU(const(uint)[] a, const(uint)[] b) {
    return a.length == b.length && a == b;
}

private ubyte[] floatBytes(const(float)[] data) @trusted {
    ubyte[] o = new ubyte[data.length * 4];
    if (data.length)
        o[] = (cast(const(ubyte)*) data.ptr)[0 .. o.length];
    return o;
}

private void diffMeshCase(MeshCase c) {
    import engine.meshopt.indexgen;
    import engine.meshopt.types : FloatStream, VertexStream;

    size_t vc = c.pos.length / 3;
    const(ubyte)[] raw = floatBytes(c.pos);
    diffRemap(c.name, c.idx, raw, vc, 12, 12);
    uint[] none;
    diffRemap(c.name ~ ".unindexed", none, raw, vc, 12, 12);
    if (c.idx.length)
        diffIndexOps(c.name, c.idx, c.pos, c.uv, 3);
}

private void diffRemap(string tag, const(uint)[] indices, const(ubyte)[] raw, size_t vc, size_t size, size_t stride) {
    import engine.meshopt.indexgen;

    uint[] dremap = new uint[vc];
    uint[] cremap = new uint[vc];
    size_t dn = generateVertexRemap(dremap, indices, raw, size);
    size_t cn = refGenerateVertexRemap(cremap, indices, raw, vc, size);
    if (dn != cn || !sameU(dremap, cremap)) {
        meshMiss("generateVertexRemap " ~ tag);
        return;
    }
    if (meshMisses > 8)
        return;
    ubyte[] dz = new ubyte[vc * size];
    ubyte[] cz = new ubyte[vc * size];
    remapVertexBuffer(dz, raw, vc, size, dremap);
    refRemapVertexBuffer(cz, raw, vc, size, cremap);
    if (!sameBytes(dz, cz))
        meshMiss("remapVertexBuffer " ~ tag);
    if (vc > 0 && size == stride) {
        ubyte[] di = raw.dup;
        ubyte[] ci = raw.dup;
        remapVertexBuffer(di, di, vc, size, dremap);
        refRemapVertexBuffer(ci, ci, vc, size, cremap);
        if (!sameBytes(di, ci))
            meshMiss("remapVertexBuffer.inplace " ~ tag);
    }
    size_t ic = indices.length ? indices.length : vc;
    uint[] di = new uint[ic];
    uint[] ci = new uint[ic];
    remapIndexBuffer(di, indices, dremap);
    refRemapIndexBuffer(ci, indices, cremap);
    if (!sameU(di, ci))
        meshMiss("remapIndexBuffer " ~ tag);
}

private void diffIndexOps(string tag, const(uint)[] indices, const(float)[] pos, const(float)[] uv, size_t strideFloats) {
    import engine.meshopt.indexgen;
    import engine.meshopt.types : FloatStream, VertexStream;

    size_t vc = pos.length / strideFloats;
    FloatStream fs;
    fs.strideFloats = strideFloats;
    fs.count = vc;
    if (vc)
        fs.address = floatAddr(pos);

    uint[] dremap = new uint[vc];
    uint[] cremap = new uint[vc];
    size_t dn = generateVertexRemapCustom(dremap, indices, fs);
    size_t cn = refGenerateVertexRemapCustom(cremap, indices, pos, vc, strideFloats * 4, null);
    if (dn != cn || !sameU(dremap, cremap))
        meshMiss("generateVertexRemapCustom " ~ tag);

    static bool no(uint, uint) {
        return false;
    }

    dn = generateVertexRemapCustom!no(dremap, indices, fs);
    cn = refGenerateVertexRemapCustom(cremap, indices, pos, vc, strideFloats * 4, &meshoptOraclePredFalse);
    if (dn != cn || !sameU(dremap, cremap))
        meshMiss("generateVertexRemapCustom.reject " ~ tag);

    if (uv.length == vc * 2) {
        VertexStream[2] streams;
        ulong p = floatAddr(pos);
        ulong u = floatAddr(uv);
        streams[0] = VertexStream(p, 12, 12);
        streams[1] = VertexStream(u, 8, 8);
        RefStream[2] cs;
        cs[0] = refStream(pos, 12, 12);
        cs[1] = refStream(uv, 8, 8);
        dn = generateVertexRemapMulti(dremap, indices, streams[]);
        cn = refGenerateVertexRemapMulti(cremap, indices, vc, cs[]);
        if (dn != cn || !sameU(dremap, cremap))
            meshMiss("generateVertexRemapMulti " ~ tag);
        uint[] dm = new uint[indices.length];
        uint[] cm = new uint[indices.length];
        size_t dlen = filterIndexBufferMulti(dm, indices, vc, streams[]);
        size_t clen = refFilterIndexBufferMulti(cm, indices, vc, cs[]);
        if (dlen != clen || !sameU(dm[0 .. dlen], cm[0 .. clen]))
            meshMiss("filterIndexBufferMulti " ~ tag);
        generateShadowIndexBufferMulti(dm, indices, vc, streams[]);
        refGenerateShadowIndexBufferMulti(cm, indices, vc, cs[]);
        if (!sameU(dm, cm))
            meshMiss("generateShadowIndexBufferMulti " ~ tag);
    }

    // Split xyz into an 8-byte stream and a 4-byte stream (stride 12).
    if (strideFloats == 3 && vc) {
        VertexStream[2] streams;
        ulong p = floatAddr(pos);
        streams[0] = VertexStream(p, 8, 12);
        streams[1] = VertexStream(p + 8, 4, 12);
        RefStream[2] cs;
        cs[0] = refStream(pos, 8, 12);
        cs[1] = refStreamOff(pos, 8, 4, 12);
        dn = generateVertexRemapMulti(dremap, indices, streams[]);
        cn = refGenerateVertexRemapMulti(cremap, indices, vc, cs[]);
        if (dn != cn || !sameU(dremap, cremap))
            meshMiss("generateVertexRemapMulti.split " ~ tag);
    }

    const(ubyte)[] raw = floatBytes(pos);
    uint[] df = new uint[indices.length];
    uint[] cf = new uint[indices.length];
    size_t dlen = filterIndexBuffer(df, indices, raw, vc, 12, 12);
    size_t clen = refFilterIndexBuffer(cf, indices, raw, vc, 12, 12);
    if (dlen != clen || !sameU(df[0 .. dlen], cf[0 .. clen]))
        meshMiss("filterIndexBuffer " ~ tag);

    uint[] ds = new uint[indices.length];
    uint[] cs = new uint[indices.length];
    generateShadowIndexBuffer(ds, indices, raw, vc, 12, 12);
    refGenerateShadowIndexBuffer(cs, indices, raw, vc, 12, 12);
    if (!sameU(ds, cs))
        meshMiss("generateShadowIndexBuffer " ~ tag);

    uint[] dpos = new uint[vc];
    uint[] cpos = new uint[vc];
    generatePositionRemap(dpos, fs);
    refGeneratePositionRemap(cpos, pos, vc, strideFloats * 4);
    if (!sameU(dpos, cpos))
        meshMiss("generatePositionRemap " ~ tag);

    uint[] dadj = new uint[indices.length * 2];
    uint[] cadj = new uint[indices.length * 2];
    generateAdjacencyIndexBuffer(dadj, indices, fs);
    refGenerateAdjacencyIndexBuffer(cadj, indices, pos, vc, strideFloats * 4);
    if (!sameU(dadj, cadj))
        meshMiss("generateAdjacencyIndexBuffer " ~ tag);

    uint[] dtess = new uint[indices.length * 4];
    uint[] ctess = new uint[indices.length * 4];
    generateTessellationIndexBuffer(dtess, indices, fs);
    refGenerateTessellationIndexBuffer(ctess, indices, pos, vc, strideFloats * 4);
    if (!sameU(dtess, ctess))
        meshMiss("generateTessellationIndexBuffer " ~ tag);

    size_t bound = vc + indices.length / 3;
    uint[] dp = new uint[indices.length];
    uint[] cp = new uint[indices.length];
    uint[] dr = new uint[bound];
    uint[] cr = new uint[bound];
    size_t drn = generateProvokingIndexBuffer(dp, dr, indices, vc);
    size_t crn = refGenerateProvokingIndexBuffer(cp, cr, indices, vc);
    if (drn != crn || !sameU(dp, cp) || !sameU(dr[0 .. drn], cr[0 .. crn]))
        meshMiss("generateProvokingIndexBuffer " ~ tag);
}

private void diffOddStride() {
    import engine.meshopt.indexgen;

    enum size_t vc = 5;
    enum size_t size = 6;
    enum size_t stride = 7;
    ubyte[] raw = new ubyte[(vc - 1) * stride + size];
    foreach (i; 0 .. vc) {
        foreach (b; 0 .. size)
            raw[i * stride + b] = cast(ubyte)(i * 3 + b + 1);
    }
    raw[4 * stride .. 4 * stride + size] = raw[1 * stride .. 1 * stride + size];
    uint[] idx = [0, 1, 2, 2, 1, 3, 4, 1, 2, 0, 0, 1];
    uint[] df = new uint[idx.length];
    uint[] cf = new uint[idx.length];
    size_t dlen = filterIndexBuffer(df, idx, raw, vc, size, stride);
    size_t clen = refFilterIndexBuffer(cf, idx, raw, vc, size, stride);
    if (dlen != clen || !sameU(df[0 .. dlen], cf[0 .. clen]))
        meshMiss("filterIndexBuffer.stride7");
    uint[] ds = new uint[idx.length];
    uint[] cs = new uint[idx.length];
    generateShadowIndexBuffer(ds, idx, raw, vc, size, stride);
    refGenerateShadowIndexBuffer(cs, idx, raw, vc, size, stride);
    if (!sameU(ds, cs))
        meshMiss("generateShadowIndexBuffer.stride7");

    ubyte[] packed = new ubyte[vc * size];
    foreach (i; 0 .. vc)
        packed[i * size .. (i + 1) * size] = raw[i * stride .. i * stride + size];
    diffRemap("odd6", idx, packed, vc, size, size);
}

private int diffMesh(int randomN) @trusted {
    import engine.meshopt.indexgen;
    meshMisses = 0;
    eachCorpus!(c => diffMeshCase(c));
    diffOddStride();
    uint seed = 1;
    foreach (n; 0 .. randomN) {
        if (meshMisses > 8)
            break;
        uint vc = 1 + rnd(seed) % 40;
        uint tc = 1 + rnd(seed) % 24;
        float[] pos = new float[vc * 3];
        foreach (ref p; pos)
            p = (cast(int)(rnd(seed) % 2001) - 1000) * 0.05f;
        if (vc > 2) {
            uint a = rnd(seed) % vc;
            uint b = rnd(seed) % vc;
            if (a != b)
                pos[b * 3 .. b * 3 + 3] = pos[a * 3 .. a * 3 + 3].dup;
        }
        uint[] idx = new uint[tc * 3];
        foreach (ref id; idx)
            id = rnd(seed) % vc;
        if (tc > 1)
            idx[0] = idx[1];
        diffMeshCase(MeshCase(formatRand(n), pos, null, idx));
    }
    uint[0] emptyU;
    ubyte[0] emptyB;
    uint[] d0 = new uint[0];
    uint[] c0 = new uint[0];
    size_t dn = generateVertexRemap(d0, emptyU[], emptyB[], 4);
    size_t cn = refGenerateVertexRemap(c0, emptyU[], emptyB[], 0, 4);
    if (dn != cn)
        meshMiss("generateVertexRemap.empty");
    if (meshMisses) {
        writefln("diff: %s mesh mismatches", meshMisses);
        return 1;
    }
    writeln("diff: M1 index functions match the C++ oracle");
    return 0;
}

private void generateMesh() @trusted {
    meshMisses = 0;
    eachCorpus!(c => writeMeshCase(c));
    writeOdd();
    writeln("wrote tests/meshopt/golden/<index function>/*.bin");
}

private void writeMeshCase(MeshCase c) {
    import engine.meshopt.indexgen;
    import engine.meshopt.types : FloatStream, VertexStream;

    size_t vc = c.pos.length / 3;
    const(ubyte)[] raw = floatBytes(c.pos);
    writeRemap(c.name, c.idx, raw, vc, 12);
    uint[] none;
    writeRemap(c.name ~ "_unindexed", none, raw, vc, 12);
    if (c.idx.length == 0)
        return;
    writeIndexOps(c.name, c.idx, c.pos, c.uv);
}

private void writeRemap(string stem, const(uint)[] indices, const(ubyte)[] raw, size_t vc, size_t size) {
    uint[] remap = new uint[vc];
    size_t unique = refGenerateVertexRemap(remap, indices, raw, vc, size);
    ubyte[] dst = new ubyte[vc * size];
    refRemapVertexBuffer(dst, raw, vc, size, remap);
    size_t ic = indices.length ? indices.length : vc;
    uint[] outIdx = new uint[ic];
    refRemapIndexBuffer(outIdx, indices, remap);

    W w;
    w.u32(cast(uint) vc);
    w.u32(cast(uint) indices.length);
    w.u32(cast(uint) size);
    w.u32(cast(uint) unique);
    if (indices.length)
        w.u32s(indices);
    w.bytes(raw);
    w.u32s(remap);
    writeGolden("generateVertexRemap", stem, w.b);

    W wv;
    wv.u32(cast(uint) vc);
    wv.u32(cast(uint) size);
    wv.u32s(remap);
    wv.bytes(raw);
    wv.bytes(dst);
    writeGolden("remapVertexBuffer", stem, wv.b);

    W wi;
    wi.u32(cast(uint) indices.length);
    wi.u32(cast(uint) vc);
    wi.u32s(remap);
    if (indices.length)
        wi.u32s(indices);
    wi.u32s(outIdx);
    writeGolden("remapIndexBuffer", stem, wi.b);
}

private void writeIndexOps(string stem, const(uint)[] indices, const(float)[] pos, const(float)[] uv) {
    import engine.meshopt.types : VertexStream;

    size_t vc = pos.length / 3;
    const(ubyte)[] raw = floatBytes(pos);

    uint[] remap = new uint[vc];
    size_t unique = refGenerateVertexRemapCustom(remap, indices, pos, vc, 12, null);
    W wc;
    wc.u32(cast(uint) vc);
    wc.u32(cast(uint) indices.length);
    wc.u32(3);
    wc.u32(0);
    wc.u32(cast(uint) unique);
    wc.u32s(indices);
    wc.f32s(pos);
    wc.u32s(remap);
    writeGolden("generateVertexRemapCustom", stem, wc.b);

    unique = refGenerateVertexRemapCustom(remap, indices, pos, vc, 12, &meshoptOraclePredFalse);
    W wr;
    wr.u32(cast(uint) vc);
    wr.u32(cast(uint) indices.length);
    wr.u32(3);
    wr.u32(1);
    wr.u32(cast(uint) unique);
    wr.u32s(indices);
    wr.f32s(pos);
    wr.u32s(remap);
    writeGolden("generateVertexRemapCustom", stem ~ "_reject", wr.b);

    uint[] filtered = new uint[indices.length];
    size_t flen = refFilterIndexBuffer(filtered, indices, raw, vc, 12, 12);
    W wf;
    wf.u32(cast(uint) vc);
    wf.u32(cast(uint) indices.length);
    wf.u32(12);
    wf.u32(12);
    wf.u32(cast(uint) flen);
    wf.u32s(indices);
    wf.bytes(raw);
    wf.u32s(filtered[0 .. flen]);
    writeGolden("filterIndexBuffer", stem, wf.b);

    uint[] shadow = new uint[indices.length];
    refGenerateShadowIndexBuffer(shadow, indices, raw, vc, 12, 12);
    W ws;
    ws.u32(cast(uint) vc);
    ws.u32(cast(uint) indices.length);
    ws.u32(12);
    ws.u32(12);
    ws.u32s(indices);
    ws.bytes(raw);
    ws.u32s(shadow);
    writeGolden("generateShadowIndexBuffer", stem, ws.b);

    uint[] prem = new uint[vc];
    refGeneratePositionRemap(prem, pos, vc, 12);
    W wp;
    wp.u32(cast(uint) vc);
    wp.u32(3);
    wp.f32s(pos);
    wp.u32s(prem);
    writeGolden("generatePositionRemap", stem, wp.b);

    uint[] adj = new uint[indices.length * 2];
    refGenerateAdjacencyIndexBuffer(adj, indices, pos, vc, 12);
    W wa;
    wa.u32(cast(uint) vc);
    wa.u32(cast(uint) indices.length);
    wa.u32(3);
    wa.u32s(indices);
    wa.f32s(pos);
    wa.u32s(adj);
    writeGolden("generateAdjacencyIndexBuffer", stem, wa.b);

    uint[] tess = new uint[indices.length * 4];
    refGenerateTessellationIndexBuffer(tess, indices, pos, vc, 12);
    W wt;
    wt.u32(cast(uint) vc);
    wt.u32(cast(uint) indices.length);
    wt.u32(3);
    wt.u32s(indices);
    wt.f32s(pos);
    wt.u32s(tess);
    writeGolden("generateTessellationIndexBuffer", stem, wt.b);

    size_t bound = vc + indices.length / 3;
    uint[] prov = new uint[indices.length];
    uint[] reorder = new uint[bound];
    size_t rn = refGenerateProvokingIndexBuffer(prov, reorder, indices, vc);
    W wpr;
    wpr.u32(cast(uint) vc);
    wpr.u32(cast(uint) indices.length);
    wpr.u32(cast(uint) rn);
    wpr.u32s(indices);
    wpr.u32s(prov);
    wpr.u32s(reorder[0 .. rn]);
    writeGolden("generateProvokingIndexBuffer", stem, wpr.b);

    if (uv.length == vc * 2) {
        RefStream[2] cs;
        cs[0] = refStream(pos, 12, 12);
        cs[1] = refStream(uv, 8, 8);
        unique = refGenerateVertexRemapMulti(remap, indices, vc, cs[]);
        W wm;
        wm.u32(cast(uint) vc);
        wm.u32(cast(uint) indices.length);
        wm.u32(2);
        wm.u32(cast(uint) unique);
        wm.u32s(indices);
        wm.u32(12);
        wm.u32(12);
        wm.bytes(raw);
        wm.u32(8);
        wm.u32(8);
        wm.bytes(floatBytes(uv));
        wm.u32s(remap);
        writeGolden("generateVertexRemapMulti", stem, wm.b);

        size_t mlen = refFilterIndexBufferMulti(filtered, indices, vc, cs[]);
        W wfm;
        wfm.u32(cast(uint) vc);
        wfm.u32(cast(uint) indices.length);
        wfm.u32(2);
        wfm.u32(cast(uint) mlen);
        wfm.u32s(indices);
        wfm.u32(12);
        wfm.u32(12);
        wfm.bytes(raw);
        wfm.u32(8);
        wfm.u32(8);
        wfm.bytes(floatBytes(uv));
        wfm.u32s(filtered[0 .. mlen]);
        writeGolden("filterIndexBufferMulti", stem, wfm.b);

        refGenerateShadowIndexBufferMulti(shadow, indices, vc, cs[]);
        W wsm;
        wsm.u32(cast(uint) vc);
        wsm.u32(cast(uint) indices.length);
        wsm.u32(2);
        wsm.u32s(indices);
        wsm.u32(12);
        wsm.u32(12);
        wsm.bytes(raw);
        wsm.u32(8);
        wsm.u32(8);
        wsm.bytes(floatBytes(uv));
        wsm.u32s(shadow);
        writeGolden("generateShadowIndexBufferMulti", stem, wsm.b);
    }
}

private void writeOdd() {
    enum size_t vc = 5;
    enum size_t size = 6;
    enum size_t stride = 7;
    ubyte[] raw = new ubyte[(vc - 1) * stride + size];
    foreach (i; 0 .. vc) {
        foreach (b; 0 .. size)
            raw[i * stride + b] = cast(ubyte)(i * 3 + b + 1);
    }
    raw[4 * stride .. 4 * stride + size] = raw[1 * stride .. 1 * stride + size];
    uint[] idx = [0, 1, 2, 2, 1, 3, 4, 1, 2, 0, 0, 1];
    uint[] filtered = new uint[idx.length];
    size_t flen = refFilterIndexBuffer(filtered, idx, raw, vc, size, stride);
    W wf;
    wf.u32(cast(uint) vc);
    wf.u32(cast(uint) idx.length);
    wf.u32(cast(uint) size);
    wf.u32(cast(uint) stride);
    wf.u32(cast(uint) flen);
    wf.u32s(idx);
    wf.bytes(raw);
    wf.u32s(filtered[0 .. flen]);
    writeGolden("filterIndexBuffer", "stride7", wf.b);
    uint[] shadow = new uint[idx.length];
    refGenerateShadowIndexBuffer(shadow, idx, raw, vc, size, stride);
    W ws;
    ws.u32(cast(uint) vc);
    ws.u32(cast(uint) idx.length);
    ws.u32(cast(uint) size);
    ws.u32(cast(uint) stride);
    ws.u32s(idx);
    ws.bytes(raw);
    ws.u32s(shadow);
    writeGolden("generateShadowIndexBuffer", "stride7", ws.b);

    ubyte[] packed = new ubyte[vc * size];
    foreach (i; 0 .. vc)
        packed[i * size .. (i + 1) * size] = raw[i * stride .. i * stride + size];
    writeRemap("odd6", idx, packed, vc, size);
}

private void writeGolden(string functionName, string stem, ubyte[] payload) {
    ubyte[] buf;
    writeHeader(buf, functionName, 0);
    // params hash covers the file stem so two meshes of one function differ.
    storeU32(buf, 44, goldenParamsHash(functionName ~ "/" ~ stem));
    storeU32(buf, 48, cast(uint) payload.length);
    buf ~= payload;
    writeFile("tests/meshopt/golden/" ~ functionName ~ "/" ~ stem ~ ".bin", buf);
}

private struct W {
    ubyte[] b;
    void u32(uint v) {
        b ~= cast(ubyte) v;
        b ~= cast(ubyte)(v >> 8);
        b ~= cast(ubyte)(v >> 16);
        b ~= cast(ubyte)(v >> 24);
    }

    void u32s(const(uint)[] xs) {
        foreach (x; xs)
            u32(x);
    }

    void bytes(const(ubyte)[] xs) {
        b ~= xs;
    }

    void f32s(const(float)[] xs) {
        foreach (f; xs)
            u32(floatBits(f));
    }
}

private uint rnd(ref uint s) {
    s = s * 1664525u + 1013904223u;
    return s;
}

private string formatRand(int n) {
    import std.conv : to;
    return "r" ~ to!string(n);
}

private ulong floatAddr(scope const(float)[] data) @trusted {
    return data.length ? cast(ulong) data.ptr : 0;
}

private RefStream refStreamOff(scope const(float)[] data, size_t off, size_t size, size_t stride) @trusted {
    RefStream s;
    s.data = data.length ? cast(const(void)*)(cast(const(ubyte)*) data.ptr + off) : null;
    s.size = size;
    s.stride = stride;
    return s;
}

private RefStream refStream(scope const(float)[] data, size_t size, size_t stride) @trusted {
    RefStream s;
    s.data = data.length ? data.ptr : null;
    s.size = size;
    s.stride = stride;
    return s;
}
