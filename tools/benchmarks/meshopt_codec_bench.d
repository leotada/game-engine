// Decode throughput for the meshopt codecs. Not tools/benchmarks/meshopt_bench.d.
// C++ times come from libmeshoptimizer_ref (clang -O2, SIMD filters + SSSE3 vertex).
module meshopt_codec_bench;

import core.sys.posix.time : CLOCK_MONOTONIC, clock_gettime, timespec;
import std.stdio;

import engine.meshopt.codec.filter;
import engine.meshopt.codec.index;
import engine.meshopt.codec.vertex;

version (MeshoptCodecBench)
extern (C) nothrow @nogc {
    size_t meshopt_encodeVertexBufferLevel(ubyte*, size_t, const(void)*, size_t, size_t, int, int);
    int meshopt_decodeVertexBuffer(void*, size_t, size_t, const(ubyte)*, size_t);
    size_t meshopt_encodeIndexBuffer(ubyte*, size_t, const(uint)*, size_t);
    int meshopt_decodeIndexBuffer(void*, size_t, size_t, const(ubyte)*, size_t);
    void meshopt_encodeIndexVersion(int);
    void meshopt_decodeFilterOct(void*, size_t, size_t);
}

private double now() nothrow @nogc @trusted {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

private double bestOf(int n, double delegate() run) {
    double best = 0;
    foreach (_; 0 .. n) {
        double g = run();
        if (g > best)
            best = g;
    }
    return best;
}

void main() {
    enum N = 1_000_000;
    enum VS = 32;
    ubyte[] raw = new ubyte[N * VS];
    foreach (i, ref b; raw)
        b = cast(ubyte)(i * 17);
    ubyte[] enc = new ubyte[encodeVertexBufferBound(N, VS)];
    size_t vn = encodeVertexBufferLevel(enc, raw, N, VS, 2, 1);
    enc = enc[0 .. vn];
    ubyte[] vout = new ubyte[N * VS];
    double dVert = bestOf(8, () {
        double t0 = now();
        if (decodeVertexBuffer(vout, N, VS, enc))
            return 0;
        return double(N * VS) / 1e9 / (now() - t0);
    });

    uint[] idx = new uint[N * 3];
    foreach (i; 0 .. N) {
        idx[i * 3] = cast(uint)(i % 1000);
        idx[i * 3 + 1] = cast(uint)((i + 1) % 1000);
        idx[i * 3 + 2] = cast(uint)((i + 2) % 1000);
    }
    ubyte[] ienc = new ubyte[encodeIndexBufferBound(idx.length, 1000)];
    size_t in_ = encodeIndexBuffer(ienc, idx, 1);
    ienc = ienc[0 .. in_];
    uint[] iout = new uint[idx.length];
    double dIdx = bestOf(8, () {
        double t0 = now();
        if (decodeIndexBuffer(iout, ienc))
            return 0;
        return double(idx.length * 4) / 1e9 / (now() - t0);
    });

    enum C = 1_000_000;
    ubyte[] oct = new ubyte[C * 4];
    double dOct = bestOf(6, () {
        double t0 = now();
        decodeFilterOct(oct, C, 4);
        return double(oct.length) / 1e9 / (now() - t0);
    });

    writefln("decodeVertexBuffer  D %.3f GB/s   bytes %s", dVert, N * VS);
    writefln("decodeIndexBuffer   D %.3f GB/s   bytes %s", dIdx, idx.length * 4);
    writefln("decodeFilterOct8    D %.3f GB/s   bytes %s", dOct, oct.length);

    version (MeshoptCodecBench) {
        ubyte[] cout = new ubyte[N * VS];
        double cVert = bestOf(8, () {
            double t0 = now();
            if (meshopt_decodeVertexBuffer(cout.ptr, N, VS, enc.ptr, enc.length))
                return 0;
            return double(N * VS) / 1e9 / (now() - t0);
        });
        uint[] ci = new uint[idx.length];
        meshopt_encodeIndexVersion(1);
        double cIdx = bestOf(8, () {
            double t0 = now();
            if (meshopt_decodeIndexBuffer(ci.ptr, idx.length, 4, ienc.ptr, ienc.length))
                return 0;
            return double(idx.length * 4) / 1e9 / (now() - t0);
        });
        ubyte[] co = new ubyte[C * 4];
        double cOct = bestOf(6, () {
            double t0 = now();
            meshopt_decodeFilterOct(co.ptr, C, 4);
            return double(co.length) / 1e9 / (now() - t0);
        });
        writefln("decodeVertexBuffer  C++ %.3f GB/s   D/C++ %.3f", cVert, cVert / dVert);
        writefln("decodeIndexBuffer   C++ %.3f GB/s   D/C++ %.3f", cIdx, cIdx / dIdx);
        writefln("decodeFilterOct8    C++ %.3f GB/s   C++/D %.3f  (C++ is rsqrt; D LDC x86-64 is exact sqrtps)", cOct, cOct / dOct);
    }
}
