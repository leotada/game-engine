/// IBL environment — procedural cubemap + precomputed irradiance,
/// GGX specular mips, and BRDF integration LUT for the textured PBR pipeline.
module engine.gpu.ibl;

import std.math : cos, sin, sqrt, PI, abs, pow;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.context : GpuContext;
import engine.math.vec : Vec3;

@safe:

/// Number of mip levels on the prefiltered specular cubemap (roughness 0 → 1).
enum uint IBL_SPECULAR_MIPS = 5;
enum uint IBL_ENV_SIZE = 64;
enum uint IBL_IRRADIANCE_SIZE = 16;
enum uint IBL_LUT_SIZE = 128;

/// GPU resources for image-based lighting (@group(2) on the textured pipeline).
struct IblEnvironment {
    WGPUTexture     irradianceTex;
    WGPUTextureView irradianceView;
    WGPUTexture     specularTex;
    WGPUTextureView specularView;
    WGPUTexture     brdfLutTex;
    WGPUTextureView brdfLutView;
    WGPUSampler     sampler;
    WGPUBindGroup   bindGroup;

    @disable this(this);

    /// Build a procedural sky environment and prefilter it for PBR.
    static IblEnvironment create(ref GpuContext gpu, WGPUBindGroupLayout layout) @trusted {
        IblEnvironment env;
        auto device = gpu.getDevice();
        auto queue  = gpu.getQueue();

        // --- Base env cubemap (CPU procedural sky) ---
        auto envFaces = generateEnvCubemap(IBL_ENV_SIZE);
        auto envTex = createCubeTexture(device, IBL_ENV_SIZE, 1);
        uploadCubeFaces(queue, envTex, envFaces, IBL_ENV_SIZE, 0);

        // --- Irradiance ---
        auto irrFaces = convolveIrradiance(envFaces, IBL_ENV_SIZE, IBL_IRRADIANCE_SIZE);
        env.irradianceTex = createCubeTexture(device, IBL_IRRADIANCE_SIZE, 1);
        uploadCubeFaces(queue, env.irradianceTex, irrFaces, IBL_IRRADIANCE_SIZE, 0);
        env.irradianceView = createCubeView(env.irradianceTex, 0, 1);

        // --- Specular mips ---
        env.specularTex = createCubeTexture(device, IBL_ENV_SIZE, IBL_SPECULAR_MIPS);
        foreach (mip; 0 .. IBL_SPECULAR_MIPS) {
            immutable size = IBL_ENV_SIZE >> mip;
            immutable roughness = mip == 0 ? 0.0f
                : cast(float) mip / cast(float)(IBL_SPECULAR_MIPS - 1);
            auto faces = prefilterSpecular(envFaces, IBL_ENV_SIZE, size, roughness);
            uploadCubeFaces(queue, env.specularTex, faces, size, mip);
        }
        env.specularView = createCubeView(env.specularTex, 0, IBL_SPECULAR_MIPS);

        // --- BRDF LUT ---
        auto lutPixels = generateBrdfLut(IBL_LUT_SIZE);
        env.brdfLutTex = createLutTexture(device, queue, lutPixels, IBL_LUT_SIZE);
        WGPUTextureViewDescriptor lutVd;
        lutVd.format = WGPUTextureFormat.rgba8Unorm;
        lutVd.dimension = WGPUTextureViewDimension.dim2D;
        env.brdfLutView = wgpuTextureCreateView(env.brdfLutTex, &lutVd);

        WGPUSamplerDescriptor sd;
        sd.addressModeU = WGPUAddressMode.clampToEdge;
        sd.addressModeV = WGPUAddressMode.clampToEdge;
        sd.addressModeW = WGPUAddressMode.clampToEdge;
        sd.magFilter = WGPUFilterMode.linear;
        sd.minFilter = WGPUFilterMode.linear;
        sd.mipmapFilter = WGPUMipmapFilterMode.linear;
        sd.lodMinClamp = 0;
        sd.lodMaxClamp = cast(float)(IBL_SPECULAR_MIPS - 1);
        sd.maxAnisotropy = 1;
        env.sampler = wgpuDeviceCreateSampler(device, &sd);

        WGPUBindGroupEntry[4] entries;
        entries[0].binding = 0;
        entries[0].textureView = env.irradianceView;
        entries[1].binding = 1;
        entries[1].textureView = env.specularView;
        entries[2].binding = 2;
        entries[2].textureView = env.brdfLutView;
        entries[3].binding = 3;
        entries[3].sampler = env.sampler;

        WGPUBindGroupDescriptor bgd;
        bgd.layout = layout;
        bgd.entryCount = 4;
        bgd.entries = entries.ptr;
        env.bindGroup = wgpuDeviceCreateBindGroup(device, &bgd);
        if (env.bindGroup is null) fatal("Failed to create IBL bind group");

        // Base env tex only needed during precompute.
        wgpuTextureRelease(envTex);

        info("IBL environment created (", IBL_ENV_SIZE, " env, ",
             IBL_IRRADIANCE_SIZE, " irradiance, ", IBL_SPECULAR_MIPS, " specular mips)");
        return env;
    }

    void destroy() nothrow @nogc @trusted {
        if (bindGroup !is null) { wgpuBindGroupRelease(bindGroup); bindGroup = null; }
        if (sampler !is null) { wgpuSamplerRelease(sampler); sampler = null; }
        if (brdfLutView !is null) { wgpuTextureViewRelease(brdfLutView); brdfLutView = null; }
        if (brdfLutTex !is null) { wgpuTextureRelease(brdfLutTex); brdfLutTex = null; }
        if (specularView !is null) { wgpuTextureViewRelease(specularView); specularView = null; }
        if (specularTex !is null) { wgpuTextureRelease(specularTex); specularTex = null; }
        if (irradianceView !is null) { wgpuTextureViewRelease(irradianceView); irradianceView = null; }
        if (irradianceTex !is null) { wgpuTextureRelease(irradianceTex); irradianceTex = null; }
    }
}

// ---------------------------------------------------------------------------
// CPU cubemap generation helpers
// ---------------------------------------------------------------------------

private struct Rgb { float r, g, b; }

private Rgb sampleSky(Vec3 dir) {
    immutable d = dir.normalized();
    immutable t = clamp01(d.y * 0.5f + 0.5f);
    // Horizon → zenith gradient
    immutable zenith = Rgb(0.15f, 0.35f, 0.85f);
    immutable horizon = Rgb(0.75f, 0.82f, 0.95f);
    immutable ground = Rgb(0.12f, 0.10f, 0.08f);
    Rgb sky;
    if (d.y >= 0) {
        sky = lerp(horizon, zenith, t);
    } else {
        sky = lerp(horizon, ground, clamp01(-d.y));
    }
    // Soft sun disc
    immutable sunDir = Vec3(0.3f, 0.85f, 0.4f).normalized();
    immutable sunDot = clamp01(d.dot(sunDir));
    immutable sun = pow(sunDot, 64.0f) * 4.0f;
    sky.r = clamp01(sky.r + sun);
    sky.g = clamp01(sky.g + sun * 0.95f);
    sky.b = clamp01(sky.b + sun * 0.8f);
    return sky;
}

private Vec3 faceDir(uint face, float u, float v) {
    // u,v in [-1,1]
    switch (face) {
        case 0: return Vec3( 1, -v, -u); // +X
        case 1: return Vec3(-1, -v,  u); // -X
        case 2: return Vec3( u,  1,  v); // +Y
        case 3: return Vec3( u, -1, -v); // -Y
        case 4: return Vec3( u, -v,  1); // +Z
        default: return Vec3(-u, -v, -1); // -Z
    }
}

private ubyte[][] generateEnvCubemap(uint size) {
    auto faces = new ubyte[][](6);
    foreach (face; 0 .. 6) {
        faces[face] = new ubyte[size * size * 4];
        foreach (y; 0 .. size) foreach (x; 0 .. size) {
            immutable u = (cast(float) x + 0.5f) / cast(float) size * 2.0f - 1.0f;
            immutable v = (cast(float) y + 0.5f) / cast(float) size * 2.0f - 1.0f;
            immutable c = sampleSky(faceDir(face, u, v));
            immutable i = (y * size + x) * 4;
            faces[face][i + 0] = toU8(c.r);
            faces[face][i + 1] = toU8(c.g);
            faces[face][i + 2] = toU8(c.b);
            faces[face][i + 3] = 255;
        }
    }
    return faces;
}

private Rgb sampleFace(const ubyte[][] faces, uint size, Vec3 dir) {
    immutable d = dir.normalized();
    immutable ax = abs(d.x), ay = abs(d.y), az = abs(d.z);
    uint face;
    float sc, tc, ma;
    if (ax >= ay && ax >= az) {
        if (d.x > 0) { face = 0; sc = -d.z; tc = -d.y; }
        else         { face = 1; sc =  d.z; tc = -d.y; }
        ma = ax;
    } else if (ay >= ax && ay >= az) {
        if (d.y > 0) { face = 2; sc =  d.x; tc =  d.z; }
        else         { face = 3; sc =  d.x; tc = -d.z; }
        ma = ay;
    } else {
        if (d.z > 0) { face = 4; sc =  d.x; tc = -d.y; }
        else         { face = 5; sc = -d.x; tc = -d.y; }
        ma = az;
    }
    immutable u = 0.5f * (sc / ma + 1.0f);
    immutable v = 0.5f * (tc / ma + 1.0f);
    immutable x = cast(uint) clampF(u * cast(float)(size - 1), 0, cast(float)(size - 1));
    immutable y = cast(uint) clampF(v * cast(float)(size - 1), 0, cast(float)(size - 1));
    immutable i = (y * size + x) * 4;
    auto px = faces[face];
    return Rgb(px[i] / 255.0f, px[i + 1] / 255.0f, px[i + 2] / 255.0f);
}

private ubyte[][] convolveIrradiance(const ubyte[][] env, uint envSize, uint outSize) {
    auto faces = new ubyte[][](6);
    // Sparse hemisphere sampling for startup cost.
    enum uint samples = 32;
    foreach (face; 0 .. 6) {
        faces[face] = new ubyte[outSize * outSize * 4];
        foreach (y; 0 .. outSize) foreach (x; 0 .. outSize) {
            immutable u = (cast(float) x + 0.5f) / cast(float) outSize * 2.0f - 1.0f;
            immutable v = (cast(float) y + 0.5f) / cast(float) outSize * 2.0f - 1.0f;
            immutable N = faceDir(face, u, v).normalized();
            Rgb sum = Rgb(0, 0, 0);
            float weight = 0;
            foreach (si; 0 .. samples) {
                immutable xi = hammersley(si, samples);
                immutable L = importanceSampleCosine(xi, N);
                immutable ndotl = max(N.dot(L), 0.0f);
                if (ndotl > 0) {
                    immutable c = sampleFace(env, envSize, L);
                    sum.r += c.r * ndotl;
                    sum.g += c.g * ndotl;
                    sum.b += c.b * ndotl;
                    weight += ndotl;
                }
            }
            if (weight > 0) {
                sum.r /= weight;
                sum.g /= weight;
                sum.b /= weight;
            }
            immutable i = (y * outSize + x) * 4;
            faces[face][i + 0] = toU8(sum.r);
            faces[face][i + 1] = toU8(sum.g);
            faces[face][i + 2] = toU8(sum.b);
            faces[face][i + 3] = 255;
        }
    }
    return faces;
}

private ubyte[][] prefilterSpecular(const ubyte[][] env, uint envSize,
                                    uint outSize, float roughness) {
    auto faces = new ubyte[][](6);
    immutable uint samples = roughness < 0.01f ? 1 : 32;
    foreach (face; 0 .. 6) {
        faces[face] = new ubyte[outSize * outSize * 4];
        foreach (y; 0 .. outSize) foreach (x; 0 .. outSize) {
            immutable u = (cast(float) x + 0.5f) / cast(float) outSize * 2.0f - 1.0f;
            immutable v = (cast(float) y + 0.5f) / cast(float) outSize * 2.0f - 1.0f;
            immutable R = faceDir(face, u, v).normalized();
            immutable N = R;
            immutable V = R;
            Rgb sum = Rgb(0, 0, 0);
            float weight = 0;
            foreach (si; 0 .. samples) {
                immutable xi = hammersley(si, samples);
                immutable H = importanceSampleGGX(xi, N, roughness);
                immutable L = (H * 2.0f * V.dot(H) - V).normalized();
                immutable ndotl = max(N.dot(L), 0.0f);
                if (ndotl > 0) {
                    immutable c = sampleFace(env, envSize, L);
                    sum.r += c.r * ndotl;
                    sum.g += c.g * ndotl;
                    sum.b += c.b * ndotl;
                    weight += ndotl;
                }
            }
            if (weight > 0) {
                sum.r /= weight;
                sum.g /= weight;
                sum.b /= weight;
            }
            immutable i = (y * outSize + x) * 4;
            faces[face][i + 0] = toU8(sum.r);
            faces[face][i + 1] = toU8(sum.g);
            faces[face][i + 2] = toU8(sum.b);
            faces[face][i + 3] = 255;
        }
    }
    return faces;
}

private ubyte[] generateBrdfLut(uint size) {
    auto pixels = new ubyte[size * size * 4];
    enum uint samples = 64;
    foreach (y; 0 .. size) foreach (x; 0 .. size) {
        immutable NdotV = (cast(float) x + 0.5f) / cast(float) size;
        immutable roughness = (cast(float) y + 0.5f) / cast(float) size;
        immutable V = Vec3(sqrt(1.0f - NdotV * NdotV), 0, NdotV);
        immutable N = Vec3(0, 0, 1);
        float A = 0, B = 0;
        foreach (si; 0 .. samples) {
            immutable xi = hammersley(si, samples);
            immutable H = importanceSampleGGX(xi, N, roughness);
            immutable L = (H * 2.0f * V.dot(H) - V).normalized();
            immutable NdotL = max(L.z, 0.0f);
            immutable NdotH = max(H.z, 0.0f);
            immutable VdotH = max(V.dot(H), 0.0f);
            if (NdotL > 0) {
                immutable G = geometrySmith(NdotV, NdotL, roughness);
                immutable G_Vis = (G * VdotH) / max(NdotH * NdotV, 1e-5f);
                immutable Fc = pow(1.0f - VdotH, 5.0f);
                A += (1.0f - Fc) * G_Vis;
                B += Fc * G_Vis;
            }
        }
        A /= samples;
        B /= samples;
        immutable i = (y * size + x) * 4;
        pixels[i + 0] = toU8(A);
        pixels[i + 1] = toU8(B);
        pixels[i + 2] = 0;
        pixels[i + 3] = 255;
    }
    return pixels;
}

// ---------------------------------------------------------------------------
// Math / sampling
// ---------------------------------------------------------------------------

private float radicalInverseVdC(uint bits) {
    bits = (bits << 16) | (bits >> 16);
    bits = ((bits & 0x55555555) << 1) | ((bits & 0xAAAAAAAA) >> 1);
    bits = ((bits & 0x33333333) << 2) | ((bits & 0xCCCCCCCC) >> 2);
    bits = ((bits & 0x0F0F0F0F) << 4) | ((bits & 0xF0F0F0F0) >> 4);
    bits = ((bits & 0x00FF00FF) << 8) | ((bits & 0xFF00FF00) >> 8);
    return cast(float) bits * 2.3283064365386963e-10f;
}

private float[2] hammersley(uint i, uint n) {
    return [cast(float) i / cast(float) n, radicalInverseVdC(i)];
}

private Vec3 importanceSampleGGX(float[2] xi, Vec3 N, float roughness) {
    immutable a = roughness * roughness;
    immutable phi = 2.0f * PI * xi[0];
    immutable cosTheta = sqrt((1.0f - xi[1]) / (1.0f + (a * a - 1.0f) * xi[1]));
    immutable sinTheta = sqrt(1.0f - cosTheta * cosTheta);
    immutable H = Vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
    immutable up = abs(N.z) < 0.999f ? Vec3(0, 0, 1) : Vec3(1, 0, 0);
    immutable tangent = up.cross(N).normalized();
    immutable bitangent = N.cross(tangent);
    return (tangent * H.x + bitangent * H.y + N * H.z).normalized();
}

private Vec3 importanceSampleCosine(float[2] xi, Vec3 N) {
    immutable phi = 2.0f * PI * xi[0];
    immutable cosTheta = sqrt(1.0f - xi[1]);
    immutable sinTheta = sqrt(xi[1]);
    immutable H = Vec3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
    immutable up = abs(N.z) < 0.999f ? Vec3(0, 0, 1) : Vec3(1, 0, 0);
    immutable tangent = up.cross(N).normalized();
    immutable bitangent = N.cross(tangent);
    return (tangent * H.x + bitangent * H.y + N * H.z).normalized();
}

private float geometrySchlickGGX(float NdotX, float roughness) {
    immutable a = roughness;
    immutable k = (a * a) / 2.0f;
    return NdotX / (NdotX * (1.0f - k) + k);
}

private float geometrySmith(float NdotV, float NdotL, float roughness) {
    return geometrySchlickGGX(NdotV, roughness) * geometrySchlickGGX(NdotL, roughness);
}

private float clamp01(float v) {
    return v < 0 ? 0 : (v > 1 ? 1 : v);
}

private float clampF(float v, float lo, float hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

private float max(float a, float b) {
    return a > b ? a : b;
}

private Rgb lerp(Rgb a, Rgb b, float t) {
    return Rgb(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t);
}

private ubyte toU8(float v) {
    immutable c = clamp01(v);
    return cast(ubyte)(c * 255.0f + 0.5f);
}

// ---------------------------------------------------------------------------
// GPU upload
// ---------------------------------------------------------------------------

private WGPUTexture createCubeTexture(WGPUDevice device, uint size, uint mipCount) @trusted {
    WGPUTextureDescriptor td;
    td.usage = WGPUTextureUsage.textureBinding | WGPUTextureUsage.copyDst;
    td.dimension = WGPUTextureDimension.dim2D;
    td.size = WGPUExtent3D(size, size, 6);
    td.format = WGPUTextureFormat.rgba8Unorm;
    td.mipLevelCount = mipCount;
    auto tex = wgpuDeviceCreateTexture(device, &td);
    if (tex is null) fatal("Failed to create IBL cube texture");
    return tex;
}

private WGPUTextureView createCubeView(WGPUTexture tex, uint baseMip, uint mipCount) @trusted {
    WGPUTextureViewDescriptor vd;
    vd.format = WGPUTextureFormat.rgba8Unorm;
    vd.dimension = WGPUTextureViewDimension.cube;
    vd.baseMipLevel = baseMip;
    vd.mipLevelCount = mipCount;
    vd.baseArrayLayer = 0;
    vd.arrayLayerCount = 6;
    return wgpuTextureCreateView(tex, &vd);
}

private void uploadCubeFaces(WGPUQueue queue, WGPUTexture tex,
                             ubyte[][] faces, uint size, uint mip) @trusted {
    foreach (face; 0 .. 6) {
        WGPUImageCopyTexture dst;
        dst.texture = tex;
        dst.mipLevel = mip;
        dst.origin = WGPUOrigin3D(0, 0, face);
        dst.aspect = WGPUTextureAspect.all;

        WGPUTextureDataLayout layout;
        layout.bytesPerRow = size * 4;
        layout.rowsPerImage = size;

        WGPUExtent3D extent = WGPUExtent3D(size, size, 1);
        wgpuQueueWriteTexture(queue, &dst, faces[face].ptr, faces[face].length,
                              &layout, &extent);
    }
}

private WGPUTexture createLutTexture(WGPUDevice device, WGPUQueue queue,
                                     ubyte[] pixels, uint size) @trusted {
    WGPUTextureDescriptor td;
    td.usage = WGPUTextureUsage.textureBinding | WGPUTextureUsage.copyDst;
    td.dimension = WGPUTextureDimension.dim2D;
    td.size = WGPUExtent3D(size, size, 1);
    td.format = WGPUTextureFormat.rgba8Unorm;
    td.mipLevelCount = 1;
    auto tex = wgpuDeviceCreateTexture(device, &td);
    if (tex is null) fatal("Failed to create BRDF LUT texture");

    WGPUImageCopyTexture dst;
    dst.texture = tex;
    WGPUTextureDataLayout layout;
    layout.bytesPerRow = size * 4;
    layout.rowsPerImage = size;
    WGPUExtent3D extent = WGPUExtent3D(size, size, 1);
    wgpuQueueWriteTexture(queue, &dst, pixels.ptr, pixels.length, &layout, &extent);
    return tex;
}
