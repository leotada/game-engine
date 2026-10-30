// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/motion_blending_job.cc @ 744eb9d
/// Blends root-motion deltas (translation / rotation) coming from motion tracks.
module engine.animation.motion_blending;

import engine.animation.math.scalar;
import std.math : copysign, sqrt;

@safe:

struct MotionBlendingJob {
    struct Layer {
        /// Layers with weight <= 0 are ignored.
        float weight = 0;
        const(Transform)* delta;
    }

    const(Layer)[] layers;
    Transform* output;

    bool validate() const scope pure nothrow @nogc {
        if (output is null) return false;
        foreach (ref l; layers) if (l.delta is null) return false;
        return true;
    }

    bool run() scope pure nothrow @nogc @trusted {
        if (!validate()) return false;
        float accWeight = 0;
        float dl = 0;                      // weighted translation lengths
        Vec3 dt = Vec3(0, 0, 0);           // weighted translation directions
        Quat dr = Quat(0, 0, 0, 0);        // weighted rotations
        foreach (ref layer; layers) {
            immutable weight = layer.weight;
            if (weight <= 0.0f) continue;
            accWeight += weight;
            // Split translation into direction and length to limit lerp error on the length.
            immutable len = sqrt(dot(layer.delta.translation, layer.delta.translation));
            dl += len * weight;
            immutable denom = len == 0.0f ? 0.0f : weight / len;
            dt = add(dt, scale(layer.delta.translation, denom));
            // Same hemisphere: negate when the dot with the accumulated rotation is negative.
            immutable signedWeight = copysign(weight, dot(dr, layer.delta.rotation));
            dr = Quat(dr.x + layer.delta.rotation.x * signedWeight, dr.y + layer.delta.rotation.y * signedWeight,
                      dr.z + layer.delta.rotation.z * signedWeight, dr.w + layer.delta.rotation.w * signedWeight);
        }
        immutable denom = sqrt(dot(dt, dt)) * accWeight;
        immutable norm = denom == 0.0f ? 0.0f : dl / denom;
        output.translation = scale(dt, norm);
        immutable l2 = dot(dr, dr);
        output.rotation = l2 == 0.0f ? Quat(0, 0, 0, 1) : normalize(dr);
        output.scale = Vec3(1, 1, 1);
        return true;
    }
}

/// Root-motion accumulation helper: delta between two playback ratios of a looping motion track.
/// `previous` and `current` are the clip ratios of the previous and current frame; when the clip
/// looped (`current < previous`) the delta is split across the loop point.
Vec3 translationDelta(Fn)(scope Fn sample, float previous, float current, bool looped)
        if (is(typeof(sample(0.0f)) == Vec3)) {
    if (!looped) return sub(sample(current), sample(previous));
    return add(sub(sample(1.0f), sample(previous)), sub(sample(current), sample(0.0f)));
}

@trusted unittest {
    import std.math : abs;
    Transform a, b;
    a.translation = Vec3(2, 0, 0);
    b.translation = Vec3(0, 4, 0);
    Transform out_;
    MotionBlendingJob.Layer[2] ls = [MotionBlendingJob.Layer(1, &a), MotionBlendingJob.Layer(3, &b)];
    MotionBlendingJob job;
    job.layers = ls[];
    job.output = &out_;
    assert(job.run());
    // Length = (2*1 + 4*3)/4 = 3.5; direction is the weighted mean of (1,0,0) and (0,1,0).
    assert(abs(sqrt(dot(out_.translation, out_.translation)) - 3.5f) < 1e-5f);
    assert(out_.translation.y > out_.translation.x);
    assert(out_.rotation == Quat(0, 0, 0, 1) && out_.scale == Vec3(1, 1, 1));
}

@trusted unittest {
    import std.math : abs;
    // Single layer reproduces its delta whatever the weight; opposed quaternions do not cancel.
    Transform a;
    a.translation = Vec3(1, 2, 3);
    a.rotation = fromAxisAngle(Vec3(0, 1, 0), 0.8f);
    Transform b = a;
    b.rotation = Quat(-a.rotation.x, -a.rotation.y, -a.rotation.z, -a.rotation.w);
    Transform out_;
    MotionBlendingJob.Layer[1] one = [MotionBlendingJob.Layer(0.3f, &a)];
    MotionBlendingJob job;
    job.layers = one[];
    job.output = &out_;
    assert(job.run());
    assert(abs(out_.translation.x - 1) < 1e-5f && abs(out_.translation.z - 3) < 1e-5f);
    assert(abs(out_.rotation.y - a.rotation.y) < 1e-5f);
    MotionBlendingJob.Layer[2] two = [MotionBlendingJob.Layer(1, &a), MotionBlendingJob.Layer(1, &b)];
    job.layers = two[];
    assert(job.run());
    assert(abs(abs(out_.rotation.y) - abs(a.rotation.y)) < 1e-5f);
    // No layers / non-positive weights -> zero translation, identity rotation.
    MotionBlendingJob.Layer[1] neg = [MotionBlendingJob.Layer(-1, &a)];
    job.layers = neg[];
    assert(job.run() && out_.translation == Vec3(0, 0, 0) && out_.rotation == Quat(0, 0, 0, 1));
    MotionBlendingJob bad;
    assert(!bad.run());
}

@trusted unittest {
    // A looping motion track accumulates the same displacement over 10 loops as one long segment.
    import engine.animation.io.archive : InputArchive;
    import engine.animation.testing : loadFixture;
    import engine.animation.track;
    import engine.animation.track_sampling;
    import std.math : abs;
    auto ar = InputArchive(loadFixture("pab/walk_motion_track.ozz"));
    Float3Track t;
    assert(loadTrack(ar, t));
    Vec3 sampleTrack(float r) {
        Vec3 v;
        Float3TrackSamplingJob j;
        j.ratio = r;
        j.track = &t;
        j.result = &v;
        assert(j.run());
        return v;
    }
    immutable perLoop = sub(sampleTrack(1.0f), sampleTrack(0.0f));
    Vec3 acc = Vec3(0, 0, 0);
    float prev = 0;
    foreach (i; 1 .. 10 * 30 + 1) {
        immutable cur = (i / 30.0f) % 1.0f;
        immutable looped = cur < prev;
        acc = add(acc, translationDelta(&sampleTrack, prev, cur, looped));
        prev = cur;
    }
    immutable want = scale(perLoop, 10);
    assert(abs(acc.x - want.x) < 1e-3f && abs(acc.y - want.y) < 1e-3f && abs(acc.z - want.z) < 1e-3f);
}
