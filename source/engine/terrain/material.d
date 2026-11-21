/// Terrain layers and their GPU texture arrays. Each layer has an albedo
/// (linear RGB + height in alpha), a tangent-space normal and an ORM map, all
/// the same size; layer `i` is array slice `i` of each `TextureArray`.
module engine.terrain.material;

import engine.core.pod : isPod;
import engine.core.strings : StringId;
import engine.gpu.context : GpuContext;
import engine.graphics.texture : TextureArray, TextureDesc;
import engine.terrain.splat : MAX_TERRAIN_LAYERS;

@safe:

/// Per-layer shading and physics parameters.
struct TerrainLayer {
    StringId name;
    /// Texture repeats per meter.
    float uvScale = 0.25f;
    /// Height-blend contribution (0 = plain weight blend).
    float heightBlend = 1.0f;
    /// Triplanar blend sharpness on steep slopes (0 disables triplanar).
    float triplanarSharpness = 4.0f;
    /// Reported as `RayCastHit.surfaceMaterialId` by terrain colliders.
    ubyte physicsMaterial = 0;
    float friction = 0.8f;
}

static assert(isPod!TerrainLayer);

/// Layer parameters plus the three texture arrays.
struct TerrainMaterial {
    TerrainLayer[MAX_TERRAIN_LAYERS] layers;
    uint layerCount;
    TextureArray albedo, normal, orm;

    @disable this(this);

    /// Upload `layerCount` layers (`size²` RGBA8 each, mipmapped). Load time.
    static TerrainMaterial create(ref GpuContext gpu, scope const(TerrainLayer)[] layers,
                                  scope const(ubyte)[][] albedo, scope const(ubyte)[][] normal,
                                  scope const(ubyte)[][] orm, uint size) {
        assert(layers.length >= 1 && layers.length <= MAX_TERRAIN_LAYERS);
        assert(albedo.length == layers.length && normal.length == layers.length && orm.length == layers.length);
        TerrainMaterial m;
        m.layerCount = cast(uint) layers.length;
        m.layers[0 .. layers.length] = layers[];
        TextureDesc color;
        color.generateMips = true;
        TextureDesc nrm = color;
        nrm.normalMap = true;
        m.albedo = TextureArray.fromLayers(gpu, albedo, size, size, color);
        m.normal = TextureArray.fromLayers(gpu, normal, size, size, nrm);
        m.orm = TextureArray.fromLayers(gpu, orm, size, size, color);
        return m;
    }

    bool valid() const nothrow @nogc { return albedo.valid && normal.valid && orm.valid; }

    void destroy() nothrow @nogc {
        albedo.destroy();
        normal.destroy();
        orm.destroy();
    }
}
