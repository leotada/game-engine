/**
 * LOD chains for objects made of several meshes (a tree: trunk, leaves,
 * flowers). Every part gets the same number of levels and the same error per
 * level, measured in object units, so all parts of an instance pick the same
 * level when they also share their culling sphere (`StaticInstanceDesc
 * .objectId`). The whole object turns simpler at once.
 *
 * Load time only: allocates and runs the simplifier.
 */
module engine.graphics.object_lod;

import engine.graphics.types : TexVert;

@safe:

/// How far the levels go.
struct ObjectLodSettings {
    /// Levels including the full mesh (at most 8).
    uint levels = 4;
    /// Triangle share of each level relative to the previous one.
    float ratio = 0.4f;
    /// Largest simplifier error accepted, relative to each part's size. Foliage
    /// tolerates a lot: a crown seen from afar only needs its silhouette.
    float maxError = 0.25f;
    /// Keep normals and UVs where they matter (slower collapse). Off suits
    /// foliage blobs; on suits hard-surface parts.
    bool attributes = false;
    /// When the regular simplifier stalls above the target, cluster vertices
    /// (`simplifySloppy`). May open small holes, within the level's error.
    bool sloppy = true;
    /// A part never goes below this many triangles (tiny parts stay whole).
    uint minTriangles = 8;
    /**
     * The last level draws one merged mesh instead of the parts: an extra part
     * (the last one) holds every part's coarsest triangles with the part's
     * color per vertex (`partColors`), drawn with one vertex-color material.
     * It is empty at the other levels and the other parts are empty at the
     * last one, so one draw replaces several at a distance.
     */
    bool mergeFarLevel = false;
}

/// One part: its vertices (reordered for fetch) and one index list per level.
/// An empty level draws nothing (a dropped part).
struct ObjectLodPart {
    TexVert[] vertices;
    uint[][] levels;
    /// Linear RGBA8 per vertex (the merged far part only).
    ubyte[4][] colors;
}

/// Every part with the shared per-level errors (object units).
struct ObjectLod {
    ObjectLodPart[] parts;
    /// Largest error of any part at each level; level 0 is 0.
    float[] errors;

    /// Triangles of the whole object at `level`.
    size_t triangles(size_t level) const pure nothrow @nogc {
        size_t n = 0;
        foreach (ref p; parts) n += level < p.levels.length ? p.levels[level].length / 3 : 0;
        return n;
    }
}

/**
 * Build the levels of an object from its parts. Level `l` of each part aims at
 * `ratio^l` of its triangles. The error of a level is the largest error of
 * any part at that level, in object units (relative error times the part's
 * size), so a level only shows where every part is within it.
 *
 * `dropFromLevel[p]` (optional) empties part `p` from that level on; 0 keeps
 * it. `partColors[p]` colors part `p` in the merged far level
 * (`ObjectLodSettings.mergeFarLevel`).
 */
ObjectLod buildObjectLod(scope const(TexVert[])[] partVertices, scope const(uint[])[] partIndices,
                         ObjectLodSettings s = ObjectLodSettings.init,
                         scope const(uint)[] dropFromLevel = null,
                         scope const(ubyte[4])[] partColors = null) @trusted {
    import engine.meshopt.simplify : simplify, simplifyScale, simplifySloppy, simplifyWithAttributes;
    import engine.meshopt.types : FloatStream, SimplifyOptions, positionsOf;
    import engine.meshopt.vfetch : optimizeVertexFetch;
    assert(partVertices.length == partIndices.length);
    immutable uint levels = s.levels < 1 ? 1 : (s.levels > 8 ? 8 : s.levels);
    ObjectLod lod;
    lod.errors = new float[levels];
    lod.errors[] = 0;
    lod.parts = new ObjectLodPart[partVertices.length];
    foreach (pi; 0 .. partVertices.length) {
        const verts = partVertices[pi];
        const base = partIndices[pi];
        auto positions = positionsOf!TexVert(verts);
        immutable float scale = verts.length ? simplifyScale(positions) : 0;
        float[] packed;
        FloatStream attributes;
        immutable float[5] weights = [0.5f, 0.5f, 0.5f, 0.25f, 0.25f];
        if (s.attributes) {
            packed = new float[verts.length * 5];
            foreach (i, ref v; verts) {
                packed[i * 5 .. i * 5 + 3] = v.normal[];
                packed[i * 5 + 3 .. i * 5 + 5] = v.uv[];
            }
            attributes.strideFloats = 5;
            attributes.count = verts.length;
            attributes.address = cast(size_t) packed.ptr;
        }
        uint[][] raw;
        raw ~= base.dup;
        foreach (l; 1 .. levels) {
            const prev = raw[$ - 1];
            double share = 1;
            foreach (_; 0 .. l) share *= s.ratio;
            size_t target = cast(size_t) (base.length * share);
            target -= target % 3;
            if (target < s.minTriangles * 3) target = s.minTriangles * 3;
            if (target >= prev.length || base.length < 6) {
                raw ~= prev.dup;
                continue;
            }
            auto dst = new uint[base.length];
            float[1] err = 0;
            size_t n = s.attributes
                ? simplifyWithAttributes(dst, base, positions, attributes, weights[], null, target, s.maxError,
                                         SimplifyOptions.none, err[])
                : simplify(dst, base, positions, target, s.maxError, SimplifyOptions.none, err[]);
            if (s.sloppy && n > target + target / 4) {
                auto sl = new uint[base.length];
                float[1] serr = 0;
                immutable sn = simplifySloppy(sl, base, positions, null, target, s.maxError, serr[]);
                if (sn > 0 && sn < n) {
                    n = sn;
                    dst = sl;
                    err[0] = serr[0];
                }
            }
            if (n == 0 || n >= prev.length) {
                raw ~= prev.dup;
                continue;
            }
            raw ~= dst[0 .. n].dup;
            immutable absErr = err[0] * scale;
            if (absErr > lod.errors[l]) lod.errors[l] = absErr;
        }
        // One vertex buffer per part, ordered for the concatenated levels.
        uint[] concat;
        foreach (r; raw) concat ~= r;
        auto compacted = new TexVert[verts.length];
        immutable fetched = optimizeVertexFetch((() @trusted => cast(ubyte[]) compacted)(), concat,
            (() @trusted => cast(const(ubyte)[]) verts)(), verts.length, TexVert.sizeof);
        lod.parts[pi].vertices = compacted[0 .. fetched];
        size_t at = 0;
        foreach (r; raw) {
            lod.parts[pi].levels ~= concat[at .. at + r.length];
            at += r.length;
        }
    }
    // Errors never decrease along the chain (a level replaces the finer one).
    foreach (l; 1 .. levels)
        if (lod.errors[l] < lod.errors[l - 1]) lod.errors[l] = lod.errors[l - 1];
    // Parts that vanish from a level on (small flowers, fruit): `dropFromLevel[p]`
    // is the first empty level, 0 = never. Level 0 always keeps every part.
    foreach (pi, from; dropFromLevel)
        if (pi < lod.parts.length && from > 0)
            foreach (l; from .. lod.parts[pi].levels.length) lod.parts[pi].levels[l] = null;
    if (s.mergeFarLevel && levels > 1) {
        ObjectLodPart merged;
        merged.levels = new uint[][levels];
        foreach (pi, ref p; lod.parts) {
            auto far = p.levels[levels - 1];
            p.levels[levels - 1] = null;
            if (far.length == 0) continue;
            ubyte[4] color = [255, 255, 255, 255];
            if (pi < partColors.length) color = partColors[pi];
            auto remap = new uint[p.vertices.length];
            remap[] = uint.max;
            foreach (i; far) {
                if (remap[i] == uint.max) {
                    remap[i] = cast(uint) merged.vertices.length;
                    merged.vertices ~= p.vertices[i];
                    merged.colors ~= color;
                }
                merged.levels[levels - 1] ~= remap[i];
            }
        }
        lod.parts ~= merged;
    }
    return lod;
}

version (WebGPU) {} else {
    import engine.gpu.context : GpuContext;
    import engine.graphics.texmesh : Closedness, TexMesh;

    /**
     * Upload one part with its levels in one index buffer and the object's
     * errors (object units, mesh scale 1). `closed` comes from the full level.
     */
    TexMesh uploadObjectLodPart(ref GpuContext gpu, ref const ObjectLod lod, size_t part) @trusted {
        import engine.graphics.closed_mesh : isClosedMesh;
        const p = &lod.parts[part];
        uint[8] first, counts;
        uint[] concat;
        foreach (l, level; p.levels) {
            first[l] = cast(uint) concat.length;
            counts[l] = cast(uint) level.length;
            concat ~= level;
        }
        // Closed when its fullest level is (the merged part has only the last one).
        immutable n = p.levels.length;
        size_t full = 0;
        foreach (l, level; p.levels) if (level.length > p.levels[full].length) full = l;
        immutable closed = n > 0 && isClosedMesh(p.vertices, p.levels[full]) ? Closedness.closed : Closedness.open;
        auto mesh = TexMesh.fromData(gpu, p.vertices, concat, null, closed);
        mesh.setLodChain(first[0 .. n], counts[0 .. n], lod.errors[0 .. n], 1);
        if (p.colors.length) mesh.setVertexColors(gpu, p.colors);
        return mesh;
    }
}

@("object_lod.shared errors") unittest {
    import engine.graphics.texmesh : texCubeIndices, texCubeVertices;
    import std.math : cos, PI, sin;
    // A finely tessellated ball (the crown) and a cube (the trunk).
    TexVert[] ball;
    uint[] bi;
    enum seg = 32, ring = 16;
    foreach (y; 0 .. ring + 1) foreach (x; 0 .. seg + 1) {
        immutable float phi = cast(float) PI * y / ring, th = 2 * cast(float) PI * x / seg;
        immutable float nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th);
        ball ~= TexVert([nx * 3, ny * 3 + 5, nz * 3], [nx, ny, nz], [cast(float) x / seg, cast(float) y / ring]);
    }
    foreach (y; 0 .. ring) foreach (x; 0 .. seg) {
        immutable a = y * (seg + 1) + x, b = a + seg + 1;
        bi ~= [a, a + 1, b, a + 1, b + 1, b];
    }
    uint[] ci;
    foreach (i; texCubeIndices) ci ~= i;
    auto lod = buildObjectLod([ball, texCubeVertices.dup], [bi, ci]);
    assert(lod.parts.length == 2 && lod.errors.length == 4);
    foreach (ref p; lod.parts) assert(p.levels.length == 4);
    // The whole object gets simpler, level after level, and errors only grow.
    foreach (l; 1 .. 4) {
        assert(lod.triangles(l) <= lod.triangles(l - 1));
        assert(lod.errors[l] >= lod.errors[l - 1]);
    }
    assert(lod.triangles(3) * 5 < lod.triangles(0));
    assert(lod.errors[0] == 0 && lod.errors[3] > 0);
    // The 12-triangle cube is under `minTriangles` * 3 / ratio^l: it never loses its shape.
    assert(lod.parts[1].levels[3].length >= 8 * 3 || lod.parts[1].levels[3].length == ci.length);

    // Drop the cube from level 2 on.
    auto dropped = buildObjectLod([ball, texCubeVertices.dup], [bi, ci], ObjectLodSettings.init, [0, 2]);
    assert(dropped.parts[1].levels[1].length > 0 && dropped.parts[1].levels[2].length == 0
           && dropped.parts[1].levels[3].length == 0);

    // Merge the far level into one colored part.
    ObjectLodSettings ms;
    ms.mergeFarLevel = true;
    immutable ubyte[4][2] colors = [[40, 120, 30, 255], [90, 60, 30, 255]];
    auto merged = buildObjectLod([ball, texCubeVertices.dup], [bi, ci], ms, null, colors[]);
    assert(merged.parts.length == 3);
    assert(merged.parts[0].levels[3].length == 0 && merged.parts[1].levels[3].length == 0);
    auto m = &merged.parts[2];
    assert(m.levels[0].length == 0 && m.levels[2].length == 0);
    assert(m.levels[3].length == lod.parts[0].levels[3].length + lod.parts[1].levels[3].length);
    assert(m.colors.length == m.vertices.length);
    bool green, brown;
    foreach (c; m.colors) { green |= c == colors[0]; brown |= c == colors[1]; }
    assert(green && brown);
    foreach (i; m.levels[3]) assert(i < m.vertices.length);
}
