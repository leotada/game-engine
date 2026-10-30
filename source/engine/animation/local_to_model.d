// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/local_to_model_job.cc @ 744eb9d
/// Converts a local-space SoA pose into model-space matrices by walking the (depth-first
/// ordered) joint hierarchy. Supports updating only a sub-hierarchy through `from` / `to`.
module engine.animation.local_to_model;

import engine.animation.math.simd;
import engine.animation.math.soa;
import engine.animation.skeleton;

@safe:

struct LocalToModelJob {
    const(Skeleton)* skeleton;
    /// Matrix applied to root joints; identity when null.
    const(Float4x4)* root;
    /// First joint to update, `kNoParent` to start from the roots.
    int from = kNoParent;
    /// Last joint to update (inclusive).
    int to = kMaxJoints;
    /// If true, `from` itself is not updated, only its descendants. Its model matrix must
    /// already be present in `output`.
    bool fromExcluded;
    const(SoaTransform)[] input;
    Float4x4[] output;

    bool validate() const scope pure nothrow @nogc {
        if (skeleton is null) return false;
        immutable numJoints = skeleton.numJoints;
        return input.length >= (numJoints + 3) / 4 && output.length >= numJoints;
    }

    bool run() scope pure nothrow @nogc {
        if (!validate()) return false;
        const parents = skeleton.parents;
        immutable identity = Float4x4.identity();

        immutable end = to + 1 < skeleton.numJoints ? to + 1 : skeleton.numJoints;
        int i = from + (fromExcluded ? 1 : 0);
        if (i < 0) i = 0;
        bool process = i < end && (!fromExcluded || parents[i] >= from);

        run_(parents, identity, i, end, process);
        return true;
    }

    /// Hot loop. Unchecked indexing is sound here: `validate()` guarantees `input` covers every
    /// SoA block and `output` every joint, `i < end <= numJoints`, and `loadSkeleton` guarantees
    /// `parents[i] < i` (so a parent index is always a valid, already-written output entry).
    private void run_(const(short)[] parents, ref const Float4x4 identity, int i, int end, bool process)
            scope pure nothrow @nogc @trusted {
        const(short)* par = parents.ptr;
        Float4x4* out_ = output.ptr;
        const(SoaTransform)* in_ = input.ptr;
        Float4x4[4] local = void;
        while (process) {
            const t = in_ + (i >> 2);
            toAos(SoaFloat4x4.fromAffine(t.translation, t.rotation, t.scale), local);

            immutable soaEnd = (i + 4) & ~3;
            for (; i < soaEnd && process; ) {
                immutable parent = par[i];
                const(Float4x4)* parentMatrix = parent == kNoParent
                    ? (root is null ? &identity : root) : out_ + parent;
                out_[i] = *parentMatrix * local[i & 3];
                ++i;
                process = i < end && par[i] >= from;
            }
        }
    }
}

version (unittest) {
    import engine.animation.io.archive : InputArchive;
    import engine.animation.testing : loadFixture, near;
    import engine.animation.clip;
    import engine.animation.sampling;

    private Skeleton loadSkel(string name) {
        auto ar = InputArchive(loadFixture(name));
        Skeleton s;
        assert(loadSkeleton(ar, s), ar.error);
        return s;
    }

    private bool eq(const Float4x4 a, const Float4x4 b, float tol = 1e-4f) {
        foreach (c; 0 .. 4) {
            foreach (r; 0 .. 4) {
                if (!near(a.cols[c][r], b.cols[c][r], tol)) return false;
            }
        }
        return true;
    }

    private Float4x4 localMatrix(ref const Skeleton s, const(SoaTransform)[] pose, int joint) {
        Float4x4[4] aos;
        const t = pose[joint / 4];
        toAos(SoaFloat4x4.fromAffine(t.translation, t.rotation, t.scale), aos);
        return aos[joint & 3];
    }
}

unittest {
    // Full run equals a naive recursive evaluation, for rest poses and a sampled pose.
    foreach (skelName; ["pab/skeleton.ozz", "ruby_skeleton.ozz", "robot_skeleton.ozz"]) {
        auto s = loadSkel(skelName);
        auto out_ = new Float4x4[s.numJoints];
        LocalToModelJob job;
        job.skeleton = &s;
        job.input = s.restPoses;
        job.output = out_;
        assert(job.run());
        foreach (i; 0 .. s.numJoints) {
            auto want = localMatrix(s, s.restPoses, i);
            for (int p = s.parents[i]; p != kNoParent; p = s.parents[p]) {
                want = localMatrix(s, s.restPoses, p) * want;
            }
            assert(eq(out_[i], want), skelName);
        }
    }
}

unittest {
    // Root matrix is applied to root joints (and so to everything below).
    auto s = loadSkel("pab/skeleton.ozz");
    auto plain = new Float4x4[s.numJoints];
    auto moved = new Float4x4[s.numJoints];
    Float4x4 root = Float4x4.identity();
    root.cols[3] = SimdFloat4(10, 20, 30, 1);
    LocalToModelJob job;
    job.skeleton = &s;
    job.input = s.restPoses;
    job.output = plain;
    assert(job.run());
    job.root = &root;
    job.output = moved;
    assert(job.run());
    foreach (i; 0 .. s.numJoints) assert(eq(moved[i], root * plain[i]));
}

unittest {
    // Partial updates: only descendants of `from` (up to `to`) are rewritten, with the same
    // values as a full update.
    auto s = loadSkel("ruby_skeleton.ozz");
    auto full = new Float4x4[s.numJoints];
    LocalToModelJob job;
    job.skeleton = &s;
    job.input = s.restPoses;
    job.output = full;
    assert(job.run());

    bool isDescendant(int j, int anc) {
        for (int p = j; p != kNoParent; p = s.parents[p]) {
            if (p == anc) return true;
        }
        return false;
    }

    foreach (from; [0, 3, s.numJoints / 2, s.numJoints - 1]) {
        foreach (excluded; [false, true]) {
            foreach (to; [from, from + 5, kMaxJoints]) {
                auto buf = new Float4x4[s.numJoints];
                foreach (ref m; buf) m.cols[0] = SimdFloat4.load1(-1); // garbage marker
                // Parents of `from` (and `from` when excluded) must already be valid.
                foreach (i; 0 .. s.numJoints) {
                    if (i < from || (excluded && i == from)) buf[i] = full[i];
                }
                job.from = from;
                job.to = to;
                job.fromExcluded = excluded;
                job.output = buf;
                assert(job.run());
                foreach (i; 0 .. s.numJoints) {
                    immutable processed = i <= to && isDescendant(i, from) && !(excluded && i == from);
                    if (processed) {
                        assert(eq(buf[i], full[i]), "joint not updated");
                    } else if (i >= from && !(excluded && i == from)) {
                        assert(buf[i].cols[0] == SimdFloat4.load1(-1), "joint touched outside range");
                    }
                }
            }
        }
    }
}

unittest {
    // Sampled animation drives model-space joints; zero GC allocations in run().
    import core.memory : GC;
    auto s = loadSkel("pab/skeleton.ozz");
    auto aar = InputArchive(loadFixture("pab/walk.ozz"));
    Animation a;
    assert(loadAnimation(aar, a));
    auto ctx = SamplingContext(s.numJoints);
    auto pose = new SoaTransform[s.numSoaJoints];
    SamplingJob sj;
    sj.animation = &a;
    sj.context = &ctx;
    sj.output = pose;
    sj.ratio = 0.3f;
    assert(sj.run());
    auto out_ = new Float4x4[s.numJoints];
    LocalToModelJob job;
    job.skeleton = &s;
    job.input = pose;
    job.output = out_;
    assert(job.run());
    immutable before = GC.stats().usedSize;
    foreach (i; 0 .. 100) assert(job.run());
    assert(GC.stats().usedSize == before);
    foreach (ref m; out_) assert(near(m.cols[3].w, 1.0f));
}

unittest {
    // Validation.
    auto s = loadSkel("robot_skeleton.ozz");
    LocalToModelJob job;
    assert(!job.run());
    job.skeleton = &s;
    assert(!job.validate());
    job.input = s.restPoses;
    job.output = new Float4x4[s.numJoints - 1];
    assert(!job.validate());
}
