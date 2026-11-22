/// OpenPBR water showcase: an ocean cove and a mountain river.
///
/// Game code only. Water, caustics, wet marks, sky, shadows and buoyancy come
/// from the engine (`engine.water`, `Scene3DTextured`, `engine.physics`);
/// this file holds the content: procedural sand / bank / timber / masonry
/// textures, the river-bank mesh, rock placements, buoys, bridge and
/// lighthouse, key bindings, HUD and the `--bench` / `--capture` flags.
/// See docs/water-guide.md.
module demo.water;

import std.math : cos, fabs, floor, sin, sqrt, tan, PI, PI_2;

import bindings.wgpu : WGPU_TRUE, WGPUPresentMode, wgpuDevicePoll;
import engine.app;
import engine.assets.bmp : loadBmpTexture;
import engine.assets.gltf : loadGltfMesh;
import engine.core.log;
import engine.gpu.context : GpuContext;
import engine.gpu.shadow;
import engine.gpu.text;
import engine.graphics.material : Material, MaterialFlags, MaterialParams;
import engine.graphics.material_presets : dryStoneParams, mossSurfaceParams,
    submergedSurfaceParams, wetSurfaceParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, Texture, TextureFilter, TextureWrap;
import engine.graphics.types : Color4, TexTanVert, TexVert;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.platform.input : InputState, Key, MouseButton;
import engine.scene.camera : Camera;
import engine.scene.controllers : OrbitCamera;
import engine.scene.light : GpuSpotLight, LightSet;
import engine.scene.scene3d_textured : Scene3DTextured;
import bindings.box3d : b3BodyId;
import engine.physics : BodyDesc, createSphereBody, getPosition, getRotation, PhysicsWorld;
import engine.water : applyBuoyancy, MAX_WATER_OBSTACLES, sphereProbes, waterSurfaceHeight,
    WaterSurfacePoint, WaterBody, WaterFeature, WaterObstacle, WaterRenderer;

@safe:

private enum int W = 1280;
private enum int H = 720;
private enum float WATER_HALF = 14.0f;

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


private void buildHeightNormalMap(const(float)[] height, uint sz, float strength, ubyte[] normalOut) pure nothrow @nogc {
    foreach (y; 0 .. sz) {
        immutable uint ym = (y + sz - 1) % sz;
        immutable uint yp = (y + 1) % sz;
        foreach (x; 0 .. sz) {
            immutable uint xm = (x + sz - 1) % sz;
            immutable uint xp = (x + 1) % sz;
            immutable float dx = (height[y * sz + xp] - height[y * sz + xm]) * strength;
            immutable float dy = (height[yp * sz + x] - height[ym * sz + x]) * strength;
            immutable Vec3 n = Vec3(-dx, -dy, 1.0f).normalized();
            immutable idx = (y * sz + x) * 4;
            normalOut[idx + 0] = clampByte((n.x * 0.5f + 0.5f) * 255.0f);
            normalOut[idx + 1] = clampByte((n.y * 0.5f + 0.5f) * 255.0f);
            normalOut[idx + 2] = clampByte((n.z * 0.5f + 0.5f) * 255.0f);
            normalOut[idx + 3] = 255;
        }
    }
}

private void generateEnvTextures(ref GpuContext gpu,
                                 out Texture bankAlbedoTex, out Texture bankNormalTex,
                                 out Texture woodAlbedoTex, out Texture woodNormalTex,
                                 out Texture masonryAlbedoTex, out Texture masonryNormalTex) {
    enum uint SZ = 512;
    auto bankA    = new ubyte[SZ * SZ * 4];
    auto bankN    = new ubyte[SZ * SZ * 4];
    auto bankH    = new float[SZ * SZ];
    auto woodA    = new ubyte[SZ * SZ * 4];
    auto woodN    = new ubyte[SZ * SZ * 4];
    auto woodH    = new float[SZ * SZ];
    auto masonryA = new ubyte[SZ * SZ * 4];
    auto masonryN = new ubyte[SZ * SZ * 4];
    auto masonryH = new float[SZ * SZ];

    foreach (y; 0 .. SZ) {
        immutable float v = cast(float) y / cast(float) SZ;
        foreach (x; 0 .. SZ) {
            immutable float u = cast(float) x / cast(float) SZ;
            immutable idx = (y * SZ + x) * 4;

            // 2. Damp mossy forest earth & dark slate gravel for riverbanks ([0.03..0.10])
            immutable soil = fbmPeriodic(u + 0.11f, v + 0.37f, 12, 4);
            immutable gravel = fbmPeriodic(u + 0.73f, v + 0.29f, 32, 3);
            immutable mossPatch = soil > 0.54f ? (soil - 0.54f) * 2.1f : 0.0f;
            immutable bankElev = soil * 0.55f + gravel * 0.45f;
            bankH[y * SZ + x] = bankElev;
            immutable bankDark = 0.036f + bankElev * 0.058f;
            immutable rSoil = bankDark * 1.08f;
            immutable gSoil = bankDark * 0.95f;
            immutable bSoil = bankDark * 0.78f;
            immutable mp = mossPatch > 1.0f ? 1.0f : mossPatch;
            bankA[idx + 0] = clampByte((rSoil * (1.0f - mp) + 0.036f * mp) * 255.0f);
            bankA[idx + 1] = clampByte((gSoil * (1.0f - mp) + 0.068f * mp) * 255.0f);
            bankA[idx + 2] = clampByte((bSoil * (1.0f - mp) + 0.022f * mp) * 255.0f);
            bankA[idx + 3] = 255;

            // 3. Weathered timber bridge planks along V (linear [0.05..0.15])
            immutable int plankIdx = cast(int)(u * 8.0f);
            immutable float uInPlank = u * 8.0f - cast(float) plankIdx;
            immutable bool plankSeam = (uInPlank < 0.035f || uInPlank > 0.965f);
            immutable float grain = sin((u * 48.0f + fbmPeriodic(u + 0.05f * plankIdx, v, 8, 3) * 3.8f) * PI_2) * 0.5f + 0.5f;
            immutable float plankTone = 0.85f + hash2D(plankIdx, 19) * 0.30f;
            immutable float woodVal = plankSeam ? 0.12f : (0.45f + grain * 0.55f);
            woodH[y * SZ + x] = woodVal;
            immutable float woodLin = (0.052f + woodVal * 0.082f) * plankTone;
            woodA[idx + 0] = clampByte(woodLin * 1.24f * 255.0f);
            woodA[idx + 1] = clampByte(woodLin * 0.84f * 255.0f);
            woodA[idx + 2] = clampByte(woodLin * 0.52f * 255.0f);
            woodA[idx + 3] = 255;

            // 4. Coursed granite ashlar blocks for bridge abutments & lighthouse trim ([0.05..0.14])
            immutable int rowIdx = cast(int)(v * 6.0f);
            immutable float vInRow = v * 6.0f - cast(float) rowIdx;
            immutable float staggeredU = u + ((rowIdx & 1) != 0 ? 0.5f / 4.0f : 0.0f);
            immutable float uBlockPos = staggeredU * 4.0f;
            import std.math : floor;
            immutable int colIdx = cast(int) floor(uBlockPos);
            immutable float uInBlock = uBlockPos - floor(uBlockPos);
            immutable bool mortar = (vInRow < 0.06f || vInRow > 0.94f || uInBlock < 0.045f || uInBlock > 0.955f);
            immutable float blockSeed = hash2D(colIdx, rowIdx);
            immutable float stoneGrain = fbmPeriodic(u + blockSeed * 0.3f, v, 24, 3);
            immutable float mH = mortar ? 0.15f : (0.55f + stoneGrain * 0.45f);
            masonryH[y * SZ + x] = mH;
            immutable float mLin = mortar
                ? 0.045f + stoneGrain * 0.020f
                : (0.072f + stoneGrain * 0.055f) * (0.85f + blockSeed * 0.30f);
            masonryA[idx + 0] = clampByte(mLin * 1.03f * 255.0f);
            masonryA[idx + 1] = clampByte(mLin * 0.99f * 255.0f);
            masonryA[idx + 2] = clampByte(mLin * 0.94f * 255.0f);
            masonryA[idx + 3] = 255;
        }
    }

    buildHeightNormalMap(bankH, SZ, 3.4f, bankN);
    buildHeightNormalMap(woodH, SZ, 3.2f, woodN);
    buildHeightNormalMap(masonryH, SZ, 3.6f, masonryN);

    bankAlbedoTex    = Texture.fromPixels(gpu, bankA, SZ, SZ);
    bankNormalTex    = Texture.fromPixels(gpu, bankN, SZ, SZ);
    woodAlbedoTex    = Texture.fromPixels(gpu, woodA, SZ, SZ);
    woodNormalTex    = Texture.fromPixels(gpu, woodN, SZ, SZ);
    masonryAlbedoTex = Texture.fromPixels(gpu, masonryA, SZ, SZ);
    masonryNormalTex = Texture.fromPixels(gpu, masonryN, SZ, SZ);
}

/// Seabed sand: dark sand with scattered pebbles, silt variation and soft
/// ripples (tiles every `BED_TILE_M` meters).
private void generateSandTextures(ref GpuContext gpu, out Texture albedoTex, out Texture normalTex) {
    enum uint SZ = 512;
    auto a = new ubyte[SZ * SZ * 4];
    auto n = new ubyte[SZ * SZ * 4];
    auto h = new float[SZ * SZ];
    foreach (y; 0 .. SZ) {
        immutable float v = cast(float) y / cast(float) SZ;
        foreach (x; 0 .. SZ) {
            immutable float u = cast(float) x / cast(float) SZ;
            immutable coarse = fbmPeriodic(u + 0.21f, v + 0.63f, 4, 4);
            immutable gravel = fbmPeriodic(u + 0.47f, v + 0.12f, 24, 3);
            immutable pebbleN = fbmPeriodic(u + 0.83f, v + 0.41f, 36, 2);
            immutable silt = fbmPeriodic(u + 0.05f, v + 0.77f, 6, 3);
            immutable ripple = sin((u * 3.0f + v * 1.0f + coarse * 0.55f) * PI_2 * 2.0f) * 0.5f + 0.5f;
            immutable pebble = pebbleN < 0.54f ? 0.0f : (pebbleN > 0.72f ? 1.0f : (pebbleN - 0.54f) / 0.18f);
            h[y * SZ + x] = coarse * 0.55f + gravel * 0.30f + ripple * 0.15f + pebble * 0.25f;
            immutable float tone = 0.78f + 0.42f * silt;
            immutable float pm = pebble * 0.78f;
            immutable idx = (y * SZ + x) * 4;
            a[idx + 0] = clampByte(((0.18f * (1 - pm) + 0.09f * pm) * tone) * 255.0f);
            a[idx + 1] = clampByte(((0.16f * (1 - pm) + 0.09f * pm) * tone) * 255.0f);
            a[idx + 2] = clampByte(((0.12f * (1 - pm) + 0.085f * pm) * tone) * 255.0f);
            a[idx + 3] = 255;
        }
    }
    buildHeightNormalMap(h, SZ, 2.6f, n);
    albedoTex = Texture.fromPixels(gpu, a, SZ, SZ);
    normalTex = Texture.fromPixels(gpu, n, SZ, SZ);
}

private enum float BED_Y = -1.15f;
private enum float BED_TILE_M = 3.5f;

/// Flat seabed quad of half size `half` at `BED_Y`, UVs tiling every `BED_TILE_M`.
private TexMesh buildBedMesh(ref GpuContext gpu, float half) {
    immutable float t = 2.0f * half / BED_TILE_M;
    TexVert[4] verts = [
        TexVert([-half, BED_Y, -half], [0, 1, 0], [0.0f, 0.0f]),
        TexVert([ half, BED_Y, -half], [0, 1, 0], [t, 0.0f]),
        TexVert([ half, BED_Y,  half], [0, 1, 0], [t, t]),
        TexVert([-half, BED_Y,  half], [0, 1, 0], [0.0f, t]),
    ];
    ushort[6] indices = [0, 2, 1, 0, 3, 2];
    return TexMesh.fromData(gpu, verts[].dup, indices[].dup);
}

/// Game content: bridge piers (river) and emergent boulders as water obstacles.
private uint gatherObstacles(bool riverMode, scope const(RockPlacement)[] rocks,
                             ref WaterObstacle[MAX_WATER_OBSTACLES] obs) nothrow @nogc {
    uint n = 0;
    if (riverMode) {
        // Wooden bridge piers breaking stream flow & forming downstream wakes.
        obs[n++] = WaterObstacle(-1.5f, -4.6f, 0.42f, 1.0f);
        obs[n++] = WaterObstacle(-1.5f,  4.6f, 0.42f, 1.0f);
    }
    foreach (ref rk; rocks) {
        if (rk.kind != 1 || n >= MAX_WATER_OBSTACLES) continue;
        // Approximate emergent boulder waterline radius from mesh scale.
        immutable r = 0.34f * (rk.scale.x + rk.scale.z) * 0.5f;
        obs[n++] = WaterObstacle(rk.pos.x, rk.pos.z, r, 1.0f);
    }
    return n;
}

/// Sculpted sloping riverbank terrain strip (z in [0..1], scaled/mirrored per side).
private TexMesh buildRiverBankMesh(ref GpuContext gpu, float zSign) {
    enum uint NX = 28;
    enum uint NZ = 10;
    enum uint SX = NX + 1;
    enum uint SZ = NZ + 1;
    auto verts = new TexTanVert[SX * SZ];

    float evalHeight(float x, float tZ) {
        // Rises organically from -0.85 beneath shoreline boulders to +2.25 up the gorge bank.
        immutable smooth = tZ * tZ * (3.0f - 2.0f * tZ);
        immutable baseH = -0.85f + smooth * 3.10f;
        immutable n1 = valueNoise(x * 0.25f + zSign * 7.3f, tZ * 2.5f + zSign * 3.1f) - 0.5f;
        immutable n2 = valueNoise(x * 0.65f + 12.1f, tZ * 5.0f + 4.7f) - 0.5f;
        return baseH + (n1 * 0.72f + n2 * 0.26f) * (0.25f + 0.75f * smooth);
    }

    foreach (iz; 0 .. SZ) {
        immutable float tZ = cast(float) iz / cast(float) NZ;
        immutable float z = zSign * (4.6f + tZ * 11.4f);
        foreach (ix; 0 .. SX) {
            immutable float tX = cast(float) ix / cast(float) NX;
            immutable float x = -16.0f + tX * 32.0f;
            immutable float y = evalHeight(x, tZ);
            immutable float eps = 0.25f;
            immutable float hdx = evalHeight(x + eps, tZ) - evalHeight(x - eps, tZ);
            immutable float hdz = evalHeight(x, tZ + 0.025f) - evalHeight(x, tZ - 0.025f);
            immutable float dzStep = zSign * (0.05f * 11.4f);
            Vec3 n = Vec3(-hdx / (2.0f * eps), 1.0f, -hdz / dzStep).normalized();
            Vec3 t = Vec3(1.0f, hdx / (2.0f * eps), 0.0f).normalized();
            t = (t - n * n.dot(t)).normalized();
            verts[iz * SX + ix] = TexTanVert(
                [x, y, z],
                [n.x, n.y, n.z],
                [tX * 7.0f, tZ * 3.0f],
                [t.x, t.y, t.z, -1.0f]
            );
        }
    }

    auto indices = new ushort[NX * NZ * 6];
    uint ii = 0;
    foreach (iz; 0 .. NZ) {
        foreach (ix; 0 .. NX) {
            immutable ushort a = cast(ushort)(iz * SX + ix);
            immutable ushort b = cast(ushort)(a + 1);
            immutable ushort c = cast(ushort)(a + SX);
            immutable ushort d = cast(ushort)(c + 1);
            if (zSign > 0.0f) {
                indices[ii++] = a; indices[ii++] = d; indices[ii++] = b;
                indices[ii++] = a; indices[ii++] = c; indices[ii++] = d;
            } else {
                indices[ii++] = a; indices[ii++] = b; indices[ii++] = d;
                indices[ii++] = a; indices[ii++] = d; indices[ii++] = c;
            }
        }
    }
    return TexMesh.fromData(gpu, verts, indices);
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
    RockPlacement(Vec3( -0.9f, -0.98f,  0.9f), Vec3(1.6f, 0.60f, 1.4f), 1.1f, 3, 2),
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

/// Showcase orbit: drag to rotate, wheel / W,S to zoom, stays above the water.
private OrbitCamera makeOrbit() {
    auto o = OrbitCamera.create(Vec3(0.0f, 0.2f, 0.0f), 16.5f, 0.85f, 0.42f);
    o.minDistance = 4.5f;
    o.maxDistance = 34.0f;
    o.minPitch = 0.08f;
    o.maxPitch = 1.42f;
    o.rotateSpeed = 1.6f;
    o.zoomSpeed = 9.0f;
    o.mouseSensitivity = 0.005f;
    o.wheelZoomSpeed = 1.2f;
    o.dragToRotate = true;
    return o;
}

private struct RockTextureSet {
    Texture albedo, normal, mr, ao;
    Texture mossAlbedo, mossMr;
    bool hasMoss;

    @disable this(this);

    static RockTextureSet load(ref GpuContext gpu, string prefix, bool loadMoss) {
        RockTextureSet s;
        s.albedo = loadBmpTexture(gpu, prefix ~ "_albedo.bmp");
        s.normal = loadBmpTexture(gpu, prefix ~ "_normal.bmp");
        s.mr     = loadBmpTexture(gpu, prefix ~ "_mr.bmp");
        s.ao     = loadBmpTexture(gpu, prefix ~ "_ao.bmp");
        s.hasMoss = loadMoss;
        if (loadMoss) {
            s.mossAlbedo = loadBmpTexture(gpu, prefix ~ "_moss_albedo.bmp");
            s.mossMr     = loadBmpTexture(gpu, prefix ~ "_moss_mr.bmp");
        }
        return s;
    }

    void destroy() nothrow @nogc {
        albedo.destroy();
        normal.destroy();
        mr.destroy();
        ao.destroy();
        if (hasMoss) {
            mossAlbedo.destroy();
            mossMr.destroy();
        }
    }
}

private struct RockMaterialGroup {
    Material dry, wet, moss, submerged;

    @disable this(this);

    void destroy() nothrow @nogc {
        dry.destroy();
        wet.destroy();
        moss.destroy();
        submerged.destroy();
    }
}

private void writeCaptureBmp(string path, const(ubyte)[] rgba, uint w, uint h) @trusted {
    import std.stdio : File;
    immutable uint rowBytes = (w * 3 + 3) & ~3u;
    immutable uint imgBytes = rowBytes * h;
    immutable uint fileSize = 54 + imgBytes;
    ubyte[54] hdr = 0;
    hdr[0] = 'B'; hdr[1] = 'M';
    hdr[2] = cast(ubyte)(fileSize & 0xFF);
    hdr[3] = cast(ubyte)((fileSize >> 8) & 0xFF);
    hdr[4] = cast(ubyte)((fileSize >> 16) & 0xFF);
    hdr[5] = cast(ubyte)((fileSize >> 24) & 0xFF);
    hdr[10] = 54;
    hdr[14] = 40;
    hdr[18] = cast(ubyte)(w & 0xFF);
    hdr[19] = cast(ubyte)((w >> 8) & 0xFF);
    hdr[20] = cast(ubyte)((w >> 16) & 0xFF);
    hdr[21] = cast(ubyte)((w >> 24) & 0xFF);
    hdr[22] = cast(ubyte)(h & 0xFF);
    hdr[23] = cast(ubyte)((h >> 8) & 0xFF);
    hdr[24] = cast(ubyte)((h >> 16) & 0xFF);
    hdr[25] = cast(ubyte)((h >> 24) & 0xFF);
    hdr[26] = 1;
    hdr[28] = 24;
    hdr[34] = cast(ubyte)(imgBytes & 0xFF);
    hdr[35] = cast(ubyte)((imgBytes >> 8) & 0xFF);
    hdr[36] = cast(ubyte)((imgBytes >> 16) & 0xFF);
    hdr[37] = cast(ubyte)((imgBytes >> 24) & 0xFF);

    auto f = File(path, "wb");
    f.rawWrite(hdr[]);
    auto row = new ubyte[rowBytes];
    foreach_reverse (y; 0 .. h) {
        row[] = 0;
        const size_t srcBase = cast(size_t) y * w * 4;
        foreach (x; 0 .. w) {
            const size_t s = srcBase + cast(size_t) x * 4;
            const size_t d = cast(size_t) x * 3;
            row[d + 0] = rgba[s + 2];
            row[d + 1] = rgba[s + 1];
            row[d + 2] = rgba[s + 0];
        }
        f.rawWrite(row);
    }
}

void main(string[] args) {
    import core.memory : GC;
    import core.time : MonoTime;
    import std.algorithm : sort, startsWith;
    import std.conv : to;
    import std.stdio : writefln;

    uint maxFrames = 0;
    uint benchFrames = 0;
    uint renderStage = 3;
    uint winW = W;
    uint winH = H;
    bool initRiver = false;
    bool initLowSun = true;
    bool initHud = true;
    bool hudHint = true;   // "[F1] Show Controls HUD" while the HUD is hidden
    bool noWater = false;
    bool initImmediate = false;
    bool benchSync = false;
    string capturePath;
    foreach (a; args[1 .. $]) {
        if (a.startsWith("--frames=")) {
            maxFrames = a[9 .. $].to!uint;
        } else if (a.startsWith("--bench=")) {
            benchFrames = a[8 .. $].to!uint;
        } else if (a.startsWith("--stage=")) {
            renderStage = a[8 .. $].to!uint;
        } else if (a == "--river") {
            initRiver = true;
        } else if (a == "--noon") {
            initLowSun = false;
        } else if (a == "--no-hud") {
            initHud = false;
            hudHint = false;
        } else if (a == "--no-water") {
            noWater = true;
        } else if (a == "--immediate") {
            initImmediate = true;
        } else if (a == "--bench-sync") {
            benchSync = true;
        } else if (a == "--1080p") {
            winW = 1920;
            winH = 1080;
        } else if (a.startsWith("--capture=")) {
            capturePath = a[10 .. $];
        }
    }
    enum uint WARMUP_FRAMES = 120;
    if (benchFrames > 0) {
        initImmediate = true;
        initHud = false;
        benchSync = true;
        maxFrames = WARMUP_FRAMES + benchFrames;
    } else if (capturePath.length > 0) {
        initImmediate = true;
        if (maxFrames == 0) maxFrames = 3;
    }
    auto app = App.create(
        "OpenPBR Water Showcase — Ocean & River",
        winW,
        winH,
        initImmediate ? WGPUPresentMode.immediate : WGPUPresentMode.fifo
    );

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();
    // Engine sky (sun from the directional light); the water reflects the same sky.
    scene.setSkyEnabled(true);

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
    // Seabed: plain PBR meshes; the engine adds caustics below the water level.
    auto oceanBedMesh = buildBedMesh(app.gpu, WATER_HALF * 10.5f);
    scope(exit) oceanBedMesh.destroy();
    auto riverBedMesh = buildBedMesh(app.gpu, WATER_HALF);
    scope(exit) riverBedMesh.destroy();
    auto leftBankMesh = buildRiverBankMesh(app.gpu, -1.0f);
    scope(exit) leftBankMesh.destroy();
    auto rightBankMesh = buildRiverBankMesh(app.gpu, 1.0f);
    scope(exit) rightBankMesh.destroy();
    // Engine water: one body, drawn after the sky by the transparent hook.
    auto water = WaterRenderer.create(app.gpu, scene);
    scope(exit) water.destroy();
    water.attach(scene, app.renderer);
    int waterBody = -1;
    if (!noWater) {
        immutable initialBody = initRiver ? WaterBody.river() : WaterBody.ocean();
        waterBody = water.addBody(initialBody);
    }

    // Ocean buoys: dynamic spheres kept afloat by engine buoyancy.
    enum float BUOY_RADIUS = 0.425f;   // unit sphere mesh (r = 0.5) scaled by 0.85
    immutable float[2][3] buoyXZ = [[-2.2f, -1.5f], [3.4f, 1.8f], [0.5f, 4.2f]];
    auto physics = PhysicsWorld.createDefault();
    b3BodyId[3] buoyBodies;
    {
        immutable spawnWater = WaterBody.ocean();
        foreach (i, xz; buoyXZ) {
            BodyDesc bd;
            bd.position = Vec3(xz[0], waterSurfaceHeight(spawnWater, xz[0], xz[1], 0.0f) + 0.1f, xz[1]);
            bd.density = 380.0f;   // floats about 40% submerged
            bd.enableSleep = false;
            buoyBodies[i] = createSphereBody(physics, bd, BUOY_RADIUS);
        }
    }
    immutable buoyProbes = sphereProbes(BUOY_RADIUS);


    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();

    auto whiteTex = Texture.solid(app.gpu, 255, 255, 255, 255);
    scope(exit) whiteTex.destroy();

    Texture bankAlbedoTex, bankNormalTex;
    Texture woodAlbedoTex, woodNormalTex, masonryAlbedoTex, masonryNormalTex;
    generateEnvTextures(app.gpu,
                        bankAlbedoTex, bankNormalTex,
                        woodAlbedoTex, woodNormalTex,
                        masonryAlbedoTex, masonryNormalTex);
    scope(exit) {
        bankAlbedoTex.destroy();
        bankNormalTex.destroy();
        woodAlbedoTex.destroy();
        woodNormalTex.destroy();
        masonryAlbedoTex.destroy();
        masonryNormalTex.destroy();
    }

    RockTextureSet[3] rockTexSets = [
        RockTextureSet.load(app.gpu, "assets/models/rock_cliff", true),
        RockTextureSet.load(app.gpu, "assets/models/rock_boulder", true),
        RockTextureSet.load(app.gpu, "assets/models/rock_cobble", false),
    ];
    scope(exit) {
        foreach (ref ts; rockTexSets) ts.destroy();
    }

    auto layout = scene.materialLayout();

    Material makePbrMat(ref Texture albedo, MaterialParams params,
                        scope Texture* mr = null, scope Texture* nrm = null,
                        scope Texture* ao = null) @trusted {
        return Material.create(app.gpu, layout, sampler, albedo, params, mr, nrm, ao, null);
    }

    bool riverMode = initRiver;
    bool lowSun = initLowSun;
    bool useOpenPbr = true;
    int waveLevel = 1; // 0 = calm, 1 = moderate, 2 = stormy
    bool transparent = true;
    bool ssrEnabled = (renderStage >= 3);

    RockMaterialGroup[3] rockMats;
    foreach (i; 0 .. 3) {
        rockMats[i].dry = makePbrMat(
            rockTexSets[i].albedo, dryStoneParams(),
            &rockTexSets[i].mr, &rockTexSets[i].normal, &rockTexSets[i].ao);
        rockMats[i].wet = makePbrMat(
            rockTexSets[i].albedo, wetSurfaceParams(dryStoneParams(), useOpenPbr),
            &rockTexSets[i].mr, &rockTexSets[i].normal, &rockTexSets[i].ao);
        if (rockTexSets[i].hasMoss) {
            rockMats[i].moss = makePbrMat(
                rockTexSets[i].mossAlbedo, mossSurfaceParams(dryStoneParams(), useOpenPbr),
                &rockTexSets[i].mossMr, &rockTexSets[i].normal, &rockTexSets[i].ao);
        } else {
            rockMats[i].moss = makePbrMat(
                rockTexSets[i].albedo, mossSurfaceParams(dryStoneParams(), useOpenPbr),
                &rockTexSets[i].mr, &rockTexSets[i].normal, &rockTexSets[i].ao);
        }
        rockMats[i].submerged = makePbrMat(
            rockTexSets[i].albedo, submergedSurfaceParams(dryStoneParams(), useOpenPbr),
            &rockTexSets[i].mr, &rockTexSets[i].normal, &rockTexSets[i].ao);
    }
    scope(exit) {
        foreach (ref mg; rockMats) mg.destroy();
    }

    MaterialParams bankP;
    bankP.baseColor = [1.0f, 1.0f, 1.0f];
    bankP.baseDiffuseRoughness = 0.92f;
    bankP.specularRoughness = 0.86f;
    bankP.flags = MaterialFlags.normal;
    auto bankMat = makePbrMat(bankAlbedoTex, bankP, null, &bankNormalTex);
    scope(exit) bankMat.destroy();

    Texture sandAlbedoTex, sandNormalTex;
    generateSandTextures(app.gpu, sandAlbedoTex, sandNormalTex);
    scope(exit) { sandAlbedoTex.destroy(); sandNormalTex.destroy(); }
    MaterialParams sandP;
    sandP.baseColor = [1.0f, 1.0f, 1.0f];
    sandP.baseDiffuseRoughness = 0.88f;
    sandP.specularWeight = 0.6f;
    sandP.specularRoughness = 0.78f;
    sandP.specularIor = 1.48f;
    sandP.flags = MaterialFlags.normal;
    auto sandMat = makePbrMat(sandAlbedoTex, sandP, null, &sandNormalTex);
    scope(exit) sandMat.destroy();

    MaterialParams woodP;
    woodP.baseColor = [1.0f, 1.0f, 1.0f];
    woodP.baseDiffuseRoughness = 0.72f;
    woodP.specularRoughness = 0.62f;
    woodP.coatWeight = 0.20f;
    woodP.coatRoughness = 0.16f;
    woodP.coatIor = 1.333f;
    woodP.coatDarkening = 0.50f;
    woodP.flags = MaterialFlags.normal;
    auto woodMat = makePbrMat(woodAlbedoTex, woodP, null, &woodNormalTex);
    scope(exit) woodMat.destroy();

    MaterialParams masonryP;
    masonryP.baseColor = [1.0f, 1.0f, 1.0f];
    masonryP.baseDiffuseRoughness = 0.85f;
    masonryP.specularRoughness = 0.78f;
    masonryP.flags = MaterialFlags.normal;
    auto masonryMat = makePbrMat(masonryAlbedoTex, masonryP, null, &masonryNormalTex);
    scope(exit) masonryMat.destroy();

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

    auto camera = Camera.create(0.85f, cast(int) winW, cast(int) winH, 0.1f, 260.0f);
    auto orbit = makeOrbit();
    auto text = TextRenderer.create(app.gpu, winW, winH);
    scope(exit) text.destroy();
    auto fps = FpsCounter.create();
    bool showHud = initHud;

    info("OpenPBR Water Showcase — [1] Ocean [2] River [3] Sun [4] OpenPBR A/B [5] Waves [6] Opacity [7] SSR [F1] HUD");

    double[] benchSamples;
    if (benchFrames > 0) {
        benchSamples = new double[benchFrames];
    }
    size_t gcStartBytes = 0;
    size_t gcEndBytes = 0;

    float time = capturePath.length > 0 ? 1.8f : 0.0f;
    float wetMemoryScale = 1.0f;
    uint frameNum = 0;
    while (app.running()) {
        if (maxFrames > 0 && frameNum >= maxFrames) break;
        immutable bool isMeasuredFrame = benchFrames > 0 && frameNum >= WARMUP_FRAMES;
        immutable uint sampleIdx = frameNum >= WARMUP_FRAMES ? frameNum - WARMUP_FRAMES : 0;
        if (benchFrames > 0 && frameNum == WARMUP_FRAMES) {
            gcStartBytes = GC.stats().usedSize;
        }
        frameNum++;
        immutable bool captureThisFrame = capturePath.length > 0 && frameNum == maxFrames;
        immutable auto frameStartT = MonoTime.currTime;
        app.pollEvents();
        immutable float realDt = fps.tick();
        // Fixed step for benchmarks and captures so `--capture` is reproducible.
        immutable float dt = (benchFrames > 0 || capturePath.length > 0) ? (1.0f / 60.0f) : realDt;
        time += dt;
        if (app.input.keyPressed(Key.escape)) break;

        bool paramsDirty = frameNum == 1;
        if (app.input.keyPressed(Key.digit1)) { riverMode = false; paramsDirty = true; }
        if (app.input.keyPressed(Key.digit2)) { riverMode = true;  paramsDirty = true; }
        if (app.input.keyPressed(Key.digit3)) { lowSun = !lowSun; }
        if (app.input.keyPressed(Key.digit4)) { useOpenPbr = !useOpenPbr; paramsDirty = true; }
        if (app.input.keyPressed(Key.digit5)) { waveLevel = (waveLevel + 1) % 3; }
        if (app.input.keyPressed(Key.digit6)) { transparent = !transparent; paramsDirty = true; }
        if (app.input.keyPressed(Key.digit7)) { ssrEnabled = !ssrEnabled; }
        if (app.input.keyPressed(Key.f1))     { showHud = !showHud; hudHint = true; }
        if (app.input.keyPressed(Key.b))      { app.post.bloom = !app.post.bloom; }
        if (app.input.keyPressed(Key.f))      { app.post.fxaa = !app.post.fxaa; }
        if (app.input.keyPressed(Key.g))      { app.post.tonemapMode = 1 - app.post.tonemapMode; }
        if (app.input.keyPressed(Key.r))      { orbit = makeOrbit(); }
        if (app.input.keyPressed(Key.equals) || app.input.keyPressed(Key.kpPlus))
            app.post.exposure += 0.1f;
        if (app.input.keyPressed(Key.minus) || app.input.keyPressed(Key.kpMinus)) {
            app.post.exposure -= 0.1f;
            if (app.post.exposure < 0.1f) app.post.exposure = 0.1f;
        }

        immutable float waveScale = waveLevel == 0 ? 0.35f : (waveLevel == 1 ? 1.0f : 1.75f);
        if (waveScale >= wetMemoryScale) {
            wetMemoryScale = waveScale;
        } else {
            wetMemoryScale -= dt * 0.28f;
            if (wetMemoryScale < waveScale) wetMemoryScale = waveScale;
        }
        immutable bool propWaterFx = !noWater && renderStage >= 3;

        scene.setWeather(0.0f, 0.0f, 0.27f);  // dry, no rain, light drifting clouds
        if (waterBody >= 0) {
            WaterBody wb = riverMode ? WaterBody.river() : WaterBody.ocean();
            wb.halfExtent = WATER_HALF;
            wb.waves.amplitudeScale = waveScale;
            wb.recentPeakScale = wetMemoryScale;
            // Render stages: 0 = surface only, 1 = + opaque snapshot,
            // 2 = + refraction, 3 = + SSR, simulation and wet marks.
            uint features = 0;
            if (useOpenPbr) features |= WaterFeature.openPbr;
            if (transparent) features |= WaterFeature.transparent;
            if (renderStage >= 2) features |= WaterFeature.refraction;
            if (renderStage >= 3 && ssrEnabled) features |= WaterFeature.ssr;
            if (renderStage >= 3) features |= WaterFeature.simulation | WaterFeature.wetline;
            wb.features = features;
            water.setBody(waterBody, wb);
            WaterObstacle[MAX_WATER_OBSTACLES] obstacles;
            immutable RockPlacement[34] rockTable = riverMode ? RIVER_ROCKS : SEA_ROCKS;  // stack copy: slicing an enum array allocates
            immutable n = gatherObstacles(riverMode, rockTable[], obstacles);
            water.setObstacles(waterBody, obstacles[0 .. n]);
        }

        if (paramsDirty) {
            immutable uint waterFlagBits = propWaterFx ? MaterialFlags.waterWetCaustics : 0u;
            void applyWaterFx(ref MaterialParams p) {
                p.flags |= waterFlagBits;
            }
            auto dryP  = dryStoneParams();
            auto wetP  = wetSurfaceParams(dryStoneParams(), useOpenPbr);
            auto mossP = mossSurfaceParams(dryStoneParams(), useOpenPbr);
            auto subP  = submergedSurfaceParams(dryStoneParams(), useOpenPbr);
            applyWaterFx(dryP);
            applyWaterFx(wetP);
            applyWaterFx(mossP);
            applyWaterFx(subP);
            foreach (ref mg; rockMats) {
                mg.dry.updateParams(app.gpu, dryP);
                mg.wet.updateParams(app.gpu, wetP);
                mg.moss.updateParams(app.gpu, mossP);
                mg.submerged.updateParams(app.gpu, subP);
            }
            auto curWoodP = woodP;
            auto curMasP = masonryP;
            auto curBankP = bankP;
            if (propWaterFx) {
                curBankP.coatWeight = 0.72f;
                curBankP.coatRoughness = 0.10f;
                curBankP.coatIor = 1.333f;
                curBankP.coatDarkening = 0.55f;
            }
            applyWaterFx(curWoodP);
            applyWaterFx(curMasP);
            applyWaterFx(curBankP);
            woodMat.updateParams(app.gpu, curWoodP);
            masonryMat.updateParams(app.gpu, curMasP);
            bankMat.updateParams(app.gpu, curBankP);
        }

        orbit.update(app.input, dt, camera);

        // Golden hour: ~7° elevation so the engine sky picks its dusk palette.
        immutable Vec3 sunDir = lowSun
            ? Vec3(-0.78f, 0.12f, -0.58f).normalized()
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

        // Buoys: buoyancy from the engine water, then one physics step.
        Mat4[3] buoyModels;
        if (!riverMode) {
            if (waterBody >= 0) {
                foreach (ref bb; buoyBodies) {
                    applyBuoyancy(physics, bb, buoyProbes[],
                        (float x, float z, ref WaterSurfacePoint p) => water.surfaceAt(x, z, time, p));
                }
                physics.step(dt);
            }
            foreach (i, ref bb; buoyBodies)
                buoyModels[i] = Mat4.trs(getPosition(bb), getRotation(bb), Vec3(0.85f, 0.85f, 0.85f));
        }

        const rocks = riverMode ? RIVER_ROCKS : SEA_ROCKS;

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

        // Engine water: shared wave data, surface uniforms, simulation step.
        water.update(camera, time);

        immutable bgCol = lowSun
            ? Color4(0.16f, 0.12f, 0.11f, 1.0f)
            : Color4(0.24f, 0.38f, 0.56f, 1.0f);
        auto frame = app.beginFrame(bgCol);
        if (!frame.valid) continue;

        scene.begin(camera);

        // 1. Opaque geometry FIRST (rocks, riverbanks, bridge/lighthouse, buoys)
        void drawRock(ref const RockPlacement rk, ref const Mat4 model) {
            immutable size_t mi = rk.meshKind < 3 ? rk.meshKind : 1;
            void submit(ref Material mat) {
                if (mi == 0)      scene.drawMatrix(cliffRockMesh, mat, model, Color4.white);
                else if (mi == 1) scene.drawMatrix(boulderRockMesh, mat, model, Color4.white);
                else              scene.drawMatrix(cobbleRockMesh, mat, model, Color4.white);
            }
            if (rk.kind == 0)      submit(rockMats[mi].dry);
            else if (rk.kind == 1) submit(rockMats[mi].wet);
            else if (rk.kind == 2) submit(rockMats[mi].moss);
            else                   submit(rockMats[mi].submerged);
        }

        foreach (ref rk; rocks) {
            auto model = Mat4.translation(rk.pos.x, rk.pos.y, rk.pos.z)
                       * Mat4.rotationY(rk.rotY)
                       * Mat4.scaling(rk.scale.x, rk.scale.y, rk.scale.z);
            drawRock(rk, model);
        }

        scene.draw(riverMode ? riverBedMesh : oceanBedMesh, sandMat,
                   Vec3(0.0f, 0.0f, 0.0f), Vec3(1.0f, 1.0f, 1.0f), Color4.white);
        if (riverMode) {
            scene.draw(leftBankMesh, bankMat, Vec3(0.0f, 0.0f, 0.0f), Vec3(1.0f, 1.0f, 1.0f), Color4.white);
            scene.draw(rightBankMesh, bankMat, Vec3(0.0f, 0.0f, 0.0f), Vec3(1.0f, 1.0f, 1.0f), Color4.white);
            scene.draw(cube, woodMat, Vec3(-1.5f, 1.35f,  0.0f), Vec3(1.8f, 0.28f, 16.2f), Color4.white);
            scene.draw(cube, woodMat, Vec3(-1.5f, 0.10f, -4.6f), Vec3(0.55f, 2.6f, 0.55f), Color4(0.85f, 0.80f, 0.76f, 1.0f));
            scene.draw(cube, woodMat, Vec3(-1.5f, 0.10f,  4.6f), Vec3(0.55f, 2.6f, 0.55f), Color4(0.85f, 0.80f, 0.76f, 1.0f));
            scene.draw(cube, masonryMat, Vec3(-1.5f, 0.65f, -7.8f), Vec3(2.3f, 1.25f, 1.8f), Color4.white);
            scene.draw(cube, masonryMat, Vec3(-1.5f, 0.65f,  7.8f), Vec3(2.3f, 1.25f, 1.8f), Color4.white);
            scene.draw(cube, woodMat, Vec3(-0.7f, 1.75f, -5.6f), Vec3(0.16f, 0.65f, 0.16f), Color4(0.80f, 0.75f, 0.70f, 1.0f));
            scene.draw(sphere, beaconMat, Vec3(-0.7f, 2.10f, -5.6f), Vec3(0.24f, 0.24f, 0.24f), Color4.white);
        } else {
            scene.draw(cube, lighthouseMat, Vec3(-11.4f, 3.6f, -6.4f), Vec3(1.4f, 5.2f, 1.4f), Color4.white);
            scene.draw(sphere, beaconMat, Vec3(-11.4f, 6.5f, -6.4f), Vec3(0.75f, 0.75f, 0.75f), Color4.white);
            scene.drawMatrix(sphere, goldBuoyMat, buoyModels[0], Color4.white);
            scene.drawMatrix(sphere, filmBuoyMat, buoyModels[1], Color4.white);
            scene.drawMatrix(sphere, goldBuoyMat, buoyModels[2], Color4.white);
        }

        // Shadows for everything queued above (sun + spot), then the frame.
        scene.renderShadows(frame, lights);
        scene.end(frame);

        // The water surface (transparent hook, after the sky) was drawn by scene.end.

        app.resolvePost(frame);
        if (!frame.valid) continue;

        if (benchFrames == 0) {
            text.beginFrame();
            if (showHud) {
                immutable waveName = waveLevel == 0 ? "Calm" : (waveLevel == 1 ? "Moderate" : "Stormy");
                immutable sceneName = riverMode ? "Mountain River (Stream)" : "Open Ocean (Beaufort 5)";
                immutable sunName = lowSun ? "Golden Hour" : "High Noon";
                immutable shadingName = useOpenPbr
                    ? "Shading: OpenPBR v1.1 (Coat + Aniso + Fuzz + IOR 1.333)"
                    : "Shading: Legacy PBR Baseline (No Coat/Fuzz, IOR 1.5)";
                immutable waterAlphaName = transparent ? "Refractive Optical" : "Opaque (1.0)";
                immutable ssrName = (!noWater && renderStage >= 3 && ssrEnabled) ? "SSR=ON" : "SSR=OFF";
                immutable tmName = app.post.tonemapMode == 0 ? "ACES" : "Reinhard";

                text.drawText(frame, app.arena.fmt("OPENPBR WATER SHOWCASE  |  %s", fps.text()), 16, 14, 2);
                text.drawText(frame, app.arena.fmt("Scene: %s  |  Sun: %s", sceneName, sunName), 16, 34, 2);
                text.drawText(frame, shadingName, 16, 54, 2);
                text.drawText(frame, app.arena.fmt("Waves: %s  |  Surface: %s  |  %s", waveName, waterAlphaName, ssrName), 16, 74, 2);
                text.drawText(frame, app.arena.fmt("Post: Bloom=%s  FXAA=%s  TM=%s  Exp=%.2f",
                              app.post.bloom ? "ON" : "OFF",
                              app.post.fxaa ? "ON" : "OFF",
                              tmName, app.post.exposure), 16, 94, 2);

                text.drawText(frame, "[CONTROLS]", 16, 124, 2);
                text.drawText(frame, "[1] Ocean Swell            [2] Mountain River", 16, 144, 2);
                text.drawText(frame, "[3] Toggle Sun Angle       [4] OpenPBR vs Legacy", 16, 164, 2);
                text.drawText(frame, "[5] Wave State (C/M/S)     [6] Water Alpha/Opaque   [7] Toggle SSR", 16, 184, 2);
                text.drawText(frame, "[B] Bloom    [F] FXAA      [G] Tonemap   [+/-] Exposure", 16, 204, 2);
                text.drawText(frame, "[Drag/Arrows] Orbit        [W/S/Wheel] Zoom  [R] Reset", 16, 224, 2);
                text.drawText(frame, "[F1] Hide HUD              [ESC] Quit", 16, 244, 2);
            } else if (hudHint) {
                text.drawText(frame, "[F1] Show Controls HUD", 16, 14, 2);
            }
        }

        if (captureThisFrame) {
            app.renderer.requestCapture();
        }
        app.endFrame(frame);
        if (benchSync) {
            () @trusted {
                wgpuDevicePoll(app.gpu.getDevice(), WGPU_TRUE, null);
            }();
        }
        if (isMeasuredFrame && sampleIdx < benchSamples.length) {
            immutable auto elapsed = MonoTime.currTime - frameStartT;
            benchSamples[sampleIdx] = elapsed.total!"hnsecs" / 10_000.0;
        }
        if (benchFrames > 0 && frameNum == maxFrames) {
            gcEndBytes = GC.stats().usedSize;
        }
        if (captureThisFrame) {
            uint cw, ch;
            auto px = app.renderer.readCapture(cw, ch);
            if (px.length > 0) {
                writeCaptureBmp(capturePath, px, cw, ch);
            }
        }
    }

    if (benchFrames > 0 && benchSamples.length > 0) {
        sort(benchSamples);
        double sum = 0.0;
        foreach (s; benchSamples) sum += s;
        immutable double avgMs = sum / cast(double) benchSamples.length;
        immutable double p50Ms = benchSamples[(benchSamples.length * 50) / 100];
        immutable double p95Ms = benchSamples[(benchSamples.length * 95) / 100];
        immutable double p99Ms = benchSamples[(benchSamples.length * 99) / 100];
        immutable double maxMs = benchSamples[$ - 1];
        immutable double fpsMean = avgMs > 0.0 ? (1000.0 / avgMs) : 0.0;
        immutable long gcDelta = cast(long) gcEndBytes - cast(long) gcStartBytes;
        immutable string scenName = noWater ? "No-Water" : (riverMode ? "River" : "Ocean");
        writefln("BENCH_RESULT scenario=%s res=%ux%u avg_ms=%.3f p50_ms=%.3f p95_ms=%.3f p99_ms=%.3f max_ms=%.3f fps=%.1f gc_delta_bytes=%d",
                 scenName, winW, winH, avgMs, p50Ms, p95Ms, p99Ms, maxMs, fpsMean, gcDelta);
    }

    app.destroy();
}
