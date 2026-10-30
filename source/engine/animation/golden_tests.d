/// Compares the D port with reference outputs dumped from upstream ozz-animation by
/// `tools/ozz/golden` (committed under `assets/animation/test/golden/`).
module engine.animation.golden_tests;

version (unittest):

import engine.animation.blending;
import engine.animation.clip;
import engine.animation.ik;
import engine.animation.io.archive;
import engine.animation.local_to_model;
import engine.animation.math.matrix;
import engine.animation.math.scalar;
import engine.animation.math.simd;
import engine.animation.math.soa;
import engine.animation.sampling;
import engine.animation.skeleton;
import engine.animation.testing;
import std.math : abs;

private enum goldenDir = "golden/";

private const(float)[] loadFloats(string name) @trusted {
    auto bytes = loadFixture(goldenDir ~ name);
    assert(bytes.length % 4 == 0);
    return (cast(const(float)*) bytes.ptr)[0 .. bytes.length / 4];
}

private Skeleton loadSkel(string name) {
    auto ar = InputArchive(loadFixture(name));
    Skeleton s;
    assert(loadSkeleton(ar, s), ar.error);
    return s;
}

private Animation loadAnim(string name) {
    auto ar = InputArchive(loadFixture(name));
    Animation a;
    assert(loadAnimation(ar, a), ar.error);
    return a;
}

/// Same ratio sequence as tools/ozz/golden/golden.cc.
private float[] ratios() {
    float[] r;
    foreach (i; 0 .. 25) r ~= i / 24.0f;
    r ~= [0.9f, 0.1f, 0.5f, 0.0f, 1.0f, 0.33f, 0.77f, 0.02f];
    for (int i = 20; i >= 0; --i) r ~= i / 20.0f;
    r ~= [0.001f, 0.999f, 0.5f, 0.25f, 0.75f, 0.6f, 0.4f, 0.123f, 0.456f];
    return r;
}

/// 40 floats per SoA element: tx ty tz, qx qy qz qw, sx sy sz, four lanes each.
private float[] flatten(const(SoaTransform)[] t) {
    float[] o;
    foreach (ref e; t) {
        foreach (c; [e.translation.x, e.translation.y, e.translation.z, e.rotation.x, e.rotation.y,
                     e.rotation.z, e.rotation.w, e.scale.x, e.scale.y, e.scale.z])
            o ~= [c.x, c.y, c.z, c.w];
    }
    return o;
}

/// Compares two flattened SoA poses; quaternions are compared up to sign (q == -q).
private void expectPose(const(float)[] got, const(float)[] want, float tol, string what) {
    assert(got.length == want.length, what);
    for (size_t e = 0; e < got.length; e += 40) {
        foreach (lane; 0 .. 4) {
            bool flip;
            {
                float dot = 0;
                foreach (c; 0 .. 4) dot += got[e + (3 + c) * 4 + lane] * want[e + (3 + c) * 4 + lane];
                flip = dot < 0;
            }
            foreach (c; 0 .. 10) {
                immutable g = got[e + c * 4 + lane], w = want[e + c * 4 + lane];
                immutable gs = (flip && c >= 3 && c <= 6) ? -g : g;
                assert(near(gs, w, tol), what);
            }
        }
    }
}

private void checkSampling(string tag, string skel, string clip, float tol) {
    auto s = loadSkel(skel);
    auto a = loadAnim(clip);
    auto want = loadFloats("sampling_" ~ tag ~ ".bin");
    auto ctx = SamplingContext(s.numJoints);
    auto out_ = new SoaTransform[s.numSoaJoints];
    immutable stride = s.numSoaJoints * 40;
    auto rs = ratios();
    assert(want.length % stride == 0 && want.length / stride >= 12, "golden fixture missing or truncated");
    foreach (i; 0 .. want.length / stride) {
        SamplingJob j;
        j.animation = &a;
        j.context = &ctx;
        j.ratio = rs[i];
        j.output = out_;
        assert(j.run());
        expectPose(flatten(out_), want[i * stride .. (i + 1) * stride], tol, tag);
    }
}

// Upstream's SSE build uses `rcpps` / `rsqrtps` estimates. The DMD x86_64 vector backend uses the
// same instructions and matches to float precision; the exact-division backends (LDC, scalar)
// differ by the estimate error.
version (EngineAnimScalarMath) enum float samplingTol = 2e-3f;
else version (D_SIMD) enum float samplingTol = 1e-5f;
else version (LDC) {
    version (X86_64) enum float samplingTol = 1e-5f; else enum float samplingTol = 2e-3f;
} else enum float samplingTol = 2e-3f;

unittest {
    checkSampling("pab_walk", "pab/skeleton.ozz", "pab/walk.ozz", samplingTol);
    checkSampling("pab_jog", "pab/skeleton.ozz", "pab/jog.ozz", samplingTol);
    checkSampling("ruby", "ruby_skeleton.ozz", "ruby_animation.ozz", samplingTol);
}

unittest {
    // Blend of walk and jog at several weights, and the model-space matrices derived from it.
    auto s = loadSkel("pab/skeleton.ozz");
    auto walk = loadAnim("pab/walk.ozz"), jog = loadAnim("pab/jog.ozz");
    auto wantBlend = loadFloats("blend_pab.bin");
    auto wantModel = loadFloats("model_pab.bin");
    auto c0 = SamplingContext(s.numJoints), c1 = SamplingContext(s.numJoints);
    auto l0 = new SoaTransform[s.numSoaJoints], l1 = new SoaTransform[s.numSoaJoints];
    auto blended = new SoaTransform[s.numSoaJoints];
    auto model = new Float4x4[s.numJoints];
    foreach (k, w; [0.0f, 0.3f, 0.5f, 0.8f, 1.0f]) {
        SamplingJob a;
        a.animation = &walk; a.context = &c0; a.ratio = 0.37f; a.output = l0;
        assert(a.run());
        SamplingJob b;
        b.animation = &jog; b.context = &c1; b.ratio = 0.62f; b.output = l1;
        assert(b.run());
        BlendingJob.Layer[2] layers = [BlendingJob.Layer(1.0f - w, l0), BlendingJob.Layer(w, l1)];
        BlendingJob job;
        job.layers = layers[];
        job.restPose = s.restPoses;
        job.output = blended;
        assert(job.run());
        immutable bs = s.numSoaJoints * 40;
        expectPose(flatten(blended), wantBlend[k * bs .. (k + 1) * bs], 1e-4f, "blend");

        LocalToModelJob l2m;
        l2m.skeleton = &s; l2m.input = blended; l2m.output = model;
        assert(l2m.run());
        immutable ms = s.numJoints * 16;
        foreach (j; 0 .. s.numJoints)
            foreach (c; 0 .. 4) foreach (r; 0 .. 4)
                assert(near(model[j].cols[c][r], wantModel[k * ms + j * 16 + c * 4 + r], 1e-3f), "model");
    }
}

private Float4x4 translate(float x, float y, float z) {
    auto m = Float4x4.identity();
    m.cols[3] = SimdFloat4(x, y, z, 1);
    return m;
}

private bool nearQuat(Quat a, const(float)[] w, float tol) {
    immutable dot = a.x * w[0] + a.y * w[1] + a.z * w[2] + a.w * w[3];
    immutable s = dot < 0 ? -1.0f : 1.0f;
    return near(s * a.x, w[0], tol) && near(s * a.y, w[1], tol) && near(s * a.z, w[2], tol) && near(s * a.w, w[3], tol);
}

@trusted unittest {
    // Two-bone and aim IK on synthetic chains, against upstream's corrections.
    auto want = loadFloats("ik.bin");
    auto start = translate(0, 0, 0), mid = translate(0.3f, 1, 0), end = translate(0, 2, 0);
    size_t at;
    foreach (t; [Vec3(0.5f, 1.2f, 0.3f), Vec3(0, 3, 0), Vec3(1, 0.5f, -0.4f)]) {
        Quat qs, qm;
        bool reached;
        IKTwoBoneJob job;
        job.target = t;
        job.poleVector = Vec3(0, 1, 0);
        job.midAxis = Vec3(0, 0, 1);
        job.startJoint = &start; job.midJoint = &mid; job.endJoint = &end;
        job.startJointCorrection = &qs; job.midJointCorrection = &qm; job.reached = &reached;
        assert(job.run());
        assert(nearQuat(qs, want[at .. at + 4], 2e-3f), "two-bone start");
        assert(nearQuat(qm, want[at + 4 .. at + 8], 2e-3f), "two-bone mid");
        assert(reached == (want[at + 8] != 0), "two-bone reached");
        at += 9;
    }
    auto joint = translate(0, 0, 0);
    foreach (t; [Vec3(1, 2, 3), Vec3(-2, 0.5f, 1)]) {
        Quat q;
        bool reached;
        IKAimJob job;
        job.target = t;
        job.forward = Vec3(0, 0, 1);
        job.up = Vec3(0, 1, 0);
        job.poleVector = Vec3(0, 1, 0);
        job.joint = &joint; job.jointCorrection = &q; job.reached = &reached;
        assert(job.run());
        assert(nearQuat(q, want[at .. at + 4], 2e-3f), "aim");
        assert(reached == (want[at + 4] != 0), "aim reached");
        at += 5;
    }
    assert(at == want.length);
}

// ---------------------------------------------------------------------------
// Tracks, triggering, motion blending, skinning
// ---------------------------------------------------------------------------

import engine.animation.motion_blending;
import engine.animation.skinning;
import engine.animation.track;
import engine.animation.track_sampling;
import engine.animation.track_triggering;

unittest {
    auto ar = InputArchive(loadFixture("pab/walk_motion_track.ozz"));
    Float3Track t;
    assert(loadTrack(ar, t), ar.error);
    auto want = loadFloats("track_float3_walk.bin");
    assert(want.length == 41 * 3);
    foreach (i; 0 .. 41) {
        Vec3 r;
        Float3TrackSamplingJob j;
        j.track = &t; j.result = &r; j.ratio = i / 40.0f;
        assert(j.run());
        assert(near(r.x, want[i * 3], 1e-5f) && near(r.y, want[i * 3 + 1], 1e-5f)
               && near(r.z, want[i * 3 + 2], 1e-5f), "float3 track");
    }
}

unittest {
    auto ar = InputArchive(loadFixture("robot_track_grasp.ozz"));
    FloatTrack t;
    assert(loadTrack(ar, t), ar.error);
    auto want = loadFloats("track_float_grasp.bin");
    assert(want.length == 41);
    foreach (i; 0 .. 41) {
        float r;
        FloatTrackSamplingJob j;
        j.track = &t; j.result = &r; j.ratio = i / 40.0f;
        assert(j.run());
        assert(near(r, want[i], 1e-5f), "float track");
    }

    // Edge detection over the same ranges as the generator, including looping and reversed ranges.
    auto trig = loadFloats("trigger_grasp.bin");
    size_t at, ranges, totalEdges;
    while (at < trig.length) {
        TrackTriggeringJob job;
        job.track = &t; job.from = trig[at]; job.to = trig[at + 1]; job.threshold = trig[at + 2];
        immutable n = cast(size_t) trig[at + 3];
        at += 4;
        size_t k;
        foreach (e; job.edges) {
            assert(k < n, "more edges than upstream");
            assert(near(e.ratio, trig[at + k * 2], 1e-5f), "edge ratio");
            assert(e.rising == (trig[at + k * 2 + 1] != 0), "edge direction");
            ++k;
        }
        assert(k == n, "fewer edges than upstream");
        at += n * 2;
        totalEdges += n;
        ++ranges;
    }
    assert(ranges == 8 && totalEdges >= 6, "trigger goldens are vacuous");
}

unittest {
    auto want = loadFloats("motion.bin");
    enum perCase = 3 * 8 + 7;
    assert(want.length == 4 * perCase);
    foreach (c; 0 .. 4) {
        Transform[3] deltas;
        MotionBlendingJob.Layer[3] layers;
        foreach (i; 0 .. 3) {
            auto d = want[c * perCase + i * 8 .. c * perCase + (i + 1) * 8];
            deltas[i].translation = Vec3(d[1], d[2], d[3]);
            deltas[i].rotation = Quat(d[4], d[5], d[6], d[7]);
            layers[i] = MotionBlendingJob.Layer(d[0], &deltas[i]);
        }
        Transform o;
        MotionBlendingJob job;
        job.layers = layers[];
        job.output = &o;
        assert(job.run());
        auto w = want[c * perCase + 24 .. (c + 1) * perCase];
        assert(near(o.translation.x, w[0], 1e-5f) && near(o.translation.y, w[1], 1e-5f)
               && near(o.translation.z, w[2], 1e-5f), "motion translation");
        assert(nearQuat(o.rotation, w[3 .. 7], 1e-4f), "motion rotation");
    }
}

@trusted unittest {
    enum J = 8, V = 64, I = 4;
    auto d = loadFloats("skinning.bin");
    size_t at;
    auto take(size_t n) { auto s = d[at .. at + n]; at += n; return s; }
    Float4x4[] mats, invT;
    foreach (dst; [&mats, &invT]) {
        foreach (j; 0 .. J) {
            auto f = take(16);
            Float4x4 m;
            foreach (c; 0 .. 4) m.cols[c] = SimdFloat4(f[c * 4], f[c * 4 + 1], f[c * 4 + 2], f[c * 4 + 3]);
            *dst ~= m;
        }
    }
    auto pos = take(V * 3).dup, nrm = take(V * 3).dup, tan = take(V * 3).dup;
    ushort[] idx;
    foreach (f; take(V * I)) idx ~= cast(ushort) f;
    auto wts = take(V * (I - 1)).dup;
    auto wantP = take(V * 3), wantN = take(V * 3), wantT = take(V * 3);
    assert(at == d.length);

    auto op = new float[V * 3], on = new float[V * 3], ot = new float[V * 3];
    op[] = 0; on[] = 0; ot[] = 0;
    SkinningJob job;
    job.vertexCount = V;
    job.influencesCount = I;
    job.jointMatrices = mats;
    job.jointInverseTransposeMatrices = invT;
    job.jointIndices = asBytes(idx); job.jointIndicesStride = ushort.sizeof * I;
    job.jointWeights = asBytes(wts); job.jointWeightsStride = float.sizeof * (I - 1);
    job.inPositions = asBytes(pos); job.inPositionsStride = float.sizeof * 3;
    job.inNormals = asBytes(nrm); job.inNormalsStride = float.sizeof * 3;
    job.inTangents = asBytes(tan); job.inTangentsStride = float.sizeof * 3;
    job.outPositions = asBytes(op); job.outPositionsStride = float.sizeof * 3;
    job.outNormals = asBytes(on); job.outNormalsStride = float.sizeof * 3;
    job.outTangents = asBytes(ot); job.outTangentsStride = float.sizeof * 3;
    assert(job.run());
    foreach (i; 0 .. V * 3) {
        assert(near(op[i], wantP[i], 1e-4f), "skin position");
        assert(near(on[i], wantN[i], 1e-3f), "skin normal");
        assert(near(ot[i], wantT[i], 1e-3f), "skin tangent");
    }
}
