/// Unified image decoding and encoding via SDL3_image (`SDL_Surface` / `SDL_IOStream`).
/// Supports PNG, JPG, BMP, TGA, QOI, SVG, GIF, WEBP, and more.
module engine.assets.image;

import bindings.sdl3;
import bindings.sdl3_image;
import engine.core.log : err;

@safe:

/// Convert an arbitrary `SDL_Surface*` into a tightly-packed RGBA8 byte array (top-left origin).
bool surfaceToRgba8(
    SDL_Surface* surf,
    out ubyte[] outRgba,
    out uint outWidth,
    out uint outHeight
) nothrow @trusted {
    outRgba = null;
    outWidth = 0;
    outHeight = 0;
    if (surf is null || surf.w <= 0 || surf.h <= 0) return false;

    SDL_Surface* rgbaSurf = surf;
    bool ownsConverted = false;
    if (surf.format != SDL_PIXELFORMAT_RGBA32) {
        rgbaSurf = SDL_ConvertSurface(surf, SDL_PIXELFORMAT_RGBA32);
        if (rgbaSurf is null) return false;
        ownsConverted = true;
    }
    scope(exit) {
        if (ownsConverted) SDL_DestroySurface(rgbaSurf);
    }

    if (rgbaSurf.pixels is null || rgbaSurf.w <= 0 || rgbaSurf.h <= 0) return false;

    immutable bool needsLock = (rgbaSurf.flags & SDL_SURFACE_LOCK_NEEDED) != 0;
    if (needsLock && !SDL_LockSurface(rgbaSurf)) return false;
    scope(exit) {
        if (needsLock) SDL_UnlockSurface(rgbaSurf);
    }

    immutable uint w = cast(uint) rgbaSurf.w;
    immutable uint h = cast(uint) rgbaSurf.h;
    immutable size_t rowBytes = cast(size_t) w * 4;
    if (rgbaSurf.pitch < cast(int) rowBytes) return false;

    outRgba = new ubyte[rowBytes * h];
    const(ubyte)* srcPtr = cast(const(ubyte)*) rgbaSurf.pixels;
    foreach (y; 0 .. h) {
        immutable size_t srcOff = cast(size_t) y * cast(size_t) rgbaSurf.pitch;
        immutable size_t dstOff = cast(size_t) y * rowBytes;
        outRgba[dstOff .. dstOff + rowBytes] = srcPtr[srcOff .. srcOff + rowBytes];
    }

    outWidth = w;
    outHeight = h;
    return true;
}

/// Decode in-memory image bytes (PNG, JPG, BMP, QOI, SVG, GIF, TGA with `typeHint="TGA"`, etc.) to RGBA8.
bool decodeImageBytes(
    const(ubyte)[] bytes,
    out ubyte[] outRgba,
    out uint outWidth,
    out uint outHeight,
    const(char)* typeHint = null
) nothrow @trusted {
    outRgba = null;
    outWidth = 0;
    outHeight = 0;
    if (bytes.length == 0) return false;

    SDL_IOStream* io = SDL_IOFromConstMem(bytes.ptr, bytes.length);
    if (io is null) return false;

    SDL_Surface* surf = (typeHint !is null)
        ? IMG_LoadTyped_IO(io, true, typeHint)
        : IMG_Load_IO(io, true);
    if (surf is null) {
        err("Image decode failed (SDL3_image)");
        return false;
    }
    scope(exit) SDL_DestroySurface(surf);

    return surfaceToRgba8(surf, outRgba, outWidth, outHeight);
}

/// Decode an image file on disk (extension auto-detected by `IMG_Load`) to RGBA8.
bool decodeImageFile(
    scope const(char)[] path,
    out ubyte[] outRgba,
    out uint outWidth,
    out uint outHeight
) nothrow @trusted {
    outRgba = null;
    outWidth = 0;
    outHeight = 0;
    if (path.length == 0 || path.length >= 1024) return false;

    char[1024] pathBuf = 0;
    pathBuf[0 .. path.length] = path[];
    pathBuf[path.length] = '\0';

    SDL_Surface* surf = IMG_Load(pathBuf.ptr);
    if (surf is null) {
        err("Image file load failed (SDL3_image)");
        return false;
    }
    scope(exit) SDL_DestroySurface(surf);

    return surfaceToRgba8(surf, outRgba, outWidth, outHeight);
}

/// Rasterize an in-memory SVG document at a specific pixel size `(targetW, targetH)`.
/// Either `targetW` or `targetH` may be 0 to preserve aspect ratio.
bool decodeSvgBytesSized(
    const(ubyte)[] svgBytes,
    uint targetW,
    uint targetH,
    out ubyte[] outRgba,
    out uint outWidth,
    out uint outHeight
) nothrow @trusted {
    outRgba = null;
    outWidth = 0;
    outHeight = 0;
    if (svgBytes.length == 0) return false;

    SDL_IOStream* io = SDL_IOFromConstMem(svgBytes.ptr, svgBytes.length);
    if (io is null) return false;
    scope(exit) SDL_CloseIO(io);

    SDL_Surface* surf = IMG_LoadSizedSVG_IO(io, cast(int) targetW, cast(int) targetH);
    if (surf is null) {
        err("SVG decode failed (SDL3_image)");
        return false;
    }
    scope(exit) SDL_DestroySurface(surf);

    return surfaceToRgba8(surf, outRgba, outWidth, outHeight);
}

/// Save an RGBA8 pixel buffer (`width * height * 4` bytes, top-left origin) to a JPEG file.
bool saveRgbaJpg(
    scope const(char)[] path,
    const(ubyte)[] rgba,
    uint width,
    uint height,
    int quality = 90
) nothrow @nogc @trusted {
    if (path.length == 0 || path.length >= 1024 || width == 0 || height == 0) return false;
    if (rgba.length < cast(size_t) width * height * 4) return false;

    char[1024] pathBuf = 0;
    pathBuf[0 .. path.length] = path[];
    pathBuf[path.length] = '\0';

    auto surf = SDL_CreateSurfaceFrom(
        cast(int) width, cast(int) height,
        SDL_PIXELFORMAT_RGBA32,
        cast(void*) rgba.ptr,
        cast(int)(width * 4)
    );
    if (surf is null) return false;
    scope(exit) SDL_DestroySurface(surf);
    return IMG_SaveJPG(surf, pathBuf.ptr, quality);
}

unittest {
    import engine.assets.png : saveRgbaPng;
    import std.file : exists, remove;

    // 1. Valid 1x1 red RGBA PNG
    static immutable ubyte[70] red1x1Png = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
        0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
        0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
        0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99,
        0x3D, 0x1D, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
        0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    ubyte[] rgba;
    uint w, h;
    assert(decodeImageBytes(red1x1Png, rgba, w, h));
    assert(w == 1 && h == 1);
    assert(rgba == [255, 0, 0, 255]);

    // 2. Roundtrip PNG save -> decodeImageFile
    enum string tmpPng = "/tmp/ge_sdl3_image_roundtrip.png";
    scope(exit) {
        if (exists(tmpPng)) () @trusted { remove(tmpPng); }();
    }
    static immutable ubyte[16] px = [
        255,  10,  20, 255,
         30, 255,  40, 255,
         50,  60, 255, 255,
        255, 255, 255, 128,
    ];
    assert(saveRgbaPng(tmpPng, px, 2, 2));
    ubyte[] fileRgba;
    uint fw, fh;
    assert(decodeImageFile(tmpPng, fileRgba, fw, fh));
    assert(fw == 2 && fh == 2);
    assert(fileRgba == px[]);

    // 3. When SDL3_image is available, test JPG save/load and sized SVG
    if (imgIsAvailable()) {
        enum string tmpJpg = "/tmp/ge_sdl3_image_roundtrip.jpg";
        scope(exit) {
            if (exists(tmpJpg)) () @trusted { remove(tmpJpg); }();
        }
        assert(saveRgbaJpg(tmpJpg, px, 2, 2, 95));
        ubyte[] jpgRgba;
        uint jw, jh;
        assert(decodeImageFile(tmpJpg, jpgRgba, jw, jh));
        assert(jw == 2 && jh == 2 && jpgRgba.length == 16);

        enum string greenSvg = `<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#00ff00"/></svg>`;
        ubyte[] svgRgba;
        uint sw, sh;
        assert(decodeSvgBytesSized(cast(const(ubyte)[]) greenSvg, 32, 32, svgRgba, sw, sh));
        assert(sw == 32 && sh == 32);
        assert(svgRgba.length == 32 * 32 * 4);
        assert(svgRgba[0] == 0 && svgRgba[1] == 255 && svgRgba[2] == 0 && svgRgba[3] == 255);
    }
}
