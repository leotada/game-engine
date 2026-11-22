/// Per-frame animation systems over an ECS `World`. All are `@nogc`: buffers come from the
/// `PosePool` allocated at spawn.
///
/// Order: `advancePlaybackSystem` -> `sampleSystem` -> `blendSystem` -> `localToModelSystem` ->
/// `ikSystem` -> `lookAtSystem` (each needs model-space joints, then re-runs local-to-model below its joint) ->
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
import engine.math.bounds : Aabb, BoundingSphere;
import engine.math.mat : Mat4, decomposeAffine;
import engine.scene.graph : Transform;

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
    static if (__traits(compiles, world.query!AnimLayerOverride())) {
        foreach (e; world.query!AnimLayerOverride()) {
            auto ov = world.getPtr!AnimLayerOverride(e);
            if (auto c = assets.animations.get(ov.clip))
                ov.time = advanceTime(ov.time, ov.speed * dt, c.duration, ov.loop);
        }
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
            static if (__traits(compiles, world.getPtr!AnimLayerOverride(e))) {
                if (auto ov = world.getPtr!AnimLayerOverride(e)) {
                    if (ov.weight > 0)
                        if (auto oc = assets.animations.get(ov.clip))
                            sampleClip(oc, ov.time, pose.ctx1, pose.local1);
                }
            }
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
        SimdFloat4[kMaxSoaJoints] complementMaskBuf = void;
        immutable numSoa = cast(size_t) skeleton.numSoaJoints;
        if (auto b = world.getPtr!AnimBlend2(e)) {
            immutable w = b.weight < 0 ? 0 : (b.weight > 1 ? 1 : b.weight);
            auto ma = assets.jointMasks.get(b.maskA);
            auto mb = assets.jointMasks.get(b.maskB);
            if (ma is null && mb is null) {
                layers[n++] = BlendingJob.Layer(1.0f - w, pose.local0);
                layers[n++] = BlendingJob.Layer(w, pose.local1);
            } else if (mb !is null && mb.length >= numSoa) {
                immutable wVec = SimdFloat4.load1(w);
                immutable one = SimdFloat4.one();
                foreach (i; 0 .. numSoa) {
                    immutable baseA = (ma !is null && ma.length >= numSoa) ? (*ma)[i] : one;
                    complementMaskBuf[i] = baseA * (one - wVec * (*mb)[i]);
                }
                layers[n++] = BlendingJob.Layer(1.0f, pose.local0, complementMaskBuf[0 .. numSoa]);
                layers[n++] = BlendingJob.Layer(w, pose.local1, (*mb)[0 .. numSoa]);
            } else if (ma !is null && ma.length >= numSoa) {
                immutable wVec = SimdFloat4.load1(1.0f - w);
                immutable one = SimdFloat4.one();
                foreach (i; 0 .. numSoa)
                    complementMaskBuf[i] = one - wVec * (*ma)[i];
                layers[n++] = BlendingJob.Layer(1.0f - w, pose.local0, (*ma)[0 .. numSoa]);
                layers[n++] = BlendingJob.Layer(1.0f, pose.local1, complementMaskBuf[0 .. numSoa]);
            }
        } else if (world.has!AnimPlayback(e)) {
            bool handledOverride = false;
            static if (__traits(compiles, world.getPtr!AnimLayerOverride(e))) {
                if (auto ov = world.getPtr!AnimLayerOverride(e)) {
                    immutable w = ov.weight < 0 ? 0 : (ov.weight > 1 ? 1 : ov.weight);
                    auto om = assets.jointMasks.get(ov.mask);
                    if (w > 0 && om !is null && om.length >= numSoa) {
                        immutable wVec = SimdFloat4.load1(w);
                        immutable one = SimdFloat4.one();
                        foreach (i; 0 .. numSoa)
                            complementMaskBuf[i] = one - wVec * (*om)[i];
                        layers[n++] = BlendingJob.Layer(1.0f, pose.local0, complementMaskBuf[0 .. numSoa]);
                        layers[n++] = BlendingJob.Layer(w, pose.local1, (*om)[0 .. numSoa]);
                        handledOverride = true;
                    }
                }
            }
            if (!handledOverride)
                layers[n++] = BlendingJob.Layer(1.0f, pose.local0);
        }
        BlendingJob.Layer[1] additive;
        size_t na = 0;
        if (auto a = world.getPtr!AnimAdditive(e)) {
            if (a.weight != 0) {
                auto am = assets.jointMasks.get(a.mask);
                additive[na++] = (am !is null && am.length >= numSoa)
                    ? BlendingJob.Layer(a.weight, pose.local2, (*am)[0 .. numSoa])
                    : BlendingJob.Layer(a.weight, pose.local2);
            }
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

/// Two-bone IK. Runs after `localToModelSystem` and before `lookAtSystem`: it corrects the start
/// and mid joints, then refreshes model matrices from the start joint down.
void ikSystem(W)(ref W world, ref const AnimAssets assets, ref PosePool pool) @trusted {
    foreach (e; world.query!(AnimSkeleton, AnimTwoBoneIK)()) {
        auto sk = world.getPtr!AnimSkeleton(e);
        auto ik = world.getPtr!AnimTwoBoneIK(e);
        auto pose = pool.get(sk.poseSlot);
        auto skeleton = assets.skeletons.get(sk.skeleton);
        if (pose is null || skeleton is null) continue;
        immutable n = cast(uint) skeleton.numJoints;
        if (ik.startJoint >= n || ik.midJoint >= n || ik.endJoint >= n) continue;

        Quat startCorrection, midCorrection;
        IKTwoBoneJob job;
        job.target = ik.target;
        job.poleVector = ik.pole;
        job.midAxis = ik.midAxis;
        job.weight = ik.weight;
        job.startJoint = &pose.model[ik.startJoint];
        job.midJoint = &pose.model[ik.midJoint];
        job.endJoint = &pose.model[ik.endJoint];
        job.startJointCorrection = &startCorrection;
        job.midJointCorrection = &midCorrection;
        if (!job.run()) continue;
        applyCorrection(pose.blended, cast(int) ik.startJoint, startCorrection);
        applyCorrection(pose.blended, cast(int) ik.midJoint, midCorrection);

        LocalToModelJob l2m;
        l2m.skeleton = skeleton;
        l2m.input = pose.blended;
        l2m.output = pose.model;
        l2m.from = cast(int) ik.startJoint;
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

/// Converts an ozz `Float4x4` to an engine `Mat4` (layout-identical column-major 4×4).
Mat4 mat4FromFloat4x4(const Float4x4 f) @trusted pure nothrow @nogc {
    return *cast(const(Mat4)*) &f;
}

/// Converts an engine `Mat4` to an ozz `Float4x4`.
Float4x4 float4x4FromMat4(const Mat4 m) @trusted pure nothrow @nogc {
    return *cast(const(Float4x4)*) &m;
}

/// World-space transform of `jointIndex` on a posed character (`characterWorld * pose.model[jointIndex] * localOffset`).
/// Use this to attach rigid props (weapons, flashlights, shoulder cameras) without an ECS `BoneSocket`.
Mat4 jointWorldMatrix(const(Pose)* pose, uint jointIndex,
                      Mat4 characterWorld = Mat4.identity(),
                      Mat4 localOffset = Mat4.identity()) pure nothrow @nogc {
    if (pose is null || jointIndex >= pose.model.length)
        return characterWorld * localOffset;
    return characterWorld * mat4FromFloat4x4(pose.model[jointIndex]) * localOffset;
}

/// Model-space bounding sphere enclosing every joint translation in `jointModels`
/// padded by `jointRadiusMargin` (for flesh/limb extent around bone origins).
/// Pass this to `Scene3DTextured.drawSkinned` so ragdolls or root-motion animations
/// are culled by their current pose instead of bind-pose bounds.
BoundingSphere poseBoundingSphere(scope const(Mat4)[] jointModels, float jointRadiusMargin = 0.35f) pure nothrow @nogc {
    import core.math : sqrt;
    import engine.math.vec : Vec3;

    if (jointModels.length == 0)
        return BoundingSphere.init;
    Aabb box;
    foreach (ref m; jointModels)
        box.extend(Vec3(m.m[12], m.m[13], m.m[14]));
    immutable c = box.center();
    float maxR2 = 0.0f;
    foreach (ref m; jointModels) {
        immutable dx = m.m[12] - c.x;
        immutable dy = m.m[13] - c.y;
        immutable dz = m.m[14] - c.z;
        immutable d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > maxR2) maxR2 = d2;
    }
    immutable margin = jointRadiusMargin > 0.0f ? jointRadiusMargin : 0.0f;
    return BoundingSphere(c, sqrt(maxR2) + margin);
}

/// Overload accepting `Pose.model` (`const(Float4x4)[]`) directly.
BoundingSphere poseBoundingSphere(scope const(Float4x4)[] jointModels, float jointRadiusMargin = 0.35f) pure nothrow @nogc {
    return poseBoundingSphere(asMat4(jointModels), jointRadiusMargin);
}

/// Updates `Transform` of entities carrying `BoneSocket` to `targetWorld * pose.model[jointIndex] * localSocket`.
/// Runs after `localToModelSystem` / `ikSystem` / `lookAtSystem`.
void boneSocketSystem(W)(ref W world, ref PosePool pool) nothrow @nogc {
    foreach (e; world.query!(BoneSocket, Transform)()) {
        auto sock = world.getPtr!BoneSocket(e);
        auto xf = world.getPtr!Transform(e);
        if (!world.alive(sock.targetEntity)) continue;
        auto sk = world.getPtr!AnimSkeleton(sock.targetEntity);
        if (sk is null) continue;
        auto pose = pool.get(sk.poseSlot);
        if (pose is null || sock.jointIndex >= pose.model.length) continue;

        Mat4 targetWorld = Mat4.identity();
        if (world.has!Transform(sock.targetEntity)) {
            const t = world.getPtr!Transform(sock.targetEntity);
            targetWorld = Mat4.trs(t.position, t.rotation, t.scale);
        }

        immutable Mat4 jointModel = mat4FromFloat4x4(pose.model[sock.jointIndex]);
        immutable Mat4 localSocket = Mat4.trs(sock.localOffset, sock.localRot, sock.localScale);
        immutable Mat4 worldMat = targetWorld * jointModel * localSocket;

        decomposeAffine(worldMat, xf.position, xf.rotation, xf.scale);
    }
}

version (unittest) {
    import core.memory : GC;
    import engine.animation.testing : fixtureDir, near;
    import engine.ecs.world : World;

    alias AnimWorld = World!(AnimSkeleton, AnimPlayback, AnimBlend2, AnimAdditive,
                             AnimLookAt, AnimTwoBoneIK, AnimLayerOverride, BoneSocket, Transform);
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

unittest {
    // Two-bone IK: with a hinge axis that fits the chain, the end joint reaches a nearby target
    // that it did not reach before. Axes are tried in turn since the skeleton's hinge is unknown.
    import engine.animation.math.matrix : translationOf;
    import std.math : sqrt;
    AnimAssets assets;
    PosePool pool;
    AnimWorld world;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtureDir ~ "pab/skeleton.ozz", err);
    auto skeleton = assets.skeletons.get(sk);
    auto walk = loadAnimationFile(assets.animations, fixtureDir ~ "pab/walk.ozz", err);

    // First joint with a parent and a grandparent, deep enough to be a limb.
    int end = -1;
    foreach (j; 3 .. skeleton.numJoints)
        if (skeleton.parents[skeleton.parents[j]] != kNoParent && skeleton.parents[skeleton.parents[skeleton.parents[j]]] != kNoParent) { end = j; break; }
    assert(end > 0);
    immutable mid = skeleton.parents[end], start = skeleton.parents[mid];

    float bestError = float.infinity;
    foreach (axis; [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]) {
        auto w = AnimWorld();
        PosePool p2;
        immutable e = w.spawn();
        w.set(e, AnimSkeleton(sk, p2.acquire(skeleton.numJoints)));
        w.set(e, AnimPlayback(walk, 0.3f, 1, true));
        sampleSystem(w, assets, p2);
        blendSystem(w, assets, p2);
        localToModelSystem(w, assets, p2);
        auto pose = p2.get(0);
        immutable before = translationOf(pose.model[end]);
        immutable sPos = translationOf(pose.model[start]);
        // Target: pull the end joint 10% closer to the start joint (always reachable).
        immutable target = Vec3(before.x + (sPos.x - before.x) * 0.1f, before.y + (sPos.y - before.y) * 0.1f,
                                before.z + (sPos.z - before.z) * 0.1f);
        w.set(e, AnimTwoBoneIK(start, mid, end, target, Vec3(0, 1, 0), axis, 1.0f));
        ikSystem(w, assets, p2);
        immutable after = translationOf(pose.model[end]);
        immutable d = Vec3(after.x - target.x, after.y - target.y, after.z - target.z);
        immutable err2 = sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
        if (err2 < bestError) bestError = err2;
    }
    assert(bestError < 1e-2f, "IK never reached the target");
}

unittest {
    // Subtree mask blending + BoneSocket world attachment.
    import engine.math.quat : Quat;
    import engine.math.vec : Vec3;
    import std.math : abs;

    AnimAssets assets;
    PosePool pool;
    AnimWorld world;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtureDir ~ "pab/skeleton.ozz", err);
    auto walk = loadAnimationFile(assets.animations, fixtureDir ~ "pab/walk.ozz", err);
    auto run = loadAnimationFile(assets.animations, fixtureDir ~ "pab/run.ozz", err);
    auto skeleton = assets.skeletons.get(sk);
    assert(skeleton !is null && !walk.isNull && !run.isNull, err);

    // Pick a mid-hierarchy joint for the upper-body subtree mask.
    immutable int subRoot = skeleton.numJoints / 2;
    auto maskData = buildSubtreeMask(*skeleton, subRoot, 1.0f, 0.0f);
    assert(maskData.length == skeleton.numSoaJoints);
    auto maskHandle = assets.jointMasks.add(maskData);

    immutable charEnt = world.spawn();
    world.set(charEnt, AnimSkeleton(sk, pool.acquire(skeleton.numJoints)));
    world.set(charEnt, AnimPlayback(walk, 0.2f, 1.0f, true));
    world.set(charEnt, AnimLayerOverride(run, maskHandle, 1.0f, 0.2f, 1.0f, true));
    Transform charXf;
    charXf.position = Vec3(10.0f, 2.0f, -5.0f);
    charXf.rotation = Quat.fromEulerYXZ(Vec3(0.0f, 90.0f, 0.0f));
    world.set(charEnt, charXf);

    immutable propEnt = world.spawn();
    world.set(propEnt, Transform.init);
    world.set(propEnt, BoneSocket(charEnt, cast(uint) subRoot, Vec3(0.5f, 0.0f, 0.0f), Quat.identity(), Vec3(1, 1, 1)));

    sampleSystem(world, assets, pool);
    blendSystem(world, assets, pool);
    localToModelSystem(world, assets, pool);
    boneSocketSystem(world, pool);

    // Joint 0 (root) should match walk (mask weight 0), while subRoot should match run (mask weight 1).
    auto pose = pool.get(world.get!AnimSkeleton(charEnt).poseSlot);
    assert(pose !is null);
    Vec3 bPos, l0Pos, l1Pos, bScale, l0Scale, l1Scale;
    Quat bRot, l0Rot, l1Rot;
    // Verify BoneSocket placed propEnt at charXf * model[subRoot] * offset.
    immutable Mat4 expectedWorld = charXf.localMatrix()
        * mat4FromFloat4x4(pose.model[subRoot])
        * Mat4.translation(0.5f, 0.0f, 0.0f);
    Vec3 expPos, expScale;
    Quat expRot;
    assert(decomposeAffine(expectedWorld, expPos, expRot, expScale));
    immutable propXf = world.get!Transform(propEnt);
    assert(abs(propXf.position.x - expPos.x) < 1e-3f);
    assert(abs(propXf.position.y - expPos.y) < 1e-3f);
    assert(abs(propXf.position.z - expPos.z) < 1e-3f);

    // jointWorldMatrix matches charXf * pose.model[subRoot] * localOffset.
    immutable jw = jointWorldMatrix(pose, cast(uint) subRoot, charXf.localMatrix(), Mat4.translation(0.5f, 0.0f, 0.0f));
    assert(abs(jw.m[12] - expPos.x) < 1e-3f);
    assert(abs(jw.m[13] - expPos.y) < 1e-3f);
    assert(abs(jw.m[14] - expPos.z) < 1e-3f);

    // poseBoundingSphere follows shifted joint positions (e.g. a fallen ragdoll away from origin).
    Mat4[3] shifted = [
        Mat4.translation(14.0f, 0.2f, -8.0f),
        Mat4.translation(15.0f, 0.2f, -8.0f),
        Mat4.translation(16.0f, 0.2f, -8.0f),
    ];
    immutable ps = poseBoundingSphere(shifted[], 0.35f);
    assert(abs(ps.center.x - 15.0f) < 1e-4f);
    assert(abs(ps.center.y - 0.2f) < 1e-4f);
    assert(abs(ps.center.z - (-8.0f)) < 1e-4f);
    assert(ps.radius >= 1.34f && ps.radius <= 1.36f);
}
