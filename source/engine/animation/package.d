// Ported from ozz-animation (MIT), (c) Guillaume Blanc, @ 744eb9d. See LICENSE-ozz-animation.md.
/// Skeletal animation runtime: a pure-D port of the ozz-animation runtime.
///
/// Pipeline: `loadSkeleton` / `loadAnimation` -> `SamplingJob` -> `BlendingJob` ->
/// `LocalToModelJob`. See `docs/plan-ozz-animation-port.md`.
module engine.animation;

public import engine.animation.blending;
public import engine.animation.clip;
public import engine.animation.io.archive;
public import engine.animation.keyframe;
public import engine.animation.local_to_model;
public import engine.animation.math.simd;
public import engine.animation.math.soa;
public import engine.animation.sampling;
public import engine.animation.gltf_skin;
public import engine.animation.skeleton;
public import engine.animation.skeleton_utils;
public import engine.animation.math.scalar;
public import engine.animation.track;
public import engine.animation.track_sampling;
public import engine.animation.track_triggering;
public import engine.animation.ik;
public import engine.animation.math.matrix;
public import engine.animation.motion_blending;
public import engine.animation.skinning;
