/// `game-engine-texc`: compress images to KTX2 (BC7, BC5) with mips.
///
///   game-engine-texc encode <in.png> <out.ktx2> [--srgb] [--normal] [--format=auto|bc7|bc5|rgba8]
///                    [--alpha-cutoff=0.5] [--no-mips] [--zstd=3] [--quality=fast|normal|high]
///   game-engine-texc gltf   <model.gltf|glb> [--linear-color] [--specular-aa] [--zstd=3] [--quality=normal]
///   game-engine-texc info   <file.ktx2> [more.ktx2 ...]
///   game-engine-texc verify <file.ktx2> <source image>
///
/// `gltf` writes the files read by `GltfImportOptions.compressedTextures`.
module texc_main;

import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.file : read, write;
import std.math : log10;
import std.stdio : stderr, writefln, writeln;
import std.string : startsWith;

import engine.assets.bc;
import engine.assets.gltf;
import engine.assets.image : decodeImageFile;
import engine.assets.ktx2;
import engine.graphics.specular_aa : specularAaChain;
import engine.graphics.texture : alphaCoverageOf, generateMipChainRgba8, ktx2Sidecar, mipCount, mipExtent,
    preserveAlphaCoverage;

@safe:

struct Options {
    bool srgb, normal, mips = true, linearColor, specularAa;
    float alphaCutoff = 0;
    int zstd = 0;
    string format = "auto";
    BcQuality quality = BcQuality.normal;
}

/// RGBA8 pixels of every level.
const(ubyte)[][] mipLevels(const(ubyte)[] rgba, uint w, uint h, bool mips, bool normal, bool srgb, float alphaCutoff) {
    const(ubyte)[][] levels = [rgba];
    if (!mips) return levels;
    immutable n = mipCount(w, h);
    size_t bytes = 0;
    foreach (l; 1 .. n) bytes += textureLevelBytes(TextureCodec.rgba8, w, h, l);
    auto tail = new ubyte[bytes];
    generateMipChainRgba8(rgba, w, h, tail, n, normal, srgb);
    if (alphaCutoff > 0)
        preserveAlphaCoverage(tail, w, h, n, alphaCutoff, alphaCoverageOf(rgba, w, h, alphaCutoff));
    size_t off = 0;
    foreach (l; 1 .. n) {
        immutable b = textureLevelBytes(TextureCodec.rgba8, w, h, l);
        levels ~= tail[off .. off + b];
        off += b;
    }
    return levels;
}

double psnr(scope const(ubyte)[] a, scope const(ubyte)[] b, uint channels) {
    double e = 0;
    foreach (i; 0 .. a.length / 4) foreach (c; 0 .. channels) {
        immutable d = cast(double) a[i * 4 + c] - b[i * 4 + c];
        e += d * d;
    }
    return e == 0 ? 99 : 10 * log10(255.0 * 255.0 * (a.length / 4 * channels) / e);
}

ubyte[] decodeLevel(ref const Ktx2Image img, uint l) {
    immutable w = mipExtent(img.width, l), h = mipExtent(img.height, l);
    if (img.codec == TextureCodec.rgba8) return img.levels[l].dup;
    auto px = new ubyte[cast(size_t) w * h * 4];
    if (img.codec == TextureCodec.bc7) decodeBcLevel!true(img.levels[l], w, h, px);
    else decodeBcLevel!false(img.levels[l], w, h, px);
    return px;
}

void compress(const(ubyte)[][] rgba, uint w, uint h, TextureCodec codec, bool srgb, string outPath, Options o) {
    StopWatch sw;
    sw.start();
    Ktx2Image img;
    img.codec = codec;
    img.srgb = srgb && codec != TextureCodec.bc5;
    img.width = w;
    img.height = h;
    foreach (l, px; rgba)
        img.levels ~= codec == TextureCodec.rgba8 ? px
            : encodeBcLevel(px, mipExtent(w, cast(uint) l), mipExtent(h, cast(uint) l), codec == TextureCodec.bc7, o.quality);
    auto file = writeKtx2(img, o.zstd);
    write(outPath, file);
    auto back = decodeLevel(img, 0);
    writefln("%s: %sx%s %s%s, %s levels, %.1f KiB (GPU %.1f KiB), PSNR %.1f dB, %.2f s", outPath, w, h, codec,
        img.srgb ? " sRGB" : "", img.levels.length, file.length / 1024.0, img.bytes / 1024.0,
        psnr(rgba[0], back, codec == TextureCodec.bc5 ? 2 : 4), sw.peek.total!"msecs" / 1000.0);
    if (codec != TextureCodec.rgba8 && (w % 4 || h % 4))
        writefln("  warning: the size is not a multiple of 4, the engine decodes this file to RGBA8 at load");
}

int encodeFile(string src, string dst, Options o) {
    ubyte[] rgba;
    uint w, h;
    if (!decodeImageFile(src, rgba, w, h)) {
        stderrLine("cannot read " ~ src);
        return 1;
    }
    TextureCodec codec = o.normal ? TextureCodec.bc5 : TextureCodec.bc7;
    if (o.format != "auto") codec = o.format.to!TextureCodec;
    immutable srgb = o.srgb && !o.normal;
    compress(mipLevels(rgba, w, h, o.mips, o.normal, srgb, o.alphaCutoff), w, h, codec, srgb, dst, o);
    return 0;
}

int encodeGltf(string path, Options o) @trusted {
    auto doc = parseGltfDocument(path);
    if ("materials" !in doc.root) {
        writeln("no materials");
        return 0;
    }
    enum Use : ubyte { none, color, normal, data, mixed }
    immutable images = "images" in doc.root ? doc.root["images"].array.length : 0;
    auto use = new Use[images];
    auto cutoff = new float[images];
    cutoff[] = 0;
    int status = 0;
    void mark(int image, Use u) {
        if (image < 0 || image >= cast(int) images) return;
        if (use[image] != Use.none && use[image] != u) {
            writefln("image %s is used as %s and as %s: skipped", image, use[image], u);
            use[image] = Use.mixed;
            return;
        }
        use[image] = u;
    }
    immutable materials = doc.root["materials"].array.length;
    foreach (i; 0 .. materials) {
        auto m = parseGltfMaterialAt(doc.root, i);
        mark(m.baseColorImage, Use.color);
        mark(m.emissiveImage, Use.color);
        mark(m.metallicRoughnessImage, Use.data);
        mark(m.occlusionImage, Use.data);
        mark(m.normalImage, Use.normal);
        if (m.alphaMode == GltfAlphaMode.mask && m.baseColorImage >= 0) cutoff[m.baseColorImage] = m.params.alphaCutoff;
    }
    foreach (i; 0 .. images) {
        if (use[i] == Use.none || use[i] == Use.mixed) continue;
        auto px = decodeGltfImagePixels(doc, cast(int) i);
        if (!px.valid) {
            writefln("image %s: cannot decode", i);
            status = 1;
            continue;
        }
        immutable normal = use[i] == Use.normal, srgb = use[i] == Use.color && !o.linearColor;
        compress(mipLevels(px.rgba, px.w, px.h, o.mips, normal, srgb, cutoff[i]), px.w, px.h,
            normal ? TextureCodec.bc5 : TextureCodec.bc7, srgb, ktx2Sidecar(gltfSidecarBase(doc, cast(int) i)), o);
    }
    if (o.specularAa) foreach (i; 0 .. materials) {
        auto m = parseGltfMaterialAt(doc.root, i);
        if (m.normalImage < 0) continue;
        auto n = decodeGltfImagePixels(doc, m.normalImage);
        if (!n.valid) continue;
        DecodedImage mr;
        if (m.metallicRoughnessImage >= 0) mr = decodeGltfImagePixels(doc, m.metallicRoughnessImage);
        uint w, h, levels;
        auto chain = specularAaChain(mr.rgba, mr.w, mr.h, n.rgba, n.w, n.h, m.params.specularRoughness, w, h, levels);
        const(ubyte)[][] list;
        size_t off = 0;
        foreach (l; 0 .. levels) {
            immutable b = textureLevelBytes(TextureCodec.rgba8, w, h, l);
            list ~= chain[off .. off + b];
            off += b;
        }
        compress(list, w, h, TextureCodec.bc7, false, gltfSpecularAaPath(doc, cast(int) i), o);
    }
    return status;
}

Ktx2Image load(string path) @trusted {
    string error;
    auto bytes = cast(const(ubyte)[]) read(path);
    auto img = readKtx2(bytes, error);
    if (!img.valid) throw new Exception(path ~ ": " ~ error);
    return img;
}

void stderrLine(string s) @trusted { stderr.writeln(s); }

int run(string[] pos, Options o) {
    switch (pos.length ? pos[0] : "") {
        case "encode":
            if (pos.length == 3) return encodeFile(pos[1], pos[2], o);
            break;
        case "gltf":
            if (pos.length == 2) return encodeGltf(pos[1], o);
            break;
        case "info":
            foreach (p; pos[1 .. $]) {
                auto img = load(p);
                writefln("%s: %sx%s %s%s, %s levels, GPU %.1f KiB (RGBA8 %.1f KiB)", p, img.width, img.height, img.codec,
                    img.srgb ? " sRGB" : "", img.levels.length, img.bytes / 1024.0, rgbaBytes(img) / 1024.0);
            }
            return pos.length > 1 ? 0 : 2;
        case "verify":
            if (pos.length != 3) break;
            auto img = load(pos[1]);
            ubyte[] rgba;
            uint w, h;
            if (!decodeImageFile(pos[2], rgba, w, h)) throw new Exception("cannot read " ~ pos[2]);
            if (w != img.width || h != img.height) throw new Exception("sizes differ");
            writefln("%s: PSNR %.2f dB", pos[1], psnr(rgba, decodeLevel(img, 0), img.codec == TextureCodec.bc5 ? 2 : 4));
            return 0;
        default:
    }
    stderrLine("usage: game-engine-texc encode|gltf|info|verify ... (see tools/texc_main.d)");
    return 2;
}

size_t rgbaBytes(ref const Ktx2Image img) {
    size_t n = 0;
    foreach (l; 0 .. cast(uint) img.levels.length) n += textureLevelBytes(TextureCodec.rgba8, img.width, img.height, l);
    return n;
}

int main(string[] args) {
    Options o;
    string[] pos;
    try {
        foreach (a; args[1 .. $]) {
            if (a == "--srgb") o.srgb = true;
            else if (a == "--normal") o.normal = true;
            else if (a == "--no-mips") o.mips = false;
            else if (a == "--linear-color") o.linearColor = true;
            else if (a == "--specular-aa") o.specularAa = true;
            else if (a.startsWith("--format=")) o.format = a[9 .. $];
            else if (a.startsWith("--alpha-cutoff=")) o.alphaCutoff = a[15 .. $].to!float;
            else if (a.startsWith("--zstd=")) o.zstd = a[7 .. $].to!int;
            else if (a.startsWith("--quality=")) o.quality = a[10 .. $].to!BcQuality;
            else if (a.startsWith("--")) throw new Exception("unknown option " ~ a);
            else pos ~= a;
        }
        return run(pos, o);
    } catch (Exception e) {
        stderrLine(e.msg);
        return 1;
    }
}
