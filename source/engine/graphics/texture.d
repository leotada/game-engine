/// GPU texture + sampler wrappers and a minimal in-engine TGA loader.
/// Textures are RGBA8Unorm by default; `TextureDesc.srgb` selects RGBA8UnormSrgb for color maps.
module engine.graphics.texture;

import bindings.wgpu;
import bindings.sdl3 : SDL_Surface;
import engine.assets.image :
    decodeImgBytes = decodeImageBytes,
    decodeImgFile  = decodeImageFile,
    decodeSvgBytesSized,
    surfaceToRgba8;
import engine.assets.pak : isAssetPakMounted, readAssetBytes;
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

/// Owned GPU texture + view (RGBA8, `TextureDesc.srgb` decides whether the GPU decodes sRGB on read).
/// Non-copyable, deterministic release.
struct Texture {
    package(engine) WGPUTexture     texture;
    package(engine) WGPUTextureView view;
    uint width;
    uint height;
    /// Number of mip levels (1 = no mip chain).
    uint mipLevels = 1;
    /// Storage format of `texture`.
    WGPUTextureFormat format = WGPUTextureFormat.rgba8Unorm;

    @disable this(this);

    /// Upload raw RGBA8 pixel data (row-major, top-left origin, 4 bytes/pixel).
    static Texture fromPixels(ref GpuContext gpu, const(ubyte)[] rgba,
                              uint width, uint height) {
        return fromPixels(gpu, rgba, width, height, TextureDesc.init);
    }

    /// Upload RGBA8 pixels. `desc.generateMips` builds a CPU box-filtered mip
    /// chain at load time (never call this from the frame loop).
    static Texture fromPixels(ref GpuContext gpu, const(ubyte)[] rgba,
                              uint width, uint height, TextureDesc desc) {
        assert(rgba.length == cast(size_t) width * height * 4,
               "Texture.fromPixels: pixel buffer size mismatch");

        Texture t;
        t.width  = width;
        t.height = height;
        t.format = desc.format;
        t.mipLevels = desc.generateMips ? mipCount(width, height) : 1;

        t.texture = createTexture2D(gpu, t.format, width, height, 1, t.mipLevels);
        if (t.texture is null)
            fatal("Failed to create WGPU texture");

        uploadRgba8WithMips(gpu, t.texture, 0, rgba, width, height, t.mipLevels, desc);
        t.view = createView(t.texture, t.format, WGPUTextureViewDimension.dim2D, 1);
        return t;
    }

    /// Single-channel 16-bit normalized texture (heightmaps, masks).
    /// Requires the 16-bit-norm device feature; returns an invalid texture
    /// (and logs) when the device cannot create it.
    static Texture fromR16(ref GpuContext gpu, const(ushort)[] texels, uint width, uint height) {
        return fromSingleChannel(gpu, WGPUTextureFormat.r16Unorm, 2,
            () @trusted { return cast(const(ubyte)[]) texels; }(), width, height);
    }

    /// Single-channel 32-bit float texture. Not filterable on stock WebGPU:
    /// sample it with a nearest sampler or `textureLoad`.
    static Texture fromR32F(ref GpuContext gpu, const(float)[] texels, uint width, uint height) {
        return fromSingleChannel(gpu, WGPUTextureFormat.r32Float, 4,
            () @trusted { return cast(const(ubyte)[]) texels; }(), width, height);
    }

    private static Texture fromSingleChannel(ref GpuContext gpu, WGPUTextureFormat fmt, uint bpp,
                                             const(ubyte)[] bytes, uint width, uint height) {
        assert(bytes.length == cast(size_t) width * height * bpp,
               "Texture: single-channel buffer size mismatch");
        Texture t;
        t.width = width;
        t.height = height;
        t.format = fmt;
        t.texture = createTexture2D(gpu, fmt, width, height, 1, 1);
        if (t.texture is null) {
            err("Texture: device cannot create single-channel format ", cast(uint) fmt);
        } else {
            writeLevel(gpu, t.texture, 0, 0, bytes, width, height, bpp);
            t.view = createView(t.texture, fmt, WGPUTextureViewDimension.dim2D, 1);
        }
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
    static Texture fromTgaFile(ref GpuContext gpu, string path, TextureDesc desc = TextureDesc.init) {
        import std.file : read;
        import std.exception : ErrnoException;
        try {
            auto bytes = cast(const(ubyte)[]) read(path);
            return fromTgaBytes(gpu, bytes, desc);
        } catch (Exception e) {
            err("Failed to read TGA file: " ~ path);
            return Texture.init;
        }
    }

    /// Decode TGA bytes (type 2 RGB uncompressed, 24 or 32 bpp).
    static Texture fromTgaBytes(ref GpuContext gpu, const(ubyte)[] bytes, TextureDesc desc = TextureDesc.init) {
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

        return fromPixels(gpu, rgba, width, height, desc);
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
    static Texture fromImageBytes(ref GpuContext gpu, const(ubyte)[] bytes, const(char)* typeHint = null,
                                  TextureDesc desc = TextureDesc.init) @trusted {
        ubyte[] rgba;
        uint w, h;
        if (!decodeImageBytes(bytes, rgba, w, h, typeHint)) return Texture.init;
        return fromPixels(gpu, rgba, w, h, desc);
    }

    /// Load an image (PNG, JPG, TGA, BMP, QOI, SVG, WEBP, etc.) from disk or mounted `GEPK` pak into a GPU Texture.
    static Texture fromImageFile(ref GpuContext gpu, scope const(char)[] path,
                                 TextureDesc desc = TextureDesc.init) {
        if (isAssetPakMounted()) {
            ubyte[] bytes;
            if (!readAssetBytes(path, bytes)) {
                err("Texture.fromImageFile: asset not found in mounted pak");
                return Texture.init;
            }
            return fromImageBytes(gpu, bytes, null, desc);
        }
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
        return fromPixels(gpu, rgba, w, h, desc);
    }

    /// Create an empty GPU texture usable as both a render target and a sampled UI/shader texture.
    static Texture createRenderTarget(ref GpuContext gpu, uint width, uint height,
                                      WGPUTextureFormat fmt = WGPUTextureFormat.rgba8Unorm) {
        Texture t;
        if (width > 0 && height > 0) {
            WGPUTextureDescriptor desc;
            desc.usage = WGPUTextureUsage.textureBinding
                       | WGPUTextureUsage.renderAttachment
                       | WGPUTextureUsage.copyDst
                       | WGPUTextureUsage.copySrc;
            desc.dimension = WGPUTextureDimension.dim2D;
            desc.size = WGPUExtent3D(width, height, 1);
            desc.format = fmt;
            desc.mipLevelCount = 1;
            desc.sampleCount = 1;

            auto device = gpu.getDevice();
            auto rawTex = () @trusted { return wgpuDeviceCreateTexture(device, &desc); }();
            if (rawTex is null) {
                err("Texture.createRenderTarget: failed to create texture");
            } else {
                t.width = width;
                t.height = height;
                t.format = fmt;
                t.mipLevels = 1;
                t.texture = rawTex;
                t.view = createView(rawTex, fmt, WGPUTextureViewDimension.dim2D, 1);
            }
        }
        return t;
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

/// Upload options for `Texture.fromPixels` and the image loaders.
struct TextureDesc {
    /// Build a full CPU box-filtered mip chain at load time.
    bool generateMips = false;
    /// Treat RGB as a tangent-space normal and re-normalize every mip texel.
    bool normalMap = false;
    /// RGB is sRGB-encoded color: the GPU decodes it to linear on read and mips
    /// are averaged in linear light. Alpha is always linear. Leave it off for
    /// data (normal, ORM, masks). Off by default: RGB is read as linear.
    bool srgb = false;

    /// GPU format of the uploaded pixels.
    WGPUTextureFormat format() const pure nothrow @nogc {
        return srgb ? WGPUTextureFormat.rgba8UnormSrgb : WGPUTextureFormat.rgba8Unorm;
    }

    /// Mipmapped sRGB color texture (albedo, emissive).
    static TextureDesc mippedSrgb() pure nothrow @nogc { return TextureDesc(true, false, true); }
    /// Mipmapped color texture read as linear (albedo, ORM, emissive).
    static TextureDesc mipped() pure nothrow @nogc { return TextureDesc(true, false); }
    /// Mipmapped normal map.
    static TextureDesc mippedNormal() pure nothrow @nogc { return TextureDesc(true, true); }
}

/// Number of mip levels for a full chain down to 1×1.
uint mipCount(uint width, uint height) pure nothrow @nogc {
    uint m = width > height ? width : height;
    uint levels = 1;
    while (m > 1) {
        m >>= 1;
        levels++;
    }
    return levels;
}

/// Size of mip `level` along one axis (never below 1).
uint mipExtent(uint base, uint level) pure nothrow @nogc {
    immutable v = base >> level;
    return v == 0 ? 1 : v;
}

/// Bytes needed for RGBA8 mip levels `1 .. levels` (level 0 excluded).
size_t mipTailBytesRgba8(uint width, uint height, uint levels) pure nothrow @nogc {
    size_t total = 0;
    foreach (l; 1 .. levels)
        total += cast(size_t) mipExtent(width, l) * mipExtent(height, l) * 4;
    return total;
}

/**
 * Downsample one RGBA8 level with a 2×2 box filter. Odd source sizes clamp
 * the second tap to the edge, so non-power-of-two images work. When
 * `normalMap` is set, RGB is decoded as a unit vector, averaged and
 * re-normalized. When `srgb` is set, RGB is averaged in linear light. Alpha is
 * always averaged as is.
 */
void downsampleRgba8(scope const(ubyte)[] src, uint sw, uint sh,
                     scope ubyte[] dst, uint dw, uint dh, bool normalMap, bool srgb = false) pure nothrow @nogc {
    assert(src.length >= cast(size_t) sw * sh * 4 && dst.length >= cast(size_t) dw * dh * 4);
    foreach (y; 0 .. dh) {
        immutable y0 = y * 2 < sh ? y * 2 : sh - 1;
        immutable y1 = y0 + 1 < sh ? y0 + 1 : y0;
        foreach (x; 0 .. dw) {
            immutable x0 = x * 2 < sw ? x * 2 : sw - 1;
            immutable x1 = x0 + 1 < sw ? x0 + 1 : x0;
            immutable size_t a = (cast(size_t) y0 * sw + x0) * 4;
            immutable size_t b = (cast(size_t) y0 * sw + x1) * 4;
            immutable size_t c = (cast(size_t) y1 * sw + x0) * 4;
            immutable size_t d = (cast(size_t) y1 * sw + x1) * 4;
            immutable size_t o = (cast(size_t) y * dw + x) * 4;
            if (normalMap) {
                float[3] n = 0;
                immutable size_t[4] taps = [a, b, c, d];
                foreach (ch; 0 .. 3) {
                    foreach (idx; taps)
                        n[ch] += src[idx + ch] / 127.5f - 1.0f;
                }
                immutable len2 = n[0] * n[0] + n[1] * n[1] + n[2] * n[2];
                if (len2 > 1e-12f) {
                    immutable inv = 1.0f / sqrtF(len2);
                    foreach (ch; 0 .. 3) n[ch] *= inv;
                } else {
                    n = [0.0f, 0.0f, 1.0f];
                }
                foreach (ch; 0 .. 3) {
                    float v = (n[ch] * 0.5f + 0.5f) * 255.0f + 0.5f;
                    dst[o + ch] = cast(ubyte)(v < 0 ? 0 : (v > 255 ? 255 : v));
                }
            } else if (srgb) {
                foreach (ch; 0 .. 3)
                    dst[o + ch] = linearToSrgb8((srgb8ToLinear[src[a + ch]] + srgb8ToLinear[src[b + ch]]
                                               + srgb8ToLinear[src[c + ch]] + srgb8ToLinear[src[d + ch]]) * 0.25f);
            } else {
                foreach (ch; 0 .. 3)
                    dst[o + ch] = cast(ubyte)((src[a + ch] + src[b + ch] + src[c + ch] + src[d + ch] + 2) / 4);
            }
            dst[o + 3] = cast(ubyte)((src[a + 3] + src[b + 3] + src[c + 3] + src[d + 3] + 2) / 4);
        }
    }
}

/// Fill `dst` with RGBA8 levels `1 .. levels` packed back to back
/// (`mipTailBytesRgba8` bytes). Level 0 is `src` itself.
void generateMipChainRgba8(scope const(ubyte)[] src, uint width, uint height,
                           scope ubyte[] dst, uint levels, bool normalMap = false,
                           bool srgb = false) pure nothrow @nogc {
    assert(dst.length >= mipTailBytesRgba8(width, height, levels));
    const(ubyte)[] prev = src;
    uint pw = width, ph = height;
    size_t off = 0;
    foreach (l; 1 .. levels) {
        immutable lw = mipExtent(width, l), lh = mipExtent(height, l);
        immutable bytes = cast(size_t) lw * lh * 4;
        downsampleRgba8(prev, pw, ph, dst[off .. off + bytes], lw, lh, normalMap, srgb);
        prev = dst[off .. off + bytes];
        pw = lw;
        ph = lh;
        off += bytes;
    }
}

/// sRGB transfer function of one 8-bit code, decoded to linear light.
immutable float[256] srgb8ToLinear = () {
    float[256] t;
    foreach (i; 0 .. 256) t[i] = srgbToLinear(i / 255.0);
    return t;
}();

/// Linear value where code `i` ends and code `i + 1` begins.
private immutable float[255] srgb8Thresholds = () {
    float[255] t;
    foreach (i; 0 .. 255) t[i] = srgbToLinear((i + 0.5) / 255.0);
    return t;
}();

private float srgbToLinear(double v) pure nothrow @nogc {
    import std.math : pow;
    return cast(float)(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4));
}

/// Encode a linear value as the nearest 8-bit sRGB code.
ubyte linearToSrgb8(float v) pure nothrow @nogc {
    uint lo = 0, hi = 255;
    while (lo < hi) {
        immutable mid = (lo + hi) / 2;
        if (v >= srgb8Thresholds[mid]) lo = mid + 1;
        else hi = mid;
    }
    return cast(ubyte) lo;
}

private float sqrtF(float v) pure nothrow @nogc {
    import core.math : sqrt;
    return sqrt(v);
}

package(engine) WGPUTexture createTexture2D(ref GpuContext gpu, WGPUTextureFormat fmt,
                                            uint width, uint height, uint layers, uint mips) {
    WGPUTextureDescriptor desc;
    desc.usage         = WGPUTextureUsage.textureBinding | WGPUTextureUsage.copyDst;
    desc.dimension     = WGPUTextureDimension.dim2D;
    desc.size          = WGPUExtent3D(width, height, layers);
    desc.format        = fmt;
    desc.mipLevelCount = mips;
    auto device = gpu.getDevice();
    return () @trusted { return wgpuDeviceCreateTexture(device, &desc); }();
}

package(engine) WGPUTextureView createView(WGPUTexture tex, WGPUTextureFormat fmt,
                                           WGPUTextureViewDimension dim, uint layers) {
    WGPUTextureViewDescriptor vd;
    vd.format    = fmt;
    vd.dimension = dim;
    vd.baseArrayLayer = 0;
    vd.arrayLayerCount = layers;
    return () @trusted { return wgpuTextureCreateView(tex, &vd); }();
}

/// Write one mip level of one array layer.
package(engine) void writeLevel(ref GpuContext gpu, WGPUTexture tex, uint layer, uint mip,
                                scope const(ubyte)[] data, uint w, uint h, uint bytesPerPixel) {
    WGPUImageCopyTexture dst;
    dst.texture  = tex;
    dst.mipLevel = mip;
    dst.origin   = WGPUOrigin3D(0, 0, layer);
    WGPUTextureDataLayout layout;
    layout.bytesPerRow  = w * bytesPerPixel;
    layout.rowsPerImage = h;
    WGPUExtent3D extent = WGPUExtent3D(w, h, 1);
    auto queue = gpu.getQueue();
    () @trusted {
        wgpuQueueWriteTexture(queue, &dst, data.ptr, data.length, &layout, &extent);
    }();
}

/// Upload level 0 plus a CPU-generated mip tail into `layer`.
private void uploadRgba8WithMips(ref GpuContext gpu, WGPUTexture tex, uint layer,
                                 const(ubyte)[] rgba, uint width, uint height,
                                 uint levels, TextureDesc desc) {
    writeLevel(gpu, tex, layer, 0, rgba, width, height, 4);
    if (levels <= 1) return;
    auto tail = new ubyte[mipTailBytesRgba8(width, height, levels)];
    generateMipChainRgba8(rgba, width, height, tail, levels, desc.normalMap, desc.srgb);
    size_t off = 0;
    foreach (l; 1 .. levels) {
        immutable lw = mipExtent(width, l), lh = mipExtent(height, l);
        immutable bytes = cast(size_t) lw * lh * 4;
        writeLevel(gpu, tex, layer, l, tail[off .. off + bytes], lw, lh, 4);
        off += bytes;
    }
}

/**
 * Owned RGBA8 `texture_2d_array` (terrain splat layers, decal atlases).
 * Every layer shares one size and mip count. Bind `view` as `texture_2d_array<f32>`.
 */
struct TextureArray {
    package(engine) WGPUTexture     texture;
    package(engine) WGPUTextureView view;
    uint width;
    uint height;
    uint layers;
    uint mipLevels = 1;
    /// Storage format of `texture`.
    WGPUTextureFormat format = WGPUTextureFormat.rgba8Unorm;

    @disable this(this);

    /// One RGBA8 buffer (`width*height*4` bytes) per layer. Load time only.
    static TextureArray fromLayers(ref GpuContext gpu, scope const(ubyte)[][] layersRgba,
                                   uint width, uint height, TextureDesc desc = TextureDesc.init) {
        TextureArray a;
        if (layersRgba.length == 0) {
            err("TextureArray.fromLayers: no layers");
            return a;
        }
        a.width = width;
        a.height = height;
        a.layers = cast(uint) layersRgba.length;
        a.mipLevels = desc.generateMips ? mipCount(width, height) : 1;
        a.format = desc.format;
        a.texture = createTexture2D(gpu, a.format, width, height, a.layers, a.mipLevels);
        if (a.texture is null) {
            err("TextureArray: failed to create texture");
            return a;
        }
        foreach (i, layer; layersRgba) {
            assert(layer.length == cast(size_t) width * height * 4,
                   "TextureArray.fromLayers: layer size mismatch");
            uploadRgba8WithMips(gpu, a.texture, cast(uint) i, layer, width, height, a.mipLevels, desc);
        }
        a.view = createView(a.texture, a.format, WGPUTextureViewDimension.dim2DArray, a.layers);
        return a;
    }

    bool valid() const nothrow @nogc { return texture !is null; }

    void destroy() nothrow @nogc @trusted {
        if (view !is null)    { wgpuTextureViewRelease(view); view = null; }
        if (texture !is null) { wgpuTextureRelease(texture); texture = null; }
    }
}

/// Sampler options. `maxAnisotropy` is clamped to 1..16; WebGPU only allows
/// anisotropy with linear min/mag/mip filtering, so `nearest` forces 1.
struct SamplerDesc {
    TextureFilter filter = TextureFilter.linear;
    TextureWrap wrap = TextureWrap.repeat;
    ushort maxAnisotropy = 1;
}

/// Pure translation of `SamplerDesc` into the WGPU descriptor.
WGPUSamplerDescriptor samplerDescriptorFor(SamplerDesc d) pure nothrow @nogc {
    WGPUFilterMode fm = d.filter == TextureFilter.linear
        ? WGPUFilterMode.linear : WGPUFilterMode.nearest;
    WGPUMipmapFilterMode mip = d.filter == TextureFilter.linear
        ? WGPUMipmapFilterMode.linear : WGPUMipmapFilterMode.nearest;
    WGPUAddressMode am;
    final switch (d.wrap) {
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
    desc.lodMinClamp  = 0.0f;
    desc.lodMaxClamp  = 32.0f;
    ushort aniso = d.maxAnisotropy < 1 ? 1 : (d.maxAnisotropy > 16 ? 16 : d.maxAnisotropy);
    if (d.filter != TextureFilter.linear) aniso = 1;
    desc.maxAnisotropy = aniso;
    return desc;
}

/// Owned GPU sampler. Reusable across textures / materials.
struct Sampler {
    package(engine) WGPUSampler sampler;

    @disable this(this);

    static Sampler create(ref GpuContext gpu,
                          TextureFilter filter = TextureFilter.linear,
                          TextureWrap wrap = TextureWrap.repeat) {
        return create(gpu, SamplerDesc(filter, wrap, 1));
    }

    /// Sampler with explicit anisotropy (4×/8× recommended for ground and roads).
    static Sampler create(ref GpuContext gpu, SamplerDesc d) {
        auto desc = samplerDescriptorFor(d);
        auto device = gpu.getDevice();
        Sampler s;
        s.sampler = () @trusted { return wgpuDeviceCreateSampler(device, &desc); }();
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

@("texture.mipCount") pure nothrow @nogc unittest {
    assert(mipCount(1, 1) == 1);
    assert(mipCount(4, 4) == 3);
    assert(mipCount(5, 3) == 3);
    assert(mipCount(1024, 1) == 11);
    assert(mipExtent(5, 1) == 2 && mipExtent(5, 2) == 1 && mipExtent(5, 7) == 1);
    assert(mipTailBytesRgba8(4, 4, 3) == (4 + 1) * 4);
}

@("texture.mipChainBox") @safe unittest {
    // 4x4: left half 0, right half 200 → 2x2 level keeps the split, 1x1 is the mean.
    ubyte[4 * 4 * 4] src;
    foreach (y; 0 .. 4) foreach (x; 0 .. 4) {
        immutable v = cast(ubyte)(x < 2 ? 0 : 200);
        src[(y * 4 + x) * 4 .. (y * 4 + x) * 4 + 4] = [v, v, v, 255];
    }
    ubyte[(4 + 1) * 4] tail;
    generateMipChainRgba8(src[], 4, 4, tail[], 3);
    assert(tail[0] == 0 && tail[4] == 200 && tail[8] == 0 && tail[12] == 200);
    assert(tail[3] == 255);
    assert(tail[16] == 100 && tail[19] == 255);
}

@("texture.mipChainNpot") @safe unittest {
    // 5x3 → 2x1 → 1x1, constant colour must stay constant.
    ubyte[5 * 3 * 4] src;
    foreach (i; 0 .. 15) src[i * 4 .. i * 4 + 4] = [10, 20, 30, 40];
    ubyte[(2 * 1 + 1) * 4] tail;
    assert(mipTailBytesRgba8(5, 3, 3) == tail.length);
    generateMipChainRgba8(src[], 5, 3, tail[], 3);
    foreach (i; 0 .. 3)
        assert(tail[i * 4 .. i * 4 + 4] == [10, 20, 30, 40]);
}

@("texture.mipChainNormal") @safe unittest {
    // Two opposing tilted normals average to +Z after renormalization.
    ubyte[2 * 2 * 4] src;
    // (+0.7, 0, 0.7) and (-0.7, 0, 0.7)
    src[0 .. 4] = [217, 128, 217, 255];
    src[4 .. 8] = [38, 128, 217, 255];
    src[8 .. 12] = [217, 128, 217, 255];
    src[12 .. 16] = [38, 128, 217, 255];
    ubyte[4] tail;
    generateMipChainRgba8(src[], 2, 2, tail[], 2, true);
    assert(tail[0] >= 126 && tail[0] <= 129);
    assert(tail[2] >= 253);
}

@("texture.srgbRoundTrip") pure nothrow @nogc unittest {
    foreach (i; 0 .. 256)
        assert(linearToSrgb8(srgb8ToLinear[i]) == i);
    assert(linearToSrgb8(-1) == 0 && linearToSrgb8(2) == 255);
    assert(srgb8ToLinear[128] > 0.2158f && srgb8ToLinear[128] < 0.2159f);
}

@("texture.mipChainSrgb") @safe unittest {
    // Black/white checker: half the light is sRGB 188, not 128. Alpha stays linear.
    ubyte[2 * 2 * 4] src = [0, 0, 0, 0, 255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 0];
    ubyte[4] tail;
    generateMipChainRgba8(src[], 2, 2, tail[], 2, false, true);
    assert(tail == [188, 188, 188, 128]);
    // Constant color stays constant.
    foreach (i; 0 .. 4) src[i * 4 .. i * 4 + 4] = [10, 128, 250, 40];
    generateMipChainRgba8(src[], 2, 2, tail[], 2, false, true);
    assert(tail == [10, 128, 250, 40]);
}

@("texture.descFormat") pure nothrow @nogc unittest {
    assert(TextureDesc.init.format == WGPUTextureFormat.rgba8Unorm);
    assert(TextureDesc.mipped().format == WGPUTextureFormat.rgba8Unorm);
    assert(TextureDesc.mippedNormal().format == WGPUTextureFormat.rgba8Unorm);
    assert(TextureDesc.mippedSrgb().format == WGPUTextureFormat.rgba8UnormSrgb);
}

@("texture.samplerDesc") pure nothrow @nogc unittest {
    auto d = samplerDescriptorFor(SamplerDesc(TextureFilter.linear, TextureWrap.repeat, 8));
    assert(d.maxAnisotropy == 8 && d.mipmapFilter == WGPUMipmapFilterMode.linear);
    assert(samplerDescriptorFor(SamplerDesc(TextureFilter.linear, TextureWrap.clamp, 64)).maxAnisotropy == 16);
    assert(samplerDescriptorFor(SamplerDesc(TextureFilter.linear, TextureWrap.clamp, 0)).maxAnisotropy == 1);
    // Anisotropy requires linear filtering: nearest forces 1.
    assert(samplerDescriptorFor(SamplerDesc(TextureFilter.nearest, TextureWrap.repeat, 8)).maxAnisotropy == 1);
    assert(d.lodMaxClamp == 32.0f);
}
