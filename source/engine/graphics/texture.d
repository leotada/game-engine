/// GPU texture + sampler wrappers and a minimal in-engine TGA loader.
/// Textures are RGBA8Unorm by default, the standard for material albedo maps.
module engine.graphics.texture;

import bindings.wgpu;
import bindings.sdl3 : SDL_Surface;
import engine.assets.image :
    decodeImgBytes = decodeImageBytes,
    decodeImgFile  = decodeImageFile,
    decodeSvgBytesSized,
    surfaceToRgba8;
import engine.gpu.context : GpuContext;
import engine.core.log;

@safe:

/// Filter mode for sampler creation.
enum TextureFilter : uint {
    nearest,
    linear,
}

/// Address/wrap mode at texture edges.
enum TextureWrap : uint {
    clamp,
    repeat,
    mirror,
}

/// Owned GPU texture + view. Always RGBA8 Unorm sRGB-linear (format rgba8Unorm).
/// Non-copyable, deterministic release.
struct Texture {
    package(engine) WGPUTexture     texture;
    package(engine) WGPUTextureView view;
    uint width;
    uint height;

    @disable this(this);

    /// Upload raw RGBA8 pixel data (row-major, top-left origin, 4 bytes/pixel).
    static Texture fromPixels(ref GpuContext gpu, const(ubyte)[] rgba,
                              uint width, uint height) @trusted {
        assert(rgba.length == cast(size_t) width * height * 4,
               "Texture.fromPixels: pixel buffer size mismatch");

        Texture t;
        t.width  = width;
        t.height = height;

        auto device = gpu.getDevice();
        auto queue  = gpu.getQueue();

        WGPUTextureDescriptor desc;
        desc.usage     = WGPUTextureUsage.textureBinding | WGPUTextureUsage.copyDst;
        desc.dimension = WGPUTextureDimension.dim2D;
        desc.size      = WGPUExtent3D(width, height, 1);
        desc.format    = WGPUTextureFormat.rgba8Unorm;
        t.texture = wgpuDeviceCreateTexture(device, &desc);
        if (t.texture is null) {
            fatal("Failed to create WGPU texture");
        }

        WGPUImageCopyTexture dst;
        dst.texture = t.texture;

        WGPUTextureDataLayout layout;
        layout.bytesPerRow  = width * 4;
        layout.rowsPerImage = height;

        WGPUExtent3D extent = WGPUExtent3D(width, height, 1);
        wgpuQueueWriteTexture(queue, &dst, rgba.ptr, rgba.length, &layout, &extent);

        WGPUTextureViewDescriptor viewDesc;
        viewDesc.format    = WGPUTextureFormat.rgba8Unorm;
        viewDesc.dimension = WGPUTextureViewDimension.dim2D;
        t.view = wgpuTextureCreateView(t.texture, &viewDesc);

        return t;
    }

    /// Procedural 2×2 checkerboard — great fallback / missing-texture marker.
    static Texture checker(ref GpuContext gpu, uint size = 64,
                           ubyte[4] a = [255,255,255,255],
                           ubyte[4] b = [40, 40, 40, 255]) {
        auto pixels = new ubyte[size * size * 4];
        immutable half = size / 2;
        foreach (y; 0 .. size) foreach (x; 0 .. size) {
            immutable cell = ((x < half) ^ (y < half));
            immutable idx = (y * size + x) * 4;
            pixels[idx .. idx + 4] = cell ? a[] : b[];
        }
        return fromPixels(gpu, pixels, size, size);
    }

    /// Flat solid-color texture (1×1, cheap).
    /// White disc with a smooth alpha falloff (alpha 1 at the center, 0 at the
    /// edge): the standard particle sprite.
    static Texture softDisc(ref GpuContext gpu, uint size = 64) @trusted {
        auto px = new ubyte[size * size * 4];
        immutable half = size * 0.5f;
        foreach (y; 0 .. size) {
            foreach (x; 0 .. size) {
                immutable dx = (x + 0.5f - half) / half;
                immutable dy = (y + 0.5f - half) / half;
                immutable d = dx * dx + dy * dy;
                float a = d >= 1.0f ? 0.0f : (1.0f - d);
                a = a * a * (3.0f - 2.0f * a); // smoothstep falloff
                immutable i = (y * size + x) * 4;
                px[i] = 255; px[i + 1] = 255; px[i + 2] = 255;
                px[i + 3] = cast(ubyte)(a * 255.0f + 0.5f);
            }
        }
        return fromPixels(gpu, px, size, size);
    }

    static Texture solid(ref GpuContext gpu, ubyte r, ubyte g, ubyte bl, ubyte a = 255) @trusted {
        ubyte[4] px = [r, g, bl, a];
        return fromPixels(gpu, px[], 1, 1);
    }

    /// Load an uncompressed 24/32-bit TGA file (bottom-left origin).
    /// Returns an invalid Texture on failure.
    static Texture fromTgaFile(ref GpuContext gpu, string path) {
        import std.file : read;
        import std.exception : ErrnoException;
        try {
            auto bytes = cast(const(ubyte)[]) read(path);
            return fromTgaBytes(gpu, bytes);
        } catch (Exception e) {
            err("Failed to read TGA file: " ~ path);
            return Texture.init;
        }
    }

    /// Decode TGA bytes (type 2 RGB uncompressed, 24 or 32 bpp).
    static Texture fromTgaBytes(ref GpuContext gpu, const(ubyte)[] bytes) {
        if (bytes.length < 18) {
            err("TGA: truncated header");
            return Texture.init;
        }
        immutable idLen      = bytes[0];
        immutable colorMap   = bytes[1];
        immutable imageType  = bytes[2];
        immutable width      = cast(uint)(bytes[12] | (bytes[13] << 8));
        immutable height     = cast(uint)(bytes[14] | (bytes[15] << 8));
        immutable bpp        = bytes[16];
        immutable descriptor = bytes[17];

        if (colorMap != 0 || imageType != 2 || (bpp != 24 && bpp != 32)) {
            err("TGA: only uncompressed RGB(A) 24/32 bpp supported");
            return Texture.init;
        }

        immutable pxCount   = cast(size_t) width * height;
        immutable dataStart = 18 + idLen;
        immutable dataSize  = pxCount * (bpp / 8);
        if (bytes.length < dataStart + dataSize) {
            err("TGA: truncated pixel data");
            return Texture.init;
        }

        auto rgba = new ubyte[pxCount * 4];
        const(ubyte)[] src = bytes[dataStart .. dataStart + dataSize];
        immutable flipY = (descriptor & 0x20) == 0; // bottom-left origin by default

        foreach (y; 0 .. height) {
            immutable srcY = flipY ? (height - 1 - y) : y;
            foreach (x; 0 .. width) {
                immutable si = (srcY * width + x) * (bpp / 8);
                immutable di = (y    * width + x) * 4;
                // TGA stores BGR(A)
                rgba[di + 0] = src[si + 2];
                rgba[di + 1] = src[si + 1];
                rgba[di + 2] = src[si + 0];
                rgba[di + 3] = bpp == 32 ? src[si + 3] : 0xFF;
            }
        }

        return fromPixels(gpu, rgba, width, height);
    }

    /// Decode PNG/JPG/BMP/QOI/GIF/WEBP/SVG/TGA image bytes into an RGBA8 buffer via SDL3_image.
    static bool decodeImageBytes(
        const(ubyte)[] bytes,
        out ubyte[] outRgba,
        out uint outWidth,
        out uint outHeight,
        const(char)* typeHint = null
    ) @trusted {
        return decodeImgBytes(bytes, outRgba, outWidth, outHeight, typeHint);
    }

    /// Create a GPU `Texture` by converting an `SDL_Surface*` to RGBA8.
    static Texture fromSurface(ref GpuContext gpu, SDL_Surface* surf) @trusted {
        ubyte[] rgba;
        uint w, h;
        if (!surfaceToRgba8(surf, rgba, w, h)) return Texture.init;
        return fromPixels(gpu, rgba, w, h);
    }

    /// Rasterize an in-memory SVG document at `(targetW, targetH)` into a GPU `Texture`.
    static Texture fromSvgBytes(ref GpuContext gpu, const(ubyte)[] svgBytes, uint targetW, uint targetH) {
        ubyte[] rgba;
        uint w, h;
        if (!decodeSvgBytesSized(svgBytes, targetW, targetH, rgba, w, h)) return Texture.init;
        return fromPixels(gpu, rgba, w, h);
    }

    /// Load an image (PNG, JPG, TGA, BMP, QOI, SVG, etc.) from in-memory file bytes into a GPU Texture.
    static Texture fromImageBytes(ref GpuContext gpu, const(ubyte)[] bytes, const(char)* typeHint = null) @trusted {
        ubyte[] rgba;
        uint w, h;
        if (!decodeImageBytes(bytes, rgba, w, h, typeHint)) return Texture.init;
        return fromPixels(gpu, rgba, w, h);
    }

    /// Load an image (PNG, JPG, TGA, BMP, QOI, SVG, WEBP, etc.) from disk into a GPU Texture.
    static Texture fromImageFile(ref GpuContext gpu, scope const(char)[] path) {
        import std.file : exists;
        if (!exists(path)) {
            err("Texture.fromImageFile: file not found");
            return Texture.init;
        }
        ubyte[] rgba;
        uint w, h;
        if (!decodeImgFile(path, rgba, w, h)) {
            err("Texture.fromImageFile: failed to decode image");
            return Texture.init;
        }
        return fromPixels(gpu, rgba, w, h);
    }

    /// Opaque UI texture handle compatible with `UiNode.textureHandle`.
    ulong uiHandle() const nothrow @nogc @trusted {
        return view is null ? 0 : cast(ulong) cast(size_t) view;
    }

    bool valid() const nothrow @nogc { return texture !is null; }

    void destroy() nothrow @nogc @trusted {
        if (view !is null)    { wgpuTextureViewRelease(view); view = null; }
        if (texture !is null) { wgpuTextureRelease(texture); texture = null; }
    }
}

/// Owned GPU sampler. Reusable across textures / materials.
struct Sampler {
    package(engine) WGPUSampler sampler;

    @disable this(this);

    static Sampler create(ref GpuContext gpu,
                          TextureFilter filter = TextureFilter.linear,
                          TextureWrap wrap = TextureWrap.repeat) @trusted {
        WGPUFilterMode fm = filter == TextureFilter.linear
            ? WGPUFilterMode.linear : WGPUFilterMode.nearest;
        WGPUMipmapFilterMode mip = filter == TextureFilter.linear
            ? WGPUMipmapFilterMode.linear : WGPUMipmapFilterMode.nearest;
        WGPUAddressMode am;
        final switch (wrap) {
            case TextureWrap.clamp:  am = WGPUAddressMode.clampToEdge;  break;
            case TextureWrap.repeat: am = WGPUAddressMode.repeat;       break;
            case TextureWrap.mirror: am = WGPUAddressMode.mirrorRepeat; break;
        }

        WGPUSamplerDescriptor desc;
        desc.addressModeU = am;
        desc.addressModeV = am;
        desc.addressModeW = am;
        desc.magFilter    = fm;
        desc.minFilter    = fm;
        desc.mipmapFilter = mip;

        Sampler s;
        s.sampler = wgpuDeviceCreateSampler(gpu.getDevice(), &desc);
        if (s.sampler is null) fatal("Failed to create sampler");
        return s;
    }

    void destroy() nothrow @nogc @trusted {
        if (sampler !is null) { wgpuSamplerRelease(sampler); sampler = null; }
    }
}

unittest {
    // Valid 1x1 red RGBA PNG (70 bytes)
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
    assert(Texture.decodeImageBytes(red1x1Png, rgba, w, h));
    assert(w == 1 && h == 1);
    assert(rgba == [255, 0, 0, 255]);
}
