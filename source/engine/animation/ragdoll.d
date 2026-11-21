/// Bidirectional ragdoll <-> skeleton bridge connecting `engine.animation` (`ozz`) to `engine.physics` (Box3D).
///
/// Supports:
/// - `animated`: kinematic rigid bodies follow the animated skeleton and track linear/angular velocities.
/// - `ragdoll`: dynamic rigid bodies simulate under physics and reconstruct `Pose.ragdollPose` + `Pose.model`.
/// - `blendingToAnim`: crossfades `Pose.ragdollPose` into the active get-up animation clip via `BlendingJob`.
module engine.animation.ragdoll;

import bindings.box3d : b3BodyId, b3JointId, b3Body_IsValidD, b3Body_SetTransformD;
import core.stdc.math : atan2f;
import engine.animation.blending : BlendingJob;
import engine.animation.ecs.assets : AnimAssets, AnimationHandle, AssetStore, RagdollAssetHandle,
    RagdollAssetTag, SkeletonHandle;
import engine.animation.ecs.components : AnimPlayback, AnimSkeleton;
import engine.animation.ecs.pose_pool : Pose, PosePool;
import engine.animation.ecs.systems : float4x4FromMat4, mat4FromFloat4x4;
import engine.animation.local_to_model : LocalToModelJob;
import engine.animation.math.matrix : invert;
import engine.animation.math.simd : Float4x4, SimdFloat4;
import engine.animation.math.soa : SoaFloat3, SoaQuaternion, SoaTransform;
import engine.animation.skeleton : kNoParent, Skeleton;
import engine.core.pod : isPod;
import engine.ecs.store : EntityId;
import engine.math.mat : decomposeAffine, Mat4;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.physics.body : BodyDesc, CollisionFilter, createBoxBody, createCapsuleBody,
    createSphereBody, destroyBody, isBodyValid, noPhysicsEntity, PhysicsBodyType,
    setBodyAwake, setBodyType, setLinearVelocity, setAngularVelocity;
import engine.physics.convert : readBodyTransform, toB3Pos, toB3Quat, writeBodyTransform;
import engine.physics.joints : createSphericalJoint, destroyJoint, isJointValid, SphericalJointConfig;
import engine.physics.world : PhysicsWorld;
import engine.reflect.attrs : component, export_;
import engine.scene.graph : Transform;

@safe:

enum uint kMaxRagdollBones = 24;

/// Simulation mode for a ragdoll-enabled character.
enum RagdollState : ubyte {
    animated = 0,
    ragdoll = 1,
    blendingToAnim = 2,
}

/// Collision shape primitive for a single ragdoll bone.
enum RagdollShapeKind : ubyte {
    capsule = 0,
    box = 1,
    sphere = 2,
}

/// Static definition of a single physics bone mapped to a skeleton joint.
struct RagdollBoneDef {
    int jointIndex = -1;
    /// Index into `RagdollAsset.bones` for the parent ragdoll bone (-1 = root bone, e.g. pelvis).
    int parentBoneIndex = -1;
    RagdollShapeKind shape = RagdollShapeKind.capsule;
    /// Shape dimensions: capsule `(radius, halfHeight, radius)`, box `(hx, hy, hz)`, sphere `(radius, _, _)`.
    Vec3 halfExtents = Vec3(0.08f, 0.2f, 0.08f);
    float mass = 1.0f;
    /// Offset from the joint's model transform to the rigid body center.
    Vec3 bindLocalOffset = Vec3(0, 0, 0);
    Quat bindLocalRot = Quat.init;
    /// Anchor offset in the bone's rigid body local space where the spherical joint attaches to `parentBoneIndex`.
    Vec3 jointAnchorLocal = Vec3(0, 0, 0);
    /// Cone/twist reference axis in world/bind orientation (defaults to -Y).
    Vec3 coneAxisLocal = Vec3(0, -1, 0);
    SphericalJointConfig jointConfig = SphericalJointConfig.init;
}

/// Reusable POD ragdoll rig definition shared across characters with the same skeleton.
struct RagdollAsset {
    SkeletonHandle skeleton;
    uint boneCount = 0;
    uint pelvisBoneIndex = 0;
    Vec3 pelvisForwardAxis = Vec3(0, 0, 1);
    Vec3 pelvisUpAxis = Vec3(0, 1, 0);
    AnimationHandle getUpFaceUpClip;
    AnimationHandle getUpFaceDownClip;
    /// Negative Box3D filter group index preventing bones of the same ragdoll from colliding.
    int collisionGroupIndex = -1;
    RagdollBoneDef[kMaxRagdollBones] bones;
}

alias RagdollAssetStore = AssetStore!(RagdollAsset, RagdollAssetTag);

/// Per-entity runtime state for the bidirectional skeleton <-> ragdoll bridge.
@component struct RagdollComponent {
    RagdollAssetHandle asset;
    @export_ RagdollState state = RagdollState.animated;
    uint boneCount = 0;
    b3BodyId[kMaxRagdollBones] bodies;
    b3JointId[kMaxRagdollBones] joints;
    Vec3[kMaxRagdollBones] prevBodyPos;
    Quat[kMaxRagdollBones] prevBodyRot;
    bool hasPrevTransforms = false;
    float blendTimer = 0.0f;
    @export_ float blendDuration = 0.35f;
    @export_ bool faceUp = true;
}

static assert(isPod!RagdollBoneDef);
static assert(isPod!RagdollAsset);
static assert(isPod!RagdollComponent);

// ---- SoA <-> AoS joint transform helpers ----

/// Reads joint `jointIndex` from a `SoaTransform[]` pose.
void getSoaJointTransform(const(SoaTransform)[] soaPose, int jointIndex,
                          out Vec3 translation, out Quat rotation, out Vec3 scale) pure nothrow @nogc {
    if (jointIndex < 0 || cast(size_t)(jointIndex >> 2) >= soaPose.length) {
        translation = Vec3(0, 0, 0);
        rotation = Quat.identity();
        scale = Vec3(1, 1, 1);
        return;
    }
    immutable size_t blk = cast(size_t)(jointIndex >> 2);
    immutable int lane = jointIndex & 3;
    const t = &soaPose[blk];
    translation = Vec3(t.translation.x[lane], t.translation.y[lane], t.translation.z[lane]);
    rotation = Quat(t.rotation.x[lane], t.rotation.y[lane], t.rotation.z[lane], t.rotation.w[lane]);
    scale = Vec3(t.scale.x[lane], t.scale.y[lane], t.scale.z[lane]);
}

/// Writes joint `jointIndex` into a `SoaTransform[]` pose.
void setSoaJointTransform(SoaTransform[] soaPose, int jointIndex,
                          Vec3 translation, Quat rotation, Vec3 scale = Vec3(1, 1, 1)) pure nothrow @nogc {
    if (jointIndex < 0 || cast(size_t)(jointIndex >> 2) >= soaPose.length)
        return;
    immutable size_t blk = cast(size_t)(jointIndex >> 2);
    immutable int lane = jointIndex & 3;
    auto t = &soaPose[blk];

    setLane(t.translation.x, lane, translation.x);
    setLane(t.translation.y, lane, translation.y);
    setLane(t.translation.z, lane, translation.z);

    setLane(t.rotation.x, lane, rotation.x);
    setLane(t.rotation.y, lane, rotation.y);
    setLane(t.rotation.z, lane, rotation.z);
    setLane(t.rotation.w, lane, rotation.w);

    setLane(t.scale.x, lane, scale.x);
    setLane(t.scale.y, lane, scale.y);
    setLane(t.scale.z, lane, scale.z);
}

private void setLane(ref SimdFloat4 v, int lane, float val) pure nothrow @nogc {
    float[4] a = [v.x, v.y, v.z, v.w];
    a[lane] = val;
    v = SimdFloat4.load(a[0], a[1], a[2], a[3]);
}

/// Reconstructs parent-local `SoaTransform[]` from model-space `Float4x4[]` matrices.
/// Inverse of `LocalToModelJob`: `local[j] = inverse(model[parent[j]]) * model[j]`.
bool modelToLocalSoa(ref const Skeleton skeleton, const(Float4x4)[] modelMatrices,
                     SoaTransform[] outLocal) pure nothrow @nogc {
    immutable int n = skeleton.numJoints;
    if (n <= 0 || modelMatrices.length < n || outLocal.length < skeleton.numSoaJoints)
        return false;

    foreach (j; 0 .. n) {
        immutable int p = skeleton.parents[j];
        Float4x4 localF;
        if (p == kNoParent) {
            localF = modelMatrices[j];
        } else {
            bool ok;
            immutable invP = invert(modelMatrices[p], ok);
            localF = ok ? (invP * modelMatrices[j]) : modelMatrices[j];
        }
        Vec3 pos, scl;
        Quat rot;
        decomposeAffine(mat4FromFloat4x4(localF), pos, rot, scl);
        setSoaJointTransform(outLocal, j, pos, rot, scl);
    }
    return true;
}

// ---- Lifecycle & state transitions ----

/// Spawns Box3D bodies and spherical constraints for `asset` in `RagdollState.animated` (kinematic).
bool spawnRagdollBodies(ref PhysicsWorld physWorld,
                        ref const RagdollAsset asset,
                        ref const Skeleton skeleton,
                        const(Float4x4)[] modelPose,
                        Mat4 entityWorld,
                        ref RagdollComponent comp,
                        EntityId entityId = noPhysicsEntity) nothrow @nogc {
    destroyRagdollBodies(comp);
    if (!physWorld.valid() || asset.boneCount == 0 || asset.boneCount > kMaxRagdollBones)
        return false;
    if (modelPose.length < skeleton.numJoints)
        return false;

    comp.boneCount = asset.boneCount;
    comp.state = RagdollState.animated;
    comp.hasPrevTransforms = false;

    CollisionFilter filter;
    filter.groupIndex = asset.collisionGroupIndex;

    foreach (i; 0 .. asset.boneCount) {
        const b = &asset.bones[i];
        if (b.jointIndex < 0 || b.jointIndex >= skeleton.numJoints) {
            destroyRagdollBodies(comp);
            return false;
        }
        immutable Mat4 bodyMat = computeBoneWorldMatrix(entityWorld, modelPose[b.jointIndex], *b);
        Vec3 pos, scl;
        Quat rot;
        decomposeAffine(bodyMat, pos, rot, scl);

        BodyDesc desc;
        desc.type = PhysicsBodyType.kinematic;
        desc.position = pos;
        desc.rotation = rot;
        desc.density = b.mass > 0.0f ? b.mass : 1.0f;
        desc.entityId = entityId;
        desc.filter = filter;
        desc.linearDamping = 0.05f;
        desc.angularDamping = 0.05f;

        b3BodyId bid;
        final switch (b.shape) {
            case RagdollShapeKind.capsule:
                bid = createCapsuleBody(physWorld, desc, b.halfExtents.y * 2.0f, b.halfExtents.x);
                break;
            case RagdollShapeKind.box:
                bid = createBoxBody(physWorld, desc, b.halfExtents);
                break;
            case RagdollShapeKind.sphere:
                bid = createSphereBody(physWorld, desc, b.halfExtents.x);
                break;
        }
        if (!isBodyValid(bid)) {
            destroyRagdollBodies(comp);
            return false;
        }
        comp.bodies[i] = bid;
        comp.prevBodyPos[i] = pos;
        comp.prevBodyRot[i] = rot;
    }

    // Connect child bones to parent bones via spherical joints.
    foreach (i; 0 .. asset.boneCount) {
        const b = &asset.bones[i];
        if (b.parentBoneIndex < 0 || b.parentBoneIndex >= cast(int) asset.boneCount)
            continue;
        immutable parentBody = comp.bodies[b.parentBoneIndex];
        immutable childBody = comp.bodies[i];
        immutable childXf = readBodyTransform(childBody);
        immutable Vec3 worldAnchor = childXf.position + childXf.rotation.rotate(b.jointAnchorLocal);
        immutable Vec3 worldConeAxis = childXf.rotation.rotate(b.coneAxisLocal);
        comp.joints[i] = createSphericalJoint(
            physWorld, parentBody, childBody, worldAnchor, worldConeAxis, b.jointConfig);
    }

    comp.hasPrevTransforms = true;
    return true;
}

/// Destroys all Box3D joints and bodies owned by `comp`.
void destroyRagdollBodies(ref RagdollComponent comp) nothrow @nogc {
    foreach (i; 0 .. comp.boneCount) {
        if (isJointValid(comp.joints[i])) {
            destroyJoint(comp.joints[i], false);
            comp.joints[i] = b3JointId.init;
        }
    }
    foreach (i; 0 .. comp.boneCount) {
        if (isBodyValid(comp.bodies[i])) {
            destroyBody(comp.bodies[i]);
            comp.bodies[i] = b3BodyId.init;
        }
    }
    comp.boneCount = 0;
    comp.hasPrevTransforms = false;
}

/// Switches `comp` from `animated` (or `blendingToAnim`) to dynamic `ragdoll` simulation,
/// preserving estimated linear/angular velocities from the previous kinematic step.
void activateRagdoll(ref RagdollComponent comp,
                     Vec3 extraLinearImpulse = Vec3(0, 0, 0),
                     float dt = 1.0f / 60.0f) nothrow @nogc {
    immutable float invDt = dt > 1e-5f ? 1.0f / dt : 60.0f;
    foreach (i; 0 .. comp.boneCount) {
        immutable bid = comp.bodies[i];
        if (!isBodyValid(bid)) continue;
        setBodyType(bid, PhysicsBodyType.dynamic);
        setBodyAwake(bid, true);

        if (comp.hasPrevTransforms) {
            immutable cur = readBodyTransform(bid);
            immutable Vec3 linVel = (cur.position - comp.prevBodyPos[i]) * invDt + extraLinearImpulse;
            setLinearVelocity(bid, linVel);
            immutable Vec3 angVel = angularVelocityBetween(comp.prevBodyRot[i], cur.rotation, invDt);
            setAngularVelocity(bid, angVel);
        } else if (extraLinearImpulse.lengthSquared() > 0.0f) {
            setLinearVelocity(bid, extraLinearImpulse);
        }
    }
    comp.state = RagdollState.ragdoll;
}

/// Transitions from `ragdoll` to `blendingToAnim`:
/// 1. Snapshots the current ragdoll pose into `pose.ragdollPose`.
/// 2. Aligns `entityTransform` position & yaw to the ragdoll pelvis and detects `faceUp` vs face-down.
/// 3. Switches bodies back to kinematic and returns the selected get-up clip handle.
AnimationHandle beginRagdollGetUp(ref const RagdollAsset asset,
                                  ref const Skeleton skeleton,
                                  ref RagdollComponent comp,
                                  ref Pose pose,
                                  ref Transform entityTransform,
                                  float blendDuration = 0.35f) nothrow @nogc {
    // Reconstruct ragdoll local pose if not already populated this frame.
    immutable Mat4 entityWorld = Mat4.trs(entityTransform.position, entityTransform.rotation, entityTransform.scale);
    syncPhysicsToSkeleton(asset, skeleton, entityWorld, comp, pose, 0.0f);

    if (asset.pelvisBoneIndex < comp.boneCount && isBodyValid(comp.bodies[asset.pelvisBoneIndex])) {
        immutable pelvisXf = readBodyTransform(comp.bodies[asset.pelvisBoneIndex]);
        entityTransform.position = pelvisXf.position;

        // Determine face-up vs face-down from pelvis up-axis dot world +Y.
        immutable Vec3 worldPelvisUp = pelvisXf.rotation.rotate(asset.pelvisUpAxis);
        comp.faceUp = worldPelvisUp.y >= 0.0f;

        // Align entity yaw to pelvis forward (or negated forward when face-up on back).
        Vec3 fwd = pelvisXf.rotation.rotate(asset.pelvisForwardAxis);
        if (comp.faceUp) fwd = fwd * -1.0f;
        immutable float yawRad = atan2f(fwd.x, fwd.z);
        entityTransform.rotation = Quat.fromAxisAngle(Vec3(0, 1, 0), yawRad);
    }

    foreach (i; 0 .. comp.boneCount) {
        if (isBodyValid(comp.bodies[i]))
            setBodyType(comp.bodies[i], PhysicsBodyType.kinematic);
    }

    comp.state = RagdollState.blendingToAnim;
    comp.blendDuration = blendDuration > 1e-4f ? blendDuration : 0.35f;
    comp.blendTimer = 0.0f;

    return comp.faceUp ? asset.getUpFaceUpClip : asset.getUpFaceDownClip;
}

// ---- Bidirectional synchronization ----

/// **Skeleton -> Physics:** moves kinematic ragdoll bodies to follow `modelPose`.
void syncSkeletonToPhysics(ref const RagdollAsset asset,
                           const(Float4x4)[] modelPose,
                           Mat4 entityWorld,
                           ref RagdollComponent comp,
                           float dt) nothrow @nogc {
    immutable uint n = comp.boneCount < asset.boneCount ? comp.boneCount : asset.boneCount;
    foreach (i; 0 .. n) {
        immutable bid = comp.bodies[i];
        if (!isBodyValid(bid)) continue;
        const b = &asset.bones[i];
        if (b.jointIndex < 0 || b.jointIndex >= modelPose.length) continue;

        if (comp.hasPrevTransforms) {
            immutable prev = readBodyTransform(bid);
            comp.prevBodyPos[i] = prev.position;
            comp.prevBodyRot[i] = prev.rotation;
        }

        immutable Mat4 bodyWorld = computeBoneWorldMatrix(entityWorld, modelPose[b.jointIndex], *b);
        Vec3 pos, scl;
        Quat rot;
        decomposeAffine(bodyWorld, pos, rot, scl);
        writeBodyTransform(bid, pos, rot);

        if (!comp.hasPrevTransforms) {
            comp.prevBodyPos[i] = pos;
            comp.prevBodyRot[i] = rot;
        }
    }
    comp.hasPrevTransforms = true;
}

/// **Physics -> Skeleton:** reads dynamic ragdoll body transforms into `pose.model`,
/// reconstructs parent-local `pose.ragdollPose`, and updates `pose.blended` / `pose.model`.
void syncPhysicsToSkeleton(ref const RagdollAsset asset,
                           ref const Skeleton skeleton,
                           Mat4 entityWorld,
                           ref RagdollComponent comp,
                           ref Pose pose,
                           float dt) @trusted nothrow @nogc {
    immutable int numJoints = skeleton.numJoints;
    if (numJoints <= 0 || pose.model.length < numJoints || pose.ragdollPose.length < skeleton.numSoaJoints)
        return;

    immutable Mat4 invEntityWorld = entityWorld.inverse();
    immutable uint n = comp.boneCount < asset.boneCount ? comp.boneCount : asset.boneCount;

    // Seed ragdollPose from current blended pose for joints without physics bodies (fingers, toes, etc.).
    foreach (i; 0 .. skeleton.numSoaJoints)
        pose.ragdollPose[i] = pose.blended[i];

    // Write physics-driven joint model matrices for mapped bones, then rebuild local SoA transforms.
    foreach (i; 0 .. n) {
        immutable bid = comp.bodies[i];
        if (!isBodyValid(bid)) continue;
        const b = &asset.bones[i];
        if (b.jointIndex < 0 || b.jointIndex >= numJoints) continue;

        immutable bodyXf = readBodyTransform(bid);
        immutable Mat4 bodyWorld = Mat4.trs(bodyXf.position, bodyXf.rotation, Vec3(1, 1, 1));
        immutable Mat4 bindLocal = Mat4.trs(b.bindLocalOffset, b.bindLocalRot, Vec3(1, 1, 1));
        immutable Mat4 jointModel = invEntityWorld * bodyWorld * bindLocal.inverse();
        pose.model[b.jointIndex] = float4x4FromMat4(jointModel);
    }

    // Recompute child joints that do not have physics bodies from their parent model matrices.
    bool[1024] isPhysicsJoint;
    foreach (i; 0 .. n) {
        immutable j = asset.bones[i].jointIndex;
        if (j >= 0 && j < 1024) isPhysicsJoint[j] = true;
    }

    modelToLocalSoa(skeleton, pose.model, pose.ragdollPose);

    // Preserve animated local pose on unmapped leaf/child joints (e.g. hands/head if unmapped).
    foreach (j; 0 .. numJoints) {
        if (!isPhysicsJoint[j]) {
            Vec3 t, s;
            Quat r;
            getSoaJointTransform(pose.blended, j, t, r, s);
            setSoaJointTransform(pose.ragdollPose, j, t, r, s);
        }
    }

    // Recompute clean model pose for all joints (including unmapped descendants).
    foreach (i; 0 .. skeleton.numSoaJoints)
        pose.blended[i] = pose.ragdollPose[i];

    LocalToModelJob l2m;
    l2m.skeleton = &skeleton;
    l2m.input = pose.blended;
    l2m.output = pose.model;
    l2m.run();
}

/// Per-frame ECS system driving `RagdollComponent` in `animated`, `ragdoll`, and `blendingToAnim` states.
/// Runs after `blendSystem` + `localToModelSystem` (and before `skinPaletteSystem`).
void ragdollSystem(W)(ref W world,
                      ref const RagdollAssetStore ragdollAssets,
                      ref const AnimAssets animAssets,
                      ref PosePool pool,
                      float dt) @trusted nothrow @nogc {
    foreach (e; world.query!(AnimSkeleton, RagdollComponent)()) {
        auto sk = world.getPtr!AnimSkeleton(e);
        auto rc = world.getPtr!RagdollComponent(e);
        auto pose = pool.get(sk.poseSlot);
        auto skeleton = animAssets.skeletons.get(sk.skeleton);
        auto ragAsset = ragdollAssets.get(rc.asset);
        if (pose is null || skeleton is null || ragAsset is null)
            continue;

        Mat4 entityWorld = Mat4.identity();
        if (world.has!Transform(e)) {
            const t = world.getPtr!Transform(e);
            entityWorld = Mat4.trs(t.position, t.rotation, t.scale);
        }

        final switch (rc.state) {
            case RagdollState.animated:
                syncSkeletonToPhysics(*ragAsset, pose.model, entityWorld, *rc, dt);
                break;

            case RagdollState.ragdoll:
                syncPhysicsToSkeleton(*ragAsset, *skeleton, entityWorld, *rc, *pose, dt);
                break;

            case RagdollState.blendingToAnim:
                rc.blendTimer += dt;
                float t = rc.blendDuration > 1e-4f ? (rc.blendTimer / rc.blendDuration) : 1.0f;
                if (t >= 1.0f) {
                    t = 1.0f;
                    rc.state = RagdollState.animated;
                }
                BlendingJob.Layer[2] layers = [
                    BlendingJob.Layer(1.0f - t, pose.ragdollPose),
                    BlendingJob.Layer(t, pose.blended),
                ];
                // Copy pose.blended into local0 temporarily? No — BlendingJob reads layers before writing output,
                // except layer 1 aliases pose.blended. Copy pose.blended to pose.local2 if needed, or write into local2 first.
                foreach (i; 0 .. skeleton.numSoaJoints)
                    pose.local2[i] = pose.blended[i];
                layers[1].transform = pose.local2;

                BlendingJob job;
                job.restPose = skeleton.restPoses;
                job.layers = layers[];
                job.output = pose.blended;
                job.run();

                LocalToModelJob l2m;
                l2m.skeleton = skeleton;
                l2m.input = pose.blended;
                l2m.output = pose.model;
                l2m.run();

                syncSkeletonToPhysics(*ragAsset, pose.model, entityWorld, *rc, dt);
                break;
        }
    }
}

private Mat4 computeBoneWorldMatrix(Mat4 entityWorld, const Float4x4 jointModel, ref const RagdollBoneDef bone) pure nothrow @nogc {
    immutable Mat4 bindLocal = Mat4.trs(bone.bindLocalOffset, bone.bindLocalRot, Vec3(1, 1, 1));
    return entityWorld * mat4FromFloat4x4(jointModel) * bindLocal;
}

private Vec3 angularVelocityBetween(Quat qPrev, Quat qCur, float invDt) pure nothrow @nogc {
    Quat q = qCur * qPrev.conjugate();
    if (q.w < 0.0f) {
        q = Quat(-q.x, -q.y, -q.z, -q.w);
    }
    return Vec3(q.x * 2.0f * invDt, q.y * 2.0f * invDt, q.z * 2.0f * invDt);
}

version (unittest) {
    import engine.animation.ecs.assets : loadAnimationFile, loadSkeletonFile;
    import engine.animation.sampling : SamplingContext, SamplingJob;
    import engine.animation.testing : fixtureDir, near;
    import engine.ecs.world : World;

    alias RagdollTestWorld = World!(AnimSkeleton, AnimPlayback, RagdollComponent, Transform);
}

unittest {
    // 1. modelToLocalSoa roundtrip: LocalToModelJob(ragdollPose) reproduces original model matrices.
    AnimAssets assets;
    string err;
    auto sk = loadSkeletonFile(assets.skeletons, fixtureDir ~ "pab/skeleton.ozz", err);
    auto walk = loadAnimationFile(assets.animations, fixtureDir ~ "pab/walk.ozz", err);
    auto skeleton = assets.skeletons.get(sk);
    auto clip = assets.animations.get(walk);
    assert(skeleton !is null && clip !is null, err);

    auto ctx = SamplingContext(skeleton.numJoints);
    auto local = new SoaTransform[skeleton.numSoaJoints];
    auto model = new Float4x4[skeleton.numJoints];
    auto roundtripLocal = new SoaTransform[skeleton.numSoaJoints];
    auto roundtripModel = new Float4x4[skeleton.numJoints];

    SamplingJob sj;
    sj.animation = clip;
    sj.context = &ctx;
    sj.output = local;
    sj.ratio = 0.35f;
    assert(sj.run());

    LocalToModelJob l2m;
    l2m.skeleton = skeleton;
    l2m.input = local;
    l2m.output = model;
    assert(l2m.run());

    assert(modelToLocalSoa(*skeleton, model, roundtripLocal));

    l2m.input = roundtripLocal;
    l2m.output = roundtripModel;
    assert(l2m.run());

    foreach (j; 0 .. skeleton.numJoints) {
        foreach (c; 0 .. 4) foreach (r; 0 .. 4) {
            assert(near(model[j].cols[c][r], roundtripModel[j].cols[c][r], 1e-3f));
        }
    }
}

unittest {
    // 2. Full bidirectional ragdoll lifecycle with Box3D PhysicsWorld:
    //    animated (kinematic) -> ragdoll (dynamic, falls under gravity) -> beginRagdollGetUp -> blendingToAnim -> animated.
    import std.math : abs;

    AnimAssets animAssets;
    RagdollAssetStore ragdollAssets;
    PosePool pool;
    RagdollTestWorld world;
    auto physWorld = PhysicsWorld.createDefault();

    string err;
    auto sk = loadSkeletonFile(animAssets.skeletons, fixtureDir ~ "pab/skeleton.ozz", err);
    auto walk = loadAnimationFile(animAssets.animations, fixtureDir ~ "pab/walk.ozz", err);
    auto skeleton = animAssets.skeletons.get(sk);
    assert(skeleton !is null && !walk.isNull, err);

    RagdollAsset rig;
    rig.skeleton = sk;
    rig.boneCount = 2;
    rig.pelvisBoneIndex = 0;
    rig.getUpFaceUpClip = walk;
    rig.getUpFaceDownClip = walk;
    rig.bones[0].jointIndex = 0;
    rig.bones[0].parentBoneIndex = -1;
    rig.bones[0].shape = RagdollShapeKind.box;
    rig.bones[0].halfExtents = Vec3(0.15f, 0.15f, 0.15f);
    rig.bones[1].jointIndex = 1;
    rig.bones[1].parentBoneIndex = 0;
    rig.bones[1].shape = RagdollShapeKind.capsule;
    rig.bones[1].halfExtents = Vec3(0.08f, 0.15f, 0.08f);
    auto rigHandle = ragdollAssets.add(rig);

    immutable e = world.spawn();
    immutable slot = pool.acquire(skeleton.numJoints);
    world.set(e, AnimSkeleton(sk, slot));
    world.set(e, AnimPlayback(walk, 0.1f, 1.0f, true));
    Transform xf;
    xf.position = Vec3(0.0f, 5.0f, 0.0f);
    world.set(e, xf);

    auto pose = pool.get(slot);
    LocalToModelJob l2m;
    l2m.skeleton = skeleton;
    l2m.input = skeleton.restPoses;
    l2m.output = pose.model;
    assert(l2m.run());

    RagdollComponent rc;
    rc.asset = rigHandle;
    assert(spawnRagdollBodies(physWorld, rig, *skeleton, pose.model, xf.localMatrix(), rc, e));
    world.set(e, rc);
    scope (exit) destroyRagdollBodies(world.get!RagdollComponent(e));

    // Step in animated mode: body 0 tracks entityWorld * pose.model[0]
    immutable expectedAnimY = xf.position.y + pose.model[0].cols[3].y;
    ragdollSystem(world, ragdollAssets, animAssets, pool, 1.0f / 60.0f);
    physWorld.step(1.0f / 60.0f);
    immutable animY = readBodyTransform(world.get!RagdollComponent(e).bodies[0]).position.y;
    assert(abs(animY - expectedAnimY) < 1e-3f);

    // Activate ragdoll and simulate 20 frames under gravity
    activateRagdoll(world.get!RagdollComponent(e));
    assert(world.get!RagdollComponent(e).state == RagdollState.ragdoll);
    foreach (_; 0 .. 20) {
        physWorld.step(1.0f / 60.0f);
        ragdollSystem(world, ragdollAssets, animAssets, pool, 1.0f / 60.0f);
    }
    immutable fallenY = readBodyTransform(world.get!RagdollComponent(e).bodies[0]).position.y;
    assert(fallenY < animY - 0.1f, "ragdoll did not fall under gravity");

    // Begin get-up blend
    auto getUpClip = beginRagdollGetUp(rig, *skeleton, world.get!RagdollComponent(e),
                                       *pose, world.get!Transform(e), 0.25f);
    assert(getUpClip == walk);
    assert(world.get!RagdollComponent(e).state == RagdollState.blendingToAnim);

    // Advance past blendDuration -> transitions back to animated
    ragdollSystem(world, ragdollAssets, animAssets, pool, 0.30f);
    assert(world.get!RagdollComponent(e).state == RagdollState.animated);
}
