// Differential oracle for meshoptimizer meshlets, clusters, and spatial order.
// Build libs/libmeshoptimizer_ref.a first (tools/meshopt-oracle/build_ref.sh).
//   cluster-oracle diff [mesh]
//   cluster-oracle generate
module cluster_main;

import std.conv : to;
import std.file : mkdirRecurse, read, write;
import std.format : format;
import std.path : dirName;
import std.stdio;

import engine.meshopt.cluster : m9Corpus, m9GoldenPayload;
import engine.meshopt.internal.bits : floatBits;
import engine.meshopt.quantize : goldenParamsHash;

extern (C) struct RefMeshlet {
    uint vertexOffset;
    uint triangleOffset;
    uint vertexCount;
    uint triangleCount;
}

extern (C) struct RefBounds {
    float[3] center;
    float radius;
    float[3] coneApex;
    float[3] coneAxis;
    float coneCutoff;
    byte[3] coneAxisS8;
    byte coneCutoffS8;
}

static assert(RefMeshlet.sizeof == 16);
static assert(RefBounds.sizeof == 48);

extern (C) nothrow @nogc {
    size_t meshopt_buildMeshletsBound(size_t index_count, size_t max_vertices, size_t max_triangles);
    size_t meshopt_buildMeshlets(RefMeshlet* meshlets, uint* meshlet_vertices, ubyte* meshlet_triangles, const(uint)* indices, size_t index_count, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t max_vertices, size_t max_triangles, float cone_weight);
    size_t meshopt_buildMeshletsScan(RefMeshlet* meshlets, uint* meshlet_vertices, ubyte* meshlet_triangles, const(uint)* indices, size_t index_count, size_t vertex_count, size_t max_vertices, size_t max_triangles);
    size_t meshopt_buildMeshletsFlex(RefMeshlet* meshlets, uint* meshlet_vertices, ubyte* meshlet_triangles, const(uint)* indices, size_t index_count, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t max_vertices, size_t min_triangles, size_t max_triangles, float cone_weight, float split_factor);
    size_t meshopt_buildMeshletsSpatial(RefMeshlet* meshlets, uint* meshlet_vertices, ubyte* meshlet_triangles, const(uint)* indices, size_t index_count, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t max_vertices, size_t min_triangles, size_t max_triangles, float fill_weight);
    RefBounds meshopt_computeClusterBounds(const(uint)* indices, size_t index_count, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride);
    RefBounds meshopt_computeMeshletBounds(const(uint)* meshlet_vertices, const(ubyte)* meshlet_triangles, size_t triangle_count, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride);
    RefBounds meshopt_computeSphereBounds(const(float)* positions, size_t count, size_t positions_stride, const(float)* radii, size_t radii_stride);
    void meshopt_optimizeMeshletLevel(uint* meshlet_vertices, size_t vertex_count, ubyte* meshlet_triangles, size_t triangle_count, int level);
    size_t meshopt_extractMeshletIndices(uint* vertices, ubyte* triangles, const(uint)* indices, size_t index_count);
    size_t meshopt_partitionClusters(uint* destination, const(uint)* cluster_indices, size_t total_index_count, const(uint)* cluster_index_counts, size_t cluster_count, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t target_partition_size);
    void meshopt_spatialSortRemap(uint* destination, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride);
    void meshopt_spatialSortTriangles(uint* destination, const(uint)* indices, size_t index_count, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride);
    void meshopt_spatialClusterPoints(uint* destination, const(float)* vertex_positions, size_t vertex_count, size_t vertex_positions_stride, size_t cluster_size);
    size_t meshopt_encodeMeshletBound(size_t max_vertices, size_t max_triangles);
    size_t meshopt_encodeMeshlet(ubyte* buffer, size_t buffer_size, const(uint)* vertices, size_t vertex_count, const(ubyte)* triangles, size_t triangle_count);
    int meshopt_decodeMeshlet(void* vertices, size_t vertex_count, size_t vertex_size, void* triangles, size_t triangle_count, size_t triangle_size, const(ubyte)* buffer, size_t buffer_size);
    int meshopt_decodeMeshletRaw(uint* vertices, size_t vertex_count, uint* triangles, size_t triangle_count, const(ubyte)* buffer, size_t buffer_size);
}

void putU32(ref ubyte[] o, uint v) {
    o ~= cast(ubyte) v;
    o ~= cast(ubyte)(v >> 8);
    o ~= cast(ubyte)(v >> 16);
    o ~= cast(ubyte)(v >> 24);
}

void putF32(ref ubyte[] o, float v) {
    putU32(o, floatBits(v));
}

void putBoundsBytes(ref ubyte[] o, RefBounds b) {
    foreach (x; b.center)
        putF32(o, x);
    putF32(o, b.radius);
    foreach (x; b.coneApex)
        putF32(o, x);
    foreach (x; b.coneAxis)
        putF32(o, x);
    putF32(o, b.coneCutoff);
    foreach (x; b.coneAxisS8)
        o ~= cast(ubyte) x;
    o ~= cast(ubyte) b.coneCutoffS8;
}

void putRec(ref ubyte[] o, string key, const(ubyte)[] payload) {
    putU32(o, cast(uint) key.length);
    foreach (char c; key)
        o ~= cast(ubyte) c;
    putU32(o, cast(uint) payload.length);
    o ~= payload;
}

void putMeshlets(ref ubyte[] payload, RefMeshlet[] meshlets, uint[] verts, ubyte[] tris, size_t count) {
    putU32(payload, cast(uint) count);
    foreach (i; 0 .. count) {
        putU32(payload, meshlets[i].vertexOffset);
        putU32(payload, meshlets[i].triangleOffset);
        putU32(payload, meshlets[i].vertexCount);
        putU32(payload, meshlets[i].triangleCount);
    }
    size_t usedV = 0;
    size_t usedT = 0;
    if (count) {
        RefMeshlet last = meshlets[count - 1];
        usedV = last.vertexOffset + last.vertexCount;
        usedT = last.triangleOffset + last.triangleCount * 3;
    }
    putU32(payload, cast(uint) usedV);
    foreach (v; verts[0 .. usedV])
        putU32(payload, v);
    putU32(payload, cast(uint) usedT);
    payload ~= tris[0 .. usedT];
}

const(uint)* iptr(const(uint)[] idx) {
    return idx.length ? idx.ptr : null;
}

const(float)* pptr(const(float)[] pos) {
    return pos.length ? pos.ptr : null;
}

ubyte[] m9RefPayload(string name, const(float)[] pos, const(uint)[] idx, size_t strideFloats) {
    ubyte[] o;
    string pfx = name ~ "/";
    size_t vertexCount = strideFloats ? pos.length / strideFloats : 0;
    size_t strideBytes = strideFloats * 4;

    void boundRec(size_t maxV, size_t maxT) {
        ubyte[] payload;
        putU32(payload, cast(uint) meshopt_buildMeshletsBound(idx.length, maxV, maxT));
        putRec(o, format("%sbound/%s/%s", pfx, maxV, maxT), payload);
    }

    boundRec(64, 64);
    boundRec(256, 512);
    boundRec(3, 1);

    void buildRec(string kind, size_t count, RefMeshlet[] mls, uint[] mv, ubyte[] mt) {
        ubyte[] payload;
        putMeshlets(payload, mls, mv, mt, count);
        putRec(o, pfx ~ kind, payload);
    }

    void runBuild(size_t maxV, size_t maxT, float cone) {
        size_t b = meshopt_buildMeshletsBound(idx.length, maxV, maxT);
        auto mls = new RefMeshlet[b];
        auto mv = new uint[idx.length];
        auto mt = new ubyte[idx.length];
        size_t n = meshopt_buildMeshlets(mls.ptr, mv.ptr, mt.ptr, iptr(idx), idx.length, pptr(pos), vertexCount, strideBytes, maxV, maxT, cone);
        buildRec(format("meshlets/%s/%s/%08x", maxV, maxT, floatBits(cone)), n, mls, mv, mt);
    }

    void runScan(size_t maxV, size_t maxT) {
        size_t b = meshopt_buildMeshletsBound(idx.length, maxV, maxT);
        auto mls = new RefMeshlet[b];
        auto mv = new uint[idx.length];
        auto mt = new ubyte[idx.length];
        size_t n = meshopt_buildMeshletsScan(mls.ptr, mv.ptr, mt.ptr, iptr(idx), idx.length, vertexCount, maxV, maxT);
        buildRec(format("scan/%s/%s", maxV, maxT), n, mls, mv, mt);
    }

    void runFlex(size_t maxV, size_t minT, size_t maxT, float cone, float split) {
        size_t b = meshopt_buildMeshletsBound(idx.length, maxV, minT);
        auto mls = new RefMeshlet[b];
        auto mv = new uint[idx.length];
        auto mt = new ubyte[idx.length];
        size_t n = meshopt_buildMeshletsFlex(mls.ptr, mv.ptr, mt.ptr, iptr(idx), idx.length, pptr(pos), vertexCount, strideBytes, maxV, minT, maxT, cone, split);
        buildRec(format("flex/%s/%s/%s/%08x/%08x", maxV, minT, maxT, floatBits(cone), floatBits(split)), n, mls, mv, mt);
    }

    void runSpatial(size_t maxV, size_t minT, size_t maxT, float fill) {
        size_t b = meshopt_buildMeshletsBound(idx.length, maxV, minT);
        auto mls = new RefMeshlet[b];
        auto mv = new uint[idx.length];
        auto mt = new ubyte[idx.length];
        size_t n = meshopt_buildMeshletsSpatial(mls.ptr, mv.ptr, mt.ptr, iptr(idx), idx.length, pptr(pos), vertexCount, strideBytes, maxV, minT, maxT, fill);
        buildRec(format("spatial/%s/%s/%s/%08x", maxV, minT, maxT, floatBits(fill)), n, mls, mv, mt);
    }

    if (idx.length == 0) {
        runScan(64, 64);
    } else {
        runBuild(64, 64, 0);
        runBuild(32, 96, 0.5f);
        runScan(64, 64);
        runScan(16, 32);
        runFlex(64, 16, 64, 0, 0);
        runFlex(48, 8, 64, 0.25f, 1.5f);
        runSpatial(64, 16, 64, 0);
        runSpatial(32, 8, 32, 0.5f);
    }

    if (idx.length / 3 <= 512) {
        ubyte[] payload;
        putBoundsBytes(payload, meshopt_computeClusterBounds(iptr(idx), idx.length, pptr(pos), vertexCount, strideBytes));
        putRec(o, pfx ~ "clusterBounds", payload);
    }
    {
        ubyte[] payload;
        putBoundsBytes(payload, meshopt_computeSphereBounds(pptr(pos), vertexCount, strideBytes, null, 0));
        putRec(o, pfx ~ "sphere", payload);
        float[] radii = new float[vertexCount];
        radii[] = 0.25f;
        ubyte[] payloadR;
        putBoundsBytes(payloadR, meshopt_computeSphereBounds(pptr(pos), vertexCount, strideBytes, radii.length ? radii.ptr : null, 4));
        putRec(o, pfx ~ "sphereR", payloadR);
    }

    if (idx.length) {
        size_t b = meshopt_buildMeshletsBound(idx.length, 64, 64);
        auto mls = new RefMeshlet[b];
        auto mv = new uint[idx.length];
        auto mt = new ubyte[idx.length];
        size_t n = meshopt_buildMeshlets(mls.ptr, mv.ptr, mt.ptr, iptr(idx), idx.length, pptr(pos), vertexCount, strideBytes, 64, 64, 0);
        foreach (i; 0 .. n) {
            RefMeshlet m = mls[i];
            ubyte[] payload;
            putBoundsBytes(payload, meshopt_computeMeshletBounds(mv.ptr + m.vertexOffset, mt.ptr + m.triangleOffset, m.triangleCount, pptr(pos), vertexCount, strideBytes));
            putRec(o, format("%smeshletBounds/%s", pfx, i), payload);

            uint[] ov = mv[m.vertexOffset .. m.vertexOffset + m.vertexCount].dup;
            ubyte[] ot = mt[m.triangleOffset .. m.triangleOffset + m.triangleCount * 3].dup;
            meshopt_optimizeMeshletLevel(ov.ptr, ov.length, ot.ptr, m.triangleCount, 0);
            ubyte[] payload0;
            foreach (v; ov)
                putU32(payload0, v);
            payload0 ~= ot;
            putRec(o, format("%sopt/0/%s", pfx, i), payload0);

            uint[] ov3 = mv[m.vertexOffset .. m.vertexOffset + m.vertexCount].dup;
            ubyte[] ot3 = mt[m.triangleOffset .. m.triangleOffset + m.triangleCount * 3].dup;
            meshopt_optimizeMeshletLevel(ov3.ptr, ov3.length, ot3.ptr, m.triangleCount, 3);
            ubyte[] payload3;
            foreach (v; ov3)
                putU32(payload3, v);
            payload3 ~= ot3;
            putRec(o, format("%sopt/3/%s", pfx, i), payload3);

            uint[] expanded = new uint[m.triangleCount * 3];
            foreach (t; 0 .. m.triangleCount * 3)
                expanded[t] = mv[m.vertexOffset + mt[m.triangleOffset + t]];
            uint[] ev = new uint[256];
            ubyte[] et = new ubyte[expanded.length];
            size_t unique = meshopt_extractMeshletIndices(ev.ptr, et.ptr, expanded.ptr, expanded.length);
            ubyte[] payloadE;
            putU32(payloadE, cast(uint) unique);
            foreach (v; ev[0 .. unique])
                putU32(payloadE, v);
            payloadE ~= et[0 .. expanded.length];
            putRec(o, format("%sextract/%s", pfx, i), payloadE);

            if (m.vertexCount <= 256 && m.triangleCount <= 256) {
                ubyte[] enc = new ubyte[meshopt_encodeMeshletBound(m.vertexCount, m.triangleCount)];
                size_t esz = meshopt_encodeMeshlet(enc.ptr, enc.length, mv.ptr + m.vertexOffset, m.vertexCount, mt.ptr + m.triangleOffset, m.triangleCount);
                ubyte[] payloadN;
                putU32(payloadN, cast(uint) esz);
                payloadN ~= enc[0 .. esz];
                uint[] dv = new uint[m.vertexCount];
                ubyte[] dt = new ubyte[m.triangleCount * 3];
                int rc = meshopt_decodeMeshlet(dv.ptr, m.vertexCount, 4, dt.ptr, m.triangleCount, 3, enc.ptr, esz);
                putU32(payloadN, cast(uint) rc);
                foreach (v; dv)
                    putU32(payloadN, v);
                payloadN ~= dt;
                uint[] rawT = new uint[m.triangleCount];
                int rcr = meshopt_decodeMeshletRaw(dv.ptr, m.vertexCount, rawT.ptr, m.triangleCount, enc.ptr, esz);
                putU32(payloadN, cast(uint) rcr);
                foreach (v; rawT)
                    putU32(payloadN, v);
                putRec(o, format("%sencode/%s", pfx, i), payloadN);
            }
        }

        size_t faces = idx.length / 3;
        uint[] counts = new uint[faces];
        counts[] = 3;
        uint[] part = new uint[faces];
        size_t np = meshopt_partitionClusters(part.ptr, iptr(idx), idx.length, counts.ptr, faces, null, vertexCount, 0, 4);
        ubyte[] payloadP;
        putU32(payloadP, cast(uint) np);
        foreach (v; part)
            putU32(payloadP, v);
        putRec(o, pfx ~ "partition/4/0", payloadP);

        part[] = 0;
        size_t wp = meshopt_partitionClusters(part.ptr, iptr(idx), idx.length, counts.ptr, faces, pptr(pos), vertexCount, strideBytes, 4);
        ubyte[] payloadW;
        putU32(payloadW, cast(uint) wp);
        foreach (v; part)
            putU32(payloadW, v);
        putRec(o, pfx ~ "partition/4/1", payloadW);
    }

    {
        uint[] remap = new uint[vertexCount];
        meshopt_spatialSortRemap(remap.ptr, pptr(pos), vertexCount, strideBytes);
        ubyte[] payload;
        foreach (v; remap)
            putU32(payload, v);
        putRec(o, pfx ~ "remap", payload);
    }
    {
        uint[] tris = new uint[idx.length];
        meshopt_spatialSortTriangles(tris.ptr, iptr(idx), idx.length, pptr(pos), vertexCount, strideBytes);
        ubyte[] payload;
        foreach (v; tris)
            putU32(payload, v);
        putRec(o, pfx ~ "sortTri", payload);
    }
    foreach (clusterSize; [8, 32]) {
        uint[] dest = new uint[vertexCount];
        meshopt_spatialClusterPoints(dest.ptr, pptr(pos), vertexCount, strideBytes, clusterSize);
        ubyte[] payload;
        foreach (v; dest)
            putU32(payload, v);
        putRec(o, format("%spoints/%s", pfx, clusterSize), payload);
    }
    return o;
}

uint loadU32(const(ubyte)[] b, size_t at) {
    return b[at] | (cast(uint) b[at + 1] << 8) | (cast(uint) b[at + 2] << 16) | (cast(uint) b[at + 3] << 24);
}

bool nextRec(ref size_t at, const(ubyte)[] blob, out string key, out const(ubyte)[] payload) {
    if (at >= blob.length)
        return false;
    uint klen = loadU32(blob, at);
    at += 4;
    char[] tmp = new char[klen];
    foreach (i; 0 .. klen)
        tmp[i] = cast(char) blob[at + i];
    at += klen;
    key = tmp.idup;
    uint n = loadU32(blob, at);
    at += 4;
    payload = blob[at .. at + n];
    at += n;
    return true;
}

int compareBlobs(string mesh, const(ubyte)[] d, const(ubyte)[] r) {
    size_t ad, ar;
    int bad = 0;
    while (true) {
        string kd, kr;
        const(ubyte)[] pd, pr;
        bool hd = nextRec(ad, d, kd, pd);
        bool hr = nextRec(ar, r, kr, pr);
        if (!hd && !hr)
            break;
        if (!hd || !hr || kd != kr || pd != pr) {
            string kk = hd ? kd : "?";
            string rk = hr ? kr : "?";
            writefln("mismatch %s key D=%s ref=%s dlen=%s rlen=%s", mesh, kk, rk, hd ? pd.length : 0, hr ? pr.length : 0);
            if (hd && hr && kd == kr) {
                size_t n = pd.length < pr.length ? pd.length : pr.length;
                size_t shown = 0;
                foreach (i; 0 .. n) {
                    if (pd[i] != pr[i]) {
                        writefln("  byte %s D=%02x ref=%02x", i, pd[i], pr[i]);
                        if (++shown == 8)
                            break;
                    }
                }
                if (pd.length != pr.length)
                    writefln("  length D=%s ref=%s", pd.length, pr.length);
            }
            bad++;
            if (bad >= 6)
                break;
            if (!hd || !hr || kd != kr)
                break;
        }
    }
    return bad;
}

void main(string[] args) {
    string mode = args.length > 1 ? args[1] : "diff";
    string only = args.length > 2 ? args[2] : null;
    ubyte[] allRef;
    int bad = 0;
    int meshes = 0;
    foreach (mesh; m9Corpus()) {
        if (only.length && mesh.name != only)
            continue;
        writefln("mesh %s verts=%s tris=%s", mesh.name, mesh.pos.length / mesh.strideFloats, mesh.idx.length / 3);
        stdout.flush();
        ubyte[] d = m9GoldenPayload(mesh.name, mesh.pos, mesh.idx, mesh.strideFloats);
        ubyte[] r = m9RefPayload(mesh.name, mesh.pos, mesh.idx, mesh.strideFloats);
        int m = compareBlobs(mesh.name, d, r);
        if (m == 0)
            writeln("  match");
        bad += m;
        meshes++;
        allRef ~= r;
    }
    if (mode == "generate") {
        if (only.length) {
            stderr.writeln("generate writes the full corpus; omit the mesh filter");
            return;
        }
        ubyte[] file;
        file ~= cast(ubyte[]) "MOPTGLD1";
        putU32(file, 1030);
        char[32] title = 0;
        title[0 .. 8] = "m9corpus";
        foreach (c; title)
            file ~= cast(ubyte) c;
        putU32(file, goldenParamsHash("m9corpus"));
        file ~= allRef;
        string path = "tests/meshopt/golden/m9/corpus.bin";
        mkdirRecurse(dirName(path));
        write(path, file);
        writefln("wrote %s (%s bytes)", path, file.length);
    }
    if (bad) {
        writefln("%s mismatched records", bad);
        import core.stdc.stdlib : exit;
        exit(1);
    }
    writefln("%s meshes byte-exact", meshes);
}
