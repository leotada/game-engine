// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/blending_job.cc @ 744eb9d
/// Blends local-space poses: weighted layers (optionally per-joint), rest pose fallback below a
/// weight threshold, normalization, then additive / subtractive layers.
module engine.animation.blending;

import engine.animation.math.simd;
import engine.animation.math.soa;
import engine.animation.skeleton : kMaxSoaJoints;

@safe:

struct BlendingJob {
    /// One input pose.
    struct Layer {
        /// Blend weight. Layers with weight <= 0 are skipped (normal layers); additive layers
        /// use a negative weight to subtract.
        float weight = 0;
        /// Local-space pose, at least as long as the rest pose.
        const(SoaTransform)[] transform;
        /// Optional per-joint weights (SoA, multiplied with `weight`). Empty = full layer.
        const(SimdFloat4)[] jointWeights;
    }

    /// Rest-pose weight floor: when the accumulated weight is below this, the rest pose fills in.
    float threshold = 0.1f;
    const(Layer)[] layers;
    const(Layer)[] additiveLayers;
    /// Defines the number of SoA joints to blend.
    const(SoaTransform)[] restPose;
    SoaTransform[] output;

    bool validate() const scope pure nothrow @nogc {
        if (!(threshold > 0.0f) || restPose.length == 0 || output.length == 0) return false;
        immutable n = restPose.length;
        if (n > kMaxSoaJoints || output.length < n) return false;
        foreach (ref l; layers) if (!validLayer(l, n)) return false;
        foreach (ref l; additiveLayers) if (!validLayer(l, n)) return false;
        return true;
    }

    bool run() scope pure nothrow @nogc {
        if (!validate()) return false;
        Args args = void;
        args.numSoaJoints = restPose.length;
        args.numPasses = 0;
        args.numPartialPasses = 0;
        args.accumulatedWeight = 0;
        blendLayers(this, args);
        blendRestPose(this, args);
        normalize(this, args);
        addLayers(this);
        return true;
    }
}

version (unittest) {
    import std.math : abs, sqrt;
    import engine.animation.testing : near;

    SoaTransform pose(float tx, float ty, float tz, SoaQuaternion q = SoaQuaternion.identity(),
                      float s = 1) {
        SoaTransform t;
        t.translation = SoaFloat3(SimdFloat4.load1(tx), SimdFloat4.load1(ty), SimdFloat4.load1(tz));
        t.rotation = q;
        t.scale = SoaFloat3(SimdFloat4.load1(s), SimdFloat4.load1(s), SimdFloat4.load1(s));
        return t;
    }

    SoaQuaternion rotZ(float angle) {
        import std.math : sin, cos;
        return SoaQuaternion(SimdFloat4.zero(), SimdFloat4.zero(), SimdFloat4.load1(sin(angle / 2)),
                             SimdFloat4.load1(cos(angle / 2)));
    }

    bool nearPose(const SoaTransform a, const SoaTransform b, float tol = 1e-4f) {
        foreach (l; 0 .. 4) {
            if (!near(a.translation.x[l], b.translation.x[l], tol)
                || !near(a.translation.y[l], b.translation.y[l], tol)
                || !near(a.translation.z[l], b.translation.z[l], tol)
                || !near(a.rotation.x[l], b.rotation.x[l], tol)
                || !near(a.rotation.y[l], b.rotation.y[l], tol)
                || !near(a.rotation.z[l], b.rotation.z[l], tol)
                || !near(a.rotation.w[l], b.rotation.w[l], tol)
                || !near(a.scale.x[l], b.scale.x[l], tol)
                || !near(a.scale.y[l], b.scale.y[l], tol)
                || !near(a.scale.z[l], b.scale.z[l], tol)) return false;
        }
        return true;
    }
}


@trusted unittest {
    // Validation.
    SoaTransform[2] rest, out_, in0;
    BlendingJob.Layer layer = {1.0f, in0[]};
    BlendingJob job;
    assert(!job.validate()); // empty rest pose / output
    job.restPose = rest[];
    job.output = out_[];
    assert(job.validate()); // no layers is valid (rest pose result)
    job.threshold = 0;
    assert(!job.validate());
    job.threshold = 0.1f;
    job.output = out_[0 .. 1];
    assert(!job.validate()); // output shorter than rest pose
    job.output = out_[];
    BlendingJob.Layer[1] ls = [layer];
    ls[0].transform = in0[0 .. 1];
    job.layers = ls[];
    assert(!job.validate()); // layer shorter than rest pose
    ls[0].transform = in0[];
    ls[0].jointWeights = new SimdFloat4[1];
    assert(!job.validate()); // joint weights shorter than rest pose
    ls[0].jointWeights = null;
    assert(job.validate());
}

@trusted unittest {
    // No layer, or only zero / negative weights -> rest pose.
    SoaTransform[1] rest = [pose(1, 2, 3, rotZ(0.5f), 2)];
    SoaTransform[1] out_, in0 = [pose(9, 9, 9)];
    BlendingJob.Layer[2] ls = [BlendingJob.Layer(0.0f, in0[]), BlendingJob.Layer(-1.0f, in0[])];
    BlendingJob job;
    job.restPose = rest[];
    job.output = out_[];
    assert(job.run() && nearPose(out_[0], rest[0]));
    job.layers = ls[];
    assert(job.run() && nearPose(out_[0], rest[0]));
}

@trusted unittest {
    // Single layer reproduces its input whatever the (positive) weight, since weights are
    // normalized.
    SoaTransform[1] rest, out_, in0 = [pose(1, 2, 3, rotZ(1.0f), 2)];
    foreach (w; [1.0f, 0.5f, 3.0f]) {
        BlendingJob.Layer[1] ls = [BlendingJob.Layer(w, in0[])];
        BlendingJob job;
        job.threshold = 0.1f;
        job.restPose = rest[];
        job.output = out_[];
        job.layers = ls[];
        assert(job.run());
        assert(nearPose(out_[0], in0[0]), "weight");
    }
}

@trusted unittest {
    // Two layers: weighted average of translations and scales; normalized weights.
    SoaTransform[1] rest, out_;
    SoaTransform[1] a = [pose(0, 0, 0, SoaQuaternion.identity(), 1)];
    SoaTransform[1] b = [pose(4, 8, 12, SoaQuaternion.identity(), 3)];
    BlendingJob.Layer[2] ls = [BlendingJob.Layer(1.0f, a[]), BlendingJob.Layer(3.0f, b[])];
    BlendingJob job;
    job.restPose = rest[];
    job.output = out_[];
    job.layers = ls[];
    assert(job.run());
    assert(nearPose(out_[0], pose(3, 6, 9, SoaQuaternion.identity(), 2.5f)));
}

@trusted unittest {
    // Opposed quaternions (q and -q are the same rotation) must not cancel out.
    auto q = rotZ(1.2f);
    auto nq = SoaQuaternion(-q.x, -q.y, -q.z, -q.w);
    SoaTransform[1] rest, out_;
    SoaTransform[1] a = [pose(0, 0, 0, q)];
    SoaTransform[1] b = [pose(0, 0, 0, nq)];
    BlendingJob.Layer[2] ls = [BlendingJob.Layer(0.5f, a[]), BlendingJob.Layer(0.5f, b[])];
    BlendingJob job;
    job.restPose = rest[];
    job.output = out_[];
    job.layers = ls[];
    assert(job.run());
    assert(near(abs(out_[0].rotation.w[0]), abs(q.w[0])) && near(abs(out_[0].rotation.z[0]), abs(q.z[0])));
}

@trusted unittest {
    // Weights below the threshold are completed by the rest pose.
    SoaTransform[1] rest = [pose(10, 0, 0, SoaQuaternion.identity(), 1)];
    SoaTransform[1] out_, a = [pose(0, 0, 0, SoaQuaternion.identity(), 1)];
    BlendingJob.Layer[1] ls = [BlendingJob.Layer(0.04f, a[])];
    BlendingJob job;
    job.threshold = 0.1f;
    job.restPose = rest[];
    job.output = out_[];
    job.layers = ls[];
    assert(job.run());
    // (0 * 0.04 + 10 * 0.06) / 0.1
    assert(near(out_[0].translation.x[0], 6.0f));
}

@trusted unittest {
    // Partial layer: a per-joint weight of 0 leaves that joint on the other layer / rest pose.
    SoaTransform[1] rest = [pose(100, 0, 0)];
    SoaTransform[1] out_;
    SoaTransform[1] base = [pose(1, 0, 0)];
    SoaTransform[1] over = [pose(5, 0, 0)];
    SimdFloat4[1] mask = [SimdFloat4.load(0, 1, 0.5f, 1)];
    BlendingJob.Layer[2] ls = [BlendingJob.Layer(1.0f, base[]), BlendingJob.Layer(1.0f, over[], mask[])];
    BlendingJob job;
    job.restPose = rest[];
    job.output = out_[];
    job.layers = ls[];
    assert(job.run());
    immutable t = out_[0].translation.x;
    assert(near(t.x, 1.0f));              // masked out
    assert(near(t.y, 3.0f));              // (1 + 5) / 2
    assert(near(t.z, (1 + 2.5f) / 1.5f)); // weights 1 + 0.5
    assert(near(t.w, 3.0f));
}

@trusted unittest {
    // Additive layers: weight 1 adds, weight 0.5 adds half, negative weight subtracts back.
    SoaTransform[1] rest, out_;
    SoaTransform[1] base = [pose(1, 2, 3, rotZ(0.4f), 2)];
    SoaTransform[1] add = [pose(10, 0, 0, rotZ(0.6f), 1.5f)];
    BlendingJob.Layer[1] ls = [BlendingJob.Layer(1.0f, base[])];
    BlendingJob.Layer[1] adds = [BlendingJob.Layer(1.0f, add[])];
    BlendingJob job;
    job.restPose = rest[];
    job.output = out_[];
    job.layers = ls[];
    job.additiveLayers = adds[];
    assert(job.run());
    assert(near(out_[0].translation.x[0], 11.0f));
    assert(near(out_[0].scale.x[0], 3.0f));
    // Rotations compose: rotZ(0.4) * rotZ(0.6) == rotZ(1.0).
    assert(nearPose(SoaTransform(out_[0].translation, out_[0].rotation, SoaFloat3.one()),
                    SoaTransform(SoaFloat3(SimdFloat4.load1(11), SimdFloat4.load1(2), SimdFloat4.load1(3)),
                                 rotZ(1.0f), SoaFloat3.one())));

    adds[0].weight = 0.5f;
    assert(job.run());
    assert(near(out_[0].translation.x[0], 6.0f));
    assert(near(out_[0].scale.x[0], 2 * (1.5f * 0.5f + 0.5f)));

    // Add then subtract the same additive pose: identity.
    BlendingJob.Layer[2] both = [BlendingJob.Layer(1.0f, add[]), BlendingJob.Layer(-1.0f, add[])];
    job.additiveLayers = both[];
    assert(job.run());
    assert(nearPose(out_[0], base[0], 2e-3f));
}

@trusted unittest {
    // Real clips: blending walk/jog/run at weights (1, 0, 0) reproduces walk; mixed weights stay
    // normalized; zero allocation in run().
    import core.memory : GC;
    import engine.animation.clip;
    import engine.animation.io.archive : InputArchive;
    import engine.animation.sampling;
    import engine.animation.skeleton;
    import engine.animation.testing : loadFixture;

    auto sar = InputArchive(loadFixture("pab/skeleton.ozz"));
    Skeleton skel;
    assert(loadSkeleton(sar, skel));

    SoaTransform[][3] poses;
    foreach (k, name; ["pab/walk.ozz", "pab/jog.ozz", "pab/run.ozz"]) {
        auto ar = InputArchive(loadFixture(name));
        Animation a;
        assert(loadAnimation(ar, a));
        auto ctx = SamplingContext(skel.numJoints);
        poses[k] = new SoaTransform[skel.numSoaJoints];
        SamplingJob sj;
        sj.animation = &a;
        sj.context = &ctx;
        sj.output = poses[k];
        sj.ratio = 0.35f;
        assert(sj.run());
    }
    auto out_ = new SoaTransform[skel.numSoaJoints];
    BlendingJob.Layer[3] ls = [BlendingJob.Layer(1, poses[0]), BlendingJob.Layer(0, poses[1]),
                               BlendingJob.Layer(0, poses[2])];
    BlendingJob job;
    job.restPose = skel.restPoses;
    job.output = out_;
    job.layers = ls[];
    assert(job.run());
    foreach (i; 0 .. out_.length) assert(nearPose(out_[i], poses[0][i], 1e-3f));

    ls[0].weight = 0.2f;
    ls[1].weight = 0.5f;
    ls[2].weight = 0.3f;
    assert(job.run());
    foreach (ref t; out_) {
        foreach (l; 0 .. 4) {
            immutable len2 = t.rotation.x[l] ^^ 2 + t.rotation.y[l] ^^ 2 + t.rotation.z[l] ^^ 2
                           + t.rotation.w[l] ^^ 2;
            assert(abs(len2 - 1) < 1e-3f);
        }
    }
    immutable before = GC.stats().usedSize;
    foreach (i; 0 .. 100) assert(job.run());
    assert(GC.stats().usedSize == before);
}
private:

pure nothrow @nogc:

bool validLayer(ref const BlendingJob.Layer l, size_t n) {
    return l.transform.length >= n && (l.jointWeights.length == 0 || l.jointWeights.length >= n);
}

struct Args {
    SimdFloat4[kMaxSoaJoints] accumulatedWeights;
    size_t numSoaJoints;
    int numPasses;
    int numPartialPasses;
    float accumulatedWeight;
}

void blend1st(ref const SoaTransform src, SimdFloat4 w, ref SoaTransform dest) {
    dest.translation = src.translation * w;
    dest.rotation = src.rotation * w;
    dest.scale = src.scale * w;
}

void blendN(ref const SoaTransform src, SimdFloat4 w, ref SoaTransform dest) {
    dest.translation = dest.translation + src.translation * w;
    // Negate opposed quaternions so the blend takes the shortest path.
    immutable s = sign(dot(dest.rotation, src.rotation));
    immutable rot = SoaQuaternion(xorBits(src.rotation.x, s), xorBits(src.rotation.y, s),
                                  xorBits(src.rotation.z, s), xorBits(src.rotation.w, s));
    dest.rotation = dest.rotation + rot * w;
    dest.scale = dest.scale + src.scale * w;
}

SoaQuaternion additiveQuat(ref const SoaTransform src, SimdFloat4 w) {
    immutable one = SimdFloat4.one();
    immutable s = sign(src.rotation.w);
    return SoaQuaternion(xorBits(src.rotation.x, s) * w, xorBits(src.rotation.y, s) * w,
                         xorBits(src.rotation.z, s) * w,
                         (xorBits(src.rotation.w, s) - one) * w + one);
}

void addPass(ref const SoaTransform src, SimdFloat4 w, SimdFloat4 oneMinusW, ref SoaTransform dest) {
    dest.translation = dest.translation + src.translation * w;
    dest.rotation = dest.rotation * normalizeEst(additiveQuat(src, w));
    dest.scale.x = dest.scale.x * madd(src.scale.x, w, oneMinusW);
    dest.scale.y = dest.scale.y * madd(src.scale.y, w, oneMinusW);
    dest.scale.z = dest.scale.z * madd(src.scale.z, w, oneMinusW);
}

void subPass(ref const SoaTransform src, SimdFloat4 w, SimdFloat4 oneMinusW, ref SoaTransform dest) {
    dest.translation = dest.translation - src.translation * w;
    dest.rotation = dest.rotation * conjugate(normalizeEst(additiveQuat(src, w)));
    dest.scale.x = dest.scale.x * rcpEst(madd(src.scale.x, w, oneMinusW));
    dest.scale.y = dest.scale.y * rcpEst(madd(src.scale.y, w, oneMinusW));
    dest.scale.z = dest.scale.z * rcpEst(madd(src.scale.z, w, oneMinusW));
}

void blendLayers(ref BlendingJob job, ref Args args) {
    foreach (ref layer; job.layers) {
        if (layer.weight <= 0.0f) continue;
        args.accumulatedWeight += layer.weight;
        immutable layerWeight = SimdFloat4.load1(layer.weight);
        immutable partial = layer.jointWeights.length != 0;
        if (partial) ++args.numPartialPasses;
        immutable first = args.numPasses == 0;
        foreach (i; 0 .. args.numSoaJoints) {
            immutable w = partial ? layerWeight * max0(layer.jointWeights[i]) : layerWeight;
            if (first) {
                args.accumulatedWeights[i] = w;
                blend1st(layer.transform[i], w, job.output[i]);
            } else {
                args.accumulatedWeights[i] = args.accumulatedWeights[i] + w;
                blendN(layer.transform[i], w, job.output[i]);
            }
        }
        ++args.numPasses;
    }
}

void blendRestPose(ref BlendingJob job, ref Args args) {
    if (args.numPartialPasses == 0) {
        // No partial pass: the threshold is tested globally.
        immutable bpWeight = job.threshold - args.accumulatedWeight;
        if (bpWeight > 0.0f) {
            if (args.numPasses == 0) {
                args.accumulatedWeight = 1.0f;
                foreach (i; 0 .. args.numSoaJoints) job.output[i] = job.restPose[i];
            } else {
                args.accumulatedWeight = job.threshold;
                immutable w = SimdFloat4.load1(bpWeight);
                foreach (i; 0 .. args.numSoaJoints) blendN(job.restPose[i], w, job.output[i]);
            }
        }
    } else {
        // Partial blending: the threshold is tested per joint.
        immutable threshold = SimdFloat4.load1(job.threshold);
        foreach (i; 0 .. args.numSoaJoints) {
            immutable bpWeight = max0(threshold - args.accumulatedWeights[i]);
            args.accumulatedWeights[i] = max(threshold, args.accumulatedWeights[i]);
            blendN(job.restPose[i], bpWeight, job.output[i]);
        }
    }
}

void normalize(ref BlendingJob job, ref const Args args) {
    if (args.numPartialPasses == 0) {
        immutable ratio = SimdFloat4.load1(1.0f / args.accumulatedWeight);
        foreach (i; 0 .. args.numSoaJoints) {
            auto dest = &job.output[i];
            dest.rotation = normalizeEst(dest.rotation);
            dest.translation = dest.translation * ratio;
            dest.scale = dest.scale * ratio;
        }
    } else {
        foreach (i; 0 .. args.numSoaJoints) {
            immutable ratio = SimdFloat4.one() / args.accumulatedWeights[i];
            auto dest = &job.output[i];
            dest.rotation = normalizeEst(dest.rotation);
            dest.translation = dest.translation * ratio;
            dest.scale = dest.scale * ratio;
        }
    }
}

void addLayers(ref BlendingJob job) {
    immutable one = SimdFloat4.one();
    foreach (ref layer; job.additiveLayers) {
        if (layer.weight == 0.0f) continue;
        immutable subtract = layer.weight < 0.0f;
        immutable layerWeight = SimdFloat4.load1(subtract ? -layer.weight : layer.weight);
        immutable partial = layer.jointWeights.length != 0;
        foreach (i; 0 .. job.restPose.length) {
            immutable w = partial ? layerWeight * max0(layer.jointWeights[i]) : layerWeight;
            immutable oneMinusW = one - w;
            if (subtract) subPass(layer.transform[i], w, oneMinusW, job.output[i]);
            else addPass(layer.transform[i], w, oneMinusW, job.output[i]);
        }
    }
}

