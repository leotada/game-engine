/// Interactive OpenPBR Surface v1.1 Ocean & River Water Showcase.
///
/// Demonstrates what the current single-pass OpenPBR v1.1 pipeline renders
/// (animated 6-octave Gerstner waves with analytical tangent/normal frames,
/// physical IOR 1.333, dual-lobe specular + clearcoat water film, anisotropic
/// river flow, Charlie crest fuzz, Fresnel-modulated opacity over a submerged
/// pebble bed, wet vs. dry vs. mossy shoreline rocks with coat darkening,
/// F82 metal and thin-film iridescent floating buoys, and multi-light PCF
/// shadows) and serves as the testbed for upcoming OPBR-6..9 phases
/// (layer texture maps, multi-pass refraction, SSS, local reflection probes/SSR).
module demo.water;

import std.math : cos, fabs, sin, sqrt, PI, PI_2;

import engine.app;
import engine.assets.gltf : loadGltfMesh;
import engine.core.log;
import engine.gpu.buffer;
import engine.gpu.context : GpuContext;
import engine.gpu.shadow;
import engine.gpu.text;
import engine.graphics.material : Material, MaterialFlags, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, Texture, TextureFilter, TextureWrap;
import engine.graphics.types : Color4, InstanceData, TexTanVert;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.platform.input : InputState, Key, MouseButton;
import engine.scene.camera : Camera;
import engine.scene.light :
    GpuSpotLight, LightSet, MAX_POINT_SHADOW_CASTERS, MAX_SPOT_SHADOW_CASTERS,
    SPOT_SHADOW_RESOLUTION;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

private enum int W = 1280;
private enum int H = 720;
private enum uint WATER_GRID = 64;
private enum float WATER_HALF = 14.0f;

private struct WaveComponent {
    float dirX;
    float dirZ;
    float wavelength;
    float amplitude;
    float steepness;
    float speedScale;
}

private immutable WaveComponent[6] OCEAN_WAVES = [
    WaveComponent( 0.86f,  0.51f, 9.5f, 0.24f, 0.52f, 1.00f),
    WaveComponent( 0.42f, -0.91f, 6.2f, 0.14f, 0.48f, 1.15f),
    WaveComponent(-0.68f,  0.73f, 4.1f, 0.08f, 0.44f, 1.25f),
    WaveComponent( 0.96f, -0.28f, 2.7f, 0.045f, 0.40f, 1.35f),
    WaveComponent(-0.22f, -0.97f, 1.8f, 0.025f, 0.35f, 1.50f),
    WaveComponent( 0.61f,  0.79f, 1.15f, 0.015f, 0.30f, 1.65f),
];

private immutable WaveComponent[6] RIVER_WAVES = [
    WaveComponent( 0.96f,  0.28f, 4.4f, 0.075f, 0.40f, 1.65f),
    WaveComponent( 0.92f, -0.39f, 3.1f, 0.055f, 0.42f, 1.80f),
    WaveComponent( 0.78f,  0.62f, 2.1f, 0.038f, 0.44f, 1.95f),
    WaveComponent( 0.85f, -0.52f, 1.45f, 0.024f, 0.38f, 2.15f),
    WaveComponent( 0.99f,  0.14f, 0.95f, 0.014f, 0.34f, 2.30f),
    WaveComponent( 0.72f, -0.69f, 0.68f, 0.009f, 0.28f, 2.45f),
];

private struct WaveSample {
    Vec3 position;
    Vec3 normal;
    Vec3 tangent;
    float foam;
}

/// Deterministic fractional noise in [0, 1] from integer coordinates.
private float hash2D(int ix, int iy) pure nothrow @nogc {
    uint n = cast(uint)(ix * 374761393 + iy * 668265263);
    n = (n ^ (n >> 13)) * 1274126177u;
    return cast(float)((n ^ (n >> 16)) & 0x00FFFFFFu) / 16777215.0f;
}

private float valueNoise(float x, float y) pure nothrow @nogc {
    import std.math : floor;
    immutable fx = floor(x);
    immutable fy = floor(y);
    immutable ix = cast(int) fx;
    immutable iy = cast(int) fy;
    immutable tx = x - fx;
    immutable ty = y - fy;
    immutable ux = tx * tx * (3.0f - 2.0f * tx);
    immutable uy = ty * ty * (3.0f - 2.0f * ty);

    immutable a = hash2D(ix, iy);
    immutable b = hash2D(ix + 1, iy);
    immutable c = hash2D(ix, iy + 1);
    immutable d = hash2D(ix + 1, iy + 1);
    return (a + (b - a) * ux) + ((c - a) + (a - b - c + d) * ux) * uy;
}

private float fbmPeriodic(float u, float v, int period, int octaves) pure nothrow @nogc {
    float sum = 0.0f;
    float amp = 0.5f;
    float norm = 0.0f;
    int p = period;
    foreach (_; 0 .. octaves) {
        immutable gx = u * cast(float) p;
        immutable gy = v * cast(float) p;
        import std.math : floor;
        immutable fx = floor(gx);
        immutable fy = floor(gy);
        immutable ix0 = ((cast(int) fx) % p + p) % p;
        immutable iy0 = ((cast(int) fy) % p + p) % p;
        immutable ix1 = (ix0 + 1) % p;
        immutable iy1 = (iy0 + 1) % p;
        immutable tx = gx - fx;
        immutable ty = gy - fy;
        immutable ux = tx * tx * (3.0f - 2.0f * tx);
        immutable uy = ty * ty * (3.0f - 2.0f * ty);
        immutable a = hash2D(ix0 + p * 7, iy0 + p * 13);
        immutable b = hash2D(ix1 + p * 7, iy0 + p * 13);
        immutable c = hash2D(ix0 + p * 7, iy1 + p * 13);
        immutable d = hash2D(ix1 + p * 7, iy1 + p * 13);
        immutable n = (a + (b - a) * ux) + ((c - a) + (a - b - c + d) * ux) * uy;
        sum += n * amp;
        norm += amp;
        amp *= 0.5f;
        p *= 2;
    }
    return norm > 0.0f ? sum / norm : 0.0f;
}

private ubyte clampByte(float v) pure nothrow @nogc {
    if (v <= 0.0f) return 0;
    if (v >= 255.0f) return 255;
    return cast(ubyte) v;
}

/// Evaluate 6-octave Gerstner swell + analytical tangent/bitangent/normal.
private WaveSample sampleGerstner(float x, float z, float time, bool riverMode, float waveScale) pure nothrow @nogc {
    immutable waves = riverMode ? RIVER_WAVES : OCEAN_WAVES;
    Vec3 p = Vec3(x, 0.0f, z);
    Vec3 dPdx = Vec3(1.0f, 0.0f, 0.0f);
    Vec3 dPdz = Vec3(0.0f, 0.0f, 1.0f);

    float bankMask = 1.0f;
    if (riverMode) {
        // Taper wave height slightly near the canyon riverbanks |z| > 5.5
        immutable absZ = fabs(z);
        if (absZ > 4.5f) {
            immutable t = (absZ - 4.5f) / 3.5f;
            bankMask = t >= 1.0f ? 0.15f : 1.0f - t * 0.85f;
        }
    }

    float heightAccum = 0.0f;
    foreach (ref w; waves) {
        immutable k = (2.0f * cast(float) PI) / w.wavelength;
        immutable c = sqrt(9.81f / k) * w.speedScale;
        immutable a = w.amplitude * waveScale * bankMask;
        immutable q = w.steepness;
        immutable phase = k * (w.dirX * x + w.dirZ * z) - k * c * time;
        immutable sn = sin(phase);
        immutable cs = cos(phase);

        immutable qa = q * a;
        p.x += qa * w.dirX * cs;
        p.y += a * sn;
        p.z += qa * w.dirZ * cs;
        heightAccum += sn * 0.5f + 0.5f;

        immutable wa = k * a;
        immutable qwa = q * wa;
        dPdx.x -= qwa * w.dirX * w.dirX * sn;
        dPdx.y += wa * w.dirX * cs;
        dPdx.z -= qwa * w.dirX * w.dirZ * sn;

        dPdz.x -= qwa * w.dirX * w.dirZ * sn;
        dPdz.y += wa * w.dirZ * cs;
        dPdz.z -= qwa * w.dirZ * w.dirZ * sn;
    }

    // Normal = normalize(cross(dPdz, dPdx)) points +Y when dPdx=(1,0,0), dPdz=(0,0,1).
    Vec3 n = dPdz.cross(dPdx).normalized();
    Vec3 t = dPdx.normalized();
    t = (t - n * n.dot(t)).normalized();

    WaveSample s;
    s.position = p;
    s.normal = n;
    s.tangent = t;
    s.foam = heightAccum / cast(float) waves.length;
    return s;
}

private void fillWaterGridVertices(TexTanVert[] verts, float time, bool riverMode, float waveScale) nothrow @nogc {
    immutable uint stride = WATER_GRID + 1;
    immutable float span = WATER_HALF * 2.0f;
    immutable float flowU = riverMode ? 0.14f * time : 0.028f * time;
    immutable float flowV = riverMode ? 0.015f * time : 0.022f * time;

    foreach (row; 0 .. stride) {
        immutable float v = cast(float) row / cast(float) WATER_GRID;
        immutable float z = -WATER_HALF + v * span;
        foreach (col; 0 .. stride) {
            immutable float u = cast(float) col / cast(float) WATER_GRID;
            immutable float x = -WATER_HALF + u * span;
            immutable w = sampleGerstner(x, z, time, riverMode, waveScale);
            immutable uint idx = row * stride + col;
            verts[idx] = TexTanVert(
                [w.position.x, w.position.y, w.position.z],
                [w.normal.x, w.normal.y, w.normal.z],
                [u * 7.0f + flowU, v * 7.0f + flowV],
                [w.tangent.x, w.tangent.y, w.tangent.z, -1.0f]
            );
        }
    }
}

private TexMesh buildWaterMesh(ref GpuContext gpu, out TexTanVert[] cpuVerts) {
    immutable uint stride = WATER_GRID + 1;
    cpuVerts = new TexTanVert[stride * stride];
    fillWaterGridVertices(cpuVerts, 0.0f, false, 1.0f);

    auto indices = new ushort[WATER_GRID * WATER_GRID * 6];
    uint ii = 0;
    foreach (row; 0 .. WATER_GRID) {
        foreach (col; 0 .. WATER_GRID) {
            immutable ushort a = cast(ushort)(row * stride + col);
            immutable ushort b = cast(ushort)(a + 1);
            immutable ushort c = cast(ushort)(a + stride);
            immutable ushort d = cast(ushort)(c + 1);
            // Counter-clockwise winding viewed from +Y
            indices[ii++] = a;
            indices[ii++] = d;
            indices[ii++] = b;
            indices[ii++] = a;
            indices[ii++] = c;
            indices[ii++] = d;
        }
    }
    return TexMesh.fromData(gpu, cpuVerts, indices);
}

private void generateWaterTextures(ref GpuContext gpu,
                                   out Texture albedoTex,
                                   out Texture normalTex,
                                   out Texture mrTex) {
    enum uint SZ = 256;
    auto albedo = new ubyte[SZ * SZ * 4];
    auto normal = new ubyte[SZ * SZ * 4];
    auto mr     = new ubyte[SZ * SZ * 4];
    auto height = new float[SZ * SZ];

    foreach (y; 0 .. SZ) {
        immutable float v = cast(float) y / cast(float) SZ;
        foreach (x; 0 .. SZ) {
            immutable float u = cast(float) x / cast(float) SZ;
            immutable h1 = fbmPeriodic(u, v, 8, 4);
            immutable h2 = fbmPeriodic(u + 0.37f, v + 0.19f, 16, 3);
            immutable h = h1 * 0.65f + h2 * 0.35f;
            height[y * SZ + x] = h;

            // Slight crest foam brightening; base deep tint comes from MaterialParams.baseColor
            immutable foam = h > 0.64f ? (h - 0.64f) * 2.4f : 0.0f;
            immutable baseRgb = 205.0f + foam * 50.0f;
            immutable idx = (y * SZ + x) * 4;
            albedo[idx + 0] = clampByte(baseRgb);
            albedo[idx + 1] = clampByte(baseRgb + 8.0f);
            albedo[idx + 2] = clampByte(baseRgb + 14.0f);
            albedo[idx + 3] = 255;

            // Roughness in G channel (smooth water troughs, slightly rougher ripples/foam)
            immutable r = 18.0f + h * 26.0f + foam * 110.0f;
            mr[idx + 0] = 255;
            mr[idx + 1] = clampByte(r);
            mr[idx + 2] = 0; // non-metallic
            mr[idx + 3] = 255;
        }
    }

    enum float NORMAL_STRENGTH = 3.2f;
    foreach (y; 0 .. SZ) {
        immutable uint ym = (y + SZ - 1) % SZ;
        immutable uint yp = (y + 1) % SZ;
        foreach (x; 0 .. SZ) {
            immutable uint xm = (x + SZ - 1) % SZ;
            immutable uint xp = (x + 1) % SZ;
            immutable float dx = (height[y * SZ + xp] - height[y * SZ + xm]) * NORMAL_STRENGTH;
            immutable float dy = (height[yp * SZ + x] - height[ym * SZ + x]) * NORMAL_STRENGTH;
            immutable Vec3 n = Vec3(-dx, -dy, 1.0f).normalized();
            immutable idx = (y * SZ + x) * 4;
            normal[idx + 0] = clampByte((n.x * 0.5f + 0.5f) * 255.0f);
            normal[idx + 1] = clampByte((n.y * 0.5f + 0.5f) * 255.0f);
            normal[idx + 2] = clampByte((n.z * 0.5f + 0.5f) * 255.0f);
            normal[idx + 3] = 255;
        }
    }

    albedoTex = Texture.fromPixels(gpu, albedo, SZ, SZ);
    normalTex = Texture.fromPixels(gpu, normal, SZ, SZ);
    mrTex     = Texture.fromPixels(gpu, mr, SZ, SZ);
}

private void generateRockAndBedTextures(ref GpuContext gpu,
                                        out Texture rockAlbedoTex,
                                        out Texture rockNormalTex,
                                        out Texture bedTex) {
    enum uint SZ = 256;
    auto rockA = new ubyte[SZ * SZ * 4];
    auto rockN = new ubyte[SZ * SZ * 4];
    auto bedA  = new ubyte[SZ * SZ * 4];
    auto rockH = new float[SZ * SZ];

    foreach (y; 0 .. SZ) {
        immutable float v = cast(float) y / cast(float) SZ;
        foreach (x; 0 .. SZ) {
            immutable float u = cast(float) x / cast(float) SZ;
            immutable n = fbmPeriodic(u, v, 8, 4);
            immutable grit = fbmPeriodic(u + 0.13f, v + 0.41f, 24, 2);
            immutable speckle = fbmPeriodic(u + 0.53f, v + 0.19f, 32, 2);
            immutable vein = fabs(fbmPeriodic(u + 0.31f, v + 0.77f, 6, 3) - 0.5f) * 2.0f;
            immutable crevice = vein < 0.20f ? (0.52f + 0.48f * (vein / 0.20f)) : 1.0f;

            immutable hVal = (n * 0.65f + grit * 0.22f + speckle * 0.13f) * (0.72f + 0.28f * crevice);
            rockH[y * SZ + x] = hVal;

            immutable idx = (y * SZ + x) * 4;
            immutable rockLum = (112.0f + n * 78.0f + (grit - 0.5f) * 38.0f + (speckle - 0.5f) * 30.0f) * crevice;
            rockA[idx + 0] = clampByte(rockLum * 1.03f);
            rockA[idx + 1] = clampByte(rockLum * 0.98f);
            rockA[idx + 2] = clampByte(rockLum * 0.92f);
            rockA[idx + 3] = 255;

            // Submerged river/seabed sand + pebble mottling
            immutable pebbles = fbmPeriodic(u + 0.21f, v + 0.67f, 16, 4);
            immutable bedLum = 82.0f + pebbles * 90.0f;
            bedA[idx + 0] = clampByte(bedLum * 1.06f);
            bedA[idx + 1] = clampByte(bedLum * 0.95f);
            bedA[idx + 2] = clampByte(bedLum * 0.76f);
            bedA[idx + 3] = 255;
        }
    }

    enum float ROCK_NORMAL_STRENGTH = 2.4f;
    foreach (y; 0 .. SZ) {
        immutable uint ym = (y + SZ - 1) % SZ;
        immutable uint yp = (y + 1) % SZ;
        foreach (x; 0 .. SZ) {
            immutable uint xm = (x + SZ - 1) % SZ;
            immutable uint xp = (x + 1) % SZ;
            immutable float dx = (rockH[y * SZ + xp] - rockH[y * SZ + xm]) * ROCK_NORMAL_STRENGTH;
            immutable float dy = (rockH[yp * SZ + x] - rockH[ym * SZ + x]) * ROCK_NORMAL_STRENGTH;
            immutable Vec3 n = Vec3(-dx, -dy, 1.0f).normalized();
            immutable idx = (y * SZ + x) * 4;
            rockN[idx + 0] = clampByte((n.x * 0.5f + 0.5f) * 255.0f);
            rockN[idx + 1] = clampByte((n.y * 0.5f + 0.5f) * 255.0f);
            rockN[idx + 2] = clampByte((n.z * 0.5f + 0.5f) * 255.0f);
            rockN[idx + 3] = 255;
        }
    }

    rockAlbedoTex = Texture.fromPixels(gpu, rockA, SZ, SZ);
    rockNormalTex = Texture.fromPixels(gpu, rockN, SZ, SZ);
    bedTex        = Texture.fromPixels(gpu, bedA, SZ, SZ);
}

private struct RockPlacement {
    Vec3 pos;
    Vec3 scale;
    float rotY;
    ubyte kind;     // 0 = dry, 1 = wet, 2 = mossy, 3 = submerged pebble
    ubyte meshKind; // 0 = cliff, 1 = boulder, 2 = cobble
}

private enum RockPlacement[34] SEA_ROCKS = [
    // Shoreline rocky headland along -X and +Z edge (wet near waterline, dry higher up)
    RockPlacement(Vec3(-11.4f, -0.35f, -6.5f), Vec3(3.4f, 1.35f, 3.1f), 0.3f, 1, 1),
    RockPlacement(Vec3(-12.3f,  0.75f, -6.9f), Vec3(2.9f, 1.80f, 2.5f), 1.1f, 0, 0),
    RockPlacement(Vec3(-10.7f, -0.42f, -2.4f), Vec3(3.1f, 1.15f, 3.6f), 0.8f, 1, 1),
    RockPlacement(Vec3(-12.1f,  0.65f, -1.9f), Vec3(2.6f, 1.55f, 2.8f), 2.2f, 0, 0),
    RockPlacement(Vec3(-11.1f, -0.32f,  2.6f), Vec3(3.6f, 1.45f, 3.2f), 1.6f, 1, 1),
    RockPlacement(Vec3(-12.4f,  0.88f,  3.2f), Vec3(2.8f, 1.85f, 2.7f), 0.4f, 0, 0),
    RockPlacement(Vec3(-10.2f, -0.38f,  7.4f), Vec3(3.7f, 1.25f, 3.4f), 2.7f, 1, 1),
    RockPlacement(Vec3(-12.0f,  0.95f,  8.1f), Vec3(3.1f, 2.10f, 2.8f), 1.9f, 2, 0),
    RockPlacement(Vec3(-12.6f,  0.25f, -10.2f), Vec3(2.9f, 1.60f, 2.6f), 0.9f, 0, 0),
    RockPlacement(Vec3(-9.8f,  -0.45f, -9.8f), Vec3(2.6f, 1.10f, 2.4f), 2.4f, 1, 1),
    RockPlacement(Vec3(-9.2f,  -0.48f,  4.8f), Vec3(2.2f, 0.95f, 2.0f), 1.3f, 1, 1),
    RockPlacement(Vec3(-9.5f,  -0.50f,  0.2f), Vec3(2.0f, 0.90f, 2.1f), 0.5f, 1, 1),
    // Sea stack / offshore wet reefs
    RockPlacement(Vec3(  7.8f, -0.25f, -7.2f), Vec3(2.6f, 1.35f, 2.4f), 0.5f, 1, 0),
    RockPlacement(Vec3(  8.3f,  0.65f, -7.4f), Vec3(1.8f, 1.50f, 1.6f), 1.8f, 0, 0),
    RockPlacement(Vec3(  9.2f, -0.45f, -6.5f), Vec3(1.9f, 0.95f, 1.8f), 2.9f, 1, 1),
    RockPlacement(Vec3( -4.2f, -0.52f,  6.4f), Vec3(2.2f, 1.00f, 2.0f), 1.2f, 1, 1),
    RockPlacement(Vec3( -5.1f, -0.60f,  7.4f), Vec3(1.6f, 0.85f, 1.5f), 2.6f, 1, 1),
    // Submerged boulders visible through translucent water (rendered with wet coat)
    RockPlacement(Vec3( -2.8f, -0.88f, -2.4f), Vec3(2.0f, 0.72f, 1.7f), 0.6f, 3, 2),
    RockPlacement(Vec3(  1.6f, -0.86f,  2.8f), Vec3(2.3f, 0.78f, 1.9f), 2.1f, 3, 2),
    RockPlacement(Vec3(  4.5f, -0.92f, -1.2f), Vec3(1.8f, 0.64f, 1.6f), 1.4f, 3, 2),
    RockPlacement(Vec3( -6.2f, -0.82f,  1.2f), Vec3(2.2f, 0.76f, 1.8f), 0.9f, 3, 1),
    RockPlacement(Vec3(  0.2f, -0.94f, -4.8f), Vec3(2.5f, 0.68f, 2.0f), 2.5f, 3, 2),
    RockPlacement(Vec3(  5.2f, -0.84f,  5.0f), Vec3(2.0f, 0.70f, 1.8f), 0.2f, 3, 2),
    RockPlacement(Vec3( -7.8f, -0.78f, -4.8f), Vec3(1.8f, 0.76f, 1.6f), 1.7f, 3, 1),
    RockPlacement(Vec3(  2.5f, -0.89f, -6.5f), Vec3(2.2f, 0.68f, 1.9f), 2.8f, 3, 2),
    RockPlacement(Vec3( -1.5f, -0.91f,  5.6f), Vec3(1.9f, 0.65f, 1.7f), 1.0f, 3, 2),
    RockPlacement(Vec3(  8.8f, -0.82f,  1.5f), Vec3(2.4f, 0.80f, 2.0f), 0.4f, 3, 1),
    RockPlacement(Vec3( -5.0f, -0.86f, -7.2f), Vec3(2.0f, 0.72f, 1.8f), 2.3f, 3, 2),
    RockPlacement(Vec3( -0.9f, -0.88f,  0.9f), Vec3(1.6f, 0.60f, 1.4f), 1.1f, 3, 2),
    RockPlacement(Vec3(  3.1f, -0.87f, -2.6f), Vec3(1.7f, 0.66f, 1.5f), 2.0f, 3, 2),
    RockPlacement(Vec3( -4.4f, -0.83f,  3.2f), Vec3(1.8f, 0.68f, 1.5f), 0.7f, 3, 2),
    RockPlacement(Vec3(  6.4f, -0.88f, -3.9f), Vec3(2.1f, 0.66f, 1.8f), 1.5f, 3, 2),
    RockPlacement(Vec3( -8.2f, -0.80f,  5.5f), Vec3(1.9f, 0.72f, 1.7f), 2.9f, 3, 1),
    RockPlacement(Vec3(  1.2f, -0.90f,  6.8f), Vec3(1.8f, 0.62f, 1.6f), 0.8f, 3, 2),
];

private enum RockPlacement[34] RIVER_ROCKS = [
    // Left canyon bank (-Z side, flowing along +X) — naturally staggered boulders & ledges
    RockPlacement(Vec3(-11.2f, -0.22f, -6.2f), Vec3(3.1f, 1.10f, 2.5f), 0.35f, 1, 1),
    RockPlacement(Vec3(-10.8f,  0.62f, -8.8f), Vec3(3.6f, 1.65f, 2.9f), 1.10f, 2, 0),
    RockPlacement(Vec3( -7.4f, -0.28f, -5.9f), Vec3(2.6f, 0.95f, 2.2f), 2.15f, 1, 1),
    RockPlacement(Vec3( -6.8f,  0.48f, -8.3f), Vec3(3.2f, 1.35f, 2.6f), 0.65f, 2, 1),
    RockPlacement(Vec3( -3.6f,  0.85f,-10.2f), Vec3(3.8f, 1.85f, 3.0f), 1.85f, 0, 0),
    RockPlacement(Vec3(  1.6f, -0.24f, -6.1f), Vec3(2.9f, 1.05f, 2.3f), 1.40f, 1, 1),
    RockPlacement(Vec3(  2.5f,  0.65f, -8.7f), Vec3(3.9f, 1.75f, 3.1f), 2.75f, 2, 0),
    RockPlacement(Vec3(  6.2f, -0.30f, -6.4f), Vec3(2.5f, 0.90f, 2.2f), 0.85f, 1, 1),
    RockPlacement(Vec3(  8.8f,  0.55f, -8.5f), Vec3(3.5f, 1.55f, 2.8f), 1.95f, 2, 0),
    RockPlacement(Vec3( 11.4f, -0.20f, -6.7f), Vec3(3.0f, 1.15f, 2.5f), 2.45f, 1, 1),
    // Right canyon bank (+Z side)
    RockPlacement(Vec3(-10.9f, -0.25f,  6.5f), Vec3(2.9f, 1.05f, 2.4f), 2.60f, 1, 1),
    RockPlacement(Vec3(-10.2f,  0.72f,  9.0f), Vec3(3.9f, 1.75f, 3.2f), 0.45f, 2, 0),
    RockPlacement(Vec3( -6.5f, -0.22f,  6.0f), Vec3(2.7f, 0.98f, 2.2f), 1.25f, 1, 1),
    RockPlacement(Vec3( -5.8f,  0.52f,  8.6f), Vec3(3.3f, 1.45f, 2.7f), 2.95f, 2, 1),
    RockPlacement(Vec3( -2.8f,  0.90f, 10.4f), Vec3(3.6f, 1.90f, 2.9f), 0.90f, 0, 0),
    RockPlacement(Vec3(  1.9f, -0.26f,  6.3f), Vec3(2.8f, 1.00f, 2.3f), 1.75f, 1, 1),
    RockPlacement(Vec3(  3.4f,  0.68f,  8.9f), Vec3(3.7f, 1.80f, 3.0f), 0.30f, 2, 0),
    RockPlacement(Vec3(  7.1f, -0.28f,  5.8f), Vec3(2.6f, 0.92f, 2.1f), 2.20f, 1, 1),
    RockPlacement(Vec3(  9.2f,  0.58f,  8.6f), Vec3(3.4f, 1.55f, 2.8f), 1.15f, 2, 0),
    RockPlacement(Vec3( 11.5f, -0.20f,  6.4f), Vec3(3.1f, 1.15f, 2.6f), 0.55f, 1, 1),
    // Mid-stream wet boulders breaking rapids
    RockPlacement(Vec3( -8.5f, -0.28f,  1.6f), Vec3(2.1f, 1.05f, 1.8f), 0.70f, 1, 0),
    RockPlacement(Vec3( -5.2f, -0.34f, -1.9f), Vec3(1.8f, 0.90f, 1.6f), 2.35f, 1, 1),
    RockPlacement(Vec3(  3.8f, -0.32f, -1.4f), Vec3(2.2f, 0.96f, 1.9f), 1.85f, 1, 1),
    RockPlacement(Vec3(  8.4f, -0.26f,  1.5f), Vec3(2.3f, 1.08f, 2.0f), 0.25f, 1, 0),
    // Submerged riverbed cobbles & stones (wet water coat clearly visible underwater)
    RockPlacement(Vec3( -9.4f, -0.78f, -1.5f), Vec3(2.0f, 0.62f, 1.7f), 1.10f, 3, 2),
    RockPlacement(Vec3( -6.4f, -0.82f,  2.9f), Vec3(1.7f, 0.58f, 1.5f), 2.60f, 3, 2),
    RockPlacement(Vec3( -3.4f, -0.76f,  0.8f), Vec3(2.2f, 0.66f, 1.8f), 0.45f, 3, 2),
    RockPlacement(Vec3( -2.0f, -0.80f, -2.5f), Vec3(1.9f, 0.60f, 1.6f), 1.90f, 3, 1),
    RockPlacement(Vec3(  0.6f, -0.74f,  1.9f), Vec3(2.3f, 0.68f, 1.9f), 2.30f, 3, 2),
    RockPlacement(Vec3(  1.2f, -0.82f, -0.4f), Vec3(1.6f, 0.54f, 1.4f), 0.80f, 3, 2),
    RockPlacement(Vec3(  2.9f, -0.78f,  3.6f), Vec3(2.0f, 0.64f, 1.7f), 1.45f, 3, 2),
    RockPlacement(Vec3(  5.6f, -0.80f,  0.6f), Vec3(2.4f, 0.65f, 1.9f), 2.85f, 3, 1),
    RockPlacement(Vec3(  6.8f, -0.84f, -3.2f), Vec3(1.8f, 0.56f, 1.6f), 0.35f, 3, 2),
    RockPlacement(Vec3( 10.2f, -0.76f, -0.6f), Vec3(2.1f, 0.62f, 1.8f), 1.65f, 3, 2),
];

private struct OrbitState {
    Vec3 target = Vec3(0.0f, 0.2f, 0.0f);
    float distance = 16.5f;
    float yaw = 0.85f;
    float pitch = 0.42f;

    void update(ref const InputState input, float dt, ref Camera camera) {
        if (input.keyDown(Key.left))  yaw   -= 1.6f * dt;
        if (input.keyDown(Key.right)) yaw   += 1.6f * dt;
        if (input.keyDown(Key.up))    pitch += 0.9f * dt;
        if (input.keyDown(Key.down))  pitch -= 0.9f * dt;
        if (input.keyDown(Key.w)) distance -= 9.0f * dt;
        if (input.keyDown(Key.s)) distance += 9.0f * dt;

        if (input.mouseDown(MouseButton.left) || input.mouseDown(MouseButton.right)) {
            yaw   += input.mdx() * 0.005f;
            pitch -= input.mdy() * 0.005f;
        }
        distance -= input.wheelY() * 1.2f;

        if (pitch < 0.08f) pitch = 0.08f;
        if (pitch > 1.42f) pitch = 1.42f;
        if (distance < 4.5f) distance = 4.5f;
        if (distance > 34.0f) distance = 34.0f;

        immutable cp = cos(pitch);
        immutable eye = target + Vec3(
            cos(yaw) * cp * distance,
            sin(pitch) * distance,
            sin(yaw) * cp * distance,
        );
        camera.lookAt(eye, target);
    }
}

private MaterialParams buildWaterParams(bool riverMode, bool useOpenPbr, bool transparent) {
    MaterialParams p;
    if (riverMode) {
        p.baseColor = [0.06f, 0.34f, 0.30f];
        p.geometryOpacity = transparent ? 0.72f : 1.0f;
    } else {
        p.baseColor = [0.03f, 0.22f, 0.34f];
        p.geometryOpacity = transparent ? 0.80f : 1.0f;
    }
    p.baseWeight = 1.0f;
    p.baseMetalness = 0.0f;
    p.specularWeight = 1.0f;
    p.specularIor = 1.333f;
    p.flags = MaterialFlags.normal | MaterialFlags.metallicRoughness;

    if (useOpenPbr) {
        p.baseDiffuseRoughness = 0.20f;
        p.specularRoughness = riverMode ? 0.14f : 0.09f;
        p.specularAnisotropy = riverMode ? 0.45f : 0.22f;
        // Sharp upper liquid film + subtle emerald/aqua optical absorption
        p.coatWeight = 0.92f;
        p.coatRoughness = 0.02f;
        p.coatIor = 1.333f;
        p.coatColor = riverMode ? [0.76f, 0.96f, 0.92f] : [0.70f, 0.92f, 1.0f];
        p.coatDarkening = 1.0f;
        // Grazing crest spray / foam sheen
        p.fuzzWeight = riverMode ? 0.22f : 0.16f;
        p.fuzzColor = [0.88f, 0.96f, 1.0f];
        p.fuzzRoughness = 0.65f;
    } else {
        // Legacy metallic-roughness equivalent for A/B comparison
        p.baseDiffuseRoughness = 0.0f;
        p.specularRoughness = 0.08f;
        p.specularAnisotropy = 0.0f;
        p.coatWeight = 0.0f;
        p.fuzzWeight = 0.0f;
        p.specularIor = 1.5f;
    }
    return p;
}

private MaterialParams buildDryRockParams() {
    MaterialParams p;
    p.baseColor = [0.44f, 0.40f, 0.36f];
    p.baseDiffuseRoughness = 0.85f;
    p.specularRoughness = 0.76f;
    p.specularIor = 1.52f;
    p.flags = MaterialFlags.normal;
    return p;
}

private MaterialParams buildWetRockParams(bool useOpenPbr) {
    MaterialParams p = buildDryRockParams();
    if (useOpenPbr) {
        p.baseColor = [0.30f, 0.28f, 0.26f];
        p.baseDiffuseRoughness = 0.65f;
        p.specularRoughness = 0.28f;
        p.coatWeight = 0.96f;
        p.coatRoughness = 0.045f;
        p.coatIor = 1.333f;
        p.coatColor = [0.88f, 0.93f, 0.95f];
        p.coatDarkening = 1.0f;
    }
    return p;
}

private MaterialParams buildMossRockParams(bool useOpenPbr) {
    MaterialParams p = buildDryRockParams();
    p.baseColor = [0.24f, 0.27f, 0.19f];
    if (useOpenPbr) {
        p.baseDiffuseRoughness = 0.78f;
        p.specularRoughness = 0.42f;
        p.coatWeight = 0.72f;
        p.coatRoughness = 0.08f;
        p.coatIor = 1.333f;
        p.coatDarkening = 1.0f;
        p.fuzzWeight = 0.26f;
        p.fuzzColor = [0.22f, 0.34f, 0.14f];
        p.fuzzRoughness = 0.76f;
    } else {
        p.baseDiffuseRoughness = 0.0f;
        p.specularRoughness = 0.72f;
    }
    return p;
}

private MaterialParams buildSubmergedRockParams(bool useOpenPbr) {
    MaterialParams p = buildDryRockParams();
    if (useOpenPbr) {
        p.baseColor = [0.24f, 0.25f, 0.24f];
        p.baseDiffuseRoughness = 0.55f;
        p.specularRoughness = 0.20f;
        p.coatWeight = 1.0f;
        p.coatRoughness = 0.03f;
        p.coatIor = 1.333f;
        p.coatColor = [0.72f, 0.90f, 0.88f];
        p.coatDarkening = 1.0f;
    } else {
        p.baseColor = [0.42f, 0.38f, 0.34f];
        p.baseDiffuseRoughness = 0.0f;
        p.specularRoughness = 0.78f;
    }
    return p;
}

void main() {
    auto app = App.create("OpenPBR Water Showcase — Ocean & River", W, H);

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();

    auto sphere = TexMesh.sphere(app.gpu, 32, 16);
    scope(exit) sphere.destroy();
    auto cliffRockMesh = loadGltfMesh(app.gpu, "assets/models/rock_cliff.gltf");
    scope(exit) cliffRockMesh.destroy();
    auto boulderRockMesh = loadGltfMesh(app.gpu, "assets/models/rock_boulder.gltf");
    scope(exit) boulderRockMesh.destroy();
    auto cobbleRockMesh = loadGltfMesh(app.gpu, "assets/models/rock_cobble.gltf");
    scope(exit) cobbleRockMesh.destroy();
    auto cube = TexMesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto quad = TexMesh.quad(app.gpu);
    scope(exit) quad.destroy();

    TexTanVert[] waterVerts;
    auto waterMesh = buildWaterMesh(app.gpu, waterVerts);
    scope(exit) waterMesh.destroy();

    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();

    auto whiteTex = Texture.solid(app.gpu, 255, 255, 255, 255);
    scope(exit) whiteTex.destroy();

    Texture waterAlbedoTex, waterNormalTex, waterMrTex;
    generateWaterTextures(app.gpu, waterAlbedoTex, waterNormalTex, waterMrTex);
    scope(exit) {
        waterAlbedoTex.destroy();
        waterNormalTex.destroy();
        waterMrTex.destroy();
    }

    Texture rockAlbedoTex, rockNormalTex, bedTex;
    generateRockAndBedTextures(app.gpu, rockAlbedoTex, rockNormalTex, bedTex);
    scope(exit) {
        rockAlbedoTex.destroy();
        rockNormalTex.destroy();
        bedTex.destroy();
    }

    auto layout = scene.materialLayout();

    Material makePbrMat(ref Texture albedo, MaterialParams params,
                        scope Texture* mr = null, scope Texture* nrm = null) @trusted {
        return Material.create(app.gpu, layout, sampler, albedo, params, mr, nrm, null, null);
    }

    bool riverMode = false;
    bool lowSun = true;
    bool useOpenPbr = true;
    int waveLevel = 1; // 0 = calm, 1 = moderate, 2 = stormy
    bool transparent = true;

    auto waterMat = makePbrMat(
        waterAlbedoTex,
        buildWaterParams(riverMode, useOpenPbr, transparent),
        &waterMrTex, &waterNormalTex);
    scope(exit) waterMat.destroy();

    auto dryRockMat = makePbrMat(rockAlbedoTex, buildDryRockParams(), null, &rockNormalTex);
    scope(exit) dryRockMat.destroy();

    // Wet shoreline rock: porous stone darkened by water coat (coatDarkening = 1.0)
    auto wetRockMat = makePbrMat(rockAlbedoTex, buildWetRockParams(useOpenPbr), null, &rockNormalTex);
    scope(exit) wetRockMat.destroy();

    // Damp mossy canyon / coastal rock using OpenPBR coat + subtle Charlie velvet fuzz
    auto mossRockMat = makePbrMat(rockAlbedoTex, buildMossRockParams(useOpenPbr), null, &rockNormalTex);
    scope(exit) mossRockMat.destroy();

    // Submerged wet stone: full water coat & aquatic tint visible through translucent surface
    auto submergedRockMat = makePbrMat(rockAlbedoTex, buildSubmergedRockParams(useOpenPbr), null, &rockNormalTex);
    scope(exit) submergedRockMat.destroy();

    MaterialParams bedP;
    bedP.baseColor = [0.48f, 0.42f, 0.32f];
    bedP.baseDiffuseRoughness = 0.9f;
    bedP.specularRoughness = 0.85f;
    auto bedMat = Material.create(
        app.gpu, layout, sampler, bedTex, bedP, null, null, null, null);
    scope(exit) bedMat.destroy();

    // Wooden bridge / lighthouse trim & metallic buoys
    MaterialParams goldBuoyP;
    goldBuoyP.baseColor = [0.98f, 0.78f, 0.36f];
    goldBuoyP.specularColor = [1.0f, 0.70f, 0.32f];
    goldBuoyP.baseMetalness = 1.0f;
    goldBuoyP.specularRoughness = 0.18f;
    goldBuoyP.coatWeight = 0.45f;
    goldBuoyP.coatRoughness = 0.04f;
    auto goldBuoyMat = Material.create(
        app.gpu, layout, sampler, whiteTex, goldBuoyP, null, null, null, null);
    scope(exit) goldBuoyMat.destroy();

    MaterialParams filmBuoyP;
    filmBuoyP.baseColor = [0.14f, 0.16f, 0.22f];
    filmBuoyP.baseMetalness = 0.85f;
    filmBuoyP.specularRoughness = 0.12f;
    filmBuoyP.thinFilmWeight = 0.95f;
    filmBuoyP.thinFilmThickness = 470.0f;
    filmBuoyP.thinFilmIor = 1.52f;
    auto filmBuoyMat = Material.create(
        app.gpu, layout, sampler, whiteTex, filmBuoyP, null, null, null, null);
    scope(exit) filmBuoyMat.destroy();

    MaterialParams lighthouseP;
    lighthouseP.baseColor = [0.92f, 0.91f, 0.88f];
    lighthouseP.baseDiffuseRoughness = 0.55f;
    lighthouseP.specularRoughness = 0.52f;
    auto lighthouseMat = Material.create(
        app.gpu, layout, sampler, whiteTex, lighthouseP, null, null, null, null);
    scope(exit) lighthouseMat.destroy();

    MaterialParams beaconP;
    beaconP.baseColor = [1.0f, 0.88f, 0.55f];
    beaconP.emissionColor = [1.0f, 0.76f, 0.32f];
    beaconP.emissionLuminance = 5.5f;
    auto beaconMat = Material.create(
        app.gpu, layout, sampler, whiteTex, beaconP, null, null, null, null);
    scope(exit) beaconMat.destroy();

    // Shadows (Directional + Lighthouse/Bridge Spot)
    auto shadowPipe = createShadowPipeline(app.gpu.getDevice());
    scope(exit) shadowPipe.release();
    auto lightBuf = createUniformBuffer(app.gpu.getDevice(), 64);
    scope(exit) destroyBuffer(lightBuf);
    auto lightBg = createUniformBindGroup(app.gpu.getDevice(), shadowPipe.bindGroupLayout, lightBuf, 64);
    scope(exit) releaseBindGroup(lightBg);
    auto shadowInstanceBuf = createDynamicVertexBuffer(app.gpu.getDevice(), 64 * InstanceData.sizeof);
    scope(exit) destroyBuffer(shadowInstanceBuf);

    auto dirShadow = ShadowMap.create(app.gpu, 2048);
    scope(exit) dirShadow.destroy();
    auto spotShadow = SpotShadowMap.create(app.gpu, SPOT_SHADOW_RESOLUTION);
    scope(exit) spotShadow.destroy();

    auto camera = Camera.create(0.85f, W, H);
    auto orbit = OrbitState();
    auto text = TextRenderer.create(app.gpu, W, H);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();
    bool showHud = true;

    info("OpenPBR Water Showcase — [1] Ocean [2] River [3] Sun [4] OpenPBR A/B [5] Waves [6] Opacity [F1] HUD");

    float time = 0.0f;
    while (app.running()) {
        app.pollEvents();
        immutable float dt = fps.tick();
        time += dt;
        if (app.input.keyPressed(Key.escape)) break;

        bool paramsDirty = false;
        if (app.input.keyPressed(Key.digit1)) { riverMode = false; paramsDirty = true; }
        if (app.input.keyPressed(Key.digit2)) { riverMode = true;  paramsDirty = true; }
        if (app.input.keyPressed(Key.digit3)) { lowSun = !lowSun; }
        if (app.input.keyPressed(Key.digit4)) { useOpenPbr = !useOpenPbr; paramsDirty = true; }
        if (app.input.keyPressed(Key.digit5)) { waveLevel = (waveLevel + 1) % 3; }
        if (app.input.keyPressed(Key.digit6)) { transparent = !transparent; paramsDirty = true; }
        if (app.input.keyPressed(Key.f1))     { showHud = !showHud; }
        if (app.input.keyPressed(Key.b))      { app.post.bloom = !app.post.bloom; }
        if (app.input.keyPressed(Key.f))      { app.post.fxaa = !app.post.fxaa; }
        if (app.input.keyPressed(Key.g))      { app.post.tonemapMode = 1 - app.post.tonemapMode; }
        if (app.input.keyPressed(Key.r))      { orbit = OrbitState(); }
        if (app.input.keyPressed(Key.equals) || app.input.keyPressed(Key.kpPlus))
            app.post.exposure += 0.1f;
        if (app.input.keyPressed(Key.minus) || app.input.keyPressed(Key.kpMinus)) {
            app.post.exposure -= 0.1f;
            if (app.post.exposure < 0.1f) app.post.exposure = 0.1f;
        }

        if (paramsDirty) {
            waterMat.updateParams(app.gpu, buildWaterParams(riverMode, useOpenPbr, transparent));
            wetRockMat.updateParams(app.gpu, buildWetRockParams(useOpenPbr));
            mossRockMat.updateParams(app.gpu, buildMossRockParams(useOpenPbr));
            submergedRockMat.updateParams(app.gpu, buildSubmergedRockParams(useOpenPbr));
        }

        immutable float waveScale = waveLevel == 0 ? 0.35f : (waveLevel == 1 ? 1.0f : 1.75f);
        fillWaterGridVertices(waterVerts, time, riverMode, waveScale);
        waterMesh.updateVertices(app.gpu, waterVerts);

        orbit.update(app.input, dt, camera);

        immutable Vec3 sunDir = lowSun
            ? Vec3(-0.78f, 0.24f, -0.58f).normalized()
            : Vec3(0.38f, 0.88f, 0.29f).normalized();
        immutable Vec3 sunCol = lowSun
            ? Vec3(1.0f, 0.72f, 0.44f)
            : Vec3(1.0f, 0.98f, 0.94f);
        immutable float sunIntensity = lowSun ? 3.8f : 3.2f;

        immutable spotPos = riverMode ? Vec3(-0.7f, 2.30f, -5.6f) : Vec3(-11.2f, 6.8f, -6.2f);
        immutable spotTarget = riverMode ? Vec3(0.4f, -0.2f, 1.0f) : Vec3(0.0f, 0.0f, 0.0f);
        immutable spotDir = (spotTarget - spotPos).normalized();
        immutable lightVP = directionalLightVP(sunDir, Vec3(0, 0, 0), 20.0f);
        immutable spotVP = spotLightVPFromCone(spotPos, spotDir, 45.0f, 0.2f, 28.0f);

        // Compute floating buoy transforms from wave height + surface normal (ocean mode)
        immutable float[2][3] buoyXZ = [
            [-2.2f, -1.5f],
            [ 3.4f,  1.8f],
            [ 0.5f,  4.2f],
        ];
        Mat4[3] buoyModels;
        if (!riverMode) {
            foreach (i, xz; buoyXZ) {
                immutable w = sampleGerstner(xz[0], xz[1], time, riverMode, waveScale);
                immutable pitchX = -w.normal.z * 0.55f;
                immutable rollZ  =  w.normal.x * 0.55f;
                buoyModels[i] = Mat4.translation(w.position.x, w.position.y + 0.10f, w.position.z)
                              * Mat4.rotationZ(rollZ)
                              * Mat4.rotationX(pitchX)
                              * Mat4.scaling(0.85f, 0.85f, 0.85f);
            }
        }

        // River embankment & bridge geometry transforms
        immutable Mat4 leftBankMat =
            Mat4.translation(0.0f, 0.05f, -11.4f)
            * Mat4.rotationX(0.24f)
            * Mat4.scaling(32.0f, 1.6f, 11.5f);
        immutable Mat4 rightBankMat =
            Mat4.translation(0.0f, 0.05f, 11.4f)
            * Mat4.rotationX(-0.24f)
            * Mat4.scaling(32.0f, 1.6f, 11.5f);

        // Gather shadow casters (rocks by mesh kind + buoys + bridge/lighthouse)
        const rocks = riverMode ? RIVER_ROCKS : SEA_ROCKS;
        InstanceData[48] cliffCasters;
        InstanceData[48] boulderCasters;
        InstanceData[48] cobbleCasters;
        uint cliffCount = 0;
        uint boulderCount = 0;
        uint cobbleCount = 0;
        foreach (ref rk; rocks) {
            if (rk.kind == 3) continue; // submerged pebbles don't cast overhead shadows
            immutable inst = InstanceData(
                (Mat4.translation(rk.pos.x, rk.pos.y, rk.pos.z)
                 * Mat4.rotationY(rk.rotY)
                 * Mat4.scaling(rk.scale.x, rk.scale.y, rk.scale.z)).m,
                Color4.white.toArray());
            if (rk.meshKind == 0)
                cliffCasters[cliffCount++] = inst;
            else if (rk.meshKind == 1)
                boulderCasters[boulderCount++] = inst;
            else
                cobbleCasters[cobbleCount++] = inst;
        }
        InstanceData[8] structureCasters;
        uint sCount = 0;
        if (riverMode) {
            // Sloped riverbanks, wooden footbridge, piers, stone abutments, and lantern post
            structureCasters[sCount++] = InstanceData(leftBankMat.m, Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(rightBankMat.m, Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 1.35f, 0.0f) * Mat4.scaling(1.8f, 0.28f, 16.2f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 0.10f, -4.6f) * Mat4.scaling(0.55f, 2.6f, 0.55f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 0.10f,  4.6f) * Mat4.scaling(0.55f, 2.6f, 0.55f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 0.65f, -7.8f) * Mat4.scaling(2.3f, 1.25f, 1.8f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-1.5f, 0.65f,  7.8f) * Mat4.scaling(2.3f, 1.25f, 1.8f)).m,
                Color4.white.toArray());
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-0.7f, 1.75f, -5.6f) * Mat4.scaling(0.16f, 0.65f, 0.16f)).m,
                Color4.white.toArray());
        } else {
            // Coastal headland lighthouse tower
            structureCasters[sCount++] = InstanceData(
                (Mat4.translation(-11.4f, 3.6f, -6.4f) * Mat4.scaling(1.4f, 5.2f, 1.4f)).m,
                Color4.white.toArray());
        }

        InstanceData[3] buoyCasters;
        if (!riverMode) {
            foreach (i; 0 .. 3)
                buoyCasters[i] = InstanceData(buoyModels[i].m, Color4.white.toArray());
        }

        // Directional shadow pass
        bool firstDirShadow = true;
        if (cliffCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, cliffCasters[0 .. cliffCount]);
            submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                             cliffRockMesh, shadowInstanceBuf, cliffCount, firstDirShadow);
            firstDirShadow = false;
        }
        if (boulderCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, boulderCasters[0 .. boulderCount]);
            submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                             boulderRockMesh, shadowInstanceBuf, boulderCount, firstDirShadow);
            firstDirShadow = false;
        }
        if (cobbleCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, cobbleCasters[0 .. cobbleCount]);
            submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                             cobbleRockMesh, shadowInstanceBuf, cobbleCount, firstDirShadow);
            firstDirShadow = false;
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, structureCasters[0 .. sCount]);
        submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                         cube, shadowInstanceBuf, sCount, firstDirShadow);
        if (!riverMode) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, buoyCasters[]);
            submitShadowPass(app.gpu, dirShadow, shadowPipe, lightBg, lightBuf, lightVP,
                             sphere, shadowInstanceBuf, 3, false);
        }

        // Spot shadow pass
        bool firstSpotShadow = true;
        if (cliffCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, cliffCasters[0 .. cliffCount]);
            submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                                 cliffRockMesh, shadowInstanceBuf, cliffCount, firstSpotShadow);
            firstSpotShadow = false;
        }
        if (boulderCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, boulderCasters[0 .. boulderCount]);
            submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                                 boulderRockMesh, shadowInstanceBuf, boulderCount, firstSpotShadow);
            firstSpotShadow = false;
        }
        if (cobbleCount > 0) {
            updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, cobbleCasters[0 .. cobbleCount]);
            submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                                 cobbleRockMesh, shadowInstanceBuf, cobbleCount, firstSpotShadow);
            firstSpotShadow = false;
        }
        updateBuffer(app.gpu.getQueue(), shadowInstanceBuf, structureCasters[0 .. sCount]);
        submitSpotShadowPass(app.gpu, spotShadow, shadowPipe, lightBg, lightBuf, spotVP,
                             cube, shadowInstanceBuf, sCount, firstSpotShadow);

        LightSet lights;
        lights.dirEnabled = true;
        lights.dir.direction = sunDir;
        lights.dir.viewProj = lightVP;
        lights.dir.color = sunCol;
        lights.dir.intensity = sunIntensity;
        lights.dir.castShadows = true;

        lights.spots[0] = GpuSpotLight(
            spotPos, spotDir, Vec3(1.0f, 0.88f, 0.64f), 26.0f, 36.0f,
            18.0f, 44.0f, spotVP, true);
        lights.spotCount = 1;
        lights.shadowBias = 0.0005f;

        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointMaps;
        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotMaps;
        spotMaps[0] = &spotShadow;
        scene.setLights(lights, &dirShadow, pointMaps, spotMaps);

        immutable bgCol = lowSun
            ? Color4(0.16f, 0.12f, 0.11f, 1.0f)
            : Color4(0.24f, 0.38f, 0.56f, 1.0f);
        auto frame = app.beginFrame(bgCol);
        if (!frame.valid) continue;

        scene.begin(camera);

        // 1. Opaque geometry FIRST (submerged bed, riverbanks, rocks, structures, buoys)
        scene.draw(quad, bedMat, Vec3(0.0f, -1.15f, 0.0f), Vec3(32.0f, 1.0f, 32.0f), Color4.white);

        void drawRockMesh(ubyte meshKind, ref Material mat, ref const Mat4 model) {
            if (meshKind == 0)
                scene.drawMatrix(cliffRockMesh, mat, model, Color4.white);
            else if (meshKind == 1)
                scene.drawMatrix(boulderRockMesh, mat, model, Color4.white);
            else
                scene.drawMatrix(cobbleRockMesh, mat, model, Color4.white);
        }

        foreach (ref rk; rocks) {
            auto model = Mat4.translation(rk.pos.x, rk.pos.y, rk.pos.z)
                       * Mat4.rotationY(rk.rotY)
                       * Mat4.scaling(rk.scale.x, rk.scale.y, rk.scale.z);
            if (rk.kind == 0)
                drawRockMesh(rk.meshKind, dryRockMat, model);
            else if (rk.kind == 1)
                drawRockMesh(rk.meshKind, wetRockMat, model);
            else if (rk.kind == 2)
                drawRockMesh(rk.meshKind, mossRockMat, model);
            else
                drawRockMesh(rk.meshKind, submergedRockMat, model);
        }

        if (riverMode) {
            scene.drawMatrix(cube, dryRockMat, leftBankMat, Color4(0.62f, 0.56f, 0.48f, 1.0f));
            scene.drawMatrix(cube, dryRockMat, rightBankMat, Color4(0.62f, 0.56f, 0.48f, 1.0f));
            scene.draw(cube, dryRockMat, Vec3(-1.5f, 1.35f,  0.0f), Vec3(1.8f, 0.28f, 16.2f), Color4(0.55f, 0.36f, 0.22f, 1.0f));
            scene.draw(cube, wetRockMat, Vec3(-1.5f, 0.10f, -4.6f), Vec3(0.55f, 2.6f, 0.55f), Color4(0.45f, 0.30f, 0.20f, 1.0f));
            scene.draw(cube, wetRockMat, Vec3(-1.5f, 0.10f,  4.6f), Vec3(0.55f, 2.6f, 0.55f), Color4(0.45f, 0.30f, 0.20f, 1.0f));
            scene.draw(cube, wetRockMat, Vec3(-1.5f, 0.65f, -7.8f), Vec3(2.3f, 1.25f, 1.8f), Color4(0.70f, 0.68f, 0.65f, 1.0f));
            scene.draw(cube, wetRockMat, Vec3(-1.5f, 0.65f,  7.8f), Vec3(2.3f, 1.25f, 1.8f), Color4(0.70f, 0.68f, 0.65f, 1.0f));
            scene.draw(cube, dryRockMat, Vec3(-0.7f, 1.75f, -5.6f), Vec3(0.16f, 0.65f, 0.16f), Color4(0.40f, 0.26f, 0.16f, 1.0f));
            scene.draw(sphere, beaconMat, Vec3(-0.7f, 2.10f, -5.6f), Vec3(0.24f, 0.24f, 0.24f), Color4.white);
        } else {
            scene.draw(cube, lighthouseMat, Vec3(-11.4f, 3.6f, -6.4f), Vec3(1.4f, 5.2f, 1.4f), Color4.white);
            scene.draw(sphere, beaconMat, Vec3(-11.4f, 6.5f, -6.4f), Vec3(0.75f, 0.75f, 0.75f), Color4.white);
            scene.drawMatrix(sphere, goldBuoyMat, buoyModels[0], Color4.white);
            scene.drawMatrix(sphere, filmBuoyMat, buoyModels[1], Color4.white);
            scene.drawMatrix(sphere, goldBuoyMat, buoyModels[2], Color4.white);
        }

        // 2. Animated Gerstner water surface LAST so Fresnel alpha blends over submerged scene
        scene.draw(waterMesh, waterMat, Vec3(0.0f, 0.0f, 0.0f), Vec3(1.0f, 1.0f, 1.0f), Color4.white);

        scene.end(frame);
        app.resolvePost(frame);

        text.beginFrame();
        if (showHud) {
            immutable waveName = waveLevel == 0 ? "Calm" : (waveLevel == 1 ? "Moderate" : "Stormy");
            immutable sceneName = riverMode ? "Mountain River (Stream)" : "Open Ocean (Beaufort 5)";
            immutable sunName = lowSun ? "Golden Hour" : "High Noon";
            immutable shadingName = useOpenPbr
                ? "Shading: OpenPBR v1.1 (Coat + Aniso + Fuzz + IOR 1.333)"
                : "Shading: Legacy PBR Baseline (No Coat/Fuzz, IOR 1.5)";
            immutable waterAlphaName = transparent ? "Fresnel Alpha (Refractive)" : "Opaque (1.0)";
            immutable tmName = app.post.tonemapMode == 0 ? "ACES" : "Reinhard";

            text.drawText(frame, app.arena.fmt("OPENPBR WATER SHOWCASE  |  %s", fps.text()), 16, 14, 2);
            text.drawText(frame, app.arena.fmt("Scene: %s  |  Sun: %s", sceneName, sunName), 16, 34, 2);
            text.drawText(frame, shadingName, 16, 54, 2);
            text.drawText(frame, app.arena.fmt("Waves: %s  |  Surface: %s", waveName, waterAlphaName), 16, 74, 2);
            text.drawText(frame, app.arena.fmt("Post: Bloom=%s  FXAA=%s  TM=%s  Exp=%.2f",
                          app.post.bloom ? "ON" : "OFF",
                          app.post.fxaa ? "ON" : "OFF",
                          tmName, app.post.exposure), 16, 94, 2);

            text.drawText(frame, "[CONTROLS]", 16, 124, 2);
            text.drawText(frame, "[1] Ocean Swell            [2] Mountain River", 16, 144, 2);
            text.drawText(frame, "[3] Toggle Sun Angle       [4] OpenPBR vs Legacy", 16, 164, 2);
            text.drawText(frame, "[5] Wave State (C/M/S)     [6] Water Alpha/Opaque", 16, 184, 2);
            text.drawText(frame, "[B] Bloom    [F] FXAA      [G] Tonemap   [+/-] Exposure", 16, 204, 2);
            text.drawText(frame, "[Drag/Arrows] Orbit        [W/S/Wheel] Zoom  [R] Reset", 16, 224, 2);
            text.drawText(frame, "[F1] Hide HUD              [ESC] Quit", 16, 244, 2);
        } else {
            text.drawText(frame, "[F1] Show Controls HUD", 16, 14, 2);
        }

        app.endFrame(frame);
    }

    app.destroy();
}
