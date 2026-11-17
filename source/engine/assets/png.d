/// PNG screenshot/image saving via SDL3 `SDL_SavePNG`.
module engine.assets.png;

import bindings.sdl3;

@safe:

/// Save an RGBA8 pixel buffer (`width * height * 4` bytes, top-left origin) to a PNG file.
bool saveRgbaPng(
    scope const(char)[] path,
    const(ubyte)[] rgba,
    uint width,
    uint height
) nothrow @nogc @trusted {
    if (path.length == 0 || path.length >= 1024 || width == 0 || height == 0) return false;
    if (rgba.length < cast(size_t) width * height * 4) return false;

    char[1024] pathBuf = 0;
    pathBuf[0 .. path.length] = path[];
    pathBuf[path.length] = '\0';
    return saveRgbaPngZ(pathBuf.ptr, rgba.ptr, width, height);
}

/// Null-terminated pointer overload for zero-overhead `@nogc` sinks.
bool saveRgbaPngZ(
    const(char)* pathZ,
    const(ubyte)* rgbaPtr,
    uint width,
    uint height
) nothrow @nogc @trusted {
    if (pathZ is null || rgbaPtr is null || width == 0 || height == 0) return false;
    auto surf = SDL_CreateSurfaceFrom(
        cast(int) width, cast(int) height,
        SDL_PIXELFORMAT_RGBA32,
        cast(void*) rgbaPtr,
        cast(int)(width * 4)
    );
    if (surf is null) return false;
    scope(exit) SDL_DestroySurface(surf);
    return SDL_SavePNG(surf, pathZ);
}

unittest {
    import engine.graphics.texture : Texture;
    import std.file : exists, read, remove;

    enum string tmpPath = "/tmp/ge_sdl3_png_roundtrip_test.png";
    scope(exit) {
        if (exists(tmpPath)) {
            () @trusted { remove(tmpPath); }();
        }
    }

    static immutable ubyte[16] px = [
        255,  64,  32, 255,
          0, 255,   0, 255,
          0,   0, 255, 255,
        255, 255,   0, 255,
    ];
    assert(saveRgbaPng(tmpPath, px, 2, 2));
    assert(exists(tmpPath));

    auto fileBytes = () @trusted { return cast(const(ubyte)[]) read(tmpPath); }();
    ubyte[] decoded;
    uint dw, dh;
    assert(Texture.decodeImageBytes(fileBytes, decoded, dw, dh));
    assert(dw == 2 && dh == 2);
    assert(decoded == px[]);
}
