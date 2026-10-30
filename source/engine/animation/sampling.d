// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/sampling_job.cc @ 744eb9d
/// Samples an `Animation` at a time ratio into a local-space SoA pose.
///
/// Keyframes of all tracks are stored sorted by time. A per-component cache remembers, for every
/// track, the key currently used as the right side of the interpolation interval, and moves
/// forward/backward through the sorted keys as the ratio changes. Only SoA groups whose keys
/// changed are decompressed again. Large jumps restart from an iframe snapshot of the cache.
module engine.animation.sampling;

import engine.animation.clip;
import engine.animation.io.group_varint;
import engine.animation.keyframe;
import engine.animation.math.half;
import engine.animation.math.simd;
import engine.animation.math.soa;

@safe:

private struct InterpSoaFloat3 {
    SimdFloat4[2] ratio;
    SoaFloat3[2] value;
}

private struct InterpSoaQuaternion {
    SimdFloat4[2] ratio;
    SoaQuaternion[2] value;
}

private struct Cache {
    uint[] entries;
    ubyte[] outdated;
    uint next;
}

/// Per-instance sampling state. Resize once at spawn; reuse across frames and clips.
struct SamplingContext {
    private InterpSoaFloat3[] translations_;
    private InterpSoaQuaternion[] rotations_;
    private InterpSoaFloat3[] scales_;
    private Cache tCache_, rCache_, sCache_;
    private int maxSoaTracks_;
    private ulong animationUid_;
    private float ratio_ = 0;

    this(int maxTracks) { resize(maxTracks); }

    int maxTracks() const pure nothrow @nogc { return maxSoaTracks_ * 4; }
    int maxSoaTracks() const pure nothrow @nogc { return maxSoaTracks_; }

    /// (Re)allocates the context for animations of up to `maxTracks` tracks. Not for the frame path.
    void resize(int maxTracks) {
        invalidate();
        immutable soa = (maxTracks > 0 ? maxTracks + 3 : 3) / 4;
        maxSoaTracks_ = soa;
        immutable tracks = soa * 4;
        immutable flags = (soa + 7) / 8;
        translations_ = new InterpSoaFloat3[soa];
        rotations_ = new InterpSoaQuaternion[soa];
        scales_ = new InterpSoaFloat3[soa];
        tCache_ = Cache(new uint[tracks], new ubyte[flags], 0);
        rCache_ = Cache(new uint[tracks], new ubyte[flags], 0);
        sCache_ = Cache(new uint[tracks], new ubyte[flags], 0);
    }

    /// Forgets the cached animation; the next run restarts from scratch.
    void invalidate() pure nothrow @nogc {
        animationUid_ = 0;
        ratio_ = 0;
        tCache_.next = 0;
        rCache_.next = 0;
        sCache_.next = 0;
    }

    /// Switches to `anim` (invalidating on change) and returns the previous ratio.
    private float step(ref const Animation anim, float ratio) pure nothrow @nogc {
        if (animationUid_ != anim.uid) {
            invalidate();
            animationUid_ = anim.uid;
        }
        immutable previous = ratio_;
        ratio_ = ratio;
        return previous;
    }
}

struct SamplingJob {
    /// Time ratio in `[0, 1]`; values outside are clamped.
    float ratio = 0;
    const(Animation)* animation;
    SamplingContext* context;
    /// Local-space output, 4 joints per element.
    SoaTransform[] output;

    bool validate() const scope pure nothrow @nogc {
        if (animation is null || context is null) return false;
        if (output.length == 0) return false;
        return context.maxSoaTracks >= animation.numSoaTracks;
    }

    bool run() scope pure nothrow @nogc {
        if (!validate()) return false;
        immutable numSoa = animation.numSoaTracks;
        if (numSoa <= 0) return true;

        immutable clamped = ratio < 0 ? 0.0f : (ratio > 1 ? 1.0f : ratio);
        immutable previous = context.step(*animation, clamped);

        updateCache(clamped, previous, numSoa, animation.timepoints, animation.translationsCtrl,
                    context.tCache_);
        decompress!(Float3Key, InterpSoaFloat3, decompressFloat3)(
            numSoa, animation.timepoints, animation.translationsCtrl, animation.translations,
            context.tCache_, context.translations_);

        updateCache(clamped, previous, numSoa, animation.timepoints, animation.rotationsCtrl,
                    context.rCache_);
        decompress!(QuaternionKey, InterpSoaQuaternion, decompressQuaternion)(
            numSoa, animation.timepoints, animation.rotationsCtrl, animation.rotations,
            context.rCache_, context.rotations_);

        updateCache(clamped, previous, numSoa, animation.timepoints, animation.scalesCtrl,
                    context.sCache_);
        decompress!(Float3Key, InterpSoaFloat3, decompressFloat3)(
            numSoa, animation.timepoints, animation.scalesCtrl, animation.scales,
            context.sCache_, context.scales_);

        immutable n = numSoa < output.length ? numSoa : output.length;
        interpolates(clamped, n, context.translations_, context.rotations_, context.scales_, output);
        return true;
    }
}

version (unittest) {
    import core.memory : GC;
    import engine.animation.io.archive : InputArchive;
    import engine.animation.testing : loadFixture, near;

    private Animation loadClip(string name) {
        auto ar = InputArchive(loadFixture(name));
        Animation a;
        assert(loadAnimation(ar, a), ar.error);
        return a;
    }

    private SoaTransform[] sample(ref const Animation a, ref SamplingContext ctx, float ratio) {
        auto out_ = new SoaTransform[a.numSoaTracks];
        SamplingJob job;
        job.ratio = ratio;
        job.animation = &a;
        job.context = &ctx;
        job.output = out_;
        assert(job.run());
        return out_;
    }

    private immutable clips = ["pab/walk.ozz", "pab/jog.ozz", "pab/run.ozz", "pab/crossarms.ozz",
                               "pab/crackhead_additive.ozz", "ruby_animation.ozz", "robot_animation.ozz"];
}

unittest {
    // Cache oracle: sampling with a long-lived context (forward, backward, random seeks) must be
    // bit-identical to sampling the same ratio with a brand new context.
    import std.random : Mt19937, uniform01;
    foreach (name; clips) {
        auto a = loadClip(name);
        auto ctx = SamplingContext(a.numTracks);
        Mt19937 rng;
        rng.seed(42);
        float[] ratios;
        foreach (i; 0 .. 120) ratios ~= i / 119.0f;                // forward
        foreach_reverse (i; 0 .. 120) ratios ~= i / 119.0f;        // backward
        foreach (i; 0 .. 150) ratios ~= uniform01!float(rng);      // random seeks
        foreach (i; 0 .. 150) ratios ~= (i * 0.0037f) % 1.0f;      // small forward steps with wrap
        ratios ~= [0.0f, 1.0f, 0.0f, 1.0f, 0.5f, 0.5f];
        foreach (r; ratios) {
            auto got = sample(a, ctx, r);
            auto fresh = SamplingContext(a.numTracks);
            auto want = sample(a, fresh, r);
            assert(got == want, name);
        }
    }
}

unittest {
    // Independent reference for translations: rebuild each track's key list and interpolate
    // without any cache.
    foreach (name; ["pab/walk.ozz", "ruby_animation.ozz", "robot_animation.ozz"]) {
        auto a = loadClip(name);
        immutable nt = a.numSoaTracks * 4;
        auto ctrl = a.translationsCtrl;
        size_t[][] keys = new size_t[][nt];
        auto last = new size_t[nt];
        foreach (t; 0 .. nt) { keys[t] = [t, t + nt]; last[t] = t + nt; }
        foreach (k; 2 * nt .. ctrl.previouses.length) {
            immutable target = k - ctrl.previouses[k];
            bool found;
            foreach (t; 0 .. nt) {
                if (last[t] == target) { keys[t] ~= k; last[t] = k; found = true; break; }
            }
            assert(found);
        }
        auto ctx = SamplingContext(a.numTracks);
        foreach (r; [0.0f, 0.013f, 0.25f, 0.5f, 0.77f, 0.999f, 1.0f, 0.3f, 0.05f]) {
            auto pose = sample(a, ctx, r);
            foreach (t; 0 .. a.numTracks) {
                auto ks = keys[t];
                size_t i = 0;
                while (i + 2 < ks.length && a.timepoints[ctrl.ratios[ks[i + 1]]] <= r) ++i;
                immutable r0 = a.timepoints[ctrl.ratios[ks[i]]];
                immutable r1 = a.timepoints[ctrl.ratios[ks[i + 1]]];
                immutable alpha = (r - r0) / (r1 - r0);
                float[3] want;
                foreach (c; 0 .. 3) {
                    immutable v0 = halfToFloat(a.translations[ks[i]].values[c]);
                    immutable v1 = halfToFloat(a.translations[ks[i + 1]].values[c]);
                    want[c] = v0 + (v1 - v0) * alpha;
                }
                immutable lane = t % 4;
                const tr = pose[t / 4].translation;
                assert(near(tr.x[lane], want[0], 1e-4f) && near(tr.y[lane], want[1], 1e-4f)
                       && near(tr.z[lane], want[2], 1e-4f), name);
            }
        }
    }
}

unittest {
    // Output rotations are unit quaternions and values are finite everywhere in the clip.
    import std.math : isFinite, abs;
    foreach (name; clips) {
        auto a = loadClip(name);
        auto ctx = SamplingContext(a.numTracks);
        foreach (i; 0 .. 50) {
            auto pose = sample(a, ctx, i / 49.0f);
            foreach (ref t; pose) {
                foreach (l; 0 .. 4) {
                    immutable len2 = t.rotation.x[l] ^^ 2 + t.rotation.y[l] ^^ 2
                                   + t.rotation.z[l] ^^ 2 + t.rotation.w[l] ^^ 2;
                    assert(abs(len2 - 1) < 1e-3f, name);
                    assert(isFinite(t.translation.x[l]) && isFinite(t.scale.y[l]));
                }
            }
        }
    }
}

unittest {
    // Ratio is clamped; 0 and 1 are the clip extremes.
    auto a = loadClip("pab/walk.ozz");
    auto c0 = SamplingContext(a.numTracks), c1 = SamplingContext(a.numTracks);
    assert(sample(a, c0, -3.0f) == sample(a, c1, 0.0f));
    assert(sample(a, c0, 7.0f) == sample(a, c1, 1.0f));
}

unittest {
    // Switching clips on the same context invalidates the cache (via uid).
    auto walk = loadClip("pab/walk.ozz");
    auto jog = loadClip("pab/jog.ozz");
    auto ctx = SamplingContext(80);
    sample(walk, ctx, 0.7f);
    auto got = sample(jog, ctx, 0.2f);
    auto fresh = SamplingContext(80);
    assert(got == sample(jog, fresh, 0.2f));
    // Back to walk at a ratio before the previous one.
    assert(sample(walk, ctx, 0.1f) == sample(walk, fresh, 0.1f));
}

unittest {
    // Output buffer size contract and validation.
    auto a = loadClip("pab/walk.ozz");
    auto ctx = SamplingContext(a.numTracks);
    auto full = sample(a, ctx, 0.4f);

    // Smaller output: only the first groups are written.
    auto small = new SoaTransform[2];
    SamplingJob job;
    job.ratio = 0.4f;
    job.animation = &a;
    job.context = &ctx;
    job.output = small;
    assert(job.run());
    assert(small == full[0 .. 2]);

    // Larger output: trailing elements are untouched.
    auto big = new SoaTransform[a.numSoaTracks + 3];
    foreach (ref t; big[a.numSoaTracks .. $]) t.translation.x = SimdFloat4.load1(99);
    job.output = big;
    assert(job.run());
    assert(big[0 .. a.numSoaTracks] == full);
    foreach (ref t; big[a.numSoaTracks .. $]) assert(t.translation.x == SimdFloat4.load1(99));

    // Invalid jobs.
    auto tiny = SamplingContext(4);
    SamplingJob bad;
    assert(!bad.run());
    bad = job;
    bad.output = null;
    assert(!bad.run());
    bad = job;
    bad.context = &tiny;
    assert(!bad.validate() == (a.numSoaTracks > 1));
}

unittest {
    // The frame path allocates nothing.
    auto a = loadClip("pab/walk.ozz");
    auto ctx = SamplingContext(a.numTracks);
    auto out_ = new SoaTransform[a.numSoaTracks];
    SamplingJob job;
    job.animation = &a;
    job.context = &ctx;
    job.output = out_;
    job.ratio = 0.1f;
    job.run();
    immutable before = GC.stats().usedSize;
    foreach (i; 0 .. 200) {
        job.ratio = (i % 100) / 100.0f;
        assert(job.run());
    }
    assert(GC.stats().usedSize == before);
}

private:

pure nothrow @nogc:

uint trackForward(const(uint)[] cache, const(ushort)[] previouses, uint key, uint lastTrack,
                  uint numTracks) {
    immutable target = key - previouses[key];
    foreach (e; lastTrack .. numTracks) {
        if (cache[e] == target) return e;
    }
    foreach (e; 0 .. lastTrack) {
        if (cache[e] == target) return e;
    }
    return lastTrack; // unreachable for validated animations
}

uint trackBackward(const(uint)[] cache, uint target, uint lastTrack, uint numTracks) {
    for (uint e = lastTrack + 1; e-- > 0;) {
        if (cache[e] == target) return e;
    }
    for (uint e = numTracks; e-- > lastTrack + 1;) {
        if (cache[e] == target) return e;
    }
    return lastTrack; // unreachable for validated animations
}

float keyRatio(const(float)[] timepoints, const(ushort)[] ratios, size_t at) {
    return timepoints[ratios[at]];
}

SimdFloat4 keysRatio(const(float)[] timepoints, const(ushort)[] ratios, const(uint)[] ats) {
    return SimdFloat4(timepoints[ratios[ats[0]]], timepoints[ratios[ats[1]]],
                      timepoints[ratios[ats[2]]], timepoints[ratios[ats[3]]]);
}

uint initializeCache(ref const KeyframesCtrl ctrl, size_t iframe, uint[] entries) {
    if (iframe > 0) {
        immutable i = (iframe - 1) * 2;
        immutable offset = ctrl.iframeDesc[i];
        decodeGV4Stream(ctrl.iframeEntries[offset .. $], entries);
        return ctrl.iframeDesc[i + 1] + 1;
    }
    immutable numTracks = cast(uint) entries.length;
    foreach (i; 0 .. numTracks) entries[i] = i + numTracks;
    return numTracks * 2;
}

void outdateCache(ubyte[] outdated, size_t numSoaTracks) {
    immutable numFlags = (numSoaTracks + 7) / 8;
    size_t i = 0;
    for (; i < numFlags - 1; ++i) outdated[i] = 0xff;
    outdated[i] = cast(ubyte)(0xff >> (numFlags * 8 - numSoaTracks));
}

void updateCache(float ratio, float previousRatio, size_t numSoaTracks, const(float)[] timepoints,
                 ref const KeyframesCtrl ctrl, ref Cache cache) {
    immutable numTracks = cast(uint)(numSoaTracks * 4);
    immutable numKeys = cast(uint) ctrl.previouses.length;
    uint next = cache.next;

    immutable delta = ratio - previousRatio;
    immutable adelta = delta < 0 ? -delta : delta;
    if (next == 0 || adelta > ctrl.iframeInterval / 2.0f) {
        int iframe = -1;
        if (ctrl.iframeDesc.length != 0) {
            iframe = cast(int)(0.5f + ratio / ctrl.iframeInterval);
        } else if (next == 0 || delta < 0.0f) {
            iframe = 0;
        }
        if (iframe >= 0) {
            next = initializeCache(ctrl, iframe, cache.entries[0 .. numTracks]);
            outdateCache(cache.outdated, numSoaTracks);
        }
    }

    // Reading forward.
    uint track = 0;
    for (; next < numKeys && keyRatio(timepoints, ctrl.ratios, next - ctrl.previouses[next]) <= ratio;
         ++next) {
        track = trackForward(cache.entries, ctrl.previouses, next, track, numTracks);
        cache.outdated[track / 32] |= cast(ubyte)(1 << ((track & 0x1f) / 4));
        cache.entries[track] = next;
    }

    // Rewinding.
    for (; keyRatio(timepoints, ctrl.ratios, (next - 1) - ctrl.previouses[next - 1]) > ratio; --next) {
        track = trackBackward(cache.entries, next - 1, track, numTracks);
        cache.outdated[track / 32] |= cast(ubyte)(1 << ((track & 0x1f) / 4));
        cache.entries[track] -= ctrl.previouses[cache.entries[track]];
    }
    cache.next = next;
}

void decompress(K, D, alias fn)(size_t numSoaTracks, const(float)[] timepoints,
                                ref const KeyframesCtrl ctrl, const(K)[] compressed,
                                ref Cache cache, D[] decompressed) {
    immutable numFlags = (numSoaTracks + 7) / 8;
    foreach (j; 0 .. numFlags) {
        ubyte outdated = cache.outdated[j];
        cache.outdated[j] = 0;
        for (size_t i = j * 8; outdated != 0; ++i, outdated >>= 1) {
            if (!(outdated & 1)) continue;
            const(uint)[] rights = cache.entries[i * 4 .. i * 4 + 4];
            immutable uint[4] lefts = [
                rights[0] - ctrl.previouses[rights[0]], rights[1] - ctrl.previouses[rights[1]],
                rights[2] - ctrl.previouses[rights[2]], rights[3] - ctrl.previouses[rights[3]]];
            decompressed[i].ratio[0] = keysRatio(timepoints, ctrl.ratios, lefts[]);
            fn(compressed[lefts[0]], compressed[lefts[1]], compressed[lefts[2]], compressed[lefts[3]],
               decompressed[i].value[0]);
            decompressed[i].ratio[1] = keysRatio(timepoints, ctrl.ratios, rights);
            fn(compressed[rights[0]], compressed[rights[1]], compressed[rights[2]], compressed[rights[3]],
               decompressed[i].value[1]);
        }
    }
}

void decompressFloat3(const Float3Key k0, const Float3Key k1, const Float3Key k2, const Float3Key k3,
                      out SoaFloat3 r) {
    r.x = halfToFloat4(SimdInt4(k0.values[0], k1.values[0], k2.values[0], k3.values[0]));
    r.y = halfToFloat4(SimdInt4(k0.values[1], k1.values[1], k2.values[1], k3.values[1]));
    r.z = halfToFloat4(SimdInt4(k0.values[2], k1.values[2], k2.values[2], k3.values[2]));
}

// Component assignment per largest-component index (see upstream kCpntMapping).
immutable ubyte[4][4] kCpntMapping = [[0, 0, 1, 2], [0, 0, 1, 2], [0, 1, 0, 2], [0, 1, 2, 0]];

void decompressQuaternion(const QuaternionKey k0, const QuaternionKey k1, const QuaternionKey k2,
                          const QuaternionKey k3, out SoaQuaternion q) {
    immutable QuaternionKey[4] keys = [k0, k1, k2, k3];
    int[4] largests, signs;
    int[3][4] values;
    foreach (l; 0 .. 4) unpack(keys[l], largests[l], signs[l], values[l]);

    enum float kSqrt2 = 1.41421356237309504880f;
    enum float kSqrt2_2 = 0.707106781186547524401f;
    immutable kScale = SimdFloat4.load1(kSqrt2 / QuaternionKey.kfScale);
    immutable kOffset = SimdFloat4.load1(-kSqrt2_2);

    // cmp[c] lane l = quantized value feeding output component c of lane l.
    SimdFloat4[4] cpnt;
    foreach (c; 0 .. 4) {
        SimdInt4 cmp;
        foreach (l; 0 .. 4) cmp[l] = values[l][kCpntMapping[largests[l]][c]];
        cpnt[c] = kScale * SimdFloat4.fromInt(cmp) + kOffset;
    }

    // Zero the largest component of each lane so it is not part of the dot.
    foreach (l; 0 .. 4) cpnt[largests[l]][l] = 0;

    immutable dotv = cpnt[0] * cpnt[0] + cpnt[1] * cpnt[1] + cpnt[2] * cpnt[2] + cpnt[3] * cpnt[3];
    immutable ww0 = SimdFloat4.one() - dotv;
    immutable w0 = ww0 * rsqrtEst(ww0);

    immutable sign = shiftL(SimdInt4(signs[0], signs[1], signs[2], signs[3]), 31);
    immutable restored = orBits(w0, sign);

    // Re-inject the restored largest component (lane is currently 0).
    foreach (l; 0 .. 4) cpnt[largests[l]][l] = restored[l];

    q.x = cpnt[0];
    q.y = cpnt[1];
    q.z = cpnt[2];
    q.w = cpnt[3];
}

void interpolates(float animRatio, size_t numSoaTracks, const(InterpSoaFloat3)[] translations,
                  const(InterpSoaQuaternion)[] rotations, const(InterpSoaFloat3)[] scales,
                  SoaTransform[] output) {
    immutable ratio = SimdFloat4.load1(animRatio);
    foreach (i; 0 .. numSoaTracks) {
        const t = &translations[i];
        immutable tRatio = (ratio - t.ratio[0]) * rcpEst(t.ratio[1] - t.ratio[0]);
        const r = &rotations[i];
        immutable rRatio = (ratio - r.ratio[0]) * rcpEst(r.ratio[1] - r.ratio[0]);
        const s = &scales[i];
        immutable sRatio = (ratio - s.ratio[0]) * rcpEst(s.ratio[1] - s.ratio[0]);
        output[i].translation = lerp(t.value[0], t.value[1], tRatio);
        output[i].rotation = nlerpEst(r.value[0], r.value[1], rRatio);
        output[i].scale = lerp(s.value[0], s.value[1], sRatio);
    }
}
