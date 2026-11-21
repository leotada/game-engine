/// Procedural terrain content so demos and tests need no assets: fBm +
/// ridged heights with a light erosion pass, a 4-biome splat map (grass,
/// rock, sand, snow by height and slope) and tileable layer textures
/// (linear albedo with height in alpha, tangent-space normal, ORM). Load time only.
module engine.terrain.generate;

import std.math : abs, floor, sqrt, cos, sin, PI;

import engine.math.vec : Vec3;
import engine.terrain.heightmap : Heightmap, TerrainDesc;
import engine.terrain.splat : SplatMap;

@safe:

struct TerrainGenSettings {
    uint seed = 1337;
    /// Feature size of the largest hills (meters).
    float baseWavelength = 900.0f;
    float hillHeight = 120.0f;
    float mountainHeight = 260.0f;
    /// Mountains occupy the region where the mask noise exceeds this.
    float mountainCoverage = 0.55f;
    uint octaves = 6;
    /// Thermal-erosion-like smoothing passes (cheap, at load).
    uint erosionPasses = 2;
    /// Flatten a disc of this radius around the terrain center (spawn area).
    float flatRadius = 60.0f;
    float flatHeight = 10.0f;
}

private uint hash2(int x, int y, uint seed) pure nothrow @nogc {
    uint h = cast(uint) x * 0x8da6b343u ^ cast(uint) y * 0xd8163841u ^ seed * 0xcb1ab31fu;
    h ^= h >> 13;
    h *= 0x5bd1e995u;
    h ^= h >> 15;
    return h;
}

private float lattice(int x, int y, uint seed) pure nothrow @nogc {
    return (hash2(x, y, seed) & 0xffffff) / cast(float) 0xffffff;
}

/// Smooth value noise in [0, 1].
float valueNoise(float x, float y, uint seed) pure nothrow @nogc {
    immutable xi = cast(int) floor(x), yi = cast(int) floor(y);
    immutable fx = x - xi, fy = y - yi;
    immutable ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy);
    immutable a = lattice(xi, yi, seed), b = lattice(xi + 1, yi, seed);
    immutable c = lattice(xi, yi + 1, seed), d = lattice(xi + 1, yi + 1, seed);
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy;
}

/// Tileable value noise (period `p` lattice cells).
private float valueNoiseTiled(float x, float y, int p, uint seed) pure nothrow @nogc {
    immutable xi = cast(int) floor(x), yi = cast(int) floor(y);
    immutable fx = x - xi, fy = y - yi;
    immutable ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy);
    int m(int v) { return ((v % p) + p) % p; }
    immutable a = lattice(m(xi), m(yi), seed), b = lattice(m(xi + 1), m(yi), seed);
    immutable c = lattice(m(xi), m(yi + 1), seed), d = lattice(m(xi + 1), m(yi + 1), seed);
    return (a + (b - a) * ux) + ((c + (d - c) * ux) - (a + (b - a) * ux)) * uy;
}

float fbm(float x, float y, uint octaves, uint seed) pure nothrow @nogc {
    float sum = 0, amp = 0.5f, norm = 0;
    foreach (o; 0 .. octaves) {
        sum += valueNoise(x, y, seed + o * 101) * amp;
        norm += amp;
        x = x * 2.03f + 17.1f;
        y = y * 2.03f - 9.7f;
        amp *= 0.5f;
    }
    return sum / norm;
}

float ridged(float x, float y, uint octaves, uint seed) pure nothrow @nogc {
    float sum = 0, amp = 0.5f, norm = 0, prev = 1;
    foreach (o; 0 .. octaves) {
        float n = 1.0f - abs(valueNoise(x, y, seed + o * 57) * 2 - 1);
        n = n * n * prev;
        prev = n;
        sum += n * amp;
        norm += amp;
        x = x * 2.1f + 3.3f;
        y = y * 2.1f + 7.9f;
        amp *= 0.5f;
    }
    return sum / norm;
}

private float smooth01(float a, float b, float x) pure nothrow @nogc {
    float t = (x - a) / (b - a);
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return t * t * (3 - 2 * t);
}

/// Generate a heightmap for `desc` (heights are quantized into its range).
Heightmap generateHeights(TerrainDesc desc, TerrainGenSettings s = TerrainGenSettings.init) {
    immutable n = cast(size_t) desc.samplesX * desc.samplesZ;
    auto hs = new float[n];
    immutable inv = 1.0f / s.baseWavelength;
    immutable cxw = desc.origin.x + (desc.samplesX - 1) * desc.cellSize * 0.5f;
    immutable czw = desc.origin.z + (desc.samplesZ - 1) * desc.cellSize * 0.5f;
    foreach (z; 0 .. desc.samplesZ) {
        immutable wz = desc.origin.z + z * desc.cellSize;
        foreach (x; 0 .. desc.samplesX) {
            immutable wx = desc.origin.x + x * desc.cellSize;
            // Light domain warp breaks up the lattice look.
            immutable warpX = (valueNoise(wx * inv * 0.7f, wz * inv * 0.7f, s.seed + 900) - 0.5f) * 0.6f;
            immutable warpZ = (valueNoise(wx * inv * 0.7f + 31, wz * inv * 0.7f, s.seed + 901) - 0.5f) * 0.6f;
            immutable px = wx * inv + warpX, pz = wz * inv + warpZ;
            float h = fbm(px, pz, s.octaves, s.seed) * s.hillHeight;
            immutable mask = smooth01(s.mountainCoverage, s.mountainCoverage + 0.2f,
                                      valueNoise(px * 0.35f, pz * 0.35f, s.seed + 7));
            h += ridged(px * 1.3f, pz * 1.3f, s.octaves, s.seed + 3) * s.mountainHeight * mask;
            if (s.flatRadius > 0) {
                immutable dx = wx - cxw, dz = wz - czw;
                immutable d = sqrt(dx * dx + dz * dz);
                immutable k = smooth01(s.flatRadius, s.flatRadius * 2.5f, d);
                h = s.flatHeight + (h - s.flatHeight) * k;
            }
            hs[cast(size_t) z * desc.samplesX + x] = h;
        }
    }
    // Erosion-lite: move material from steep cells toward lower neighbors.
    if (s.erosionPasses > 0) {
        auto tmp = new float[n];
        immutable talus = desc.cellSize * 0.9f;
        foreach (pass; 0 .. s.erosionPasses) {
            tmp[] = hs[];
            foreach (z; 1 .. desc.samplesZ - 1)
                foreach (x; 1 .. desc.samplesX - 1) {
                    immutable i = cast(size_t) z * desc.samplesX + x;
                    immutable c = hs[i];
                    float avg = (hs[i - 1] + hs[i + 1] + hs[i - desc.samplesX] + hs[i + desc.samplesX]) * 0.25f;
                    immutable diff = c - avg;
                    if (diff > talus) tmp[i] = c - (diff - talus) * 0.5f;
                    else if (-diff > talus) tmp[i] = c + (-diff - talus) * 0.25f;
                }
            hs[] = tmp[];
        }
    }
    return Heightmap.fromFloats(desc, hs);
}

/// Layer order used by `generateBiomeSplat` and `generateLayerTextures`.
enum BiomeLayer : ubyte { grass = 0, rock = 1, sand = 2, snow = 3 }

/// 4-biome splat map of `width × height` texels from height and slope.
SplatMap generateBiomeSplat(ref const Heightmap h, uint width, uint height,
                            float sandLevel = 14.0f, float snowLevel = 230.0f, uint seed = 99) {
    auto s = SplatMap.create(width, height);
    foreach (tz; 0 .. height)
        foreach (tx; 0 .. width) {
            immutable wx = h.desc.origin.x + (tx + 0.5f) / width * h.sizeX();
            immutable wz = h.desc.origin.z + (tz + 0.5f) / height * h.sizeZ();
            immutable y = h.heightAt(wx, wz);
            immutable sx = cast(int)((wx - h.desc.origin.x) / h.desc.cellSize);
            immutable sz = cast(int)((wz - h.desc.origin.z) / h.desc.cellSize);
            immutable slope = 1.0f - h.sampleNormal(sx, sz).y; // 0 flat .. 1 vertical
            immutable n = valueNoise(wx * 0.02f, wz * 0.02f, seed) - 0.5f;
            float rock = smooth01(0.12f, 0.25f, slope + n * 0.08f);
            float snow = smooth01(snowLevel - 20, snowLevel + 20, y + n * 40) * (1 - rock * 0.7f);
            float sand = (1 - smooth01(sandLevel - 4, sandLevel + 4, y + n * 6)) * (1 - rock);
            float grass = 1 - rock - snow - sand;
            if (grass < 0) grass = 0;
            auto t = s.texel(tx, tz);
            t[BiomeLayer.grass] = cast(ubyte)(grass * 255);
            t[BiomeLayer.rock] = cast(ubyte)(rock * 255);
            t[BiomeLayer.sand] = cast(ubyte)(sand * 255);
            t[BiomeLayer.snow] = cast(ubyte)(snow * 255);
        }
    s.normalize();
    return s;
}

/// Tileable procedural layer textures (`size²` RGBA8 each): albedo with
/// height in alpha, tangent-space normal (RGB), ORM (occlusion, roughness,
/// metalness).
void generateLayerTextures(BiomeLayer kind, uint size, out ubyte[] albedo, out ubyte[] normal,
                           out ubyte[] orm, uint seed = 5) {
    albedo = new ubyte[size * size * 4];
    normal = new ubyte[size * size * 4];
    orm = new ubyte[size * size * 4];
    auto hgt = new float[size * size];
    float[3] c0, c1;
    float rough, freq, contrast;
    final switch (kind) {
        case BiomeLayer.grass: c0 = [0.16f, 0.30f, 0.07f]; c1 = [0.30f, 0.42f, 0.12f]; rough = 0.85f; freq = 16; contrast = 0.6f; break;
        case BiomeLayer.rock:  c0 = [0.30f, 0.28f, 0.26f]; c1 = [0.52f, 0.50f, 0.47f]; rough = 0.75f; freq = 6;  contrast = 1.0f; break;
        case BiomeLayer.sand:  c0 = [0.62f, 0.52f, 0.36f]; c1 = [0.78f, 0.68f, 0.50f]; rough = 0.9f;  freq = 24; contrast = 0.4f; break;
        case BiomeLayer.snow:  c0 = [0.80f, 0.84f, 0.90f]; c1 = [0.95f, 0.97f, 1.00f]; rough = 0.55f; freq = 8;  contrast = 0.5f; break;
    }
    immutable uint sd = seed + cast(uint) kind * 1000;
    immutable int period = cast(int) freq;
    foreach (y; 0 .. size)
        foreach (x; 0 .. size) {
            immutable u = cast(float) x / size * period, v = cast(float) y / size * period;
            float n = 0, amp = 0.5f, norm = 0;
            int p = period;
            float fu = u, fv = v;
            foreach (o; 0 .. 4) {
                n += valueNoiseTiled(fu, fv, p, sd + o) * amp;
                norm += amp;
                fu *= 2; fv *= 2; p *= 2; amp *= 0.5f;
            }
            n /= norm;
            if (kind == BiomeLayer.rock) n = 1 - abs(n * 2 - 1); // cracks
            hgt[y * size + x] = n;
        }
    foreach (y; 0 .. size)
        foreach (x; 0 .. size) {
            immutable i = y * size + x;
            immutable n = hgt[i];
            immutable t = 0.5f + (n - 0.5f) * contrast * 2;
            immutable tt = t < 0 ? 0 : (t > 1 ? 1 : t);
            foreach (k; 0 .. 3) albedo[i * 4 + k] = toByte(c0[k] + (c1[k] - c0[k]) * tt);
            albedo[i * 4 + 3] = toByte(n);
            immutable hl = hgt[y * size + (x + size - 1) % size], hr = hgt[y * size + (x + 1) % size];
            immutable hd = hgt[((y + size - 1) % size) * size + x], hu = hgt[((y + 1) % size) * size + x];
            immutable strength = kind == BiomeLayer.rock ? 6.0f : 3.0f;
            immutable nv = Vec3((hl - hr) * strength, (hd - hu) * strength, 1.0f).normalized();
            normal[i * 4 + 0] = toByte(nv.x * 0.5f + 0.5f);
            normal[i * 4 + 1] = toByte(nv.y * 0.5f + 0.5f);
            normal[i * 4 + 2] = toByte(nv.z * 0.5f + 0.5f);
            normal[i * 4 + 3] = 255;
            orm[i * 4 + 0] = toByte(0.6f + 0.4f * n);
            orm[i * 4 + 1] = toByte(rough + (0.5f - n) * 0.1f);
            orm[i * 4 + 2] = 0;
            orm[i * 4 + 3] = 255;
        }
}

private ubyte toByte(float v) pure nothrow @nogc {
    v = v < 0 ? 0 : (v > 1 ? 1 : v);
    return cast(ubyte)(v * 255.0f + 0.5f);
}

unittest {
    TerrainDesc d;
    d.samplesX = 129;
    d.samplesZ = 129;
    d.cellSize = 4;
    auto h = generateHeights(d);
    float lo, hi;
    h.rangeMinMax(0, 0, 128, 128, lo, hi);
    assert(hi > lo + 5, "generated terrain must have relief");
    auto s = generateBiomeSplat(h, 32, 32);
    foreach (z; 0 .. 32)
        foreach (x; 0 .. 32) {
            uint sum = 0;
            foreach (v; s.texel(x, z)) sum += v;
            assert(sum == 255);
        }
    ubyte[] a, n, o;
    generateLayerTextures(BiomeLayer.rock, 16, a, n, o);
    assert(a.length == 16 * 16 * 4 && n[2] > 128);
}
