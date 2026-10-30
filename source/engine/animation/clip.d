// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/animation.cc @ 744eb9d
/// Runtime animation clip: keyframes of all tracks, sorted by time and compressed.
///
/// Deviations from upstream: key ratios are widened to `ushort[]` at load (upstream keeps raw
/// `u8` when there are <= 255 timepoints), each clip gets a process-unique `uid` that the sampling
/// context caches on instead of a raw address, and all structural invariants the sampler relies on
/// are validated at load time.
module engine.animation.clip;

import core.atomic : atomicOp;
import engine.animation.io.archive;
import engine.animation.io.group_varint;
import engine.animation.keyframe;

@safe:

enum string animationTag = "ozz-animation\0";
enum int kMaxTracks = 1024;

private shared ulong nextUid_;

private ulong newUid() @trusted nothrow @nogc {
    return atomicOp!"+="(nextUid_, 1);
}

/// Per-component (translation / rotation / scale) key sequencing data.
struct KeyframesCtrl {
    /// Index into `Animation.timepoints` for each key.
    ushort[] ratios;
    /// Distance (in keys) back to the previous key of the same track.
    ushort[] previouses;
    /// GV4-compressed snapshots of the sampling cache (see `SamplingJob`).
    ubyte[] iframeEntries;
    /// Pairs `(offset into iframeEntries, last cached key)` per iframe.
    uint[] iframeDesc;
    float iframeInterval = 0;
}

struct Animation {
    float duration = 0;
    int numTracks;
    string name;
    float[] timepoints;
    KeyframesCtrl translationsCtrl, rotationsCtrl, scalesCtrl;
    Float3Key[] translations;
    QuaternionKey[] rotations;
    Float3Key[] scales;
    ulong uid;

    int numSoaTracks() const pure nothrow @nogc { return (numTracks + 3) / 4; }
}

private void readCtrl(ref InputArchive ar, ref KeyframesCtrl c, size_t keys, size_t entries,
                      size_t desc) {
    c.ratios = new ushort[keys];
    c.previouses = new ushort[keys];
    c.iframeEntries = new ubyte[entries];
    c.iframeDesc = new uint[desc];
}

/// Reads the ctrl block. `wideRatios` selects u16 (true) or u8 (false) key ratios.
private void readCtrlData(ref InputArchive ar, ref KeyframesCtrl c, bool wideRatios) {
    foreach (ref r; c.ratios) r = wideRatios ? ar.read!ushort() : ar.read!ubyte();
    ar.readArray(c.previouses);
    foreach (ref b; c.iframeEntries) b = ar.read!ubyte();
    ar.readArray(c.iframeDesc);
    c.iframeInterval = ar.read!float();
}

private bool validateCtrl(ref InputArchive ar, const ref KeyframesCtrl c, const(float)[] timepoints,
                          int numTracks) {
    immutable keys = c.ratios.length;
    immutable numSoaTracks = (numTracks + 3) / 4;
    immutable minKeys = cast(size_t) numSoaTracks * 4 * 2;
    if (keys < minKeys) {
        ar.fail("animation has fewer keys than 2 per track");
        return false;
    }
    if (keys > kMaxPreviousOffset * cast(size_t) 1024) {
        ar.fail("animation key count out of range");
        return false;
    }
    foreach (k; 0 .. keys) {
        if (c.ratios[k] >= timepoints.length) {
            ar.fail("animation key ratio index out of range");
            return false;
        }
        if (c.previouses[k] > k) {
            ar.fail("animation key previous offset out of range");
            return false;
        }
    }
    // Initial left/right pairs: key i (i < numTracks) is followed by key i + numTracks.
    immutable nt = numSoaTracks * 4;
    foreach (k; nt .. 2 * nt) {
        if (c.previouses[k] != nt) {
            ar.fail("animation initial key pairing invalid");
            return false;
        }
    }
    // Iframes.
    if (c.iframeDesc.length % 2 != 0) {
        ar.fail("animation iframe descriptor count is odd");
        return false;
    }
    if (c.iframeDesc.length > 0 && !(c.iframeInterval > 0)) {
        ar.fail("animation iframe interval invalid");
        return false;
    }
    auto cache = new uint[nt];
    for (size_t i = 0; i < c.iframeDesc.length; i += 2) {
        immutable offset = c.iframeDesc[i];
        immutable last = c.iframeDesc[i + 1];
        if (offset > c.iframeEntries.length || last + 1 < 2 * nt || last + 1 > keys) {
            ar.fail("animation iframe descriptor out of range");
            return false;
        }
        if (decodeGV4Stream(c.iframeEntries[offset .. $], cache) == size_t.max) {
            ar.fail("animation iframe entries truncated");
            return false;
        }
        foreach (e; cache) {
            if (e >= keys) {
                ar.fail("animation iframe entry out of range");
                return false;
            }
        }
    }
    return true;
}

/// Reads one animation (tag, version 7) from `ar`. On failure returns false and leaves the
/// reason in `ar.error`.
bool loadAnimation(ref InputArchive ar, out Animation anim) {
    uint ver;
    if (!ar.beginObject(animationTag, ver)) return false;
    if (ver != 7) {
        ar.fail("unsupported animation version");
        return false;
    }
    Animation a;
    a.duration = ar.read!float();
    immutable numTracks = ar.read!uint();
    immutable nameLen = ar.read!uint();
    immutable timepointsCount = ar.read!uint();
    immutable tCount = ar.read!uint();
    immutable rCount = ar.read!uint();
    immutable sCount = ar.read!uint();
    immutable tEntries = ar.read!uint();
    immutable tDesc = ar.read!uint();
    immutable rEntries = ar.read!uint();
    immutable rDesc = ar.read!uint();
    immutable sEntries = ar.read!uint();
    immutable sDesc = ar.read!uint();
    if (!ar.ok) return false;

    if (numTracks > kMaxTracks) {
        ar.fail("animation track count out of range");
        return false;
    }
    // Every count must be coverable by the remaining bytes (a cheap guard against huge allocs).
    immutable remaining = ar.remaining();
    foreach (n; [nameLen, timepointsCount, tCount, rCount, sCount, tEntries, tDesc, rEntries, rDesc,
                 sEntries, sDesc]) {
        if (n > remaining) {
            ar.fail("animation section size exceeds archive");
            return false;
        }
    }
    if (timepointsCount > ushort.max) {
        ar.fail("animation timepoint count out of range");
        return false;
    }
    a.numTracks = cast(int) numTracks;

    auto nameBytes = ar.readBytes(nameLen);
    if (!ar.ok) return false;
    a.name = (cast(const(char)[]) nameBytes).idup;

    a.timepoints = new float[timepointsCount];
    ar.readArray(a.timepoints);
    immutable wide = timepointsCount > ubyte.max;

    readCtrl(ar, a.translationsCtrl, tCount, tEntries, tDesc);
    readCtrlData(ar, a.translationsCtrl, wide);
    a.translations = new Float3Key[tCount];
    foreach (ref k; a.translations) ar.readArray(k.values[]);

    readCtrl(ar, a.rotationsCtrl, rCount, rEntries, rDesc);
    readCtrlData(ar, a.rotationsCtrl, wide);
    a.rotations = new QuaternionKey[rCount];
    foreach (ref k; a.rotations) ar.readArray(k.values[]);

    readCtrl(ar, a.scalesCtrl, sCount, sEntries, sDesc);
    readCtrlData(ar, a.scalesCtrl, wide);
    a.scales = new Float3Key[sCount];
    foreach (ref k; a.scales) ar.readArray(k.values[]);
    if (!ar.ok) return false;

    // Timepoints sorted in [0, 1].
    float prev = 0;
    foreach (t; a.timepoints) {
        if (!(t >= prev) || t > 1.0f) {
            ar.fail("animation timepoints not sorted in [0, 1]");
            return false;
        }
        prev = t;
    }
    if (a.numTracks > 0) {
        if (a.timepoints.length == 0) {
            ar.fail("animation has tracks but no timepoints");
            return false;
        }
        if (!validateCtrl(ar, a.translationsCtrl, a.timepoints, a.numTracks)
            || !validateCtrl(ar, a.rotationsCtrl, a.timepoints, a.numTracks)
            || !validateCtrl(ar, a.scalesCtrl, a.timepoints, a.numTracks)) {
            return false;
        }
    }
    a.uid = newUid();
    anim = a;
    return true;
}

/// Number of keyframes of the given track (`track` in `[0, numTracks)`), per component.
int countTranslationKeyframes(ref const Animation a, int track) {
    return countKeys(a.translationsCtrl, a.numTracks, track);
}
int countRotationKeyframes(ref const Animation a, int track) {
    return countKeys(a.rotationsCtrl, a.numTracks, track);
}
int countScaleKeyframes(ref const Animation a, int track) {
    return countKeys(a.scalesCtrl, a.numTracks, track);
}

private int countKeys(const ref KeyframesCtrl c, int numTracks, int track) {
    // Keys are linked to their predecessor of the same track; count by walking track chains is
    // not possible without a track id, so rebuild it from the initial cache like the sampler does.
    immutable nt = ((numTracks + 3) / 4) * 4;
    auto entries = new uint[nt];
    foreach (i; 0 .. nt) entries[i] = cast(uint)(i + nt);
    int count = 2;
    foreach (next; 2 * nt .. c.previouses.length) {
        immutable target = next - c.previouses[next];
        foreach (t; 0 .. nt) {
            if (entries[t] == target) {
                entries[t] = cast(uint) next;
                if (t == track) ++count;
                break;
            }
        }
    }
    return count;
}

unittest {
    import engine.animation.testing : loadFixture;
    foreach (name; ["pab/walk.ozz", "pab/jog.ozz", "pab/run.ozz", "pab/crossarms.ozz",
                    "pab/crackhead_additive.ozz", "ruby_animation.ozz",
                    "robot_animation.ozz", "versioning/animation_v7_le.ozz",
                    "versioning/animation_v7_be.ozz"]) {
        auto ar = InputArchive(loadFixture(name));
        Animation a;
        assert(loadAnimation(ar, a), name ~ ": " ~ ar.error);
        assert(a.duration > 0);
        assert(a.numTracks > 0);
        assert(a.translations.length == a.translationsCtrl.ratios.length);
        assert(a.rotations.length >= 2 * a.numSoaTracks * 4);
        assert(a.uid != 0);
    }
}

unittest {
    import engine.animation.testing : loadFixture;
    auto le = InputArchive(loadFixture("versioning/animation_v7_le.ozz"));
    auto be = InputArchive(loadFixture("versioning/animation_v7_be.ozz"));
    Animation a, b;
    assert(loadAnimation(le, a) && loadAnimation(be, b));
    assert(a.duration == b.duration && a.numTracks == b.numTracks && a.name == b.name);
    assert(a.timepoints == b.timepoints);
    assert(a.translations == b.translations && a.rotations == b.rotations && a.scales == b.scales);
    assert(a.rotationsCtrl.iframeDesc == b.rotationsCtrl.iframeDesc);
    assert(a.uid != b.uid);
}

unittest {
    import engine.animation.testing : loadFixture;
    auto ar = InputArchive(loadFixture("versioning/animation_v6_le.ozz"));
    Animation a;
    assert(!loadAnimation(ar, a));
    assert(ar.error == "unsupported animation version");
}

unittest {
    // Key counts per track: every track has at least its 2 initial keys; the per-track totals
    // add up to the number of keys in the file.
    import engine.animation.testing : loadFixture;
    auto ar = InputArchive(loadFixture("pab/walk.ozz"));
    Animation a;
    assert(loadAnimation(ar, a));
    size_t total = 0;
    foreach (t; 0 .. a.numSoaTracks * 4) {
        immutable n = countRotationKeyframes(a, t);
        assert(n >= 2);
        total += n;
    }
    assert(total == a.rotations.length);
}

unittest {
    // Truncation anywhere fails cleanly (no range errors escape).
    import engine.animation.testing : loadFixture;
    auto data = loadFixture("pab/walk.ozz");
    Animation a;
    for (size_t n = 0; n < data.length; n += 97) {
        auto ar = InputArchive(data[0 .. n]);
        assert(!loadAnimation(ar, a));
    }
}
