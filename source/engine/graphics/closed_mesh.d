/**
 * Load-time test of whether a triangle mesh is closed and faces outward.
 *
 * A closed mesh shows its back faces only to a camera inside it, so
 * `TexMesh.closed` lets double-sided materials skip them
 * (`Material.drawClosedBackFaces` keeps them).
 *
 * The test is linear and allocation-free on the GC heap: vertices are welded
 * through a hash keyed by their quantized cell (three 21-bit axes in one
 * `ulong`), and directed edges are bucketed by their lower welded endpoint
 * with a counting sort, so every edge is balanced against its twin inside a
 * small per-vertex bucket. Scratch memory is one `malloc` block per thread,
 * reused between calls and freed after a call that needed more than
 * `CLOSED_MESH_KEEP_BYTES`.
 */
module engine.graphics.closed_mesh;

@safe:

/// Meshes with more indices are reported open (the test would slow loading).
enum size_t CLOSED_MESH_MAX_INDICES = 3_000_000;

/// Scratch kept between calls (per thread). A larger block is freed after use.
enum size_t CLOSED_MESH_KEEP_BYTES = 8 << 20;

/// Whether a mesh is closed, when the caller already knows it.
enum Closedness : ubyte {
    /// Run `isClosedMesh` on the uploaded data.
    detect,
    /// The mesh is open (or the caller does not want back faces culled).
    open,
    /// The mesh is closed and faces outward.
    closed,
}

/**
 * True when every edge of the mesh, after welding vertices closer than a
 * millionth of the bounding box diagonal (UV and normal seams split
 * vertices), is shared by as many
 * triangles in one direction as in the other, and the signed volume is
 * positive (faces wind outward). Degenerate triangles are ignored. Several
 * closed pieces, touching or not, count as closed. Reports open when the
 * scratch block cannot be allocated.
 */
bool isClosedMesh(V, I)(scope const(V)[] verts, scope const(I)[] indices) nothrow @nogc
if (is(I == ushort) || is(I == uint)) {
    import std.math : sqrt;
    if (indices.length < 12 || indices.length % 3 != 0 || indices.length > CLOSED_MESH_MAX_INDICES)
        return false;
    // Welded ids and edge entries pack a vertex id in 31 bits.
    if (verts.length == 0 || verts.length >= (1u << 31))
        return false;
    immutable size_t nv = verts.length;

    float[3] lo = [float.max, float.max, float.max], hi = [-float.max, -float.max, -float.max];
    foreach (ref v; verts)
        foreach (k; 0 .. 3) {
            if (v.pos[k] < lo[k]) lo[k] = v.pos[k];
            if (v.pos[k] > hi[k]) hi[k] = v.pos[k];
        }
    double diag = 0;
    foreach (k; 0 .. 3) diag += (cast(double) hi[k] - lo[k]) * (cast(double) hi[k] - lo[k]);
    if (diag != diag || diag == double.infinity) return false;
    // Cells per axis stay below 2^20 + 1: each axis spans at most the diagonal.
    immutable double inv = diag > 0 ? 1.0 / (sqrt(diag) * 1e-6) : 1.0;

    // Scratch layout: weld[nv] | region (weld hash, then counts[nv + 1] + entries[indices]).
    immutable size_t weldCap = pow2AtLeast(nv + nv / 3); // load factor at most 3/4
    immutable size_t weldBytes = (nv * uint.sizeof + 15) & ~cast(size_t) 15;
    immutable size_t hashBytes = weldCap * WeldSlot.sizeof;
    immutable size_t csrBytes = (nv + 1) * uint.sizeof + indices.length * uint.sizeof;
    ubyte[] mem = scratch(weldBytes + (hashBytes > csrBytes ? hashBytes : csrBytes));
    if (mem is null) return false;
    scope (exit) releaseScratch();
    uint[] weld = asArray!uint(mem[0 .. weldBytes], nv);
    ubyte[] region = mem[weldBytes .. $];

    // Weld: the first vertex of each cell represents it (same ids as a sort by cell, then index).
    {
        WeldSlot[] table = asArray!WeldSlot(region, weldCap);
        foreach (ref s; table) s.key = WELD_EMPTY;
        immutable uint shift = 64 - log2(weldCap);
        immutable size_t mask = weldCap - 1;
        foreach (i, ref v; verts) {
            ulong key = 0;
            foreach (k; 0 .. 3)
                key = (key << 21) | (roundCell((v.pos[k] - cast(double) lo[k]) * inv) & 0x1F_FFFF);
            size_t h = cast(size_t) ((key * 0x9E37_79B9_7F4A_7C15UL) >> shift);
            while (true) {
                if (table[h].key == WELD_EMPTY) {
                    table[h].key = key;
                    table[h].id = cast(uint) i;
                    weld[i] = cast(uint) i;
                    break;
                }
                if (table[h].key == key) {
                    weld[i] = table[h].id;
                    break;
                }
                h = (h + 1) & mask;
            }
        }
    }

    // Count directed edges per lower endpoint; validate indices and sum the signed volume.
    uint[] start = asArray!uint(region, nv + 1);
    uint[] entries = asArray!uint(region[(nv + 1) * uint.sizeof .. $], indices.length);
    start[] = 0;
    double volume = 0;
    size_t edgeCount = 0;
    for (size_t t = 0; t + 2 < indices.length; t += 3) {
        if (indices[t] >= nv || indices[t + 1] >= nv || indices[t + 2] >= nv)
            return false;
        immutable a = weld[indices[t]], b = weld[indices[t + 1]], c = weld[indices[t + 2]];
        if (a == b || b == c || a == c) continue;
        start[a < b ? a : b]++;
        start[b < c ? b : c]++;
        start[c < a ? c : a]++;
        edgeCount += 3;
        immutable p = verts[a].pos, q = verts[b].pos, r = verts[c].pos;
        volume += (cast(double) p[0]) * (cast(double) q[1] * r[2] - cast(double) q[2] * r[1])
                - (cast(double) p[1]) * (cast(double) q[0] * r[2] - cast(double) q[2] * r[0])
                + (cast(double) p[2]) * (cast(double) q[0] * r[1] - cast(double) q[1] * r[0]);
    }
    if (edgeCount == 0 || volume <= 0) return false;
    // Exclusive prefix sum: start[v] is where the bucket of v begins.
    {
        uint sum = 0;
        foreach (ref s; start) {
            immutable cnt = s;
            s = sum;
            sum += cnt;
        }
    }
    // Scatter: entry = other endpoint << 1 | (1 when the edge runs from the lower endpoint).
    // `start[v]` advances to the end of the bucket of v.
    pragma(inline, true) static void put(uint[] start, uint[] entries, uint from, uint to) nothrow @nogc {
        if (from < to) entries[start[from]++] = (to << 1) | 1;
        else entries[start[to]++] = from << 1;
    }
    for (size_t t = 0; t + 2 < indices.length; t += 3) {
        immutable a = weld[indices[t]], b = weld[indices[t + 1]], c = weld[indices[t + 2]];
        if (a == b || b == c || a == c) continue;
        put(start, entries, a, b);
        put(start, entries, b, c);
        put(start, entries, c, a);
    }
    // Every bucket [start[v - 1], start[v]) must hold, per other endpoint, as many
    // edges running out of v as running into it.
    size_t begin = 0;
    foreach (v; 0 .. nv) {
        immutable size_t end = start[v];
        if (!bucketBalanced(entries[begin .. end])) return false;
        begin = end;
    }
    return true;
}

private enum ulong WELD_EMPTY = ulong.max;

private struct WeldSlot {
    ulong key;
    uint id;
}

/// Sort one bucket and check that each endpoint has as many 1 bits as 0 bits.
private bool bucketBalanced(uint[] bucket) nothrow @nogc {
    if (bucket.length == 0) return true;
    if (bucket.length & 1) return false;
    if (bucket.length <= 32) {
        foreach (i; 1 .. bucket.length) {
            immutable x = bucket[i];
            size_t j = i;
            for (; j > 0 && bucket[j - 1] > x; j--) bucket[j] = bucket[j - 1];
            bucket[j] = x;
        }
    } else {
        import std.algorithm.sorting : sort;
        sort(bucket);
    }
    // Sorted: entries with one endpoint are adjacent, 0-bit ones first.
    size_t i = 0;
    while (i < bucket.length) {
        immutable other = bucket[i] >> 1;
        size_t outward = 0, total = 0;
        for (; i < bucket.length && bucket[i] >> 1 == other; i++) {
            outward += bucket[i] & 1;
            total++;
        }
        if (outward * 2 != total) return false;
    }
    return true;
}

/// `lround` for `0 <= x < 2^52` without the libm call: `x - trunc(x)` is exact there.
private ulong roundCell(double x) pure nothrow @nogc {
    ulong r = cast(ulong) x;
    if (x - cast(double) r >= 0.5) r++;
    return r;
}

private size_t pow2AtLeast(size_t n) pure nothrow @nogc {
    size_t p = 16;
    while (p < n) p <<= 1;
    return p;
}

private uint log2(size_t p) pure nothrow @nogc {
    uint b = 0;
    while ((cast(size_t) 1 << b) < p) b++;
    return b;
}

private T[] asArray(T)(ubyte[] bytes, size_t count) @trusted nothrow @nogc {
    assert(bytes.length >= count * T.sizeof);
    return (cast(T*) bytes.ptr)[0 .. count];
}

// One block per thread (module variables are thread-local).
private ubyte* scratchPtr;
private size_t scratchLen;

private ubyte[] scratch(size_t bytes) @trusted nothrow @nogc {
    import core.stdc.stdlib : free, malloc;
    if (bytes > scratchLen) {
        free(scratchPtr);
        scratchPtr = cast(ubyte*) malloc(bytes);
        scratchLen = scratchPtr is null ? 0 : bytes;
        if (scratchPtr is null) return null;
    }
    return scratchPtr[0 .. bytes];
}

private void releaseScratch() @trusted nothrow @nogc {
    import core.stdc.stdlib : free;
    if (scratchLen <= CLOSED_MESH_KEEP_BYTES) return;
    free(scratchPtr);
    scratchPtr = null;
    scratchLen = 0;
}

version (unittest) version = ClosedMeshReference;
version (ClosedMeshBench) version = ClosedMeshReference;

version (ClosedMeshReference) {
    /// The sort-based test `isClosedMesh` replaced. Differential tests and
    /// `closed-mesh-bench` compare against it.
    bool isClosedMeshReference(V, I)(scope const(V)[] verts, scope const(I)[] indices)
    if (is(I == ushort) || is(I == uint)) {
        import std.algorithm.sorting : sort;
        import std.math : lround, sqrt;
        if (indices.length < 12 || indices.length % 3 != 0 || indices.length > CLOSED_MESH_MAX_INDICES)
            return false;
        float[3] lo = [float.max, float.max, float.max], hi = [-float.max, -float.max, -float.max];
        foreach (ref v; verts)
            foreach (k; 0 .. 3) {
                if (v.pos[k] < lo[k]) lo[k] = v.pos[k];
                if (v.pos[k] > hi[k]) hi[k] = v.pos[k];
            }
        double diag = 0;
        foreach (k; 0 .. 3) diag += (cast(double) hi[k] - lo[k]) * (cast(double) hi[k] - lo[k]);
        immutable double inv = diag > 0 ? 1.0 / (sqrt(diag) * 1e-6) : 1.0;
        auto cells = new long[3][verts.length];
        foreach (i, ref v; verts)
            foreach (k; 0 .. 3) cells[i][k] = lround((v.pos[k] - cast(double) lo[k]) * inv);
        auto order = new uint[verts.length];
        foreach (i, ref o; order) o = cast(uint) i;
        order.sort!((a, b) => cells[a] < cells[b] || (cells[a] == cells[b] && a < b));
        auto weld = new uint[verts.length];
        foreach (n, i; order) {
            if (n > 0 && cells[order[n - 1]] == cells[i])
                weld[i] = weld[order[n - 1]];
            else
                weld[i] = i;
        }
        auto edges = new ulong[indices.length];
        size_t n = 0;
        double volume = 0;
        for (size_t t = 0; t + 2 < indices.length; t += 3) {
            if (indices[t] >= verts.length || indices[t + 1] >= verts.length || indices[t + 2] >= verts.length)
                return false;
            immutable a = weld[indices[t]], b = weld[indices[t + 1]], c = weld[indices[t + 2]];
            if (a == b || b == c || a == c) continue;
            edges[n++] = (cast(ulong) a << 32) | b;
            edges[n++] = (cast(ulong) b << 32) | c;
            edges[n++] = (cast(ulong) c << 32) | a;
            immutable p = verts[a].pos, q = verts[b].pos, r = verts[c].pos;
            volume += (cast(double) p[0]) * (cast(double) q[1] * r[2] - cast(double) q[2] * r[1])
                    - (cast(double) p[1]) * (cast(double) q[0] * r[2] - cast(double) q[2] * r[0])
                    + (cast(double) p[2]) * (cast(double) q[0] * r[1] - cast(double) q[1] * r[0]);
        }
        if (n == 0 || volume <= 0) return false;
        auto fwd = edges[0 .. n];
        auto rev = new ulong[n];
        foreach (i, e; fwd) rev[i] = (e << 32) | (e >> 32);
        fwd.sort();
        rev.sort();
        return fwd == rev;
    }
}

@("closed_mesh.cube and quad") unittest {
    import engine.graphics.texmesh : texCubeIndices, texCubeVertices, texQuadIndices, texQuadVertices;
    // The cube has a seam on every edge (per-face UVs): closed after welding.
    assert(isClosedMesh(texCubeVertices[], texCubeIndices[]));
    // A single quad is open.
    assert(!isClosedMesh(texQuadVertices[], texQuadIndices[]));
    // Inside out: closed but facing inward.
    auto flipped = texCubeIndices.dup;
    for (size_t t = 0; t < flipped.length; t += 3) {
        immutable x = flipped[t + 1];
        flipped[t + 1] = flipped[t + 2];
        flipped[t + 2] = x;
    }
    assert(!isClosedMesh(texCubeVertices[], flipped));
    // One face missing: open.
    assert(!isClosedMesh(texCubeVertices[], texCubeIndices[0 .. 30]));
    // Two separate closed pieces.
    import engine.graphics.types : TexVert;
    auto two = texCubeVertices.dup;
    foreach (v; texCubeVertices) { TexVert w = v; w.pos[0] += 3; two ~= w; }
    ushort[] idx = texCubeIndices.dup;
    foreach (i; texCubeIndices) idx ~= cast(ushort) (i + 24);
    assert(isClosedMesh(two, idx));
}

@("closed_mesh.edge cases") unittest {
    import engine.graphics.texmesh : texCubeIndices, texCubeVertices;
    import engine.graphics.types : TexVert;
    // Out-of-range index: open.
    auto bad = texCubeIndices.dup;
    bad[5] = 200;
    assert(!isClosedMesh(texCubeVertices[], bad));
    // A doubled face (four triangles over one quad, two each way) stays balanced.
    ushort[] extra = texCubeIndices.dup ~ cast(ushort[]) [0, 1, 2, 0, 2, 1];
    assert(isClosedMesh(texCubeVertices[], extra) == isClosedMesh(texCubeVertices[], texCubeIndices[]));
    // All vertices at one point: every triangle degenerates.
    TexVert[24] dot;
    foreach (ref d; dot) d.pos = [0, 0, 0];
    assert(!isClosedMesh(dot[], texCubeIndices[]));
    // Indices that cannot form triangles, or too few.
    assert(!isClosedMesh(texCubeVertices[], texCubeIndices[0 .. 9]));
    assert(!isClosedMesh(texCubeVertices[], texCubeIndices[0 .. 13]));
    // uint indices take the same path.
    uint[] wide;
    foreach (i; texCubeIndices) wide ~= i;
    assert(isClosedMesh(texCubeVertices[], wide));
}

version (unittest) {
    import engine.graphics.types : TexVert;

    // Deterministic xorshift for the differential tests.
    private struct Rng {
        ulong s = 0x2545_F491_4F6C_DD1DUL;
        uint next() nothrow @nogc { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return cast(uint) s; }
        uint below(uint n) nothrow @nogc { return next() % n; }
    }

    /// UV sphere with a seam column and pole fans: closed, with split vertices.
    private void testSphere(uint seg, uint ring, out TexVert[] verts, out uint[] idx) {
        import std.math : cos, PI, sin;
        foreach (y; 0 .. ring + 1) foreach (x; 0 .. seg + 1) {
            immutable float phi = cast(float) PI * y / ring, th = 2 * cast(float) PI * x / seg;
            immutable float nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th);
            verts ~= TexVert([nx, ny, nz], [nx, ny, nz], [cast(float) x / seg, cast(float) y / ring]);
        }
        foreach (y; 0 .. ring) foreach (x; 0 .. seg) {
            immutable uint a = y * (seg + 1) + x, b = a + seg + 1;
            idx ~= [a, a + 1, b, a + 1, b + 1, b];
        }
    }
}

@("closed_mesh.matches the sort-based reference") unittest {
    Rng rng;
    TexVert[] base;
    uint[] baseIdx;
    testSphere(24, 12, base, baseIdx);
    assert(isClosedMesh(base, baseIdx) && isClosedMeshReference(base, baseIdx));
    size_t closedSeen = 0, openSeen = 0;
    foreach (round; 0 .. 400) {
        TexVert[] verts = base.dup;
        uint[] idx = baseIdx.dup;
        switch (rng.below(6)) {
        default: break;                                           // untouched
        case 1: idx = idx[0 .. $ - 3 * (1 + rng.below(4))]; break; // holes
        case 2: {                                                // flip one triangle
            immutable t = 3 * rng.below(cast(uint) (idx.length / 3));
            immutable x = idx[t + 1]; idx[t + 1] = idx[t + 2]; idx[t + 2] = x;
            break;
        }
        case 3:                                                  // move a vertex off its seam twin
            verts[rng.below(cast(uint) verts.length)].pos[0] += 0.01f;
            break;
        case 4:                                                  // shuffle triangle order
            foreach (k; 0 .. idx.length / 3) {
                immutable j = rng.below(cast(uint) (idx.length / 3));
                foreach (c; 0 .. 3) { immutable x = idx[3 * k + c]; idx[3 * k + c] = idx[3 * j + c]; idx[3 * j + c] = x; }
            }
            break;
        case 5:                                                  // duplicate vertices, reroute some corners
            foreach (ref i; idx) if (rng.below(4) == 0) { verts ~= verts[i]; i = cast(uint) verts.length - 1; }
            break;
        }
        immutable got = isClosedMesh(verts, idx), want = isClosedMeshReference(verts, idx);
        assert(got == want);
        (got ? closedSeen : openSeen)++;
    }
    assert(closedSeen > 0 && openSeen > 0);
}

@("closed_mesh.high valence fan") unittest {
    // A cone with 200 segments: the apex and base center buckets take the sort path.
    import std.math : cos, PI, sin;
    enum seg = 200;
    TexVert[] verts = [TexVert([0, 1, 0]), TexVert([0, 0, 0])];
    foreach (i; 0 .. seg) {
        immutable float th = 2 * cast(float) PI * i / seg;
        verts ~= TexVert([cos(th), 0, sin(th)]);
    }
    uint[] idx;
    foreach (i; 0 .. seg) {
        immutable uint a = 2 + i, b = 2 + (i + 1) % seg;
        idx ~= [0u, b, a, 1u, a, b];
    }
    immutable want = isClosedMeshReference(verts, idx);
    assert(isClosedMesh(verts, idx) == want);
    idx = idx[0 .. $ - 3];
    assert(isClosedMesh(verts, idx) == isClosedMeshReference(verts, idx));
}
