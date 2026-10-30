/// glTF skin import: joints, inverse bind matrices and per-vertex weights, bound to an ozz skeleton
/// by joint name. Only the first skin and the first primitive of the first mesh are read.
module engine.animation.gltf_skin;

import engine.animation.ecs.assets : SkinBinding;
import engine.animation.math.simd;
import engine.animation.skeleton;

@safe:

/// Per-vertex skinning attributes of the first primitive.
struct GltfSkinVertices {
    /// 4 skin-joint indices per vertex (indices into `SkinBinding.remap`).
    ushort[] joints;
    /// 4 weights per vertex.
    float[] weights;
}

private enum uint CT_UBYTE = 5121, CT_USHORT = 5123, CT_FLOAT = 5126;

/// Loads the skin of `gltfPath`. Skin joints are matched to `skeleton` joints by node name; a joint
/// with no match makes the load fail, naming the joint in `error`.
bool loadGltfSkin(string gltfPath, ref const Skeleton skeleton, out SkinBinding binding,
                  out GltfSkinVertices vertices, out string error) @trusted {
    import std.file : read;
    import std.json;
    import std.path : buildPath, dirName;
    try {
        auto root = parseJSON(cast(string) read(gltfPath));
        if (!("skins" in root) || root["skins"].array.length == 0) { error = "glTF: no skins"; return false; }
        auto skin = root["skins"].array[0];
        auto nodes = root["nodes"].array;
        auto accessors = root["accessors"].array;
        auto bufferViews = root["bufferViews"].array;

        const(ubyte)[][] buffers;
        foreach (b; root["buffers"].array) {
            if (!("uri" in b.object)) { error = "glTF: embedded buffers unsupported"; return false; }
            buffers ~= cast(const(ubyte)[]) read(buildPath(dirName(gltfPath), b["uri"].str));
        }

        // Bytes of accessor `ai`, plus count and component size, bounds-checked.
        const(ubyte)[] view(long ai, uint comps, uint compSize, uint[] allowed, out size_t count, out uint ctype) {
            auto acc = accessors[cast(size_t) ai];
            ctype = cast(uint) acc["componentType"].integer;
            bool ok;
            foreach (a; allowed) if (a == ctype) ok = true;
            if (!ok) throw new Exception("glTF: unsupported component type");
            count = cast(size_t) acc["count"].integer;
            auto bv = bufferViews[cast(size_t) acc["bufferView"].integer];
            immutable off = ("byteOffset" in bv.object ? cast(size_t) bv["byteOffset"].integer : 0)
                          + ("byteOffset" in acc.object ? cast(size_t) acc["byteOffset"].integer : 0);
            immutable len = count * comps * compSize;
            auto buf = buffers[cast(size_t) bv["buffer"].integer];
            if (off + len > buf.length) throw new Exception("glTF: accessor out of buffer bounds");
            return buf[off .. off + len];
        }

        auto joints = skin["joints"].array;
        size_t ibCount;
        uint ct;
        const ibBytes = "inverseBindMatrices" in skin.object
            ? view(skin["inverseBindMatrices"].integer, 16, 4, [CT_FLOAT], ibCount, ct) : null;
        if (ibBytes !is null && ibCount < joints.length) { error = "glTF: too few inverse bind matrices"; return false; }

        binding = SkinBinding.init;
        foreach (ji, jn; joints) {
            auto node = nodes[cast(size_t) jn.integer];
            immutable name = "name" in node.object ? node["name"].str : "";
            immutable sj = findJoint(skeleton, name);
            if (sj < 0) { error = "glTF: skin joint '" ~ name ~ "' not in skeleton"; return false; }
            binding.remap ~= cast(uint) sj;
            Float4x4 m = Float4x4.identity();
            if (ibBytes !is null) {
                foreach (c; 0 .. 4) {
                    float[4] col;
                    foreach (r; 0 .. 4) {
                        immutable o = (ji * 16 + c * 4 + r) * 4;
                        col[r] = *cast(const(float)*)(ibBytes.ptr + o);
                    }
                    m.cols[c] = SimdFloat4(col[0], col[1], col[2], col[3]);
                }
            }
            binding.inverseBinds ~= m;
        }

        auto prim = root["meshes"].array[0]["primitives"].array[0];
        auto attrs = prim["attributes"].object;
        if (!("JOINTS_0" in attrs) || !("WEIGHTS_0" in attrs)) { error = "glTF: primitive has no JOINTS_0/WEIGHTS_0"; return false; }

        size_t n, nw;
        // JOINTS_0 may be ubyte or ushort.
        immutable jct = cast(uint) accessors[cast(size_t) attrs["JOINTS_0"].integer]["componentType"].integer;
        immutable jsize = jct == CT_USHORT ? 2u : 1u;
        const jbytes = view(attrs["JOINTS_0"].integer, 4, jsize, [CT_UBYTE, CT_USHORT], n, ct);
        const wbytes = view(attrs["WEIGHTS_0"].integer, 4, 4, [CT_FLOAT], nw, ct);
        if (n != nw) { error = "glTF: JOINTS_0/WEIGHTS_0 count mismatch"; return false; }
        vertices.joints = new ushort[n * 4];
        vertices.weights = new float[n * 4];
        foreach (i; 0 .. n * 4) {
            immutable j = jsize == 2 ? *cast(const(ushort)*)(jbytes.ptr + i * 2) : jbytes[i];
            if (j >= joints.length) { error = "glTF: vertex joint index out of range"; return false; }
            vertices.joints[i] = j;
            vertices.weights[i] = *cast(const(float)*)(wbytes.ptr + i * 4);
        }
        return true;
    } catch (Exception e) {
        error = e.msg;
        return false;
    }
}

version (unittest) {
    import engine.animation.io.archive : InputArchive;
    import engine.animation.testing : loadFixture;
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
