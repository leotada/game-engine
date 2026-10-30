/// Procedural skinned mesh for any skeleton: one tapered prism per bone, from the parent joint to
/// the joint, with vertices blended between the two joints (so bending shows smooth skinning).
/// Meant for previews and tests; real characters come from `gltf_skin`.
module engine.animation.bone_mesh;

import engine.animation.ecs.assets : SkinBinding;
import engine.animation.skeleton_utils : getRestPoseModelSpace;
import engine.animation.math.matrix;
import engine.animation.math.scalar : Vec3;
import engine.animation.math.simd;
import engine.animation.skeleton;
import std.math : sqrt, abs;

@safe:

/// CPU-side vertex (same layout as `engine.gpu.skinned.SkinnedVertex`, which this module does not
/// import so it stays free of GPU dependencies).
struct BoneVertex {
    float[3] position = 0;
    float[3] normal = 0;
    uint[4] joints = 0;
    float[4] weights = 0;
}

struct BoneMesh {
    BoneVertex[] vertices;
    uint[] indices;
    /// Inverse bind matrices per skeleton joint (identity remap).
    SkinBinding binding;
}

private Vec3 sub(Vec3 a, Vec3 b) { return Vec3(a.x - b.x, a.y - b.y, a.z - b.z); }
private Vec3 add(Vec3 a, Vec3 b) { return Vec3(a.x + b.x, a.y + b.y, a.z + b.z); }
private Vec3 mul(Vec3 a, float s) { return Vec3(a.x * s, a.y * s, a.z * s); }
private float dot(Vec3 a, Vec3 b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
private Vec3 cross(Vec3 a, Vec3 b) { return Vec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x); }
private Vec3 norm(Vec3 a) { immutable l = sqrt(dot(a, a)); return l > 0 ? mul(a, 1 / l) : Vec3(0, 1, 0); }

/// Builds the mesh in the skeleton's rest pose (model space). `radius` is the prism half-width at
/// the parent end; it tapers to 40% at the child end.
BoneMesh buildBoneMesh(ref const Skeleton skeleton, float radius = 0.02f) {
    BoneMesh mesh;
    auto model = new Float4x4[skeleton.numJoints];
    getRestPoseModelSpace(skeleton, model);

    foreach (j; 0 .. skeleton.numJoints) {
        bool ok;
        mesh.binding.remap ~= cast(uint) j;
        mesh.binding.inverseBinds ~= invert(model[j], ok);
    }

    foreach (j; 0 .. skeleton.numJoints) {
        immutable parent = skeleton.parents[j];
        if (parent == kNoParent) continue;
        immutable a = translationOf(model[parent]), b = translationOf(model[j]);
        immutable axis = sub(b, a);
        immutable len = sqrt(dot(axis, axis));
        if (len < 1e-5f) continue;
        immutable dir = mul(axis, 1 / len);
        immutable helper = abs(dir.y) < 0.9f ? Vec3(0, 1, 0) : Vec3(1, 0, 0);
        immutable u = norm(cross(dir, helper));
        immutable v = cross(dir, u);
        immutable base = cast(uint) mesh.vertices.length;
        // Four ring vertices at each end (a square prism); the parent ring is weighted fully to the
        // parent joint, the child ring to the child joint, middle-skin comes from the shared normal.
        foreach (end; 0 .. 2) {
            immutable center = end == 0 ? a : b;
            immutable r = radius * (end == 0 ? 1.0f : 0.4f);
            foreach (k; 0 .. 4) {
                immutable angle = k * 1.5707964f + 0.7853982f;
                import std.math : cos, sin;
                immutable n = add(mul(u, cos(angle)), mul(v, sin(angle)));
                immutable p = add(center, mul(n, r));
                BoneVertex vert;
                vert.position = [p.x, p.y, p.z];
                vert.normal = [n.x, n.y, n.z];
                vert.joints = [end == 0 ? cast(uint) parent : cast(uint) j, 0, 0, 0];
                vert.weights = [1, 0, 0, 0];
                mesh.vertices ~= vert;
            }
        }
        foreach (k; 0 .. 4) {
            immutable k2 = (k + 1) % 4;
            mesh.indices ~= [base + k, base + 4 + k, base + 4 + k2, base + k, base + 4 + k2, base + k2];
        }
    }
    return mesh;
}

unittest {
    import engine.animation.io.archive : InputArchive;
    import engine.animation.skinning;
    import engine.animation.testing : loadFixture, near;

    auto ar = InputArchive(loadFixture("pab/skeleton.ozz"));
    Skeleton s;
    assert(loadSkeleton(ar, s));
    auto mesh = buildBoneMesh(s);
    assert(mesh.vertices.length > 0 && mesh.indices.length % 3 == 0);
    foreach (i; mesh.indices) assert(i < mesh.vertices.length);

    // With the rest pose, palette = model * inverseBind = identity: skinning must reproduce the
    // bind-pose positions.
    auto model = new Float4x4[s.numJoints];
    assert(getRestPoseModelSpace(s, model));
    auto palette = new Float4x4[s.numJoints];
    foreach (j; 0 .. s.numJoints) palette[j] = model[j] * mesh.binding.inverseBinds[j];
    foreach (j; 0 .. s.numJoints)
        foreach (c; 0 .. 4) foreach (r; 0 .. 4)
            assert(near(palette[j].cols[c][r], c == r ? 1.0f : 0.0f, 1e-3f));

    // A moved joint drags exactly the vertices weighted to it.
    palette[1] = Float4x4.identity();
    palette[1].cols[3] = SimdFloat4(0, 5, 0, 1);
    foreach (v; mesh.vertices) {
        immutable moved = v.joints[0] == 1;
        immutable p = transformPoint(palette[v.joints[0]], Vec3(v.position[0], v.position[1], v.position[2]));
        assert(moved ? near(p.y, v.position[1] + 5, 1e-4f) : near(p.y, v.position[1], 1e-4f));
    }
}
