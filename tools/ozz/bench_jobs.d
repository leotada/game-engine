// D counterpart of `golden_gen --bench-jobs` (same data, same LCG): random-seek sampling,
// 3 layers + additive blending, skinning. Run with tools/ozz/bench.sh (uses ldc2).
module bench_jobs;

import std.datetime.stopwatch : AutoStart, StopWatch;
import std.file : read;
import std.stdio : writefln;
import engine.animation;
import engine.animation.math.matrix;

private float lcg(ref uint s) { s = s * 1664525u + 1013904223u; return cast(float)((s >> 8) & 0xffff) / 65536.0f; }

private Animation loadA(string n) {
    auto ar = InputArchive(cast(const(ubyte)[]) read("assets/animation/test/" ~ n));
    Animation a;
    if (!loadAnimation(ar, a)) assert(false, n);
    return a;
}

void main() {
    auto sa = InputArchive(cast(const(ubyte)[]) read("assets/animation/test/pab/skeleton.ozz"));
    Skeleton s;
    loadSkeleton(sa, s);
    auto walk = loadA("pab/walk.ozz"), jog = loadA("pab/jog.ozz"), run = loadA("pab/run.ozz"),
         add = loadA("pab/crackhead_additive.ozz");
    enum n = 1000;
    {
        auto ctx = new SamplingContext[n];
        foreach (ref c; ctx) c = SamplingContext(s.numJoints);
        auto out_ = new SoaTransform[s.numSoaJoints];
        uint seed = 7;
        enum frames = 100;
        double t = 0;
        foreach (f; 0 .. frames + 3) {
            auto sw = StopWatch(AutoStart.yes);
            foreach (i; 0 .. n) {
                SamplingJob j;
                j.animation = &walk; j.context = &ctx[i]; j.ratio = lcg(seed); j.output = out_;
                j.run();
            }
            if (f >= 3) t += sw.peek.total!"usecs";
        }
        writefln("seek-sampling pab/walk: %.2f us/char", t / frames / n);
    }
    {
        immutable ns = s.numSoaJoints;
        auto p0 = new SoaTransform[ns], p1 = new SoaTransform[ns], p2 = new SoaTransform[ns],
             pa = new SoaTransform[ns], out_ = new SoaTransform[ns];
        void samp(ref Animation a, float r, SoaTransform[] o) {
            auto c = SamplingContext(s.numJoints);
            SamplingJob j;
            j.animation = &a; j.context = &c; j.ratio = r; j.output = o;
            j.run();
        }
        samp(walk, .2f, p0); samp(jog, .5f, p1); samp(run, .8f, p2); samp(add, .4f, pa);
        BlendingJob.Layer[3] layers = [BlendingJob.Layer(.5f, p0), BlendingJob.Layer(.3f, p1), BlendingJob.Layer(.2f, p2)];
        BlendingJob.Layer[1] addl = [BlendingJob.Layer(.6f, pa)];
        enum reps = 300;
        double t = 0;
        foreach (f; 0 .. reps + 3) {
            auto sw = StopWatch(AutoStart.yes);
            foreach (i; 0 .. n) {
                BlendingJob job;
                job.layers = layers[]; job.additiveLayers = addl[];
                job.restPose = s.restPoses; job.output = out_;
                job.run();
            }
            if (f >= 3) t += sw.peek.total!"usecs";
        }
        writefln("blend 3 layers + additive: %.2f us/char", t / reps / n);
    }
    {
        enum kJ = 24, kV = 20000, kI = 4;
        uint seed = 99;
        auto m = new Float4x4[kJ], it = new Float4x4[kJ];
        foreach (j; 0 .. kJ) {
            // Rotation about a random axis, like the C++ side (axis-angle -> matrix).
            import std.math : sin, cos, sqrt;
            immutable a = lcg(seed) * 3.0f;
            float[3] ax = [lcg(seed), lcg(seed) + 1.0f, lcg(seed)];
            immutable l = sqrt(ax[0] * ax[0] + ax[1] * ax[1] + ax[2] * ax[2]);
            ax[] /= l;
            immutable c = cos(a), sn = sin(a), t1 = 1 - c;
            m[j] = Float4x4.identity();
            m[j].cols[0] = SimdFloat4(t1 * ax[0] * ax[0] + c, t1 * ax[0] * ax[1] + sn * ax[2], t1 * ax[0] * ax[2] - sn * ax[1], 0);
            m[j].cols[1] = SimdFloat4(t1 * ax[0] * ax[1] - sn * ax[2], t1 * ax[1] * ax[1] + c, t1 * ax[1] * ax[2] + sn * ax[0], 0);
            m[j].cols[2] = SimdFloat4(t1 * ax[0] * ax[2] + sn * ax[1], t1 * ax[1] * ax[2] - sn * ax[0], t1 * ax[2] * ax[2] + c, 0);
            m[j].cols[3] = SimdFloat4(lcg(seed), lcg(seed), lcg(seed), 1);
            bool ok;
            immutable inv = invert(m[j], ok);
            // Inverse transpose.
            Float4x4 tr;
            foreach (cc; 0 .. 4) foreach (r; 0 .. 4) tr.cols[cc][r] = inv.cols[r][cc];
            it[j] = tr;
        }
        auto pos = new float[kV * 3], nrm = new float[kV * 3], w = new float[kV * (kI - 1)],
             op = new float[kV * 3], on = new float[kV * 3];
        auto idx = new ushort[kV * kI];
        foreach (ref v; pos) v = lcg(seed) - .5f;
        foreach (ref v; nrm) v = lcg(seed) - .5f;
        foreach (i; 0 .. kV) {
            foreach (k; 0 .. kI - 1) w[i * (kI - 1) + k] = .25f * lcg(seed);
            foreach (k; 0 .. kI) idx[i * kI + k] = cast(ushort)((i * 7 + k * 5) % kJ);
        }
        enum reps = 100;
        double t = 0;
        foreach (f; 0 .. reps + 3) {
            auto sw = StopWatch(AutoStart.yes);
            SkinningJob job;
            job.vertexCount = kV; job.influencesCount = kI;
            job.jointMatrices = m; job.jointInverseTransposeMatrices = it;
            job.jointIndices = asBytes(idx); job.jointIndicesStride = ushort.sizeof * kI;
            job.jointWeights = asBytes(w); job.jointWeightsStride = float.sizeof * (kI - 1);
            job.inPositions = asBytes(pos); job.inPositionsStride = 12;
            job.inNormals = asBytes(nrm); job.inNormalsStride = 12;
            job.outPositions = asBytes(op); job.outPositionsStride = 12;
            job.outNormals = asBytes(on); job.outNormalsStride = 12;
            job.run();
            if (f >= 3) t += sw.peek.total!"usecs";
        }
        writefln("skinning 4 influences pos+normals: %.2f us per 1000 vertices", t / reps / (kV / 1000.0));
    }
}
