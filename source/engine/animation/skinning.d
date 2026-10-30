// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/geometry/runtime/skinning_job.cc @ 744eb9d
/// CPU skinning: blends joint matrices per vertex and transforms positions, normals and tangents.
///
/// Vertex data is read from / written to raw byte buffers with explicit strides (in bytes), so an
/// interleaved engine vertex buffer can be skinned in place of separate arrays. Upstream generates
/// 25 specialized loops with macros; here a single template is instantiated for 1..4 influences
/// (plus a dynamic count), with / without normals, tangents and inverse-transpose matrices.
module engine.animation.skinning;

import engine.animation.math.matrix;
import engine.animation.math.scalar : Vec3;
import engine.animation.math.simd;

@safe:

struct SkinningJob {
    /// Number of vertices to transform.
    int vertexCount;
    /// Joints influencing each vertex (> 0). Indices: `influencesCount` per vertex; weights:
    /// `influencesCount - 1` per vertex (the last weight is `1 - sum`).
    int influencesCount;
    const(Float4x4)[] jointMatrices;
    /// Optional, to transform normals / tangents under non-uniform scale.
    const(Float4x4)[] jointInverseTransposeMatrices;

    const(ubyte)[] jointIndices;     // ushort per index
    size_t jointIndicesStride;
    const(ubyte)[] jointWeights;     // float per weight; unused if influencesCount == 1
    size_t jointWeightsStride;

    const(ubyte)[] inPositions;      // 3 floats per vertex
    size_t inPositionsStride;
    const(ubyte)[] inNormals;        // optional
    size_t inNormalsStride;
    const(ubyte)[] inTangents;       // optional, requires normals
    size_t inTangentsStride;

    ubyte[] outPositions;
    size_t outPositionsStride;
    ubyte[] outNormals;
    size_t outNormalsStride;
    ubyte[] outTangents;
    size_t outTangentsStride;

    bool validate() const scope pure nothrow @nogc {
        if (influencesCount <= 0 || jointMatrices.length == 0 || vertexCount < 0) return false;
        immutable n1 = vertexCount > 0 ? cast(size_t) vertexCount - 1 : 0;
        immutable some = vertexCount > 0 ? 1 : 0;
        bool ok = true;
        ok &= jointIndices.length >= jointIndicesStride * n1 + ushort.sizeof * influencesCount * some;
        if (influencesCount != 1) {
            ok &= jointWeights.length >= jointWeightsStride * n1 + float.sizeof * (influencesCount - 1) * some;
        }
        ok &= inPositions.length >= inPositionsStride * n1 + float.sizeof * 3 * some;
        ok &= outPositions.length != 0 && outPositions.length >= outPositionsStride * n1 + float.sizeof * 3 * some;
        if (inNormals.length != 0) {
            ok &= inNormals.length >= inNormalsStride * n1 + float.sizeof * 3 * some;
            ok &= outNormals.length != 0 && outNormals.length >= outNormalsStride * n1 + float.sizeof * 3 * some;
            if (inTangents.length != 0) {
                ok &= inTangents.length >= inTangentsStride * n1 + float.sizeof * 3 * some;
                ok &= outTangents.length != 0 && outTangents.length >= outTangentsStride * n1 + float.sizeof * 3 * some;
            }
        } else {
            ok &= inTangents.length == 0;
        }
        return ok;
    }

    bool run() scope pure nothrow @nogc {
        if (!validate()) return false;
        if (vertexCount == 0) return true;
        immutable normals = inNormals.length != 0;
        immutable tangents = inTangents.length != 0;
        immutable it = jointInverseTransposeMatrices.length != 0 && normals;
        // Joint indices are validated lazily by bounds checks on `jointMatrices` (kept on).
        dispatch(this, normals, tangents, it);
        return true;
    }
}

private {

pure nothrow @nogc {

// Unaligned, bounds-checked scalar access into byte buffers.
float readF(const(ubyte)[] b, size_t at) @trusted {
    ubyte[4] t = b[at .. at + 4];
    return *cast(const(float)*) t.ptr;
}

ushort readU16(const(ubyte)[] b, size_t at) {
    return cast(ushort)(b[at] | (b[at + 1] << 8)); // joint indices are stored little-endian here
}

void writeF(ubyte[] b, size_t at, float v) @trusted {
    ubyte[4] t = *cast(ubyte[4]*)&v;
    b[at .. at + 4] = t[];
}

Vec3 readV3(const(ubyte)[] b, size_t at) {
    return Vec3(readF(b, at), readF(b, at + 4), readF(b, at + 8));
}

void writeV3(ubyte[] b, size_t at, Vec3 v) {
    writeF(b, at, v.x);
    writeF(b, at + 4, v.y);
    writeF(b, at + 8, v.z);
}

Float4x4 columnMultiply(const Float4x4 m, float w) {
    Float4x4 r;
    foreach (c; 0 .. 4) r.cols[c] = m.cols[c] * SimdFloat4.load1(w);
    return r;
}

Float4x4 plus(const Float4x4 a, const Float4x4 b) {
    Float4x4 r;
    foreach (c; 0 .. 4) r.cols[c] = a.cols[c] + b.cols[c];
    return r;
}

/// N = number of influences (1..4), or 0 for "dynamic" (job.influencesCount).
void skin(int N, bool normals, bool tangents, bool useIT)(ref SkinningJob job) {
    immutable count = N == 0 ? job.influencesCount : N;
    foreach (v; 0 .. cast(size_t) job.vertexCount) {
        immutable iBase = v * job.jointIndicesStride;
        immutable wBase = v * job.jointWeightsStride;
        Float4x4 transform = void;
        static if (useIT) Float4x4 itTransform = void;
        float wsum = 0;
        foreach (j; 0 .. count) {
            immutable idx = readU16(job.jointIndices, iBase + j * 2);
            immutable w = j + 1 < count ? readF(job.jointWeights, wBase + j * 4) : 1.0f - wsum;
            wsum += w;
            if (j == 0) {
                transform = columnMultiply(job.jointMatrices[idx], w);
                static if (useIT) itTransform = columnMultiply(job.jointInverseTransposeMatrices[idx], w);
            } else {
                transform = plus(transform, columnMultiply(job.jointMatrices[idx], w));
                static if (useIT) itTransform = plus(itTransform,
                    columnMultiply(job.jointInverseTransposeMatrices[idx], w));
            }
        }
        static if (useIT) alias itm = itTransform; else alias itm = transform;

        writeV3(job.outPositions, v * job.outPositionsStride,
                transformPoint(transform, readV3(job.inPositions, v * job.inPositionsStride)));
        static if (normals) {
            writeV3(job.outNormals, v * job.outNormalsStride,
                    transformVector(itm, readV3(job.inNormals, v * job.inNormalsStride)));
        }
        static if (tangents) {
            writeV3(job.outTangents, v * job.outTangentsStride,
                    transformVector(itm, readV3(job.inTangents, v * job.inTangentsStride)));
        }
    }
}

void dispatchN(int N)(ref SkinningJob job, bool normals, bool tangents, bool it) {
    if (!normals) skin!(N, false, false, false)(job);
    else if (!tangents) {
        if (it) skin!(N, true, false, true)(job); else skin!(N, true, false, false)(job);
    } else {
        if (it) skin!(N, true, true, true)(job); else skin!(N, true, true, false)(job);
    }
}

void dispatch(ref SkinningJob job, bool normals, bool tangents, bool it) {
    switch (job.influencesCount) {
        case 1: dispatchN!1(job, normals, tangents, it); break;
        case 2: dispatchN!2(job, normals, tangents, it); break;
        case 3: dispatchN!3(job, normals, tangents, it); break;
        case 4: dispatchN!4(job, normals, tangents, it); break;
        default: dispatchN!0(job, normals, tangents, it); break;
    }
}

}
}

public:

/// Views a typed slice as bytes (for filling the job's buffers).
const(ubyte)[] asBytes(T)(const(T)[] s) @trusted pure nothrow @nogc {
    return (cast(const(ubyte)*) s.ptr)[0 .. s.length * T.sizeof];
}
ubyte[] asBytes(T)(T[] s) @trusted pure nothrow @nogc {
    return (cast(ubyte*) s.ptr)[0 .. s.length * T.sizeof];
}

version (unittest) {
    import std.math : abs, sqrt;
    import std.random : Mt19937, uniform;

    private Float4x4 randomMatrix(ref Mt19937 rng) {
        Float4x4 m;
        foreach (c; 0 .. 4) {
            m.cols[c] = SimdFloat4(uniform(-2.0f, 2.0f, rng), uniform(-2.0f, 2.0f, rng),
                                   uniform(-2.0f, 2.0f, rng), c == 3 ? 1.0f : 0.0f);
        }
        return m;
    }

    private Float4x4 invTranspose(const Float4x4 m) {
        bool ok;
        immutable inv = invert(m, ok);
        Float4x4 t;
        foreach (c; 0 .. 4) foreach (r; 0 .. 4) t.cols[c][r] = inv.cols[r][c];
        return t;
    }

    private bool near3(Vec3 a, Vec3 b, float tol = 1e-4f) {
        return abs(a.x - b.x) < tol * (1 + abs(b.x)) && abs(a.y - b.y) < tol * (1 + abs(b.y))
            && abs(a.z - b.z) < tol * (1 + abs(b.z));
    }

    // Interleaved vertex as an engine vertex buffer would store it.
    private struct Vertex { float[3] p; float[3] n; float[2] uv; float[3] t; }
}

@trusted unittest {
    // Reference: the weighted blend of per-joint transforms equals the blended-matrix transform,
    // for every influence count (specialized 1..4 and dynamic 5, 6), with and without normals /
    // tangents / inverse-transpose matrices, on strided interleaved buffers.
    Mt19937 rng;
    rng.seed(7);
    enum numJoints = 8;
    enum numVerts = 33;
    foreach (inf; 1 .. 7) {
        foreach (withN; [false, true]) foreach (withT; [false, true]) foreach (withIT; [false, true]) {
            if (withT && !withN) continue;
            auto mats = new Float4x4[numJoints];
            auto its = new Float4x4[numJoints];
            foreach (i; 0 .. numJoints) { mats[i] = randomMatrix(rng); its[i] = invTranspose(mats[i]); }
            auto verts = new Vertex[numVerts];
            auto idx = new ushort[numVerts * inf];
            auto wts = new float[numVerts * (inf > 1 ? inf - 1 : 1)];
            auto full = new float[numVerts * inf];
            foreach (v; 0 .. numVerts) {
                foreach (k; 0 .. 3) {
                    verts[v].p[k] = uniform(-1.0f, 1.0f, rng);
                    verts[v].n[k] = uniform(-1.0f, 1.0f, rng);
                    verts[v].t[k] = uniform(-1.0f, 1.0f, rng);
                }
                float rest = 1;
                foreach (j; 0 .. inf) {
                    idx[v * inf + j] = cast(ushort) uniform(0, numJoints, rng);
                    float w = j + 1 < inf ? uniform(0.0f, rest, rng) : rest;
                    if (j + 1 < inf) wts[v * (inf - 1) + j] = w;
                    full[v * inf + j] = w;
                    rest -= w;
                }
            }
            auto outV = new Vertex[numVerts];
            foreach (ref o; outV) o = Vertex([0, 0, 0], [0, 0, 0], [0, 0], [0, 0, 0]);
            SkinningJob job;
            job.vertexCount = numVerts;
            job.influencesCount = inf;
            job.jointMatrices = mats;
            if (withIT) job.jointInverseTransposeMatrices = its;
            job.jointIndices = asBytes(idx);
            job.jointIndicesStride = ushort.sizeof * inf;
            job.jointWeights = asBytes(wts);
            job.jointWeightsStride = float.sizeof * (inf > 1 ? inf - 1 : 1);
            auto vb = asBytes(verts);
            auto ob = asBytes(outV);
            job.inPositions = vb;
            job.inPositionsStride = Vertex.sizeof;
            job.outPositions = ob;
            job.outPositionsStride = Vertex.sizeof;
            if (withN) {
                job.inNormals = vb[Vertex.n.offsetof .. $];
                job.inNormalsStride = Vertex.sizeof;
                job.outNormals = ob[Vertex.n.offsetof .. $];
                job.outNormalsStride = Vertex.sizeof;
            }
            if (withT) {
                job.inTangents = vb[Vertex.t.offsetof .. $];
                job.inTangentsStride = Vertex.sizeof;
                job.outTangents = ob[Vertex.t.offsetof .. $];
                job.outTangentsStride = Vertex.sizeof;
            }
            assert(job.run(), "run");
            foreach (v; 0 .. numVerts) {
                Vec3 p = Vec3(0, 0, 0), n = Vec3(0, 0, 0), t = Vec3(0, 0, 0);
                foreach (j; 0 .. inf) {
                    immutable w = full[v * inf + j];
                    immutable i = idx[v * inf + j];
                    immutable pv = Vec3(verts[v].p[0], verts[v].p[1], verts[v].p[2]);
                    immutable nv = Vec3(verts[v].n[0], verts[v].n[1], verts[v].n[2]);
                    immutable tv = Vec3(verts[v].t[0], verts[v].t[1], verts[v].t[2]);
                    immutable vm = withIT ? its[i] : mats[i];
                    p = Vec3(p.x + transformPoint(mats[i], pv).x * w, p.y + transformPoint(mats[i], pv).y * w,
                             p.z + transformPoint(mats[i], pv).z * w);
                    n = Vec3(n.x + transformVector(vm, nv).x * w, n.y + transformVector(vm, nv).y * w,
                             n.z + transformVector(vm, nv).z * w);
                    t = Vec3(t.x + transformVector(vm, tv).x * w, t.y + transformVector(vm, tv).y * w,
                             t.z + transformVector(vm, tv).z * w);
                }
                assert(near3(Vec3(outV[v].p[0], outV[v].p[1], outV[v].p[2]), p), "position");
                if (withN) assert(near3(Vec3(outV[v].n[0], outV[v].n[1], outV[v].n[2]), n), "normal");
                if (withT) assert(near3(Vec3(outV[v].t[0], outV[v].t[1], outV[v].t[2]), t), "tangent");
                // Untouched interleaved fields stay untouched.
                assert(outV[v].uv == [0, 0]);
                if (!withN) assert(outV[v].n == [0, 0, 0]);
            }
        }
    }
}

@trusted unittest {
    // Validation, empty jobs, no allocation.
    import core.memory : GC;
    SkinningJob job;
    assert(!job.run());
    auto mats = [Float4x4.identity()];
    auto idx = new ushort[3];
    auto pos = new float[9];
    auto outp = new float[9];
    job.vertexCount = 3;
    job.influencesCount = 1;
    job.jointMatrices = mats;
    job.jointIndices = asBytes(idx);
    job.jointIndicesStride = 2;
    job.inPositions = asBytes(pos);
    job.inPositionsStride = 12;
    job.outPositions = asBytes(outp);
    job.outPositionsStride = 12;
    assert(job.run());
    foreach (i; 0 .. 9) pos[i] = i;
    assert(job.run() && outp == pos);
    immutable before = GC.stats().usedSize;
    foreach (i; 0 .. 50) job.run();
    assert(GC.stats().usedSize == before);

    auto bad = job;
    bad.outPositions = asBytes(outp)[0 .. 20];
    assert(!bad.run());
    bad = job;
    bad.inTangents = asBytes(pos); // tangents without normals
    assert(!bad.validate());
    bad = job;
    bad.influencesCount = 2; // weights required
    assert(!bad.validate());
    bad = job;
    bad.vertexCount = 0;
    assert(bad.run());
}
