// Ported from meshoptimizer v1.3 (src/meshletutils.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Meshlet triangle reorder and local index extraction.
module engine.meshopt.meshlet;

@safe:

private enum size_t kMeshletMaxVertices = 256;
private enum size_t kMeshletMaxTriangles = 512;

/**
 * Reorder one meshlet for locality and, at `level >= 1`, rotate corners for compression.
 * `level` is 0..9. Level 0 matches `optimizeMeshlet`.
 */
void optimizeMeshletLevel(scope uint[] meshletVertices, scope ubyte[] meshletTriangles, int level) nothrow @nogc
in (level >= 0 && level <= 9)
in (meshletVertices.length <= kMeshletMaxVertices)
in (meshletTriangles.length % 3 == 0)
in (meshletTriangles.length / 3 <= kMeshletMaxTriangles)
do {
    size_t vertexCount = meshletVertices.length;
    size_t triangleCount = meshletTriangles.length / 3;
    ubyte[] indices = meshletTriangles;
    uint[] vertices = meshletVertices;

    ubyte[kMeshletMaxVertices] cache;
    cache[0 .. vertexCount] = 0;
    ubyte cacheLast = 128;
    enum ubyte cacheCutoff = 3;

    ubyte[kMeshletMaxVertices] valence;
    valence[0 .. vertexCount] = 0;
    foreach (i; 0 .. triangleCount) {
        ubyte a = indices[i * 3 + 0], b = indices[i * 3 + 1], c = indices[i * 3 + 2];
        assert(a < vertexCount && b < vertexCount && c < vertexCount);
        valence[a]++;
        valence[b]++;
        valence[c]++;
    }

    foreach (i; 0 .. triangleCount) {
        int next = -1;
        int nextScore = -1;
        int edges = 0;
        foreach (j; i .. triangleCount) {
            ubyte a = indices[j * 3 + 0], b = indices[j * 3 + 1], c = indices[j * 3 + 2];
            assert(a < vertexCount && b < vertexCount && c < vertexCount);
            ubyte ad = cast(ubyte)(cacheLast - cache[a]);
            ubyte bd = cast(ubyte)(cacheLast - cache[b]);
            ubyte cd = cast(ubyte)(cacheLast - cache[c]);
            int match = (ad < cacheCutoff) + (bd < cacheCutoff) + (cd < cacheCutoff);
            if (level) {
                int vmin = valence[a] < valence[b] ? valence[a] : valence[b];
                vmin = valence[c] < vmin ? valence[c] : vmin;
                int score = match * 1024 + (1023 - ad - bd - cd);
                score = score * 256 + (255 - vmin);
                next = (score > nextScore) ? cast(int) j : next;
                nextScore = (score > nextScore) ? score : nextScore;
                if (match >= 2 && ++edges >= level)
                    break;
            } else {
                int score = match;
                next = (score > nextScore) ? cast(int) j : next;
                nextScore = (score > nextScore) ? score : nextScore;
                if (match >= 2)
                    break;
            }
        }
        assert(next >= 0);
        ubyte a = indices[next * 3 + 0], b = indices[next * 3 + 1], c = indices[next * 3 + 2];

        // Slide triangles [i, next) forward one slot, then write the chosen triangle at i.
        size_t n = (cast(size_t) next - i) * 3;
        size_t begin = i * 3;
        foreach_reverse (k; 0 .. n)
            indices[begin + 3 + k] = indices[begin + k];
        indices[i * 3 + 0] = a;
        indices[i * 3 + 1] = b;
        indices[i * 3 + 2] = c;

        cacheLast++;
        cache[a] = cacheLast;
        cache[b] = cacheLast;
        cache[c] = cacheLast;
        valence[a]--;
        valence[b]--;
        valence[c]--;
    }

    if (level >= 1) {
        cache[0 .. vertexCount] = 0;
        foreach (i; 0 .. triangleCount) {
            ubyte a = indices[i * 3 + 0], b = indices[i * 3 + 1], c = indices[i * 3 + 2];
            if (!cache[a] && cache[b] && !cache[c]) {
                ubyte t = a;
                a = b;
                b = c;
                c = t;
            } else if (!cache[a] && !cache[b] && !cache[c]) {
                bool needab = false, needbc = false, needca = false;
                foreach (j; i + 1 .. triangleCount) {
                    if (j > i + cacheCutoff)
                        break;
                    ubyte oa = indices[j * 3 + 0], ob = indices[j * 3 + 1], oc = indices[j * 3 + 2];
                    needab |= (oa == b && ob == a) || (ob == b && oc == a) || (oc == b && oa == a);
                    needbc |= (oa == c && ob == b) || (ob == c && oc == b) || (oc == c && oa == b);
                    needca |= (oa == a && ob == c) || (ob == a && oc == c) || (oc == a && oa == c);
                }
                if (needab && !needbc) {
                    ubyte t = a;
                    a = b;
                    b = c;
                    c = t;
                } else if (needab && !needca) {
                    ubyte t = c;
                    c = b;
                    b = a;
                    a = t;
                } else if (!needab && needbc && !needca) {
                    ubyte t = c;
                    c = b;
                    b = a;
                    a = t;
                }
            }
            indices[i * 3 + 0] = a;
            indices[i * 3 + 1] = b;
            indices[i * 3 + 2] = c;
            cache[a] = cache[b] = cache[c] = 1;
        }
    }

    uint[kMeshletMaxVertices] order;
    short[kMeshletMaxVertices] remap;
    remap[0 .. vertexCount] = -1;
    size_t vertexOffset = 0;
    foreach (i; 0 .. triangleCount * 3) {
        ubyte local = indices[i];
        if (remap[local] < 0) {
            remap[local] = cast(short) vertexOffset;
            order[vertexOffset] = vertices[local];
            vertexOffset++;
        }
        indices[i] = cast(ubyte) remap[local];
    }
    assert(vertexOffset <= vertexCount);
    vertices[0 .. vertexOffset] = order[0 .. vertexOffset];
}

/// Level-0 meshlet reorder. `triangleCount` and `vertexCount` follow the C argument order.
void optimizeMeshlet(scope uint[] meshletVertices, scope ubyte[] meshletTriangles) nothrow @nogc
in (meshletVertices.length <= kMeshletMaxVertices)
in (meshletTriangles.length % 3 == 0)
in (meshletTriangles.length / 3 <= kMeshletMaxTriangles)
do {
    optimizeMeshletLevel(meshletVertices, meshletTriangles, 0);
}

/**
 * Build local indices so `vertices[triangles[i]] == indices[i]`.
 * Returns the number of unique vertices (at most 256).
 */
size_t extractMeshletIndices(scope uint[] vertices, scope ubyte[] triangles, scope const(uint)[] indices) nothrow @nogc
in (indices.length % 3 == 0)
in (indices.length / 3 <= kMeshletMaxTriangles)
in (triangles.length >= indices.length)
do {
    size_t unique = 0;
    short[1024] cache;
    cache[] = -1;
    foreach (i, v; indices) {
        uint key = v & 1023;
        short c = cache[key];
        if (c >= 0 && vertices[c] == v) {
            triangles[i] = cast(ubyte) c;
            continue;
        }
        if (c < 0) {
            assert(unique < kMeshletMaxVertices);
            cache[key] = cast(short) unique;
            triangles[i] = cast(ubyte) unique;
            vertices[unique++] = v;
            continue;
        }
        int pos = -1;
        foreach (j; 0 .. unique) {
            if (vertices[j] == v) {
                pos = cast(int) j;
                break;
            }
        }
        if (pos < 0) {
            assert(unique < kMeshletMaxVertices);
            pos = cast(int) unique;
            vertices[unique++] = v;
        }
        cache[key] = cast(short) pos;
        triangles[i] = cast(ubyte) pos;
    }
    assert(unique <= kMeshletMaxVertices);
    return unique;
}

@("meshlet.upstream") unittest {
    uint[4] vertices;
    ubyte[6] triangles;
    uint[6] indices = [0, 7, 15, 1039, 7, 15];
    size_t unique = extractMeshletIndices(vertices[], triangles[], indices[]);
    assert(unique == 4);
    foreach (i; 0 .. 6)
        assert(vertices[triangles[i]] == indices[i]);
    assert(vertices[0 .. 4] == [0, 7, 15, 1039]);
    assert(triangles[0 .. 6] == [0, 1, 2, 3, 1, 2]);

    // Sequential local indices after a level-0 reorder of a tiny strip.
    uint[4] mv = [3, 1, 2, 0];
    ubyte[6] mt = [0, 1, 2, 1, 2, 3];
    optimizeMeshlet(mv[], mt[]);
    int vmax = -1;
    foreach (b; mt[]) {
        assert(b <= vmax + 1);
        vmax = vmax < b ? b : vmax;
    }
    optimizeMeshletLevel(mv[], mt[], 0);
    optimizeMeshletLevel(mv[], mt[], 3);
}
