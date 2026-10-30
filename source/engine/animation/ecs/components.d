/// POD components for animated entities. All pass `isPod`, so they live in `ComponentStore`
/// without GC cost; assets are referenced through handles.
module engine.animation.ecs.components;

import engine.animation.ecs.assets;
import engine.core.pod : isPod;
import engine.math.vec : Vec3;

@safe:

/// Links an entity to a skeleton and to its runtime buffers in the `PosePool`.
struct AnimSkeleton {
    SkeletonHandle skeleton;
    uint poseSlot;
    /// Optional skin binding used to build the skinning palette.
    SkinHandle skin;
}

/// Plays one clip.
struct AnimPlayback {
    AnimationHandle clip;
    /// Seconds into the clip.
    float time = 0;
    float speed = 1;
    bool loop = true;
}

/// Blends two clips (e.g. idle / walk). `weight` 0 = all `a`, 1 = all `b`.
struct AnimBlend2 {
    AnimationHandle a, b;
    float weight = 0;
    float timeA = 0, timeB = 0;
    float speed = 1;
}

/// Additive layer on top of the base pose.
struct AnimAdditive {
    AnimationHandle clip;
    float weight = 0;
    float time = 0;
    float speed = 1;
}

/// Makes a joint aim at a model-space target (head look-at).
struct AnimLookAt {
    uint headJoint;
    Vec3 target;
    float weight = 1;
    /// Joint-local axis that should point at the target.
    Vec3 forward = Vec3(0, 0, 1);
    Vec3 up = Vec3(0, 1, 0);
}

static assert(isPod!AnimSkeleton && isPod!AnimPlayback && isPod!AnimBlend2
              && isPod!AnimAdditive && isPod!AnimLookAt);
