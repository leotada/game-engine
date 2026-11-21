/// Procedural terrain content so demos and tests need no assets: fBm +
/// ridged heights with a light erosion pass, a 4-biome splat map, generic
/// `ProcLayerDesc` PBR texture synthesis, and low-level heightfield-to-PBR
/// bakers. Load time only.
module engine.terrain.generate;

import std.math : abs, floor, sqrt, cos, sin, PI;

import engine.core.pod : isPod;
public import engine.math.noise : BrickSample, brickPatternTiled2D, fbmTiled2D,
    ridgedTiled2D, valueNoiseTiled2D, VoronoiSample, voronoiTiled2D;
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

/// Primary pattern basis for `ProcLayerDesc`.
enum ProcNoiseBasis : ubyte {
    /// Multi-octave tileable fBm (soils, grass, sand, asphalt, snow).
    fbm = 0,
    /// Multi-octave tileable ridged noise (cracked rock, mud, rough concrete).
    ridged = 1,
    /// Tileable Voronoi / Worley cells (gravel, aggregate, irregular stone).
    voronoi = 2,
    /// Tileable brick / paver / slab grid (cobblestone, sidewalk slabs, tiles).
    brick = 3,
}

/// Generic, game-agnostic POD descriptor for procedural tileable PBR layer
/// textures (linear albedo with height in alpha, tangent-space normal, ORM).
struct ProcLayerDesc {
    /// Base linear RGB color (valleys, pores, or mortar joints).
    float[3] color0 = [0.25f, 0.25f, 0.25f];
    /// Secondary linear RGB color (peaks or block faces).
    float[3] color1 = [0.45f, 0.45f, 0.45f];
    /// Per-cell random brightness/tint variation in `[0, 1]` (used by `voronoi` and `brick`).
    float cellColorVariation = 0.0f;

    /// Primary pattern basis.
    ProcNoiseBasis basis = ProcNoiseBasis.fbm;
    /// Horizontal tiling period across `[0, 1)` (clamped to `>= 1`).
    int periodX = 8;
    /// Vertical tiling period across `[0, 1)` (`0` reuses `periodX`).
    int periodY = 0;
    /// Octave count for `fbm`/`ridged` and fine grain detail.
    uint octaves = 4;
    /// Octave amplitude decay.
    float gain = 0.5f;
    /// Color interpolation contrast around `0.5` height.
    float contrast = 0.6f;
    /// Tileable domain-warp amplitude in UV units (`0` disables warp).
    float warp = 0.0f;

    /// Fine surface grain mixed over the primary pattern (`0` disables detail).
    float detailAmp = 0.0f;
    /// Frequency multiplier for the fine surface grain relative to `periodX`/`periodY`.
    int detailFreqMul = 4;

    /// Row horizontal offset for `ProcNoiseBasis.brick` (`0.5` = running bond, `0.0` = regular grid).
    float rowOffset = 0.5f;
    /// Mortar/grout joint width in `[0, 0.9]` for `brick` or bevel-edge threshold for `voronoi`.
    float mortarWidth = 0.08f;
    /// Edge bevel width for `brick` or `voronoi`.
    float bevelWidth = 0.08f;
    /// Feature point jitter in `[0, 1]` for `ProcNoiseBasis.voronoi`.
    float jitter = 0.85f;

    /// Central-difference normal map strength.
    float normalStrength = 3.0f;
    /// Base roughness in `[0, 1]`.
    float roughness = 0.8f;
    /// Height-driven roughness modulation (`(0.5 - h) * roughnessVariation`).
    float roughnessVariation = 0.1f;
    /// Cavity ambient occlusion strength in `[0, 1]` (`AO = 1 - aoStrength * (1 - h)`).
    float aoStrength = 0.4f;
    /// Base metallic value in `[0, 1]`.
    float metallic = 0.0f;
    /// Deterministic seed.
    uint seed = 5;
}

static assert(isPod!ProcLayerDesc);

/// Return a `ProcLayerDesc` preset for one of the 4 built-in demo biomes.
ProcLayerDesc biomeLayerDesc(BiomeLayer kind, uint seed = 5) pure nothrow @nogc {
    ProcLayerDesc d;
    d.seed = seed + cast(uint) kind * 1000u;
    d.octaves = 4;
    d.gain = 0.5f;
    d.aoStrength = 0.4f;
    d.roughnessVariation = 0.1f;
    final switch (kind) {
        case BiomeLayer.grass:
            d.color0 = [0.16f, 0.30f, 0.07f];
            d.color1 = [0.30f, 0.42f, 0.12f];
            d.roughness = 0.85f;
            d.periodX = 16;
            d.contrast = 0.6f;
            d.normalStrength = 3.0f;
            break;
        case BiomeLayer.rock:
            d.basis = ProcNoiseBasis.ridged;
            d.color0 = [0.30f, 0.28f, 0.26f];
            d.color1 = [0.52f, 0.50f, 0.47f];
            d.roughness = 0.75f;
            d.periodX = 6;
            d.contrast = 1.0f;
            d.normalStrength = 6.0f;
            break;
        case BiomeLayer.sand:
            d.color0 = [0.62f, 0.52f, 0.36f];
            d.color1 = [0.78f, 0.68f, 0.50f];
            d.roughness = 0.9f;
            d.periodX = 24;
            d.contrast = 0.4f;
            d.normalStrength = 3.0f;
            break;
        case BiomeLayer.snow:
            d.color0 = [0.80f, 0.84f, 0.90f];
            d.color1 = [0.95f, 0.97f, 1.00f];
            d.roughness = 0.55f;
            d.periodX = 8;
            d.contrast = 0.5f;
            d.normalStrength = 3.0f;
            break;
    }
    return d;
}

/// Bake a tileable tangent-space RGBA8 normal map from a `size × size` heightfield
/// (`heights` in `[0, 1]`) using toroidal central differences.
void bakeNormalsFromHeightField(scope const(float)[] heights, uint size, float strength,
                                scope ubyte[] outNormal) pure nothrow @nogc {
    immutable count = cast(size_t) size * size;
    assert(size > 0 && heights.length >= count && outNormal.length >= count * 4);
    foreach (y; 0 .. size) {
        immutable ym = (y + size - 1) % size;
        immutable yp = (y + 1) % size;
        foreach (x; 0 .. size) {
            immutable xm = (x + size - 1) % size;
            immutable xp = (x + 1) % size;
            immutable hl = heights[y * size + xm];
            immutable hr = heights[y * size + xp];
            immutable hd = heights[ym * size + x];
            immutable hu = heights[yp * size + x];
            immutable nv = Vec3((hl - hr) * strength, (hd - hu) * strength, 1.0f).normalized();
            immutable i = (y * size + x) * 4;
            outNormal[i + 0] = toByte(nv.x * 0.5f + 0.5f);
            outNormal[i + 1] = toByte(nv.y * 0.5f + 0.5f);
            outNormal[i + 2] = toByte(nv.z * 0.5f + 0.5f);
            outNormal[i + 3] = 255;
        }
    }
}

/// Bake tileable RGBA8 PBR maps (`outAlbedo` with height in alpha, `outNormal`, `outOrm`)
/// from a `size × size` heightfield in `[0, 1]` and optional per-texel `cellVariation` in `[-1, 1]`.
void bakePbrMapsFromHeightFieldInto(scope const(float)[] heights, uint size, const ProcLayerDesc desc,
                                    scope ubyte[] outAlbedo, scope ubyte[] outNormal, scope ubyte[] outOrm,
                                    scope const(float)[] cellVariation = null) pure nothrow @nogc {
    immutable count = cast(size_t) size * size;
    assert(size > 0 && heights.length >= count);
    assert(outAlbedo.length >= count * 4 && outNormal.length >= count * 4 && outOrm.length >= count * 4);
    immutable bool hasCell = cellVariation.length >= count && desc.cellColorVariation != 0.0f;
    foreach (i; 0 .. count) {
        immutable n = heights[i];
        immutable t = 0.5f + (n - 0.5f) * desc.contrast * 2.0f;
        immutable tt = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
        immutable float cellTint = hasCell ? (1.0f + cellVariation[i] * desc.cellColorVariation * 0.35f) : 1.0f;
        foreach (k; 0 .. 3) {
            immutable float c = (desc.color0[k] + (desc.color1[k] - desc.color0[k]) * tt) * cellTint;
            outAlbedo[i * 4 + k] = toByte(c);
        }
        outAlbedo[i * 4 + 3] = toByte(n);
        outOrm[i * 4 + 0] = toByte(1.0f - desc.aoStrength * (1.0f - n));
        outOrm[i * 4 + 1] = toByte(desc.roughness + (0.5f - n) * desc.roughnessVariation);
        outOrm[i * 4 + 2] = toByte(desc.metallic);
        outOrm[i * 4 + 3] = 255;
    }
    bakeNormalsFromHeightField(heights, size, desc.normalStrength, outNormal);
}

/// Allocating helper that bakes tileable RGBA8 PBR maps from a `size × size` heightfield.
void bakePbrMapsFromHeightField(scope const(float)[] heights, uint size, const ProcLayerDesc desc,
                                out ubyte[] albedo, out ubyte[] normal, out ubyte[] orm,
                                scope const(float)[] cellVariation = null) {
    immutable bytes = cast(size_t) size * size * 4;
    albedo = new ubyte[bytes];
    normal = new ubyte[bytes];
    orm = new ubyte[bytes];
    bakePbrMapsFromHeightFieldInto(heights, size, desc, albedo, normal, orm, cellVariation);
}

/// Evaluate a `ProcLayerDesc` into a `size × size` heightfield (`outHeights` in `[0, 1]`)
/// and optional per-texel `outCellVariation` in `[-1, 1]`.
void evaluateProcLayer(const ProcLayerDesc desc, uint size, scope float[] outHeights,
                       scope float[] outCellVariation = null) pure nothrow @nogc {
    immutable count = cast(size_t) size * size;
    assert(size > 0 && outHeights.length >= count);
    immutable bool writeCell = outCellVariation.length >= count;
    immutable int px = desc.periodX < 1 ? 1 : desc.periodX;
    immutable int py = desc.periodY < 1 ? px : desc.periodY;
    immutable int mul = desc.detailFreqMul < 1 ? 1 : desc.detailFreqMul;
    immutable float invSize = 1.0f / size;

    foreach (y; 0 .. size) {
        immutable float v = y * invSize;
        foreach (x; 0 .. size) {
            immutable float u = x * invSize;
            float wu = u, wv = v;
            if (desc.warp != 0.0f) {
                wu += (fbmTiled2D(u, v, px, py, 2, 0.5f, desc.seed + 3001u) - 0.5f) * desc.warp;
                wv += (fbmTiled2D(u, v, px, py, 2, 0.5f, desc.seed + 4001u) - 0.5f) * desc.warp;
            }
            float h = 0.5f;
            float cv = 0.0f;
            final switch (desc.basis) {
                case ProcNoiseBasis.fbm:
                    h = fbmTiled2D(wu, wv, px, py, desc.octaves, desc.gain, desc.seed);
                    break;
                case ProcNoiseBasis.ridged:
                    h = ridgedTiled2D(wu, wv, px, py, desc.octaves, desc.gain, desc.seed);
                    break;
                case ProcNoiseBasis.voronoi:
                    immutable VoronoiSample vs = voronoiTiled2D(wu, wv, px, py, desc.jitter, desc.seed);
                    if (desc.mortarWidth > 0.0f || desc.bevelWidth > 0.0f)
                        h = smooth01(desc.mortarWidth, desc.mortarWidth + desc.bevelWidth, vs.edge);
                    else
                        h = 1.0f - (vs.f1 > 1.0f ? 1.0f : vs.f1);
                    cv = vs.cellValue * 2.0f - 1.0f;
                    break;
                case ProcNoiseBasis.brick:
                    immutable BrickSample bs = brickPatternTiled2D(
                        wu, wv, px, py, desc.rowOffset, desc.mortarWidth, desc.bevelWidth, desc.seed);
                    h = bs.height;
                    cv = (bs.cellValue * 2.0f - 1.0f) * bs.mask;
                    break;
            }
            if (desc.detailAmp != 0.0f) {
                immutable float det = fbmTiled2D(wu, wv, px * mul, py * mul, desc.octaves, desc.gain, desc.seed + 7919u);
                h += (det - 0.5f) * desc.detailAmp;
            }
            h = h < 0.0f ? 0.0f : (h > 1.0f ? 1.0f : h);
            immutable i = cast(size_t) y * size + x;
            outHeights[i] = h;
            if (writeCell) outCellVariation[i] = cv;
        }
    }
}

/// Zero-GC procedural texture synthesis into caller-provided buffers (`size × size` texels).
void generateLayerTexturesInto(const ProcLayerDesc desc, uint size,
                               scope float[] scratchHeights, scope float[] scratchCellVar,
                               scope ubyte[] outAlbedo, scope ubyte[] outNormal,
                               scope ubyte[] outOrm) pure nothrow @nogc {
    evaluateProcLayer(desc, size, scratchHeights, scratchCellVar);
    bakePbrMapsFromHeightFieldInto(scratchHeights, size, desc, outAlbedo, outNormal, outOrm, scratchCellVar);
}

/// Tileable procedural layer textures (`size²` RGBA8 each) from a generic `ProcLayerDesc`.
void generateLayerTextures(const ProcLayerDesc desc, uint size, out ubyte[] albedo,
                           out ubyte[] normal, out ubyte[] orm) {
    immutable count = cast(size_t) size * size;
    auto hgt = new float[count];
    auto cell = new float[count];
    albedo = new ubyte[count * 4];
    normal = new ubyte[count * 4];
    orm = new ubyte[count * 4];
    generateLayerTexturesInto(desc, size, hgt, cell, albedo, normal, orm);
}

/// Tileable procedural layer textures (`size²` RGBA8 each): albedo with
/// height in alpha, tangent-space normal (RGB), ORM (occlusion, roughness,
/// metalness).
void generateLayerTextures(BiomeLayer kind, uint size, out ubyte[] albedo, out ubyte[] normal,
                           out ubyte[] orm, uint seed = 5) {
    generateLayerTextures(biomeLayerDesc(kind, seed), size, albedo, normal, orm);
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

    // Generic ProcLayerDesc across all 4 bases.
    foreach (basis; [ProcNoiseBasis.fbm, ProcNoiseBasis.ridged, ProcNoiseBasis.voronoi, ProcNoiseBasis.brick]) {
        ProcLayerDesc pd;
        pd.basis = basis;
        pd.periodX = 4;
        pd.periodY = 6;
        pd.cellColorVariation = 0.2f;
        pd.detailAmp = 0.1f;
        pd.warp = 0.03f;
        pd.roughness = 0.65f;
        pd.metallic = 0.1f;
        generateLayerTextures(pd, 16, a, n, o);
        assert(a.length == 16 * 16 * 4 && n.length == 16 * 16 * 4 && o.length == 16 * 16 * 4);
        assert(n[2] > 128);
        assert(o[2] > 20 && o[2] < 35); // metallic ~0.1 -> ~26
    }

    // Zero-GC Into path and custom heightfield baking.
    () @nogc {
        float[16 * 16] hBuf;
        float[16 * 16] cBuf;
        ubyte[16 * 16 * 4] aBuf, nBuf, oBuf;
        ProcLayerDesc pd;
        pd.basis = ProcNoiseBasis.brick;
        pd.periodX = 4;
        generateLayerTexturesInto(pd, 16, hBuf[], cBuf[], aBuf[], nBuf[], oBuf[]);
        assert(nBuf[2] > 128);

        foreach (idx, ref hv; hBuf) hv = (idx % 16) / 15.0f;
        bakePbrMapsFromHeightFieldInto(hBuf[], 16, pd, aBuf[], nBuf[], oBuf[]);
        assert(aBuf[3] == 0 && aBuf[15 * 4 + 3] == 255);
    }();
}
