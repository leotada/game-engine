/// KTX2 container for 2D textures: BC7, BC5 and RGBA8 levels, optionally
/// zstd-compressed. Other KTX2 features are rejected.
module engine.assets.ktx2;

import engine.assets.bc : bcLevelBytes;
import engine.assets.zstd : zstdCompressToArray, zstdDecompress;

@safe:

/// Block format of a texture file (sRGB or not is separate).
enum TextureCodec : ubyte {
    rgba8,
    bc5, /// two-channel normal map, Z is rebuilt
    bc7,
}

/// A texture file in memory. `levels[0]` is the full size.
struct Ktx2Image {
    TextureCodec codec;
    bool srgb;
    uint width, height;
    const(ubyte)[][] levels;

    bool valid() const pure nothrow @nogc { return levels.length > 0; }

    size_t bytes() const pure nothrow @nogc {
        size_t n = 0;
        foreach (l; levels) n += l.length;
        return n;
    }
}

private immutable ubyte[12] identifier = [0xAB, 0x4B, 0x54, 0x58, 0x20, 0x32, 0x30, 0xBB, 0x0D, 0x0A, 0x1A, 0x0A];
private enum HEADER = 80, LEVEL_ENTRY = 24, MAX_SIZE = 16_384;

/// Bytes of level `level`.
size_t textureLevelBytes(TextureCodec codec, uint width, uint height, uint level) pure nothrow @nogc {
    immutable w = width >> level ? width >> level : 1, h = height >> level ? height >> level : 1;
    return codec == TextureCodec.rgba8 ? cast(size_t) w * h * 4 : bcLevelBytes(w, h);
}

/// True when `bytes` starts with the KTX2 signature.
bool isKtx2(scope const(ubyte)[] bytes) pure nothrow @nogc {
    return bytes.length >= 12 && bytes[0 .. 12] == identifier[];
}

private uint vkFormat(TextureCodec c, bool srgb) pure nothrow @nogc {
    final switch (c) {
        case TextureCodec.rgba8: return srgb ? 43 : 37;
        case TextureCodec.bc5:   return 141;
        case TextureCodec.bc7:   return srgb ? 146 : 145;
    }
}

private void put32(ref ubyte[] b, uint v) pure nothrow { foreach (i; 0 .. 4) b ~= cast(ubyte)(v >> (8 * i)); }
private void put64(ref ubyte[] b, ulong v) pure nothrow { foreach (i; 0 .. 8) b ~= cast(ubyte)(v >> (8 * i)); }

private uint get32(scope const(ubyte)[] b, size_t o) pure nothrow @nogc {
    return b[o] | b[o + 1] << 8 | b[o + 2] << 16 | cast(uint) b[o + 3] << 24;
}
private ulong get64(scope const(ubyte)[] b, size_t o) pure nothrow @nogc {
    return get32(b, o) | cast(ulong) get32(b, o + 4) << 32;
}

/// Write a KTX2 file. `zstdLevel` 0 stores the levels as they are.
ubyte[] writeKtx2(ref const Ktx2Image img, int zstdLevel = 0) {
    assert(img.valid);
    // Data format descriptor.
    immutable samples = img.codec == TextureCodec.rgba8 ? 4 : img.codec == TextureCodec.bc5 ? 2 : 1;
    ubyte[] dfd;
    immutable uint blockSize = 24 + 16 * samples;
    put32(dfd, 4 + blockSize);
    put32(dfd, 0);
    put32(dfd, 2 | blockSize << 16);
    immutable uint model = img.codec == TextureCodec.rgba8 ? 1 : img.codec == TextureCodec.bc5 ? 132 : 134;
    put32(dfd, model | 1 << 8 | (img.srgb ? 2 : 1) << 16);
    put32(dfd, img.codec == TextureCodec.rgba8 ? 0 : 3 | 3 << 8);
    put32(dfd, img.codec == TextureCodec.rgba8 ? 4 : 16);
    put32(dfd, 0);
    foreach (s; 0 .. samples) {
        final switch (img.codec) {
            case TextureCodec.rgba8:
                // Alpha is channel 15 and stays linear.
                immutable uint channel = s == 3 ? 15 | (img.srgb ? 16 : 0) : s;
                put32(dfd, s * 8 | 7 << 16 | channel << 24);
                break;
            case TextureCodec.bc5: put32(dfd, s * 64 | 63 << 16 | s << 24); break;
            case TextureCodec.bc7: put32(dfd, 127 << 16); break;
        }
        put32(dfd, 0);
        put32(dfd, 0);
        put32(dfd, img.codec == TextureCodec.rgba8 ? 255 : uint.max);
    }
    immutable char[] writer = "KTXwriter\0game-engine-texc\0";
    ubyte[] kvd;
    put32(kvd, cast(uint) writer.length);
    foreach (c; writer) kvd ~= cast(ubyte) c;
    while (kvd.length % 4) kvd ~= 0;

    const(ubyte)[][] stored;
    foreach (l; img.levels) stored ~= zstdLevel > 0 ? zstdCompressToArray(l, zstdLevel) : l;
    ubyte[] f;
    f ~= identifier[];
    put32(f, vkFormat(img.codec, img.srgb));
    put32(f, 1);
    put32(f, img.width);
    put32(f, img.height);
    put32(f, 0); // depth
    put32(f, 0); // layers
    put32(f, 1); // faces
    put32(f, cast(uint) img.levels.length);
    put32(f, zstdLevel > 0 ? 2 : 0);
    immutable dfdAt = HEADER + LEVEL_ENTRY * img.levels.length;
    put32(f, cast(uint) dfdAt);
    put32(f, cast(uint) dfd.length);
    put32(f, cast(uint)(dfdAt + dfd.length));
    put32(f, cast(uint) kvd.length);
    put64(f, 0); // no global data
    put64(f, 0);
    assert(f.length == HEADER);
    // Levels are stored smallest first.
    immutable align_ = zstdLevel > 0 ? 1 : img.codec == TextureCodec.rgba8 ? 4 : 16;
    auto offsets = new ulong[img.levels.length];
    ulong at = dfdAt + dfd.length + kvd.length;
    foreach_reverse (i; 0 .. img.levels.length) {
        at = (at + align_ - 1) / align_ * align_;
        offsets[i] = at;
        at += stored[i].length;
    }
    foreach (i; 0 .. img.levels.length) {
        put64(f, offsets[i]);
        put64(f, stored[i].length);
        put64(f, img.levels[i].length);
    }
    f ~= dfd;
    f ~= kvd;
    foreach_reverse (i; 0 .. img.levels.length) {
        while (f.length < offsets[i]) f ~= 0;
        f ~= stored[i];
    }
    return f;
}

/// Read a KTX2 file. On failure the result is not `valid` and `error` says why.
/// Levels stored without zstd are slices of `file`.
Ktx2Image readKtx2(const(ubyte)[] file, out string error) {
    Ktx2Image none, img;
    if (!isKtx2(file) || file.length < HEADER) { error = "not a KTX2 file"; return none; }
    switch (get32(file, 12)) {
        case 37: img.codec = TextureCodec.rgba8; break;
        case 43: img.codec = TextureCodec.rgba8; img.srgb = true; break;
        case 141: img.codec = TextureCodec.bc5; break;
        case 145: img.codec = TextureCodec.bc7; break;
        case 146: img.codec = TextureCodec.bc7; img.srgb = true; break;
        default: error = "unsupported format (BC7, BC5 and RGBA8 only)"; return none;
    }
    img.width = get32(file, 20);
    img.height = get32(file, 24);
    immutable levels = get32(file, 40);
    immutable scheme = get32(file, 44);
    if (img.width == 0 || img.height == 0 || img.width > MAX_SIZE || img.height > MAX_SIZE) {
        error = "bad size";
        return none;
    }
    if (get32(file, 28) > 1 || get32(file, 32) > 1 || get32(file, 36) != 1) {
        error = "only 2D textures are supported";
        return none;
    }
    uint full = 1;
    while ((img.width >> full) || (img.height >> full)) full++;
    if (levels == 0 || levels > full) { error = "bad level count"; return none; }
    if (scheme != 0 && scheme != 2) { error = "unsupported supercompression"; return none; }
    if (file.length < HEADER + cast(size_t) LEVEL_ENTRY * levels) { error = "truncated"; return none; }
    foreach (l; 0 .. levels) {
        immutable o = HEADER + LEVEL_ENTRY * l;
        immutable off = get64(file, o), len = get64(file, o + 8), raw = get64(file, o + 16);
        immutable want = textureLevelBytes(img.codec, img.width, img.height, l);
        if (off > file.length || len > file.length - off || raw != want || (scheme == 0 && len != want)) {
            error = "bad level";
            return none;
        }
        auto data = file[cast(size_t) off .. cast(size_t)(off + len)];
        if (scheme == 2) {
            auto buf = new ubyte[want];
            size_t written;
            if (!zstdDecompress(data, buf, written) || written != want) { error = "corrupt level"; return none; }
            img.levels ~= buf;
        } else {
            img.levels ~= data;
        }
    }
    return img;
}

@("ktx2.roundTrip") unittest {
    foreach (codec; [TextureCodec.rgba8, TextureCodec.bc5, TextureCodec.bc7]) foreach (zstd; [0, 3]) {
        Ktx2Image img;
        img.codec = codec;
        img.srgb = codec != TextureCodec.bc5;
        img.width = 16;
        img.height = 8;
        foreach (l; 0 .. 5) {
            auto d = new ubyte[textureLevelBytes(codec, 16, 8, l)];
            foreach (i, ref x; d) x = cast(ubyte)(i * 7 + l);
            img.levels ~= d;
        }
        auto f = writeKtx2(img, zstd);
        string e;
        auto r = readKtx2(f, e);
        assert(r.valid && e.length == 0);
        assert(r.codec == img.codec && r.srgb == img.srgb && r.width == 16 && r.height == 8);
        assert(r.levels == img.levels);
        // Truncated or damaged files are refused, never read out of bounds.
        foreach (n; 0 .. f.length) {
            auto cut = readKtx2(f[0 .. n], e);
            if (cut.valid) assert(cut.levels.length == 5);
        }
        foreach (o; 12 .. HEADER + LEVEL_ENTRY * 5) {
            auto bad = f.dup;
            bad[o] ^= 0xFF;
            readKtx2(bad, e);
        }
    }
    string e;
    assert(!readKtx2(null, e).valid && e.length);
}
