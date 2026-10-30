/// Skeleton helpers: traversal and rest-pose matrices (port of ozz `skeleton_utils.h`).
module engine.animation.skeleton_utils;

import engine.animation.local_to_model;
import engine.animation.math.simd;
import engine.animation.math.soa;
import engine.animation.skeleton;

@safe:

/// Visits every joint depth-first, parents before children. `fn(joint, parent)` is called with
/// `parent == kNoParent` for roots. Joints are stored in depth-first order, so this is a linear scan.
void iterateJointsDF(alias fn)(ref const Skeleton s) {
    foreach (i; 0 .. s.numJoints) fn(i, s.parents[i]);
}

/// Visits every joint in reverse depth-first order: children before parents.
void iterateJointsDFReverse(alias fn)(ref const Skeleton s) {
    for (int i = s.numJoints - 1; i >= 0; --i) fn(i, s.parents[i]);
}

/// Rest pose of `joint` as a parent-relative matrix.
Float4x4 getJointRestPoseLocalSpace(ref const Skeleton s, int joint) pure nothrow @nogc {
    Float4x4[4] aos;
    const t = s.restPoses[joint / 4];
    toAos(SoaFloat4x4.fromAffine(t.translation, t.rotation, t.scale), aos);
    return aos[joint & 3];
}

/// Rest pose of every joint in model space, written to `output` (needs `numJoints` entries).
/// Returns false if `output` is too small.
bool getRestPoseModelSpace(ref const Skeleton s, Float4x4[] output) pure nothrow @nogc @trusted {
    LocalToModelJob job;
    job.skeleton = &s;
    job.input = s.restPoses;
    job.output = output;
    return job.run();
}

version (unittest) import engine.animation.testing : loadFixture;
version (unittest) import engine.animation.io.archive : InputArchive;

unittest {
    auto ar = InputArchive(loadFixture("pab/skeleton.ozz"));
    Skeleton s;
    assert(loadSkeleton(ar, s));

    // Forward visits parents first; reverse visits the same joints children first.
    auto seen = new bool[s.numJoints];
    int count;
    iterateJointsDF!((int i, int p) {
        assert(p == kNoParent || seen[p]);
        seen[i] = true;
        ++count;
    })(s);
    assert(count == s.numJoints);

    auto done = new bool[s.numJoints];
    iterateJointsDFReverse!((int i, int p) {
        foreach (c; 0 .. s.numJoints) if (s.parents[c] == i) assert(done[c]);
        done[i] = true;
    })(s);

    // Model-space rest pose chains the local-space ones.
    auto model = new Float4x4[s.numJoints];
    assert(getRestPoseModelSpace(s, model));
    assert(!getRestPoseModelSpace(s, model[0 .. 1]));
    foreach (i; 0 .. s.numJoints) {
        auto want = getJointRestPoseLocalSpace(s, i);
        for (int p = s.parents[i]; p != kNoParent; p = s.parents[p])
            want = getJointRestPoseLocalSpace(s, p) * want;
        foreach (c; 0 .. 4) foreach (r; 0 .. 4) {
            import std.math : abs;
            assert(abs(model[i].cols[c][r] - want.cols[c][r]) < 1e-4f);
        }
    }
}
