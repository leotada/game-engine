// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/skeleton.cc + skeleton_utils.cc @ 744eb9d
/// Runtime skeleton: joint hierarchy (depth-first order), names and SoA rest poses.
module engine.animation.skeleton;

import engine.animation.io.archive;
import engine.animation.io.math_archive;
import engine.animation.math.soa;

@safe:

enum int kMaxJoints = 1024;
enum int kMaxSoaJoints = (kMaxJoints + 3) / 4;
enum int kNoParent = -1;

enum string skeletonTag = "ozz-skeleton\0";

struct Skeleton {
    @safe pure nothrow:
    /// Rest pose of every joint, 4 joints per `SoaTransform`.
    SoaTransform[] restPoses;
    /// Parent index per joint, `kNoParent` for roots. A parent always precedes its children.
    short[] parents;
    private char[] names_; // NUL-separated, contiguous
    private uint[] nameOffsets_;

    int numJoints() const @nogc { return cast(int) parents.length; }
    int numSoaJoints() const @nogc { return (numJoints + 3) / 4; }

    const(char)[] jointName(int i) const @nogc {
        immutable begin = nameOffsets_[i];
        size_t end = begin;
        while (names_[end] != 0) ++end;
        return names_[begin .. end];
    }
}

/// Reads one skeleton (tag, version 2) from `ar` and validates its invariants. On failure
/// returns false and leaves the reason in `ar.error`.
bool loadSkeleton(ref InputArchive ar, out Skeleton skel) {
    uint ver;
    if (!ar.beginObject(skeletonTag, ver)) return false;
    if (ver != 2) {
        ar.fail("unsupported skeleton version");
        return false;
    }
    immutable numJoints = ar.read!int();
    if (!ar.ok) return false;
    if (numJoints == 0) return true;
    if (numJoints < 0 || numJoints > kMaxJoints) {
        ar.fail("skeleton joint count out of range");
        return false;
    }
    immutable chars = ar.read!int();
    if (!ar.ok) return false;
    if (chars < numJoints || cast(size_t) chars > ar.remaining()) {
        ar.fail("skeleton name buffer size invalid");
        return false;
    }

    auto names = new char[chars];
    foreach (ref c; names) c = cast(char) ar.read!ubyte();
    auto parents = new short[numJoints];
    ar.readArray(parents);
    auto rest = new SoaTransform[(numJoints + 3) / 4];
    foreach (ref t; rest) t = readSoaTransform(ar);
    if (!ar.ok) return false;

    // Names: exactly numJoints NUL-terminated strings filling the buffer.
    auto offsets = new uint[numJoints];
    size_t cursor = 0;
    foreach (i; 0 .. numJoints) {
        if (cursor >= names.length) {
            ar.fail("skeleton names truncated");
            return false;
        }
        offsets[i] = cast(uint) cursor;
        while (cursor < names.length && names[cursor] != 0) ++cursor;
        if (cursor >= names.length) {
            ar.fail("skeleton name not NUL-terminated");
            return false;
        }
        ++cursor;
    }
    if (cursor != names.length) {
        ar.fail("skeleton name buffer has trailing data");
        return false;
    }

    // Hierarchy: depth-first order, parents precede children.
    foreach (i, p; parents) {
        if (p < kNoParent || p >= cast(int) i) {
            ar.fail("skeleton parent index invalid");
            return false;
        }
    }

    skel.restPoses = rest;
    skel.parents = parents;
    skel.names_ = names;
    skel.nameOffsets_ = offsets;
    return true;
}

/// Index of the joint named `name`, or -1.
int findJoint(ref const Skeleton s, const(char)[] name) pure nothrow @nogc {
    foreach (i; 0 .. s.numJoints) {
        if (s.jointName(i) == name) return i;
    }
    return -1;
}

/// True if joint `i` has no children (children follow their parent in depth-first order).
bool isLeaf(ref const Skeleton s, int i) pure nothrow @nogc {
    return i + 1 >= s.numJoints || s.parents[i + 1] != i;
}

version (unittest) import engine.animation.testing : loadFixture;

unittest {
    foreach (name; ["pab/skeleton.ozz", "ruby_skeleton.ozz", "robot_skeleton.ozz",
                    "versioning/skeleton_v2_le.ozz", "versioning/skeleton_v2_be.ozz"]) {
        auto data = loadFixture(name);
        auto ar = InputArchive(data);
        Skeleton s;
        assert(loadSkeleton(ar, s), name ~ ": " ~ ar.error);
        assert(s.numJoints > 0);
        assert(s.restPoses.length == s.numSoaJoints);
        assert(s.parents[0] == kNoParent);
        assert(s.jointName(0).length > 0);
        assert(findJoint(s, s.jointName(s.numJoints - 1)) >= 0);
    }
}

unittest {
    // Little- and big-endian archives of the same skeleton are identical once loaded.
    auto le = InputArchive(loadFixture("versioning/skeleton_v2_le.ozz"));
    auto be = InputArchive(loadFixture("versioning/skeleton_v2_be.ozz"));
    Skeleton a, b;
    assert(loadSkeleton(le, a) && loadSkeleton(be, b));
    assert(a.parents == b.parents && a.restPoses == b.restPoses);
    foreach (i; 0 .. a.numJoints) assert(a.jointName(i) == b.jointName(i));
}

unittest {
    // v1 is rejected, not crashed on.
    auto ar = InputArchive(loadFixture("versioning/skeleton_v1_le.ozz"));
    Skeleton s;
    assert(!loadSkeleton(ar, s));
    assert(ar.error == "unsupported skeleton version");
}

unittest {
    // Truncating a valid file at any length fails cleanly.
    auto data = loadFixture("robot_skeleton.ozz");
    Skeleton s;
    for (size_t n = 0; n < data.length; n += 7) {
        auto ar = InputArchive(data[0 .. n]);
        assert(!loadSkeleton(ar, s));
    }
    auto full = InputArchive(data);
    assert(loadSkeleton(full, s));
}

unittest {
    auto ar = InputArchive(loadFixture("pab/skeleton.ozz"));
    Skeleton s;
    assert(loadSkeleton(ar, s));
    assert(isLeaf(s, s.numJoints - 1));
    assert(!isLeaf(s, 0) || s.numJoints == 1);
    assert(findJoint(s, "no such joint") == -1);
}
