/// GPU texture + sampler wrappers and a minimal in-engine TGA loader.
/// Textures are RGBA8Unorm by default, the standard for material albedo maps.
module engine.graphics.texture;

import bindings.wgpu;
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
