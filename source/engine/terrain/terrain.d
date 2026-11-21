/// `Terrain`: the CPU-side terrain (heights, splat weights, chunk grid) and
/// the gameplay queries. GPU rendering lives in `engine.terrain.renderer`,
/// physics colliders in `engine.terrain.physics`.
module engine.terrain.terrain;

import engine.math.vec : Vec3;
import engine.terrain.chunks : TerrainChunks, TerrainLodSettings;
import engine.terrain.heightmap : Heightmap;
import engine.terrain.splat : SplatMap;

@safe:

struct Terrain {
    Heightmap height;
    SplatMap splat;
    TerrainChunks chunks;

    @disable this(this);

    static Terrain create(Heightmap h, SplatMap s, TerrainLodSettings lod = TerrainLodSettings.init) {
        Terrain t;
        t.height = h;
        t.splat = s;
        t.chunks = TerrainChunks.create(t.height, lod);
        return t;
    }

    /// Surface height at world (x, z) — matches the physics collider.
    float heightAt(float x, float z) const pure nothrow @nogc { return height.heightAt(x, z); }

    /// Surface normal at world (x, z).
    Vec3 normalAt(float x, float z) const pure nothrow @nogc { return height.normalAt(x, z); }

    /// Dominant splat layer at world (x, z).
    ubyte layerAt(float x, float z) const pure nothrow @nogc { return splat.dominantLayer(height, x, z); }

    bool contains(float x, float z) const pure nothrow @nogc { return height.contains(x, z); }

    /// World-space center of the terrain at ground level.
    Vec3 center() const pure nothrow @nogc {
        immutable cx = height.desc.origin.x + height.sizeX() * 0.5f;
        immutable cz = height.desc.origin.z + height.sizeZ() * 0.5f;
        return Vec3(cx, heightAt(cx, cz), cz);
    }
}
