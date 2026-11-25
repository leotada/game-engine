/// Specular antialiasing of normal-mapped surfaces: the normal variation lost
/// in each mip is added to the roughness of the same mip (load time, CPU).
module engine.graphics.specular_aa;

import engine.graphics.texture : mipCount, mipExtent;
import engine.gpu.context : GpuContext;
import engine.graphics.texture : Texture, TextureDesc;
import std.math : sqrt;

@safe:

/// Roughness (perceptual) after adding the normal variation described by the
/// length `len` of an averaged unit normal.
float roughnessWithVariance(float roughness, float len) pure nothrow @nogc {
    if (len >= 1 - 1e-5f) return roughness;
    if (len < 1e-3f) return 1;
    // Von Mises-Fisher concentration; per-axis variance = 1 / kappa.
    immutable kappa = (3 * len - len * len * len) / (1 - len * len);
    immutable alpha = roughness * roughness;
    immutable a2 = alpha * alpha + 2 / kappa;
    return a2 >= 1 ? 1 : sqrt(sqrt(a2));
}

/// Metallic-roughness chain (RGBA8, all levels) with normal variance in G.
/// `mr` may be empty (white). `roughnessFactor` is baked: use 1 in the material.
ubyte[] specularAaChain(scope const(ubyte)[] mr, uint mw, uint mh, scope const(ubyte)[] normal,
                        uint nw, uint nh, float roughnessFactor, out uint width, out uint height, out uint levels) {
    width = mr.length && mw > nw ? mw : nw;
    height = mr.length && mh > nh ? mh : nh;
    levels = mipCount(width, height);

    // Unnormalized average normals, halved per level.
    float[3][][] chain;
    uint[2][] dims;
    auto base = new float[3][](cast(size_t) nw * nh);
    foreach (i, ref n; base) {
        float[3] v;
        foreach (c; 0 .. 3) v[c] = normal[i * 4 + c] / 127.5f - 1;
        immutable l = sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
        foreach (c; 0 .. 3) n[c] = l > 1e-6f ? v[c] / l : (c == 2 ? 1 : 0);
    }
    chain ~= base;
    dims ~= [nw, nh];
    while (dims[$ - 1][0] > 1 || dims[$ - 1][1] > 1) {
        immutable pw = dims[$ - 1][0], ph = dims[$ - 1][1];
        immutable w = pw > 1 ? pw / 2 : 1, h = ph > 1 ? ph / 2 : 1;
        auto next = new float[3][](cast(size_t) w * h);
        foreach (y; 0 .. h) foreach (x; 0 .. w) {
            float[3] s = 0;
            foreach (dy; 0 .. 2) foreach (dx; 0 .. 2) {
                immutable sx = x * pw / w + dx < pw ? x * pw / w + dx : pw - 1;
                immutable sy = y * ph / h + dy < ph ? y * ph / h + dy : ph - 1;
                foreach (c; 0 .. 3) s[c] += chain[$ - 1][cast(size_t) sy * pw + sx][c];
            }
            foreach (c; 0 .. 3) next[cast(size_t) y * w + x][c] = s[c] * 0.25f;
        }
        chain ~= next;
        dims ~= [w, h];
    }

    size_t bytes = 0;
    foreach (l; 0 .. levels) bytes += cast(size_t) mipExtent(width, l) * mipExtent(height, l) * 4;
    auto dst = new ubyte[bytes];
    // Level 0 values in float (G = roughness), box-halved for the next ones.
    auto cur = new float[4][](cast(size_t) width * height);
    foreach (y; 0 .. height) foreach (x; 0 .. width) {
        auto p = &cur[cast(size_t) y * width + x];
        if (mr.length) {
            immutable si = (cast(size_t)(cast(ulong) y * mh / height) * mw + cast(size_t)(cast(ulong) x * mw / width)) * 4;
            foreach (c; 0 .. 4) (*p)[c] = mr[si + c] / 255.0f;
        } else {
            *p = [1.0f, 1.0f, 1.0f, 1.0f];
        }
        immutable r = (*p)[1] * roughnessFactor;
        (*p)[1] = r < 0.04f ? 0.04f : (r > 1 ? 1 : r);
    }
    size_t off = 0;
    uint cw = width, ch = height;
    foreach (l; 0 .. levels) {
        immutable w = mipExtent(width, l), h = mipExtent(height, l);
        if (l > 0) {
            auto next = new float[4][](cast(size_t) w * h);
            foreach (y; 0 .. h) foreach (x; 0 .. w) {
                float[4] s = 0;
                foreach (dy; 0 .. 2) foreach (dx; 0 .. 2) {
                    immutable sx = x * cw / w + dx < cw ? x * cw / w + dx : cw - 1;
                    immutable sy = y * ch / h + dy < ch ? y * ch / h + dy : ch - 1;
                    foreach (c; 0 .. 4) s[c] += cur[cast(size_t) sy * cw + sx][c];
                }
                foreach (c; 0 .. 4) next[cast(size_t) y * w + x][c] = s[c] * 0.25f;
            }
            cur = next;
            cw = w;
            ch = h;
        }
        // Normal level with the same footprint.
        size_t nl = 0;
        while (nl + 1 < chain.length && dims[nl][0] > w) nl++;
        immutable dw = dims[nl][0], dh = dims[nl][1];
        foreach (y; 0 .. h) foreach (x; 0 .. w) {
            immutable n = chain[nl][cast(size_t)(cast(ulong) y * dh / h) * dw + cast(size_t)(cast(ulong) x * dw / w)];
            immutable len = sqrt(n[0] * n[0] + n[1] * n[1] + n[2] * n[2]);
            auto p = cur[cast(size_t) y * w + x];
            p[1] = roughnessWithVariance(p[1], len);
            foreach (c; 0 .. 4) {
                immutable v = p[c] * 255 + 0.5f;
                dst[off + c] = v <= 0 ? 0 : v >= 255 ? 255 : cast(ubyte) v;
            }
            off += 4;
        }
    }
    return dst;
}

/// Metallic-roughness texture for `normal`, see `specularAaChain`.
Texture specularAaTexture(ref GpuContext gpu, scope const(ubyte)[] mr, uint mw, uint mh, scope const(ubyte)[] normal,
                          uint nw, uint nh, float roughnessFactor) {
    uint w, h, levels;
    auto chain = specularAaChain(mr, mw, mh, normal, nw, nh, roughnessFactor, w, h, levels);
    return Texture.fromMipChain(gpu, chain, w, h, levels);
}

@("specularAa.variance") @safe unittest {
    import std.math : abs, cos, PI, sin, log;
    import std.random : Random, uniform01;
    assert(roughnessWithVariance(0.3f, 1) == 0.3f);
    assert(roughnessWithVariance(0.3f, 0) == 1);
    // Gaussian slopes of standard deviation s add 2 s^2 to alpha^2.
    auto rng = Random(3);
    enum s = 0.1f;
    double[3] m = 0;
    enum N = 200_000;
    foreach (i; 0 .. N) {
        immutable r = s * sqrt(-2 * log(1 - uniform01!double(rng)));
        immutable a = 2 * PI * uniform01!double(rng);
        immutable x = r * cos(a), y = r * sin(a);
        immutable l = sqrt(x * x + y * y + 1);
        m[0] += x / l; m[1] += y / l; m[2] += 1 / l;
    }
    immutable len = cast(float)(sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]) / N);
    immutable got = roughnessWithVariance(0.4f, len);
    immutable want = sqrt(sqrt(0.16f * 0.16f + 2 * s * s));
    assert(abs(got - want) < 0.005f);
}

@("specularAa.chain") @safe unittest {
    // Flat normals change nothing; alternating tilts raise every mip but level 0.
    enum N = 8;
    auto flat = new ubyte[N * N * 4], bumpy = new ubyte[N * N * 4], mr = new ubyte[N * N * 4];
    foreach (i; 0 .. N * N) {
        flat[i * 4 .. i * 4 + 4] = [128, 128, 255, 255];
        bumpy[i * 4 .. i * 4 + 4] = (i + i / N) % 2 ? [ubyte(160), ubyte(128), ubyte(250), ubyte(255)]
                                                    : [ubyte(96), ubyte(128), ubyte(250), ubyte(255)];
        mr[i * 4 .. i * 4 + 4] = [255, 128, 10, 255];
    }
    uint w, h, levels;
    auto a = specularAaChain(mr, N, N, flat, N, N, 0.5f, w, h, levels);
    assert(w == N && h == N && levels == 4);
    foreach (i; 0 .. a.length / 4) assert(a[i * 4 + 1] == 64 && a[i * 4 + 2] == 10);
    auto b = specularAaChain(mr, N, N, bumpy, N, N, 0.5f, w, h, levels);
    foreach (i; 0 .. N * N) assert(b[i * 4 + 1] == 64);
    foreach (i; N * N .. b.length / 4) assert(b[i * 4 + 1] > 120);
    // No metallic-roughness image, smaller normal map.
    auto c = specularAaChain(null, 0, 0, flat, N, N, 0.5f, w, h, levels);
    assert(c[1] == 128 && c[2] == 255);
    auto d = specularAaChain(mr, N, N, bumpy[0 .. 16 * 4], 4, 4, 1, w, h, levels);
    assert(w == N && d[1] == 128);
}
