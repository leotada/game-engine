/**
 * Load-time test of whether a triangle mesh is closed and faces outward.
 *
 * A closed mesh shows its back faces only to a camera inside it, so
 * `TexMesh.closed` lets double-sided materials skip them
 * (`Material.drawClosedBackFaces` keeps them).
 */
module engine.graphics.closed_mesh;

@safe:

/// Meshes with more indices are reported open (the test would slow loading).
enum size_t CLOSED_MESH_MAX_INDICES = 3_000_000;

/**
 * True when every edge of the mesh, after welding vertices closer than a
 * millionth of the bounding box diagonal (UV and normal seams split
 * vertices), is shared by as many
 * triangles in one direction as in the other, and the signed volume is
 * positive (faces wind outward). Degenerate triangles are ignored. Several
 * closed pieces, touching or not, count as closed.
 */
bool isClosedMesh(V, I)(scope const(V)[] verts, scope const(I)[] indices)
if (is(I == ushort) || is(I == uint)) {
    import std.algorithm.sorting : sort;
    if (indices.length < 12 || indices.length % 3 != 0 || indices.length > CLOSED_MESH_MAX_INDICES)
        return false;
    // Weld: vertices closer than a millionth of the bounding box diagonal share one id.
    float[3] lo = [float.max, float.max, float.max], hi = [-float.max, -float.max, -float.max];
    foreach (ref v; verts)
        foreach (k; 0 .. 3) {
            if (v.pos[k] < lo[k]) lo[k] = v.pos[k];
            if (v.pos[k] > hi[k]) hi[k] = v.pos[k];
        }
    double diag = 0;
    foreach (k; 0 .. 3) diag += (cast(double) hi[k] - lo[k]) * (cast(double) hi[k] - lo[k]);
    import std.math : lround, sqrt;
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
    // Directed edges as (from << 32 | to); closed when each one has a reverse twin.
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
