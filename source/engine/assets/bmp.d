/// Minimal BMP decoder — uncompressed 24-bit (BGR) and 32-bit (BGRA), bottom-up.
/// Returns raw RGBA8 pixel data suitable for `Texture.fromPixels`.
/// Gameplay-layer helper: GC is permitted (we allocate the output buffer).
module engine.assets.bmp;

import std.exception : enforce;
import std.file : read;

import engine.core.log;
import engine.graphics.texture : Texture, TextureDesc;
import engine.gpu.context : GpuContext;

@safe:

struct BmpImage {
    uint width;
    uint height;
    ubyte[] pixels; // RGBA8, row-major, top-left origin
}

/// Decode a BMP byte buffer. Supports BI_RGB 24-bit and 32-bit.
BmpImage decodeBmp(const(ubyte)[] data) @trusted {
    enforce(data.length > 54, "BMP too small");
    enforce(data[0] == 'B' && data[1] == 'M', "Not a BMP file");

    immutable ulong pixelOffset = readU32(data, 10); // 64-bit: crafted headers must not wrap the size check
    immutable uint dibSize     = readU32(data, 14);
    enforce(dibSize >= 40, "Unsupported DIB header");

    immutable int  width  = cast(int)  readU32(data, 18);
    immutable int  signedHeight = cast(int) readU32(data, 22);
    immutable ushort bpp  = readU16(data, 28);
    immutable uint compression = readU32(data, 30);
    enforce(compression == 0, "Compressed BMPs not supported");
    enforce(bpp == 24 || bpp == 32, "Only 24/32-bpp BMPs are supported");

    immutable bool topDown = signedHeight < 0;
    immutable uint height  = topDown ? cast(uint)(-signedHeight) : cast(uint) signedHeight;
    enforce(width > 0 && height > 0, "Invalid BMP dimensions");

    immutable uint bytesPerPixel = bpp / 8;
    immutable ulong rowUnpadded  = cast(ulong) width * bytesPerPixel;
    immutable ulong rowStride    = (rowUnpadded + 3u) & ~3UL; // 4-byte align
    enforce(rowStride <= data.length && height <= data.length
        && pixelOffset + rowStride * height <= data.length, "BMP pixel data truncated");

    auto dst = new ubyte[cast(size_t) width * height * 4];
    foreach (row; 0 .. height) {
        immutable srcRow = topDown ? row : (height - 1 - row);
        immutable srcBase = pixelOffset + srcRow * rowStride;
        immutable dstBase = cast(size_t) row * width * 4;
        foreach (col; 0 .. cast(uint) width) {
            immutable size_t si = cast(size_t) srcBase + col * bytesPerPixel;
            immutable size_t di = dstBase + col * 4;
            dst[di + 0] = data[si + 2]; // R
            dst[di + 1] = data[si + 1]; // G
            dst[di + 2] = data[si + 0]; // B
            dst[di + 3] = (bpp == 32) ? data[si + 3] : 255;
        }
    }

    return BmpImage(cast(uint) width, height, dst);
}

/// Load a BMP from disk and upload it as a GPU texture.
Texture loadBmpTexture(ref GpuContext gpu, string path, TextureDesc desc = TextureDesc.init) @trusted {
    auto bytes = cast(const(ubyte)[]) read(path);
    auto img   = decodeBmp(bytes);
    info("Loaded BMP: ", path, " (", img.width, "x", img.height, ")");
    return Texture.fromPixels(gpu, img.pixels, img.width, img.height, desc);
}

private uint readU32(const(ubyte)[] b, size_t off) pure nothrow @nogc {
    return cast(uint) b[off] | (cast(uint) b[off + 1] << 8)
         | (cast(uint) b[off + 2] << 16) | (cast(uint) b[off + 3] << 24);
}

private ushort readU16(const(ubyte)[] b, size_t off) pure nothrow @nogc {
    return cast(ushort)(cast(uint) b[off] | (cast(uint) b[off + 1] << 8));
}

@("bmp: a header whose size wraps 32 bits is rejected")
@safe unittest {
    import std.exception : assertThrown;
    auto d = new ubyte[64];
    static void put(ubyte[] b, size_t o, uint v) {
        foreach (i; 0 .. 4) b[o + i] = cast(ubyte)(v >> (8 * i));
    }
    d[0] = 'B';
    d[1] = 'M';
    put(d, 10, 54);
    put(d, 14, 40);
    put(d, 18, 0x4000_0000); // width * 4 = 2^32
    put(d, 22, 1);
    d[28] = 32;
    assertThrown(decodeBmp(d));
    put(d, 18, 1);
    put(d, 22, 2);
    d[54] = 9;
    assert(decodeBmp(d).pixels.length == 8);
}
