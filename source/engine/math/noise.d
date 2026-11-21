/// Deterministic pure-D procedural noise and pattern functions (value, simplex,
/// FBM, ridged, plus tileable 2D noise, Voronoi, and brick/grid samplers).
/// Suitable for CPU mesh synthesis, terrain, asteroids, and procedural textures.
module engine.math.noise;

import std.math : floor, sqrt;

pure nothrow @nogc @safe:

private uint hashU32(uint x) {
    x ^= x >> 16;
    x *= 0x7FEB_352Du;
    x ^= x >> 15;
    x *= 0x846C_A68Bu;
    x ^= x >> 16;
    return x;
}

private uint hash2(int x, int y, uint seed) {
    uint h = seed ^ (cast(uint) x * 0x9E37_79B1u);
    h ^= cast(uint) y * 0x85EB_CA77u;
    return hashU32(h);
}

private uint hash3(int x, int y, int z, uint seed) {
    uint h = seed ^ (cast(uint) x * 0x9E37_79B1u);
    h ^= cast(uint) y * 0x85EB_CA77u;
    h ^= cast(uint) z * 0xC2B2_AE3Du;
    return hashU32(h);
}

private float hashTo01(uint h) {
    return cast(float)(h & 0x00FF_FFFFu) * (1.0f / 16_777_216.0f);
}

private float smoothstep5(float t) {
    return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f);
}

private float lerpf(float a, float b, float t) {
    return a + (b - a) * t;
}

private int fastFloor(float x) {
    immutable int i = cast(int) x;
    return x < cast(float) i ? i - 1 : i;
}

/// 2D lattice value noise in [0, 1].
float valueNoise2D(float x, float y, uint seed = 0) {
    immutable int ix = fastFloor(x);
    immutable int iy = fastFloor(y);
    immutable float fx = smoothstep5(x - ix);
    immutable float fy = smoothstep5(y - iy);

    immutable float v00 = hashTo01(hash2(ix,     iy,     seed));
    immutable float v10 = hashTo01(hash2(ix + 1, iy,     seed));
    immutable float v01 = hashTo01(hash2(ix,     iy + 1, seed));
    immutable float v11 = hashTo01(hash2(ix + 1, iy + 1, seed));

    return lerpf(lerpf(v00, v10, fx), lerpf(v01, v11, fx), fy);
}

/// 3D lattice value noise in [0, 1].
float valueNoise3D(float x, float y, float z, uint seed = 0) {
    immutable int ix = fastFloor(x);
    immutable int iy = fastFloor(y);
    immutable int iz = fastFloor(z);
    immutable float fx = smoothstep5(x - ix);
    immutable float fy = smoothstep5(y - iy);
    immutable float fz = smoothstep5(z - iz);

    immutable float c000 = hashTo01(hash3(ix,     iy,     iz,     seed));
    immutable float c100 = hashTo01(hash3(ix + 1, iy,     iz,     seed));
    immutable float c010 = hashTo01(hash3(ix,     iy + 1, iz,     seed));
    immutable float c110 = hashTo01(hash3(ix + 1, iy + 1, iz,     seed));
    immutable float c001 = hashTo01(hash3(ix,     iy,     iz + 1, seed));
    immutable float c101 = hashTo01(hash3(ix + 1, iy,     iz + 1, seed));
    immutable float c011 = hashTo01(hash3(ix,     iy + 1, iz + 1, seed));
    immutable float c111 = hashTo01(hash3(ix + 1, iy + 1, iz + 1, seed));

    immutable float x00 = lerpf(c000, c100, fx);
    immutable float x10 = lerpf(c010, c110, fx);
    immutable float x01 = lerpf(c001, c101, fx);
    immutable float x11 = lerpf(c011, c111, fx);

    return lerpf(lerpf(x00, x10, fy), lerpf(x01, x11, fy), fz);
}

private float grad2(uint h, float x, float y) {
    final switch (h & 7u) {
        case 0: return  x + y;
        case 1: return -x + y;
        case 2: return  x - y;
        case 3: return -x - y;
        case 4: return  x * 1.41421356f;
        case 5: return -x * 1.41421356f;
        case 6: return  y * 1.41421356f;
        case 7: return -y * 1.41421356f;
    }
}

private float grad3(uint h, float x, float y, float z) {
    switch (h & 15u) {
        case  0: return  x + y;
        case  1: return -x + y;
        case  2: return  x - y;
        case  3: return -x - y;
        case  4: return  x + z;
        case  5: return -x + z;
        case  6: return  x - z;
        case  7: return -x - z;
        case  8: return  y + z;
        case  9: return -y + z;
        case 10: return  y - z;
        case 11: return -y - z;
        case 12: return  y + x;
        case 13: return -y + z;
        case 14: return  y - x;
        default: return -y - z;
    }
}

/// 2D simplex gradient noise in approximately [-1, 1].
float simplex2D(float x, float y, uint seed = 0) {
    enum float F2 = 0.36602540378f; // 0.5 * (sqrt(3) - 1)
    enum float G2 = 0.21132486540f; // (3 - sqrt(3)) / 6

    immutable float s = (x + y) * F2;
    immutable int i = fastFloor(x + s);
    immutable int j = fastFloor(y + s);
    immutable float t = cast(float)(i + j) * G2;
    immutable float x0 = x - (cast(float) i - t);
    immutable float y0 = y - (cast(float) j - t);

    immutable int i1 = x0 > y0 ? 1 : 0;
    immutable int j1 = x0 > y0 ? 0 : 1;

    immutable float x1 = x0 - cast(float) i1 + G2;
    immutable float y1 = y0 - cast(float) j1 + G2;
    immutable float x2 = x0 - 1.0f + 2.0f * G2;
    immutable float y2 = y0 - 1.0f + 2.0f * G2;

    float n0 = 0.0f, n1 = 0.0f, n2 = 0.0f;

    float t0 = 0.5f - x0 * x0 - y0 * y0;
    if (t0 > 0.0f) {
        t0 *= t0;
        n0 = t0 * t0 * grad2(hash2(i, j, seed), x0, y0);
    }

    float t1 = 0.5f - x1 * x1 - y1 * y1;
    if (t1 > 0.0f) {
        t1 *= t1;
        n1 = t1 * t1 * grad2(hash2(i + i1, j + j1, seed), x1, y1);
    }

    float t2 = 0.5f - x2 * x2 - y2 * y2;
    if (t2 > 0.0f) {
        t2 *= t2;
        n2 = t2 * t2 * grad2(hash2(i + 1, j + 1, seed), x2, y2);
    }

    immutable float v = 70.0f * (n0 + n1 + n2);
    return v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);
}

/// 3D simplex gradient noise in approximately [-1, 1].
float simplex3D(float x, float y, float z, uint seed = 0) {
    enum float F3 = 1.0f / 3.0f;
    enum float G3 = 1.0f / 6.0f;

    immutable float s = (x + y + z) * F3;
    immutable int i = fastFloor(x + s);
    immutable int j = fastFloor(y + s);
    immutable int k = fastFloor(z + s);
    immutable float t = cast(float)(i + j + k) * G3;
    immutable float x0 = x - (cast(float) i - t);
    immutable float y0 = y - (cast(float) j - t);
    immutable float z0 = z - (cast(float) k - t);

    int i1, j1, k1;
    int i2, j2, k2;
    if (x0 >= y0) {
        if (y0 >= z0)      { i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 1; k2 = 0; }
        else if (x0 >= z0) { i1 = 1; j1 = 0; k1 = 0; i2 = 1; j2 = 0; k2 = 1; }
        else               { i1 = 0; j1 = 0; k1 = 1; i2 = 1; j2 = 0; k2 = 1; }
    } else {
        if (y0 < z0)       { i1 = 0; j1 = 0; k1 = 1; i2 = 0; j2 = 1; k2 = 1; }
        else if (x0 < z0)  { i1 = 0; j1 = 1; k1 = 0; i2 = 0; j2 = 1; k2 = 1; }
        else               { i1 = 0; j1 = 1; k1 = 0; i2 = 1; j2 = 1; k2 = 0; }
    }

    immutable float x1 = x0 - cast(float) i1 + G3;
    immutable float y1 = y0 - cast(float) j1 + G3;
    immutable float z1 = z0 - cast(float) k1 + G3;
    immutable float x2 = x0 - cast(float) i2 + 2.0f * G3;
    immutable float y2 = y0 - cast(float) j2 + 2.0f * G3;
    immutable float z2 = z0 - cast(float) k2 + 2.0f * G3;
    immutable float x3 = x0 - 1.0f + 3.0f * G3;
    immutable float y3 = y0 - 1.0f + 3.0f * G3;
    immutable float z3 = z0 - 1.0f + 3.0f * G3;

    float n0 = 0, n1 = 0, n2 = 0, n3 = 0;

    float t0 = 0.6f - x0 * x0 - y0 * y0 - z0 * z0;
    if (t0 > 0) { t0 *= t0; n0 = t0 * t0 * grad3(hash3(i, j, k, seed), x0, y0, z0); }

    float t1 = 0.6f - x1 * x1 - y1 * y1 - z1 * z1;
    if (t1 > 0) { t1 *= t1; n1 = t1 * t1 * grad3(hash3(i + i1, j + j1, k + k1, seed), x1, y1, z1); }

    float t2 = 0.6f - x2 * x2 - y2 * y2 - z2 * z2;
    if (t2 > 0) { t2 *= t2; n2 = t2 * t2 * grad3(hash3(i + i2, j + j2, k + k2, seed), x2, y2, z2); }

    float t3 = 0.6f - x3 * x3 - y3 * y3 - z3 * z3;
    if (t3 > 0) { t3 *= t3; n3 = t3 * t3 * grad3(hash3(i + 1, j + 1, k + 1, seed), x3, y3, z3); }

    immutable float v = 32.0f * (n0 + n1 + n2 + n3);
    return v < -1.0f ? -1.0f : (v > 1.0f ? 1.0f : v);
}

private int wrapPeriod(int v, int p) {
    if (p <= 1) return 0;
    immutable int r = v % p;
    return r < 0 ? r + p : r;
}

private float smoothStep01(float a, float b, float x) {
    if (b <= a) return x < a ? 0.0f : 1.0f;
    float t = (x - a) / (b - a);
    t = t < 0.0f ? 0.0f : (t > 1.0f ? 1.0f : t);
    return t * t * (3.0f - 2.0f * t);
}

/// Tileable 2D value noise in `[0, 1]` over normalized UVs with period `1.0`
/// across `periodX × periodY` lattice cells.
float valueNoiseTiled2D(float u, float v, int periodX, int periodY, uint seed = 0) {
    immutable int px = periodX < 1 ? 1 : periodX;
    immutable int py = periodY < 1 ? 1 : periodY;
    immutable float x = u * px;
    immutable float y = v * py;
    immutable int ix = fastFloor(x);
    immutable int iy = fastFloor(y);
    immutable float fx = smoothstep5(x - ix);
    immutable float fy = smoothstep5(y - iy);

    immutable int x0 = wrapPeriod(ix, px), x1 = wrapPeriod(ix + 1, px);
    immutable int y0 = wrapPeriod(iy, py), y1 = wrapPeriod(iy + 1, py);

    immutable float v00 = hashTo01(hash2(x0, y0, seed));
    immutable float v10 = hashTo01(hash2(x1, y0, seed));
    immutable float v01 = hashTo01(hash2(x0, y1, seed));
    immutable float v11 = hashTo01(hash2(x1, y1, seed));

    return lerpf(lerpf(v00, v10, fx), lerpf(v01, v11, fx), fy);
}

/// Square-period overload of `valueNoiseTiled2D`.
float valueNoiseTiled2D(float u, float v, int period, uint seed = 0) {
    return valueNoiseTiled2D(u, v, period, period, seed);
}

/// Tileable 2D Fractal Brownian Motion in `[0, 1]` over normalized UVs `(u, v)`.
/// Each octave doubles the integer cell periods `(periodX, periodY)` to preserve exact tiling.
float fbmTiled2D(float u, float v, int periodX, int periodY, uint octaves = 4, float gain = 0.5f, uint seed = 0) {
    if (octaves == 0) return 0.5f;
    int px = periodX < 1 ? 1 : periodX;
    int py = periodY < 1 ? 1 : periodY;
    float sum = 0.0f;
    float amp = 0.5f;
    float norm = 0.0f;
    foreach (i; 0 .. octaves) {
        sum += valueNoiseTiled2D(u, v, px, py, seed + i * 101u) * amp;
        norm += amp;
        px *= 2;
        py *= 2;
        amp *= gain;
    }
    return norm > 0.0f ? sum / norm : 0.5f;
}

/// Square-period overload of `fbmTiled2D`.
float fbmTiled2D(float u, float v, int period, uint octaves = 4, float gain = 0.5f, uint seed = 0) {
    return fbmTiled2D(u, v, period, period, octaves, gain, seed);
}

/// Tileable 2D ridged multifractal noise in `[0, 1]` over normalized UVs `(u, v)`.
float ridgedTiled2D(float u, float v, int periodX, int periodY, uint octaves = 4, float gain = 0.5f, uint seed = 0) {
    if (octaves == 0) return 0.0f;
    int px = periodX < 1 ? 1 : periodX;
    int py = periodY < 1 ? 1 : periodY;
    float sum = 0.0f;
    float amp = 0.5f;
    float norm = 0.0f;
    foreach (i; 0 .. octaves) {
        float n = valueNoiseTiled2D(u, v, px, py, seed + i * 197u) * 2.0f - 1.0f;
        if (n < 0.0f) n = -n;
        immutable float ridge = 1.0f - n;
        sum += ridge * ridge * amp;
        norm += amp;
        px *= 2;
        py *= 2;
        amp *= gain;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

/// Square-period overload of `ridgedTiled2D`.
float ridgedTiled2D(float u, float v, int period, uint octaves = 4, float gain = 0.5f, uint seed = 0) {
    return ridgedTiled2D(u, v, period, period, octaves, gain, seed);
}

/// Result of a tileable 2D Voronoi / Worley cellular sample.
struct VoronoiSample {
    float f1 = 0.0f;        /// Distance to nearest feature point (in cell units)
    float f2 = 0.0f;        /// Distance to second-nearest feature point (in cell units)
    float edge = 0.0f;      /// Distance to nearest cell border (`f2 - f1`)
    uint cellId = 0;        /// Deterministic hash of the winning cell
    float cellValue = 0.0f; /// Uniform random value in `[0, 1]` for the winning cell
}

/// Tileable 2D Voronoi / Worley cellular sampler over `cellsX × cellsY` cells.
VoronoiSample voronoiTiled2D(float u, float v, int cellsX, int cellsY, float jitter = 1.0f, uint seed = 0) {
    immutable int cx = cellsX < 1 ? 1 : cellsX;
    immutable int cy = cellsY < 1 ? 1 : cellsY;
    immutable float j = jitter < 0.0f ? 0.0f : (jitter > 1.0f ? 1.0f : jitter);
    immutable float px = u * cx;
    immutable float py = v * cy;
    immutable int ix = fastFloor(px);
    immutable int iy = fastFloor(py);

    float d1Sq = 1e9f;
    float d2Sq = 1e9f;
    uint bestId = 0;

    foreach (dy; -1 .. 2) {
        foreach (dx; -1 .. 2) {
            immutable int nx = ix + dx;
            immutable int ny = iy + dy;
            immutable int wx = wrapPeriod(nx, cx);
            immutable int wy = wrapPeriod(ny, cy);
            immutable uint cid = hash2(wx, wy, seed);
            immutable float ox = 0.5f + (hashTo01(cid) - 0.5f) * j;
            immutable float oy = 0.5f + (hashTo01(hashU32(cid ^ 0x9E37_79B9u)) - 0.5f) * j;
            immutable float fx = (nx + ox) - px;
            immutable float fy = (ny + oy) - py;
            immutable float dSq = fx * fx + fy * fy;
            if (dSq < d1Sq) {
                d2Sq = d1Sq;
                d1Sq = dSq;
                bestId = cid;
            } else if (dSq < d2Sq) {
                d2Sq = dSq;
            }
        }
    }

    VoronoiSample res;
    res.f1 = sqrt(d1Sq);
    res.f2 = sqrt(d2Sq);
    res.edge = res.f2 - res.f1;
    res.cellId = bestId;
    res.cellValue = hashTo01(hashU32(bestId ^ 0x85EB_CA6Bu));
    return res;
}

/// Square-grid overload of `voronoiTiled2D`.
VoronoiSample voronoiTiled2D(float u, float v, int cells, float jitter = 1.0f, uint seed = 0) {
    return voronoiTiled2D(u, v, cells, cells, jitter, seed);
}

/// Result of a tileable 2D brick / paver / slab grid sample.
struct BrickSample {
    float mask = 1.0f;      /// 0 in mortar/grout joint, 1 on block interior
    float height = 1.0f;    /// Beveled height profile in `[0, 1]`
    uint cellId = 0;        /// Deterministic hash of the block cell
    float cellValue = 0.0f; /// Uniform random value in `[0, 1]` for the block
    float localU = 0.0f;    /// Block-local U coordinate in `[0, 1]`
    float localV = 0.0f;    /// Block-local V coordinate in `[0, 1]`
}

/// Tileable 2D brick / cobblestone / sidewalk slab pattern over `cols × rows` blocks.
/// `rowOffset = 0.5` gives a running-bond paver pattern; `rowOffset = 0.0` gives a regular grid.
BrickSample brickPatternTiled2D(float u, float v, int cols, int rows,
                                  float rowOffset = 0.5f, float mortarWidth = 0.08f,
                                  float bevelWidth = 0.06f, uint seed = 0) {
    immutable int c = cols < 1 ? 1 : cols;
    immutable int r = rows < 1 ? 1 : rows;
    immutable float y = v * r;
    immutable int ry = fastFloor(y);
    immutable int wy = wrapPeriod(ry, r);
    immutable float x = u * c + wy * rowOffset;
    immutable int rx = fastFloor(x);
    immutable int wx = wrapPeriod(rx, c);

    immutable float lu = x - rx;
    immutable float lv = y - ry;
    immutable float dx = lu < (1.0f - lu) ? lu : (1.0f - lu);
    immutable float dy = lv < (1.0f - lv) ? lv : (1.0f - lv);
    immutable float edgeDist = (dx < dy ? dx : dy) * 2.0f;

    immutable float mw = mortarWidth < 0.0f ? 0.0f : (mortarWidth > 0.9f ? 0.9f : mortarWidth);
    immutable float bw = bevelWidth < 0.0f ? 0.0f : bevelWidth;
    immutable uint cid = hash2(wx, wy, seed);

    BrickSample res;
    res.mask = smoothStep01(mw * 0.5f, mw, edgeDist);
    res.height = smoothStep01(mw, mw + bw, edgeDist);
    res.cellId = cid;
    res.cellValue = hashTo01(cid);
    res.localU = lu;
    res.localV = lv;
    return res;
}

/// 2D Fractal Brownian Motion over `simplex2D`, normalized to approximately [-1, 1].
float fbm2D(float x, float y, uint octaves = 4, float lacunarity = 2.0f, float gain = 0.5f, uint seed = 0) {
    if (octaves == 0) return 0.0f;
    float sum = 0.0f;
    float amp = 1.0f;
    float freq = 1.0f;
    float norm = 0.0f;
    foreach (i; 0 .. octaves) {
        sum += amp * simplex2D(x * freq, y * freq, seed + i * 131u);
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

/// 3D Fractal Brownian Motion over `simplex3D`, normalized to approximately [-1, 1].
float fbm3D(float x, float y, float z, uint octaves = 4, float lacunarity = 2.0f, float gain = 0.5f, uint seed = 0) {
    if (octaves == 0) return 0.0f;
    float sum = 0.0f;
    float amp = 1.0f;
    float freq = 1.0f;
    float norm = 0.0f;
    foreach (i; 0 .. octaves) {
        sum += amp * simplex3D(x * freq, y * freq, z * freq, seed + i * 131u);
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

/// 2D ridged multifractal noise in [0, 1].
float ridged2D(float x, float y, uint octaves = 4, float lacunarity = 2.0f, float gain = 0.5f, uint seed = 0) {
    if (octaves == 0) return 0.0f;
    float sum = 0.0f;
    float amp = 1.0f;
    float freq = 1.0f;
    float norm = 0.0f;
    foreach (i; 0 .. octaves) {
        float n = simplex2D(x * freq, y * freq, seed + i * 197u);
        if (n < 0.0f) n = -n;
        immutable float ridge = 1.0f - n;
        sum += amp * ridge * ridge;
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

/// 3D ridged multifractal noise in [0, 1].
float ridged3D(float x, float y, float z, uint octaves = 4, float lacunarity = 2.0f, float gain = 0.5f, uint seed = 0) {
    if (octaves == 0) return 0.0f;
    float sum = 0.0f;
    float amp = 1.0f;
    float freq = 1.0f;
    float norm = 0.0f;
    foreach (i; 0 .. octaves) {
        float n = simplex3D(x * freq, y * freq, z * freq, seed + i * 197u);
        if (n < 0.0f) n = -n;
        immutable float ridge = 1.0f - n;
        sum += amp * ridge * ridge;
        norm += amp;
        amp *= gain;
        freq *= lacunarity;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

unittest {
    // Determinism, bounds, and continuity checks.
    assert(valueNoise2D(1.5f, 2.5f, 7) == valueNoise2D(1.5f, 2.5f, 7));
    assert(simplex3D(1.5f, -2.3f, 0.7f, 42) == simplex3D(1.5f, -2.3f, 0.7f, 42));

    float minV = 10.0f, maxV = -10.0f;
    float minS = 10.0f, maxS = -10.0f;
    foreach (ix; -10 .. 11) {
        foreach (iy; -10 .. 11) {
            immutable x = ix * 0.37f;
            immutable y = iy * 0.41f;
            immutable v = valueNoise3D(x, y, x - y, 3);
            assert(v >= 0.0f && v <= 1.0f);
            if (v < minV) minV = v;
            if (v > maxV) maxV = v;

            immutable s = simplex3D(x, y, x + y, 3);
            assert(s >= -1.0f && s <= 1.0f);
            if (s < minS) minS = s;
            if (s > maxS) maxS = s;

            immutable f = fbm3D(x, y, 0.5f, 4);
            assert(f >= -1.0f && f <= 1.0f);
            immutable r = ridged3D(x, y, 0.5f, 4);
            assert(r >= 0.0f && r <= 1.0f);
        }
    }
    assert(maxV > minV + 0.2f);
    assert(maxS > minS + 0.2f);

    // Continuity: small step yields small delta.
    immutable a = simplex2D(3.14f, 1.59f);
    immutable b = simplex2D(3.141f, 1.591f);
    assert((a - b) * (a - b) < 0.01f);

    // Tileable 2D noise and pattern periodicity + bounds checks.
    foreach (k; 0 .. 8) {
        immutable float t = k * 0.125f;
        assert(valueNoiseTiled2D(0.0f, t, 6, 4, 11) == valueNoiseTiled2D(1.0f, t, 6, 4, 11));
        assert(valueNoiseTiled2D(t, 0.0f, 6, 4, 11) == valueNoiseTiled2D(t, 1.0f, 6, 4, 11));

        immutable float fb0 = fbmTiled2D(0.0f, t, 4, 4, 4, 0.5f, 12);
        immutable float fb1 = fbmTiled2D(1.0f, t, 4, 4, 4, 0.5f, 12);
        assert(fb0 == fb1 && fb0 >= 0.0f && fb0 <= 1.0f);

        immutable float rg0 = ridgedTiled2D(t, 0.0f, 4, 6, 4, 0.5f, 13);
        immutable float rg1 = ridgedTiled2D(t, 1.0f, 4, 6, 4, 0.5f, 13);
        assert(rg0 == rg1 && rg0 >= 0.0f && rg0 <= 1.0f);

        immutable auto vo0 = voronoiTiled2D(0.0f, t, 5, 5, 0.85f, 14);
        immutable auto vo1 = voronoiTiled2D(1.0f, t, 5, 5, 0.85f, 14);
        assert(vo0.cellId == vo1.cellId && vo0.edge >= 0.0f);

        immutable auto br0 = brickPatternTiled2D(0.0f, t, 4, 8, 0.5f, 0.08f, 0.06f, 15);
        immutable auto br1 = brickPatternTiled2D(1.0f, t, 4, 8, 0.5f, 0.08f, 0.06f, 15);
        assert(br0.cellId == br1.cellId && br0.height >= 0.0f && br0.height <= 1.0f);
    }
}
