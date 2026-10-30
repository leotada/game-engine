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

`tools/ozz/bench.sh 1000 300 pab` builds the whole pipeline with LDC (`-O3 -release`) and prints
per-stage times; `dub run --config=anim -- --headless-frames=600 --assert-no-gc --characters=1000`
is the DMD functional run (also asserts zero GC allocations). `tools/ozz/golden/golden_gen ... --bench`
runs the same scenario against upstream C++ (g++ -O2, same machine, single thread, 1000
characters, 2-clip blend with continuous playback). Microseconds per character:

| Stage | pab (67 joints) D | C++ | D/C++ | ruby (368 joints) D | C++ | D/C++ |
|:---|---:|---:|---:|---:|---:|---:|
| sampling (2 clips) | 4.1 | 3.9 | 1.06 | 12.6 | 11.0 | 1.15 |
| blending (2 layers) | 1.1 | 0.9 | ~1.3 | 4.9 | 3.9 | ~1.25 |
| local to model | 1.2 | 0.9 | ~1.3 | 5.6 | 4.7 | ~1.2 |

Measurements are noisy (about 10 percent run to run). Plan targets (section 10 of the port plan) are
sampling <= 1.25x (met), blending and local-to-model <= 1.15x (**not met**, about 1.2-1.3x). Removing
bounds checks entirely (`-boundscheck=off`) gains about 9 percent overall, so the remaining gap is
arithmetic/codegen, not indexing. The hot loop of local-to-model already uses a narrowly-scoped
`@trusted` unchecked path (invariants documented at the function); no other loop was changed because
measurements did not justify it.

Full ECS pipeline, 1000 pab characters, LDC: ~7.3 ms per frame (sampling 4.1, blend 1.1, local to
model 1.2, look-at on 1/8 of characters 0.1, palette 0.7 us/char), zero GC allocations.

The `core.simd` backend (default on DMD x86_64 and LDC) is selected in `math/simd.d`;
`-version=EngineAnimScalarMath` forces the scalar reference backend. Both are checked against each
other by `math/simd_diff_tests.d`, and against upstream by `golden_tests.d`.

Perf notes (measured, kept in the code): building vectors lane-by-lane through a union made every
following 16-byte load miss store forwarding. The 4x4 transpose and the matrix-product broadcasts
therefore use register shuffles (`SHUFPS`), which made local-to-model ~8.7x faster.

**Compiler caveats.** DMD 2.1xx crashes (segfault) compiling `math/soa.d` with `-inline` when the
vector backend is active; DMD release builds of this module must not use `-inline` (or use
`-version=EngineAnimScalarMath`). Release builds should use LDC, per `AGENTS.md`. `dub
--compiler=ldc2` cannot link this repository because `libs/libsymgc` is built with DMD, hence the
standalone `tools/ozz/bench.sh`.

## 5. Conventions

- Matrices are column-major and `Float4x4` is layout-identical to `Mat4`.
- Rotations are quaternions `(x, y, z, w)`; IK corrections are joint-local, applied as
  `local.rotation * correction`.
- The runtime does not change handedness or units: they are whatever the source asset used.

## 6. Tools

| Tool | Purpose |
|:---|:---|
| `dub run --config=anim-viewer` | windowed viewer: skeleton gizmos, Left/Right blend walk/jog, Up/Down speed, G look-at, overlay line `anim: N chars, X ms` |
| `dub run --config=anim` / `anim-bench` | headless demo / benchmark (`--assert-no-gc`) |
| `tools/ozz/bench.sh` | LDC benchmark |
| `tools/ozz/golden/` | C++ golden generator (see its README) |
| Editor, Project panel | with a `.gltf` selected, **Import with gltf2ozz** runs upstream's `gltf2ozz` if it is on `PATH` |

## 7. GPU skinning

`engine.gpu.skinned.SkinnedRenderer` draws a skinned mesh with linear-blend skinning (4 influences).
The palette (`skinPaletteSystem` output, viewed with `asMat4`) goes to a read-only storage buffer
every frame via `updatePalette`. Limit: 1024 joints (the ozz skeleton limit, 64 KiB). Vertex format:
`SkinnedVertex` (position, normal, 4 x uint32 joints, 4 x float weights, 56 bytes). Normals assume
(near-)uniform scale. `buildBoneMesh` generates a tapered prism per bone for any skeleton, which the
viewer uses; real meshes come from `loadGltfSkin`.

## 8. Known gaps

- The viewer and the editor action were smoke-tested (the viewer starts, creates the skinned
  pipeline and renders for several seconds without errors) but not visually compared with the
  upstream sample viewer; an automated screenshot attempt captured the wrong window.
- Goldens cover sampling, blending, local-to-model, IK, tracks, triggering, motion blending and
  skinning. Not covered: track types other than float/float3, additive/partial blending paths, and
  the `SamplingJob` on animations other than pab/ruby.
- Blend and local-to-model are ~1.2-1.3x C++ against a 1.15x target (deviation measured and
  documented above; the remaining cost is a dependent parent-matrix load chain, not bounds checks).
- Per-character jobs are independent but run serially; they are ready for
  [plan-parallel-ecs.md](plan-parallel-ecs.md).
