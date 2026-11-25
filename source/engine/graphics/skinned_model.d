/**
 * GPU-skinned character asset: multi-mesh / multi-primitive glTF/GLB character
 * with OpenPBR materials, material-name lookup (`findMaterial`), and batched
 * `Scene3DTextured.drawSkinned` submission.
 */
module engine.graphics.skinned_model;

import core.lifetime : move;

import bindings.wgpu : WGPUBindGroupLayout;
import engine.animation.ecs.assets : SkinBinding;
import engine.animation.gltf_skin : GltfSkinnedCharacterCpu, loadGltfSkinnedCharacterCpu;
import engine.animation.skeleton : Skeleton;
import engine.assets.gltf : buildGltfLayerMaps, buildGltfSpecularAa, gltfBaseColorDesc, GltfImportOptions, GltfMaterialDesc, gltfRenderState, loadGltfImage, parseGltfDocument, parseGltfMaterialAt;
import engine.core.log;
import engine.core.pod : isPod, Pod;
import engine.core.strings : StringId, StringTable;
import engine.gpu.context : GpuContext;
import engine.gpu.skinned : SkinnedMesh;
import engine.graphics.material : Material, MaterialFlags, MaterialLayerMaps, MaterialParams;
import engine.graphics.model : DEFAULT_MATERIAL, findMaterialIn;
import engine.graphics.texture : Sampler, Texture, TextureDesc;
import engine.graphics.types : Color4;
import engine.math.bounds : Aabb, BoundingSphere;
import engine.math.mat : Mat4;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

/// Per-primitive metadata on a `SkinnedCharacterAsset`.
struct SkinnedSubMeshInfo {
    /// Index into `SkinnedCharacterAsset.materials`, or `DEFAULT_MATERIAL`.
    uint material = DEFAULT_MATERIAL;
    /// Bind-pose object-space bounds of this primitive.
    Aabb bounds;
    /// Interned owning mesh name (in `SkinnedCharacterAsset.names`).
    StringId name;
}
static assert(isPod!SkinnedSubMeshInfo);

/// Shared GPU data for a skinned character (one `SkinnedMesh` per glTF primitive,
/// OpenPBR materials + textures, material-name table, and `SkinBinding`).
struct SkinnedCharacterAsset {
    SkinBinding binding;
    SkinnedMesh[] subMeshes;
    Pod!SkinnedSubMeshInfo[] subMeshInfo;
    /// One material per glTF material, plus a trailing default material.
    Material[] materials;
    /// Interned glTF material names (`materials[0 .. materials.length - 1]`).
    Pod!StringId[] materialNames;
    Texture[] textures;
    StringTable names;
    Aabb bindBounds;
    BoundingSphere bindSphere;

    @disable this(this);

    /// glTF material index by name, or -1 (`@nogc`).
    int findMaterial(scope const(char)[] name) const nothrow @nogc {
        return findMaterialIn(materialNames, names, name);
    }

    /// Name of glTF material `index`, or `""`.
    const(char)[] materialName(size_t index) const nothrow @nogc {
        return index < materialNames.length ? names.get(materialNames[index]) : "";
    }

    /// First sub-mesh index matching `meshName`, or -1 (`@nogc`).
    int findSubMesh(scope const(char)[] meshName) const nothrow @nogc {
        if (meshName.length == 0) return -1;
        foreach (i, ref sm; subMeshInfo)
            if (names.get(sm.name) == meshName) return cast(int) i;
        return -1;
    }

    /// Material used by `subMesh` when no override applies.
    ref Material materialOf(size_t subMesh) return nothrow @nogc {
        immutable m = subMeshInfo[subMesh].material;
        return materials[m == DEFAULT_MATERIAL ? materials.length - 1 : m];
    }

    /// Material pointer for `subMesh` (`nothrow @nogc`).
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
    }
}

/// Loads all skinned meshes, primitives, OpenPBR materials (including `doubleSided`
/// and material names) and textures of a `.gltf`/`.glb` character file, matching
/// skin joints to `skeleton` by name.
bool loadGltfSkinnedCharacter(ref GpuContext gpu, string path, ref const Skeleton skeleton,
                              WGPUBindGroupLayout materialLayout, ref Sampler sampler,
                              out SkinnedCharacterAsset asset, out string error,
                              bool generateMips = true,
                              GltfImportOptions gltfOpts = GltfImportOptions.init) @trusted {
    GltfSkinnedCharacterCpu cpu;
    if (!loadGltfSkinnedCharacterCpu(path, skeleton, cpu, error, 0, gltfOpts.vertexColors))
        return false;

    try {
        auto doc = parseGltfDocument(path);
        asset.binding = cpu.binding;
        asset.bindBounds = cpu.bindBounds;
        asset.bindSphere = cpu.bindSphere;

        size_t imageCount = ("images" in doc.root) ? doc.root["images"].array.length : 0;
        immutable matCount = cpu.materials.length;
        immutable size_t layerTexBase = imageCount * 4 + matCount + 1;
        asset.textures = new Texture[layerTexBase + matCount * 6]; // 5 layer maps + specular AA roughness
        bool[] loaded = new bool[imageCount * 4];

        // One slot per (image, usage): data, normal map, sRGB color, masked base color.
        Texture* imageTexture(int image, bool normal, bool color = false, float alphaCoverage = 0) {
            if (image < 0 || image >= cast(int) imageCount) return null;
            immutable srgb = color && gltfOpts.srgbColor;
            immutable slot = image * 4 + (normal ? 1 : (alphaCoverage > 0 ? 3 : (srgb ? 2 : 0)));
            if (!loaded[slot]) {
                loaded[slot] = true;
                TextureDesc d;
                d.generateMips = generateMips;
                d.normalMap = normal;
                d.srgb = srgb;
                d.alphaCoverage = alphaCoverage;
                d.compressed = gltfOpts.compressedTextures;
                auto t = loadGltfImage(gpu, doc, image, d);
                move(t, asset.textures[slot]);
            }
            return asset.textures[slot].valid ? &asset.textures[slot] : null;
        }

        asset.materials = new Material[matCount + 1];
        asset.materialNames = new Pod!StringId[matCount];
        foreach (mi; 0 .. matCount + 1) {
            GltfMaterialDesc md = mi < matCount ? parseGltfMaterialAt(doc.root, mi) : GltfMaterialDesc.init;
            if (mi < matCount)
                asset.materialNames[mi] = asset.names.intern(md.name);
            MaterialParams params = md.params;
            params.flags = md.params.flags & MaterialFlags.thinWalled;
            Texture* albedo = imageTexture(md.baseColorImage, false, true,
                                               gltfBaseColorDesc(md, gltfOpts, true).alphaCoverage);
            if (albedo is null) {
                auto solidSlot = &asset.textures[imageCount * 4 + mi];
                auto t = Texture.solid(gpu, toU8(params.baseColor[0]), toU8(params.baseColor[1]),
                                       toU8(params.baseColor[2]), toU8(params.geometryOpacity));
                move(t, *solidSlot);
                albedo = solidSlot;
                params.baseColor = [1, 1, 1];
                params.geometryOpacity = 1.0f;
            }
            Texture* mr;
            if (gltfOpts.specularAa && generateMips && mi < matCount) {
                auto t = buildGltfSpecularAa(gpu, doc, md, params, gltfOpts.compressedTextures ? cast(int) mi : -1);
                if (t.valid) {
                    mr = &asset.textures[layerTexBase + matCount * 5 + mi];
                    move(t, *mr);
                }
            }
            if (mr is null) mr = imageTexture(md.metallicRoughnessImage, false);
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
            Texture[5] layerTexs;
            bool[5] hasLayers;
            MaterialLayerMaps layers;
            if (mi < matCount) {
                layers = buildGltfLayerMaps(
                    gpu, doc, md, params, layerTexs, hasLayers, generateMips, gltfOpts.srgbColor);
            }
            auto m = Material.create(gpu, materialLayout, sampler, *albedo, params, mr, nrm, ao, em, layers);
            m.renderState = gltfRenderState(md, gltfOpts);
            move(m, asset.materials[mi]);
            if (mi < matCount) {
                foreach (li; 0 .. 5)
                    if (hasLayers[li]) move(layerTexs[li], asset.textures[layerTexBase + mi * 5 + li]);
            }
        }

        asset.subMeshes = new SkinnedMesh[cpu.subMeshes.length];
        asset.subMeshInfo = new Pod!SkinnedSubMeshInfo[cpu.subMeshes.length];
        foreach (i, ref sm; cpu.subMeshes) {
            auto uploaded = SkinnedMesh.fromData(gpu, sm.vertices, sm.indices);
            uploaded.setVertexColors(gpu, sm.colors);
            move(uploaded, asset.subMeshes[i]);
            asset.subMeshInfo[i].material = sm.material >= 0 ? cast(uint) sm.material : DEFAULT_MATERIAL;
            asset.subMeshInfo[i].bounds = sm.localBounds;
            asset.subMeshInfo[i].name = asset.names.intern(sm.meshName);
        }

        info("Loaded glTF skinned character: ", path, " (",
             asset.subMeshes.length, " sub-meshes, ", matCount, " materials, ",
             asset.binding.remap.length, " skin joints)");
        return true;
    } catch (Exception e) {
        asset.destroy();
        error = e.msg;
        return false;
    }
}

/// Submit every sub-mesh of `asset` to `scene` using `palette` and `modelPoseSphere`.
void drawSkinnedCharacter(ref Scene3DTextured scene, ref SkinnedCharacterAsset asset,
                          Mat4 world, scope const(Mat4)[] palette,
                          BoundingSphere modelPoseSphere,
                          Color4 tint = Color4.white,
                          float[4] custom = [1.0f, 0.0f, 0.0f, 0.0f]) nothrow @nogc {
    foreach (i; 0 .. asset.subMeshes.length) {
        scene.drawSkinned(asset.subMeshes[i], *asset.materialPtr(i), world, tint,
                          palette, modelPoseSphere, custom);
    }
}

/// Overload deriving the pose bounding sphere from `asset.bindSphere` and `palette`.
void drawSkinnedCharacter(ref Scene3DTextured scene, ref SkinnedCharacterAsset asset,
                          Mat4 world, scope const(Mat4)[] palette,
                          Color4 tint = Color4.white,
                          float[4] custom = [1.0f, 0.0f, 0.0f, 0.0f]) nothrow @nogc {
    foreach (i; 0 .. asset.subMeshes.length) {
        scene.drawSkinned(asset.subMeshes[i], *asset.materialPtr(i), world, tint,
                          palette, custom);
    }
}

/// Submit every sub-mesh of `asset` with optional per-sub-mesh material overrides.
/// Entries in `subMeshMaterials` that are non-null replace the asset's default material.
void drawSkinnedCharacter(ref Scene3DTextured scene, ref SkinnedCharacterAsset asset,
                          Mat4 world, scope const(Mat4)[] palette,
                          BoundingSphere modelPoseSphere,
                          scope const(Material*)[] subMeshMaterials,
                          Color4 tint = Color4.white,
                          float[4] custom = [1.0f, 0.0f, 0.0f, 0.0f]) nothrow @nogc @trusted {
    foreach (i; 0 .. asset.subMeshes.length) {
        Material* mat = (i < subMeshMaterials.length && subMeshMaterials[i] !is null)
            ? cast(Material*) subMeshMaterials[i]
            : asset.materialPtr(i);
        scene.drawSkinned(asset.subMeshes[i], *mat, world, tint,
                          palette, modelPoseSphere, custom);
    }
}

/// Populate `outPerSubMesh` slots whose glTF material matches `materialName` with `&replacement`.
void setCharacterMaterialOverride(ref const SkinnedCharacterAsset asset,
                                  scope const(char)[] materialName,
                                  ref Material replacement,
                                  scope Material*[] outPerSubMesh) nothrow @nogc @trusted {
    immutable mi = asset.findMaterial(materialName);
    if (mi < 0) return;
    immutable n = asset.subMeshInfo.length < outPerSubMesh.length
        ? asset.subMeshInfo.length : outPerSubMesh.length;
    foreach (i; 0 .. n) {
        if (asset.subMeshInfo[i].material == cast(uint) mi)
            outPerSubMesh[i] = &replacement;
    }
}

private ubyte toU8(float v) pure nothrow @nogc {
    if (v < 0.0f) return 0;
    if (v > 1.0f) return 255;
    return cast(ubyte)(v * 255.0f + 0.5f);
}

@("skinnedModel.materialOverrideMapping") @safe unittest {
    SkinnedCharacterAsset asset;
    asset.materialNames = [asset.names.intern("pele"), asset.names.intern("farda")];
    SkinnedSubMeshInfo[3] info;
    info[0].material = 0; info[0].name = asset.names.intern("head");
    info[1].material = 1; info[1].name = asset.names.intern("torso");
    info[2].material = 1; info[2].name = asset.names.intern("legs");
    asset.subMeshInfo = info.dup;

    assert(asset.findMaterial("pele") == 0);
    assert(asset.findMaterial("farda") == 1);
    assert(asset.findMaterial("none") == -1);
    assert(asset.findSubMesh("torso") == 1);

    Material customMat;
    Material*[3] overrides;
    setCharacterMaterialOverride(asset, "farda", customMat, overrides[]);
    assert(overrides[0] is null);
    assert(overrides[1] !is null && overrides[2] !is null);
}
