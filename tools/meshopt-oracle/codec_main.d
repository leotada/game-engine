// Differential oracle for the meshoptimizer codecs. Not part of the engine library.
// Build libs/libmeshoptimizer_ref.a first (tools/meshopt-oracle/build_ref.sh).
//   codec-oracle diff [--random=N]
//   codec-oracle generate
module codec_main;

import std.conv : to;
import std.file : mkdirRecurse, write;
import std.format : format;
import std.stdio;
import std.string : startsWith;

import engine.meshopt.codec.filter;
import engine.meshopt.codec.index;
import engine.meshopt.codec.vertex;
import engine.meshopt.types : EncodeExpMode;

version (MeshoptOracle)
extern (C) nothrow @nogc {
    size_t meshopt_encodeIndexBuffer(ubyte* buffer, size_t buffer_size, const(uint)* indices, size_t index_count);
    size_t meshopt_encodeIndexBufferBound(size_t index_count, size_t vertex_count);
    void meshopt_encodeIndexVersion(int version_);
    int meshopt_decodeIndexBuffer(void* destination, size_t index_count, size_t index_size, const(ubyte)* buffer, size_t buffer_size);
    int meshopt_decodeIndexVersion(const(ubyte)* buffer, size_t buffer_size);
    size_t meshopt_encodeIndexSequence(ubyte* buffer, size_t buffer_size, const(uint)* indices, size_t index_count);
    size_t meshopt_encodeIndexSequenceBound(size_t index_count, size_t vertex_count);
    int meshopt_decodeIndexSequence(void* destination, size_t index_count, size_t index_size, const(ubyte)* buffer, size_t buffer_size);
    size_t meshopt_encodeVertexBufferLevel(ubyte* buffer, size_t buffer_size, const(void)* vertices, size_t vertex_count, size_t vertex_size, int level, int version_);
    size_t meshopt_encodeVertexBufferBound(size_t vertex_count, size_t vertex_size);
    int meshopt_decodeVertexBuffer(void* destination, size_t vertex_count, size_t vertex_size, const(ubyte)* buffer, size_t buffer_size);
    int meshopt_decodeVertexVersion(const(ubyte)* buffer, size_t buffer_size);
    void meshopt_decodeFilterOct(void* buffer, size_t count, size_t stride);
    void meshopt_decodeFilterQuat(void* buffer, size_t count, size_t stride);
    void meshopt_decodeFilterExp(void* buffer, size_t count, size_t stride);
    void meshopt_decodeFilterColor(void* buffer, size_t count, size_t stride);
    void meshopt_encodeFilterOct(void* destination, size_t count, size_t stride, int bits, const(float)* data);
    void meshopt_encodeFilterQuat(void* destination, size_t count, size_t stride, int bits, const(float)* data);
    void meshopt_encodeFilterExp(void* destination, size_t count, size_t stride, int bits, const(float)* data, int mode);
    void meshopt_encodeFilterColor(void* destination, size_t count, size_t stride, int bits, const(float)* data);
}

private uint rng = 0xC0FFEE;

uint rnd() {
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
}

void reseed(uint s) {
    rng = s ? s : 1;
}

int failures;

void fail(string what, string detail) {
    stderr.writefln("FAIL %s: %s", what, detail);
    failures++;
    if (failures > 8) {
        stderr.writeln("too many failures");
        import core.stdc.stdlib : exit;
        exit(1);
    }
}

string hexPrefix(const(ubyte)[] b, size_t n) {
    if (n > b.length)
        n = b.length;
    if (n > 32)
        n = 32;
    string s;
    foreach (i; 0 .. n) {
        if (i)
            s ~= " ";
        s ~= format("%02x", b[i]);
    }
    return s;
}

void putU32(ref ubyte[] o, uint v) {
    o ~= cast(ubyte) v;
    o ~= cast(ubyte)(v >> 8);
    o ~= cast(ubyte)(v >> 16);
    o ~= cast(ubyte)(v >> 24);
}

void putI32(ref ubyte[] o, int v) {
    putU32(o, cast(uint) v);
}

void putBytes(ref ubyte[] o, const(ubyte)[] b) {
    putU32(o, cast(uint) b.length);
    o ~= b;
}

// kind, a, b, c, count, input, encoded, decoded
void pushCase(ref ubyte[] o, ref uint count, uint kind, int a, int b, uint c, uint n,
        const(ubyte)[] input, const(ubyte)[] encoded, const(ubyte)[] decoded) {
    putU32(o, kind);
    putI32(o, a);
    putI32(o, b);
    putU32(o, c);
    putU32(o, n);
    putBytes(o, input);
    putBytes(o, encoded);
    putBytes(o, decoded);
    count++;
}

bool generating;
ubyte[] gIndex, gVertex, gFilter;
uint nIndex, nVertex, nFilter;

extern (C) size_t cEncodeIndex(ubyte[] dst, const(uint)[] idx, int ver) {
    meshopt_encodeIndexVersion(ver);
    return meshopt_encodeIndexBuffer(dst.ptr, dst.length, idx.ptr, idx.length);
}

extern (C) int cDecodeIndex(void* dst, size_t count, size_t size, const(ubyte)[] enc) {
    return meshopt_decodeIndexBuffer(dst, count, size, enc.ptr, enc.length);
}

extern (C) size_t cEncodeSeq(ubyte[] dst, const(uint)[] idx, int ver) {
    meshopt_encodeIndexVersion(ver);
    return meshopt_encodeIndexSequence(dst.ptr, dst.length, idx.ptr, idx.length);
}

extern (C) int cDecodeSeq(void* dst, size_t count, size_t size, const(ubyte)[] enc) {
    return meshopt_decodeIndexSequence(dst, count, size, enc.ptr, enc.length);
}

extern (C) size_t cEncodeVert(ubyte[] dst, const(ubyte)[] verts, size_t count, size_t size, int level, int ver) {
    return meshopt_encodeVertexBufferLevel(dst.ptr, dst.length, verts.ptr, count, size, level, ver);
}

extern (C) int cDecodeVert(ubyte[] dst, size_t count, size_t size, const(ubyte)[] enc) {
    return meshopt_decodeVertexBuffer(dst.ptr, count, size, enc.ptr, enc.length);
}

void checkBytes(string what, const(ubyte)[] a, const(ubyte)[] b) {
    if (a.length != b.length || a != b)
        fail(what, format("len %s vs %s a[%s] b[%s]", a.length, b.length, hexPrefix(a, 24), hexPrefix(b, 24)));
}

void checkIndex(const(uint)[] idx, int ver, size_t vertexCount, string tag) {
    size_t boundD = encodeIndexBufferBound(idx.length, vertexCount);
    size_t boundC = meshopt_encodeIndexBufferBound(idx.length, vertexCount);
    if (boundD != boundC)
        fail("index bound " ~ tag, format("%s vs %s", boundD, boundC));
    ubyte[] encD = new ubyte[boundD + 64];
    ubyte[] encC = new ubyte[boundC + 64];
    size_t nD = encodeIndexBuffer(encD, idx, ver);
    size_t nC = cEncodeIndex(encC, idx, ver);
    if (nD == 0 || nC == 0)
        return fail("index encode empty " ~ tag, format("D=%s C=%s", nD, nC));
    checkBytes("index encode " ~ tag, encD[0 .. nD], encC[0 .. nC]);
    if (failures && encD[0 .. nD] != encC[0 .. nC])
        return;
    int verD = decodeIndexVersion(encC[0 .. nC]);
    int verC = meshopt_decodeIndexVersion(encC.ptr, nC);
    if (verD != verC)
        fail("index version " ~ tag, format("%s vs %s", verD, verC));
    uint[] decD = new uint[idx.length];
    uint[] decC = new uint[idx.length];
    int rcD = decodeIndexBuffer(decD, encC[0 .. nC]);
    int rcC = cDecodeIndex(decC.ptr, idx.length, 4, encC[0 .. nC]);
    if (rcD != rcC)
        return fail("index rc " ~ tag, format("%s vs %s", rcD, rcC));
    if (rcD == 0 && decD != decC)
        fail("index decode " ~ tag, "mismatch");
    // D bytes decoded by C++.
    uint[] decCross = new uint[idx.length];
    int rcX = cDecodeIndex(decCross.ptr, idx.length, 4, encD[0 .. nD]);
    if (rcX != 0 || decCross != decD)
        fail("index cross " ~ tag, format("rc=%s", rcX));
    if (generating && failures == 0)
        pushCase(gIndex, nIndex, 1, ver, 0, 4, cast(uint) idx.length, cast(ubyte[]) idx, encC[0 .. nC], cast(ubyte[]) decC);

    if (vertexCount <= 65536) {
        ushort[] sidx = new ushort[idx.length];
        bool fit = true;
        foreach (i, v; idx) {
            if (v > 65535) {
                fit = false;
                break;
            }
            sidx[i] = cast(ushort) v;
        }
        if (fit) {
            ubyte[] encS = new ubyte[boundD + 64];
            size_t nS = encodeIndexBuffer(encS, sidx, ver);
            checkBytes("index ushort encode " ~ tag, encS[0 .. nS], encC[0 .. nC]);
            ushort[] decS = new ushort[idx.length];
            assert(decodeIndexBuffer(decS, encC[0 .. nC]) == 0);
        }
    }
}

void checkSeq(const(uint)[] idx, int ver, size_t vertexCount, string tag) {
    size_t boundD = encodeIndexSequenceBound(idx.length, vertexCount);
    size_t boundC = meshopt_encodeIndexSequenceBound(idx.length, vertexCount);
    if (boundD != boundC)
        fail("seq bound " ~ tag, format("%s vs %s", boundD, boundC));
    ubyte[] encD = new ubyte[boundD + 16];
    ubyte[] encC = new ubyte[boundC + 16];
    size_t nD = encodeIndexSequence(encD, idx, ver);
    size_t nC = cEncodeSeq(encC, idx, ver);
    if (nD == 0 || nC == 0)
        return fail("seq encode empty " ~ tag, format("D=%s C=%s", nD, nC));
    checkBytes("seq encode " ~ tag, encD[0 .. nD], encC[0 .. nC]);
    uint[] decD = new uint[idx.length];
    uint[] decC = new uint[idx.length];
    int rcD = decodeIndexSequence(decD, encC[0 .. nC]);
    int rcC = cDecodeSeq(decC.ptr, idx.length, 4, encC[0 .. nC]);
    if (rcD != rcC || (rcD == 0 && decD != decC))
        fail("seq decode " ~ tag, format("rc %s/%s", rcD, rcC));
    if (generating && failures == 0)
        pushCase(gIndex, nIndex, 2, ver, 0, 4, cast(uint) idx.length, cast(ubyte[]) idx, encC[0 .. nC], cast(ubyte[]) decC);
}

void checkVertex(const(ubyte)[] verts, size_t count, size_t size, int level, int ver, string tag) {
    size_t boundD = encodeVertexBufferBound(count, size);
    size_t boundC = meshopt_encodeVertexBufferBound(count, size);
    if (boundD != boundC)
        fail("vert bound " ~ tag, format("%s vs %s", boundD, boundC));
    ubyte[] encD = new ubyte[boundD];
    ubyte[] encC = new ubyte[boundC];
    size_t nD = encodeVertexBufferLevel(encD, verts, count, size, level, ver);
    size_t nC = cEncodeVert(encC, verts, count, size, level, ver);
    if (nD == 0 || nC == 0)
        return fail("vert encode empty " ~ tag, format("D=%s C=%s level=%s ver=%s", nD, nC, level, ver));
    if (nD != nC || encD[0 .. nD] != encC[0 .. nC])
        return fail("vert encode " ~ tag, format("len %s vs %s D[%s] C[%s]", nD, nC, hexPrefix(encD, 24), hexPrefix(encC, 24)));
    int verD = decodeVertexVersion(encC[0 .. nC]);
    int verC = meshopt_decodeVertexVersion(encC.ptr, nC);
    if (verD != verC)
        fail("vert version " ~ tag, format("%s vs %s", verD, verC));
    ubyte[] decD = new ubyte[count * size];
    ubyte[] decC = new ubyte[count * size];
    int rcD = decodeVertexBuffer(decD, count, size, encC[0 .. nC]);
    int rcC = cDecodeVert(decC, count, size, encC[0 .. nC]);
    if (rcD != rcC || decD != decC)
        return fail("vert decode " ~ tag, format("rc %s/%s", rcD, rcC));
    ubyte[] decX = new ubyte[count * size];
    int rcX = cDecodeVert(decX, count, size, encD[0 .. nD]);
    if (rcX != 0 || decX != verts[0 .. count * size])
        fail("vert cross " ~ tag, format("rc=%s", rcX));
    if (generating && failures == 0)
        pushCase(gVertex, nVertex, 3, ver, level, cast(uint) size, cast(uint) count, verts[0 .. count * size], encC[0 .. nC], decC);
}

void checkFilterOct(const(float)[] data, size_t count, size_t stride, int bits, string tag) {
    ubyte[] dD = new ubyte[count * stride];
    ubyte[] dC = new ubyte[count * stride];
    encodeFilterOct(dD, count, stride, bits, data);
    meshopt_encodeFilterOct(dC.ptr, count, stride, bits, data.ptr);
    checkBytes("oct encode " ~ tag, dD, dC);
    ubyte[] backD = dC.dup;
    ubyte[] backC = dC.dup;
    decodeFilterOct(backD, count, stride);
    meshopt_decodeFilterOct(backC.ptr, count, stride);
    checkBytes("oct decode " ~ tag, backD, backC);
    if (generating && failures == 0)
        pushCase(gFilter, nFilter, 4, bits, cast(int) stride, cast(uint) stride, cast(uint) count,
                cast(ubyte[]) data, dC, backC);
}

void checkFilterQuat(const(float)[] data, size_t count, int bits, string tag) {
    ubyte[] dD = new ubyte[count * 8];
    ubyte[] dC = new ubyte[count * 8];
    encodeFilterQuat(dD, count, 8, bits, data);
    meshopt_encodeFilterQuat(dC.ptr, count, 8, bits, data.ptr);
    checkBytes("quat encode " ~ tag, dD, dC);
    ubyte[] backD = dC.dup;
    ubyte[] backC = dC.dup;
    decodeFilterQuat(backD, count, 8);
    meshopt_decodeFilterQuat(backC.ptr, count, 8);
    checkBytes("quat decode " ~ tag, backD, backC);
    if (generating && failures == 0)
        pushCase(gFilter, nFilter, 5, bits, 8, 8, cast(uint) count, cast(ubyte[]) data, dC, backC);
}

void checkFilterExp(const(float)[] data, size_t count, size_t stride, int bits, EncodeExpMode mode, string tag) {
    ubyte[] dD = new ubyte[count * stride];
    ubyte[] dC = new ubyte[count * stride];
    encodeFilterExp(dD, count, stride, bits, data, mode);
    meshopt_encodeFilterExp(dC.ptr, count, stride, bits, data.ptr, cast(int) mode);
    checkBytes("exp encode " ~ tag, dD, dC);
    ubyte[] backD = dC.dup;
    ubyte[] backC = dC.dup;
    decodeFilterExp(backD, count, stride);
    meshopt_decodeFilterExp(backC.ptr, count, stride);
    checkBytes("exp decode " ~ tag, backD, backC);
    if (generating && failures == 0)
        pushCase(gFilter, nFilter, 6, bits, cast(int) mode, cast(uint) stride, cast(uint) count,
                cast(ubyte[]) data, dC, backC);
}

void checkFilterColor(const(float)[] data, size_t count, size_t stride, int bits, string tag) {
    ubyte[] dD = new ubyte[count * stride];
    ubyte[] dC = new ubyte[count * stride];
    encodeFilterColor(dD, count, stride, bits, data);
    meshopt_encodeFilterColor(dC.ptr, count, stride, bits, data.ptr);
    checkBytes("color encode " ~ tag, dD, dC);
    ubyte[] backD = dC.dup;
    ubyte[] backC = dC.dup;
    decodeFilterColor(backD, count, stride);
    meshopt_decodeFilterColor(backC.ptr, count, stride);
    checkBytes("color decode " ~ tag, backD, backC);
    if (generating && failures == 0)
        pushCase(gFilter, nFilter, 7, bits, cast(int) stride, cast(uint) stride, cast(uint) count,
                cast(ubyte[]) data, dC, backC);
}

void checkErrors() {
    ubyte[8] junk = [0, 1, 2, 3, 4, 5, 6, 7];
    uint[3] tri;
    int rdJunk = decodeIndexBuffer(tri[], junk[]);
    int rc = cDecodeIndex(tri.ptr, 3, 4, junk[]);
    if (rdJunk != rc)
        fail("err index", format("%s vs %s", rdJunk, rc));
    ubyte[1] one = [0xe1];
    int rdShort = decodeIndexBuffer(tri[], one[]);
    rc = cDecodeIndex(tri.ptr, 3, 4, one[]);
    if (rdShort != rc)
        fail("err index short", format("%s vs %s", rdShort, rc));

    ubyte[16] vjunk;
    foreach (i, ref b; vjunk)
        b = cast(ubyte) i;
    ubyte[64] dest;
    int rdVert = decodeVertexBuffer(dest[], 4, 4, vjunk[]);
    rc = cDecodeVert(dest[], 4, 4, vjunk[]);
    if (rdVert != rc)
        fail("err vert", format("%s vs %s", rdVert, rc));
    if (generating) {
        pushCase(gIndex, nIndex, 8, rdJunk, 0, 4, 3, junk[], null, null);
        pushCase(gIndex, nIndex, 8, rdShort, 0, 4, 3, one[], null, null);
        pushCase(gVertex, nVertex, 9, rdVert, 0, 4, 4, vjunk[], null, null);
    }
}

uint[] makeTris(size_t tris, size_t verts) {
    uint[] idx = new uint[tris * 3];
    foreach (i, ref v; idx)
        v = rnd() % cast(uint)(verts ? verts : 1);
    return idx;
}

void corpus(int randomExtra) {
    // Structured index cases.
    uint[][5] fixed = [
        cast(uint[])[0, 1, 2],
        cast(uint[])[0, 1, 2, 2, 1, 3],
        cast(uint[])[0, 1, 2, 1, 2, 3, 2, 3, 4, 3, 4, 5],
        cast(uint[])[0, 1, 2, 2, 1, 3, 0, 1, 2, 2, 1, 4],
        cast(uint[])[0, 0, 0, 1, 1, 1, 5, 5, 5],
    ];
    foreach (ver; 0 .. 2) {
        foreach (i, idx; fixed) {
            checkIndex(idx, ver, 16, format("fix%s.v%s", i, ver));
            checkSeq(idx, ver, 16, format("sfix%s.v%s", i, ver));
        }
        uint[] hi = [0, 1, 2, 40000, 40001, 40002, 100000, 1, 2];
        checkIndex(hi, ver, 100001, format("hi.v%s", ver));
        checkSeq(hi, ver, 100001, format("shi.v%s", ver));
        uint[] wrap = [0, uint.max, uint.max - 1, 1, 2, uint.max];
        checkSeq(wrap, ver, uint.max, format("wrap.v%s", ver));
        checkIndex(cast(uint[])[0, uint.max, 1], ver, uint.max, format("iwrap.v%s", ver));
    }

    reseed(1);
    int nRand = randomExtra < 32 ? 32 : randomExtra;
    foreach (k; 0 .. nRand) {
        size_t verts = 1 + rnd() % 500;
        size_t tris = 1 + rnd() % 80;
        uint[] idx = makeTris(tris, verts);
        int ver = rnd() % 2;
        checkIndex(idx, ver, verts, format("r%s", k));
        size_t seqn = 1 + rnd() % 200;
        uint[] seq = new uint[seqn];
        foreach (ref v; seq)
            v = rnd() % cast(uint) verts;
        checkSeq(seq, ver, verts, format("rs%s", k));
        if (failures)
            return;
    }

    // Vertex corpus.
    size_t[] sizes = [4, 8, 12, 16, 24, 32, 64];
    size_t[] counts = [0, 1, 3, 15, 16, 17, 31, 64, 128, 255, 256, 257];
    foreach (sz; sizes) {
        foreach (ct; counts) {
            ubyte[] raw = new ubyte[ct * sz + 8];
            foreach (i; 0 .. ct * sz)
                raw[i] = cast(ubyte)(i * 17 + sz + ct);
            foreach (ver; 0 .. 2)
                foreach (level; 0 .. 4) {
                    checkVertex(raw, ct, sz, level, ver, format("s%s.c%s.l%s.v%s", sz, ct, level, ver));
                    if (failures)
                        return;
                }
        }
    }
    reseed(2);
    int vRand = randomExtra < 16 ? 16 : randomExtra / 4;
    foreach (k; 0 .. vRand) {
        size_t sz = [4, 12, 16, 20, 32, 48][rnd() % 6];
        size_t ct = rnd() % 400;
        ubyte[] raw = new ubyte[ct * sz];
        foreach (ref b; raw)
            b = cast(ubyte) rnd();
        checkVertex(raw, ct, sz, rnd() % 4, rnd() % 2, format("vr%s", k));
        if (failures)
            return;
    }

    // Filters.
    reseed(3);
    foreach (bits; [2, 4, 8, 12, 16]) {
        foreach (stride; [4, 8]) {
            if (stride == 4 && bits > 8)
                continue;
            float[] data = new float[32 * 4];
            foreach (i; 0 .. 32) {
                float x = (cast(int)(rnd() % 2000) - 1000) / 1000.0f;
                float y = (cast(int)(rnd() % 2000) - 1000) / 1000.0f;
                float z = (cast(int)(rnd() % 2000) - 1000) / 1000.0f;
                float len = x * x + y * y + z * z;
                if (len > 0) {
                    import core.stdc.math : sqrtf;
                    float inv = 1.0f / sqrtf(len);
                    x *= inv;
                    y *= inv;
                    z *= inv;
                }
                data[i * 4 + 0] = x;
                data[i * 4 + 1] = y;
                data[i * 4 + 2] = z;
                data[i * 4 + 3] = (cast(int)(rnd() % 2000) - 1000) / 1000.0f;
            }
            checkFilterOct(data, 32, stride, bits, format("b%s.s%s", bits, stride));
            if (stride == 8 && bits >= 4)
                checkFilterQuat(data, 32, bits, format("b%s", bits));
            if (bits >= 2 && bits <= 16)
                checkFilterColor(data, 32, stride, bits, format("b%s.s%s", bits, stride));
        }
    }
    foreach (mode; 0 .. 4) {
        foreach (stride; [4, 12, 16]) {
            foreach (bits; [1, 8, 15, 24]) {
                float[] data = new float[16 * (stride / 4)];
                foreach (i, ref f; data) {
                    int mag = cast(int)(rnd() % 40) - 20;
                    f = (mag == 0) ? 0 : (mag < 0 ? -1.0f : 1.0f) * (1.0f + (rnd() % 100) / 100.0f);
                    if (i % 7 == 0)
                        f = 0;
                }
                checkFilterExp(data, 16, stride, bits, cast(EncodeExpMode) mode, format("m%s.s%s.b%s", mode, stride, bits));
                if (failures)
                    return;
            }
        }
    }
    checkErrors();
}

void writeGolden(string path, ubyte[] body, uint count) {
    ubyte[] file;
    file ~= cast(ubyte[])"MOPTCDC1";
    putU32(file, 1030);
    putU32(file, count);
    file ~= body;
    write(path, file);
    writefln("wrote %s (%s cases, %s bytes)", path, count, file.length);
}

int main(string[] args) {
    bool gen = false;
    int randomN = 64;
    foreach (a; args[1 .. $]) {
        if (a == "generate")
            gen = true;
        else if (a == "diff")
            gen = false;
        else if (a.startsWith("--random="))
            randomN = to!int(a["--random=".length .. $]);
        else {
            stderr.writefln("usage: %s diff [--random=N] | generate", args[0]);
            return 2;
        }
    }
    generating = gen;
    corpus(randomN);
    if (failures) {
        stderr.writefln("%s failure(s)", failures);
        return 1;
    }
    writeln("codec oracle: ok");
    if (gen) {
        mkdirRecurse("tests/meshopt/golden/codec");
        writeGolden("tests/meshopt/golden/codec/index.bin", gIndex, nIndex);
        writeGolden("tests/meshopt/golden/codec/vertex.bin", gVertex, nVertex);
        writeGolden("tests/meshopt/golden/codec/filter.bin", gFilter, nFilter);
    }
    return 0;
}
