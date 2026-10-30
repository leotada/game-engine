// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/track.cc + include/ozz/animation/runtime/track.h @ 744eb9d
/// Runtime user-channel tracks: a sequence of keys (ratio, value, step flag) for one value type.
module engine.animation.track;

import engine.animation.io.archive;
import engine.animation.math.scalar;

@safe:

/// Operations the sampler needs per value type.
struct TrackPolicy(T) {
    static T lerp(T a, T b, float alpha) pure nothrow @nogc {
        static if (is(T == Quat)) return nlerp(a, b, alpha);
        else return .lerp(a, b, alpha);
    }

    static T identity() pure nothrow @nogc {
        static if (is(T == Quat)) return Quat(0, 0, 0, 1);
        else static if (is(T == float)) return 0.0f;
        else return T.init;
    }
}

private template trackTag(T) {
    static if (is(T == float)) enum trackTag = "ozz-float_track\0";
    else static if (is(T == Vec2)) enum trackTag = "ozz-float2_track\0";
    else static if (is(T == Vec3)) enum trackTag = "ozz-float3_track\0";
    else static if (is(T == Vec4)) enum trackTag = "ozz-float4_track\0";
    else static if (is(T == Quat)) enum trackTag = "ozz-quat_track\0";
    else static assert(false, "unsupported track type");
}

struct Track(T) {
    /// Key times in `[0, 1]`, sorted ascending.
    float[] ratios;
    T[] values;
    /// Bit `i` set: key `i` is a step (value held until key `i + 1`) instead of linear.
    ubyte[] steps;
    string name;

    bool isStep(size_t i) const pure nothrow @nogc { return (steps[i / 8] & (1 << (i & 7))) != 0; }
}

alias FloatTrack = Track!float;
alias Float2Track = Track!Vec2;
alias Float3Track = Track!Vec3;
alias Float4Track = Track!Vec4;
alias QuaternionTrack = Track!Quat;

private T readValue(T)(ref InputArchive ar) {
    static if (is(T == float)) return ar.read!float();
    else static if (is(T == Vec2)) { immutable x = ar.read!float(); immutable y = ar.read!float(); return Vec2(x, y); }
    else static if (is(T == Vec3)) {
        immutable x = ar.read!float(); immutable y = ar.read!float(); immutable z = ar.read!float();
        return Vec3(x, y, z);
    } else {
        immutable x = ar.read!float(); immutable y = ar.read!float();
        immutable z = ar.read!float(); immutable w = ar.read!float();
        return T(x, y, z, w);
    }
}

/// Reads one track (version 1) of type `T`. Validates sizes and key ordering.
bool loadTrack(T)(ref InputArchive ar, out Track!T track) {
    uint ver;
    if (!ar.beginObject(trackTag!T, ver)) return false;
    if (ver != 1) {
        ar.fail("unsupported track version");
        return false;
    }
    immutable numKeys = ar.read!uint();
    immutable nameLen = ar.read!int();
    if (!ar.ok) return false;
    if (nameLen < 0 || numKeys > ar.remaining() || cast(size_t) nameLen > ar.remaining()) {
        ar.fail("track section size exceeds archive");
        return false;
    }
    Track!T t;
    t.ratios = new float[numKeys];
    ar.readArray(t.ratios);
    t.values = new T[numKeys];
    foreach (ref v; t.values) v = readValue!T(ar);
    t.steps = new ubyte[(numKeys + 7) / 8];
    ar.readArray(t.steps);
    auto nameBytes = ar.readBytes(nameLen);
    if (!ar.ok) return false;
    t.name = (cast(const(char)[]) nameBytes).idup;

    float prev = 0;
    foreach (r; t.ratios) {
        if (!(r >= prev) || r > 1.0f) {
            ar.fail("track ratios not sorted in [0, 1]");
            return false;
        }
        prev = r;
    }
    track = t;
    return true;
}

unittest {
    import engine.animation.testing : loadFixture;
    {
        auto ar = InputArchive(loadFixture("robot_track_grasp.ozz"));
        FloatTrack t;
        assert(loadTrack(ar, t), ar.error);
        assert(t.ratios.length == 14 && t.values.length == 14 && t.steps.length == 2);
        assert(t.name.length == 12);
        assert(t.ratios[0] == 0.0f && t.ratios[$ - 1] == 1.0f);
    }
    {
        auto ar = InputArchive(loadFixture("pab/walk_motion_track.ozz"));
        Float3Track t;
        assert(loadTrack(ar, t), ar.error);
        assert(t.ratios.length == 17 && t.values.length == 17);
    }
    {
        // Wrong type tag is rejected without consuming the archive.
        auto ar = InputArchive(loadFixture("robot_track_grasp.ozz"));
        Float3Track t;
        assert(!loadTrack(ar, t));
    }
    {
        // Truncation at any length fails cleanly.
        auto data = loadFixture("robot_track_grasp.ozz");
        FloatTrack t;
        foreach (n; 0 .. data.length) {
            auto ar = InputArchive(data[0 .. n]);
            assert(!loadTrack(ar, t));
        }
    }
}
