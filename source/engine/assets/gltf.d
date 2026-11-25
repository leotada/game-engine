/// glTF 2.0 loader — geometry, OpenPBR materials and the node hierarchy.
///
/// Supported:
///   - `.gltf` JSON with external `.bin` or `data:` base64 buffers, and binary `.glb`
///   - Images by file URI, `data:` URI or GLB `bufferView` (PNG/JPG/WEBP/TGA/BMP...)
///   - Component types u8/u16/u32 indices, float and normalized-integer attributes
///     (`KHR_mesh_quantization`), `EXT_meshopt_compression`
///   - Every mesh, every primitive (with its own material) and the node tree
///     (`parseGltfScene`, `engine.graphics.model.loadGltfAsset`)
///   - Materials: pbrMetallicRoughness + `KHR_materials_*` mapped to OpenPBR
///
/// The single-mesh helpers (`parseGltfMesh`, `loadGltfMesh`, `loadGltfPbr`)
/// keep their historical behavior: first primitive of mesh 0 with the first
/// instancing node's transform baked in.
///
/// NOT supported: animations, skinning, morph targets, sparse accessors.
module engine.assets.gltf;

import core.math : sqrt;
import std.conv : to;
import std.exception : enforce;
import std.json;
import std.path : dirName, buildPath, extension;
import std.string : toLower;

import engine.assets.pak : assetExists, readAssetBytes;
import engine.core.log;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : BlendMode, RenderState;
import engine.graphics.material : Material, MaterialFlags, MaterialLayerMaps, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Texture, TextureDesc, Sampler;
import engine.graphics.types : TexVert;
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.vec : Vec3, Vec4;
import engine.assets.gltf_optimize : finalizeImportedMesh, generateMissingTangents, uploadImportedMesh;
import engine.meshopt.codec.filter;
import engine.meshopt.codec.index;
import engine.meshopt.codec.vertex;
import bindings.wgpu : WGPUBindGroupLayout;

@safe:

private enum uint CT_BYTE   = 5120;
private enum uint CT_UBYTE  = 5121;
private enum uint CT_SHORT  = 5122;
private enum uint CT_USHORT = 5123;
private enum uint CT_UINT   = 5125;
private enum uint CT_FLOAT  = 5126;

/// Load the first primitive of the first mesh from a .gltf file and
/// upload it as a TexMesh.
TexMesh loadGltfMesh(ref GpuContext gpu, string gltfPath) @trusted {
    auto mesh = parseGltfMesh(gltfPath);
    info("Loaded glTF: ", gltfPath, " (",
         mesh.vertices.length, " verts, ", mesh.indices.length, " indices)");
    return uploadImportedMesh(gpu, gltfPath, mesh.vertices, mesh.indices, mesh.shadowIndices, mesh.tangents);
}

/// Parsed glTF mesh on the CPU (no GPU resources yet).
struct GltfMesh {
    TexVert[] vertices;
    uint[] indices;
    /// Position-only indices from `optimizeMesh`. Empty when optimization is off.
    uint[] shadowIndices;
    /// One tangent per vertex when the file has `TANGENT` or a normal map generated one. `tangent[3]` is handedness.
    float[4][] tangents;
    /// One linear RGBA8 color per vertex (`COLOR_0` with `GltfImportOptions.vertexColors`), or empty.
    ubyte[4][] colors;
}

/// Opt-in glTF material features shared by `loadGltfPbr`, `loadGltfAsset` and
/// `loadGltfSkinnedCharacter`. Everything is off by default, so existing
/// assets keep their look.
struct GltfImportOptions {
    /// Read base color, emissive and sheen color textures as sRGB (the glTF
    /// rule). Normal, ORM and factor colors stay linear.
    bool srgbColor = false;
    /// Apply `alphaMode` / `alphaCutoff`: `MASK` becomes `RenderState.alphaMask`
    /// with coverage-preserving base color mips, `OPAQUE` disables blending.
    bool alphaModes = false;
    /// Bake the normal-map variation lost in each mip into the roughness of
    /// normal-mapped materials (specular antialiasing). Builds one
    /// metallic-roughness texture per such material.
    bool specularAa = false;
    /// Import `COLOR_0` and multiply it into base color and opacity.
    bool vertexColors = false;
}

/// glTF `alphaMode`.
enum GltfAlphaMode : ubyte { opaque, mask, blend }

/// Base color upload options of `desc` under `opts`.
package(engine) TextureDesc gltfBaseColorDesc(ref const GltfMaterialDesc desc, GltfImportOptions opts,
                                              bool generateMips) pure nothrow @nogc {
    TextureDesc d;
    d.generateMips = generateMips;
    d.srgb = opts.srgbColor;
    if (opts.alphaModes && desc.alphaMode == GltfAlphaMode.mask) d.alphaCoverage = desc.params.alphaCutoff;
    return d;
}

/// Render state of a glTF material under `opts`.
package(engine) RenderState gltfRenderState(ref const GltfMaterialDesc desc, GltfImportOptions opts) pure nothrow @nogc {
    RenderState s;
    s.doubleSided = desc.doubleSided;
    if (opts.alphaModes) {
        if (desc.alphaMode != GltfAlphaMode.blend) s.blend = BlendMode.opaque;
        s.alphaMask = desc.alphaMode == GltfAlphaMode.mask;
    }
    return s;
}

/// CPU-side OpenPBR material description extracted from glTF 2.0 + `KHR_materials_*`.
struct GltfMaterialDesc {
    string name;
    MaterialParams params;
    bool doubleSided = false;
    /// `alphaMode` (`alphaCutoff` goes to `params.alphaCutoff`).
    GltfAlphaMode alphaMode;
    bool hasBaseColorFactor = false;
    string baseColorUri;       // relative to glTF, empty if none
    string metallicRoughnessUri;
    string normalUri;
    string occlusionUri;
    string emissiveUri;
    /// glTF image indices behind each map (-1 = none). Embedded images have
    /// an empty URI and are loaded through `loadGltfImage`.
    int baseColorImage = -1;
    int metallicRoughnessImage = -1;
    int normalImage = -1;
    int occlusionImage = -1;
    int emissiveImage = -1;

    // OPBR-6 / OPBR-7 per-pixel layer & transmission maps.
    string clearcoatUri;
    string clearcoatRoughnessUri;
    string clearcoatNormalUri;
    string sheenColorUri;
    string sheenRoughnessUri;
    string anisotropyUri;
    string iridescenceThicknessUri;
    string transmissionUri;
    string thicknessUri;
    string diffuseTransmissionUri;
    int clearcoatImage = -1;
    int clearcoatRoughnessImage = -1;
    int clearcoatNormalImage = -1;
    int sheenColorImage = -1;
    int sheenRoughnessImage = -1;
    int anisotropyImage = -1;
    int iridescenceThicknessImage = -1;
    int transmissionImage = -1;
    int thicknessImage = -1;
    int diffuseTransmissionImage = -1;
}

/// Loaded GPU model: mesh + material (caller destroys both).
struct GltfModel {
    TexMesh mesh;
    Material material;
    Texture albedo;
    Texture metallicRoughness;
    Texture normal;
    Texture occlusion;
    Texture emissive;
    Texture[5] layerTextures;
    bool hasAlbedo;
    bool hasMR;
    bool hasNormal;
    bool hasOcclusion;
    bool hasEmissive;
    bool[5] hasLayerTextures;

    void destroy() {
        material.destroy();
        mesh.destroy();
        if (hasAlbedo) albedo.destroy();
        if (hasMR) metallicRoughness.destroy();
        if (hasNormal) normal.destroy();
        if (hasOcclusion) occlusion.destroy();
        if (hasEmissive) emissive.destroy();
        foreach (i, has; hasLayerTextures)
            if (has) layerTextures[i].destroy();
    }
}

/// Load mesh + OpenPBR material from a .gltf file.
/// Creates GPU textures for referenced images (BMP/TGA). Missing maps fall back
/// to MaterialDefaults via Material.create.
GltfModel loadGltfPbr(ref GpuContext gpu, string gltfPath,
                      WGPUBindGroupLayout materialLayout,
                      ref Sampler sampler,
                      GltfImportOptions opts = GltfImportOptions.init) @trusted {
    import core.lifetime : move;

    auto doc = parseGltfDocument(gltfPath);
    auto meshCpu = parseFirstMesh(doc, opts.vertexColors);
    GltfMaterialDesc matDesc;
    if ("materials" in doc.root && doc.root["materials"].array.length) {
        immutable mi = firstPrimitiveMaterial(doc);
        matDesc = parseGltfMaterialAt(doc.root, mi >= 0 ? mi : 0);
    }
    if (matDesc.normalImage >= 0 || matDesc.clearcoatNormalImage >= 0
        || matDesc.anisotropyImage >= 0 || matDesc.params.specularAnisotropy != 0.0f)
        generateMissingTangents(gltfPath, meshCpu.vertices, meshCpu.indices, meshCpu.shadowIndices, meshCpu.tangents, meshCpu.colors);

    GltfModel model;
    model.mesh = uploadImportedMesh(gpu, gltfPath, meshCpu.vertices, meshCpu.indices, meshCpu.shadowIndices, meshCpu.tangents, meshCpu.colors);

    MaterialParams params = matDesc.params;
    params.flags = matDesc.params.flags & MaterialFlags.thinWalled;

    TextureDesc colorDesc = TextureDesc.mipped();
    colorDesc.srgb = opts.srgbColor;
    Texture loadMap(int image, TextureDesc d) {
        return image >= 0 ? loadGltfImage(gpu, doc, image, d) : Texture.init;
    }

    {
        auto t = loadMap(matDesc.baseColorImage, gltfBaseColorDesc(matDesc, opts, true));
        if (t.valid) {
            model.albedo = move(t);
            model.hasAlbedo = true;
        }
    }
    if (!model.hasAlbedo) {
        model.albedo = Texture.solid(gpu,
            toU8(params.baseColor[0]),
            toU8(params.baseColor[1]),
            toU8(params.baseColor[2]),
            toU8(params.geometryOpacity));
        model.hasAlbedo = true;
        params.baseColor = [1, 1, 1];
        params.geometryOpacity = 1.0f;
    }

    Texture* mrPtr = null;
    Texture* nrmPtr = null;
    Texture* aoPtr = null;
    Texture* emPtr = null;

    {
        Texture t;
        if (opts.specularAa) {
            auto baked = buildGltfSpecularAa(gpu, doc, matDesc, params);
            move(baked, t);
        }
        if (!t.valid) {
            auto plain = loadMap(matDesc.metallicRoughnessImage, TextureDesc.mipped());
            move(plain, t);
        }
        if (t.valid) {
            model.metallicRoughness = move(t);
            model.hasMR = true;
            mrPtr = &model.metallicRoughness;
            params.flags |= MaterialFlags.metallicRoughness;
        }
    }
    {
        auto t = loadMap(matDesc.normalImage, TextureDesc.mippedNormal());
        if (t.valid) {
            model.normal = move(t);
            model.hasNormal = true;
            nrmPtr = &model.normal;
            params.flags |= MaterialFlags.normal;
        }
    }
    {
        auto t = loadMap(matDesc.occlusionImage, TextureDesc.mipped());
        if (t.valid) {
            model.occlusion = move(t);
            model.hasOcclusion = true;
            aoPtr = &model.occlusion;
            params.flags |= MaterialFlags.occlusion;
        }
    }
    {
        auto t = loadMap(matDesc.emissiveImage, colorDesc);
        if (t.valid) {
            model.emissive = move(t);
            model.hasEmissive = true;
            emPtr = &model.emissive;
            params.flags |= MaterialFlags.emissive;
            if (params.emissionLuminance == 0.0f)
                params.emissionLuminance = 1.0f;
        }
    }

    auto layers = buildGltfLayerMaps(
        gpu, doc, matDesc, params, model.layerTextures, model.hasLayerTextures, true, opts.srgbColor);

    model.material = Material.create(gpu, materialLayout, sampler, model.albedo,
                                     params, mrPtr, nrmPtr, aoPtr, emPtr, layers);
    model.material.renderState = gltfRenderState(matDesc, opts);

    info("Loaded glTF OpenPBR: ", gltfPath, " (",
         meshCpu.vertices.length, " verts, metalness=", params.baseMetalness,
         " roughness=", params.specularRoughness,
         " coat=", params.coatWeight, " fuzz=", params.fuzzWeight,
         " trans=", params.transmissionWeight, ")");
    return model;
}

/// Material index of mesh 0 / primitive 0, or -1.
private int firstPrimitiveMaterial(ref GltfDocument doc) @trusted {
    if ("meshes" !in doc.root) return -1;
    auto meshes = doc.root["meshes"].array;
    if (meshes.length == 0) return -1;
    auto prims = meshes[0]["primitives"].array;
    if (prims.length == 0 || "material" !in prims[0].object) return -1;
    return cast(int) prims[0]["material"].integer;
}

/// Parse pbrMetallicRoughness + `KHR_materials_*` extensions from the first material in a `.gltf`/`.glb` file.
GltfMaterialDesc parseGltfMaterial(string gltfPath) @trusted {
    auto doc = parseGltfDocument(gltfPath);
    return parseGltfMaterialAt(doc.root, 0);
}

/// Pure JSON material parser mapping glTF 2.0 + `KHR_materials_*` into OpenPBR `MaterialParams`.
GltfMaterialDesc parseGltfMaterialJson(string jsonText) @trusted {
    auto root = parseJSON(jsonText);
    return parseGltfMaterialAt(root, 0);
}

/// Parse `materials[index]`. Returns defaults when the material does not exist.
GltfMaterialDesc parseGltfMaterialAt(ref JSONValue root, size_t index) @trusted {
    GltfMaterialDesc desc;
    if ("materials" !in root) return desc;
    auto materials = root["materials"].array;
    if (index >= materials.length) return desc;
    auto mat = materials[index];

    if ("name" in mat && mat["name"].type == JSONType.string)
        desc.name = mat["name"].str;
    desc.doubleSided = jsonFlag(mat, "doubleSided");
    if ("alphaMode" in mat && mat["alphaMode"].type == JSONType.string) {
        if (mat["alphaMode"].str == "MASK") desc.alphaMode = GltfAlphaMode.mask;
        else if (mat["alphaMode"].str == "BLEND") desc.alphaMode = GltfAlphaMode.blend;
    }
    if ("alphaCutoff" in mat) desc.params.alphaCutoff = jsonFloat(mat["alphaCutoff"]);

    if ("pbrMetallicRoughness" in mat) {
        auto pbr = mat["pbrMetallicRoughness"];
        desc.params.baseMetalness = 1.0f;
        desc.params.specularRoughness = 1.0f;
        if ("baseColorFactor" in pbr) {
            auto arr = pbr["baseColorFactor"].array;
            if (arr.length >= 3) {
                desc.params.baseColor = [jsonFloat(arr[0]), jsonFloat(arr[1]), jsonFloat(arr[2])];
                desc.hasBaseColorFactor = true;
            }
            if (arr.length >= 4) {
                desc.params.geometryOpacity = jsonFloat(arr[3]);
            }
        }
        if ("metallicFactor" in pbr)
            desc.params.baseMetalness = jsonFloat(pbr["metallicFactor"]);
        if ("roughnessFactor" in pbr)
            desc.params.specularRoughness = jsonFloat(pbr["roughnessFactor"]);
        if ("baseColorTexture" in pbr)
            desc.baseColorUri = resolveTextureRef(root, cast(int) pbr["baseColorTexture"]["index"].integer, desc.baseColorImage);
        if ("metallicRoughnessTexture" in pbr)
            desc.metallicRoughnessUri = resolveTextureRef(root, cast(int) pbr["metallicRoughnessTexture"]["index"].integer, desc.metallicRoughnessImage);
    }
    if ("normalTexture" in mat)
        desc.normalUri = resolveTextureRef(root, cast(int) mat["normalTexture"]["index"].integer, desc.normalImage);
    if ("occlusionTexture" in mat)
        desc.occlusionUri = resolveTextureRef(root, cast(int) mat["occlusionTexture"]["index"].integer, desc.occlusionImage);
    if ("emissiveTexture" in mat) {
        desc.emissiveUri = resolveTextureRef(root, cast(int) mat["emissiveTexture"]["index"].integer, desc.emissiveImage);
        if (desc.params.emissionLuminance == 0.0f)
            desc.params.emissionLuminance = 1.0f;
    }
    if ("emissiveFactor" in mat) {
        auto arr = mat["emissiveFactor"].array;
        if (arr.length >= 3) {
            desc.params.emissionColor = [jsonFloat(arr[0]), jsonFloat(arr[1]), jsonFloat(arr[2])];
            if (desc.params.emissionColor[0] > 0.0f ||
                desc.params.emissionColor[1] > 0.0f ||
                desc.params.emissionColor[2] > 0.0f) {
                if (desc.params.emissionLuminance == 0.0f)
                    desc.params.emissionLuminance = 1.0f;
            }
        }
    }

    if ("extensions" in mat && mat["extensions"].type == JSONType.object) {
        auto ext = mat["extensions"];
        void readTexRef(ref JSONValue obj, string key, ref string uri, ref int img) {
            if (key in obj && obj[key].type == JSONType.object && "index" in obj[key].object)
                uri = resolveTextureRef(root, cast(int) obj[key]["index"].integer, img);
        }

        if ("KHR_materials_ior" in ext && ext["KHR_materials_ior"].type == JSONType.object) {
            auto e = ext["KHR_materials_ior"];
            if ("ior" in e) desc.params.specularIor = jsonFloat(e["ior"]);
        }
        if ("KHR_materials_specular" in ext && ext["KHR_materials_specular"].type == JSONType.object) {
            auto e = ext["KHR_materials_specular"];
            if ("specularFactor" in e) desc.params.specularWeight = jsonFloat(e["specularFactor"]);
            if ("specularColorFactor" in e) {
                auto arr = e["specularColorFactor"].array;
                if (arr.length >= 3)
                    desc.params.specularColor = [jsonFloat(arr[0]), jsonFloat(arr[1]), jsonFloat(arr[2])];
            }
        }
        if ("KHR_materials_clearcoat" in ext && ext["KHR_materials_clearcoat"].type == JSONType.object) {
            auto e = ext["KHR_materials_clearcoat"];
            if ("clearcoatFactor" in e) desc.params.coatWeight = jsonFloat(e["clearcoatFactor"]);
            if ("clearcoatRoughnessFactor" in e) desc.params.coatRoughness = jsonFloat(e["clearcoatRoughnessFactor"]);
            readTexRef(e, "clearcoatTexture", desc.clearcoatUri, desc.clearcoatImage);
            readTexRef(e, "clearcoatRoughnessTexture", desc.clearcoatRoughnessUri, desc.clearcoatRoughnessImage);
            readTexRef(e, "clearcoatNormalTexture", desc.clearcoatNormalUri, desc.clearcoatNormalImage);
        }
        if ("KHR_materials_sheen" in ext && ext["KHR_materials_sheen"].type == JSONType.object) {
            auto e = ext["KHR_materials_sheen"];
            desc.params.fuzzWeight = 1.0f;
            if ("sheenColorFactor" in e) {
                auto arr = e["sheenColorFactor"].array;
                if (arr.length >= 3)
                    desc.params.fuzzColor = [jsonFloat(arr[0]), jsonFloat(arr[1]), jsonFloat(arr[2])];
            }
            if ("sheenRoughnessFactor" in e) desc.params.fuzzRoughness = jsonFloat(e["sheenRoughnessFactor"]);
            readTexRef(e, "sheenColorTexture", desc.sheenColorUri, desc.sheenColorImage);
            readTexRef(e, "sheenRoughnessTexture", desc.sheenRoughnessUri, desc.sheenRoughnessImage);
        }
        if ("KHR_materials_iridescence" in ext && ext["KHR_materials_iridescence"].type == JSONType.object) {
            auto e = ext["KHR_materials_iridescence"];
            if ("iridescenceFactor" in e) desc.params.thinFilmWeight = jsonFloat(e["iridescenceFactor"]);
            if ("iridescenceIor" in e) desc.params.thinFilmIor = jsonFloat(e["iridescenceIor"]);
            if ("iridescenceThicknessMinimum" in e)
                desc.params.thinFilmThicknessMin = jsonFloat(e["iridescenceThicknessMinimum"]);
            else if ("iridescenceThicknessTexture" in e)
                desc.params.thinFilmThicknessMin = 100.0f;
            if ("iridescenceThicknessMaximum" in e) desc.params.thinFilmThickness = jsonFloat(e["iridescenceThicknessMaximum"]);
            readTexRef(e, "iridescenceThicknessTexture", desc.iridescenceThicknessUri, desc.iridescenceThicknessImage);
        }
        if ("KHR_materials_emissive_strength" in ext && ext["KHR_materials_emissive_strength"].type == JSONType.object) {
            auto e = ext["KHR_materials_emissive_strength"];
            if ("emissiveStrength" in e) {
                immutable strength = jsonFloat(e["emissiveStrength"]);
                desc.params.emissionLuminance = desc.params.emissionLuminance > 0.0f
                    ? desc.params.emissionLuminance * strength
                    : strength;
            }
        }
        if ("KHR_materials_anisotropy" in ext && ext["KHR_materials_anisotropy"].type == JSONType.object) {
            auto e = ext["KHR_materials_anisotropy"];
            if ("anisotropyStrength" in e) desc.params.specularAnisotropy = jsonFloat(e["anisotropyStrength"]);
            if ("anisotropyRotation" in e) desc.params.anisotropyRotation = jsonFloat(e["anisotropyRotation"]);
            readTexRef(e, "anisotropyTexture", desc.anisotropyUri, desc.anisotropyImage);
        }
        if ("KHR_materials_transmission" in ext && ext["KHR_materials_transmission"].type == JSONType.object) {
            auto e = ext["KHR_materials_transmission"];
            if ("transmissionFactor" in e) desc.params.transmissionWeight = jsonFloat(e["transmissionFactor"]);
            readTexRef(e, "transmissionTexture", desc.transmissionUri, desc.transmissionImage);
        }
        if ("KHR_materials_volume" in ext && ext["KHR_materials_volume"].type == JSONType.object) {
            auto e = ext["KHR_materials_volume"];
            if ("thicknessFactor" in e) desc.params.transmissionThickness = jsonFloat(e["thicknessFactor"]);
            if ("attenuationDistance" in e) desc.params.transmissionDepth = jsonFloat(e["attenuationDistance"]);
            if ("attenuationColor" in e) {
                auto arr = e["attenuationColor"].array;
                if (arr.length >= 3)
                    desc.params.transmissionColor = [jsonFloat(arr[0]), jsonFloat(arr[1]), jsonFloat(arr[2])];
            }
            readTexRef(e, "thicknessTexture", desc.thicknessUri, desc.thicknessImage);
        }
        if ("KHR_materials_dispersion" in ext && ext["KHR_materials_dispersion"].type == JSONType.object) {
            auto e = ext["KHR_materials_dispersion"];
            if ("dispersion" in e) desc.params.transmissionDispersion = jsonFloat(e["dispersion"]);
        }
        if ("KHR_materials_diffuse_transmission" in ext && ext["KHR_materials_diffuse_transmission"].type == JSONType.object) {
            auto e = ext["KHR_materials_diffuse_transmission"];
            if ("diffuseTransmissionFactor" in e)
                desc.params.subsurfaceWeight = jsonFloat(e["diffuseTransmissionFactor"]);
            if ("diffuseTransmissionColorFactor" in e) {
                auto arr = e["diffuseTransmissionColorFactor"].array;
                if (arr.length >= 3)
                    desc.params.subsurfaceColor = [jsonFloat(arr[0]), jsonFloat(arr[1]), jsonFloat(arr[2])];
            }
            readTexRef(e, "diffuseTransmissionTexture", desc.diffuseTransmissionUri, desc.diffuseTransmissionImage);
            immutable hasVolThick = ("KHR_materials_volume" in ext
                && ext["KHR_materials_volume"].type == JSONType.object
                && "thicknessFactor" in ext["KHR_materials_volume"]
                && jsonFloat(ext["KHR_materials_volume"]["thicknessFactor"]) > 0.0f);
            if (!hasVolThick) {
                desc.params.flags |= MaterialFlags.thinWalled;
            } else if (desc.params.transmissionDepth > 0.0f) {
                desc.params.subsurfaceRadius = desc.params.transmissionDepth;
            }
        }
    }

    return desc;
}

private float jsonFloat(ref JSONValue v) {
    if (v.type == JSONType.float_) return cast(float) v.floating;
    if (v.type == JSONType.integer) return cast(float) v.integer;
    return 0;
}

/// Resolve `textures[textureIndex]` to its image index; returns the file URI
/// (empty for embedded `bufferView` / `data:` images).
private string resolveTextureRef(ref JSONValue root, int textureIndex, out int imageIndex) @trusted {
    auto textures = root["textures"].array;
    enforce(textureIndex >= 0 && textureIndex < textures.length, "glTF: texture index OOB");
    enforce("source" in textures[textureIndex], "glTF: texture without source");
    immutable int source = cast(int) textures[textureIndex]["source"].integer;
    auto images = root["images"].array;
    enforce(source >= 0 && source < images.length, "glTF: image index OOB");
    imageIndex = source;
    if ("uri" !in images[source]) return null;
    immutable uri = images[source]["uri"].str;
    return isDataUri(uri) ? null : uri;
}

private Texture loadImageTexture(ref GpuContext gpu, string path, TextureDesc desc = TextureDesc.init) {
    if (!assetExists(path)) {
        err("glTF image not found: ", path);
        return Texture.init;
    }
    immutable ext = extension(path).toLower;
    if (ext == ".tga") {
        import engine.assets.pak : isAssetPakMounted;
        if (isAssetPakMounted()) {
            ubyte[] bytes;
            if (!readAssetBytes(path, bytes)) return Texture.init;
            return Texture.fromImageBytes(gpu, bytes, "TGA", desc);
        }
        return Texture.fromTgaFile(gpu, path, desc);
    }
    if (ext == ".bmp") {
        import engine.assets.pak : isAssetPakMounted;
        if (isAssetPakMounted()) {
            ubyte[] bytes;
            if (!readAssetBytes(path, bytes)) return Texture.init;
            return Texture.fromImageBytes(gpu, bytes, "BMP", desc);
        }
        import engine.assets.bmp : loadBmpTexture;
        return loadBmpTexture(gpu, path, desc);
    }
    if (ext == ".png" || ext == ".jpg" || ext == ".jpeg" || ext == ".webp"
            || ext == ".qoi" || ext == ".gif" || ext == ".avif" || ext == ".svg") {
        return Texture.fromImageFile(gpu, path, desc);
    }
    err("glTF: unsupported image format: ", path);
    return Texture.init;
}

private ubyte toU8(float v) pure nothrow @nogc {
    if (v < 0) return 0;
    if (v > 1) return 255;
    return cast(ubyte)(v * 255.0f + 0.5f);
}

private bool jsonFlag(ref JSONValue obj, string key) @trusted {
    if (key !in obj.object)
        return false;
    auto v = obj[key];
    if (v.type == JSONType.true_)
        return true;
    return false;
}

private size_t componentSize(uint componentType) pure nothrow @nogc {
    if (componentType == CT_BYTE || componentType == CT_UBYTE)
        return 1;
    if (componentType == CT_SHORT || componentType == CT_USHORT)
        return 2;
    if (componentType == CT_UINT || componentType == CT_FLOAT)
        return 4;
    return 0;
}

private float dequantizeComponent(int value, uint componentType, bool normalized) pure nothrow @nogc {
    if (componentType == CT_FLOAT)
        return 0;
    if (!normalized)
        return value;
    int bits = componentType == CT_BYTE || componentType == CT_UBYTE ? 8 : 16;
    if (componentType == CT_BYTE || componentType == CT_SHORT) {
        float maxv = cast(float)((1 << (bits - 1)) - 1);
        float f = cast(float) value / maxv;
        return f < -1.0f ? -1.0f : f;
    }
    float denom = cast(float)((1 << bits) - 1);
    return cast(float) value / denom;
}

private int readComponent(const(ubyte)[] src, size_t at, uint componentType) pure nothrow @nogc {
    if (componentType == CT_BYTE)
        return cast(byte) src[at];
    if (componentType == CT_UBYTE)
        return src[at];
    if (componentType == CT_SHORT)
        return cast(short)(src[at] | (src[at + 1] << 8));
    if (componentType == CT_USHORT)
        return src[at] | (src[at + 1] << 8);
    if (componentType == CT_UINT) {
        uint u = src[at] | (cast(uint) src[at + 1] << 8) | (cast(uint) src[at + 2] << 16) | (cast(uint) src[at + 3] << 24);
        return cast(int) u;
    }
    return 0;
}

private void applyMeshoptFilter(ubyte[] data, size_t count, size_t stride, string filter) @trusted {
    if (filter == "NONE" || filter.length == 0)
        return;
    if (filter == "OCTAHEDRAL") {
        enforce(stride == 4 || stride == 8, "glTF: octahedral filter stride must be 4 or 8");
        decodeFilterOct(data, count, stride);
    } else if (filter == "QUATERNION") {
        enforce(stride == 8, "glTF: quaternion filter stride must be 8");
        decodeFilterQuat(data, count, stride);
    } else if (filter == "EXPONENTIAL") {
        enforce(stride % 4 == 0, "glTF: exponential filter stride must be a multiple of 4");
        decodeFilterExp(data, count, stride);
    } else if (filter == "COLOR") {
        enforce(stride == 4 || stride == 8, "glTF: color filter stride must be 4 or 8");
        decodeFilterColor(data, count, stride);
    }
    else
        enforce(false, "glTF: unsupported EXT_meshopt_compression filter " ~ filter);
}

/// Decode one `EXT_meshopt_compression` bufferView into tightly packed bytes.
private ubyte[] decodeMeshoptView(ref JSONValue ext, const(ubyte)[][] buffers) @trusted {
    enforce("buffer" in ext.object && "byteLength" in ext.object && "byteStride" in ext.object
            && "count" in ext.object && "mode" in ext.object,
            "glTF: EXT_meshopt_compression is missing required fields");
    immutable size_t bufIdx = cast(size_t) ext["buffer"].integer;
    enforce(bufIdx < buffers.length, "glTF: meshopt buffer index OOB");
    immutable size_t off = ("byteOffset" in ext.object) ? cast(size_t) ext["byteOffset"].integer : 0;
    immutable size_t len = cast(size_t) ext["byteLength"].integer;
    immutable size_t stride = cast(size_t) ext["byteStride"].integer;
    immutable size_t count = cast(size_t) ext["count"].integer;
    string mode = ext["mode"].str;
    string filter = ("filter" in ext.object) ? ext["filter"].str : "NONE";
    auto srcBuf = buffers[bufIdx];
    enforce(off + len <= srcBuf.length, "glTF: meshopt block out of buffer bounds");
    auto src = srcBuf[off .. off + len];
    enforce(stride > 0 && count <= size_t.max / stride, "glTF: meshopt stride/count overflow");
    ubyte[] dst = new ubyte[count * stride];
    int rc = -1;
    if (mode == "ATTRIBUTES") {
        rc = decodeVertexBuffer(dst, count, stride, src);
    } else if (mode == "TRIANGLES" || mode == "INDICES") {
        enforce(stride == 2 || stride == 4, "glTF: meshopt index byteStride must be 2 or 4");
        if (stride == 2) {
            ushort[] idx = new ushort[count];
            rc = mode == "TRIANGLES" ? decodeIndexBuffer(idx, src) : decodeIndexSequence(idx, src);
            if (rc == 0)
                dst = cast(ubyte[]) idx;
        } else {
            uint[] idx = new uint[count];
            rc = mode == "TRIANGLES" ? decodeIndexBuffer(idx, src) : decodeIndexSequence(idx, src);
            if (rc == 0)
                dst = cast(ubyte[]) idx;
        }
    } else {
        enforce(false, "glTF: unsupported EXT_meshopt_compression mode " ~ mode);
    }
    enforce(rc == 0, "glTF: EXT_meshopt_compression decode failed (code " ~ rc.to!string ~ ")");
    applyMeshoptFilter(dst, count, stride, filter);
    return dst;
}

// ---------------------------------------------------------------------------
// Document: JSON root + resolved buffers (.gltf, .glb, data: URIs)
// ---------------------------------------------------------------------------

private enum uint GLB_MAGIC      = 0x46546C67; // "glTF"
private enum uint GLB_CHUNK_JSON = 0x4E4F534A; // "JSON"
private enum uint GLB_CHUNK_BIN  = 0x004E4942; // "BIN\0"

/// Parsed glTF container: JSON root plus every buffer resolved to bytes.
/// Load-time only (GC allowed).
struct GltfDocument {
    JSONValue root;
    /// One entry per `buffers[]` (external `.bin`, GLB BIN chunk, or `data:` URI).
    const(ubyte)[][] buffers;
    /// Decoded `EXT_meshopt_compression` bufferViews; empty when uncompressed.
    ubyte[][] meshoptViews;
    /// Directory used to resolve relative URIs.
    string baseDir;
    /// Asset path (for `.meta` import settings). May be empty.
    string path;
}

/// CPU view of one glTF image: either a URI on disk or embedded bytes.
struct GltfImageRef {
    /// Relative file URI; empty for embedded images.
    string uri;
    /// Embedded bytes (GLB bufferView or `data:` URI); empty for file URIs.
    const(ubyte)[] bytes;
    string mimeType;
}

private uint readU32le(scope const(ubyte)[] b, size_t at) pure nothrow @nogc {
    return cast(uint) b[at] | (cast(uint) b[at + 1] << 8)
         | (cast(uint) b[at + 2] << 16) | (cast(uint) b[at + 3] << 24);
}

/// True when `bytes` starts with the binary glTF (`.glb`) header.
bool isGlb(scope const(ubyte)[] bytes) pure nothrow @nogc {
    return bytes.length >= 12 && readU32le(bytes, 0) == GLB_MAGIC;
}

private bool isDataUri(string uri) pure nothrow @nogc {
    return uri.length >= 5 && uri[0 .. 5] == "data:";
}

/// Decode a `data:[<mime>];base64,<payload>` URI. Writes the MIME type.
private ubyte[] decodeDataUri(string uri, out string mime) @trusted {
    import std.base64 : Base64;
    import std.string : indexOf;
    immutable comma = uri.indexOf(',');
    enforce(comma > 5, "glTF: malformed data: URI");
    auto header = uri[5 .. comma];
    enforce(header.length >= 7 && header[$ - 7 .. $] == ";base64", "glTF: only base64 data: URIs are supported");
    mime = header[0 .. $ - 7];
    return Base64.decode(uri[comma + 1 .. $]);
}

/// Load and parse a `.gltf` or `.glb` file (disk or mounted asset pak).
GltfDocument parseGltfDocument(string path) @trusted {
    ubyte[] raw;
    enforce(readAssetBytes(path, raw), "glTF file not found: " ~ path);
    return parseGltfDocumentBytes(raw, dirName(path), path);
}

/**
 * Files whose edits change what `path` loads: the glTF/GLB itself, its
 * `.meta` sidecar (LOD settings) and every external buffer / image URI,
 * as normalized paths. Load-time only (parses the document). Returns just
 * the glTF and `.meta` paths when the document cannot be parsed.
 */
string[] gltfFileDependencies(string path) @trusted {
    import std.path : buildNormalizedPath, buildPath;
    string[] deps = [buildNormalizedPath(path), buildNormalizedPath(path ~ ".meta")];
    try {
        auto doc = parseGltfDocument(path);
        foreach (key; ["buffers", "images"]) {
            if (key !in doc.root) continue;
            foreach (ref item; doc.root[key].array) {
                if ("uri" !in item.object) continue;
                immutable uri = item["uri"].str;
                if (isDataUri(uri)) continue;
                deps ~= buildNormalizedPath(buildPath(doc.baseDir, uri));
            }
        }
    } catch (Exception) {}
    return deps;
}

/// Parse an in-memory `.gltf` (JSON text) or `.glb` container.
/// External buffer URIs resolve against `baseDir`.
GltfDocument parseGltfDocumentBytes(const(ubyte)[] bytes, string baseDir, string assetPath = "") @trusted {
    GltfDocument doc;
    doc.baseDir = baseDir;
    doc.path = assetPath;

    const(ubyte)[] bin;
    string jsonText;
    if (isGlb(bytes)) {
        enforce(readU32le(bytes, 4) == 2, "GLB: unsupported container version");
        immutable size_t total = readU32le(bytes, 8);
        enforce(total <= bytes.length, "GLB: truncated file");
        size_t at = 12;
        bool haveJson = false;
        while (at + 8 <= total) {
            immutable size_t len = readU32le(bytes, at);
            immutable uint type = readU32le(bytes, at + 4);
            at += 8;
            enforce(at + len <= total, "GLB: chunk out of bounds");
            if (type == GLB_CHUNK_JSON && !haveJson) {
                jsonText = cast(string) bytes[at .. at + len].idup;
                haveJson = true;
            } else if (type == GLB_CHUNK_BIN && bin.length == 0) {
                bin = bytes[at .. at + len];
            }
            at += len;
        }
        enforce(haveJson, "GLB: missing JSON chunk");
    } else {
        jsonText = cast(string) bytes.idup;
    }
    doc.root = parseJSON(jsonText);
    enforce(doc.root.type == JSONType.object, "glTF: root is not a JSON object");

    if ("buffers" in doc.root) {
        auto buffers = doc.root["buffers"].array;
        doc.buffers.length = buffers.length;
        foreach (i, b; buffers) {
            if ("uri" !in b.object) {
                enforce(bin.length > 0, "glTF: buffer without uri needs a GLB BIN chunk");
                doc.buffers[i] = bin;
                continue;
            }
            immutable uri = b["uri"].str;
            if (isDataUri(uri)) {
                string mime;
                doc.buffers[i] = decodeDataUri(uri, mime);
                continue;
            }
            ubyte[] binBytes;
            immutable binPath = buildPath(baseDir, uri);
            enforce(readAssetBytes(binPath, binBytes), "glTF: missing external buffer: " ~ binPath);
            doc.buffers[i] = binBytes;
        }
    }

    // Decode EXT_meshopt_compression before any accessor read. The decoded
    // bytes replace that bufferView; accessor byteOffset is relative to them.
    if ("bufferViews" in doc.root) {
        auto bufferViews = doc.root["bufferViews"].array;
        doc.meshoptViews.length = bufferViews.length;
        foreach (vi, ref bv; bufferViews) {
            if ("extensions" !in bv.object)
                continue;
            auto exts = bv["extensions"];
            if ("EXT_meshopt_compression" !in exts.object)
                continue;
            doc.meshoptViews[vi] = decodeMeshoptView(exts["EXT_meshopt_compression"], doc.buffers);
        }
    }
    return doc;
}

/// Raw bytes of a whole bufferView (embedded images).
const(ubyte)[] bufferViewBytes(ref GltfDocument doc, int bvIndex) @trusted {
    auto bufferViews = doc.root["bufferViews"].array;
    enforce(bvIndex >= 0 && bvIndex < bufferViews.length, "glTF: bufferView index OOB");
    if (doc.meshoptViews.length > bvIndex && doc.meshoptViews[bvIndex].length)
        return doc.meshoptViews[bvIndex];
    auto bv = bufferViews[bvIndex];
    immutable size_t bufIdx = cast(size_t) bv["buffer"].integer;
    enforce(bufIdx < doc.buffers.length, "glTF: buffer index OOB");
    immutable size_t off = ("byteOffset" in bv.object) ? cast(size_t) bv["byteOffset"].integer : 0;
    immutable size_t len = cast(size_t) bv["byteLength"].integer;
    enforce(off + len <= doc.buffers[bufIdx].length, "glTF: bufferView out of buffer bounds");
    return doc.buffers[bufIdx][off .. off + len];
}

/// Resolve `images[imageIndex]` to a file URI or embedded bytes.
GltfImageRef resolveGltfImage(ref GltfDocument doc, int imageIndex) @trusted {
    GltfImageRef r;
    enforce("images" in doc.root, "glTF: no images array");
    auto images = doc.root["images"].array;
    enforce(imageIndex >= 0 && imageIndex < images.length, "glTF: image index OOB");
    auto img = images[imageIndex];
    if ("mimeType" in img.object)
        r.mimeType = img["mimeType"].str;
    if ("bufferView" in img.object) {
        r.bytes = bufferViewBytes(doc, cast(int) img["bufferView"].integer);
        return r;
    }
    enforce("uri" in img.object, "glTF: image has neither uri nor bufferView");
    immutable uri = img["uri"].str;
    if (isDataUri(uri)) {
        string mime;
        r.bytes = decodeDataUri(uri, mime);
        if (r.mimeType.length == 0) r.mimeType = mime;
        return r;
    }
    r.uri = uri;
    return r;
}

/// SDL3_image type hint for a glTF MIME type (null lets SDL sniff the bytes).
private const(char)* imageTypeHint(string mime) pure nothrow @nogc {
    if (mime == "image/png") return "PNG";
    if (mime == "image/jpeg") return "JPG";
    if (mime == "image/webp") return "WEBP";
    return null;
}

/// Upload a glTF image (file URI or embedded bytes) as a GPU texture.
Texture loadGltfImage(ref GpuContext gpu, ref GltfDocument doc, int imageIndex,
                      TextureDesc desc = TextureDesc.init) @trusted {
    GltfImageRef r;
    try {
        r = resolveGltfImage(doc, imageIndex);
    } catch (Exception e) {
        err("glTF image ", imageIndex, ": ", e.msg);
        return Texture.init;
    }
    if (r.bytes.length)
        return Texture.fromImageBytes(gpu, r.bytes, imageTypeHint(r.mimeType), desc);
    return loadImageTexture(gpu, buildPath(doc.baseDir, r.uri), desc);
}

private struct DecodedImage {
    ubyte[] rgba;
    uint w;
    uint h;
    bool valid() const pure nothrow @nogc { return w > 0 && h > 0 && rgba.length >= cast(size_t) w * h * 4; }
}

private DecodedImage decodeGltfImagePixels(ref GltfDocument doc, int imageIndex) @trusted {
    DecodedImage img;
    if (imageIndex < 0) return img;
    GltfImageRef r;
    try {
        r = resolveGltfImage(doc, imageIndex);
    } catch (Exception e) {
        err("glTF image ", imageIndex, ": ", e.msg);
        return img;
    }
    if (r.bytes.length) {
        if (!Texture.decodeImageBytes(r.bytes, img.rgba, img.w, img.h, imageTypeHint(r.mimeType)))
            return DecodedImage.init;
        return img;
    }
    immutable path = buildPath(doc.baseDir, r.uri);
    if (!assetExists(path)) {
        err("glTF image not found: ", path);
        return img;
    }
    ubyte[] fileBytes;
    if (!readAssetBytes(path, fileBytes)) return img;
    immutable ext = extension(path).toLower;
    if (ext == ".bmp") {
        import engine.assets.bmp : decodeBmp;
        try {
            auto bmp = decodeBmp(fileBytes);
            img.rgba = bmp.pixels;
            img.w = bmp.width;
            img.h = bmp.height;
            return img;
        } catch (Exception e) {
            err("glTF BMP decode failed: ", path, ": ", e.msg);
            return DecodedImage.init;
        }
    }
    const(char)* hint = ext == ".tga" ? "TGA".ptr : null;
    if (!Texture.decodeImageBytes(fileBytes, img.rgba, img.w, img.h, hint))
        return DecodedImage.init;
    return img;
}

/// Metallic-roughness texture with the normal variation of each mip
/// (`GltfImportOptions.specularAa`). Invalid when the material has no normal
/// map. The roughness factor moves from `params` into the texture.
package(engine) Texture buildGltfSpecularAa(ref GpuContext gpu, ref GltfDocument doc, ref const GltfMaterialDesc desc,
                                            ref MaterialParams params) @trusted {
    import engine.graphics.specular_aa : specularAaTexture;
    if (desc.normalImage < 0) return Texture.init;
    auto n = decodeGltfImagePixels(doc, desc.normalImage);
    if (!n.valid) return Texture.init;
    DecodedImage mr;
    if (desc.metallicRoughnessImage >= 0) mr = decodeGltfImagePixels(doc, desc.metallicRoughnessImage);
    params.flags |= MaterialFlags.metallicRoughness;
    immutable factor = params.specularRoughness;
    params.specularRoughness = 1;
    return specularAaTexture(gpu, mr.valid ? mr.rgba : null, mr.w, mr.h, n.rgba, n.w, n.h, factor);
}

private ubyte sampleChannelResized(ref const DecodedImage img, uint x, uint y, uint dw, uint dh, uint ch) pure nothrow @nogc {
    immutable sx = (img.w == dw) ? x : cast(uint)((cast(size_t) x * img.w) / dw);
    immutable sy = (img.h == dh) ? y : cast(uint)((cast(size_t) y * img.h) / dh);
    return img.rgba[(cast(size_t) sy * img.w + sx) * 4 + ch];
}

private enum LayerPackMode : ubyte {
    coat,         // R=A.r, G=B.g, B=255, A=255
    fuzz,         // RGB=A.rgb, A=B.a
    anisoFilm,    // RGB=A.rgb (or 255,128,255), A=B.g
    transmission, // R=A.r, G=B.g, B=255, A=255
}

private Texture packLayerTexture(ref GpuContext gpu, ref GltfDocument doc,
                                 int imgIdxA, int imgIdxB, LayerPackMode mode,
                                 bool generateMips, out bool okA, out bool okB,
                                 int imgIdxC, out bool okC, bool srgb = false) @trusted {
    auto a = decodeGltfImagePixels(doc, imgIdxA);
    auto b = (imgIdxB == imgIdxA) ? a : decodeGltfImagePixels(doc, imgIdxB);
    auto c = (imgIdxC == imgIdxA) ? a : ((imgIdxC == imgIdxB) ? b : decodeGltfImagePixels(doc, imgIdxC));
    okA = a.valid;
    okB = b.valid;
    okC = c.valid;
    if (!okA && !okB && !okC) return Texture.init;

    uint w = 0, h = 0;
    if (okA) { if (a.w > w) w = a.w; if (a.h > h) h = a.h; }
    if (okB) { if (b.w > w) w = b.w; if (b.h > h) h = b.h; }
    if (okC) { if (c.w > w) w = c.w; if (c.h > h) h = c.h; }
    auto pixels = new ubyte[cast(size_t) w * h * 4];

    foreach (y; 0 .. h) {
        foreach (x; 0 .. w) {
            immutable di = (cast(size_t) y * w + x) * 4;
            final switch (mode) {
                case LayerPackMode.coat:
                    pixels[di + 0] = okA ? sampleChannelResized(a, x, y, w, h, 0) : 255;
                    pixels[di + 1] = okB ? sampleChannelResized(b, x, y, w, h, 1) : 255;
                    pixels[di + 2] = 255;
                    pixels[di + 3] = 255;
                    break;
                case LayerPackMode.transmission:
                    pixels[di + 0] = okA ? sampleChannelResized(a, x, y, w, h, 0) : 255;
                    pixels[di + 1] = okB ? sampleChannelResized(b, x, y, w, h, 1) : 255;
                    pixels[di + 2] = okC ? sampleChannelResized(c, x, y, w, h, 3) : 255;
                    pixels[di + 3] = 255;
                    break;
                case LayerPackMode.fuzz:
                    pixels[di + 0] = okA ? sampleChannelResized(a, x, y, w, h, 0) : 255;
                    pixels[di + 1] = okA ? sampleChannelResized(a, x, y, w, h, 1) : 255;
                    pixels[di + 2] = okA ? sampleChannelResized(a, x, y, w, h, 2) : 255;
                    pixels[di + 3] = okB ? sampleChannelResized(b, x, y, w, h, 3) : 255;
                    break;
                case LayerPackMode.anisoFilm:
                    pixels[di + 0] = okA ? sampleChannelResized(a, x, y, w, h, 0) : 255;
                    pixels[di + 1] = okA ? sampleChannelResized(a, x, y, w, h, 1) : 128;
                    pixels[di + 2] = okA ? sampleChannelResized(a, x, y, w, h, 2) : 255;
                    pixels[di + 3] = okB ? sampleChannelResized(b, x, y, w, h, 1) : 255;
                    break;
            }
        }
    }
    return Texture.fromPixels(gpu, pixels, w, h, TextureDesc(generateMips, false, srgb));
}

private Texture packLayerTexture(ref GpuContext gpu, ref GltfDocument doc,
                                 int imgIdxA, int imgIdxB, LayerPackMode mode,
                                 bool generateMips, out bool okA, out bool okB, bool srgb = false) @trusted {
    bool okC;
    return packLayerTexture(gpu, doc, imgIdxA, imgIdxB, mode, generateMips, okA, okB, -1, okC, srgb);
}

/**
 * Decode and pack the OPBR-6/7 glTF layer textures (`clearcoat*Texture`,
 * `sheen*Texture`, `anisotropyTexture`, `iridescenceThicknessTexture`,
 * `transmissionTexture`, `thicknessTexture`) into the 5 `MaterialLayerMaps`
 * slots, updating `params.flags` for each valid map.
 */
MaterialLayerMaps buildGltfLayerMaps(
    ref GpuContext gpu,
    ref GltfDocument doc,
    ref const GltfMaterialDesc matDesc,
    ref MaterialParams params,
    out Texture[5] outTextures,
    out bool[5] outHas,
    bool generateMips = true,
    bool srgbColor = false
) @trusted {
    import core.lifetime : move;
    MaterialLayerMaps maps;

    if (matDesc.clearcoatImage >= 0 || matDesc.clearcoatRoughnessImage >= 0) {
        bool okA, okB;
        auto t = packLayerTexture(gpu, doc, matDesc.clearcoatImage,
                                  matDesc.clearcoatRoughnessImage, LayerPackMode.coat,
                                  generateMips, okA, okB);
        if (t.valid) {
            move(t, outTextures[0]);
            outHas[0] = true;
            maps.coat = &outTextures[0];
            params.flags |= MaterialFlags.coat;
        }
    }
    if (matDesc.clearcoatNormalImage >= 0) {
        auto t = loadGltfImage(gpu, doc, matDesc.clearcoatNormalImage,
                               TextureDesc(generateMips, true));
        if (t.valid) {
            move(t, outTextures[1]);
            outHas[1] = true;
            maps.coatNormal = &outTextures[1];
            params.flags |= MaterialFlags.coatNormal;
        }
    }
    if (matDesc.sheenColorImage >= 0 || matDesc.sheenRoughnessImage >= 0) {
        bool okA, okB;
        auto t = packLayerTexture(gpu, doc, matDesc.sheenColorImage,
                                  matDesc.sheenRoughnessImage, LayerPackMode.fuzz,
                                  generateMips, okA, okB, srgbColor);
        if (t.valid) {
            move(t, outTextures[2]);
            outHas[2] = true;
            maps.fuzz = &outTextures[2];
            params.flags |= MaterialFlags.fuzz;
        }
    }
    if (matDesc.anisotropyImage >= 0 || matDesc.iridescenceThicknessImage >= 0) {
        bool okAniso, okFilm;
        auto t = packLayerTexture(gpu, doc, matDesc.anisotropyImage,
                                  matDesc.iridescenceThicknessImage, LayerPackMode.anisoFilm,
                                  generateMips, okAniso, okFilm);
        if (t.valid) {
            move(t, outTextures[3]);
            outHas[3] = true;
            maps.anisoFilm = &outTextures[3];
            if (okAniso) params.flags |= MaterialFlags.anisotropy;
            if (okFilm) params.flags |= MaterialFlags.thinFilm;
        }
    }
    if (matDesc.transmissionImage >= 0
        || (matDesc.thicknessImage >= 0 && (params.transmissionWeight > 0.0f || params.subsurfaceWeight > 0.0f))
        || matDesc.diffuseTransmissionImage >= 0) {
        bool okA, okB, okC;
        auto t = packLayerTexture(gpu, doc, matDesc.transmissionImage,
                                  matDesc.thicknessImage, LayerPackMode.transmission,
                                  generateMips, okA, okB,
                                  matDesc.diffuseTransmissionImage, okC);
        if (t.valid) {
            move(t, outTextures[4]);
            outHas[4] = true;
            maps.transmission = &outTextures[4];
            if (okA || (okB && params.transmissionWeight > 0.0f)) params.flags |= MaterialFlags.transmission;
            if (okC || (okB && params.subsurfaceWeight > 0.0f)) params.flags |= MaterialFlags.subsurface;
        }
    }
    return maps;
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------

private const(ubyte)[] viewBytes(ref GltfDocument doc, int bvIndex, ref size_t baseOff) @trusted {
    auto bufferViews = doc.root["bufferViews"].array;
    enforce(bvIndex >= 0 && bvIndex < bufferViews.length, "glTF: bufferView index OOB");
    if (doc.meshoptViews.length > bvIndex && doc.meshoptViews[bvIndex].length) {
        baseOff = 0;
        return doc.meshoptViews[bvIndex];
    }
    auto bv = bufferViews[bvIndex];
    immutable size_t bufIdx = cast(size_t) bv["buffer"].integer;
    enforce(bufIdx < doc.buffers.length, "glTF: buffer index OOB");
    baseOff = ("byteOffset" in bv.object) ? cast(size_t) bv["byteOffset"].integer : 0;
    return doc.buffers[bufIdx];
}

private bool isMeshoptView(ref GltfDocument doc, int bvIndex) {
    return doc.meshoptViews.length > bvIndex && doc.meshoptViews[bvIndex].length > 0;
}

/// Read a float VEC2/3/4 accessor (dequantizing normalized integers).
float[] readAccessorFloats(ref GltfDocument doc, int accessorIndex, uint expectedComponents) @trusted {
    auto accessors = doc.root["accessors"].array;
    enforce(accessorIndex >= 0 && accessorIndex < accessors.length, "glTF: accessor index OOB");
    auto acc = accessors[accessorIndex];
    immutable uint ct = cast(uint) acc["componentType"].integer;
    immutable bool normalized = jsonFlag(acc, "normalized");
    immutable string type = acc["type"].str;
    uint comps = 0;
    if (type == "VEC2") comps = 2;
    else if (type == "VEC3") comps = 3;
    else if (type == "VEC4") comps = 4;
    else enforce(false, "glTF: unsupported accessor type " ~ type);
    enforce(comps == expectedComponents, "glTF: accessor component count mismatch");
    immutable size_t count = cast(size_t) acc["count"].integer;
    enforce("bufferView" in acc.object, "glTF: accessors without bufferView (sparse/zero) are unsupported");
    immutable int bvIndex  = cast(int) acc["bufferView"].integer;
    auto bv = doc.root["bufferViews"].array[bvIndex];
    size_t baseOff;
    auto src = viewBytes(doc, bvIndex, baseOff);
    immutable size_t accOff = ("byteOffset" in acc.object) ? cast(size_t) acc["byteOffset"].integer : 0;
    immutable size_t elem = componentSize(ct) * comps;
    enforce(elem > 0, "glTF: unsupported component type");
    immutable size_t stride = ("byteStride" in bv.object) ? cast(size_t) bv["byteStride"].integer : elem;
    enforce(stride >= elem, "glTF: byteStride smaller than the element");
    immutable size_t totalOff = baseOff + accOff;
    enforce(count == 0 || totalOff + (count - 1) * stride + elem <= src.length,
            "glTF: accessor out of buffer bounds");
    auto dst = new float[count * comps];
    if (ct == CT_FLOAT && stride == elem && (cast(size_t)(src.ptr + totalOff)) % 4 == 0) {
        auto fSrc = cast(const(float)*) (src.ptr + totalOff);
        foreach (i; 0 .. count * comps) dst[i] = fSrc[i];
        return dst;
    }
    foreach (v; 0 .. count) {
        size_t at = totalOff + v * stride;
        foreach (c; 0 .. comps) {
            if (ct == CT_FLOAT) {
                uint bits = src[at] | (cast(uint) src[at + 1] << 8) | (cast(uint) src[at + 2] << 16) | (cast(uint) src[at + 3] << 24);
                import engine.meshopt.internal.bits : bitsFloat;
                dst[v * comps + c] = bitsFloat(bits);
                at += 4;
            } else {
                int raw = readComponent(src, at, ct);
                dst[v * comps + c] = dequantizeComponent(raw, ct, normalized);
                at += componentSize(ct);
            }
        }
    }
    return dst;
}

/// Read a SCALAR index accessor (u8/u16/u32) into `uint[]`.
uint[] readAccessorIndices(ref GltfDocument doc, int accessorIndex) @trusted {
    auto accessors = doc.root["accessors"].array;
    enforce(accessorIndex >= 0 && accessorIndex < accessors.length, "glTF: accessor index OOB");
    auto acc = accessors[accessorIndex];
    immutable uint ct = cast(uint) acc["componentType"].integer;
    immutable string type = acc["type"].str;
    enforce(type == "SCALAR", "glTF: indices must be SCALAR");
    immutable size_t count = cast(size_t) acc["count"].integer;
    immutable int bvIndex  = cast(int) acc["bufferView"].integer;
    auto bv = doc.root["bufferViews"].array[bvIndex];
    size_t baseOff;
    auto src = viewBytes(doc, bvIndex, baseOff);
    immutable size_t accOff = ("byteOffset" in acc.object) ? cast(size_t) acc["byteOffset"].integer : 0;
    immutable size_t elem = componentSize(ct);
    immutable size_t stride = ("byteStride" in bv.object && !isMeshoptView(doc, bvIndex))
            ? cast(size_t) bv["byteStride"].integer : elem;
    immutable size_t totalOff = baseOff + accOff;
    enforce(elem > 0, "glTF: unsupported index component type");
    enforce(count == 0 || totalOff + (count - 1) * stride + elem <= src.length,
            "glTF: index accessor out of buffer bounds");
    auto dst = new uint[count];
    if (ct == CT_USHORT || ct == CT_UINT || ct == CT_UBYTE) {
        foreach (i; 0 .. count) {
            size_t at = totalOff + i * stride;
            if (ct == CT_UINT) {
                dst[i] = src[at] | (cast(uint) src[at + 1] << 8) | (cast(uint) src[at + 2] << 16) | (cast(uint) src[at + 3] << 24);
            } else {
                int raw = readComponent(src, at, ct);
                enforce(raw >= 0, "glTF: negative index");
                dst[i] = cast(uint) raw;
            }
        }
    } else {
        enforce(false, "glTF: unsupported index component type");
    }
    return dst;
}

/// `COLOR_0` floats (3 or 4 per vertex, linear) to RGBA8.
package(engine) ubyte[4][] packVertexColors(scope const(float)[] c, uint comps) pure {
    auto dst = new ubyte[4][c.length / comps];
    foreach (i, ref d; dst) {
        d = [255, 255, 255, 255];
        foreach (k; 0 .. comps) {
            immutable v = c[i * comps + k];
            d[k] = v <= 0 ? 0 : v >= 1 ? 255 : cast(ubyte)(v * 255 + 0.5f);
        }
    }
    return dst;
}

/// Geometry of one primitive, exactly as authored (no node transform, no
/// optimization). Non-indexed triangle lists get sequential indices.
GltfMesh readPrimitiveGeometry(ref GltfDocument doc, ref JSONValue prim, bool vertexColors = false) @trusted {
    if ("mode" in prim.object)
        enforce(prim["mode"].integer == 4, "glTF: only TRIANGLES primitives are supported");
    auto attrs = prim["attributes"].object;
    enforce("POSITION" in attrs, "glTF: primitive missing POSITION");
    immutable int posAcc  = cast(int) attrs["POSITION"].integer;
    immutable int normAcc = ("NORMAL"     in attrs) ? cast(int) attrs["NORMAL"].integer     : -1;
    immutable int uvAcc   = ("TEXCOORD_0" in attrs) ? cast(int) attrs["TEXCOORD_0"].integer : -1;
    immutable int tanAcc  = ("TANGENT"    in attrs) ? cast(int) attrs["TANGENT"].integer    : -1;

    auto positions = readAccessorFloats(doc, posAcc, 3);
    immutable size_t vcount = positions.length / 3;
    float[] normals; float[] uvs; float[] tans;
    if (normAcc >= 0) normals = readAccessorFloats(doc, normAcc, 3);
    if (uvAcc   >= 0) uvs     = readAccessorFloats(doc, uvAcc,   2);
    if (tanAcc  >= 0) tans    = readAccessorFloats(doc, tanAcc,  4);
    enforce(normals.length == 0 || normals.length == vcount * 3, "glTF: NORMAL count mismatch");
    enforce(uvs.length == 0 || uvs.length == vcount * 2, "glTF: TEXCOORD_0 count mismatch");

    GltfMesh out_;
    out_.vertices.length = vcount;
    foreach (i; 0 .. vcount) {
        TexVert v;
        v.pos = [positions[i * 3], positions[i * 3 + 1], positions[i * 3 + 2]];
        v.normal = normals.length ? [normals[i * 3], normals[i * 3 + 1], normals[i * 3 + 2]] : [0.0f, 1.0f, 0.0f];
        v.uv = uvs.length ? [uvs[i * 2], uvs[i * 2 + 1]] : [0.0f, 0.0f];
        out_.vertices[i] = v;
    }
    if (vertexColors && "COLOR_0" in attrs) {
        immutable acc = cast(int) attrs["COLOR_0"].integer;
        auto accessors = doc.root["accessors"].array;
        enforce(acc >= 0 && acc < accessors.length, "glTF: accessor index OOB");
        immutable uint comps = accessors[acc]["type"].str == "VEC3" ? 3 : 4;
        auto c = readAccessorFloats(doc, acc, comps);
        enforce(c.length == vcount * comps, "glTF: COLOR_0 count mismatch");
        out_.colors = packVertexColors(c, comps);
    }
    if (tans.length) {
        enforce(tans.length == vcount * 4, "glTF: TANGENT count mismatch");
        out_.tangents.length = vcount;
        foreach (i; 0 .. vcount)
            out_.tangents[i] = [tans[i * 4 + 0], tans[i * 4 + 1], tans[i * 4 + 2], tans[i * 4 + 3]];
    }
    if ("indices" in prim.object) {
        out_.indices = readAccessorIndices(doc, cast(int) prim["indices"].integer);
    } else {
        enforce(vcount % 3 == 0, "glTF: non-indexed primitive vertex count is not a multiple of 3");
        out_.indices = new uint[vcount];
        foreach (i; 0 .. vcount) out_.indices[i] = cast(uint) i;
    }
    foreach (idx; out_.indices)
        enforce(idx < vcount, "glTF: index out of vertex range");
    return out_;
}

// ---------------------------------------------------------------------------
// Scene graph (meshes × primitives × materials × nodes), transforms not baked
// ---------------------------------------------------------------------------

/// One primitive: optimized geometry plus its glTF material index (-1 = default).
struct GltfPrimitiveCpu {
    GltfMesh mesh;
    int material = -1;
}

/// One glTF mesh (a list of primitives).
struct GltfMeshCpu {
    string name;
    GltfPrimitiveCpu[] primitives;
}

/// One glTF node with its local transform kept separate (never baked).
struct GltfNodeCpu {
    string name;
    int parent = -1;
    int[] children;
    /// Local transform (T * R * S, or the authored matrix).
    Mat4 local = Mat4.identity;
    /// Mesh index or -1.
    int mesh = -1;
}

/// Whole-file CPU scene.
struct GltfSceneCpu {
    GltfMeshCpu[] meshes;
    GltfNodeCpu[] nodes;
    /// Root node indices of the default scene (or every parentless node).
    int[] roots;
    GltfMaterialDesc[] materials;
}

/// Parse every mesh, primitive, material and node. Each primitive runs the
/// import-time optimizer (`.meta` settings of `doc.path`) and generates
/// tangents when its material needs them. Node transforms stay in
/// `GltfNodeCpu.local`.
GltfSceneCpu parseGltfScene(ref GltfDocument doc, bool vertexColors = false) @trusted {
    GltfSceneCpu scene;
    auto root = doc.root;

    if ("materials" in root) {
        immutable n = root["materials"].array.length;
        scene.materials.length = n;
        foreach (i; 0 .. n)
            scene.materials[i] = parseGltfMaterialAt(root, i);
    }

    if ("meshes" in root) {
        auto meshes = root["meshes"].array;
        scene.meshes.length = meshes.length;
        foreach (mi, ref m; meshes) {
            if ("name" in m.object) scene.meshes[mi].name = m["name"].str;
            auto prims = m["primitives"].array;
            scene.meshes[mi].primitives.length = prims.length;
            foreach (pi, ref prim; prims) {
                auto p = &scene.meshes[mi].primitives[pi];
                p.material = ("material" in prim.object) ? cast(int) prim["material"].integer : -1;
                enforce(p.material < cast(int) scene.materials.length, "glTF: primitive material index OOB");
                p.mesh = readPrimitiveGeometry(doc, prim, vertexColors);
                auto g = &p.mesh;
                finalizeImportedMesh(doc.path, g.vertices, g.indices, g.shadowIndices, g.tangents, g.colors);
                if (p.material >= 0) {
                    auto md = &scene.materials[p.material];
                    if (md.normalImage >= 0 || md.normalUri.length
                        || md.clearcoatNormalImage >= 0 || md.clearcoatNormalUri.length
                        || md.anisotropyImage >= 0 || md.anisotropyUri.length
                        || md.params.specularAnisotropy != 0.0f)
                        generateMissingTangents(doc.path, g.vertices, g.indices, g.shadowIndices, g.tangents, g.colors);
                }
            }
        }
    }

    if ("nodes" in root) {
        auto nodes = root["nodes"].array;
        scene.nodes.length = nodes.length;
        foreach (ni, ref n; nodes) {
            auto node = &scene.nodes[ni];
            if ("name" in n.object) node.name = n["name"].str;
            node.local = nodeLocalMatrix(n);
            if ("mesh" in n.object) {
                node.mesh = cast(int) n["mesh"].integer;
                enforce(node.mesh >= 0 && node.mesh < cast(int) scene.meshes.length, "glTF: node mesh index OOB");
            }
            if ("children" in n.object) {
                foreach (c; n["children"].array) {
                    immutable ci = cast(int) c.integer;
                    enforce(ci >= 0 && ci < cast(int) nodes.length, "glTF: child index OOB");
                    node.children ~= ci;
                }
            }
        }
        foreach (ni, ref node; scene.nodes) {
            foreach (ci; node.children) {
                enforce(scene.nodes[ci].parent < 0, "glTF: node has two parents");
                scene.nodes[ci].parent = cast(int) ni;
            }
        }
        if ("scenes" in root && root["scenes"].array.length) {
            immutable si = ("scene" in root) ? cast(size_t) root["scene"].integer : 0;
            auto sc = root["scenes"].array[si < root["scenes"].array.length ? si : 0];
            if ("nodes" in sc.object)
                foreach (r; sc["nodes"].array) scene.roots ~= cast(int) r.integer;
        } else {
            foreach (ni, ref node; scene.nodes)
                if (node.parent < 0) scene.roots ~= cast(int) ni;
        }
    } else {
        // No node graph: expose every mesh as a root node at the origin.
        foreach (mi; 0 .. scene.meshes.length) {
            GltfNodeCpu node;
            node.name = scene.meshes[mi].name;
            node.mesh = cast(int) mi;
            scene.nodes ~= node;
            scene.roots ~= cast(int) mi;
        }
    }
    return scene;
}

/// Build a `.glb` container from JSON text and an optional BIN chunk
/// (padding added per spec). Used by tests and tooling.
ubyte[] buildGlb(string json, scope const(ubyte)[] bin = null) @trusted {
    ubyte[] jsonBytes = cast(ubyte[]) json.dup;
    while (jsonBytes.length % 4) jsonBytes ~= ' ';
    ubyte[] binBytes = bin.dup;
    while (binBytes.length % 4) binBytes ~= 0;
    void put32(ref ubyte[] o, uint v) {
        o ~= cast(ubyte)(v & 0xFF);
        o ~= cast(ubyte)((v >> 8) & 0xFF);
        o ~= cast(ubyte)((v >> 16) & 0xFF);
        o ~= cast(ubyte)(v >> 24);
    }
    immutable total = 12 + 8 + jsonBytes.length + (binBytes.length ? 8 + binBytes.length : 0);
    ubyte[] o;
    put32(o, GLB_MAGIC);
    put32(o, 2);
    put32(o, cast(uint) total);
    put32(o, cast(uint) jsonBytes.length);
    put32(o, GLB_CHUNK_JSON);
    o ~= jsonBytes;
    if (binBytes.length) {
        put32(o, cast(uint) binBytes.length);
        put32(o, GLB_CHUNK_BIN);
        o ~= binBytes;
    }
    return o;
}

private Mat4 nodeLocalMatrix(ref JSONValue node) @trusted {
    if ("matrix" in node.object) {
        auto arr = node["matrix"].array;
        enforce(arr.length == 16, "glTF: node matrix must have 16 elements");
        Mat4 m;
        foreach (i; 0 .. 16)
            m.m[i] = jsonFloat(arr[i]);
        return m;
    }
    Vec3 t = Vec3(0, 0, 0);
    Quat r = Quat.identity();
    Vec3 s = Vec3(1, 1, 1);
    if ("translation" in node.object) {
        auto a = node["translation"].array;
        if (a.length >= 3)
            t = Vec3(jsonFloat(a[0]), jsonFloat(a[1]), jsonFloat(a[2]));
    }
    if ("rotation" in node.object) {
        auto a = node["rotation"].array;
        if (a.length >= 4)
            r = Quat(jsonFloat(a[0]), jsonFloat(a[1]), jsonFloat(a[2]), jsonFloat(a[3]));
    }
    if ("scale" in node.object) {
        auto a = node["scale"].array;
        if (a.length >= 3)
            s = Vec3(jsonFloat(a[0]), jsonFloat(a[1]), jsonFloat(a[2]));
    }
    // glTF: T * R * S.
    return Mat4.translation(t.x, t.y, t.z) * r.toMat4() * Mat4.scaling(s.x, s.y, s.z);
}

/// World matrix of the first node that instances mesh 0, including parents.
/// Identity when the file has no such node (the mesh is used as authored).
private Mat4 meshNodeWorld(ref JSONValue root) @trusted {
    if ("nodes" !in root)
        return Mat4.identity;
    auto nodes = root["nodes"].array;
    if (nodes.length == 0)
        return Mat4.identity;
    int[] parent;
    parent.length = nodes.length;
    parent[] = -1;
    int meshNode = -1;
    foreach (i, ref n; nodes) {
        if ("children" in n.object) {
            foreach (c; n["children"].array) {
                int ci = cast(int) c.integer;
                if (ci >= 0 && ci < cast(int) parent.length)
                    parent[ci] = cast(int) i;
            }
        }
        if (meshNode < 0 && "mesh" in n.object && cast(int) n["mesh"].integer == 0)
            meshNode = cast(int) i;
    }
    if (meshNode < 0)
        return Mat4.identity;
    int[] chain;
    int guard = 0;
    for (int i = meshNode; i >= 0 && guard < cast(int) nodes.length; i = parent[i], ++guard)
        chain ~= i;
    Mat4 world = Mat4.identity;
    for (int k = cast(int) chain.length - 1; k >= 0; --k)
        world = world * nodeLocalMatrix(nodes[chain[k]]);
    return world;
}

private Vec3 transformNormal(Mat4 invWorld, Vec3 n) pure nothrow @nogc {
    float x = invWorld.m[0] * n.x + invWorld.m[1] * n.y + invWorld.m[2] * n.z;
    float y = invWorld.m[4] * n.x + invWorld.m[5] * n.y + invWorld.m[6] * n.z;
    float z = invWorld.m[8] * n.x + invWorld.m[9] * n.y + invWorld.m[10] * n.z;
    Vec3 r = Vec3(x, y, z);
    float len2 = r.x * r.x + r.y * r.y + r.z * r.z;
    if (len2 <= 0)
        return Vec3(0, 1, 0);
    float inv = 1.0f / sqrt(len2);
    return Vec3(r.x * inv, r.y * inv, r.z * inv);
}

/// Parse a `.gltf`/`.glb` file and return its first primitive as CPU geometry,
/// with the first instancing node's world transform baked into the vertices.
GltfMesh parseGltfMesh(string gltfPath, bool vertexColors = false) @trusted {
    auto doc = parseGltfDocument(gltfPath);
    return parseFirstMesh(doc, vertexColors);
}

private GltfMesh parseFirstMesh(ref GltfDocument doc, bool vertexColors = false) @trusted {
    enforce("meshes" in doc.root, "glTF: no meshes");
    auto meshes = doc.root["meshes"].array;
    enforce(meshes.length > 0, "glTF: empty meshes array");
    auto primitives = meshes[0]["primitives"].array;
    enforce(primitives.length > 0, "glTF: no primitives in first mesh");
    auto prim = primitives[0];
    immutable hasNormals = ("NORMAL" in prim["attributes"].object) !is null;

    GltfMesh out_ = readPrimitiveGeometry(doc, prim, vertexColors);
    Mat4 world = meshNodeWorld(doc.root);
    Mat4 ident = Mat4.identity;
    if (world.m != ident.m) {
        Mat4 inv = world.inverse();
        foreach (ref v; out_.vertices) {
            Vec4 p = world * Vec4(v.pos[0], v.pos[1], v.pos[2], 1);
            v.pos = [p.x, p.y, p.z];
            if (hasNormals) {
                Vec3 n = transformNormal(inv, Vec3(v.normal[0], v.normal[1], v.normal[2]));
                v.normal = [n.x, n.y, n.z];
            }
        }
        foreach (ref t; out_.tangents) {
            Vec3 n = transformNormal(inv, Vec3(t[0], t[1], t[2]));
            t[0] = n.x;
            t[1] = n.y;
            t[2] = n.z;
        }
    }
    finalizeImportedMesh(doc.path, out_.vertices, out_.indices, out_.shadowIndices, out_.tangents, out_.colors);
    return out_;
}

@trusted unittest {
    import std.file : mkdirRecurse, write, rmdirRecurse;
    import std.path : buildPath;

    // Three positions, triangle 0,1,2. Vertex codec v1 level 2, index codec v1.
    float[9] pos = [0, 0, 0, 1, 0, 0, 0, 1, 0];
    float[9] nrm = [0, 0, 1, 0, 0, 1, 0, 0, 1];
    ubyte[] posBytes = new ubyte[9 * 4];
    ubyte[] nrmBytes = new ubyte[9 * 4];
    foreach (i; 0 .. 9) {
        import engine.meshopt.internal.bits : floatBits;
        uint pb = floatBits(pos[i]);
        uint nb = floatBits(nrm[i]);
        foreach (b; 0 .. 4) {
            posBytes[i * 4 + b] = cast(ubyte)(pb >> (8 * b));
            nrmBytes[i * 4 + b] = cast(ubyte)(nb >> (8 * b));
        }
    }
    ubyte[] penc = new ubyte[encodeVertexBufferBound(3, 12)];
    ubyte[] nenc = new ubyte[encodeVertexBufferBound(3, 12)];
    size_t pn = encodeVertexBuffer(penc, posBytes, 3, 12);
    size_t nn = encodeVertexBuffer(nenc, nrmBytes, 3, 12);
    uint[3] idx = [0, 1, 2];
    ubyte[] ienc = new ubyte[encodeIndexBufferBound(3, 3)];
    size_t in_ = encodeIndexBuffer(ienc, idx[], 1);
    ubyte[] bin;
    bin ~= penc[0 .. pn];
    size_t nOff = bin.length;
    bin ~= nenc[0 .. nn];
    size_t iOff = bin.length;
    bin ~= ienc[0 .. in_];

    string dir = "/tmp/meshopt-gltf-m7";
    mkdirRecurse(dir);
    write(buildPath(dir, "mesh.bin"), bin);
    string gltf = `{
      "asset":{"version":"2.0"},
      "extensionsUsed":["EXT_meshopt_compression","KHR_mesh_quantization"],
      "buffers":[{"uri":"mesh.bin","byteLength":` ~ bin.length.to!string ~ `}],
      "bufferViews":[
        {"buffer":0,"byteOffset":0,"byteLength":4,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteOffset":0,"byteLength":` ~ pn.to!string ~ `,"byteStride":12,"count":3,"mode":"ATTRIBUTES","filter":"NONE"}}},
        {"buffer":0,"byteOffset":0,"byteLength":4,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteOffset":` ~ nOff.to!string ~ `,"byteLength":` ~ nn.to!string ~ `,"byteStride":12,"count":3,"mode":"ATTRIBUTES","filter":"NONE"}}},
        {"buffer":0,"byteOffset":0,"byteLength":4,"extensions":{"EXT_meshopt_compression":{"buffer":0,"byteOffset":` ~ iOff.to!string ~ `,"byteLength":` ~ in_.to!string ~ `,"byteStride":4,"count":3,"mode":"TRIANGLES","filter":"NONE"}}}
      ],
      "accessors":[
        {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
        {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
        {"bufferView":2,"componentType":5125,"count":3,"type":"SCALAR"}
      ],
      "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1},"indices":2}]}],
      "nodes":[{"mesh":0,"translation":[10,20,30],"scale":[2,2,2]}]
    }`;
    write(buildPath(dir, "mesh.gltf"), gltf);
    auto mesh = parseGltfMesh(buildPath(dir, "mesh.gltf"));
    assert(mesh.indices == [0, 1, 2]);
    assert(mesh.vertices.length == 3);
    // T * S on (0,0,0), (1,0,0), (0,1,0) → (10,20,30), (12,20,30), (10,22,30)
    assert(mesh.vertices[0].pos[0] > 9.9f && mesh.vertices[0].pos[0] < 10.1f);
    assert(mesh.vertices[1].pos[0] > 11.9f && mesh.vertices[1].pos[0] < 12.1f);
    assert(mesh.vertices[2].pos[1] > 21.9f && mesh.vertices[2].pos[1] < 22.1f);
    assert(mesh.vertices[0].normal[2] > 0.9f);

    // KHR_mesh_quantization: ushort positions normalized, node scale bakes them back.
    ushort[9] qpos = [0, 0, 0, 65535, 0, 0, 0, 65535, 0];
    ubyte[] qbin = cast(ubyte[]) qpos.dup;
    ushort[3] qidx = [0, 1, 2];
    qbin ~= cast(ubyte[]) qidx.dup;
    write(buildPath(dir, "q.bin"), qbin);
    string qgltf = `{
      "asset":{"version":"2.0"},
      "extensionsUsed":["KHR_mesh_quantization"],
      "buffers":[{"uri":"q.bin","byteLength":` ~ qbin.length.to!string ~ `}],
      "bufferViews":[
        {"buffer":0,"byteOffset":0,"byteLength":18},
        {"buffer":0,"byteOffset":18,"byteLength":6}
      ],
      "accessors":[
        {"bufferView":0,"componentType":5123,"normalized":true,"count":3,"type":"VEC3"},
        {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
      ],
      "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}],
      "nodes":[{"mesh":0,"translation":[10,20,30],"scale":[2,2,2]}]
    }`;
    write(buildPath(dir, "q.gltf"), qgltf);
    auto qmesh = parseGltfMesh(buildPath(dir, "q.gltf"));
    assert(qmesh.indices == [0, 1, 2]);
    assert(qmesh.vertices[0].pos[0] > 9.9f && qmesh.vertices[0].pos[0] < 10.1f);
    assert(qmesh.vertices[1].pos[0] > 11.9f && qmesh.vertices[1].pos[0] < 12.1f);
    assert(qmesh.vertices[2].pos[1] > 21.9f && qmesh.vertices[2].pos[1] < 22.1f);
    rmdirRecurse(dir);
}

@safe unittest {
    string extGltf = `{
      "asset": {"version": "2.0"},
      "materials": [{
        "pbrMetallicRoughness": {
          "baseColorFactor": [0.2, 0.4, 0.8, 0.9],
          "metallicFactor": 0.25,
          "roughnessFactor": 0.6
        },
        "emissiveFactor": [1.0, 0.5, 0.1],
        "extensions": {
          "KHR_materials_ior": { "ior": 1.75 },
          "KHR_materials_specular": { "specularFactor": 0.85, "specularColorFactor": [0.9, 0.8, 0.7] },
          "KHR_materials_clearcoat": { "clearcoatFactor": 0.9, "clearcoatRoughnessFactor": 0.05 },
          "KHR_materials_sheen": { "sheenColorFactor": [0.6, 0.2, 0.8], "sheenRoughnessFactor": 0.35 },
          "KHR_materials_iridescence": { "iridescenceFactor": 0.7, "iridescenceIor": 1.33, "iridescenceThicknessMaximum": 620.0 },
          "KHR_materials_emissive_strength": { "emissiveStrength": 4.5 },
          "KHR_materials_anisotropy": { "anisotropyStrength": 0.55 }
        }
      }]
    }`;

    auto desc = parseGltfMaterialJson(extGltf);
    assert(desc.hasBaseColorFactor);
    assert(desc.params.baseColor[0] > 0.19f && desc.params.baseColor[0] < 0.21f);
    assert(desc.params.geometryOpacity > 0.89f && desc.params.geometryOpacity < 0.91f);
    assert(desc.params.baseMetalness == 0.25f);
    assert(desc.params.specularRoughness == 0.6f);
    assert(desc.params.specularIor == 1.75f);
    assert(desc.params.specularWeight == 0.85f);
    assert(desc.params.specularColor[1] > 0.79f && desc.params.specularColor[1] < 0.81f);
    assert(desc.params.coatWeight == 0.9f);
    assert(desc.params.coatRoughness == 0.05f);
    assert(desc.params.fuzzWeight == 1.0f);
    assert(desc.params.fuzzColor[2] > 0.79f && desc.params.fuzzColor[2] < 0.81f);
    assert(desc.params.fuzzRoughness == 0.35f);
    assert(desc.params.thinFilmWeight == 0.7f);
    assert(desc.params.thinFilmIor == 1.33f);
    assert(desc.params.thinFilmThickness == 620.0f);
    assert(desc.params.emissionLuminance == 4.5f);
    assert(desc.params.specularAnisotropy == 0.55f);
}

version (unittest) {
    /// Little-endian bytes of a POD array.
    private ubyte[] leBytes(T)(const(T)[] values) @trusted {
        return (cast(const(ubyte)[]) values).dup;
    }

    /// Two meshes / three primitives / two materials / three nodes, one BIN
    /// chunk carrying geometry plus an embedded "PNG" image bufferView.
    package(engine) ubyte[] makeTestVehicleGlb() @trusted {
        float[9] pos = [0, 0, 0, 1, 0, 0, 0, 1, 0];
        ushort[4] idx = [0, 1, 2, 0]; // 3 indices + pad to 4-byte alignment
        ubyte[8] fakeImage = [0x89, 'P', 'N', 'G', 1, 2, 3, 4];
        ubyte[] bin = leBytes(pos[]) ~ leBytes(idx[]) ~ fakeImage[].dup;
        string json = `{
          "asset":{"version":"2.0"},
          "scene":0,
          "scenes":[{"nodes":[0]}],
          "buffers":[{"byteLength":` ~ bin.length.to!string ~ `}],
          "bufferViews":[
            {"buffer":0,"byteOffset":0,"byteLength":36},
            {"buffer":0,"byteOffset":36,"byteLength":6},
            {"buffer":0,"byteOffset":44,"byteLength":8}
          ],
          "accessors":[
            {"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
            {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}
          ],
          "images":[{"bufferView":2,"mimeType":"image/png"}],
          "textures":[{"source":0}],
          "materials":[
            {"name":"paint","pbrMetallicRoughness":{"baseColorTexture":{"index":0},"metallicFactor":0.5}},
            {"name":"glass","pbrMetallicRoughness":{"baseColorFactor":[1,0,0,0.5],"roughnessFactor":0.1}}
          ],
          "meshes":[
            {"name":"body","primitives":[
              {"attributes":{"POSITION":0},"indices":1,"material":0},
              {"attributes":{"POSITION":0},"indices":1,"material":1}]},
            {"name":"door","primitives":[{"attributes":{"POSITION":0},"indices":1}]}
          ],
          "nodes":[
            {"name":"body","mesh":0,"translation":[0,1,0],"children":[1]},
            {"name":"door_fl","mesh":1,"translation":[1,0,0],"children":[2]},
            {"name":"handle","scale":[2,2,2]}
          ]
        }`;
        return buildGlb(json, bin);
    }
}

@("gltf.fileDependencies") @trusted unittest {
    import std.algorithm.searching : canFind;
    auto deps = gltfFileDependencies("assets/models/pbr_cube.gltf");
    assert(deps[0] == "assets/models/pbr_cube.gltf");
    assert(deps.canFind("assets/models/pbr_cube.gltf.meta"));
    assert(deps.canFind("assets/models/pbr_cube.bin"));
    assert(deps.canFind("assets/models/pbr_cube_albedo.bmp"));
    // Unparseable / missing documents still report themselves.
    assert(gltfFileDependencies("build/no_such_model.gltf").length == 2);
}

@("gltf.glbScene") @trusted unittest {
    auto glb = makeTestVehicleGlb();
    assert(isGlb(glb));
    auto doc = parseGltfDocumentBytes(glb, "/nonexistent-dir");
    assert(doc.buffers.length == 1 && doc.buffers[0].length == 52);

    auto scene = parseGltfScene(doc);
    assert(scene.meshes.length == 2);
    assert(scene.meshes[0].name == "body" && scene.meshes[0].primitives.length == 2);
    assert(scene.meshes[0].primitives[0].material == 0);
    assert(scene.meshes[0].primitives[1].material == 1);
    assert(scene.meshes[1].primitives[0].material == -1);
    assert(scene.meshes[1].primitives[0].mesh.indices.length == 3);

    // Node transforms are kept, never baked into the vertices.
    auto door = scene.meshes[1].primitives[0].mesh;
    float maxX = -1;
    foreach (v; door.vertices) if (v.pos[0] > maxX) maxX = v.pos[0];
    assert(maxX > 0.99f && maxX < 1.01f);

    assert(scene.nodes.length == 3 && scene.roots == [0]);
    assert(scene.nodes[0].name == "body" && scene.nodes[0].parent == -1 && scene.nodes[0].mesh == 0);
    assert(scene.nodes[1].name == "door_fl" && scene.nodes[1].parent == 0 && scene.nodes[1].mesh == 1);
    assert(scene.nodes[2].parent == 1 && scene.nodes[2].mesh == -1);
    assert(scene.nodes[0].local.m[13] == 1.0f);
    assert(scene.nodes[1].local.m[12] == 1.0f);
    assert(scene.nodes[2].local.m[0] == 2.0f);

    // Materials: embedded image reference, per-index factors.
    assert(scene.materials.length == 2);
    assert(scene.materials[0].baseColorImage == 0 && scene.materials[0].baseColorUri.length == 0);
    assert(scene.materials[0].params.baseMetalness == 0.5f);
    assert(scene.materials[1].baseColorImage == -1);
    assert(scene.materials[1].params.baseColor[0] == 1.0f && scene.materials[1].params.geometryOpacity == 0.5f);

    auto img = resolveGltfImage(doc, 0);
    assert(img.uri.length == 0 && img.mimeType == "image/png");
    assert(img.bytes.length == 8 && img.bytes[1] == 'P');
}

@("gltf.dataUriBuffer") @trusted unittest {
    import std.base64 : Base64;
    float[9] pos = [0, 0, 0, 2, 0, 0, 0, 2, 0];
    auto b64 = Base64.encode(leBytes(pos[]));
    string json = `{"asset":{"version":"2.0"},
      "buffers":[{"uri":"data:application/octet-stream;base64,` ~ cast(string) b64 ~ `","byteLength":36}],
      "bufferViews":[{"buffer":0,"byteLength":36}],
      "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],
      "meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}]}`;
    auto doc = parseGltfDocumentBytes(cast(const(ubyte)[]) json, ".");
    assert(!isGlb(cast(const(ubyte)[]) json));
    auto scene = parseGltfScene(doc);
    // No node graph: each mesh becomes a root node; non-indexed gets 0,1,2.
    assert(scene.nodes.length == 1 && scene.roots == [0] && scene.nodes[0].mesh == 0);
    auto g = scene.meshes[0].primitives[0].mesh;
    assert(g.indices.length == 3);
    float maxX = -1;
    foreach (v; g.vertices) if (v.pos[0] > maxX) maxX = v.pos[0];
    assert(maxX == 2.0f);
}

@("gltf.alphaMode") @safe unittest {
    import std.json : parseJSON;
    auto root = parseJSON(`{"materials": [
        {"name": "leaf", "alphaMode": "MASK", "alphaCutoff": 0.3, "doubleSided": true},
        {"name": "glass", "alphaMode": "BLEND"},
        {"name": "wall"}
    ]}`);
    auto leaf = parseGltfMaterialAt(root, 0), glass = parseGltfMaterialAt(root, 1), wall = parseGltfMaterialAt(root, 2);
    assert(leaf.alphaMode == GltfAlphaMode.mask && leaf.params.alphaCutoff == 0.3f);
    assert(glass.alphaMode == GltfAlphaMode.blend && wall.alphaMode == GltfAlphaMode.opaque);
    assert(wall.params.alphaCutoff == 0.5f);

    // Off by default: only doubleSided applies.
    GltfImportOptions off;
    assert(gltfRenderState(leaf, off) == RenderState(BlendMode.alpha, true, true));
    assert(gltfBaseColorDesc(leaf, off, true).alphaCoverage == 0);
    GltfImportOptions on;
    on.alphaModes = true;
    assert(gltfRenderState(leaf, on) == RenderState(BlendMode.opaque, true, true, true));
    assert(gltfRenderState(glass, on) == RenderState.init);
    assert(gltfRenderState(wall, on) == RenderState(BlendMode.opaque));
    assert(gltfBaseColorDesc(leaf, on, true).alphaCoverage == 0.3f);
}

@("gltf.doubleSidedAndName") @safe unittest {
    import std.json : parseJSON;

    string json = `{
      "asset": {"version": "2.0"},
      "materials": [
        {"name": "wire_fence", "doubleSided": true, "pbrMetallicRoughness": {"baseColorFactor": [1, 1, 1, 1]}},
        {"name": "concrete", "pbrMetallicRoughness": {"baseColorFactor": [0.5, 0.5, 0.5, 1]}}
      ]
    }`;
    auto root = parseJSON(json);
    auto m0 = parseGltfMaterialAt(root, 0);
    auto m1 = parseGltfMaterialAt(root, 1);
    assert(m0.name == "wire_fence" && m0.doubleSided == true);
    assert(m1.name == "concrete" && m1.doubleSided == false);
}

@("gltf.opbr6And7Extensions") @safe unittest {
    import std.math : abs;

    string gltf = `{
      "asset": {"version": "2.0"},
      "images": [
        {"uri": "cc.png"},
        {"uri": "cc_rough.png"},
        {"uri": "cc_nrm.png"},
        {"uri": "sheen_col.png"},
        {"uri": "sheen_rough.png"},
        {"uri": "aniso.png"},
        {"uri": "irid_thick.png"},
        {"uri": "trans.png"},
        {"uri": "thick.png"}
      ],
      "textures": [
        {"source": 0}, {"source": 1}, {"source": 2},
        {"source": 3}, {"source": 4}, {"source": 5},
        {"source": 6}, {"source": 7}, {"source": 8}
      ],
      "materials": [{
        "name": "opbr_glass_velvet",
        "pbrMetallicRoughness": {"baseColorFactor": [0.9, 0.95, 1.0, 1.0], "roughnessFactor": 0.15},
        "extensions": {
          "KHR_materials_ior": {"ior": 1.52},
          "KHR_materials_clearcoat": {
            "clearcoatFactor": 0.8,
            "clearcoatRoughnessFactor": 0.12,
            "clearcoatTexture": {"index": 0},
            "clearcoatRoughnessTexture": {"index": 1},
            "clearcoatNormalTexture": {"index": 2}
          },
          "KHR_materials_sheen": {
            "sheenColorFactor": [0.4, 0.6, 0.9],
            "sheenRoughnessFactor": 0.45,
            "sheenColorTexture": {"index": 3},
            "sheenRoughnessTexture": {"index": 4}
          },
          "KHR_materials_anisotropy": {
            "anisotropyStrength": 0.7,
            "anisotropyRotation": 0.785398,
            "anisotropyTexture": {"index": 5}
          },
          "KHR_materials_iridescence": {
            "iridescenceFactor": 0.65,
            "iridescenceIor": 1.38,
            "iridescenceThicknessMinimum": 220.0,
            "iridescenceThicknessMaximum": 680.0,
            "iridescenceThicknessTexture": {"index": 6}
          },
          "KHR_materials_transmission": {
            "transmissionFactor": 0.92,
            "transmissionTexture": {"index": 7}
          },
          "KHR_materials_volume": {
            "thicknessFactor": 1.4,
            "attenuationDistance": 2.5,
            "attenuationColor": [0.2, 0.85, 0.6],
            "thicknessTexture": {"index": 8}
          },
          "KHR_materials_dispersion": {
            "dispersion": 0.6
          }
        }
      }]
    }`;

    auto desc = parseGltfMaterialJson(gltf);
    assert(desc.clearcoatImage == 0 && desc.clearcoatUri == "cc.png");
    assert(desc.clearcoatRoughnessImage == 1 && desc.clearcoatRoughnessUri == "cc_rough.png");
    assert(desc.clearcoatNormalImage == 2 && desc.clearcoatNormalUri == "cc_nrm.png");
    assert(desc.sheenColorImage == 3 && desc.sheenColorUri == "sheen_col.png");
    assert(desc.sheenRoughnessImage == 4 && desc.sheenRoughnessUri == "sheen_rough.png");
    assert(desc.anisotropyImage == 5 && desc.anisotropyUri == "aniso.png");
    assert(desc.iridescenceThicknessImage == 6 && desc.iridescenceThicknessUri == "irid_thick.png");
    assert(desc.transmissionImage == 7 && desc.transmissionUri == "trans.png");
    assert(desc.thicknessImage == 8 && desc.thicknessUri == "thick.png");

    assert(abs(desc.params.anisotropyRotation - 0.785398f) < 1e-4f);
    assert(desc.params.thinFilmThicknessMin == 220.0f);
    assert(desc.params.thinFilmThickness == 680.0f);
    assert(abs(desc.params.transmissionWeight - 0.92f) < 1e-4f);
    assert(abs(desc.params.transmissionThickness - 1.4f) < 1e-4f);
    assert(abs(desc.params.transmissionDepth - 2.5f) < 1e-4f);
    assert(abs(desc.params.transmissionColor[1] - 0.85f) < 1e-4f);
    assert(abs(desc.params.transmissionDispersion - 0.6f) < 1e-4f);
}

@("gltf.opbr8DiffuseTransmission") @safe unittest {
    import std.math : abs;

    string foliageGltf = `{
      "asset": {"version": "2.0"},
      "images": [{"uri": "leaf_dt.png"}],
      "textures": [{"source": 0}],
      "materials": [{
        "name": "foliage",
        "extensions": {
          "KHR_materials_diffuse_transmission": {
            "diffuseTransmissionFactor": 0.65,
            "diffuseTransmissionColorFactor": [0.35, 0.85, 0.2],
            "diffuseTransmissionTexture": {"index": 0}
          }
        }
      }]
    }`;
    auto leaf = parseGltfMaterialJson(foliageGltf);
    assert(abs(leaf.params.subsurfaceWeight - 0.65f) < 1e-4f);
    assert(abs(leaf.params.subsurfaceColor[1] - 0.85f) < 1e-4f);
    assert(leaf.diffuseTransmissionImage == 0 && leaf.diffuseTransmissionUri == "leaf_dt.png");
    assert((leaf.params.flags & MaterialFlags.thinWalled) != 0);

    string waxGltf = `{
      "asset": {"version": "2.0"},
      "materials": [{
        "name": "wax",
        "extensions": {
          "KHR_materials_volume": {"thicknessFactor": 0.5, "attenuationDistance": 0.8},
          "KHR_materials_diffuse_transmission": {
            "diffuseTransmissionFactor": 0.9,
            "diffuseTransmissionColorFactor": [1.0, 0.7, 0.45]
          }
        }
      }]
    }`;
    auto wax = parseGltfMaterialJson(waxGltf);
    assert((wax.params.flags & MaterialFlags.thinWalled) == 0);
    assert(abs(wax.params.subsurfaceWeight - 0.9f) < 1e-4f);
    assert(abs(wax.params.subsurfaceRadius - 0.8f) < 1e-4f);
}

@("gltf.vertexColors") @trusted unittest {
    // COLOR_0 as normalized ubyte VEC4 and as float VEC3, only when asked for.
    float[9] pos = [0, 0, 0, 1, 0, 0, 0, 1, 0];
    float[9] rgb = [1, 0.5f, 0, 0, 1, 2, 0.25f, -1, 1];
    ubyte[12] rgba = [255, 0, 0, 255, 0, 128, 0, 64, 0, 0, 255, 0];
    ubyte[] bin = leBytes(pos[]) ~ leBytes(rgb[]) ~ rgba[].dup;
    foreach (fl; [false, true]) {
        string json = `{"asset":{"version":"2.0"},"buffers":[{"byteLength":` ~ bin.length.to!string ~ `}],
          "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36},
                         {"buffer":0,"byteOffset":72,"byteLength":12}],
          "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"},
                       {"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"},
                       {"bufferView":2,"componentType":5121,"normalized":true,"count":3,"type":"VEC4"}],
          "meshes":[{"primitives":[{"attributes":{"POSITION":0,"COLOR_0":` ~ (fl ? "1" : "2") ~ `}}]}],
          "nodes":[{"mesh":0}]}`;
        auto doc = parseGltfDocumentBytes(buildGlb(json, bin), "/nonexistent-dir");
        assert(parseGltfScene(doc).meshes[0].primitives[0].mesh.colors.length == 0);
        auto m = parseGltfScene(doc, true).meshes[0].primitives[0].mesh;
        assert(m.colors.length == m.vertices.length && m.colors.length == 3);
        foreach (i, v; m.vertices) {
            immutable ubyte[4] want = v.pos[0] > 0.5f ? (fl ? [ubyte(0), ubyte(255), ubyte(255), ubyte(255)] : [ubyte(0), ubyte(128), ubyte(0), ubyte(64)])
                : v.pos[1] > 0.5f ? (fl ? [ubyte(64), ubyte(0), ubyte(255), ubyte(255)] : [ubyte(0), ubyte(0), ubyte(255), ubyte(0)])
                : (fl ? [ubyte(255), ubyte(128), ubyte(0), ubyte(255)] : [ubyte(255), ubyte(0), ubyte(0), ubyte(255)]);
            assert(m.colors[i] == want);
        }
    }
}
