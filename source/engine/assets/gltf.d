/// Minimal glTF 2.0 loader — extracts the first mesh primitive's POSITION,
/// NORMAL, and TEXCOORD_0 attributes, plus UNSIGNED_SHORT or UNSIGNED_INT
/// indices, and uploads them as a `TexMesh`.
///
/// Supported:
///   - .gltf JSON + external .bin buffer (same directory)
///   - Component types: 5123 (u16), 5125 (u32 → downcast to u16 if in range)
///   - Attribute types: VEC3 positions/normals, VEC2 uvs (float32)
///
/// NOT supported (out of scope for v1): .glb containers, embedded base64
/// buffers, animations, skinning, multiple primitives, materials.
module engine.assets.gltf;

import std.conv : to;
import std.exception : enforce;
import std.file : read;
import std.json;
import std.path : dirName, buildPath;

import engine.core.log;
import engine.gpu.context : GpuContext;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.types : TexVert;

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

    // Load all buffers referenced by the accessors we touch.
    const(ubyte)[][] bufferData;
    bufferData.length = buffers.length;
    immutable baseDir = dirName(gltfPath);
    foreach (i, b; buffers) {
        enforce("uri" in b.object, "glTF: embedded base64 buffers not supported");
        immutable uri = b["uri"].str;
        // Reject data: URIs explicitly.
        enforce(uri.length < 5 || uri[0 .. 5] != "data:",
                "glTF: data: URIs not supported — use external .bin");
        bufferData[i] = cast(const(ubyte)[]) read(buildPath(baseDir, uri));
    }

    // Helper: read a float VEC{N} accessor as a flat float slice.
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
        // Copy via memcpy-equivalent; assumes little-endian host (x86_64).
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
