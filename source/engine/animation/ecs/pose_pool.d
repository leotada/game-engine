/// Per-character runtime buffers, allocated at spawn and recycled at despawn, never in the frame
/// path. Indexed by `AnimSkeleton.poseSlot`.
module engine.animation.ecs.pose_pool;

import engine.animation.math.simd;
import engine.animation.math.soa;
import engine.animation.sampling;
import engine.core.pod : Pod;
import engine.math.mat : Mat4;

@safe:

static assert(Float4x4.sizeof == Mat4.sizeof, "Float4x4 must be layout-compatible with Mat4");

struct Pose {
    int numJoints;
    bool used;
    /// Sampled local poses: layer 0 (base / clip A), layer 1 (clip B), layer 2 (additive).
    Pod!SoaTransform[] local0, local1, local2;
    /// Blended local pose (input of local-to-model).
    Pod!SoaTransform[] blended;
    Pod!Float4x4[] model;
    Pod!Float4x4[] palette;
    SamplingContext ctx0, ctx1, ctx2;
}

struct PosePool {
    private Pose[] slots_;
    private uint[] free_;

    /// Acquires buffers for `numJoints` joints. Returns the slot index.
    uint acquire(int numJoints) {
        uint idx;
        if (free_.length > 0) {
            idx = free_[$ - 1];
            free_.length = free_.length - 1;
        } else {
            idx = cast(uint) slots_.length;
            slots_ ~= Pose.init;
        }
        immutable soa = (numJoints + 3) / 4;
        Pose p;
        p.numJoints = numJoints;
        p.used = true;
        p.local0 = new SoaTransform[soa];
        p.local1 = new SoaTransform[soa];
        p.local2 = new SoaTransform[soa];
        p.blended = new SoaTransform[soa];
        p.model = new Float4x4[numJoints];
        p.palette = new Float4x4[numJoints];
        foreach (ref m; p.model) m = Float4x4.identity();
        foreach (ref m; p.palette) m = Float4x4.identity();
        p.ctx0 = SamplingContext(numJoints);
        p.ctx1 = SamplingContext(numJoints);
        p.ctx2 = SamplingContext(numJoints);
        slots_[idx] = p;
        return idx;
    }

    void release(uint slot) {
        if (slot >= slots_.length || !slots_[slot].used) return;
        slots_[slot] = Pose.init;
        free_ ~= slot;
    }

    /// The pose for `slot`, or null if it is not in use.
    Pose* get(uint slot) pure nothrow @nogc @trusted {
        return (slot < slots_.length && slots_[slot].used) ? &slots_[slot] : null;
    }

    size_t activeCount() const pure nothrow @nogc {
        size_t n = 0;
        foreach (ref s; slots_) if (s.used) ++n;
        return n;
    }
}

/// Zero-copy view of a `Float4x4` array as engine `Mat4`s (GPU upload).
const(Mat4)[] asMat4(const(Float4x4)[] s) @trusted pure nothrow @nogc {
    return (cast(const(Mat4)*) s.ptr)[0 .. s.length];
}

unittest {
    PosePool pool;
    immutable a = pool.acquire(67);
    immutable b = pool.acquire(10);
    assert(a != b && pool.activeCount == 2);
    assert(pool.get(a).model.length == 67 && pool.get(a).local0.length == 17);
    assert(pool.get(a).ctx0.maxTracks >= 67);
    pool.release(a);
    assert(pool.get(a) is null && pool.activeCount == 1);
    immutable c = pool.acquire(4);
    assert(c == a); // recycled
    // Identity matrices view as identity Mat4.
    auto v = asMat4(pool.get(c).model);
    assert(v[0] == Mat4.identity());
    pool.release(99); // out of range is ignored
}
