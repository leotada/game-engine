/// Minimal glTF 2.0 loader — mesh geometry + optional pbrMetallicRoughness materials.
///
/// Supported:
///   - .gltf JSON + external .bin buffer (same directory)
///   - Component types: 5123 (u16), 5125 (u32 → downcast to u16 if in range)
///   - Attribute types: VEC3 positions/normals, VEC2 uvs (float32)
///   - Materials: pbrMetallicRoughness factors + baseColor / MR / normal /
///     occlusion / emissive textures (BMP or TGA via engine loaders)
///
/// NOT supported: .glb containers, embedded base64 buffers, animations,
/// skinning, multiple primitives.
module engine.assets.gltf;

import std.conv : to;
import std.exception : enforce;
import std.file : read, exists;
import std.json;
import std.path : dirName, buildPath, extension;
import std.string : toLower;

import engine.core.log;
import engine.gpu.context : GpuContext;
import engine.graphics.material : Material, MaterialParams, MaterialFlags;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Texture, Sampler;
import engine.graphics.types : TexVert;
import bindings.wgpu : WGPUBindGroupLayout;

@safe:

private enum uint CT_UBYTE  = 5121;
private enum uint CT_USHORT = 5123;
private enum uint CT_UINT   = 5125;
private enum uint CT_FLOAT  = 5126;

/// Load the first primitive of the first mesh from a .gltf file and
/// upload it as a TexMesh.
TexMesh loadGltfMesh(ref GpuContext gpu, string gltfPath) @trusted {
    auto mesh = parseGltfMesh(gltfPath);
    info("Loaded glTF: ", gltfPath, " (",
         mesh.vertices.length, " verts, ", mesh.indices.length, " indices)");
    return TexMesh.fromData(gpu, mesh.vertices, mesh.indices);
}

/// Parsed glTF mesh on the CPU (no GPU resources yet).
struct GltfMesh {
    TexVert[] vertices;
    ushort[]  indices;
}

/// CPU-side PBR material description extracted from glTF.
struct GltfMaterialDesc {
    float[4] baseColorFactor = [1, 1, 1, 1];
    float metallic = 1;
    float roughness = 1;
    string baseColorUri;       // relative to glTF, empty if none
    string metallicRoughnessUri;
    string normalUri;
    string occlusionUri;
    string emissiveUri;
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
    bool hasAlbedo;
    bool hasMR;
    bool hasNormal;
    bool hasOcclusion;
    bool hasEmissive;

    void destroy() {
        material.destroy();
        mesh.destroy();
        if (hasAlbedo) albedo.destroy();
        if (hasMR) metallicRoughness.destroy();
        if (hasNormal) normal.destroy();
        if (hasOcclusion) occlusion.destroy();
        if (hasEmissive) emissive.destroy();
    }
}

/// Load mesh + PBR material from a .gltf file.
/// Creates GPU textures for referenced images (BMP/TGA). Missing maps fall back
/// to MaterialDefaults via Material.create.
GltfModel loadGltfPbr(ref GpuContext gpu, string gltfPath,
                      WGPUBindGroupLayout materialLayout,
                      ref Sampler sampler) @trusted {
    import core.lifetime : move;

    auto meshCpu = parseGltfMesh(gltfPath);
    auto matDesc = parseGltfMaterial(gltfPath);
    immutable baseDir = dirName(gltfPath);

    GltfModel model;
    model.mesh = TexMesh.fromData(gpu, meshCpu.vertices, meshCpu.indices);

    MaterialParams params;
    params.baseColorFactor = matDesc.baseColorFactor;
    params.metallic = matDesc.metallic;
    params.roughness = matDesc.roughness;
    params.flags = MaterialFlags.none;

    if (matDesc.baseColorUri.length) {
        auto t = loadImageTexture(gpu, buildPath(baseDir, matDesc.baseColorUri));
        if (t.valid) {
            model.albedo = move(t);
            model.hasAlbedo = true;
        }
    }
    if (!model.hasAlbedo) {
        model.albedo = Texture.solid(gpu,
            toU8(matDesc.baseColorFactor[0]),
            toU8(matDesc.baseColorFactor[1]),
            toU8(matDesc.baseColorFactor[2]),
            toU8(matDesc.baseColorFactor[3]));
        model.hasAlbedo = true;
        params.baseColorFactor = [1, 1, 1, 1];
    }

    Texture* mrPtr = null;
    Texture* nrmPtr = null;
    Texture* aoPtr = null;
    Texture* emPtr = null;

    if (matDesc.metallicRoughnessUri.length) {
        auto t = loadImageTexture(gpu, buildPath(baseDir, matDesc.metallicRoughnessUri));
        if (t.valid) {
            model.metallicRoughness = move(t);
            model.hasMR = true;
            mrPtr = &model.metallicRoughness;
            params.flags |= MaterialFlags.metallicRoughness;
        }
    }
    if (matDesc.normalUri.length) {
        auto t = loadImageTexture(gpu, buildPath(baseDir, matDesc.normalUri));
        if (t.valid) {
            model.normal = move(t);
            model.hasNormal = true;
            nrmPtr = &model.normal;
            params.flags |= MaterialFlags.normal;
        }
    }
    if (matDesc.occlusionUri.length) {
        auto t = loadImageTexture(gpu, buildPath(baseDir, matDesc.occlusionUri));
        if (t.valid) {
            model.occlusion = move(t);
            model.hasOcclusion = true;
            aoPtr = &model.occlusion;
            params.flags |= MaterialFlags.occlusion;
        }
    }
    if (matDesc.emissiveUri.length) {
        auto t = loadImageTexture(gpu, buildPath(baseDir, matDesc.emissiveUri));
        if (t.valid) {
            model.emissive = move(t);
            model.hasEmissive = true;
            emPtr = &model.emissive;
            params.flags |= MaterialFlags.emissive;
        }
    }

    model.material = Material.create(gpu, materialLayout, sampler, model.albedo,
                                     params, mrPtr, nrmPtr, aoPtr, emPtr);

    info("Loaded glTF PBR: ", gltfPath, " (",
         meshCpu.vertices.length, " verts, metallic=", matDesc.metallic,
         " roughness=", matDesc.roughness, ")");
    return model;
}

/// Parse pbrMetallicRoughness from the first material (or defaults).
GltfMaterialDesc parseGltfMaterial(string gltfPath) @trusted {
    GltfMaterialDesc desc;
    auto text = cast(string) read(gltfPath);
    auto root = parseJSON(text);
    if ("materials" !in root) return desc;
    auto materials = root["materials"].array;
    if (materials.length == 0) return desc;
    auto mat = materials[0];

    if ("pbrMetallicRoughness" in mat) {
        auto pbr = mat["pbrMetallicRoughness"];
        if ("baseColorFactor" in pbr) {
            auto arr = pbr["baseColorFactor"].array;
            foreach (i; 0 .. 4)
                if (i < arr.length) desc.baseColorFactor[i] = jsonFloat(arr[i]);
        }
        if ("metallicFactor" in pbr)
            desc.metallic = jsonFloat(pbr["metallicFactor"]);
        if ("roughnessFactor" in pbr)
            desc.roughness = jsonFloat(pbr["roughnessFactor"]);
        if ("baseColorTexture" in pbr)
            desc.baseColorUri = resolveTextureUri(root, cast(int) pbr["baseColorTexture"]["index"].integer);
        if ("metallicRoughnessTexture" in pbr)
            desc.metallicRoughnessUri = resolveTextureUri(root, cast(int) pbr["metallicRoughnessTexture"]["index"].integer);
    }
    if ("normalTexture" in mat)
        desc.normalUri = resolveTextureUri(root, cast(int) mat["normalTexture"]["index"].integer);
    if ("occlusionTexture" in mat)
        desc.occlusionUri = resolveTextureUri(root, cast(int) mat["occlusionTexture"]["index"].integer);
    if ("emissiveTexture" in mat)
        desc.emissiveUri = resolveTextureUri(root, cast(int) mat["emissiveTexture"]["index"].integer);
    return desc;
}

private float jsonFloat(ref JSONValue v) {
    if (v.type == JSONType.float_) return cast(float) v.floating;
    if (v.type == JSONType.integer) return cast(float) v.integer;
    return 0;
}

private string resolveTextureUri(ref JSONValue root, int textureIndex) @trusted {
    auto textures = root["textures"].array;
    enforce(textureIndex >= 0 && textureIndex < textures.length, "glTF: texture index OOB");
    immutable int source = cast(int) textures[textureIndex]["source"].integer;
    auto images = root["images"].array;
    enforce(source >= 0 && source < images.length, "glTF: image index OOB");
    enforce("uri" in images[source], "glTF: image missing uri");
    return images[source]["uri"].str;
}

private Texture loadImageTexture(ref GpuContext gpu, string path) {
    if (!exists(path)) {
        err("glTF image not found: ", path);
        return Texture.init;
    }
    immutable ext = extension(path).toLower;
    if (ext == ".tga") {
        return Texture.fromTgaFile(gpu, path);
    }
    if (ext == ".bmp") {
        import engine.assets.bmp : loadBmpTexture;
        return loadBmpTexture(gpu, path);
    }
    err("glTF: unsupported image format (use .bmp or .tga): ", path);
    return Texture.init;
}

private ubyte toU8(float v) pure nothrow @nogc {
    if (v < 0) return 0;
    if (v > 1) return 255;
    return cast(ubyte)(v * 255.0f + 0.5f);
}

/// Parse a .gltf file and return its first primitive as CPU geometry.
GltfMesh parseGltfMesh(string gltfPath) @trusted {
    auto text = cast(string) read(gltfPath);
    auto root = parseJSON(text);
    enforce("meshes" in root, "glTF: no meshes");
    auto meshes = root["meshes"].array;
    enforce(meshes.length > 0, "glTF: empty meshes array");
    auto primitives = meshes[0]["primitives"].array;
    enforce(primitives.length > 0, "glTF: no primitives in first mesh");
    auto prim = primitives[0];
    auto attrs = prim["attributes"].object;

    enforce("POSITION" in attrs, "glTF: primitive missing POSITION");
    immutable int posAcc   = cast(int) attrs["POSITION"].integer;
    immutable int normAcc  = ("NORMAL"     in attrs) ? cast(int) attrs["NORMAL"].integer     : -1;
    immutable int uvAcc    = ("TEXCOORD_0" in attrs) ? cast(int) attrs["TEXCOORD_0"].integer : -1;
    enforce("indices" in prim, "glTF: primitive missing indices (non-indexed meshes unsupported)");
    immutable int idxAcc   = cast(int) prim["indices"].integer;

    auto accessors   = root["accessors"].array;
    auto bufferViews = root["bufferViews"].array;
    auto buffers     = root["buffers"].array;

    const(ubyte)[][] bufferData;
    bufferData.length = buffers.length;
    immutable baseDir = dirName(gltfPath);
    foreach (i, b; buffers) {
        enforce("uri" in b.object, "glTF: embedded base64 buffers not supported");
        immutable uri = b["uri"].str;
        enforce(uri.length < 5 || uri[0 .. 5] != "data:",
                "glTF: data: URIs not supported — use external .bin");
        bufferData[i] = cast(const(ubyte)[]) read(buildPath(baseDir, uri));
    }

    float[] readFloatVec(int accessorIndex, uint expectedComponents) @trusted {
        auto acc = accessors[accessorIndex];
        enforce(cast(uint) acc["componentType"].integer == CT_FLOAT,
                "glTF: non-float vector accessor unsupported");
        immutable string type = acc["type"].str;
        uint comps = 0;
        if (type == "VEC2") comps = 2;
        else if (type == "VEC3") comps = 3;
        else if (type == "VEC4") comps = 4;
        else enforce(false, "glTF: unsupported accessor type " ~ type);
        enforce(comps == expectedComponents, "glTF: accessor component count mismatch");
        immutable size_t count = cast(size_t) acc["count"].integer;
        immutable int bvIndex  = cast(int) acc["bufferView"].integer;
        auto bv = bufferViews[bvIndex];
        immutable size_t bufIdx = cast(size_t) bv["buffer"].integer;
        immutable size_t offset = ("byteOffset" in bv.object) ? cast(size_t) bv["byteOffset"].integer : 0;
        immutable size_t accOff = ("byteOffset" in acc.object) ? cast(size_t) acc["byteOffset"].integer : 0;
        immutable size_t totalOff = offset + accOff;
        immutable size_t byteLen  = count * comps * float.sizeof;
        auto src = bufferData[bufIdx];
        enforce(totalOff + byteLen <= src.length, "glTF: accessor out of buffer bounds");
        auto dst = new float[count * comps];
        auto fSrc = cast(const(float)*) (src.ptr + totalOff);
        foreach (i; 0 .. count * comps) dst[i] = fSrc[i];
        return dst;
    }

    ushort[] readIndices(int accessorIndex) @trusted {
        auto acc = accessors[accessorIndex];
        immutable uint ct = cast(uint) acc["componentType"].integer;
        immutable string type = acc["type"].str;
        enforce(type == "SCALAR", "glTF: indices must be SCALAR");
        immutable size_t count = cast(size_t) acc["count"].integer;
        immutable int bvIndex  = cast(int) acc["bufferView"].integer;
        auto bv = bufferViews[bvIndex];
        immutable size_t bufIdx = cast(size_t) bv["buffer"].integer;
        immutable size_t offset = ("byteOffset" in bv.object) ? cast(size_t) bv["byteOffset"].integer : 0;
        immutable size_t accOff = ("byteOffset" in acc.object) ? cast(size_t) acc["byteOffset"].integer : 0;
        immutable size_t totalOff = offset + accOff;
        auto src = bufferData[bufIdx];
        auto dst = new ushort[count];
        if (ct == CT_USHORT) {
            auto p = cast(const(ushort)*) (src.ptr + totalOff);
            foreach (i; 0 .. count) dst[i] = p[i];
        } else if (ct == CT_UINT) {
            auto p = cast(const(uint)*) (src.ptr + totalOff);
            foreach (i; 0 .. count) {
                enforce(p[i] <= 65535, "glTF: u32 index exceeds ushort range");
                dst[i] = cast(ushort) p[i];
            }
        } else if (ct == CT_UBYTE) {
            auto p = cast(const(ubyte)*) (src.ptr + totalOff);
            foreach (i; 0 .. count) dst[i] = p[i];
        } else {
            enforce(false, "glTF: unsupported index component type");
        }
        return dst;
    }

    auto positions = readFloatVec(posAcc, 3);
    immutable size_t vcount = positions.length / 3;
    float[] normals; float[] uvs;
    if (normAcc >= 0) normals = readFloatVec(normAcc, 3);
    if (uvAcc   >= 0) uvs     = readFloatVec(uvAcc,   2);

    GltfMesh out_;
    out_.vertices.length = vcount;
    foreach (i; 0 .. vcount) {
        TexVert v;
        v.pos[0] = positions[i*3 + 0];
        v.pos[1] = positions[i*3 + 1];
        v.pos[2] = positions[i*3 + 2];
        if (normals.length) {
            v.normal[0] = normals[i*3 + 0];
            v.normal[1] = normals[i*3 + 1];
            v.normal[2] = normals[i*3 + 2];
        } else {
            v.normal = [0, 1, 0];
        }
        if (uvs.length) {
            v.uv[0] = uvs[i*2 + 0];
            v.uv[1] = uvs[i*2 + 1];
        } else {
            v.uv = [0, 0];
        }
        out_.vertices[i] = v;
    }
    out_.indices = readIndices(idxAcc);
    return out_;
}
