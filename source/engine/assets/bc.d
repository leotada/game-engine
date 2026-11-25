/// BC5 and BC7 block compression: CPU decoders (every BC7 mode) and encoders
/// (import time). The decoders match the GPU (`render-check --check=bc`).
module engine.assets.bc;

@safe:

/// Effort of the BC7 encoder.
enum BcQuality : ubyte {
    fast,   /// one subset (modes 5 and 6)
    normal, /// plus the best two-subset shapes (mode 1)
    high,   /// plus mode 4 and more shapes
}

enum uint BC_BLOCK_BYTES = 16;

/// Bytes of one BC5 / BC7 level.
size_t bcLevelBytes(uint width, uint height) pure nothrow @nogc {
    return cast(size_t)((width + 3) / 4) * ((height + 3) / 4) * BC_BLOCK_BYTES;
}

// ---------------------------------------------------------------- tables ---

private struct Mode {
    ubyte subsets, partitionBits, rotationBits, indexSelBits, colorBits, alphaBits;
    bool endpointP, sharedP;
    ubyte indexBits, indexBits2;
}

private immutable Mode[8] modes = [
    Mode(3, 4, 0, 0, 4, 0, true, false, 3, 0),
    Mode(2, 6, 0, 0, 6, 0, false, true, 3, 0),
    Mode(3, 6, 0, 0, 5, 0, false, false, 2, 0),
    Mode(2, 6, 0, 0, 7, 0, true, false, 2, 0),
    Mode(1, 0, 2, 1, 5, 6, false, false, 2, 3),
    Mode(1, 0, 2, 0, 7, 8, false, false, 2, 2),
    Mode(1, 0, 0, 0, 7, 7, true, false, 4, 0),
    Mode(2, 6, 0, 0, 5, 5, true, false, 2, 0),
];

private immutable ubyte[4] weights2 = [0, 21, 43, 64];
private immutable ubyte[8] weights3 = [0, 9, 18, 27, 37, 46, 55, 64];
private immutable ubyte[16] weights4 = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64];

private immutable(ubyte)[] weightsFor(uint bits) pure nothrow @nogc {
    return bits == 2 ? weights2[] : bits == 3 ? weights3[] : weights4[];
}

/// Subset of each texel, 64 shapes, one digit per texel.
private immutable string partition2 =
    "0011001100110011" ~ "0001000100010001" ~ "0111011101110111" ~ "0001001100110111" ~
    "0000000100010011" ~ "0011011101111111" ~ "0001001101111111" ~ "0000000100110111" ~
    "0000000000010011" ~ "0011011111111111" ~ "0000000101111111" ~ "0000000000010111" ~
    "0001011111111111" ~ "0000000011111111" ~ "0000111111111111" ~ "0000000000001111" ~
    "0000100011101111" ~ "0111000100000000" ~ "0000000010001110" ~ "0111001100010000" ~
    "0011000100000000" ~ "0000100011001110" ~ "0000000010001100" ~ "0111001100110001" ~
    "0011000100010000" ~ "0000100010001100" ~ "0110011001100110" ~ "0011011001101100" ~
    "0001011111101000" ~ "0000111111110000" ~ "0111000110001110" ~ "0011100110011100" ~
    "0101010101010101" ~ "0000111100001111" ~ "0101101001011010" ~ "0011001111001100" ~
    "0011110000111100" ~ "0101010110101010" ~ "0110100101101001" ~ "0101101010100101" ~
    "0111001111001110" ~ "0001001111001000" ~ "0011001001001100" ~ "0011101111011100" ~
    "0110100110010110" ~ "0011110011000011" ~ "0110011010011001" ~ "0000011001100000" ~
    "0100111001000000" ~ "0010011100100000" ~ "0000001001110010" ~ "0000010011100100" ~
    "0110110010010011" ~ "0011011011001001" ~ "0110001110011100" ~ "0011100111000110" ~
    "0110110011001001" ~ "0110001100111001" ~ "0111111010000001" ~ "0001100011100111" ~
    "0000111100110011" ~ "0011001111110000" ~ "0010001011101110" ~ "0100010001110111";

private immutable string partition3 =
    "0011001102212222" ~ "0001001122112221" ~ "0000200122112211" ~ "0222002200110111" ~
    "0000000011221122" ~ "0011001100220022" ~ "0022002211111111" ~ "0011001122112211" ~
    "0000000011112222" ~ "0000111111112222" ~ "0000111122222222" ~ "0012001200120012" ~
    "0112011201120112" ~ "0122012201220122" ~ "0011011211221222" ~ "0011200122002220" ~
    "0001001101121122" ~ "0111001120012200" ~ "0000112211221122" ~ "0022002200221111" ~
    "0111011102220222" ~ "0001000122212221" ~ "0000001101220122" ~ "0000110022102210" ~
    "0122012200110000" ~ "0012001211222222" ~ "0110122112210110" ~ "0000011012211221" ~
    "0022110211020022" ~ "0110011020022222" ~ "0011012201220011" ~ "0000200022112221" ~
    "0000000211221222" ~ "0222002200120011" ~ "0011001200220222" ~ "0120012001200120" ~
    "0000111122220000" ~ "0120120120120120" ~ "0120201212010120" ~ "0011220011220011" ~
    "0011112222000011" ~ "0101010122222222" ~ "0000000021212121" ~ "0022112200221122" ~
    "0022001100220011" ~ "0220122102201221" ~ "0101222222220101" ~ "0000212121212121" ~
    "0101010101012222" ~ "0222011102220111" ~ "0002111200021112" ~ "0000211221122112" ~
    "0222011101110222" ~ "0002111211120002" ~ "0110011001102222" ~ "0000000021122112" ~
    "0110011022222222" ~ "0022001100110022" ~ "0022112211220022" ~ "0000000000002112" ~
    "0002000100020001" ~ "0222122202221222" ~ "0101222222222222" ~ "0111201122012220";
static assert(partition2.length == 64 * 16 && partition3.length == 64 * 16);

private immutable ubyte[64] anchor2 = [
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15,
    15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6,
    6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15];
private immutable ubyte[64] anchor3a = [
    3, 3, 15, 15, 8, 3, 15, 15, 8, 8, 6, 6, 6, 5, 3, 3,
    3, 3, 8, 15, 3, 3, 6, 10, 5, 8, 8, 6, 8, 5, 15, 15,
    8, 15, 3, 5, 6, 10, 8, 15, 15, 3, 15, 5, 15, 15, 15, 15,
    3, 15, 5, 5, 5, 8, 5, 10, 5, 10, 8, 13, 15, 12, 3, 3];
private immutable ubyte[64] anchor3b = [
    15, 8, 8, 3, 15, 15, 3, 8, 15, 15, 15, 15, 15, 15, 15, 8,
    15, 8, 15, 3, 15, 8, 15, 8, 3, 15, 6, 10, 15, 15, 10, 8,
    15, 3, 15, 10, 10, 8, 9, 10, 6, 15, 8, 15, 3, 6, 6, 8,
    15, 3, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 3, 15, 15, 8];

private uint subsetOf(uint subsets, uint partition, uint texel) pure nothrow @nogc {
    if (subsets == 1) return 0;
    return (subsets == 2 ? partition2 : partition3)[partition * 16 + texel] - '0';
}

private uint anchorOf(uint subsets, uint partition, uint subset) pure nothrow @nogc {
    if (subset == 0) return 0;
    if (subsets == 2) return anchor2[partition];
    return subset == 1 ? anchor3a[partition] : anchor3b[partition];
}

// -------------------------------------------------------------- decoders ---

private uint takeBits(ref const ubyte[16] block, ref uint pos, uint n) pure nothrow @nogc {
    uint v = 0;
    foreach (i; 0 .. n) {
        v |= ((block[pos >> 3] >> (pos & 7)) & 1u) << i;
        pos++;
    }
    return v;
}

private uint expand(uint v, uint bits) pure nothrow @nogc {
    v <<= 8 - bits;
    return v | (v >> bits);
}

private uint interpolate(uint a, uint b, uint w) pure nothrow @nogc { return ((64 - w) * a + w * b + 32) >> 6; }

/// Decode one BC7 block to 16 RGBA texels.
void decodeBc7Block(ref const ubyte[16] block, ref ubyte[64] rgba) pure nothrow @nogc {
    uint modeIndex = 0;
    while (modeIndex < 8 && !((block[0] >> modeIndex) & 1)) modeIndex++;
    if (modeIndex == 8) { // reserved: transparent black
        rgba[] = 0;
        return;
    }
    immutable m = modes[modeIndex];
    uint pos = modeIndex + 1;
    immutable partition = takeBits(block, pos, m.partitionBits);
    immutable rotation = takeBits(block, pos, m.rotationBits);
    immutable indexSel = takeBits(block, pos, m.indexSelBits);
    uint[4][6] e; // endpoint, channel
    immutable count = m.subsets * 2;
    foreach (c; 0 .. 3) foreach (i; 0 .. count) e[i][c] = takeBits(block, pos, m.colorBits);
    foreach (i; 0 .. count) e[i][3] = m.alphaBits ? takeBits(block, pos, m.alphaBits) : 255;
    uint colorBits = m.colorBits, alphaBits = m.alphaBits;
    if (m.endpointP || m.sharedP) {
        uint[6] p;
        if (m.endpointP) foreach (i; 0 .. count) p[i] = takeBits(block, pos, 1);
        else foreach (s; 0 .. m.subsets) p[s * 2] = p[s * 2 + 1] = takeBits(block, pos, 1);
        foreach (i; 0 .. count) {
            foreach (c; 0 .. 3) e[i][c] = (e[i][c] << 1) | p[i];
            if (alphaBits) e[i][3] = (e[i][3] << 1) | p[i];
        }
        colorBits++;
        if (alphaBits) alphaBits++;
    }
    foreach (i; 0 .. count) {
        foreach (c; 0 .. 3) e[i][c] = expand(e[i][c], colorBits);
        if (alphaBits) e[i][3] = expand(e[i][3], alphaBits);
    }
    uint[16] first, second;
    foreach (t; 0 .. 16) {
        immutable s = subsetOf(m.subsets, partition, t);
        first[t] = takeBits(block, pos, m.indexBits - (t == anchorOf(m.subsets, partition, s) ? 1 : 0));
    }
    if (m.indexBits2)
        foreach (t; 0 .. 16) second[t] = takeBits(block, pos, m.indexBits2 - (t == 0 ? 1 : 0));
    foreach (t; 0 .. 16) {
        immutable s = subsetOf(m.subsets, partition, t) * 2;
        uint cw, aw;
        if (m.indexBits2 == 0) cw = aw = weightsFor(m.indexBits)[first[t]];
        else if (indexSel == 0) {
            cw = weightsFor(m.indexBits)[first[t]];
            aw = weightsFor(m.indexBits2)[second[t]];
        } else {
            cw = weightsFor(m.indexBits2)[second[t]];
            aw = weightsFor(m.indexBits)[first[t]];
        }
        uint[4] c;
        foreach (k; 0 .. 3) c[k] = interpolate(e[s][k], e[s + 1][k], cw);
        c[3] = interpolate(e[s][3], e[s + 1][3], aw);
        if (rotation) {
            immutable tmp = c[3];
            c[3] = c[rotation - 1];
            c[rotation - 1] = tmp;
        }
        foreach (k; 0 .. 4) rgba[t * 4 + k] = cast(ubyte) c[k];
    }
}

private void decodeBc4Half(scope const(ubyte)[] block, ref ubyte[16] texels) pure nothrow @nogc {
    immutable uint a = block[0], b = block[1];
    ulong bits = 0;
    foreach (i; 0 .. 6) bits |= cast(ulong) block[2 + i] << (8 * i);
    ubyte[8] pal;
    bc4Palette(a, b, pal);
    foreach (t; 0 .. 16) texels[t] = pal[(bits >> (3 * t)) & 7];
}

private void bc4Palette(uint a, uint b, ref ubyte[8] pal) pure nothrow @nogc {
    pal[0] = cast(ubyte) a;
    pal[1] = cast(ubyte) b;
    if (a > b) {
        foreach (i; 1 .. 7) pal[i + 1] = cast(ubyte)(((7 - i) * a + i * b + 3) / 7);
    } else {
        foreach (i; 1 .. 5) pal[i + 1] = cast(ubyte)(((5 - i) * a + i * b + 2) / 5);
        pal[6] = 0;
        pal[7] = 255;
    }
}

/// Decode one BC5 block: R and G as stored, B = the Z of the unit normal, A = 255.
void decodeBc5Block(ref const ubyte[16] block, ref ubyte[64] rgba) pure nothrow @nogc {
    import core.math : sqrt;
    ubyte[16] r, g;
    decodeBc4Half(block[0 .. 8], r);
    decodeBc4Half(block[8 .. 16], g);
    foreach (t; 0 .. 16) {
        immutable float x = r[t] / 127.5f - 1, y = g[t] / 127.5f - 1;
        immutable float zz = 1 - x * x - y * y;
        immutable float z = zz > 0 ? sqrt(zz) : 0;
        rgba[t * 4] = r[t];
        rgba[t * 4 + 1] = g[t];
        rgba[t * 4 + 2] = cast(ubyte)((z * 0.5f + 0.5f) * 255 + 0.5f);
        rgba[t * 4 + 3] = 255;
    }
}

/// Decode a whole level to RGBA8 (`width * height * 4` bytes).
void decodeBcLevel(bool bc7)(scope const(ubyte)[] blocks, uint width, uint height, scope ubyte[] rgba) pure nothrow @nogc {
    assert(blocks.length >= bcLevelBytes(width, height) && rgba.length >= cast(size_t) width * height * 4);
    ubyte[16] b;
    ubyte[64] t;
    size_t src = 0;
    for (uint by = 0; by < height; by += 4) {
        for (uint bx = 0; bx < width; bx += 4) {
            b[] = blocks[src .. src + 16];
            src += 16;
            static if (bc7) decodeBc7Block(b, t);
            else decodeBc5Block(b, t);
            foreach (y; 0 .. 4) foreach (x; 0 .. 4) {
                if (bx + x >= width || by + y >= height) continue;
                immutable o = (cast(size_t)(by + y) * width + bx + x) * 4;
                rgba[o .. o + 4] = t[(y * 4 + x) * 4 .. (y * 4 + x) * 4 + 4];
            }
        }
    }
}

// -------------------------------------------------------------- encoders ---

private void putBits(ref ubyte[16] block, ref uint pos, uint v, uint n) pure nothrow @nogc {
    foreach (i; 0 .. n) {
        if ((v >> i) & 1) block[pos >> 3] |= cast(ubyte)(1 << (pos & 7));
        pos++;
    }
}

/// One BC4 channel: 16 values.
private void encodeBc4Half(ref const ubyte[16] v, scope ubyte[] dst) pure nothrow @nogc {
    uint lo = 255, hi = 0, lo2 = 255, hi2 = 0; // lo2 / hi2 without 0 and 255
    foreach (x; v) {
        if (x < lo) lo = x;
        if (x > hi) hi = x;
        if (x > 0 && x < 255) {
            if (x < lo2) lo2 = x;
            if (x > hi2) hi2 = x;
        }
    }
    uint bestErr = uint.max, bestA = hi, bestB = lo;
    ubyte[16] bestIdx;
    void attempt(int a, int b) {
        if (a < 0 || a > 255 || b < 0 || b > 255) return;
        ubyte[8] pal;
        bc4Palette(a, b, pal);
        uint err = 0;
        ubyte[16] idx;
        foreach (t; 0 .. 16) {
            uint be = uint.max;
            foreach (i; 0 .. 8) {
                immutable d = cast(int) pal[i] - v[t];
                if (cast(uint)(d * d) < be) { be = d * d; idx[t] = cast(ubyte) i; }
            }
            err += be;
            if (err >= bestErr) return;
        }
        bestErr = err;
        bestA = a;
        bestB = b;
        bestIdx = idx;
    }
    attempt(hi, lo);
    if (bestErr > 0) {
        // Shrinking the range lowers the error when few texels are extreme.
        immutable int range = cast(int)(hi - lo);
        immutable int reach = range < 8 ? 2 : range < 64 ? 4 : 6;
        foreach (da; -1 .. reach) foreach (db; -1 .. reach)
            if (cast(int) hi - da > cast(int) lo + db) attempt(cast(int) hi - da, cast(int) lo + db);
        if (lo2 <= hi2 && (lo == 0 || hi == 255)) attempt(lo2, hi2);
    }
    dst[0] = cast(ubyte) bestA;
    dst[1] = cast(ubyte) bestB;
    ulong bits = 0;
    foreach (t; 0 .. 16) bits |= cast(ulong) bestIdx[t] << (3 * t);
    foreach (i; 0 .. 6) dst[2 + i] = cast(ubyte)(bits >> (8 * i));
}

/// Encode 16 RGBA texels (R and G used) as one BC5 block.
void encodeBc5Block(ref const ubyte[64] rgba, ref ubyte[16] block) pure nothrow @nogc {
    ubyte[16] r, g;
    foreach (t; 0 .. 16) {
        r[t] = rgba[t * 4];
        g[t] = rgba[t * 4 + 1];
    }
    encodeBc4Half(r, block[0 .. 8]);
    encodeBc4Half(g, block[8 .. 16]);
}

private enum PMode : ubyte { none, perEndpoint, shared_ }

/// Endpoints and indices of one subset.
private struct Fit {
    uint error = uint.max;
    uint[4][2] q; // quantized endpoints, without the p bit
    uint[2] p;
    ubyte[16] index; // per texel of the block
}

/// Quantized value whose expansion is closest to `v` (0..255).
private uint quantize(float v, uint bits, PMode pm, uint p, out uint expanded) pure nothrow @nogc {
    immutable uint total = pm == PMode.none ? bits : bits + 1;
    immutable float scaled = v * ((1u << total) - 1) / 255.0f;
    int q = pm == PMode.none ? cast(int)(scaled + 0.5f) : cast(int)((scaled - p) * 0.5f + 0.5f);
    immutable int top = (1 << bits) - 1;
    if (q < 0) q = 0;
    if (q > top) q = top;
    expanded = expand(pm == PMode.none ? q : (q << 1) | p, total);
    return q;
}

/// Fit a line of `channels` channels starting at `first` to the texels in `mask`.
private Fit fitLine(ref const float[4][16] px, uint mask, uint first, uint channels, uint bits, PMode pm, uint indexBits)
pure nothrow @nogc {
    import core.math : sqrt;
    immutable last = first + channels;
    float[4] mean = 0;
    uint n = 0;
    foreach (t; 0 .. 16) if ((mask >> t) & 1) {
        foreach (c; first .. last) mean[c] += px[t][c];
        n++;
    }
    foreach (c; first .. last) mean[c] /= n;
    float[4] axis = 0;
    if (channels == 1) axis[first] = 1;
    else {
        float[4][4] cov;
        foreach (ref row; cov) row[] = 0;
        foreach (t; 0 .. 16) if ((mask >> t) & 1)
            foreach (a; first .. last) foreach (b; first .. last)
                cov[a][b] += (px[t][a] - mean[a]) * (px[t][b] - mean[b]);
        uint start = first;
        foreach (c; first .. last) if (cov[c][c] > cov[start][start]) start = c;
        axis = cov[start];
        foreach (_; 0 .. 8) {
            float[4] next = 0;
            float len = 0;
            foreach (a; first .. last) {
                foreach (b; first .. last) next[a] += cov[a][b] * axis[b];
                len += next[a] * next[a];
            }
            if (len < 1e-12f) break;
            len = 1 / sqrt(len);
            foreach (a; first .. last) axis[a] = next[a] * len;
        }
        float len = 0;
        foreach (c; first .. last) len += axis[c] * axis[c];
        if (len > 1e-12f) {
            len = 1 / sqrt(len);
            foreach (c; first .. last) axis[c] *= len;
        }
    }
    float lo = 1e9f, hi = -1e9f;
    foreach (t; 0 .. 16) if ((mask >> t) & 1) {
        float d = 0;
        foreach (c; first .. last) d += (px[t][c] - mean[c]) * axis[c];
        if (d < lo) lo = d;
        if (d > hi) hi = d;
    }
    float[4][2] ends;
    foreach (c; 0 .. 4) {
        ends[0][c] = mean[c] + axis[c] * lo;
        ends[1][c] = mean[c] + axis[c] * hi;
    }
    auto weights = weightsFor(indexBits);
    immutable int levels = 1 << indexBits;
    Fit best;
    foreach (iteration; 0 .. 4) {
        bool improved = false;
        immutable combos = pm == PMode.none ? 1 : pm == PMode.shared_ ? 2 : 4;
        foreach (combo; 0 .. combos) {
            Fit f;
            f.error = 0;
            f.p[0] = pm == PMode.none ? 0 : combo & 1;
            f.p[1] = pm == PMode.shared_ ? f.p[0] : pm == PMode.none ? 0 : combo >> 1;
            uint[4][2] e;
            foreach (k; 0 .. 2) foreach (c; first .. last) {
                immutable v = ends[k][c] < 0 ? 0 : ends[k][c] > 255 ? 255 : ends[k][c];
                f.q[k][c] = quantize(v, bits, pm, f.p[k], e[k][c]);
            }
            uint[4][16] pal;
            foreach (i; 0 .. levels) foreach (c; first .. last) pal[i][c] = interpolate(e[0][c], e[1][c], weights[i]);
            float dd = 0;
            float[4] dir = 0;
            foreach (c; first .. last) {
                dir[c] = cast(float) e[1][c] - e[0][c];
                dd += dir[c] * dir[c];
            }
            immutable float inv = dd > 0 ? (levels - 1) / dd : 0;
            foreach (t; 0 .. 16) if ((mask >> t) & 1) {
                float pos = 0;
                foreach (c; first .. last) pos += (px[t][c] - e[0][c]) * dir[c];
                int guess = cast(int)(pos * inv + 0.5f);
                if (guess < 0) guess = 0;
                if (guess > levels - 1) guess = levels - 1;
                uint be = uint.max;
                foreach (i; (guess > 0 ? guess - 1 : 0) .. (guess + 2 < levels ? guess + 2 : levels)) {
                    uint err = 0;
                    foreach (c; first .. last) {
                        immutable int d = cast(int) pal[i][c] - cast(int) px[t][c];
                        err += d * d;
                    }
                    if (err < be) { be = err; f.index[t] = cast(ubyte) i; }
                }
                f.error += be;
            }
            if (f.error < best.error) { best = f; improved = true; }
        }
        if (!improved || best.error == 0) break;
        // Least squares endpoints for the indices found.
        float aa = 0, bb = 0, ab = 0;
        float[4] ax = 0, bx = 0;
        foreach (t; 0 .. 16) if ((mask >> t) & 1) {
            immutable float w = weights[best.index[t]] / 64.0f, u = 1 - w;
            aa += u * u;
            bb += w * w;
            ab += u * w;
            foreach (c; first .. last) {
                ax[c] += u * px[t][c];
                bx[c] += w * px[t][c];
            }
        }
        immutable float det = aa * bb - ab * ab;
        if (det < 1e-6f) break;
        foreach (c; first .. last) {
            ends[0][c] = (ax[c] * bb - bx[c] * ab) / det;
            ends[1][c] = (bx[c] * aa - ax[c] * ab) / det;
        }
    }
    return best;
}

/// Squared distance of the texels in `mask` from their best line.
private float lineResidual(ref const float[4][16] px, uint mask) pure nothrow @nogc {
    float[4] mean = 0;
    uint n = 0;
    foreach (t; 0 .. 16) if ((mask >> t) & 1) {
        foreach (c; 0 .. 4) mean[c] += px[t][c];
        n++;
    }
    foreach (c; 0 .. 4) mean[c] /= n;
    float[4][4] m;
    foreach (ref row; m) row[] = 0;
    foreach (t; 0 .. 16) if ((mask >> t) & 1)
        foreach (a; 0 .. 4) foreach (b; a .. 4) m[a][b] += (px[t][a] - mean[a]) * (px[t][b] - mean[b]);
    foreach (a; 0 .. 4) foreach (b; 0 .. a) m[a][b] = m[b][a];
    immutable trace = m[0][0] + m[1][1] + m[2][2] + m[3][3];
    if (trace < 1e-3f) return 0;
    uint start = 0;
    foreach (c; 1 .. 4) if (m[c][c] > m[start][start]) start = c;
    float[4] v = m[start];
    float lambda = 0;
    foreach (_; 0 .. 4) {
        float[4] w = 0;
        float vv = 0, vw = 0, big = 0;
        foreach (a; 0 .. 4) {
            foreach (b; 0 .. 4) w[a] += m[a][b] * v[b];
            vv += v[a] * v[a];
            vw += v[a] * w[a];
            immutable x = w[a] < 0 ? -w[a] : w[a];
            if (x > big) big = x;
        }
        if (vv < 1e-12f || big < 1e-12f) break;
        lambda = vw / vv;
        foreach (c; 0 .. 4) v[c] = w[c] / big;
    }
    immutable r = trace - lambda;
    return r > 0 ? r : 0;
}

/// Make the anchor index of `mask` start with a 0 bit.
private void fixAnchor(ref Fit f, uint mask, uint anchor, uint indexBits) pure nothrow @nogc {
    if (!(f.index[anchor] >> (indexBits - 1))) return;
    immutable q = f.q[0];
    f.q[0] = f.q[1];
    f.q[1] = q;
    immutable p = f.p[0];
    f.p[0] = f.p[1];
    f.p[1] = p;
    foreach (t; 0 .. 16) if ((mask >> t) & 1) f.index[t] = cast(ubyte)((1 << indexBits) - 1 - f.index[t]);
}

/// Encode 16 RGBA texels as one BC7 block.
void encodeBc7Block(ref const ubyte[64] rgba, ref ubyte[16] block, BcQuality quality = BcQuality.normal) pure nothrow @nogc {
    float[4][16] px;
    bool opaque_ = true;
    foreach (t; 0 .. 16) {
        foreach (c; 0 .. 4) px[t][c] = rgba[t * 4 + c];
        if (rgba[t * 4 + 3] != 255) opaque_ = false;
    }
    enum uint ALL = 0xFFFF;
    uint best = uint.max;

    // Mode 6: one RGBA line, 16 steps.
    {
        auto f = fitLine(px, ALL, 0, 4, 7, PMode.perEndpoint, 4);
        best = f.error;
        fixAnchor(f, ALL, 0, 4);
        block[] = 0;
        uint pos = 0;
        putBits(block, pos, 1 << 6, 7);
        foreach (c; 0 .. 4) foreach (k; 0 .. 2) putBits(block, pos, f.q[k][c], 7);
        foreach (k; 0 .. 2) putBits(block, pos, f.p[k], 1);
        foreach (t; 0 .. 16) putBits(block, pos, f.index[t], t == 0 ? 3 : 4);
    }
    if (best == 0) return;

    // Modes 5 and 4: one channel apart from the other three.
    foreach (rotation; 0 .. 4) {
        float[4][16] r = px;
        if (rotation)
            foreach (t; 0 .. 16) {
                r[t][3] = px[t][rotation - 1];
                r[t][rotation - 1] = px[t][3];
            }
        {
            auto c = fitLine(r, ALL, 0, 3, 7, PMode.none, 2);
            if (c.error < best) {
                auto a = fitLine(r, ALL, 3, 1, 8, PMode.none, 2);
                if (c.error + a.error < best) {
                    best = c.error + a.error;
                    writeSeparate(block, 5, rotation, 0, c, a);
                }
            }
        }
        if (quality == BcQuality.high) foreach (sel; 0 .. 2) {
            auto c = fitLine(r, ALL, 0, 3, 5, PMode.none, sel ? 3 : 2);
            if (c.error >= best) continue;
            auto a = fitLine(r, ALL, 3, 1, 6, PMode.none, sel ? 2 : 3);
            if (c.error + a.error < best) {
                best = c.error + a.error;
                writeSeparate(block, 4, rotation, sel, c, a);
            }
        }
    }
    if (quality == BcQuality.fast || best == 0) return;

    // Two lines: mode 1 (RGB, 8 steps) for opaque blocks, mode 7 (RGBA, 4 steps) for the rest.
    enum MAX_SHAPES = 12;
    immutable shapes = quality == BcQuality.high ? MAX_SHAPES : 3;
    float[MAX_SHAPES] score = float.max;
    ubyte[MAX_SHAPES] shape;
    foreach (p; 0 .. 64) {
        uint mask = 0;
        foreach (t; 0 .. 16) mask |= subsetOf(2, p, t) << t;
        immutable s = lineResidual(px, mask) + lineResidual(px, ~mask & ALL);
        if (s >= score[shapes - 1]) continue;
        uint at = shapes - 1;
        while (at > 0 && score[at - 1] > s) {
            score[at] = score[at - 1];
            shape[at] = shape[at - 1];
            at--;
        }
        score[at] = s;
        shape[at] = cast(ubyte) p;
    }
    foreach (k; 0 .. shapes) {
        if (score[k] >= best) break;
        immutable p = shape[k];
        uint mask = 0;
        foreach (t; 0 .. 16) mask |= subsetOf(2, p, t) << t;
        immutable uint channels = opaque_ ? 3 : 4, bits = opaque_ ? 6 : 5, indexBits = opaque_ ? 3 : 2;
        immutable pm = opaque_ ? PMode.shared_ : PMode.perEndpoint;
        Fit[2] f;
        f[0] = fitLine(px, ~mask & ALL, 0, channels, bits, pm, indexBits);
        if (f[0].error >= best) continue;
        f[1] = fitLine(px, mask, 0, channels, bits, pm, indexBits);
        if (f[0].error + f[1].error >= best) continue;
        best = f[0].error + f[1].error;
        fixAnchor(f[0], ~mask & ALL, 0, indexBits);
        fixAnchor(f[1], mask, anchor2[p], indexBits);
        block[] = 0;
        uint pos = 0;
        if (opaque_) putBits(block, pos, 1 << 1, 2);
        else putBits(block, pos, 1 << 7, 8);
        putBits(block, pos, p, 6);
        foreach (c; 0 .. channels) foreach (s; 0 .. 2) foreach (e; 0 .. 2) putBits(block, pos, f[s].q[e][c], bits);
        foreach (s; 0 .. 2) foreach (e; 0 .. (opaque_ ? 1 : 2)) putBits(block, pos, f[s].p[e], 1);
        foreach (t; 0 .. 16) {
            immutable s = (mask >> t) & 1;
            putBits(block, pos, f[s].index[t], t == 0 || t == anchor2[p] ? indexBits - 1 : indexBits);
        }
    }
}

/// Modes 4 and 5. `c` fits channels 0..3, `a` channel 3 (after the rotation).
private void writeSeparate(ref ubyte[16] block, uint mode, uint rotation, uint sel, Fit c, Fit a) pure nothrow @nogc {
    immutable m = modes[mode];
    immutable colorIndexBits = sel ? m.indexBits2 : m.indexBits;
    immutable alphaIndexBits = sel ? m.indexBits : m.indexBits2;
    fixAnchor(c, 0xFFFF, 0, colorIndexBits);
    fixAnchor(a, 0xFFFF, 0, alphaIndexBits);
    block[] = 0;
    uint pos = 0;
    putBits(block, pos, 1 << mode, mode + 1);
    putBits(block, pos, rotation, 2);
    putBits(block, pos, sel, m.indexSelBits);
    foreach (ch; 0 .. 3) foreach (k; 0 .. 2) putBits(block, pos, c.q[k][ch], m.colorBits);
    foreach (k; 0 .. 2) putBits(block, pos, a.q[k][3], m.alphaBits);
    const first = sel ? &a : &c;
    const second = sel ? &c : &a;
    foreach (t; 0 .. 16) putBits(block, pos, first.index[t], t == 0 ? m.indexBits - 1 : m.indexBits);
    foreach (t; 0 .. 16) putBits(block, pos, second.index[t], t == 0 ? m.indexBits2 - 1 : m.indexBits2);
}

/// Encode an RGBA8 level on every core. Texels outside the image repeat the edge.
ubyte[] encodeBcLevel(const(ubyte)[] rgba, uint width, uint height, bool bc7, BcQuality quality = BcQuality.normal) @trusted {
    assert(rgba.length >= cast(size_t) width * height * 4);
    immutable bw = (width + 3) / 4, bh = (height + 3) / 4;
    auto dst = new ubyte[bcLevelBytes(width, height)];
    void row(uint by) {
        ubyte[64] t;
        ubyte[16] b;
        foreach (bx; 0 .. bw) {
            foreach (y; 0 .. 4) foreach (x; 0 .. 4) {
                immutable sx = bx * 4 + x < width ? bx * 4 + x : width - 1;
                immutable sy = by * 4 + y < height ? by * 4 + y : height - 1;
                immutable o = (cast(size_t) sy * width + sx) * 4;
                t[(y * 4 + x) * 4 .. (y * 4 + x) * 4 + 4] = rgba[o .. o + 4];
            }
            if (bc7) encodeBc7Block(t, b, quality);
            else encodeBc5Block(t, b);
            immutable o = (cast(size_t) by * bw + bx) * 16;
            dst[o .. o + 16] = b[];
        }
    }
    version (WebAssembly) {
        foreach (by; 0 .. bh) row(by);
    } else {
        import std.parallelism : parallel;
        import std.range : iota;
        foreach (by; parallel(iota(bh), 4)) row(by);
    }
    return dst;
}

// ----------------------------------------------------------------- tests ---

version (unittest) {
    private double psnr(scope const(ubyte)[] a, scope const(ubyte)[] b, uint channels) {
        import std.math : log10;
        double e = 0;
        size_t n = 0;
        foreach (i; 0 .. a.length / 4) foreach (c; 0 .. channels) {
            immutable d = cast(double) a[i * 4 + c] - b[i * 4 + c];
            e += d * d;
            n++;
        }
        return e == 0 ? 99 : 10 * log10(255.0 * 255.0 * n / e);
    }

    private ubyte[] testImage(uint n, bool alpha) {
        import std.math : sin;
        auto px = new ubyte[n * n * 4];
        uint rng = 7;
        foreach (y; 0 .. n) foreach (x; 0 .. n) {
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
            auto o = px[(y * n + x) * 4 .. (y * n + x) * 4 + 4];
            immutable edge = (x * 3 + y * 5) % 37 < 14;
            o[0] = cast(ubyte)(128 + 100 * sin(x * 0.11) + (rng & 7));
            o[1] = cast(ubyte)(edge ? 200 : 60 + (y & 31));
            o[2] = cast(ubyte)(edge ? 40 : 128 + 90 * sin(y * 0.07 + x * 0.03));
            o[3] = cast(ubyte)(alpha ? 128 + 120 * sin(x * 0.2 - y * 0.13) : 255);
        }
        return px;
    }
}

@("bc.bc7RoundTrip") unittest {
    enum N = 64;
    foreach (alpha; [false, true]) {
        auto src = testImage(N, alpha);
        double last = 0;
        foreach (q; [BcQuality.fast, BcQuality.normal, BcQuality.high]) {
            auto blocks = encodeBcLevel(src, N, N, true, q);
            auto back = new ubyte[N * N * 4];
            decodeBcLevel!true(blocks, N, N, back);
            immutable v = psnr(src, back, 4);
            // Four unrelated channels are the worst case of the format.
            assert(v > (alpha ? 33 : 41) && v >= last - 1e-9);
            last = v;
            if (!alpha) foreach (i; 0 .. N * N) assert(back[i * 4 + 3] >= 254);
        }
    }
    // Solid colors come back within one code, gradients too.
    ubyte[64] t, d;
    ubyte[16] b;
    foreach (v; [0, 1, 77, 128, 200, 254, 255]) {
        foreach (i; 0 .. 16) t[i * 4 .. i * 4 + 4] = [cast(ubyte) v, cast(ubyte)(255 - v), 10, cast(ubyte) v];
        encodeBc7Block(t, b);
        decodeBc7Block(b, d);
        foreach (i; 0 .. 64) assert(d[i] - t[i] <= 1 && t[i] - d[i] <= 1);
    }
}

@("bc.bc5RoundTrip") unittest {
    enum N = 64;
    auto src = testImage(N, false);
    auto blocks = encodeBcLevel(src, N, N, false);
    auto back = new ubyte[N * N * 4];
    decodeBcLevel!false(blocks, N, N, back);
    assert(psnr(src, back, 2) > 36);
    // The normal pointing at the viewer keeps Z.
    foreach (i; 0 .. N * N) src[i * 4 .. i * 4 + 4] = [128, 128, 255, 255];
    blocks = encodeBcLevel(src, N, N, false);
    decodeBcLevel!false(blocks, N, N, back);
    assert(back[0 .. 4] == [128, 128, 255, 255]);
}

@("bc.decodeNeverOverruns") unittest {
    // Any 16 bytes decode (files are untrusted).
    uint rng = 99;
    ubyte[64] d;
    foreach (_; 0 .. 20_000) {
        ubyte[16] b;
        foreach (ref x; b) {
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
            x = cast(ubyte)(rng >> 9);
        }
        decodeBc7Block(b, d);
        decodeBc5Block(b, d);
    }
    ubyte[16] zero;
    decodeBc7Block(zero, d);
    foreach (x; d) assert(x == 0);
}

@("bc.sizes") unittest {
    assert(bcLevelBytes(4, 4) == 16 && bcLevelBytes(1, 1) == 16 && bcLevelBytes(5, 8) == 64);
    // Sizes that are not multiples of 4.
    auto src = testImage(8, false);
    auto blocks = encodeBcLevel(src[0 .. 6 * 5 * 4], 6, 5, true);
    assert(blocks.length == 64);
    auto back = new ubyte[6 * 5 * 4];
    decodeBcLevel!true(blocks, 6, 5, back);
}
