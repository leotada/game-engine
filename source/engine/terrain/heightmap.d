/// Terrain height data (CPU side). Heights are stored quantized to 16 bits
/// over `[minHeight, maxHeight]` with exactly the scheme Box3D uses for its
/// heightfields, so the CPU queries (`heightAt`), the GPU mesh (decoded
/// floats in an `r32Float` texture) and the physics collider all see the
/// same surface. Cells are split along the diagonal from (x0, z1) to
/// (x1, z0), matching `b3CreateHeightField`.
module engine.terrain.heightmap;

import std.math : floor, sqrt;

import engine.core.pod : isPod, Pod;
import engine.math.vec : Vec3;

@safe:

/// Grid layout of a terrain. `samplesX/Z` must be `chunks * chunkCells + 1`.
struct TerrainDesc {
    uint samplesX = 1025;
    uint samplesZ = 1025;
    /// World distance between samples (meters).
    float cellSize = 1.0f;
    /// World position of sample (0, 0); heights are absolute world Y.
    Vec3 origin = Vec3(0, 0, 0);
    /// Quantization range of the heights.
    float minHeight = -50.0f;
    float maxHeight = 450.0f;
    /// Cells per render chunk side (power of two, ≤ 128 for 16-bit indices).
    uint chunkCells = 128;
}

static assert(isPod!TerrainDesc);

/// Height samples plus the derived per-chunk bounds.
struct Heightmap {
    TerrainDesc desc;
    /// Quantized heights, row-major (`z * samplesX + x`).
    Pod!ushort[] q;

    /// Height step of one quantum (Box3D: `range / UINT16_MAX`).
    float quantum() const pure nothrow @nogc {
        immutable r = desc.maxHeight - desc.minHeight;
        return (r > 0.005f ? r : 0.005f) / 65535.0f;
    }

    /// Allocate a flat terrain at `desc.minHeight` (load time).
    static Heightmap create(TerrainDesc desc) {
        Heightmap h;
        h.desc = desc;
        h.q = new ushort[cast(size_t) desc.samplesX * desc.samplesZ];
        return h;
    }

    /// Quantize `heights` (row-major, `samplesX * samplesZ`) with Box3D's rule.
    static Heightmap fromFloats(TerrainDesc desc, scope const(float)[] heights) {
        assert(heights.length == cast(size_t) desc.samplesX * desc.samplesZ, "Heightmap: size mismatch");
        auto h = create(desc);
        foreach (i, v; heights) h.q[i] = h.encode(v);
        return h;
    }

    /// Load a raw little-endian 16-bit height file (`samplesX * samplesZ`
    /// values, 0 = minHeight, 65535 = maxHeight) — e.g. World Machine /
    /// Gaea `.r16` exports.
    static Heightmap fromR16(TerrainDesc desc, scope const(ubyte)[] bytes) {
        immutable n = cast(size_t) desc.samplesX * desc.samplesZ;
        assert(bytes.length >= n * 2, "Heightmap.fromR16: file too small");
        auto h = create(desc);
        foreach (i; 0 .. n) h.q[i] = cast(ushort)(bytes[2 * i] | (bytes[2 * i + 1] << 8));
        return h;
    }

    ushort encode(float height) const pure nothrow @nogc {
        immutable c = height < desc.minHeight ? desc.minHeight : (height > desc.maxHeight ? desc.maxHeight : height);
        immutable s = (c - desc.minHeight) / quantum();
        return cast(ushort)(s < 65535.0f ? s : 65535.0f);
    }

    float decode(ushort v) const pure nothrow @nogc { return desc.minHeight + quantum() * v; }

    /// Height of sample (x, z), clamped to the grid.
    float sample(int x, int z) const pure nothrow @nogc {
        if (x < 0) x = 0;
        if (z < 0) z = 0;
        if (x >= cast(int) desc.samplesX) x = desc.samplesX - 1;
        if (z >= cast(int) desc.samplesZ) z = desc.samplesZ - 1;
        return decode(q[cast(size_t) z * desc.samplesX + x]);
    }

    void set(uint x, uint z, float height) pure nothrow @nogc {
        q[cast(size_t) z * desc.samplesX + x] = encode(height);
    }

    /// World size of the terrain on X / Z.
    float sizeX() const pure nothrow @nogc { return (desc.samplesX - 1) * desc.cellSize; }
    float sizeZ() const pure nothrow @nogc { return (desc.samplesZ - 1) * desc.cellSize; }

    bool contains(float wx, float wz) const pure nothrow @nogc {
        immutable lx = wx - desc.origin.x, lz = wz - desc.origin.z;
        return lx >= 0 && lz >= 0 && lx <= sizeX() && lz <= sizeZ();
    }

    /// Exact surface height at world (wx, wz) — the same triangle the
    /// physics heightfield and the LOD0 render mesh use.
    float heightAt(float wx, float wz) const pure nothrow @nogc {
        int cx, cz;
        float tx, tz;
        locate(wx, wz, cx, cz, tx, tz);
        immutable h00 = sample(cx, cz), h10 = sample(cx + 1, cz);
        immutable h01 = sample(cx, cz + 1), h11 = sample(cx + 1, cz + 1);
        if (tx + tz <= 1.0f)
            return h00 + (h10 - h00) * tx + (h01 - h00) * tz;
        return h11 + (h01 - h11) * (1.0f - tx) + (h10 - h11) * (1.0f - tz);
    }

    /// Face normal of the triangle under (wx, wz).
    Vec3 normalAt(float wx, float wz) const pure nothrow @nogc {
        int cx, cz;
        float tx, tz;
        locate(wx, wz, cx, cz, tx, tz);
        immutable s = desc.cellSize;
        immutable h00 = sample(cx, cz), h10 = sample(cx + 1, cz);
        immutable h01 = sample(cx, cz + 1), h11 = sample(cx + 1, cz + 1);
        float dx, dz; // dh/dx, dh/dz
        if (tx + tz <= 1.0f) {
            dx = (h10 - h00) / s;
            dz = (h01 - h00) / s;
        } else {
            dx = (h11 - h01) / s;
            dz = (h11 - h10) / s;
        }
        return Vec3(-dx, 1.0f, -dz).normalized();
    }

    /// Smooth normal at sample (x, z) from central differences (render normal map).
    Vec3 sampleNormal(int x, int z) const pure nothrow @nogc {
        immutable s = desc.cellSize;
        immutable dx = (sample(x + 1, z) - sample(x - 1, z)) / (2 * s);
        immutable dz = (sample(x, z + 1) - sample(x, z - 1)) / (2 * s);
        return Vec3(-dx, 1.0f, -dz).normalized();
    }

    /// Min / max height over samples [x0, x1] × [z0, z1] (inclusive).
    void rangeMinMax(uint x0, uint z0, uint x1, uint z1, out float lo, out float hi) const pure nothrow @nogc {
        ushort mn = ushort.max, mx = 0;
        foreach (z; z0 .. z1 + 1)
            foreach (v; q[cast(size_t) z * desc.samplesX + x0 .. cast(size_t) z * desc.samplesX + x1 + 1]) {
                if (v < mn) mn = v;
                if (v > mx) mx = v;
            }
        lo = decode(mn);
        hi = decode(mx);
    }

    private void locate(float wx, float wz, out int cx, out int cz, out float tx, out float tz) const pure nothrow @nogc {
        immutable fx = (wx - desc.origin.x) / desc.cellSize;
        immutable fz = (wz - desc.origin.z) / desc.cellSize;
        immutable maxX = cast(int) desc.samplesX - 2, maxZ = cast(int) desc.samplesZ - 2;
        cx = cast(int) floor(fx);
        cz = cast(int) floor(fz);
        if (cx < 0) cx = 0;
        if (cz < 0) cz = 0;
        if (cx > maxX) cx = maxX;
        if (cz > maxZ) cz = maxZ;
        tx = fx - cx;
        tz = fz - cz;
        tx = tx < 0 ? 0 : (tx > 1 ? 1 : tx);
        tz = tz < 0 ? 0 : (tz > 1 ? 1 : tz);
    }
}

unittest {
    TerrainDesc d;
    d.samplesX = 3;
    d.samplesZ = 3;
    d.cellSize = 2;
    d.minHeight = 0;
    d.maxHeight = 10;
    float[9] hs = [0, 2, 4, 0, 2, 4, 0, 2, 4]; // ramp along +X
    auto h = Heightmap.fromFloats(d, hs[]);
    assert(abs(h.heightAt(1, 1) - 1.0f) < 0.001f);
    assert(abs(h.heightAt(3, 3) - 3.0f) < 0.001f);
    auto n = h.normalAt(1, 1);
    assert(abs(n.x + 0.7071f) < 0.001f && abs(n.y - 0.7071f) < 0.001f && abs(n.z) < 0.001f);
    float lo, hi;
    h.rangeMinMax(0, 0, 2, 2, lo, hi);
    assert(lo < 0.001f && abs(hi - 4) < 0.001f);
}

private float abs(float v) pure nothrow @nogc { return v < 0 ? -v : v; }
