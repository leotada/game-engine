/// Terrain splat map: up to 8 layer weights per texel (two RGBA8 planes on
/// the GPU). The splat grid covers the whole terrain and may be coarser
/// than the height grid. `dominantLayer` is what physics uses for surface
/// materials, so a raycast reports the layer that is visibly on top.
module engine.terrain.splat;

import engine.core.pod : Pod;
import engine.terrain.heightmap : Heightmap;

@safe:

enum MAX_TERRAIN_LAYERS = 8;

struct SplatMap {
    uint width, height;
    /// `width * height * 8` weights (0..255), texel-major.
    Pod!ubyte[] weights;

    static SplatMap create(uint width, uint height) {
        SplatMap s;
        s.width = width;
        s.height = height;
        s.weights = new ubyte[cast(size_t) width * height * MAX_TERRAIN_LAYERS];
        return s;
    }

    /// Weights of texel (x, z) — 8 bytes.
    inout(ubyte)[] texel(uint x, uint z) inout pure nothrow @nogc return {
        immutable i = (cast(size_t) z * width + x) * MAX_TERRAIN_LAYERS;
        return weights[i .. i + MAX_TERRAIN_LAYERS];
    }

    /// Normalize weights in place so they sum to 255 (load time).
    void normalize() pure nothrow @nogc {
        foreach (t; 0 .. cast(size_t) width * height) {
            auto w = weights[t * MAX_TERRAIN_LAYERS .. (t + 1) * MAX_TERRAIN_LAYERS];
            uint sum = 0;
            foreach (v; w) sum += v;
            if (sum == 0) { w[0] = 255; continue; }
            uint acc = 0;
            foreach (ref v; w) { v = cast(ubyte)(v * 255 / sum); acc += v; }
            // Put rounding loss on the largest weight.
            size_t best = 0;
            foreach (i, v; w) if (v > w[best]) best = i;
            w[best] = cast(ubyte)(w[best] + (255 - acc));
        }
    }

    /// Splat texel under the world position (nearest; texel centers span the terrain).
    void texelFor(ref const Heightmap h, float wx, float wz, out uint tx, out uint tz) const pure nothrow @nogc {
        immutable u = (wx - h.desc.origin.x) / h.sizeX();
        immutable v = (wz - h.desc.origin.z) / h.sizeZ();
        int x = cast(int)(u * width);
        int z = cast(int)(v * height);
        if (x < 0) x = 0;
        if (z < 0) z = 0;
        if (x >= cast(int) width) x = width - 1;
        if (z >= cast(int) height) z = height - 1;
        tx = x;
        tz = z;
    }

    /// Index of the heaviest layer at a world position.
    ubyte dominantLayer(ref const Heightmap h, float wx, float wz) const pure nothrow @nogc {
        uint tx, tz;
        texelFor(h, wx, wz, tx, tz);
        auto w = texel(tx, tz);
        ubyte best = 0;
        foreach (i; 1 .. MAX_TERRAIN_LAYERS) if (w[i] > w[best]) best = cast(ubyte) i;
        return best;
    }

    /// The two RGBA8 planes (layers 0–3, 4–7) for `TextureArray.fromLayers`.
    void planes(out ubyte[] plane0, out ubyte[] plane1) const {
        immutable n = cast(size_t) width * height;
        plane0 = new ubyte[n * 4];
        plane1 = new ubyte[n * 4];
        foreach (t; 0 .. n) {
            plane0[t * 4 .. t * 4 + 4] = weights[t * 8 .. t * 8 + 4];
            plane1[t * 4 .. t * 4 + 4] = weights[t * 8 + 4 .. t * 8 + 8];
        }
    }
}

unittest {
    auto s = SplatMap.create(2, 1);
    s.texel(0, 0)[1] = 10;
    s.texel(0, 0)[3] = 30;
    s.normalize();
    uint sum = 0;
    foreach (v; s.texel(0, 0)) sum += v;
    assert(sum == 255 && s.texel(0, 0)[3] > s.texel(0, 0)[1]);
    assert(s.texel(1, 0)[0] == 255);
}
