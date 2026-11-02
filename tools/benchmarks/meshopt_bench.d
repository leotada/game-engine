/// M0 quantize timings and M1 index timings.
/// D-only: `dub run --config=meshopt-bench`
/// With the C++ oracle (dub ignores pragma(lib), so link the archive explicitly):
///   dmd -version=MeshoptOracle -Isource -Itools/meshopt-oracle -of=meshopt-bench \
///       source/engine/core/pod.d source/engine/meshopt/internal/bits.d \
///       source/engine/meshopt/quantize.d tools/meshopt-oracle/meshopt_oracle_capi.d \
///       tools/benchmarks/meshopt_bench.d -L-L./libs -L-lmeshoptimizer_ref -L-lstdc++
module meshopt_bench;

import engine.meshopt.analyze;
import engine.meshopt.corpus;
import engine.meshopt.indexgen;
import engine.meshopt.overdraw;
import engine.meshopt.quantize;
import engine.meshopt.stripify;
import engine.meshopt.types : FloatStream;
import engine.meshopt.vcache;
import engine.meshopt.vfetch;

import core.time : MonoTime;
import std.stdio : writeln, writefln;

version (MeshoptOracle) {
    import meshopt_oracle_capi;
    pragma(lib, "meshoptimizer_ref");
    pragma(lib, "stdc++");
}

@safe:

int main() {
    enum n = 1 << 18;
    float[] data = new float[n];
    foreach (i, ref x; data)
        x = (cast(int)(i % 20001) - 10000) * 0.01f;

    version (LDC)
        enum dCol = "D LDC (ms)";
    else
        enum dCol = "D DMD (ms)";

    version (MeshoptOracle)
        writeln("| Function | Input | C++ (ms) | ", dCol, " | ratio |");
    else
        writeln("| Function | Input | ", dCol, " |");
    version (MeshoptOracle)
        writeln("|:---|:---|---:|---:|---:|");
    else
        writeln("|:---|:---|---:|");

    row!((float f) => quantizeHalf(f), (float f) => refHalf(f))("quantizeHalf", data);
    row!((float f) => quantizeFloat(f, 12), (float f) => refFloat(f))("quantizeFloat", data);
    row!((float f) => dequantizeHalf(cast(ushort) quantizeHalf(f)), (float f) => refDehalf(f))("dequantizeHalf", data);
    row!((float f) => quantizeUnorm(f < 0 ? 0 : f > 1 ? 1 : f, 16), (float f) => refUnorm(f))("quantizeUnorm", data);
    timeIndex();
    writeln("<!-- sink ", sink, " -->");
    return 0;
}

private double[] ratios;

private void timeIndex() {
    ProcMesh grid = makeGrid(64, 64);
    ubyte[] raw = floatBytes(grid.positions);
    size_t vc = grid.positions.length / 3;
    uint[] remap = new uint[vc];
    uint[] filtered = new uint[grid.indices.length];
    uint[] shadow = new uint[grid.indices.length];
    uint[] adj = new uint[grid.indices.length * 2];
    uint[] prov = new uint[grid.indices.length];
    uint[] reorder = new uint[vc + grid.indices.length / 3];
    uint[] cache = new uint[grid.indices.length];
    uint[] fetched = grid.indices.dup;
    uint[] fetchedSrc = grid.indices.dup;
    ubyte[] fetchedVerts = new ubyte[vc * 12];
    uint[] strip = new uint[stripifyBound(grid.indices.length)];
    FloatStream fs = floatsOf(grid.positions);
    enum reps = 4;
    timeOne("generateVertexRemap", reps,
        { sink += generateVertexRemap(remap, grid.indices, raw, 12); },
        { version (MeshoptOracle) sink += refGenerateVertexRemap(remap, grid.indices, raw, vc, 12); });
    timeOne("filterIndexBuffer", reps,
        { sink += filterIndexBuffer(filtered, grid.indices, raw, vc, 12, 12); },
        { version (MeshoptOracle) sink += refFilterIndexBuffer(filtered, grid.indices, raw, vc, 12, 12); });
    timeOne("generateShadowIndexBuffer", reps,
        { generateShadowIndexBuffer(shadow, grid.indices, raw, vc, 12, 12); sink += shadow[0]; },
        { version (MeshoptOracle) { refGenerateShadowIndexBuffer(shadow, grid.indices, raw, vc, 12, 12); sink += shadow[0]; } });
    timeOne("generateAdjacencyIndexBuffer", reps,
        { generateAdjacencyIndexBuffer(adj, grid.indices, fs); sink += adj[0]; },
        { version (MeshoptOracle) { refGenerateAdjacencyIndexBuffer(adj, grid.indices, grid.positions, vc, 12); sink += adj[0]; } });
    timeOne("generateProvokingIndexBuffer", reps,
        { sink += generateProvokingIndexBuffer(prov, reorder, grid.indices, vc); },
        { version (MeshoptOracle) sink += refGenerateProvokingIndexBuffer(prov, reorder, grid.indices, vc); });
    timeOne("optimizeVertexCache", reps,
        { optimizeVertexCache(cache, grid.indices, vc); sink += cache[0]; },
        { version (MeshoptOracle) { refOptimizeVertexCache(cache, grid.indices, vc); sink += cache[0]; } });
    timeOne("optimizeVertexCacheFifo", reps,
        { optimizeVertexCacheFifo(cache, grid.indices, vc, 16); sink += cache[0]; },
        { version (MeshoptOracle) { refOptimizeVertexCacheFifo(cache, grid.indices, vc, 16); sink += cache[0]; } });
    timeOne("optimizeOverdraw", reps,
        { optimizeOverdraw(cache, grid.indices, fs, 1.05f); sink += cache[0]; },
        { version (MeshoptOracle) { refOptimizeOverdraw(cache, grid.indices, grid.positions, vc, 12, 1.05f); sink += cache[0]; } });
    timeOne("optimizeVertexFetch", reps,
        { fetched[] = fetchedSrc[]; sink += optimizeVertexFetch(fetchedVerts, fetched, raw, vc, 12); },
        { version (MeshoptOracle) { fetched[] = fetchedSrc[]; sink += refOptimizeVertexFetch(fetchedVerts, fetched, raw, vc, 12); } });
    timeOne("analyzeVertexCache", reps,
        { sink += analyzeVertexCache(grid.indices, vc).verticesTransformed; },
        { version (MeshoptOracle) sink += refAnalyzeVertexCache(grid.indices, vc, 16, 0, 0).verticesTransformed; });
    timeOne("analyzeOverdraw", 2,
        { sink += analyzeOverdraw(grid.indices, fs).pixelsShaded; },
        { version (MeshoptOracle) sink += refAnalyzeOverdraw(grid.indices, grid.positions, vc, 12).pixelsShaded; });
    timeOne("stripify", reps,
        { sink += stripify(strip, grid.indices, vc, 0); },
        { version (MeshoptOracle) sink += refStripify(strip, grid.indices, vc, 0); });
    version (MeshoptOracle) {
        if (ratios.length) {
            double logSum = 0;
            foreach (r; ratios)
                logSum += libmLog(r);
            double geo = libmExp(logSum / ratios.length);
            writefln("| geomean | grid 64 |  |  | %.2f |", geo);
        }
    }
}

private double libmLog(double x) @trusted {
    import core.stdc.math : log;
    return log(x);
}

private double libmExp(double x) @trusted {
    import core.stdc.math : exp;
    return exp(x);
}

private void timeOne(string name, int reps, void delegate() @system dFun, void delegate() @system cFun = null) @trusted {
    dFun();
    auto t0 = MonoTime.currTime;
    foreach (_; 0 .. reps)
        dFun();
    double dms = (MonoTime.currTime - t0).total!"usecs" / 1000.0 / reps;
    version (MeshoptOracle) {
        if (cFun !is null) {
            cFun();
            auto t1 = MonoTime.currTime;
            foreach (_; 0 .. reps)
                cFun();
            double cms = (MonoTime.currTime - t1).total!"usecs" / 1000.0 / reps;
            double ratio = cms == 0 ? 0 : dms / cms;
            ratios ~= ratio;
            writefln("| `%s` | grid 64 | %.3f | %.3f | %.2f |", name, cms, dms, ratio);
            return;
        }
    }
    version (MeshoptOracle)
        writefln("| `%s` | grid 64 |  | %.3f |  |", name, dms);
    else
        writefln("| `%s` | grid 64 | %.3f |", name, dms);
}

private ubyte[] floatBytes(const(float)[] data) @trusted {
    ubyte[] o = new ubyte[data.length * 4];
    if (data.length)
        o[] = (cast(const(ubyte)*) data.ptr)[0 .. o.length];
    return o;
}

private FloatStream floatsOf(const(float)[] data) @trusted {
    FloatStream s;
    s.strideFloats = 3;
    s.count = data.length / 3;
    if (data.length)
        s.address = cast(ulong) data.ptr;
    return s;
}

private ulong sink;

private void row(alias dFun, alias cFun)(string name, float[] data) {
    // Warmup.
    foreach (f; data[0 .. 1024])
        sink += absorb(dFun(f));
    auto t0 = MonoTime.currTime;
    foreach (f; data)
        sink += absorb(dFun(f));
    double dms = (MonoTime.currTime - t0).total!"usecs" / 1000.0;

    version (MeshoptOracle) {
        foreach (f; data[0 .. 1024])
            sink += absorb(cFun(f));
        auto t1 = MonoTime.currTime;
        foreach (f; data)
            sink += absorb(cFun(f));
        double cms = (MonoTime.currTime - t1).total!"usecs" / 1000.0;
        double ratio = cms == 0 ? 0 : dms / cms;
        writefln("| `%s` | %s floats | %.3f | %.3f | %.2f |", name, data.length, cms, dms, ratio);
    } else {
        writefln("| `%s` | %s floats | %.3f |", name, data.length, dms);
    }
}

private ulong absorb(ushort h) pure nothrow @nogc {
    return h;
}

private ulong absorb(float f) pure nothrow @nogc {
    import engine.meshopt.internal.bits : floatBits;
    return floatBits(f);
}

private ulong absorb(int v) pure nothrow @nogc {
    return cast(uint) v;
}

version (MeshoptOracle) {
    private ushort refHalf(float f) {
        return refQuantizeHalf(f);
    }

    private float refFloat(float f) {
        return refQuantizeFloat(f, 12);
    }

    private float refDehalf(float f) {
        return refDequantizeHalf(cast(ushort) refQuantizeHalf(f));
    }

    private int refUnorm(float f) {
        float c = f < 0 ? 0 : f > 1 ? 1 : f;
        return refQuantizeUnorm(c, 16);
    }
} else {
    private ushort refHalf(float) {
        return 0;
    }

    private float refFloat(float) {
        return 0;
    }

    private float refDehalf(float) {
        return 0;
    }

    private int refUnorm(float) {
        return 0;
    }
}
