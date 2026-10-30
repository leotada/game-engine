/// Per-frame animation systems over an ECS `World`. All are `@nogc`: buffers come from the
/// `PosePool` allocated at spawn.
///
/// Order: `advancePlaybackSystem` -> `sampleSystem` -> `blendSystem` -> `localToModelSystem` ->
/// `lookAtSystem` (needs model-space joints, then re-runs local-to-model from the aimed joint) ->
/// `skinPaletteSystem`. Each character is independent, so every system is a candidate for the
/// parallel ECS (docs/plan-parallel-ecs.md).
module engine.animation.ecs.systems;

import engine.animation.blending;
import engine.animation.clip;
import engine.animation.ecs.assets;
import engine.animation.ecs.components;
import engine.animation.ecs.pose_pool;
import engine.animation.ik;
import engine.animation.local_to_model;
import engine.animation.math.scalar : Vec3, Quat;
import engine.animation.math.simd;
import engine.animation.math.soa;
import engine.animation.sampling;
import engine.animation.skeleton;

@safe:

private float advanceTime(float time, float delta, float duration, bool loop) pure nothrow @nogc {
    if (duration <= 0) return 0;
    float t = time + delta;
    if (loop) {
        t = t - duration * cast(float)(cast(int)(t / duration));
        if (t < 0) t += duration;
    } else {
        t = t < 0 ? 0 : (t > duration ? duration : t);
    }
    return t;
}

void advancePlaybackSystem(W)(ref W world, ref const AnimAssets assets, float dt) {
    foreach (e; world.query!AnimPlayback()) {
        auto p = world.getPtr!AnimPlayback(e);
        if (auto clip = assets.animations.get(p.clip))
            p.time = advanceTime(p.time, p.speed * dt, clip.duration, p.loop);
    }
    foreach (e; world.query!AnimBlend2()) {
        auto b = world.getPtr!AnimBlend2(e);
        if (auto ca = assets.animations.get(b.a)) b.timeA = advanceTime(b.timeA, b.speed * dt, ca.duration, true);
        if (auto cb = assets.animations.get(b.b)) b.timeB = advanceTime(b.timeB, b.speed * dt, cb.duration, true);
    }
    foreach (e; world.query!AnimAdditive()) {
        auto a = world.getPtr!AnimAdditive(e);
        if (auto c = assets.animations.get(a.clip)) a.time = advanceTime(a.time, a.speed * dt, c.duration, true);
    }
}

private bool sampleClip(const(Animation)* clip, float time, ref SamplingContext ctx,
                        SoaTransform[] output) @trusted pure nothrow @nogc {
    SamplingJob job;
    job.ratio = clip.duration > 0 ? time / clip.duration : 0;
    job.animation = clip;
    job.context = &ctx;
    job.output = output;
    return job.run();
}

void sampleSystem(W)(ref W world, ref const AnimAssets assets, ref PosePool pool) {
    foreach (e; world.query!AnimSkeleton()) {
        auto pose = pool.get(world.getPtr!AnimSkeleton(e).poseSlot);
        if (pose is null) continue;
        if (auto b = world.getPtr!AnimBlend2(e)) {
            if (auto c = assets.animations.get(b.a)) sampleClip(c, b.timeA, pose.ctx0, pose.local0);
            if (auto c = assets.animations.get(b.b)) sampleClip(c, b.timeB, pose.ctx1, pose.local1);
        } else if (auto p = world.getPtr!AnimPlayback(e)) {
            if (auto c = assets.animations.get(p.clip)) sampleClip(c, p.time, pose.ctx0, pose.local0);
        }
        if (auto a = world.getPtr!AnimAdditive(e)) {
            if (a.weight != 0)
                if (auto c = assets.animations.get(a.clip)) sampleClip(c, a.time, pose.ctx2, pose.local2);
        }
    }
}

void blendSystem(W)(ref W world, ref const AnimAssets assets, ref PosePool pool) @trusted {
    foreach (e; world.query!AnimSkeleton()) {
        auto sk = world.getPtr!AnimSkeleton(e);
        auto pose = pool.get(sk.poseSlot);
        auto skeleton = assets.skeletons.get(sk.skeleton);
        if (pose is null || skeleton is null) continue;

        BlendingJob.Layer[2] layers;
        size_t n = 0;
        if (auto b = world.getPtr!AnimBlend2(e)) {
            immutable w = b.weight < 0 ? 0 : (b.weight > 1 ? 1 : b.weight);
            layers[n++] = BlendingJob.Layer(1.0f - w, pose.local0);
            layers[n++] = BlendingJob.Layer(w, pose.local1);
        } else if (world.has!AnimPlayback(e)) {
            layers[n++] = BlendingJob.Layer(1.0f, pose.local0);
        }
        BlendingJob.Layer[1] additive;
        size_t na = 0;
        if (auto a = world.getPtr!AnimAdditive(e)) {
            if (a.weight != 0) additive[na++] = BlendingJob.Layer(a.weight, pose.local2);
        }

        BlendingJob job;
        job.restPose = skeleton.restPoses;
        job.output = pose.blended;
        job.layers = layers[0 .. n];
        job.additiveLayers = additive[0 .. na];
        job.run();
    }
}

void localToModelSystem(W)(ref W world, ref const AnimAssets assets, ref PosePool pool) @trusted {
    foreach (e; world.query!AnimSkeleton()) {
        auto sk = world.getPtr!AnimSkeleton(e);
        auto pose = pool.get(sk.poseSlot);
        auto skeleton = assets.skeletons.get(sk.skeleton);
        if (pose is null || skeleton is null) continue;
        LocalToModelJob job;
        job.skeleton = skeleton;
        job.input = pose.blended;
        job.output = pose.model;
        job.run();
    }
}

/// Aims `AnimLookAt.headJoint` at the target. Runs after `localToModelSystem`: it corrects the
/// local rotation of the joint, then refreshes model matrices from that joint down.
void lookAtSystem(W)(ref W world, ref const AnimAssets assets, ref PosePool pool) @trusted {
    foreach (e; world.query!(AnimSkeleton, AnimLookAt)()) {
        auto sk = world.getPtr!AnimSkeleton(e);
        auto look = world.getPtr!AnimLookAt(e);
        auto pose = pool.get(sk.poseSlot);
        auto skeleton = assets.skeletons.get(sk.skeleton);
        if (pose is null || skeleton is null || look.headJoint >= skeleton.numJoints) continue;

        Quat correction;
        IKAimJob aim;
        aim.joint = &pose.model[look.headJoint];
        aim.jointCorrection = &correction;
        aim.target = look.target;
        aim.forward = look.forward;
        aim.up = look.up;
        aim.weight = look.weight;
        if (!aim.run()) continue;
        applyCorrection(pose.blended, cast(int) look.headJoint, correction);

        LocalToModelJob l2m;
        l2m.skeleton = skeleton;
        l2m.input = pose.blended;
        l2m.output = pose.model;
        l2m.from = cast(int) look.headJoint;
        l2m.run();
    }
}

/// `palette[j] = model[remap[j]] * inverseBind[j]`; without a skin the palette is the model pose.
void skinPaletteSystem(W)(ref W world, ref const AnimAssets assets, ref PosePool pool) @trusted {
    foreach (e; world.query!AnimSkeleton()) {
        auto sk = world.getPtr!AnimSkeleton(e);
        auto pose = pool.get(sk.poseSlot);
        if (pose is null) continue;
        auto skin = assets.skins.get(sk.skin);
        if (skin is null) {
            foreach (i; 0 .. pose.model.length) pose.palette[i] = pose.model[i];
            continue;
        }
        immutable n = skin.remap.length < pose.palette.length ? skin.remap.length : pose.palette.length;
        foreach (j; 0 .. n) {
            immutable joint = skin.remap[j];
            if (joint < pose.model.length) pose.palette[j] = pose.model[joint] * skin.inverseBinds[j];
        }
    }
}

version (unittest) {
    import core.memory : GC;
    import engine.animation.testing : fixtureDir, near;
    import engine.ecs.world : World;

    alias AnimWorld = World!(AnimSkeleton, AnimPlayback, AnimBlend2, AnimAdditive, AnimLookAt);
}

unittest {
    AnimAssets assets;
    PosePool pool;
    AnimWorld world;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtureDir ~ "pab/skeleton.ozz", err);
    auto walk = loadAnimationFile(assets.animations, fixtureDir ~ "pab/walk.ozz", err);
    auto jog = loadAnimationFile(assets.animations, fixtureDir ~ "pab/jog.ozz", err);
    auto skeleton = assets.skeletons.get(sk);
    assert(skeleton !is null && !walk.isNull && !jog.isNull, err);

    // One character playing walk, one blending walk/jog, one playing nothing.
    immutable e0 = world.spawn();
    world.set(e0, AnimSkeleton(sk, pool.acquire(skeleton.numJoints)));
    world.set(e0, AnimPlayback(walk, 0.0f, 1.0f, true));
    immutable e1 = world.spawn();
    world.set(e1, AnimSkeleton(sk, pool.acquire(skeleton.numJoints)));
    world.set(e1, AnimBlend2(walk, jog, 0.5f));
    immutable e2 = world.spawn();
    world.set(e2, AnimSkeleton(sk, pool.acquire(skeleton.numJoints)));

    void frame(float dt) {
        advancePlaybackSystem(world, assets, dt);
        sampleSystem(world, assets, pool);
        blendSystem(world, assets, pool);
        localToModelSystem(world, assets, pool);
        lookAtSystem(world, assets, pool);
        skinPaletteSystem(world, assets, pool);
    }

    foreach (i; 0 .. 30) frame(1.0f / 60);
    assert(near(world.get!AnimPlayback(e0).time, 0.5f, 1e-4f));

    // The first character's model pose equals a direct evaluation of the same clip and time.
    auto p0 = pool.get(world.get!AnimSkeleton(e0).poseSlot);
    {
        auto clip = assets.animations.get(walk);
        auto ctx = SamplingContext(skeleton.numJoints);
        auto local = new SoaTransform[skeleton.numSoaJoints];
        auto model = new Float4x4[skeleton.numJoints];
        SamplingJob sj;
        sj.ratio = world.get!AnimPlayback(e0).time / clip.duration;
        sj.animation = clip;
        sj.context = &ctx;
        sj.output = local;
        assert(sj.run());
        LocalToModelJob lj;
        lj.skeleton = skeleton;
        lj.input = local;
        lj.output = model;
        assert(lj.run());
        foreach (j; 0 .. skeleton.numJoints)
            foreach (c; 0 .. 4) foreach (r; 0 .. 4)
                assert(near(p0.model[j].cols[c][r], model[j].cols[c][r], 1e-4f));
    }
    // Blended character differs from the pure one; the idle one stays on the rest pose.
    auto p1 = pool.get(world.get!AnimSkeleton(e1).poseSlot);
    assert(p1.model != p0.model);
    auto p2 = pool.get(world.get!AnimSkeleton(e2).poseSlot);
    auto restModel = new Float4x4[skeleton.numJoints];
    LocalToModelJob rj;
    rj.skeleton = skeleton;
    rj.input = skeleton.restPoses;
    rj.output = restModel;
    assert(rj.run());
    foreach (j; 0 .. skeleton.numJoints) assert(near(p2.model[j].cols[3].y, restModel[j].cols[3].y, 1e-4f));

    // Frame path allocates nothing.
    immutable before = GC.stats().usedSize;
    foreach (i; 0 .. 120) frame(1.0f / 60);
    assert(GC.stats().usedSize == before);
}

unittest {
    // Non-looping playback clamps at the end; looping wraps; negative speed wraps backwards.
    AnimAssets assets;
    AnimWorld world;
    string err;
    auto walk = loadAnimationFile(assets.animations, fixtureDir ~ "pab/walk.ozz", err);
    immutable dur = assets.animations.get(walk).duration;
    immutable a = world.spawn();
    world.set(a, AnimPlayback(walk, 0, 1, false));
    immutable b = world.spawn();
    world.set(b, AnimPlayback(walk, 0, 1, true));
    immutable c = world.spawn();
    world.set(c, AnimPlayback(walk, 0.1f, -1, true));
    advancePlaybackSystem(world, assets, dur * 1.25f);
    assert(world.get!AnimPlayback(a).time == dur);
    assert(near(world.get!AnimPlayback(b).time, dur * 0.25f, 1e-4f));
    assert(world.get!AnimPlayback(c).time >= 0 && world.get!AnimPlayback(c).time < dur);
}

unittest {
    // Look-at: after the system runs, the head's forward axis points at the target.
    import engine.animation.math.matrix : translationOf, transformVector;
    AnimAssets assets;
    PosePool pool;
    AnimWorld world;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtureDir ~ "pab/skeleton.ozz", err);
    auto skeleton = assets.skeletons.get(sk);
    auto walk = loadAnimationFile(assets.animations, fixtureDir ~ "pab/walk.ozz", err);
    immutable head = skeleton.numJoints / 2;
    immutable e = world.spawn();
    world.set(e, AnimSkeleton(sk, pool.acquire(skeleton.numJoints)));
    world.set(e, AnimPlayback(walk, 0.2f, 1, true));
    world.set(e, AnimLookAt(cast(uint) head, Vec3(3, 4, 5), 1, Vec3(0, 0, 1), Vec3(0, 1, 0)));
    sampleSystem(world, assets, pool);
    blendSystem(world, assets, pool);
    localToModelSystem(world, assets, pool);
    lookAtSystem(world, assets, pool);
    auto pose = pool.get(world.get!AnimSkeleton(e).poseSlot);
    immutable m = pose.model[head];
    immutable fwd = transformVector(m, Vec3(0, 0, 1));
    immutable pos = translationOf(m);
    immutable d = Vec3(3 - pos.x, 4 - pos.y, 5 - pos.z);
    import std.math : sqrt;
    immutable dl = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    immutable fl = sqrt(fwd.x * fwd.x + fwd.y * fwd.y + fwd.z * fwd.z);
    immutable cosA = (fwd.x * d.x + fwd.y * d.y + fwd.z * d.z) / (dl * fl);
    assert(cosA > 0.999f, "head does not face the target");
}

unittest {
    // Skin palette: model * inverseBind; an inverse bind equal to inverse(model rest) at rest pose
    // gives the identity palette.
    import engine.animation.math.matrix : invert;
    AnimAssets assets;
    PosePool pool;
    AnimWorld world;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtureDir ~ "pab/skeleton.ozz", err);
    auto skeleton = assets.skeletons.get(sk);
    auto restModel = new Float4x4[skeleton.numJoints];
    LocalToModelJob rj;
    rj.skeleton = skeleton;
    rj.input = skeleton.restPoses;
    rj.output = restModel;
    assert(rj.run());
    SkinBinding binding;
    binding.skeleton = sk;
    foreach (j; 0 .. skeleton.numJoints) {
        bool ok;
        binding.remap ~= cast(uint) j;
        binding.inverseBinds ~= invert(restModel[j], ok);
    }
    auto skin = assets.skins.add(binding);
    immutable e = world.spawn();
    world.set(e, AnimSkeleton(sk, pool.acquire(skeleton.numJoints), skin));
    blendSystem(world, assets, pool);   // no clip: output = rest pose
    localToModelSystem(world, assets, pool);
    skinPaletteSystem(world, assets, pool);
    auto pose = pool.get(world.get!AnimSkeleton(e).poseSlot);
    foreach (j; 0 .. skeleton.numJoints)
        foreach (c; 0 .. 4) foreach (r; 0 .. 4)
            assert(near(pose.palette[j].cols[c][r], c == r ? 1.0f : 0.0f, 1e-3f));
}
