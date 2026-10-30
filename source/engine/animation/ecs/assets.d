/// Engine-owned stores for animation assets, referenced from components through `Handle!`.
///
/// `Skeleton`, `Animation` and `Track!T` contain slices, so they are not POD and never live in
/// component storage; components hold generational handles into these stores instead.
module engine.animation.ecs.assets;

import engine.animation.clip;
import engine.animation.io.archive;
import engine.animation.math.simd;
import engine.animation.skeleton;
import engine.animation.track;
import engine.core.handle : Handle;

@safe:

struct SkeletonAssetTag {}
struct AnimationAssetTag {}
struct TrackAssetTag {}
struct SkinAssetTag {}

alias SkeletonHandle = Handle!SkeletonAssetTag;
alias AnimationHandle = Handle!AnimationAssetTag;
alias TrackHandle = Handle!TrackAssetTag;
alias SkinHandle = Handle!SkinAssetTag;

/// Binds a mesh skin to a skeleton: for mesh joint `j`, `remap[j]` is the skeleton joint index and
/// `inverseBinds[j]` its inverse bind matrix. The palette entry is `model[remap[j]] * inverseBind[j]`.
struct SkinBinding {
    SkeletonHandle skeleton;
    uint[] remap;
    Float4x4[] inverseBinds;
}

/// Generational slot store. Handle index 0 is reserved for the null handle.
struct AssetStore(T, Tag) {
    private struct Slot {
        T value;
        uint generation = 1;
        bool used;
    }
    private Slot[] slots_;
    private uint[] free_;

    Handle!Tag add(T value) {
        if (slots_.length == 0) slots_ ~= Slot.init; // index 0 = null
        uint idx;
        if (free_.length > 0) {
            idx = free_[$ - 1];
            free_.length = free_.length - 1;
        } else {
            idx = cast(uint) slots_.length;
            slots_ ~= Slot.init;
        }
        slots_[idx].value = value;
        slots_[idx].used = true;
        return Handle!Tag(idx, slots_[idx].generation);
    }
    /// Pointer to the asset, or null if the handle is null or stale. The pointer is invalidated by
    /// the next `add`; fetch it again each frame.
    const(T)* get(Handle!Tag h) const pure nothrow @nogc @trusted {
        if (h.index == 0 || h.index >= slots_.length) return null;
        const s = &slots_[h.index];
        return (s.used && s.generation == h.generation) ? &s.value : null;
    }

    /// Replaces the asset behind `h` (hot reload). The handle stays valid.
    bool replace(Handle!Tag h, T value) {
        if (get(h) is null) return false;
        slots_[h.index].value = value;
        return true;
    }

    /// Frees the slot; all handles to it become stale.
    void remove(Handle!Tag h) {
        if (get(h) is null) return;
        slots_[h.index].used = false;
        slots_[h.index].value = T.init;
        slots_[h.index].generation++;
        free_ ~= h.index;
    }

    size_t count() const pure nothrow @nogc {
        size_t n = 0;
        foreach (ref s; slots_) if (s.used) ++n;
        return n;
    }
}


alias SkeletonStore = AssetStore!(Skeleton, SkeletonAssetTag);
alias AnimationStore = AssetStore!(Animation, AnimationAssetTag);
alias FloatTrackStore = AssetStore!(FloatTrack, TrackAssetTag);
alias SkinStore = AssetStore!(SkinBinding, SkinAssetTag);

/// All animation assets of a world.
struct AnimAssets {
    SkeletonStore skeletons;
    AnimationStore animations;
    FloatTrackStore floatTracks;
    SkinStore skins;
}

private const(ubyte)[] readFile(string path) @trusted {
    import std.file : read;
    return cast(const(ubyte)[]) read(path);
}

/// Loads a skeleton `.ozz` file. Returns a null handle on failure (error text in `error`).
SkeletonHandle loadSkeletonFile(ref SkeletonStore store, string path, out string error) {
    try {
        auto ar = InputArchive(readFile(path));
        Skeleton s;
        if (!loadSkeleton(ar, s)) { error = ar.error; return SkeletonHandle.init; }
        return store.add(s);
    } catch (Exception e) {
        error = e.msg;
        return SkeletonHandle.init;
    }
}

/// Loads an animation `.ozz` file.
AnimationHandle loadAnimationFile(ref AnimationStore store, string path, out string error) {
    try {
        auto ar = InputArchive(readFile(path));
        Animation a;
        if (!loadAnimation(ar, a)) { error = ar.error; return AnimationHandle.init; }
        return store.add(a);
    } catch (Exception e) {
        error = e.msg;
        return AnimationHandle.init;
    }
}

/// Hot reload: re-reads `path` and replaces the animation behind `h`. The new animation has a new
/// `uid`, so sampling contexts invalidate themselves on the next run.
bool reloadAnimationFile(ref AnimationStore store, AnimationHandle h, string path, out string error) {
    try {
        auto ar = InputArchive(readFile(path));
        Animation a;
        if (!loadAnimation(ar, a)) { error = ar.error; return false; }
        return store.replace(h, a);
    } catch (Exception e) {
        error = e.msg;
        return false;
    }
}

version (unittest) import engine.animation.testing : fixtureDir;

unittest {
    AnimAssets assets;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtureDir ~ "pab/skeleton.ozz", err);
    auto walk = loadAnimationFile(assets.animations, fixtureDir ~ "pab/walk.ozz", err);
    assert(!sk.isNull && !walk.isNull, err);
    assert(assets.skeletons.get(sk).numJoints > 0);
    assert(assets.animations.get(walk).duration > 0);

    // Failures give a null handle and a message.
    auto bad = loadSkeletonFile(assets.skeletons, fixtureDir ~ "pab/walk.ozz", err);
    assert(bad.isNull && err.length > 0);
    bad = loadSkeletonFile(assets.skeletons, "does/not/exist.ozz", err);
    assert(bad.isNull);

    // Hot reload keeps the handle and changes the uid; remove makes handles stale and reuses the slot.
    immutable oldUid = assets.animations.get(walk).uid;
    assert(reloadAnimationFile(assets.animations, walk, fixtureDir ~ "pab/walk.ozz", err));
    assert(assets.animations.get(walk).uid != oldUid);
    auto jog = loadAnimationFile(assets.animations, fixtureDir ~ "pab/jog.ozz", err);
    assets.animations.remove(jog);
    assert(assets.animations.get(jog) is null);
    auto run = loadAnimationFile(assets.animations, fixtureDir ~ "pab/run.ozz", err);
    assert(run.index == jog.index && run.generation != jog.generation);
    assert(assets.animations.get(jog) is null && assets.animations.get(run) !is null);
    assert(assets.animations.count == 2);
    assert(assets.animations.get(AnimationHandle.init) is null);
}
