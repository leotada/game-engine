# Animation Guide

User-facing guide to `engine.animation`, a pure-D port of the [ozz-animation](https://github.com/guillaumeblanc/ozz-animation)
**runtime** (MIT, pinned at `744eb9d`, v0.17.0). Design and porting notes live in
[plan-ozz-animation-port.md](plan-ozz-animation-port.md).

Animation data is authored offline and converted to `.ozz` archives with upstream's tools
(`gltf2ozz`, `fbx2ozz`); this engine only **loads and evaluates** them.

## 1. Pipeline

```
 .ozz skeleton ──► Skeleton ─────────────────────────┐
 .ozz animation ─► Animation ─► SamplingJob ─┐        │
                                             ├► BlendingJob ─► LocalToModelJob ─► model matrices
 .ozz animation ─► Animation ─► SamplingJob ─┘                     │
                                                                    ├► IKTwoBoneJob / IKAimJob (corrections)
                                                                    └► SkinningJob (CPU) or palette (GPU)
```

| Stage | Module | Job | Notes |
|:---|:---|:---|:---|
| Load | `skeleton`, `clip`, `track` | `loadSkeleton`, `loadAnimation`, `loadTrack` | All archives are validated on load; a corrupt file returns `false`, never traps. |
| Sample | `sampling` | `SamplingJob` + `SamplingContext` | The context caches keyframe cursors per animation (`uid`); reuse one per playing clip. |
| Blend | `blending` | `BlendingJob` | Normal, partial (per-joint weights) and additive layers; rest-pose fallback. |
| Local to model | `local_to_model` | `LocalToModelJob` | `from` / `to` / `fromExcluded` for partial updates. |
| IK | `ik` | `IKTwoBoneJob`, `IKAimJob` | Produce joint-local corrections, applied with `applyCorrection`. |
| Root motion | `motion_blending`, `track_sampling` | `MotionBlendingJob`, `TrackSamplingJob` | Sample a motion track, blend deltas, apply to the entity transform. |
| Events | `track_triggering` | `TrackTriggeringJob` | Edge-detected events from float tracks between two ratios. |
| Skin | `skinning`, `gltf_skin` | `SkinningJob` | `model[remap[j]] * inverseBind[j]` palette; CPU skinning of positions/normals/tangents. |

Every `run()` is `@nogc nothrow` and allocation-free; buffers are owned by the caller.

## 2. Using the jobs directly

```d
import engine.animation;

auto ar = InputArchive(readBytes("pab/skeleton.ozz"));
Skeleton skeleton;  loadSkeleton(ar, skeleton);
// ... load `Animation anim` the same way ...

auto ctx   = SamplingContext(skeleton.numJoints);
auto local = new SoaTransform[skeleton.numSoaJoints];
auto model = new Float4x4[skeleton.numJoints];   // layout-identical to engine.math.Mat4

SamplingJob s;  s.animation = &anim; s.context = &ctx; s.ratio = t / anim.duration; s.output = local;
s.run();
LocalToModelJob l; l.skeleton = &skeleton; l.input = local; l.output = model;
l.run();
```

`asMat4(model)` (in `engine.animation.ecs`) views the result as `const(Mat4)[]` for GPU upload.

## 3. ECS integration (`engine.animation.ecs`)

Assets contain slices, so they are **not** components. They live in `AnimAssets` stores and
components reference them through generational handles:

```d
AnimAssets assets;  PosePool pool;
AnimWorld world;   // World!(AnimSkeleton, AnimPlayback, AnimBlend2, AnimAdditive, AnimLookAt, AnimTwoBoneIK)

auto sk   = loadSkeletonFile(assets.skeletons, "skeleton.ozz", err);
auto walk = loadAnimationFile(assets.animations, "walk.ozz", err);

auto e = world.spawn();
world.set(e, AnimSkeleton(sk, pool.acquire(numJoints)));   // PosePool allocates once, at spawn
world.set(e, AnimPlayback(walk, 0, 1, true));
```

Frame loop (all `@nogc`, zero GC allocations measured by `--assert-no-gc`):

```d
advancePlaybackSystem(world, assets, dt);
sampleSystem(world, assets, pool);
blendSystem(world, assets, pool);
localToModelSystem(world, assets, pool);
ikSystem(world, assets, pool);            // optional, entities with AnimTwoBoneIK
lookAtSystem(world, assets, pool);        // optional, entities with AnimLookAt
skinPaletteSystem(world, assets, pool);   // pool.get(slot).palette -> GPU
```

| Component | Purpose |
|:---|:---|
| `AnimSkeleton` | skeleton handle, pose slot, optional skin handle |
| `AnimPlayback` | one clip: `time`, `speed`, `loop` |
| `AnimBlend2` | two clips mixed by `weight` (idle/walk) |
| `AnimAdditive` | additive layer on top |
| `AnimTwoBoneIK` | arm/leg IK toward a model-space target |
| `AnimLookAt` | aim a joint at a model-space target |

Hot reload: `reloadAnimationFile` replaces an asset under the same handle; the new `uid` makes
sampling contexts rebuild themselves on the next run.
`.ozz` files are registered by `AssetDatabase` with importer `"ozz"`.

Skins: `loadGltfSkin(path, skeleton, binding, vertices, err)` reads the first skin of a glTF file
and matches joints to the skeleton **by node name**; an unmatched joint fails the load and names it.

Debug: `drawSkeleton(gizmos, skeleton, pose.model)` draws bones and joint axes through any sink
with `line(Vec3, Vec3, Color4)`, including `GizmoRenderer`.

## 4. Performance

`dub run --config=anim -- --headless-frames=600 --assert-no-gc --characters=1000 [--skeleton=ruby]`
runs the whole pipeline headless and prints per-stage times. Numbers below: LDC 2 `-O3 -release`,
one core, 67-joint `pab` skeleton, 2-layer blend, look-at on 1/8 of characters, 1000 characters.

| Stage | µs / character |
|:---|---:|
| sampling (2 clips) | 4.2 |
| blending | 1.1 |
| local to model | 1.2 |
| look-at | 0.1 |
| skin palette | 0.7 |
| **total** | **~7.3** (7.3 ms for 1000 characters) |

The `core.simd` backend (default on DMD x86_64 and LDC) is selected in `math/simd.d`;
`-version=EngineAnimScalarMath` forces the scalar reference backend. Both are checked against each
other by `math/simd_diff_tests.d`.

Perf notes (measured, kept in the code): building vectors lane-by-lane through a union made every
following 16-byte load miss store forwarding. The 4x4 transpose and the matrix-product broadcasts
therefore use register shuffles (`SHUFPS`), which made local-to-model ~8.7x faster.

## 5. Conventions

- Matrices are column-major and `Float4x4` is layout-identical to `Mat4`.
- Rotations are quaternions `(x, y, z, w)`; IK corrections are joint-local, applied as
  `local.rotation * correction`.
- The runtime does not change handedness or units: they are whatever the source asset used.

## 6. Known gaps

- No C++ golden harness: correctness is checked with oracle tests (cache vs fresh context, naive
  recursive local-to-model, blend identities, SIMD differential tests), not by comparing numbers
  with upstream binaries. Estimate instructions (`rcpps`/`rsqrtps`) can differ slightly from the
  scalar path.
- The anim demo is headless; there is no windowed viewer or keyboard-driven blend yet.
- Editor: components are annotated for the Inspector, but there is no import action for `gltf2ozz`.
- Per-character jobs are independent but run serially; they are ready for
  [plan-parallel-ecs.md](plan-parallel-ecs.md).
