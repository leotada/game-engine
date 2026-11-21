/// Terrain chunk grid: per-chunk bounds, distance-based LOD selection with
/// hysteresis, frustum culling, and the shared grid template mesh.
///
/// The template has no vertex buffer: vertex `i < G` (G = (C+1)²) is grid
/// point (i % (C+1), i / (C+1)) of a chunk; vertex `G + i` is the same point
/// pushed down by the skirt depth. One 16-bit index buffer holds every LOD
/// (step 1, 2, 4, …) followed by its skirt ring, so a frame needs one
/// instanced draw per LOD. Cells use the Box3D diagonal (x0,z1)–(x1,z0).
module engine.terrain.chunks;

import engine.core.pod : isPod, Pod;
import engine.math.bounds : Aabb;
import engine.math.frustum : Frustum;
import engine.math.vec : Vec3;
import engine.terrain.heightmap : Heightmap;

@safe:

enum MAX_TERRAIN_LODS = 5;

/// One instanced-draw instance (16 bytes): chunk origin in samples + LOD.
struct TerrainChunkInstance {
    float sampleX = 0, sampleZ = 0;
    float lod = 0;
    float pad = 0;
}

static assert(isPod!TerrainChunkInstance && TerrainChunkInstance.sizeof == 16);

/// Index range of one LOD inside the template index buffer.
struct LodRange {
    uint first, count;
}

/// Build the template index buffer for `chunkCells` and `lodCount` LODs.
ushort[] buildGridTemplate(uint chunkCells, uint lodCount, out LodRange[MAX_TERRAIN_LODS] ranges) {
    immutable uint V = chunkCells + 1;
    immutable uint G = V * V;
    assert(2 * G <= ushort.max + 1, "chunkCells too large for 16-bit indices");
    ushort[] idx;
    foreach (lod; 0 .. lodCount) {
        immutable uint s = 1u << lod;
        assert(s <= chunkCells);
        ranges[lod].first = cast(uint) idx.length;
        ushort at(uint x, uint z) { return cast(ushort)(z * V + x); }
        for (uint z = 0; z < chunkCells; z += s)
            for (uint x = 0; x < chunkCells; x += s) {
                immutable a = at(x, z), b = at(x + s, z), c = at(x, z + s), d = at(x + s, z + s);
                idx ~= [a, c, b, c, d, b];
            }
        // Skirts along the 4 borders, both windings (cheap, no culling issues).
        void skirt(ushort p, ushort q) {
            immutable ushort ps = cast(ushort)(p + G), qs = cast(ushort)(q + G);
            idx ~= [p, ps, q, q, ps, qs, p, q, ps, q, qs, ps];
        }
        for (uint t = 0; t < chunkCells; t += s) {
            skirt(at(t, 0), at(t + s, 0));
            skirt(at(t, chunkCells), at(t + s, chunkCells));
            skirt(at(0, t), at(0, t + s));
            skirt(at(chunkCells, t), at(chunkCells, t + s));
        }
        ranges[lod].count = cast(uint) idx.length - ranges[lod].first;
    }
    return idx;
}

struct TerrainLodSettings {
    uint lodCount = MAX_TERRAIN_LODS;
    /// LOD0 is used up to this distance (meters); LOD i up to `lod0Distance * 2^i`.
    float lod0Distance = 160.0f;
    /// Fraction of each LOD band over which vertices geomorph to the next LOD.
    float morphFraction = 0.3f;
    /// Relative distance margin before a chunk switches back to a finer LOD.
    float hysteresis = 0.08f;
    /// Coarsest LOD index used for shadow casters is at least this.
    uint shadowMinLod = 1;
    /// Chunks farther than this are not drawn (0 = no limit).
    float maxDistance = 0;
}

/// Per-chunk state and the per-frame visible lists.
struct TerrainChunks {
    uint chunksX, chunksZ, chunkCells;
    float cellSize = 1;
    Vec3 origin;
    TerrainLodSettings lod;
    Pod!Aabb[] bounds;
    Pod!ubyte[] lodOf;
    /// Visible instances grouped by LOD (`lodFirst[l] .. + lodCount[l]`).
    Pod!TerrainChunkInstance[] visible;
    uint[MAX_TERRAIN_LODS] lodFirst, lodCount;
    uint visibleCount;
    /// Scratch for shadow views.
    Pod!TerrainChunkInstance[] scratch;

    static TerrainChunks create(ref const Heightmap h, TerrainLodSettings lod = TerrainLodSettings.init) {
        TerrainChunks c;
        immutable C = h.desc.chunkCells;
        assert((h.desc.samplesX - 1) % C == 0 && (h.desc.samplesZ - 1) % C == 0,
               "terrain samples must be chunks * chunkCells + 1");
        c.chunkCells = C;
        c.chunksX = (h.desc.samplesX - 1) / C;
        c.chunksZ = (h.desc.samplesZ - 1) / C;
        c.cellSize = h.desc.cellSize;
        c.origin = h.desc.origin;
        if (lod.lodCount > MAX_TERRAIN_LODS) lod.lodCount = MAX_TERRAIN_LODS;
        while (lod.lodCount > 1 && (1u << (lod.lodCount - 1)) > C) lod.lodCount--;
        c.lod = lod;
        immutable n = c.chunksX * c.chunksZ;
        c.bounds = new Aabb[n];
        c.lodOf = new ubyte[n];
        c.visible = new TerrainChunkInstance[n];
        c.scratch = new TerrainChunkInstance[n];
        foreach (cz; 0 .. c.chunksZ)
            foreach (cx; 0 .. c.chunksX) {
                float lo, hi;
                h.rangeMinMax(cx * C, cz * C, (cx + 1) * C, (cz + 1) * C, lo, hi);
                Aabb b;
                b.min = Vec3(c.origin.x + cx * C * c.cellSize, lo, c.origin.z + cz * C * c.cellSize);
                b.max = Vec3(b.min.x + C * c.cellSize, hi, b.min.z + C * c.cellSize);
                c.bounds[cz * c.chunksX + cx] = b;
            }
        return c;
    }

    uint chunkCount() const pure nothrow @nogc { return chunksX * chunksZ; }

    /// Upper distance of LOD `l`'s band.
    float lodDistance(uint l) const pure nothrow @nogc { return lod.lod0Distance * (1u << l); }

    /// LOD for a chunk at `dist` given its previous LOD (hysteresis).
    uint selectLod(float dist, uint prev) const pure nothrow @nogc {
        uint l = 0;
        while (l + 1 < lod.lodCount && dist > lodDistance(l)) l++;
        // Only refine when clearly inside the finer band.
        if (l < prev && dist > lodDistance(l) * (1.0f - lod.hysteresis)) l = prev;
        return l;
    }

    /// Cull against the camera frustum, update LODs, and fill `visible`
    /// grouped by LOD. Returns the number of visible chunks.
    uint update(ref const Frustum view, Vec3 cameraPos) pure nothrow @nogc {
        uint[MAX_TERRAIN_LODS] counts;
        immutable n = chunkCount();
        foreach (i; 0 .. n) {
            immutable b = bounds[i];
            immutable d = distanceToAabb(b, cameraPos);
            immutable l = selectLod(d, lodOf[i]);
            lodOf[i] = cast(ubyte) l;
        }
        // Pass 1: count visible per LOD; pass 2: scatter.
        foreach (i; 0 .. n) if (isVisible(i, view, cameraPos)) counts[lodOf[i]]++;
        uint acc = 0;
        foreach (l; 0 .. MAX_TERRAIN_LODS) { lodFirst[l] = acc; lodCount[l] = 0; acc += counts[l]; }
        foreach (i; 0 .. n) {
            if (!isVisible(i, view, cameraPos)) continue;
            immutable l = lodOf[i];
            visible[lodFirst[l] + lodCount[l]++] = instanceFor(i, l);
        }
        visibleCount = acc;
        return acc;
    }

    /// Fill `out_` with the chunks inside `view`, grouped by LOD (at least
    /// `lod.shadowMinLod`), for one shadow view. Returns the count.
    uint gatherShadow(ref const Frustum view, scope Pod!TerrainChunkInstance[] out_,
                      ref uint[MAX_TERRAIN_LODS] first, ref uint[MAX_TERRAIN_LODS] count) const pure nothrow @nogc {
        uint[MAX_TERRAIN_LODS] cnt;
        immutable n = chunkCount();
        immutable minL = lod.shadowMinLod < lod.lodCount ? lod.shadowMinLod : lod.lodCount - 1;
        foreach (i; 0 .. n) {
            if (!view.intersectsAabb(bounds[i])) continue;
            immutable l = lodOf[i] > minL ? lodOf[i] : minL;
            cnt[l]++;
        }
        uint acc = 0;
        foreach (l; 0 .. MAX_TERRAIN_LODS) { first[l] = acc; count[l] = 0; acc += cnt[l]; }
        if (acc > out_.length) return 0;
        foreach (i; 0 .. n) {
            if (!view.intersectsAabb(bounds[i])) continue;
            immutable l = lodOf[i] > minL ? lodOf[i] : minL;
            out_[first[l] + count[l]++] = instanceFor(i, l);
        }
        return acc;
    }

    private bool isVisible(size_t i, ref const Frustum view, Vec3 cameraPos) const pure nothrow @nogc {
        if (lod.maxDistance > 0 && distanceToAabb(bounds[i], cameraPos) > lod.maxDistance) return false;
        return view.intersectsAabb(bounds[i]);
    }

    private TerrainChunkInstance instanceFor(size_t i, uint l) const pure nothrow @nogc {
        immutable cx = cast(uint)(i % chunksX), cz = cast(uint)(i / chunksX);
        return TerrainChunkInstance(cast(float)(cx * chunkCells), cast(float)(cz * chunkCells), cast(float) l, 0);
    }
}

float distanceToAabb(Aabb b, Vec3 p) pure nothrow @nogc {
    import std.math : sqrt;
    immutable dx = p.x < b.min.x ? b.min.x - p.x : (p.x > b.max.x ? p.x - b.max.x : 0);
    immutable dy = p.y < b.min.y ? b.min.y - p.y : (p.y > b.max.y ? p.y - b.max.y : 0);
    immutable dz = p.z < b.min.z ? b.min.z - p.z : (p.z > b.max.z ? p.z - b.max.z : 0);
    return sqrt(dx * dx + dy * dy + dz * dz);
}

unittest {
    LodRange[MAX_TERRAIN_LODS] r;
    auto idx = buildGridTemplate(8, 4, r);
    assert(r[0].first == 0);
    // LOD0: 64 cells * 6 + 4 borders * 8 segments * 12.
    assert(r[0].count == 64 * 6 + 4 * 8 * 12);
    assert(r[3].count == 1 * 6 + 4 * 1 * 12);
    assert(r[3].first + r[3].count == idx.length);
    foreach (i; idx) assert(i < 2 * 81);
}

unittest {
    import engine.terrain.heightmap : TerrainDesc;
    TerrainDesc d;
    d.samplesX = 4 * 16 + 1;
    d.samplesZ = 4 * 16 + 1;
    d.chunkCells = 16;
    d.cellSize = 10;
    auto h = Heightmap.create(d);
    TerrainLodSettings ls;
    ls.lod0Distance = 50;
    auto c = TerrainChunks.create(h, ls);
    assert(c.chunkCount() == 16 && c.lod.lodCount == MAX_TERRAIN_LODS);
    assert(c.selectLod(10, 0) == 0);
    assert(c.selectLod(120, 0) == 2);
    // Hysteresis: at 98 m (just below the LOD1 bound of 100) stay at LOD2.
    assert(c.selectLod(98, 2) == 2);
    assert(c.selectLod(80, 2) == 1);

    import engine.math.mat : Mat4;
    auto vp = Mat4.ortho(-1000, 1000, -1000, 1000, -1000, 1000);
    auto f = Frustum.fromViewProj(vp);
    immutable vis = c.update(f, Vec3(5, -45, 5)); // heights are at minHeight (-50)
    assert(vis == 16 && c.lodCount[0] >= 1);
    uint total = 0;
    foreach (l; 0 .. MAX_TERRAIN_LODS) total += c.lodCount[l];
    assert(total == 16);
    foreach (l; 0 .. MAX_TERRAIN_LODS)
        foreach (inst; c.visible[c.lodFirst[l] .. c.lodFirst[l] + c.lodCount[l]])
            assert(cast(uint) inst.lod == l);
}
