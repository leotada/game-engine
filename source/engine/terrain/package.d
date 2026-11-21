/// Chunked heightmap terrain: data, procedural generation, splat layers,
/// GPU rendering (CDLOD-style geomorphing, CSM casting) and Box3D colliders.
/// See docs/terrain-guide.md.
module engine.terrain;

public import engine.terrain.heightmap;
public import engine.terrain.splat;
public import engine.terrain.chunks;
public import engine.terrain.material;
public import engine.terrain.terrain;
public import engine.terrain.generate;
public import engine.terrain.renderer;
public import engine.terrain.physics;
