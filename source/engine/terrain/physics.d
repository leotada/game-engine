/// Box3D colliders for `Terrain`: one static heightfield body per tile
/// (`tileCells` cells, default 512), all sharing the terrain's global
/// height range so tile borders are seamless. Each cell's material index is
/// the dominant splat layer, mapped to `TerrainLayer.physicsMaterial`, so
/// `RayCastHit.surfaceMaterialId` reports the layer that is visibly on top.
/// Heights are fed with half a quantum of bias so Box3D's truncating
/// quantizer reproduces exactly the terrain's own 16-bit values.
module engine.terrain.physics;

import bindings.box3d : b3BodyId;
import engine.core.pod : isPod;
import engine.ecs.store : EntityId;
import engine.math.vec : Vec3;
import engine.physics.body : CollisionFilter, createHeightField, noPhysicsEntity, PhysicsSurfaceMaterial;
import engine.physics.world : PhysicsWorld;
import engine.terrain.material : TerrainLayer;
import engine.terrain.splat : MAX_TERRAIN_LAYERS;
import engine.terrain.terrain : Terrain;

@safe:

/// POD configuration for `buildTerrainColliders`.
struct TerrainColliderDesc {
    /// Tile size in cells along X and Z (0 uses the default 512).
    uint tileCells = 512;
    /// Collision filter applied to every tile shape.
    CollisionFilter filter = CollisionFilter.init;
    /// ECS `EntityId` stored on every tile body (queried via `RayCastHit.entityId`).
    EntityId entityId = noPhysicsEntity;
    /// Enable Box3D hit events on terrain tile shapes.
    bool enableHitEvents = false;
}

static assert(isPod!TerrainColliderDesc);

/// Number of heightfield collider tiles that `buildTerrainColliders` creates for `terrain`.
uint terrainColliderTileCount(ref const Terrain terrain, uint tileCells = 512) pure nothrow @nogc {
    const h = &terrain.height;
    if (h.desc.samplesX < 2 || h.desc.samplesZ < 2)
        return 0;
    immutable tc = tileCells == 0 ? 512 : tileCells;
    immutable cellsX = h.desc.samplesX - 1;
    immutable cellsZ = h.desc.samplesZ - 1;
    immutable nx = (cellsX + tc - 1) / tc;
    immutable nz = (cellsZ + tc - 1) / tc;
    return nx * nz;
}

/// Create the terrain colliders in `world` (load time). The cooked data is
/// owned by `world`. If `outBodies` is provided, writes up to `outBodies.length`
/// created tile `b3BodyId`s in row-major tile order. Returns the number of tiles created.
uint buildTerrainColliders(ref PhysicsWorld world, ref const Terrain terrain,
                           scope const(TerrainLayer)[] layers,
                           const TerrainColliderDesc desc,
                           scope b3BodyId[] outBodies = null) {
    const h = &terrain.height;
    immutable cellsX = h.desc.samplesX - 1, cellsZ = h.desc.samplesZ - 1;
    immutable tileCells = desc.tileCells == 0 ? 512 : desc.tileCells;

    PhysicsSurfaceMaterial[MAX_TERRAIN_LAYERS] mats;
    foreach (i, ref m; mats) {
        if (i < layers.length) {
            m.friction = layers[i].friction;
            m.userMaterialId = layers[i].physicsMaterial;
        }
    }
    immutable matCount = layers.length > 0 ? (layers.length < MAX_TERRAIN_LAYERS ? layers.length : MAX_TERRAIN_LAYERS) : 1;
    immutable bias = h.quantum() * 0.5f;
    immutable cs = h.desc.cellSize;

    uint tiles = 0;
    auto heights = new float[(tileCells + 1) * (tileCells + 1)];
    auto cellMats = new ubyte[tileCells * tileCells];
    for (uint z0 = 0; z0 < cellsZ; z0 += tileCells)
        for (uint x0 = 0; x0 < cellsX; x0 += tileCells) {
            immutable nx = (x0 + tileCells <= cellsX ? tileCells : cellsX - x0);
            immutable nz = (z0 + tileCells <= cellsZ ? tileCells : cellsZ - z0);
            immutable sx = nx + 1, sz = nz + 1;
            foreach (z; 0 .. sz)
                foreach (x; 0 .. sx)
                    heights[z * sx + x] = h.sample(x0 + x, z0 + z) + bias;
            foreach (z; 0 .. nz)
                foreach (x; 0 .. nx) {
                    immutable wx = h.desc.origin.x + (x0 + x + 0.5f) * cs;
                    immutable wz = h.desc.origin.z + (z0 + z + 0.5f) * cs;
                    ubyte l = terrain.layerAt(wx, wz);
                    if (l >= matCount) l = 0;
                    cellMats[z * nx + x] = l;
                }
            immutable pos = Vec3(h.desc.origin.x + x0 * cs, 0, h.desc.origin.z + z0 * cs);
            immutable bodyId = createHeightField(world, pos, heights[0 .. sx * sz], cast(int) sx, cast(int) sz,
                Vec3(cs, 1, cs), cellMats[0 .. nx * nz], mats[0 .. matCount], desc.entityId,
                h.desc.minHeight, h.desc.maxHeight, false, desc.filter, desc.enableHitEvents);
            if (tiles < outBodies.length)
                outBodies[tiles] = bodyId;
            tiles++;
        }
    return tiles;
}

/// Backwards-compatible overload using default `CollisionFilter` and `noPhysicsEntity`.
uint buildTerrainColliders(ref PhysicsWorld world, ref const Terrain terrain,
                           scope const(TerrainLayer)[] layers, uint tileCells = 512,
                           scope b3BodyId[] outBodies = null) {
    TerrainColliderDesc desc;
    desc.tileCells = tileCells;
    return buildTerrainColliders(world, terrain, layers, desc, outBodies);
}

unittest {
    import std.math : abs;
    import std.random : Random, uniform;
    import engine.physics.queries : castRayClosest;
    import engine.terrain.generate : generateBiomeSplat, generateHeights, TerrainGenSettings;
    import engine.terrain.heightmap : TerrainDesc;

    TerrainDesc d;
    d.samplesX = 2 * 128 + 1;
    d.samplesZ = 3 * 128 + 1;
    d.cellSize = 2.0f;
    d.origin = Vec3(-100, 0, 50);
    d.minHeight = -20;
    d.maxHeight = 420;
    TerrainGenSettings gs;
    gs.baseWavelength = 300;
    auto h = generateHeights(d, gs);
    auto s = generateBiomeSplat(h, 64, 96);
    auto t = Terrain.create(h, s);

    TerrainLayer[4] layers;
    foreach (i, ref l; layers) l.physicsMaterial = cast(ubyte)(10 + i);

    auto world = PhysicsWorld.createDefault();
    // Small tiles to exercise the seams.
    immutable tiles = buildTerrainColliders(world, t, layers[], 128);
    assert(tiles == 6);

    auto rng = Random(42);
    float maxErr = 0;
    uint matMismatch = 0;
    foreach (i; 0 .. 10_000) {
        immutable x = uniform(d.origin.x + 0.01f, d.origin.x + h.sizeX() - 0.01f, rng);
        immutable z = uniform(d.origin.z + 0.01f, d.origin.z + h.sizeZ() - 0.01f, rng);
        auto hit = castRayClosest(world, Vec3(x, 500, z), Vec3(0, -1, 0), 1000);
        assert(hit.hit, "terrain raycast missed");
        immutable err = abs(hit.point.y - t.heightAt(x, z));
        if (err > maxErr) maxErr = err;
        if (hit.surfaceMaterialId != 10 + t.layerAt(x, z)) matMismatch++;
    }
    assert(maxErr < 0.01f, "heightAt must match the physics surface within 1 cm");
    assert(matMismatch == 0, "raycast material must match the dominant splat layer");
}

unittest {
    import engine.physics.body : getBodyEntity, isBodyValid;
    import engine.physics.queries : castRayClosest, makeQueryFilter;
    import engine.terrain.generate : generateBiomeSplat, generateHeights, TerrainGenSettings;
    import engine.terrain.heightmap : TerrainDesc;

    TerrainDesc d;
    d.samplesX = 2 * 128 + 1;
    d.samplesZ = 3 * 128 + 1;
    d.cellSize = 2.0f;
    d.origin = Vec3(0, 0, 0);
    d.minHeight = -20;
    d.maxHeight = 420;
    TerrainGenSettings gs;
    gs.baseWavelength = 300;
    auto h = generateHeights(d, gs);
    auto s = generateBiomeSplat(h, 32, 32);
    auto t = Terrain.create(h, s);

    TerrainLayer[4] layers;
    foreach (i, ref l; layers) l.physicsMaterial = cast(ubyte)(1 + i);

    assert(terrainColliderTileCount(t, 128) == 6);

    auto world = PhysicsWorld.createDefault();
    enum ulong LAYER_WORLD = 1UL << 0;
    enum EntityId TERRAIN_ENTITY = 42;
    TerrainColliderDesc desc;
    desc.tileCells = 128;
    desc.filter = CollisionFilter(LAYER_WORLD, ulong.max, 0);
    desc.entityId = TERRAIN_ENTITY;
    desc.enableHitEvents = true;

    b3BodyId[6] bodies;
    immutable tiles = buildTerrainColliders(world, t, layers[], desc, bodies[]);
    assert(tiles == 6);
    foreach (b; bodies) {
        assert(isBodyValid(b));
        assert(getBodyEntity(b) == TERRAIN_ENTITY);
    }

    immutable cx = d.origin.x + h.sizeX() * 0.5f;
    immutable cz = d.origin.z + h.sizeZ() * 0.5f;

    // A query mask that excludes LAYER_WORLD must not hit the terrain.
    immutable hitExcluded = castRayClosest(world, Vec3(cx, 500, cz), Vec3(0, -1, 0), 1000,
        makeQueryFilter(ulong.max, ~LAYER_WORLD));
    assert(!hitExcluded.hit, "query excluding terrain category must miss");

    // A query mask that includes LAYER_WORLD must hit and return the configured EntityId.
    immutable hitIncluded = castRayClosest(world, Vec3(cx, 500, cz), Vec3(0, -1, 0), 1000,
        makeQueryFilter(ulong.max, LAYER_WORLD));
    assert(hitIncluded.hit, "query including terrain category must hit");
    assert(hitIncluded.entityId == TERRAIN_ENTITY);
}
