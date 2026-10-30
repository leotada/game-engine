// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/track_sampling_job.cc @ 744eb9d
/// Samples a `Track` at a time ratio.
module engine.animation.track_sampling;

import engine.animation.math.scalar;
import engine.animation.track;

@safe:

struct TrackSamplingJob(T) {
    float ratio = 0;
    const(Track!T)* track;
    T* result;

    bool validate() const scope pure nothrow @nogc { return track !is null && result !is null; }

    bool run() scope pure nothrow @nogc @trusted {
        if (!validate()) return false;
        const ratios = track.ratios;
        const values = track.values;
        alias Policy = TrackPolicy!T;
        if (ratios.length == 0) {
            *result = Policy.identity();
        } else if (ratios.length == 1 || ratio <= 0.0f) {
            *result = values[0];
        } else if (ratio >= 1.0f) {
            *result = values[$ - 1];
        } else {
            // First key with a ratio greater than `ratio` (upper bound).
            size_t lo = 0, hi = ratios.length;
            while (lo < hi) {
                immutable mid = lo + (hi - lo) / 2;
                if (ratios[mid] > ratio) hi = mid; else lo = mid + 1;
            }
            immutable id1 = lo;
            immutable id0 = id1 - 1;
            if (track.isStep(id0) || id1 == ratios.length) {
                *result = values[id0];
            } else {
                immutable tk0 = ratios[id0];
                immutable tk1 = ratios[id1];
                *result = Policy.lerp(values[id0], values[id1], (ratio - tk0) / (tk1 - tk0));
            }
        }
        return true;
    }
}

alias FloatTrackSamplingJob = TrackSamplingJob!float;
alias Float2TrackSamplingJob = TrackSamplingJob!Vec2;
alias Float3TrackSamplingJob = TrackSamplingJob!Vec3;
alias Float4TrackSamplingJob = TrackSamplingJob!Vec4;
alias QuaternionTrackSamplingJob = TrackSamplingJob!Quat;

version (unittest) {
    private FloatTrack mk(float[] r, float[] v, ubyte[] steps) {
        FloatTrack t;
        t.ratios = r;
        t.values = v;
        t.steps = steps;
        return t;
    }
    private float sampleAt(const FloatTrack t, float ratio) {
        float res = -99;
        FloatTrackSamplingJob j;
        j.ratio = ratio;
        j.track = &t;
        j.result = &res;
        assert(j.run());
        return res;
    }
}

unittest {
    // Empty track -> identity; single key -> that value.
    assert(sampleAt(mk([], [], []), 0.5f) == 0.0f);
    assert(sampleAt(mk([0.3f], [7], [0]), 0.9f) == 7.0f);
    // Linear: clamped at the ends, lerped inside.
    auto lin = mk([0, 0.5f, 1], [0, 10, 20], [0]);
    assert(sampleAt(lin, -1) == 0 && sampleAt(lin, 2) == 20);
    assert(sampleAt(lin, 0.25f) == 5.0f && sampleAt(lin, 0.5f) == 10.0f && sampleAt(lin, 0.75f) == 15.0f);
    // Step on key 0 holds value 0 until key 1.
    auto stp = mk([0, 0.5f, 1], [0, 10, 20], [0b001]);
    assert(sampleAt(stp, 0.25f) == 0.0f && sampleAt(stp, 0.5f) == 10.0f && sampleAt(stp, 0.75f) == 15.0f);
}

unittest {
    // Vector and quaternion tracks; invalid job.
    Float3Track t;
    t.ratios = [0, 1];
    t.values = [Vec3(0, 0, 0), Vec3(2, 4, 6)];
    t.steps = [0];
    Vec3 r;
    Float3TrackSamplingJob j;
    assert(!j.run());
    j.ratio = 0.5f;
    j.track = &t;
    j.result = &r;
    assert(j.run() && r == Vec3(1, 2, 3));

    QuaternionTrack q;
    q.ratios = [0, 1];
    q.values = [Quat(0, 0, 0, 1), Quat(0, 0, 1, 0)];
    q.steps = [0];
    Quat qr;
    QuaternionTrackSamplingJob qj;
    qj.ratio = 0.5f;
    qj.track = &q;
    qj.result = &qr;
    assert(qj.run());
    import std.math : abs, sqrt;
    assert(abs(qr.z - sqrt(0.5f)) < 1e-6f && abs(qr.w - sqrt(0.5f)) < 1e-6f);
}

unittest {
    // Real tracks: monotonic sampling stays within the value range of the grasp track.
    import engine.animation.io.archive : InputArchive;
    import engine.animation.testing : loadFixture;
    auto ar = InputArchive(loadFixture("robot_track_grasp.ozz"));
    FloatTrack t;
    assert(loadTrack(ar, t));
    float lo = float.max, hi = -float.max;
    foreach (v; t.values) { if (v < lo) lo = v; if (v > hi) hi = v; }
    foreach (i; 0 .. 101) {
        immutable v = sampleAt(t, i / 100.0f);
        assert(v >= lo - 1e-5f && v <= hi + 1e-5f);
    }
    assert(sampleAt(t, 0) == t.values[0] && sampleAt(t, 1) == t.values[$ - 1]);
}
