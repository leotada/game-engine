/// POD components for animated entities. All pass `isPod`, so they live in `ComponentStore`
/// without GC cost; assets are referenced through handles. Scalar fields carry the editor's
/// `@export_` attribute so the Inspector can edit them; handles are set by code.
module engine.animation.ecs.components;

import engine.animation.ecs.assets;
import engine.core.pod : isPod;
import engine.math.vec : Vec3;
import engine.reflect.attrs : component, export_, range;

@safe:

/// Links an entity to a skeleton and to its runtime buffers in the `PosePool`.
@component struct AnimSkeleton {
    SkeletonHandle skeleton;
    uint poseSlot;
    /// Optional skin binding used to build the skinning palette.
    SkinHandle skin;
}

/// Plays one clip.
@component struct AnimPlayback {
    AnimationHandle clip;
    /// Seconds into the clip.
    @export_ float time = 0;
    @export_ float speed = 1;
    @export_ bool loop = true;
}

/// Blends two clips (e.g. idle / walk). `weight` 0 = all `a`, 1 = all `b`.
@component struct AnimBlend2 {
    AnimationHandle a, b;
    @export_ @range(0, 1) float weight = 0;
    float timeA = 0, timeB = 0;
    @export_ float speed = 1;
}

/// Additive layer on top of the base pose.
@component struct AnimAdditive {
    AnimationHandle clip;
    @export_ @range(0, 1) float weight = 0;
    float time = 0;
    @export_ float speed = 1;
}

/// Makes a joint aim at a model-space target (head look-at).
@component struct AnimLookAt {
    @export_ uint headJoint;
    @export_ Vec3 target;
    @export_ @range(0, 1) float weight = 1;
    /// Joint-local axis that should point at the target.
    Vec3 forward = Vec3(0, 0, 1);
    Vec3 up = Vec3(0, 1, 0);
}

static assert(isPod!AnimSkeleton && isPod!AnimPlayback && isPod!AnimBlend2
              && isPod!AnimAdditive && isPod!AnimLookAt);

/// Two-bone IK (arm/leg): reaches `target` (model space) with the chain `start -> mid -> end`.
@component struct AnimTwoBoneIK {
    @export_ uint startJoint, midJoint, endJoint;
    @export_ Vec3 target;
    /// Direction the mid joint (elbow/knee) should point to.
    @export_ Vec3 pole = Vec3(0, 1, 0);
    /// Hinge axis of the mid joint, in mid-joint space.
    Vec3 midAxis = Vec3(0, 0, 1);
    @export_ @range(0, 1) float weight = 1;
}

static assert(isPod!AnimTwoBoneIK);
