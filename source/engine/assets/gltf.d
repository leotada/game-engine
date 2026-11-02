/// Minimal glTF 2.0 loader — mesh geometry + optional pbrMetallicRoughness materials.
///
/// Supported:
///   - .gltf JSON + external .bin buffer (same directory)
///   - Component types: 5123 (u16), 5125 (u32). Upload narrows to u16 when every index fits in 65535.
///   - Attribute types: VEC3 positions/normals, VEC2 uvs (float32)
///   - Materials: pbrMetallicRoughness factors + baseColor / MR / normal /
///     occlusion / emissive textures (BMP or TGA via engine loaders)
///
/// NOT supported: .glb containers, embedded base64 buffers, animations,
/// skinning, multiple primitives.
module engine.assets.gltf;

import core.math : sqrt;
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
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.vec : Vec3, Vec4;
import engine.assets.gltf_optimize : optimizeImportedMesh;
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
    return TexMesh.fromData(gpu, mesh.vertices, mesh.indices, mesh.shadowIndices);
}

/// Parsed glTF mesh on the CPU (no GPU resources yet).
struct GltfMesh {
    TexVert[] vertices;
    uint[] indices;
    /// Position-only indices from `optimizeMesh`. Empty when optimization is off.
    uint[] shadowIndices;
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
    model.mesh = TexMesh.fromData(gpu, meshCpu.vertices, meshCpu.indices, meshCpu.shadowIndices);

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

    // Decode EXT_meshopt_compression before any accessor read. The decoded
    // bytes replace that bufferView; accessor byteOffset is relative to them.
    ubyte[][] meshoptViews;
    meshoptViews.length = bufferViews.length;
    foreach (vi, ref bv; bufferViews) {
        if ("extensions" !in bv.object)
            continue;
        auto exts = bv["extensions"];
        if ("EXT_meshopt_compression" !in exts.object)
            continue;
        meshoptViews[vi] = decodeMeshoptView(exts["EXT_meshopt_compression"], bufferData);
    }

    const(ubyte)[] viewBytes(int bvIndex, ref size_t baseOff) {
        auto bv = bufferViews[bvIndex];
        if (meshoptViews[bvIndex].length) {
            baseOff = 0;
            return meshoptViews[bvIndex];
        }
        immutable size_t bufIdx = cast(size_t) bv["buffer"].integer;
        baseOff = ("byteOffset" in bv.object) ? cast(size_t) bv["byteOffset"].integer : 0;
        return bufferData[bufIdx];
    }

    float[] readFloatVec(int accessorIndex, uint expectedComponents) @trusted {
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
        immutable int bvIndex  = cast(int) acc["bufferView"].integer;
        auto bv = bufferViews[bvIndex];
        size_t baseOff;
        auto src = viewBytes(bvIndex, baseOff);
        immutable size_t accOff = ("byteOffset" in acc.object) ? cast(size_t) acc["byteOffset"].integer : 0;
        immutable size_t elem = componentSize(ct) * comps;
        immutable size_t stride = ("byteStride" in bv.object) ? cast(size_t) bv["byteStride"].integer : elem;
        enforce(stride >= elem, "glTF: byteStride smaller than the element");
        immutable size_t totalOff = baseOff + accOff;
        enforce(count == 0 || totalOff + (count - 1) * stride + elem <= src.length,
                "glTF: accessor out of buffer bounds");
        auto dst = new float[count * comps];
        if (ct == CT_FLOAT && stride == elem) {
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

    uint[] readIndices(int accessorIndex) @trusted {
        auto acc = accessors[accessorIndex];
        immutable uint ct = cast(uint) acc["componentType"].integer;
        immutable string type = acc["type"].str;
        enforce(type == "SCALAR", "glTF: indices must be SCALAR");
        immutable size_t count = cast(size_t) acc["count"].integer;
        immutable int bvIndex  = cast(int) acc["bufferView"].integer;
        auto bv = bufferViews[bvIndex];
        size_t baseOff;
        auto src = viewBytes(bvIndex, baseOff);
        immutable size_t accOff = ("byteOffset" in acc.object) ? cast(size_t) acc["byteOffset"].integer : 0;
        immutable size_t elem = componentSize(ct);
        immutable size_t stride = ("byteStride" in bv.object && meshoptViews[bvIndex].length == 0)
                ? cast(size_t) bv["byteStride"].integer : elem;
        immutable size_t totalOff = baseOff + accOff;
        enforce(count == 0 || totalOff + (count - 1) * stride + elem <= src.length,
                "glTF: index accessor out of buffer bounds");
        auto dst = new uint[count];
        if (ct == CT_USHORT && stride == 2) {
            auto p = cast(const(ushort)*) (src.ptr + totalOff);
            foreach (i; 0 .. count) dst[i] = p[i];
        } else if (ct == CT_UINT && stride == 4) {
            auto p = cast(const(uint)*) (src.ptr + totalOff);
            foreach (i; 0 .. count) dst[i] = p[i];
        } else if (ct == CT_UBYTE && stride == 1) {
            auto p = cast(const(ubyte)*) (src.ptr + totalOff);
            foreach (i; 0 .. count) dst[i] = p[i];
        } else if (ct == CT_USHORT || ct == CT_UINT || ct == CT_UBYTE) {
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
    Mat4 world = meshNodeWorld(root);
    Mat4 ident = Mat4.identity;
    bool hasXform = world.m != ident.m;
    if (hasXform) {
        Mat4 inv = world.inverse();
        foreach (ref v; out_.vertices) {
            Vec4 p = world * Vec4(v.pos[0], v.pos[1], v.pos[2], 1);
            v.pos = [p.x, p.y, p.z];
            if (normals.length) {
                Vec3 n = transformNormal(inv, Vec3(v.normal[0], v.normal[1], v.normal[2]));
                v.normal = [n.x, n.y, n.z];
            }
        }
    }
    out_.indices = readIndices(idxAcc);
    optimizeImportedMesh(gltfPath, out_.vertices, out_.indices, out_.shadowIndices);
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
