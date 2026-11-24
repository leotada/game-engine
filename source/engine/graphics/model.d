/**
 * Multi-node glTF models: shared immutable GPU data (`GltfAsset`) plus
 * lightweight per-object state (`ModelInstance`).
 *
 * - `GltfAsset` owns every sub-mesh (one per glTF primitive), material and
 *   texture of a file, plus the node tree in parents-first order. Load it
 *   once (`loadGltfAsset`) and share it between any number of instances.
 * - `ModelInstance` is a POD value (fits in ECS storage): per-node
 *   visibility bits, up to 8 material overrides (`MaterialHandle`) and up to
 *   8 node transform overrides.
 * - `drawModel` submits the visible sub-meshes to `Scene3DTextured`
 *   (`nothrow @nogc`, no per-frame allocation).
 * - `detachSubMesh` hides a node (door, wheel, bumper...) in an instance and
 *   returns its world transform and geometry so the game can spawn an
 *   independent rigid body / entity from it.
 */
module engine.graphics.model;

import core.lifetime : move;

import engine.assets.gltf;
import engine.assets.gltf_optimize : lodImportFor, uploadOptimizedMesh, uploadLodMesh;
import engine.core.handle : Handle;
import engine.core.log;
import engine.core.pod : isPod, Pod;
import engine.core.strings : StringId, StringTable;
import engine.gpu.context : GpuContext;
import engine.graphics.material : Material, MaterialFlags, MaterialParams;
import engine.graphics.material_pool : MaterialHandle, MaterialPool;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Sampler, Texture, TextureDesc;
import engine.graphics.types : Color4;
import engine.math.bounds : Aabb;
import engine.math.mat : Mat4;
import engine.meshopt.pipeline : LodSettings;
import engine.scene.scene3d_textured : Scene3DTextured, LOD_AUTO;
import bindings.wgpu : WGPUBindGroupLayout;

@safe:

/// Hard cap on nodes per asset (`ModelInstance` visibility bits are fixed size).
enum uint MAX_MODEL_NODES = 256;
/// Material / transform overrides per `ModelInstance`.
enum uint MAX_MODEL_OVERRIDES = 8;
/// `SubMeshInfo.material` value for primitives without a glTF material.
enum uint DEFAULT_MATERIAL = uint.max;

/// One node of a `GltfAsset`, stored parents-first (`parent < own index`).
struct GltfNode {
    StringId name;
    /// Parent index in `GltfAsset.nodes`, -1 for roots.
    int parent = -1;
    /// Local transform relative to the parent.
    Mat4 local;
    /// Asset-space transform at bind pose (`parent.bindWorld * local`).
    Mat4 bindWorld;
    /// First entry in `GltfAsset.subMeshes`; `subMeshCount == 0` for empty nodes.
    uint firstSubMesh;
    ushort subMeshCount;
    /// Index of this node in the source glTF `nodes[]`.
    ushort sourceIndex;
}
static assert(isPod!GltfNode);

/// Per-primitive metadata (material and object-space bounds).
struct SubMeshInfo {
    /// Index into `GltfAsset.materials`, or `DEFAULT_MATERIAL`.
    uint material = DEFAULT_MATERIAL;
    Aabb bounds;
}
static assert(isPod!SubMeshInfo);

/// Load options for `loadGltfAsset`.
struct GltfLoadOptions {
    /// CPU mip chains for every material texture (recommended for 3D).
    bool generateMips = true;
    /// Build a simplified LOD chain per primitive at load time.
    bool generateLods = false;
    LodSettings lodSettings;
    /// Opt-in material features (sRGB color textures, ...).
    GltfImportOptions gltf;
}

/// Shared GPU data of one glTF/GLB file. Move-only; call `destroy()`.
struct GltfAsset {
    /// One GPU mesh per glTF primitive (shared by every node using its mesh).
    TexMesh[] subMeshes;
    Pod!SubMeshInfo[] subMeshInfo;
    /// One material per glTF material, plus a trailing default material.
    Material[] materials;
    /// Interned glTF material names (one per glTF material, in `names`).
    Pod!StringId[] materialNames;
    Texture[] textures;
    Pod!GltfNode[] nodes;
    /// Node and material names (`GltfNode.name`, `GltfAsset.materialNames`).
    StringTable names;
    /// Asset-space bounds of every sub-mesh at bind pose.
    Aabb bounds;

    @disable this(this);

    /// Node index by name, or -1. Linear scan (≤ 256 nodes), `@nogc`.
    int findNode(scope const(char)[] name) const nothrow @nogc {
        return findNodeIn(nodes, names, name);
    }

    /// glTF material index by name, or -1 (`@nogc`).
    int findMaterial(scope const(char)[] name) const nothrow @nogc {
        return findMaterialIn(materialNames, names, name);
    }

    /// Name of glTF material `index` (empty when unnamed or out of range).
    const(char)[] materialName(size_t index) const nothrow @nogc {
        return index < materialNames.length ? names.get(materialNames[index]) : "";
    }

    /// Material used by sub-mesh `i` when no override applies.
    ref Material materialOf(size_t subMesh) return {
        immutable m = subMeshInfo[subMesh].material;
        return materials[m == DEFAULT_MATERIAL ? materials.length - 1 : m];
    }

    /// Material pointer for sub-mesh `i` (`nothrow @nogc`).
    Material* materialPtr(size_t subMesh) return nothrow @nogc @trusted {
        immutable m = subMeshInfo[subMesh].material;
        return &materials[m == DEFAULT_MATERIAL ? materials.length - 1 : m];
    }

    void destroy() nothrow @nogc {
        foreach (ref m; subMeshes) m.destroy();
        foreach (ref m; materials) m.destroy();
        foreach (ref t; textures) t.destroy();
        subMeshes = null;
        subMeshInfo = null;
        materials = null;
        materialNames = null;
        textures = null;
        nodes = null;
    }
}

/// Override of one sub-mesh's material.
struct MaterialOverride {
    ushort subMesh;
    MaterialHandle material;
}

/// Override of one node's local transform (opened door, steered wheel).
struct NodeTransformOverride {
    ushort node;
    Mat4 local;
}

/**
 * Per-object state of a model. POD: store it in ECS components.
 * Default-initialized instances show every node with the asset materials.
 */
struct ModelInstance {
    /// Optional registry handle of the shared asset (game-defined pool).
    Handle!GltfAsset asset;
    /// Bit set = node hidden (its whole subtree is skipped).
    uint[MAX_MODEL_NODES / 32] hiddenBits;
    MaterialOverride[MAX_MODEL_OVERRIDES] materialOverrides;
    ubyte materialOverrideCount;
    NodeTransformOverride[MAX_MODEL_OVERRIDES] transformOverrides;
    ubyte transformOverrideCount;

pure nothrow @nogc:

    void setNodeVisible(size_t node, bool visible) {
        if (node >= MAX_MODEL_NODES) return;
        immutable bit = 1u << (node & 31);
        if (visible) hiddenBits[node >> 5] &= ~bit;
        else hiddenBits[node >> 5] |= bit;
    }

    /// Own visibility flag (ancestors are not considered; see `isNodeShown`).
    bool isNodeVisible(size_t node) const {
        if (node >= MAX_MODEL_NODES) return false;
        return (hiddenBits[node >> 5] & (1u << (node & 31))) == 0;
    }

    /// Show every node again.
    void showAll() { hiddenBits[] = 0; }

    /// Override sub-mesh `subMesh` with `material`. False when the table is full.
    bool setMaterialOverride(size_t subMesh, MaterialHandle material) {
        foreach (ref o; materialOverrides[0 .. materialOverrideCount]) {
            if (o.subMesh == subMesh) {
                o.material = material;
                return true;
            }
        }
        if (materialOverrideCount >= MAX_MODEL_OVERRIDES) return false;
        materialOverrides[materialOverrideCount++] = MaterialOverride(cast(ushort) subMesh, material);
        return true;
    }

    void clearMaterialOverride(size_t subMesh) {
        foreach (i; 0 .. materialOverrideCount) {
            if (materialOverrides[i].subMesh == subMesh) {
                materialOverrides[i] = materialOverrides[--materialOverrideCount];
                return;
            }
        }
    }

    /// Override index for `subMesh`, or -1.
    int findMaterialOverride(size_t subMesh) const {
        foreach (i; 0 .. materialOverrideCount)
            if (materialOverrides[i].subMesh == subMesh) return cast(int) i;
        return -1;
    }

    /// Replace node `node`'s local transform. False when the table is full.
    bool setNodeLocal(size_t node, Mat4 local) {
        foreach (ref o; transformOverrides[0 .. transformOverrideCount]) {
            if (o.node == node) {
                o.local = local;
                return true;
            }
        }
        if (transformOverrideCount >= MAX_MODEL_OVERRIDES) return false;
        transformOverrides[transformOverrideCount++] = NodeTransformOverride(cast(ushort) node, local);
        return true;
    }

    void clearNodeLocal(size_t node) {
        foreach (i; 0 .. transformOverrideCount) {
            if (transformOverrides[i].node == node) {
                transformOverrides[i] = transformOverrides[--transformOverrideCount];
                return;
            }
        }
    }

    /// Local transform of `node` for this instance.
    Mat4 localOf(const(GltfNode)[] nodes, size_t node) const {
        foreach (ref o; transformOverrides[0 .. transformOverrideCount])
            if (o.node == node) return o.local;
        return nodes[node].local;
    }
}
static assert(isPod!ModelInstance);

/// Node index by name in a node table, or -1.
int findNodeIn(const(GltfNode)[] nodes, ref const StringTable names, scope const(char)[] name) nothrow @nogc {
    foreach (i, ref n; nodes)
        if (names.get(n.name) == name) return cast(int) i;
    return -1;
}

/// Material index by name in a material-name table, or -1.
int findMaterialIn(const(StringId)[] matNames, ref const StringTable names, scope const(char)[] name) nothrow @nogc {
    if (name.length == 0) return -1;
    foreach (i, id; matNames)
        if (names.get(id) == name) return cast(int) i;
    return -1;
}

/**
 * World matrix of every node for one instance. `outWorld.length` must be at
 * least `nodes.length`. Nodes are parents-first, so one forward pass is enough.
 */
void computeNodeWorlds(const(GltfNode)[] nodes, ref const ModelInstance inst,
                       Mat4 instanceWorld, scope Mat4[] outWorld) pure nothrow @nogc {
    assert(outWorld.length >= nodes.length);
    foreach (i, ref n; nodes) {
        immutable parentWorld = n.parent >= 0 ? outWorld[n.parent] : instanceWorld;
        outWorld[i] = parentWorld * inst.localOf(nodes, i);
    }
}

/// Effective visibility (node and every ancestor shown) for all nodes.
void computeNodeShown(const(GltfNode)[] nodes, ref const ModelInstance inst,
                      scope bool[] outShown) pure nothrow @nogc {
    assert(outShown.length >= nodes.length);
    foreach (i, ref n; nodes) {
        immutable parentShown = n.parent >= 0 ? outShown[n.parent] : true;
        outShown[i] = parentShown && inst.isNodeVisible(i);
    }
}

/// Result of `detachSubMesh`.
struct DetachedPart {
    bool found;
    uint nodeIndex;
    /// World transform of the node at detach time (instance world × node chain).
    Mat4 world;
    /// Sub-meshes of the node (`GltfAsset.subMeshes[first .. first + count]`).
    uint firstSubMesh;
    ushort subMeshCount;
    /// Node-local bounds of those sub-meshes (empty for nodes without geometry).
    Aabb localBounds;
}
static assert(isPod!DetachedPart);

/**
 * Hide node `nodeName` in `inst` and return what is needed to spawn it as an
 * independent object: its current world transform, its sub-mesh range and
 * node-local bounds (e.g. `createBoxBody` half extents). Children of the
 * node stay attached to it in the asset and are hidden too; detach them
 * separately if they must survive.
 */
DetachedPart detachSubMesh(const(GltfNode)[] nodes, const(SubMeshInfo)[] info,
                           ref const StringTable names, ref ModelInstance inst,
                           scope const(char)[] nodeName, Mat4 instanceWorld) nothrow @nogc {
    DetachedPart part;
    immutable idx = findNodeIn(nodes, names, nodeName);
    if (idx < 0) return part;
    Mat4[MAX_MODEL_NODES] worlds;
    computeNodeWorlds(nodes, inst, instanceWorld, worlds[0 .. nodes.length]);
    auto n = &nodes[idx];
    part.found = true;
    part.nodeIndex = cast(uint) idx;
    part.world = worlds[idx];
    part.firstSubMesh = n.firstSubMesh;
    part.subMeshCount = n.subMeshCount;
    foreach (sm; n.firstSubMesh .. n.firstSubMesh + n.subMeshCount)
        part.localBounds = part.localBounds.merge(info[sm].bounds);
    inst.setNodeVisible(idx, false);
    return part;
}

/// `detachSubMesh` on a loaded asset.
DetachedPart detachSubMesh(ref GltfAsset asset, ref ModelInstance inst,
                           scope const(char)[] nodeName, Mat4 instanceWorld) nothrow @nogc {
    return detachSubMesh(asset.nodes, asset.subMeshInfo, asset.names, inst, nodeName, instanceWorld);
}

/**
 * Submit every visible sub-mesh of `inst` to `scene`. Material overrides
 * resolve through `pool` (stale handles fall back to the asset material).
 * `lod` is forwarded to `Scene3DTextured.drawMatrix` (`LOD_AUTO` picks per
 * sub-mesh from distance when the mesh has a LOD chain).
 */
void drawModel(ref Scene3DTextured scene, ref GltfAsset asset, ref const ModelInstance inst,
               Mat4 world, ref MaterialPool pool, Color4 tint = Color4.white,
               ubyte lod = LOD_AUTO) nothrow @nogc {
    immutable count = asset.nodes.length;
    if (count == 0) return;
    Mat4[MAX_MODEL_NODES] worlds = void;
    bool[MAX_MODEL_NODES] shown;
    computeNodeWorlds(asset.nodes, inst, world, worlds[0 .. count]);
    computeNodeShown(asset.nodes, inst, shown[0 .. count]);
    foreach (i, ref n; asset.nodes) {
        if (!shown[i] || n.subMeshCount == 0) continue;
        foreach (sm; n.firstSubMesh .. n.firstSubMesh + n.subMeshCount) {
            Material* mat = null;
            immutable o = inst.findMaterialOverride(sm);
            if (o >= 0) mat = pool.get(inst.materialOverrides[o].material);
            if (mat is null) mat = asset.materialPtr(sm);
            scene.drawMatrix(asset.subMeshes[sm], *mat, worlds[i], tint, [1.0f, 0.0f, 0.0f, 0.0f], lod);
        }
    }
}

/// Overload without overrides (no pool needed).
void drawModel(ref Scene3DTextured scene, ref GltfAsset asset, ref const ModelInstance inst,
               Mat4 world, Color4 tint = Color4.white, ubyte lod = LOD_AUTO) nothrow @nogc {
    MaterialPool none;
    drawModel(scene, asset, inst, world, none, tint, lod);
}

/// Draw one sub-mesh on its own (a detached part) with an explicit material.
void drawSubMesh(ref Scene3DTextured scene, ref GltfAsset asset, size_t subMesh, Mat4 world,
                 ref Material material, Color4 tint = Color4.white, ubyte lod = LOD_AUTO) nothrow @nogc {
    scene.drawMatrix(asset.subMeshes[subMesh], material, world, tint, [1.0f, 0.0f, 0.0f, 0.0f], lod);
}

/// Draw one sub-mesh with its asset material.
void drawSubMesh(ref Scene3DTextured scene, ref GltfAsset asset, size_t subMesh, Mat4 world,
                 Color4 tint = Color4.white, ubyte lod = LOD_AUTO) nothrow @nogc {
    scene.drawMatrix(asset.subMeshes[subMesh], *asset.materialPtr(subMesh), world, tint,
                     [1.0f, 0.0f, 0.0f, 0.0f], lod);
}

// ---------------------------------------------------------------------------
// Loading
// ---------------------------------------------------------------------------

/**
 * Flatten the glTF node graph into a parents-first table (depth-first from
 * the scene roots). `meshFirstSubMesh[m]` is the first sub-mesh index of
 * glTF mesh `m`. Node names are interned into `names`.
 */
GltfNode[] buildNodeTable(ref const GltfSceneCpu scene, const(uint)[] meshFirstSubMesh,
                          ref StringTable names) @trusted {
    import std.exception : enforce;
    GltfNode[] table;
    int[] stackNode;
    int[] stackParent;
    foreach_reverse (r; scene.roots) {
        stackNode ~= r;
        stackParent ~= -1;
    }
    bool[] seen = new bool[scene.nodes.length];
    while (stackNode.length) {
        immutable src = stackNode[$ - 1];
        immutable parent = stackParent[$ - 1];
        stackNode.length--;
        stackParent.length--;
        enforce(src >= 0 && src < cast(int) scene.nodes.length, "glTF: node index OOB");
        enforce(!seen[src], "glTF: node graph is not a tree");
        seen[src] = true;
        enforce(table.length < MAX_MODEL_NODES, "glTF: more than 256 nodes in one model");
        auto cpu = &scene.nodes[src];
        GltfNode n;
        n.name = names.intern(cpu.name);
        n.parent = parent;
        n.local = cpu.local;
        n.bindWorld = parent >= 0 ? table[parent].bindWorld * cpu.local : cpu.local;
        n.sourceIndex = cast(ushort) src;
        if (cpu.mesh >= 0) {
            n.firstSubMesh = meshFirstSubMesh[cpu.mesh];
            n.subMeshCount = cast(ushort) scene.meshes[cpu.mesh].primitives.length;
        }
        immutable self = cast(int) table.length;
        table ~= n;
        foreach_reverse (c; cpu.children) {
            stackNode ~= c;
            stackParent ~= self;
        }
    }
    return table;
}

/**
 * Load every mesh, primitive, material, texture and node of a `.gltf`/`.glb`
 * file into GPU memory. Load-time only (allocates; never call per frame).
 */
GltfAsset loadGltfAsset(ref GpuContext gpu, string path, WGPUBindGroupLayout materialLayout,
                        ref Sampler sampler, GltfLoadOptions opts = GltfLoadOptions.init) @trusted {
    auto doc = parseGltfDocument(path);
    auto scene = parseGltfScene(doc);
    GltfAsset asset;
    // `.meta` `settings.lod.enabled` turns LOD generation on for this file.
    if (!opts.generateLods) {
        immutable metaLod = lodImportFor(path);
        if (metaLod.enabled) {
            opts.generateLods = true;
            opts.lodSettings = metaLod.settings;
        }
    }

    // Textures: one slot per (image, usage), one solid fallback per material, plus 5 layer slots per material.
    size_t imageCount = ("images" in doc.root) ? doc.root["images"].array.length : 0;
    immutable matCount = scene.materials.length;
    immutable size_t layerTexBase = imageCount * 4 + matCount + 1;
    asset.textures = new Texture[layerTexBase + matCount * 5];
    bool[] loaded = new bool[imageCount * 4];

    // One slot per (image, usage): data, normal map, sRGB color, masked base color.
    Texture* imageTexture(int image, bool normal, bool color = false, float alphaCoverage = 0) {
        if (image < 0 || image >= cast(int) imageCount) return null;
        immutable srgb = color && opts.gltf.srgbColor;
        immutable slot = image * 4 + (normal ? 1 : (alphaCoverage > 0 ? 3 : (srgb ? 2 : 0)));
        if (!loaded[slot]) {
            loaded[slot] = true;
            TextureDesc d;
            d.generateMips = opts.generateMips;
            d.normalMap = normal;
            d.srgb = srgb;
            d.alphaCoverage = alphaCoverage;
            auto t = loadGltfImage(gpu, doc, image, d);
            move(t, asset.textures[slot]);
        }
        return asset.textures[slot].valid ? &asset.textures[slot] : null;
    }

    asset.materials = new Material[matCount + 1];
    asset.materialNames = new Pod!StringId[matCount];
    foreach (mi; 0 .. matCount + 1) {
        GltfMaterialDesc md = mi < matCount ? scene.materials[mi] : GltfMaterialDesc.init;
        if (mi < matCount)
            asset.materialNames[mi] = asset.names.intern(md.name);
        MaterialParams params = md.params;
        params.flags = md.params.flags & MaterialFlags.thinWalled;
        Texture* albedo = imageTexture(md.baseColorImage, false, true,
                                           gltfBaseColorDesc(md, opts.gltf, true).alphaCoverage);
        if (albedo is null) {
            auto solidSlot = &asset.textures[imageCount * 4 + mi];
            auto t = Texture.solid(gpu, toU8(params.baseColor[0]), toU8(params.baseColor[1]),
                                   toU8(params.baseColor[2]), toU8(params.geometryOpacity));
            move(t, *solidSlot);
            albedo = solidSlot;
            params.baseColor = [1, 1, 1];
            params.geometryOpacity = 1.0f;
        }
        Texture* mr = imageTexture(md.metallicRoughnessImage, false);
        Texture* nrm = imageTexture(md.normalImage, true);
        Texture* ao = imageTexture(md.occlusionImage, false);
        Texture* em = imageTexture(md.emissiveImage, false, true);
        if (mr !is null) params.flags |= MaterialFlags.metallicRoughness;
        if (nrm !is null) params.flags |= MaterialFlags.normal;
        if (ao !is null) params.flags |= MaterialFlags.occlusion;
        if (em !is null) {
            params.flags |= MaterialFlags.emissive;
            if (params.emissionLuminance == 0.0f) params.emissionLuminance = 1.0f;
        }
        import engine.graphics.material : MaterialLayerMaps;
        Texture[5] layerTexs;
        bool[5] hasLayers;
        MaterialLayerMaps layers;
        if (mi < matCount) {
            layers = buildGltfLayerMaps(
                gpu, doc, md, params, layerTexs, hasLayers, opts.generateMips, opts.gltf.srgbColor);
        }
        auto m = Material.create(gpu, materialLayout, sampler, *albedo, params, mr, nrm, ao, em, layers);
        m.renderState = gltfRenderState(md, opts.gltf);
        move(m, asset.materials[mi]);
        if (mi < matCount) {
            foreach (li; 0 .. 5)
                if (hasLayers[li]) move(layerTexs[li], asset.textures[layerTexBase + mi * 5 + li]);
        }
    }

    // Sub-meshes: one per (mesh, primitive), shared by every node using the mesh.
    uint[] meshFirst = new uint[scene.meshes.length];
    size_t subCount = 0;
    foreach (mi, ref m; scene.meshes) {
        meshFirst[mi] = cast(uint) subCount;
        subCount += m.primitives.length;
    }
    asset.subMeshes = new TexMesh[subCount];
    asset.subMeshInfo = new SubMeshInfo[subCount];
    size_t k = 0;
    foreach (ref m; scene.meshes) {
        foreach (ref p; m.primitives) {
            auto g = &p.mesh;
            TexMesh tm = opts.generateLods
                ? uploadLodMesh(gpu, g.vertices, g.indices, g.shadowIndices, g.tangents, opts.lodSettings)
                : uploadOptimizedMesh(gpu, g.vertices, g.indices, g.shadowIndices, g.tangents);
            move(tm, asset.subMeshes[k]);
            asset.subMeshInfo[k].material = p.material >= 0 ? cast(uint) p.material : DEFAULT_MATERIAL;
            asset.subMeshInfo[k].bounds = asset.subMeshes[k].localBounds;
            k++;
        }
    }

    asset.nodes = buildNodeTable(scene, meshFirst, asset.names);
    foreach (ref n; asset.nodes)
        foreach (sm; n.firstSubMesh .. n.firstSubMesh + n.subMeshCount)
            asset.bounds = asset.bounds.merge(asset.subMeshInfo[sm].bounds.transformed(n.bindWorld));

    info("Loaded glTF asset: ", path, " (", asset.nodes.length, " nodes, ",
         subCount, " sub-meshes, ", matCount, " materials)");
    return asset;
}

private ubyte toU8(float v) pure nothrow @nogc {
    if (v < 0) return 0;
    if (v > 1) return 255;
    return cast(ubyte)(v * 255.0f + 0.5f);
}

// ---------------------------------------------------------------------------
// Tests (CPU only: node tables built from the synthetic GLB)
// ---------------------------------------------------------------------------

version (unittest) {
    private struct TestModel {
        GltfNode[] nodes;
        SubMeshInfo[] info;
        StringTable names;
    }

    private TestModel testModel() @trusted {
        auto doc = parseGltfDocumentBytes(makeTestVehicleGlb(), "/nonexistent-dir");
        auto scene = parseGltfScene(doc);
        TestModel t;
        uint[] meshFirst = [0, 2];
        t.nodes = buildNodeTable(scene, meshFirst, t.names);
        t.info = new SubMeshInfo[3];
        foreach (i; 0 .. 3) {
            t.info[i].bounds = Aabb.fromPositions(scene.meshes[i < 2 ? 0 : 1].primitives[i < 2 ? i : 0].mesh.vertices);
            t.info[i].material = i == 0 ? 0 : (i == 1 ? 1 : DEFAULT_MATERIAL);
        }
        return t;
    }
}

@("model.nodeTable") @safe unittest {
    auto t = testModel();
    assert(t.nodes.length == 3);
    assert(t.names.get(t.nodes[0].name) == "body" && t.nodes[0].parent == -1);
    assert(t.names.get(t.nodes[1].name) == "door_fl" && t.nodes[1].parent == 0);
    assert(t.names.get(t.nodes[2].name) == "handle" && t.nodes[2].parent == 1);
    assert(t.nodes[0].firstSubMesh == 0 && t.nodes[0].subMeshCount == 2);
    assert(t.nodes[1].firstSubMesh == 2 && t.nodes[1].subMeshCount == 1);
    assert(t.nodes[2].subMeshCount == 0);
    // bindWorld = body(0,1,0) * door(1,0,0)
    assert(t.nodes[1].bindWorld.m[12] == 1.0f && t.nodes[1].bindWorld.m[13] == 1.0f);
    assert(findNodeIn(t.nodes, t.names, "door_fl") == 1);
    assert(findNodeIn(t.nodes, t.names, "nope") == -1);
}

@("model.visibility") @safe unittest {
    auto t = testModel();
    ModelInstance inst;
    bool[3] shown;
    computeNodeShown(t.nodes, inst, shown[]);
    assert(shown == [true, true, true]);
    inst.setNodeVisible(1, false);
    computeNodeShown(t.nodes, inst, shown[]);
    assert(shown == [true, false, false]); // subtree hidden
    assert(inst.isNodeVisible(2));          // own flag untouched
    inst.setNodeVisible(1, true);
    inst.setNodeVisible(200, false);
    assert(!inst.isNodeVisible(200) && inst.isNodeVisible(199));
    inst.showAll();
    assert(inst.isNodeVisible(200));
}

@("model.materialOverride") @safe unittest {
    ModelInstance inst;
    assert(inst.findMaterialOverride(1) == -1);
    assert(inst.setMaterialOverride(1, MaterialHandle(5, 0)));
    assert(inst.setMaterialOverride(1, MaterialHandle(6, 0))); // replace, no new slot
    assert(inst.materialOverrideCount == 1);
    assert(inst.materialOverrides[inst.findMaterialOverride(1)].material == MaterialHandle(6, 0));
    foreach (i; 2 .. 1 + MAX_MODEL_OVERRIDES)
        assert(inst.setMaterialOverride(i, MaterialHandle(1, 0)));
    assert(!inst.setMaterialOverride(99, MaterialHandle(1, 0))); // full
    inst.clearMaterialOverride(1);
    assert(inst.findMaterialOverride(1) == -1 && inst.materialOverrideCount == MAX_MODEL_OVERRIDES - 1);
}

@("model.transformOverride") @safe unittest {
    auto t = testModel();
    ModelInstance inst;
    Mat4[3] worlds;
    auto instWorld = Mat4.translation(100, 0, 0);
    computeNodeWorlds(t.nodes, inst, instWorld, worlds[]);
    assert(worlds[1].m[12] == 101.0f && worlds[1].m[13] == 1.0f);
    // Swing the door: override its local translation; the child follows.
    assert(inst.setNodeLocal(1, Mat4.translation(0, 0, 5)));
    computeNodeWorlds(t.nodes, inst, instWorld, worlds[]);
    assert(worlds[1].m[12] == 100.0f && worlds[1].m[14] == 5.0f);
    assert(worlds[2].m[14] == 5.0f && worlds[2].m[0] == 2.0f);
    inst.clearNodeLocal(1);
    computeNodeWorlds(t.nodes, inst, instWorld, worlds[]);
    assert(worlds[1].m[12] == 101.0f);
}

@("model.detach") @safe unittest {
    auto t = testModel();
    ModelInstance inst;
    auto part = detachSubMesh(t.nodes, t.info, t.names, inst, "door_fl", Mat4.translation(0, 0, 10));
    assert(part.found && part.nodeIndex == 1);
    assert(part.world.m[12] == 1.0f && part.world.m[13] == 1.0f && part.world.m[14] == 10.0f);
    assert(part.firstSubMesh == 2 && part.subMeshCount == 1);
    assert(!part.localBounds.empty && part.localBounds.max.x > 0.99f);
    assert(!inst.isNodeVisible(1));
    bool[3] shown;
    computeNodeShown(t.nodes, inst, shown[]);
    assert(shown == [true, false, false]);

    auto missing = detachSubMesh(t.nodes, t.info, t.names, inst, "wheel_rr", Mat4.identity());
    assert(!missing.found);
}

@("model.materialNames") @safe unittest {
    auto doc = parseGltfDocumentBytes(makeTestVehicleGlb(), "/nonexistent-dir");
    auto scene = parseGltfScene(doc);
    StringTable names;
    auto matNames = new StringId[scene.materials.length];
    foreach (i, ref m; scene.materials)
        matNames[i] = names.intern(m.name);
    assert(findMaterialIn(matNames, names, "paint") == 0);
    assert(findMaterialIn(matNames, names, "glass") == 1);
    assert(findMaterialIn(matNames, names, "missing") == -1);
    assert(findMaterialIn(matNames, names, "") == -1);
}
