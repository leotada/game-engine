/// glTF/GLB skin import: joints, inverse bind matrices, per-vertex skinning
/// attributes (`SkinnedVertex`: position, normal, UV, tangent, joints, weights),
/// multi-mesh/multi-primitive support and material metadata, bound to an ozz
/// skeleton by joint name.
module engine.animation.gltf_skin;

import core.math : sqrt;
import engine.animation.ecs.assets : SkinBinding;
import engine.animation.math.simd;
import engine.animation.skeleton;
import engine.graphics.types : SkinnedVertex;
import engine.math.bounds : Aabb, BoundingSphere;
import engine.math.vec : Vec3;
import std.json;

@safe:

/// Per-vertex skinning attributes of the first primitive (`loadGltfSkin`).
struct GltfSkinVertices {
    /// 4 skin-joint indices per vertex (indices into `SkinBinding.remap`).
    ushort[] joints;
    /// 4 weights per vertex.
    float[] weights;
}

/// Material metadata parsed from glTF alongside a skinned character.
struct GltfSkinMaterialInfo {
    string name;
    bool doubleSided = false;
    float[4] baseColorFactor = [1.0f, 1.0f, 1.0f, 1.0f];
    float metallicFactor = 1.0f;
    float roughnessFactor = 1.0f;
}

/// One skinned primitive (sub-mesh) of a character.
struct GltfSkinnedSubMeshCpu {
    /// Name of the owning glTF mesh (or node name when the mesh is unnamed).
    string meshName;
    /// Index in `GltfSkinnedCharacterCpu.materials`, or -1 for default material.
    int material = -1;
    /// Material name from `materials[material].name` (`""` if none).
    string materialName;
    /// Interleaved vertices (`position`, `normal`, `uv`, `tangent`, `joints`, `weights`).
    SkinnedVertex[] vertices;
    /// Triangle indices.
    uint[] indices;
    /// Bind-pose object-space bounds.
    Aabb localBounds;
    BoundingSphere localSphere;
}

/// Complete CPU-side skinned character parsed from a `.gltf` or `.glb` file.
struct GltfSkinnedCharacterCpu {
    SkinBinding binding;
    GltfSkinnedSubMeshCpu[] subMeshes;
    GltfSkinMaterialInfo[] materials;
    Aabb bindBounds;
    BoundingSphere bindSphere;

    /// Find material index by name, or -1.
    int findMaterial(scope const(char)[] name) const pure nothrow @nogc {
        if (name.length == 0) return -1;
        foreach (i, ref m; materials)
            if (m.name == name) return cast(int) i;
        return -1;
    }

    /// Find first sub-mesh index by mesh name, or -1.
    int findSubMesh(scope const(char)[] name) const pure nothrow @nogc {
        if (name.length == 0) return -1;
        foreach (i, ref sm; subMeshes)
            if (sm.meshName == name) return cast(int) i;
        return -1;
    }
}

private enum uint CT_BYTE   = 5120;
private enum uint CT_UBYTE  = 5121;
private enum uint CT_SHORT  = 5122;
private enum uint CT_USHORT = 5123;
private enum uint CT_UINT   = 5125;
private enum uint CT_FLOAT  = 5126;

private enum uint GLB_MAGIC      = 0x46546C67;
private enum uint GLB_CHUNK_JSON = 0x4E4F534A;
private enum uint GLB_CHUNK_BIN  = 0x004E4942;

private uint readU32le(scope const(ubyte)[] b, size_t at) pure nothrow @nogc {
    return cast(uint) b[at] | (cast(uint) b[at + 1] << 8)
         | (cast(uint) b[at + 2] << 16) | (cast(uint) b[at + 3] << 24);
}

private float readF32le(scope const(ubyte)[] b, size_t at) @trusted pure nothrow @nogc {
    uint bits = readU32le(b, at);
    return *cast(float*) &bits;
}

private size_t ctSize(uint ct) pure nothrow @nogc {
    if (ct == CT_BYTE || ct == CT_UBYTE) return 1;
    if (ct == CT_SHORT || ct == CT_USHORT) return 2;
    if (ct == CT_UINT || ct == CT_FLOAT) return 4;
    return 0;
}

private float dequantize(scope const(ubyte)[] b, size_t at, uint ct, bool normalized) @trusted pure nothrow @nogc {
    if (ct == CT_FLOAT) return readF32le(b, at);
    int v = 0;
    if (ct == CT_BYTE) v = cast(byte) b[at];
    else if (ct == CT_UBYTE) v = b[at];
    else if (ct == CT_SHORT) v = cast(short)(b[at] | (b[at + 1] << 8));
    else if (ct == CT_USHORT) v = b[at] | (b[at + 1] << 8);
    else if (ct == CT_UINT) v = cast(int) readU32le(b, at);
    if (!normalized) return cast(float) v;
    int bits = (ct == CT_BYTE || ct == CT_UBYTE) ? 8 : 16;
    if (ct == CT_BYTE || ct == CT_SHORT) {
        float f = cast(float) v / cast(float)((1 << (bits - 1)) - 1);
        return f < -1.0f ? -1.0f : f;
    }
    return cast(float) v / cast(float)((1 << bits) - 1);
}

private float jsonFloat(ref JSONValue v) @trusted {
    if (v.type == JSONType.float_) return cast(float) v.floating;
    if (v.type == JSONType.integer) return cast(float) v.integer;
    return 0.0f;
}

private bool isDataUri(string uri) pure nothrow @nogc {
    return uri.length >= 5 && uri[0 .. 5] == "data:";
}

private ubyte[] decodeDataUri(string uri) @trusted {
    import std.base64 : Base64;
    import std.string : indexOf;
    immutable comma = uri.indexOf(',');
    if (comma <= 5) throw new Exception("glTF: malformed data: URI");
    auto header = uri[5 .. comma];
    if (header.length < 7 || header[$ - 7 .. $] != ";base64")
        throw new Exception("glTF: only base64 data: URIs are supported");
    return Base64.decode(uri[comma + 1 .. $]);
}

private void parseGltfContainer(const(ubyte)[] bytes, string baseDir,
                                out JSONValue root, out const(ubyte)[][] buffers) @trusted {
    import std.file : read;
    import std.path : buildPath;

    const(ubyte)[] bin;
    string jsonText;
    if (bytes.length >= 12 && readU32le(bytes, 0) == GLB_MAGIC) {
        if (readU32le(bytes, 4) != 2) throw new Exception("GLB: unsupported container version");
        immutable size_t total = readU32le(bytes, 8);
        if (total > bytes.length) throw new Exception("GLB: truncated file");
        size_t at = 12;
        bool haveJson = false;
        while (at + 8 <= total) {
            immutable size_t len = readU32le(bytes, at);
            immutable uint type = readU32le(bytes, at + 4);
            at += 8;
            if (at + len > total) throw new Exception("GLB: chunk out of bounds");
            if (type == GLB_CHUNK_JSON && !haveJson) {
                jsonText = cast(string) bytes[at .. at + len].idup;
                haveJson = true;
            } else if (type == GLB_CHUNK_BIN && bin.length == 0) {
                bin = bytes[at .. at + len];
            }
            at += len;
        }
        if (!haveJson) throw new Exception("GLB: missing JSON chunk");
    } else {
        jsonText = cast(string) bytes.idup;
    }
    root = parseJSON(jsonText);
    if (root.type != JSONType.object) throw new Exception("glTF: root is not a JSON object");

    if ("buffers" in root.object) {
        auto bs = root["buffers"].array;
        buffers.length = bs.length;
        foreach (i, b; bs) {
            if ("uri" !in b.object) {
                if (bin.length == 0) throw new Exception("glTF: buffer without uri needs a GLB BIN chunk");
                buffers[i] = bin;
            } else {
                immutable uri = b["uri"].str;
                if (isDataUri(uri)) {
                    buffers[i] = decodeDataUri(uri);
                } else {
                    buffers[i] = cast(const(ubyte)[]) read(buildPath(baseDir, uri));
                }
            }
        }
    }
}

private struct AccessorSlice {
    const(ubyte)[] buf;
    size_t offset;
    size_t stride;
    size_t count;
    uint componentType;
    bool normalized;
}

private AccessorSlice resolveAccessor(ref JSONValue root, const(ubyte)[][] buffers,
                                      long accIdx, uint expectedComps,
                                      scope const(uint)[] allowedTypes) @trusted {
    auto accessors = root["accessors"].array;
    if (accIdx < 0 || accIdx >= cast(long) accessors.length)
        throw new Exception("glTF: accessor index out of range");
    auto acc = accessors[cast(size_t) accIdx];
    immutable uint ctype = cast(uint) acc["componentType"].integer;
    bool ok = false;
    foreach (a; allowedTypes) if (a == ctype) { ok = true; break; }
    if (!ok) throw new Exception("glTF: unsupported accessor componentType");

    immutable size_t csize = ctSize(ctype);
    if (csize == 0) throw new Exception("glTF: invalid componentType");
    immutable size_t elemBytes = csize * expectedComps;
    immutable size_t count = cast(size_t) acc["count"].integer;
    if ("bufferView" !in acc.object)
        throw new Exception("glTF: accessors without bufferView are unsupported");
    immutable size_t bvIdx = cast(size_t) acc["bufferView"].integer;
    auto bufferViews = root["bufferViews"].array;
    if (bvIdx >= bufferViews.length) throw new Exception("glTF: bufferView index out of range");
    auto bv = bufferViews[bvIdx];
    immutable size_t bufIdx = cast(size_t) bv["buffer"].integer;
    if (bufIdx >= buffers.length) throw new Exception("glTF: buffer index out of range");
    auto buf = buffers[bufIdx];
    immutable size_t bvOff = "byteOffset" in bv.object ? cast(size_t) bv["byteOffset"].integer : 0;
    immutable size_t accOff = "byteOffset" in acc.object ? cast(size_t) acc["byteOffset"].integer : 0;
    immutable size_t stride = "byteStride" in bv.object ? cast(size_t) bv["byteStride"].integer : elemBytes;
    if (stride < elemBytes) throw new Exception("glTF: byteStride smaller than element size");
    immutable size_t totalOff = bvOff + accOff;
    if (count > 0 && totalOff + (count - 1) * stride + elemBytes > buf.length)
        throw new Exception("glTF: accessor out of buffer bounds");

    AccessorSlice s;
    s.buf = buf;
    s.offset = totalOff;
    s.stride = stride;
    s.count = count;
    s.componentType = ctype;
    s.normalized = ("normalized" in acc.object) && acc["normalized"].type == JSONType.true_;
    return s;
}

private float[] readAccessorFloats(ref JSONValue root, const(ubyte)[][] buffers,
                                   long accIdx, uint comps) @trusted {
    static immutable uint[5] allowed = [CT_FLOAT, CT_UBYTE, CT_USHORT, CT_BYTE, CT_SHORT];
    auto s = resolveAccessor(root, buffers, accIdx, comps, allowed[]);
    immutable size_t cs = ctSize(s.componentType);
    auto dst = new float[s.count * comps];
    foreach (i; 0 .. s.count) {
        size_t at = s.offset + i * s.stride;
        foreach (c; 0 .. comps)
            dst[i * comps + c] = dequantize(s.buf, at + c * cs, s.componentType, s.normalized);
    }
    return dst;
}

private ushort[] readAccessorJoints4(ref JSONValue root, const(ubyte)[][] buffers,
                                     long accIdx, size_t jointCount, out size_t count) @trusted {
    static immutable uint[2] allowed = [CT_UBYTE, CT_USHORT];
    auto s = resolveAccessor(root, buffers, accIdx, 4, allowed[]);
    count = s.count;
    immutable size_t cs = ctSize(s.componentType);
    auto dst = new ushort[s.count * 4];
    foreach (i; 0 .. s.count) {
        size_t at = s.offset + i * s.stride;
        foreach (c; 0 .. 4) {
            immutable size_t p = at + c * cs;
            immutable ushort j = cs == 2
                ? cast(ushort)(s.buf[p] | (s.buf[p + 1] << 8))
                : s.buf[p];
            if (j >= jointCount) throw new Exception("glTF: vertex joint index out of range");
            dst[i * 4 + c] = j;
        }
    }
    return dst;
}

private uint[] readAccessorIndices(ref JSONValue root, const(ubyte)[][] buffers, long accIdx) @trusted {
    static immutable uint[3] allowed = [CT_UBYTE, CT_USHORT, CT_UINT];
    auto s = resolveAccessor(root, buffers, accIdx, 1, allowed[]);
    auto dst = new uint[s.count];
    foreach (i; 0 .. s.count) {
        size_t at = s.offset + i * s.stride;
        if (s.componentType == CT_UINT) dst[i] = readU32le(s.buf, at);
        else if (s.componentType == CT_USHORT) dst[i] = cast(uint)(s.buf[at] | (s.buf[at + 1] << 8));
        else dst[i] = s.buf[at];
    }
    return dst;
}

private bool buildSkinBinding(ref JSONValue root, const(ubyte)[][] buffers, size_t skinIndex,
                              ref const Skeleton skeleton, out SkinBinding binding, out string error) @trusted {
    if ("skins" !in root.object || root["skins"].array.length <= skinIndex) {
        error = "glTF: no skins";
        return false;
    }
    auto skin = root["skins"].array[skinIndex];
    auto nodes = root["nodes"].array;
    auto joints = skin["joints"].array;

    float[] ibFloats;
    if ("inverseBindMatrices" in skin.object) {
        static immutable uint[1] allowed = [CT_FLOAT];
        auto s = resolveAccessor(root, buffers, skin["inverseBindMatrices"].integer, 16, allowed[]);
        if (s.count < joints.length) {
            error = "glTF: too few inverse bind matrices";
            return false;
        }
        ibFloats = new float[s.count * 16];
        foreach (i; 0 .. s.count) {
            size_t at = s.offset + i * s.stride;
            foreach (k; 0 .. 16)
                ibFloats[i * 16 + k] = readF32le(s.buf, at + k * 4);
        }
    }

    binding = SkinBinding.init;
    foreach (ji, jn; joints) {
        auto node = nodes[cast(size_t) jn.integer];
        immutable name = "name" in node.object ? node["name"].str : "";
        immutable sj = findJoint(skeleton, name);
        if (sj < 0) {
            error = "glTF: skin joint '" ~ name ~ "' not in skeleton";
            return false;
        }
        binding.remap ~= cast(uint) sj;
        Float4x4 m = Float4x4.identity();
        if (ibFloats.length > 0) {
            foreach (c; 0 .. 4) {
                immutable o = ji * 16 + c * 4;
                m.cols[c] = SimdFloat4(ibFloats[o], ibFloats[o + 1], ibFloats[o + 2], ibFloats[o + 3]);
            }
        }
        binding.inverseBinds ~= m;
    }
    return true;
}

/// Generates smooth per-vertex tangents in place from triangle geometry + UVs,
/// preserving exact vertex ordering (1:1 with `JOINTS_0`/`WEIGHTS_0`).
private void generateSmoothSkinnedTangents(SkinnedVertex[] verts, scope const(uint)[] indices) pure nothrow @safe {
    auto accT = new Vec3[verts.length];
    auto accB = new Vec3[verts.length];
    foreach (i; 0 .. verts.length) {
        accT[i] = Vec3(0, 0, 0);
        accB[i] = Vec3(0, 0, 0);
    }

    for (size_t i = 0; i + 2 < indices.length; i += 3) {
        immutable i0 = indices[i], i1 = indices[i + 1], i2 = indices[i + 2];
        if (i0 >= verts.length || i1 >= verts.length || i2 >= verts.length) continue;
        immutable p0 = Vec3(verts[i0].position[0], verts[i0].position[1], verts[i0].position[2]);
        immutable p1 = Vec3(verts[i1].position[0], verts[i1].position[1], verts[i1].position[2]);
        immutable p2 = Vec3(verts[i2].position[0], verts[i2].position[1], verts[i2].position[2]);
        immutable e1 = p1 - p0;
        immutable e2 = p2 - p0;
        immutable du1 = verts[i1].uv[0] - verts[i0].uv[0];
        immutable dv1 = verts[i1].uv[1] - verts[i0].uv[1];
        immutable du2 = verts[i2].uv[0] - verts[i0].uv[0];
        immutable dv2 = verts[i2].uv[1] - verts[i0].uv[1];
        immutable det = du1 * dv2 - du2 * dv1;
        if (det > -1e-12f && det < 1e-12f) continue;
        immutable invDet = 1.0f / det;
        immutable t = Vec3((e1.x * dv2 - e2.x * dv1) * invDet,
                           (e1.y * dv2 - e2.y * dv1) * invDet,
                           (e1.z * dv2 - e2.z * dv1) * invDet);
        immutable b = Vec3((e2.x * du1 - e1.x * du2) * invDet,
                           (e2.y * du1 - e1.y * du2) * invDet,
                           (e2.z * du1 - e1.z * du2) * invDet);
        accT[i0] = accT[i0] + t; accT[i1] = accT[i1] + t; accT[i2] = accT[i2] + t;
        accB[i0] = accB[i0] + b; accB[i1] = accB[i1] + b; accB[i2] = accB[i2] + b;
    }

    foreach (i, ref v; verts) {
        immutable n = Vec3(v.normal[0], v.normal[1], v.normal[2]).normalized();
        immutable rawT = accT[i];
        immutable ortho = rawT - n * n.dot(rawT);
        immutable len2 = ortho.dot(ortho);
        if (len2 > 1e-10f) {
            immutable t = ortho * (1.0f / sqrt(len2));
            immutable sign = n.cross(t).dot(accB[i]) < 0.0f ? -1.0f : 1.0f;
            v.tangent = [t.x, t.y, t.z, sign];
        } else {
            Vec3 helper = (n.x < 0.9f && n.x > -0.9f) ? Vec3(1, 0, 0) : Vec3(0, 0, 1);
            immutable t = (helper - n * n.dot(helper)).normalized();
            v.tangent = [t.x, t.y, t.z, 1.0f];
        }
    }
}

/// Loads the skin of `gltfPath` (first primitive of first mesh). Skin joints are matched
/// to `skeleton` joints by node name; a joint with no match makes the load fail, naming
/// the joint in `error`.
bool loadGltfSkin(string gltfPath, ref const Skeleton skeleton, out SkinBinding binding,
                  out GltfSkinVertices vertices, out string error) @trusted {
    import std.file : read;
    import std.path : dirName;
    try {
        JSONValue root;
        const(ubyte)[][] buffers;
        parseGltfContainer(cast(const(ubyte)[]) read(gltfPath), dirName(gltfPath), root, buffers);
        if (!buildSkinBinding(root, buffers, 0, skeleton, binding, error))
            return false;

        auto prim = root["meshes"].array[0]["primitives"].array[0];
        auto attrs = prim["attributes"].object;
        if (!("JOINTS_0" in attrs) || !("WEIGHTS_0" in attrs)) {
            error = "glTF: primitive has no JOINTS_0/WEIGHTS_0";
            return false;
        }
        size_t n;
        vertices.joints = readAccessorJoints4(root, buffers, attrs["JOINTS_0"].integer, binding.remap.length, n);
        vertices.weights = readAccessorFloats(root, buffers, attrs["WEIGHTS_0"].integer, 4);
        if (vertices.weights.length != n * 4) {
            error = "glTF: JOINTS_0/WEIGHTS_0 count mismatch";
            return false;
        }
        return true;
    } catch (Exception e) {
        error = e.msg;
        return false;
    }
}

/// Loads every skinned mesh and primitive (plus material metadata and UV/tangent/joint/weight
/// attributes) from a `.gltf` or `.glb` character file, matching skin joints to `skeleton` by name.
bool loadGltfSkinnedCharacterCpu(string gltfPath, ref const Skeleton skeleton,
                                 out GltfSkinnedCharacterCpu character, out string error,
                                 size_t skinIndex = 0) @trusted {
    import std.file : read;
    import std.path : dirName;
    try {
        auto bytes = cast(const(ubyte)[]) read(gltfPath);
        return loadGltfSkinnedCharacterCpuFromBytes(bytes, dirName(gltfPath), skeleton, character, error, skinIndex);
    } catch (Exception e) {
        error = e.msg;
        return false;
    }
}

/// In-memory `.gltf` / `.glb` overload of `loadGltfSkinnedCharacterCpu`.
bool loadGltfSkinnedCharacterCpuFromBytes(const(ubyte)[] bytes, string baseDir,
                                          ref const Skeleton skeleton,
                                          out GltfSkinnedCharacterCpu character,
                                          out string error,
                                          size_t skinIndex = 0) @trusted {
    try {
        JSONValue root;
        const(ubyte)[][] buffers;
        parseGltfContainer(bytes, baseDir, root, buffers);

        if (!buildSkinBinding(root, buffers, skinIndex, skeleton, character.binding, error))
            return false;

        if ("materials" in root.object) {
            auto mats = root["materials"].array;
            character.materials.length = mats.length;
            foreach (mi, ref mat; mats) {
                GltfSkinMaterialInfo info;
                if ("name" in mat.object && mat["name"].type == JSONType.string)
                    info.name = mat["name"].str;
                info.doubleSided = ("doubleSided" in mat.object) && mat["doubleSided"].type == JSONType.true_;
                if ("pbrMetallicRoughness" in mat.object) {
                    auto pbr = mat["pbrMetallicRoughness"];
                    if ("baseColorFactor" in pbr.object) {
                        auto arr = pbr["baseColorFactor"].array;
                        foreach (k; 0 .. 4)
                            if (k < arr.length) info.baseColorFactor[k] = jsonFloat(arr[k]);
                    }
                    if ("metallicFactor" in pbr.object)
                        info.metallicFactor = jsonFloat(pbr["metallicFactor"]);
                    if ("roughnessFactor" in pbr.object)
                        info.roughnessFactor = jsonFloat(pbr["roughnessFactor"]);
                }
                character.materials[mi] = info;
            }
        }

        if ("meshes" !in root.object) {
            error = "glTF: no meshes";
            return false;
        }
        auto meshes = root["meshes"].array;
        string[] nodeNamesForMesh = new string[meshes.length];
        if ("nodes" in root.object) {
            foreach (ref n; root["nodes"].array) {
                if ("mesh" !in n.object) continue;
                immutable mi = cast(size_t) n["mesh"].integer;
                if (mi < nodeNamesForMesh.length && nodeNamesForMesh[mi].length == 0
                        && "name" in n.object && n["name"].type == JSONType.string) {
                    nodeNamesForMesh[mi] = n["name"].str;
                }
            }
        }

        immutable size_t skinJointCount = character.binding.remap.length;
        foreach (mi, ref m; meshes) {
            string mname = ("name" in m.object && m["name"].type == JSONType.string)
                ? m["name"].str : nodeNamesForMesh[mi];
            auto prims = m["primitives"].array;
            foreach (ref prim; prims) {
                auto attrs = prim["attributes"].object;
                if ("JOINTS_0" !in attrs || "WEIGHTS_0" !in attrs || "POSITION" !in attrs)
                    continue;
                if ("mode" in prim.object && prim["mode"].integer != 4)
                    throw new Exception("glTF: only TRIANGLES skinned primitives are supported");

                auto pos = readAccessorFloats(root, buffers, attrs["POSITION"].integer, 3);
                immutable size_t vcount = pos.length / 3;
                float[] nrm = ("NORMAL" in attrs) ? readAccessorFloats(root, buffers, attrs["NORMAL"].integer, 3) : null;
                float[] uv = ("TEXCOORD_0" in attrs) ? readAccessorFloats(root, buffers, attrs["TEXCOORD_0"].integer, 2) : null;
                float[] tan = ("TANGENT" in attrs) ? readAccessorFloats(root, buffers, attrs["TANGENT"].integer, 4) : null;
                size_t jcount;
                auto jts = readAccessorJoints4(root, buffers, attrs["JOINTS_0"].integer, skinJointCount, jcount);
                auto wts = readAccessorFloats(root, buffers, attrs["WEIGHTS_0"].integer, 4);
                if (jcount != vcount || wts.length != vcount * 4)
                    throw new Exception("glTF: skinned attribute vertex count mismatch");
                if (nrm.length != 0 && nrm.length != vcount * 3)
                    throw new Exception("glTF: NORMAL count mismatch");
                if (uv.length != 0 && uv.length != vcount * 2)
                    throw new Exception("glTF: TEXCOORD_0 count mismatch");
                if (tan.length != 0 && tan.length != vcount * 4)
                    throw new Exception("glTF: TANGENT count mismatch");

                GltfSkinnedSubMeshCpu sm;
                sm.meshName = mname;
                if ("material" in prim.object) {
                    sm.material = cast(int) prim["material"].integer;
                    if (sm.material < 0 || sm.material >= cast(int) character.materials.length)
                        throw new Exception("glTF: primitive material index OOB");
                    sm.materialName = character.materials[sm.material].name;
                }
                if ("indices" in prim.object) {
                    sm.indices = readAccessorIndices(root, buffers, prim["indices"].integer);
                } else {
                    if (vcount % 3 != 0) throw new Exception("glTF: non-indexed triangle count not divisible by 3");
                    sm.indices = new uint[vcount];
                    foreach (i; 0 .. vcount) sm.indices[i] = cast(uint) i;
                }
                foreach (idx; sm.indices)
                    if (idx >= vcount) throw new Exception("glTF: index out of vertex range");

                sm.vertices = new SkinnedVertex[vcount];
                foreach (i; 0 .. vcount) {
                    SkinnedVertex v;
                    v.position = [pos[i * 3], pos[i * 3 + 1], pos[i * 3 + 2]];
                    v.normal = nrm.length ? [nrm[i * 3], nrm[i * 3 + 1], nrm[i * 3 + 2]] : [0.0f, 1.0f, 0.0f];
                    v.uv = uv.length ? [uv[i * 2], uv[i * 2 + 1]] : [0.0f, 0.0f];
                    if (tan.length)
                        v.tangent = [tan[i * 4], tan[i * 4 + 1], tan[i * 4 + 2], tan[i * 4 + 3]];
                    v.joints = [jts[i * 4], jts[i * 4 + 1], jts[i * 4 + 2], jts[i * 4 + 3]];
                    float[4] w = [wts[i * 4], wts[i * 4 + 1], wts[i * 4 + 2], wts[i * 4 + 3]];
                    float wsum = 0.0f;
                    foreach (k; 0 .. 4) {
                        if (w[k] < 0.0f) w[k] = 0.0f;
                        wsum += w[k];
                    }
                    if (wsum > 1e-6f) {
                        immutable inv = 1.0f / wsum;
                        foreach (k; 0 .. 4) w[k] *= inv;
                    } else {
                        w = [1.0f, 0.0f, 0.0f, 0.0f];
                    }
                    v.weights = w;
                    sm.vertices[i] = v;
                }
                if (tan.length == 0)
                    generateSmoothSkinnedTangents(sm.vertices, sm.indices);
                sm.localBounds = Aabb.fromPositions(sm.vertices);
                sm.localSphere = BoundingSphere.fromAabb(sm.localBounds);
                character.bindBounds = character.bindBounds.merge(sm.localBounds);
                character.subMeshes ~= sm;
            }
        }

        if (character.subMeshes.length == 0) {
            error = "glTF: no skinned primitives found";
            return false;
        }
        character.bindSphere = BoundingSphere.fromAabb(character.bindBounds);
        return true;
    } catch (Exception e) {
        error = e.msg;
        return false;
    }
}

version (unittest) {
    import engine.animation.io.archive : InputArchive;
    import engine.animation.testing : loadFixture;

    private ubyte[] makeTestGlbBytes(string json, scope const(ubyte)[] bin) @trusted {
        ubyte[] jb = cast(ubyte[]) json.dup;
        while (jb.length % 4) jb ~= ' ';
        ubyte[] bb = bin.dup;
        while (bb.length % 4) bb ~= 0;
        ubyte[] o;
        void put32(uint v) {
            o ~= cast(ubyte)(v & 0xFF);
            o ~= cast(ubyte)((v >> 8) & 0xFF);
            o ~= cast(ubyte)((v >> 16) & 0xFF);
            o ~= cast(ubyte)(v >> 24);
        }
        immutable total = 12 + 8 + jb.length + (bb.length ? 8 + bb.length : 0);
        put32(GLB_MAGIC);
        put32(2);
        put32(cast(uint) total);
        put32(cast(uint) jb.length);
        put32(GLB_CHUNK_JSON);
        o ~= jb;
        if (bb.length) {
            put32(cast(uint) bb.length);
            put32(GLB_CHUNK_BIN);
            o ~= bb;
        }
        return o;
    }
}

unittest {
    import std.file : mkdirRecurse, write, exists, rmdirRecurse, readText;
    import std.format : format;
    import std.array : replace;

    auto ar = InputArchive(loadFixture("pab/skeleton.ozz"));
    Skeleton sk;
    assert(loadSkeleton(ar, sk));
    immutable n0 = sk.jointName(0).idup, n1 = sk.jointName(1).idup;

    // Two joints, three vertices: vertex 2 uses joint index 1 with weights (0.25, 0.75).
    float[] ibm;
    foreach (j; 0 .. 2) { // identity with a translation of (j, 0, 0)
        ibm ~= [1, 0, 0, 0,  0, 1, 0, 0,  0, 0, 1, 0,  cast(float) j, 0, 0, 1];
    }
    ubyte[] bin = cast(ubyte[]) ibm.dup;               // 0..128: matrices
    bin ~= [0, 0, 0, 0,  1, 0, 0, 0,  1, 0, 0, 0];     // 128..140: JOINTS_0 (ubyte VEC4 x3)
    float[] w = [1, 0, 0, 0,  1, 0, 0, 0,  0.75f, 0.25f, 0, 0];
    bin ~= cast(ubyte[]) w.dup;                        // 140..188: WEIGHTS_0
    enum dir = "build/test_gltf_skin";
    mkdirRecurse(dir);
    scope (exit) if (exists(dir)) rmdirRecurse(dir);
    write(dir ~ "/s.bin", bin);
    write(dir ~ "/s.gltf", format(`{
 "asset":{"version":"2.0"},
 "nodes":[{"name":"%s"},{"name":"%s"}],
 "skins":[{"joints":[0,1],"inverseBindMatrices":0}],
 "meshes":[{"primitives":[{"attributes":{"JOINTS_0":1,"WEIGHTS_0":2}}]}],
 "buffers":[{"uri":"s.bin","byteLength":%d}],
 "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":128},{"buffer":0,"byteOffset":128,"byteLength":12},{"buffer":0,"byteOffset":140,"byteLength":48}],
 "accessors":[{"bufferView":0,"componentType":5126,"count":2,"type":"MAT4"},
              {"bufferView":1,"componentType":5121,"count":3,"type":"VEC4"},
              {"bufferView":2,"componentType":5126,"count":3,"type":"VEC4"}]
}`, n1, n0, bin.length)); // node order swapped: remap must follow names, not indices

    SkinBinding b;
    GltfSkinVertices v;
    string err;
    assert(loadGltfSkin(dir ~ "/s.gltf", sk, b, v, err), err);
    assert(b.remap == [1u, 0u]);
    assert(b.inverseBinds[1].cols[3].x == 1);
    assert(v.joints.length == 12 && v.joints[4] == 1 && v.weights[8] == 0.75f);

    // Unknown joint name fails with a useful message.
    write(dir ~ "/bad.gltf", readText(dir ~ "/s.gltf").replace(n0, "no_such_joint"));
    assert(!loadGltfSkin(dir ~ "/bad.gltf", sk, b, v, err) && err.length > 0);
}

@("gltfSkin.characterMultiMeshAndMaterialNames") @safe unittest {
    import std.format : format;
    import std.math : abs;

    auto ar = InputArchive(loadFixture("pab/skeleton.ozz"));
    Skeleton sk;
    assert(loadSkeleton(ar, sk));
    immutable n0 = sk.jointName(0).idup, n1 = sk.jointName(1).idup;

    // Interleaved vertex layout (byteStride = 52): pos(12) + nrm(12) + uv(8) + joints ubyte4(4) + weights f32x4(16)
    struct InterleavedV {
        float[3] p;
        float[3] n;
        float[2] uv;
        ubyte[4] j;
        float[4] w;
    }
    static assert(InterleavedV.sizeof == 52);

    float[32] ibm = [
        1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1,
        1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1,
    ];
    InterleavedV[3] tri = [
        InterleavedV([0,0,0], [0,0,1], [0,0], [0,1,0,0], [2.0f, 2.0f, 0, 0]), // unnormalized -> 0.5, 0.5
        InterleavedV([1,0,0], [0,0,1], [1,0], [1,0,0,0], [1.0f, 0, 0, 0]),
        InterleavedV([0,1,0], [0,0,1], [0,1], [0,0,0,0], [1.0f, 0, 0, 0]),
    ];
    ushort[4] idx16 = [0, 1, 2, 0];
    ushort[12] j16 = [1,0,0,0, 0,0,0,0, 1,0,0,0];

    ubyte[] bin;
    void appendBytes(T)(const(T)[] s) @trusted { bin ~= cast(const(ubyte)[]) s; }
    size_t offIbm = bin.length; appendBytes(ibm[]);
    size_t offVtx = bin.length; appendBytes(tri[]);
    size_t offIdx = bin.length; appendBytes(idx16[]);
    size_t offJ16 = bin.length; appendBytes(j16[]);

    immutable json = format(`{
      "asset":{"version":"2.0"},
      "nodes":[{"name":"%s"},{"name":"%s"},{"name":"char_root","children":[3,4]},{"name":"corpo_node","mesh":0,"skin":0},{"name":"quepe_node","mesh":1,"skin":0}],
      "skins":[{"joints":[0,1],"inverseBindMatrices":0}],
      "materials":[
        {"name":"pele","pbrMetallicRoughness":{"baseColorFactor":[0.9,0.7,0.6,1]}},
        {"name":"farda","pbrMetallicRoughness":{"baseColorFactor":[0.1,0.2,0.4,1]}},
        {"name":"quepe","doubleSided":true,"pbrMetallicRoughness":{"baseColorFactor":[0.1,0.1,0.1,1]}}
      ],
      "meshes":[
        {"name":"corpo","primitives":[
          {"attributes":{"POSITION":1,"NORMAL":2,"TEXCOORD_0":3,"JOINTS_0":4,"WEIGHTS_0":5},"indices":6,"material":0},
          {"attributes":{"POSITION":1,"NORMAL":2,"TEXCOORD_0":3,"JOINTS_0":4,"WEIGHTS_0":5},"indices":6,"material":1}
        ]},
        {"name":"acessorio_quepe","primitives":[
          {"attributes":{"POSITION":1,"NORMAL":2,"TEXCOORD_0":3,"JOINTS_0":7,"WEIGHTS_0":5},"indices":6,"material":2}
        ]}
      ],
      "buffers":[{"byteLength":%d}],
      "bufferViews":[
        {"buffer":0,"byteOffset":%d,"byteLength":128},
        {"buffer":0,"byteOffset":%d,"byteLength":%d,"byteStride":52},
        {"buffer":0,"byteOffset":%d,"byteLength":6},
        {"buffer":0,"byteOffset":%d,"byteLength":24}
      ],
      "accessors":[
        {"bufferView":0,"componentType":5126,"count":2,"type":"MAT4"},
        {"bufferView":1,"byteOffset":0,"componentType":5126,"count":3,"type":"VEC3"},
        {"bufferView":1,"byteOffset":12,"componentType":5126,"count":3,"type":"VEC3"},
        {"bufferView":1,"byteOffset":24,"componentType":5126,"count":3,"type":"VEC2"},
        {"bufferView":1,"byteOffset":32,"componentType":5121,"count":3,"type":"VEC4"},
        {"bufferView":1,"byteOffset":36,"componentType":5126,"count":3,"type":"VEC4"},
        {"bufferView":2,"componentType":5123,"count":3,"type":"SCALAR"},
        {"bufferView":3,"componentType":5123,"count":3,"type":"VEC4"}
      ]
    }`, n0, n1, bin.length, offIbm, offVtx, tri.sizeof, offIdx, offJ16);

    auto glb = makeTestGlbBytes(json, bin);
    GltfSkinnedCharacterCpu ch;
    string err;
    assert(loadGltfSkinnedCharacterCpuFromBytes(glb, ".", sk, ch, err), err);
    assert(ch.materials.length == 3);
    assert(ch.findMaterial("pele") == 0);
    assert(ch.findMaterial("farda") == 1);
    assert(ch.findMaterial("quepe") == 2);
    assert(ch.materials[2].doubleSided == true);
    assert(ch.subMeshes.length == 3);
    assert(ch.subMeshes[0].meshName == "corpo" && ch.subMeshes[0].materialName == "pele");
    assert(ch.subMeshes[1].meshName == "corpo" && ch.subMeshes[1].materialName == "farda");
    assert(ch.subMeshes[2].meshName == "acessorio_quepe" && ch.subMeshes[2].materialName == "quepe");
    assert(abs(ch.subMeshes[0].vertices[0].weights[0] - 0.5f) < 1e-5f);
    assert(abs(ch.subMeshes[0].vertices[0].weights[1] - 0.5f) < 1e-5f);
    assert(ch.subMeshes[0].vertices[1].uv[0] == 1.0f);
    assert(abs(ch.subMeshes[0].vertices[0].tangent[0] - 1.0f) < 1e-4f);
    assert(ch.subMeshes[2].vertices[0].joints[0] == 1);
}
