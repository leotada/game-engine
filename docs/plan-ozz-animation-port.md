# Port Plan: ozz-animation Runtime → Pure D (`engine.animation`)

> **Status:** proposed · Priority: medium (roadmap #5, skeletal animation)
> **Upstream:** [guillaumeblanc/ozz-animation](https://github.com/guillaumeblanc/ozz-animation), pinned at
> commit `744eb9d` (release **0.17.0**, Aug 2026). License: **MIT**.
> **Scope:** the **runtime** libraries only (`ozz_base`, `ozz_animation`, `ozz_geometry`).
> The offline pipeline (`ozz_animation_offline`, `*2ozz` tools, `ozz_options`) is **not** ported.
> **Relation to other plans:** this document is the concrete implementation of phases
> AN-1 (POD data structures) and AN-3 (pose evaluation) of [plan-animation.md](plan-animation.md),
> and supplies the CPU side of AN-4 (GPU skinning). AN-2 (glTF animation parsing) is replaced by
> the `.ozz` data pipeline described in §3.

---

## 1. Goals and Non-Goals

### Goals

1. A native, dependency-free D implementation of the ozz-animation runtime: skeleton, compressed
   animation clips, sampling, blending (normal + additive + partial), local-to-model conversion,
   user-channel tracks, IK (two-bone and aim), root-motion blending, and CPU skinning.
2. **Binary compatibility** with `.ozz` archives produced by the upstream offline tools
   (`gltf2ozz`, `fbx2ozz`) for the current format versions: Skeleton **v2**, Animation **v7**,
   tracks **v1**. Assets authored with the upstream toolchain load unchanged.
3. **Numerical parity** with upstream C++: sampled local poses and model-space matrices match the
   reference implementation within documented tolerances (§9).
4. **Engine-native idioms:** `@safe:` modules, `pure nothrow @nogc` jobs, `Pod!T` engine storage,
   `Handle!T` references from ECS components, zero GC allocation in the frame path.
5. **Performance parity:** LDC2 release build within **1.25×** of upstream C++ (clang `-O3`, SSE2
   backend) on the sampling + blending + local-to-model pipeline (§10).

### Non-Goals

- Porting `ozz/animation/offline/*` (RawAnimation, AnimationBuilder, AnimationOptimizer,
  SkeletonBuilder, AdditiveAnimationBuilder, MotionExtraction, track builders/optimizers) and the
  `*2ozz` command-line tools. They stay C++ and are used as external tools (§3).
- Backward compatibility with old archive versions (Animation v1–v6, Skeleton v1). Upstream itself
  refuses them (`if (_version != 7) …`); we do the same and log a clear error.
- Writing archives (`OArchive`). The runtime only reads. Writing is an offline concern.
- Porting `ozz/base/containers/*`, `ozz/base/memory/*`, `ozz/base/log.*`, `ozz/base/platform.*`,
  `ozz/options/*`, `gtest_helper.h`, and the samples framework. D slices, the engine allocator
  policy, and `engine.core.log` replace them.
- Retargeting, morph targets, animation state machines/graphs. These are built *on top of* the
  runtime later (out of scope here, tracked in [plan-animation.md](plan-animation.md)).

---

## 2. Upstream Inventory (Runtime Scope)

Line counts are from the pinned commit (headers + sources, comments included).

### 2.1 Files to port

| Upstream file(s) | Lines | D module | Phase |
|:---|---:|:---|:---|
| `base/maths/simd_math.h`, `internal/simd_math_ref-inl.h`, `internal/simd_math_sse-inl.h`, `internal/simd_math_config.h` | ~5,670 | `engine.animation.math.simd` (+ `simd_ref`, `simd_vec`) | OZ-1, OZ-2 |
| `base/maths/simd_quaternion.h` | 271 | `engine.animation.math.simd_quat` | OZ-1 |
| `base/maths/soa_float.h`, `soa_quaternion.h`, `soa_transform.h`, `soa_float4x4.h` | ~1,190 | `engine.animation.math.soa` | OZ-1 |
| `base/maths/vec_float.h`, `quaternion.h`, `transform.h`, `math_ex.h`, `math_constant.h`, `box.h`/`box.cc` | ~1,170 | `engine.animation.math.scalar` (reuses `engine.math` where layout-identical) | OZ-1 |
| Half-float conversion (in `simd_math.h` / `math_ex.h`) | — | `engine.animation.math.half` | OZ-1 |
| `base/endianness.h` | 150 | `engine.animation.io.endian` | OZ-3 |
| `base/io/archive.h`, `archive_traits.h`, `archive.cc`, `stream.h`/`stream.cc` (read side only) | ~1,120 | `engine.animation.io.archive` | OZ-3 |
| `base/maths/math_archive.*`, `simd_math_archive.*`, `soa_math_archive.*` (load side) | ~590 | `engine.animation.io.math_archive` | OZ-3 |
| `base/encode/group_varint.h` / `.cc` (decode side) | ~240 | `engine.animation.io.group_varint` | OZ-3 |
| `animation/runtime/skeleton.h` / `.cc` | 315 | `engine.animation.skeleton` | OZ-4 |
| `animation/runtime/skeleton_utils.h` / `.cc` | 191 | `engine.animation.skeleton_utils` | OZ-4 |
| `animation/runtime/animation.h` / `.cc`, `animation_keyframe.h` | 675 | `engine.animation.clip`, `engine.animation.keyframe` | OZ-5 |
| `animation/runtime/animation_utils.h` / `.cc` | 111 | `engine.animation.clip_utils` | OZ-5 |
| `animation/runtime/sampling_job.h` / `.cc` | 793 | `engine.animation.sampling` | OZ-6 |
| `animation/runtime/local_to_model_job.h` / `.cc` | 223 | `engine.animation.local_to_model` | OZ-7 |
| `animation/runtime/blending_job.h` / `.cc` | 587 | `engine.animation.blending` | OZ-8 |
| `animation/runtime/track.h` / `.cc`, `track_sampling_job.*`, `track_triggering_job.*`, `track_triggering_job_trait.h` | ~915 | `engine.animation.track`, `track_sampling`, `track_triggering` | OZ-9 |
| `animation/runtime/ik_two_bone_job.*`, `ik_aim_job.*` | 828 | `engine.animation.ik` | OZ-10 |
| `animation/runtime/motion_blending_job.*` | 176 | `engine.animation.motion_blending` | OZ-11 |
| `geometry/runtime/skinning_job.h` / `.cc` | 685 | `engine.animation.skinning` | OZ-12 |

The SIMD layer dominates the line count because upstream carries two complete backends (reference
and SSE) plus many operations the animation runtime never calls. The D port implements **only the
operations reachable from the runtime jobs**, discovered by compiling each job and adding what is
missing. Expected D size: **~5–7 kLOC** of library code plus **~4–6 kLOC** of tests.

### 2.2 Explicitly excluded

| Upstream | Reason / replacement |
|:---|:---|
| `animation/offline/**`, `animation/offline/tools/**` | Offline pipeline; use upstream `*2ozz` binaries (§3) |
| `options/**` | CLI option parsing for tools |
| `base/containers/**` | D slices and engine containers |
| `base/memory/allocator.*`, `unique_ptr.h` | Single-block allocation policy (§4.3) |
| `base/log.*` | `engine.core.log` |
| `base/platform.*`, `span.h`, `export.h` | D language features |
| `base/io/stream.*` write side, `OArchive` | Runtime only reads |
| `base/maths/rect.h`, `gtest_math_helper.h` | Unused by runtime / replaced by D test helpers |
| `samples/framework/**` (incl. `ozz::sample::Mesh` archive) | Sample-only; meshes come from the engine's glTF loader |

---

## 3. Data Pipeline Without an Offline Port

Because the offline libraries are not ported, animation data enters the engine as `.ozz` archives:

```
 Authoring (DCC)        Offline (upstream C++, external)          Runtime (this port, pure D)
 ───────────────        ────────────────────────────────          ───────────────────────────
  model.gltf  ──►  gltf2ozz --file=model.gltf --config=…  ──►  skeleton.ozz  ──►  Skeleton
  model.fbx   ──►  fbx2ozz  …                              ──►  walk.ozz      ──►  Animation
                                                           ──►  grasp.ozz     ──►  FloatTrack …
  model.gltf  ──────────────────────────────────────────────────────────────►  engine glTF loader
                                                                             (mesh + skin: joints,
                                                                              weights, inverse binds)
```

- `gltf2ozz` / `fbx2ozz` are invoked as **external tools** (prebuilt upstream binaries, or built
  from a pinned checkout under `tools/ozz/` by a script — never part of `dub build`).
- A thin wrapper `tools/ozz/import.sh` documents the exact `*2ozz` JSON configuration the engine
  expects (skeleton import, animation import with `iframe_interval`, optional motion extraction,
  optional user tracks).
- The engine's `AssetDatabase` treats `.ozz` as a first-class asset type with `.meta` sidecars
  (§OZ-13). The asset importer *does not* run `*2ozz` itself in the first iteration; the editor can
  call it later as an optional external step.
- Mesh skin data (`JOINTS_0`, `WEIGHTS_0`, inverse bind matrices) is loaded by extending
  `engine.assets.gltf` (plan-animation AN-2, mesh half only). Joint order differs between glTF and
  the ozz skeleton (the skeleton is stored depth-first), so a **name-based remap table** from mesh
  joint indices to skeleton joint indices is built at load time (OZ-13).

> **Future option (not in this plan):** a pure-D minimal offline builder (glTF clip → v7 archive,
> no optimizer) could remove the external-tool dependency. It would be scoped as a separate plan
> because it requires porting `AnimationBuilder`, the keyframe compressor and iframe generation.

### 3.1 Archive format (read side)

All archives share the same framing, written by `OArchive`:

| Field | Type | Notes |
|:---|:---|:---|
| endianness | `u8` | `0` = big-endian, `1` = little-endian (`kBigEndian`, `kLittleEndian`). Never swapped. All subsequent multi-byte primitives are swapped if this differs from native. |
| tag | `char[N]` | Type tag **including the terminating NUL** (`OZZ_ARRAY_SIZE` of the literal): `"ozz-skeleton\0"`, `"ozz-animation\0"`, `"ozz-float_track\0"`, `"ozz-float2_track\0"`, `"ozz-float3_track\0"`, `"ozz-float4_track\0"`, `"ozz-quat_track\0"` |
| version | `u32` | Type version (Skeleton 2, Animation 7, tracks 1) |
| payload | — | Type-specific. Arrays (`MakeArray`) are raw element sequences **without a count prefix**; counts come from earlier header fields. |

A file may contain several objects back to back (e.g. a skeleton followed by animations). The D
reader exposes `bool nextIs(T)()` (tag peek without consuming) mirroring `IArchive::TestTag`.

**Skeleton v2 payload:**

| Field | Type |
|:---|:---|
| `num_joints` | `i32` (0 ⇒ empty skeleton, payload ends) |
| `chars_count` | `i32` |
| names | `char[chars_count]` — NUL-separated, contiguous |
| `joint_parents` | `i16[num_joints]` (`-1` = no parent) |
| `joint_rest_poses` | `SoaTransform[(num_joints + 3) / 4]`, each = 40 `f32` (t.x[4], t.y[4], t.z[4], r.x[4], r.y[4], r.z[4], r.w[4], s.x[4], s.y[4], s.z[4]) |

**Animation v7 payload:**

| Field | Type |
|:---|:---|
| `duration` | `f32` |
| `num_tracks`, `name_len`, `timepoints_count` | `u32` ×3 |
| `translation_count`, `rotation_count`, `scale_count` | `u32` ×3 |
| `{t,r,s}_iframe_entries_count`, `{t,r,s}_iframe_desc_count` | `u32` ×6 (interleaved t-entries, t-desc, r-entries, r-desc, s-entries, s-desc) |
| name | `char[name_len]` (no NUL in file) |
| timepoints | `f32[timepoints_count]` |
| translations ctrl | `ratios: u8/u16[translation_count]`, `previouses: u16[translation_count]`, `iframe_entries: u8[…]`, `iframe_desc: u32[…]`, `iframe_interval: f32` |
| translations values | `Float3Key[translation_count]` (3× `u16` half floats) |
| rotations ctrl + values | same ctrl layout, `QuaternionKey[rotation_count]` (3× `u16`, packed) |
| scales ctrl + values | same as translations |

`ratios` element width is **`u8` if `timepoints_count <= 255`, else `u16`**. The byte size of
`ratios` must be computed accordingly when reading (and endian-swapped only in the `u16` case).

---

## 4. Global Port Conventions

These extend the rules in `AGENTS.md`; nothing here overrides them.

### 4.1 Language mapping

| C++ (ozz) | D (engine) |
|:---|:---|
| `ozz::span<T>` | `T[]` / `const(T)[]` slices |
| `class Skeleton` / `class Animation` (move-only) | `struct` with `@disable this(this)`; explicit `move` |
| `const Animation*` in jobs | `const(Animation)*` field (job structs) — non-null checked in `validate()` |
| `bool* reached`, `SimdQuaternion* correction` (job outputs) | pointer fields kept for API parity; free-function wrappers take `out`/`ref` params |
| `const char* const*` joint names | one `char[]` name buffer + `uint[]` offsets; `jointName(i)` returns `const(char)[]` slice |
| `assert` + `Validate()` | `validate()` returns `bool`; `run()` returns `false` on invalid input; `assert` kept for internal invariants |
| `OZZ_INLINE` | `pragma(inline, true)` |
| `alignas(16)` | `align(16)` on structs; SIMD types are naturally 16-byte aligned |
| `reinterpret_span<const uint16_t>(bytes)` | `@trusted` helper `reinterpretAs!T(const(ubyte)[])` asserting length and alignment |
| Templates over value type (`Track<T>`) | D templates (`Track!T`) with `alias FloatTrack = Track!float` etc. |
| Iterator classes (`TrackTriggeringJob::Iterator`) | D input range (`empty` / `front` / `popFront`), `@nogc` |
| `log::Err() << …` | `engine.core.log.err(...)` (load path only, never in jobs) |

Identifiers follow D style (`numJoints`, `jointParents`, `restPoses`, `SamplingJob.run`) while
keeping upstream concept names so the upstream documentation remains a usable reference.

### 4.2 Attributes and safety

- Every module starts with `@safe:`.
- All job `run()`/`validate()` methods and math are `pure nothrow @nogc @safe`.
- Loaders are `@safe` but **not** `@nogc` (they run at asset-load time, outside the frame loop).
- `@trusted` appears only in: byte-slice reinterpretation (`reinterpretAs`), endian swapping of
  raw arrays, SIMD intrinsics that take pointers (`loadPtr`/`storePtr`), and carving typed slices
  out of a single allocation block. Each such function is ≤ 10 lines with its invariant stated in a
  comment.
- **Bounds checks stay on** in the first implementation (including LDC release, where `@safe` code
  keeps checks under `-release`). Unchecked `.ptr` indexing in hot loops is a later, measured
  optimization (OZ-14) justified by the load-time validation in §4.4.

### 4.3 Memory and GC policy

- **One allocation per resource**, like upstream: `Skeleton`, `Animation`, `Track!T` and
  `SamplingJob.Context` each own a single `ubyte[]` block, allocated with `GC.malloc` +
  `BlkAttr.NO_SCAN` (contents are pure numeric data), from which typed slices are carved in
  decreasing-alignment order. The GC sees one non-scanned root per resource.
- `Skeleton`, `Animation`, `Track!T` contain slices and are therefore **not** `isPod`. They never
  live in ECS component storage. They live in an engine-owned asset store and are referenced from
  components through `Handle!SkeletonAsset` / `Handle!AnimationAsset` (§OZ-13).
- Per-instance runtime buffers (local poses `SoaTransform[]`, model matrices `Mat4[]`, sampling
  contexts) are pre-allocated per character in a `PosePool` declared with `Pod!T[]`.
- Transient per-frame buffers (e.g. blend layer arrays, temporary poses) come from `FrameArena`.
- Jobs never allocate. `BlendingJob` keeps its upstream fixed-size stack scratch
  (`SimdFloat4[kMaxSoAJoints]` = 4 KiB), declared `= void`.

### 4.4 Load-time validation (deviation from upstream)

Upstream trusts archive contents and relies on debug asserts. The engine loads user-provided files,
so the D loaders **validate every structural invariant once at load time**, returning an error
instead of crashing later inside a job:

- Skeleton: `num_joints <= 1024`; `parents[i] < i` (depth-first order) and `>= -1`; names buffer
  contains exactly `num_joints` NUL-terminated strings.
- Animation: `num_tracks <= 1024`; every `ratios[k] < timepoints_count`; timepoints sorted in
  `[0, 1]`; `previouses[k] <= k` and the first `2 * num_soa_tracks * 4` keys form the initial
  left/right key pairs; `iframe_desc` offsets lie within `iframe_entries`; every key count is a
  multiple of 4 where upstream requires it.
- Tracks: `ratios`, `values` same length; ratios sorted; `steps` bit count matches.
- Truncated or oversized files fail with a precise message (field name + offset).

This lets jobs assume well-formed data, exactly as upstream does, while staying memory-safe.

### 4.5 Workflow

- One phase per commit (or a small series), each ending with `dub test --config=library` green and
  every existing build configuration still compiling.
- DMD for day-to-day development (per `AGENTS.md`); LDC2 for benchmarks and release.
- Every ported file carries a header comment: `Ported from ozz-animation (MIT), © Guillaume Blanc,
  <upstream path> @ 744eb9d`. The upstream `LICENSE.md` is copied to
  `source/engine/animation/LICENSE-ozz-animation.md`.

---

## 5. Target Module Layout

```
source/engine/animation/
├── package.d                 # public imports of the user-facing API
├── LICENSE-ozz-animation.md  # upstream MIT license
├── math/
│   ├── simd.d                # SimdFloat4 / SimdInt4 / Float4x4 — backend selection
│   ├── simd_ref.d            # scalar reference backend (float[4] / int[4])
│   ├── simd_vec.d            # core.simd backend (DMD x86_64 SSE, LDC all targets)
│   ├── simd_quat.d           # SimdQuaternion (AoS quaternion in one SimdFloat4)
│   ├── soa.d                 # SoaFloat2/3/4, SoaQuaternion, SoaFloat4x4, SoaTransform
│   ├── scalar.d              # Float2/3/4, Quaternion, Transform, Box (aliases to engine.math where possible)
│   └── half.d                # half <-> float (scalar + SIMD)
├── io/
│   ├── endian.d              # native endianness, byte swap for scalars and arrays
│   ├── archive.d             # InputArchive over const(ubyte)[]: tags, versions, primitives, arrays
│   ├── math_archive.d        # load SoaTransform, Float3, Quaternion, Transform…
│   └── group_varint.d        # GV4 decode (bounds-safe)
├── skeleton.d                # Skeleton + loadSkeleton
├── skeleton_utils.d          # findJoint, isLeaf, iterateJointsDF(+Reverse), restPose helpers
├── keyframe.d                # Float3Key, QuaternionKey, pack/unpack
├── clip.d                    # Animation + loadAnimation
├── clip_utils.d              # countTranslationKeyframes, …
├── sampling.d                # SamplingJob, SamplingContext
├── blending.d                # BlendingJob (+ additive, partial)
├── local_to_model.d          # LocalToModelJob
├── motion_blending.d         # MotionBlendingJob
├── ik.d                      # IKTwoBoneJob, IKAimJob
├── track.d                   # Track!T (Float, Float2, Float3, Float4, Quaternion) + loaders
├── track_sampling.d          # TrackSamplingJob!T
├── track_triggering.d        # TrackTriggeringJob + edge range
├── skinning.d                # SkinningJob (CPU skinning)
└── ecs/                      # engine integration (OZ-13), not part of the upstream port
    ├── assets.d              # SkeletonAsset / AnimationAsset stores, Handle types, .ozz importer
    ├── components.d          # POD components
    ├── pose_pool.d           # Pod!-backed per-instance pose buffers
    └── systems.d             # sample → blend → IK → local-to-model → palette systems
```

`engine/package.d` gains `public import engine.animation;` once OZ-13 lands. Before that, the
package is reachable only by explicit import, so partial phases cannot affect existing code.

The name `engine.animation` is used (consistent with `engine.physics`, `engine.audio`). Upstream
`Animation` becomes `Animation` inside `engine.animation.clip`; ECS-facing wrappers use the
`AnimationClip` / `AnimationAsset` names to avoid confusion with the package name.

---

## 6. Math Layer Design (Highest-Risk Area)

The runtime's performance and correctness depend almost entirely on the SIMD/SoA math layer.

### 6.1 Backends

| Backend | Selected when | Implementation |
|:---|:---|:---|
| `simd_vec` | `version(LDC)` (any target) or `version(D_SIMD)` with `version(X86_64)` (DMD) | `core.simd.float4` / `int4`; LDC: `ldc.simd` + `ldc.intrinsics` / `ldc.gccbuiltins_x86` for estimate instructions on x86, generic LLVM vectors elsewhere (NEON on ARM) |
| `simd_ref` | everything else, or `version(EngineAnimScalarMath)` forced | `struct { float[4] v; }`, plain loops — mirrors `simd_math_ref-inl.h` |

- `SimdFloat4`, `SimdInt4`, `Float4x4` are **type aliases chosen at compile time**; all upstream
  functions (`load`, `splatX`, `madd`, `rcpEst`, `rsqrtEst`, `normalizeEst3`, `select`, `and`,
  `or`, `xor`, `andNot`, `sign`, `cmpLt`, `transpose4x4`, `transpose16x16`, `halfToFloat`, …) are
  free functions with identical semantics in both backends.
- **DMD caveats** to handle explicitly: DMD's `core.simd` does not support vector comparison
  operators or shuffles through operators — use `__simd(XMM.CMPPS, a, b, imm)`, `__simd(XMM.SHUFPS,
  …)`, `__simd(XMM.RCPPS, …)`, `__simd(XMM.RSQRTPS, …)`. DMD inlining is weak; DMD builds must be
  correct, not fast. Performance targets apply to LDC only.
- **No third-party SIMD dependency** (e.g. `intel-intrinsics`): consistent with the "we control our
  own bindings" policy. All intrinsics are compiler builtins.
- The reference backend is written **first** (OZ-1) and is the oracle for the vector backend's
  unit tests (OZ-2): every SIMD function is tested against `simd_ref` on randomized inputs.

### 6.2 Estimate functions and determinism

Upstream uses `RcpEst`, `RSqrtEst`, `NLerpEst`, `NormalizeEst` (SSE `rcpps`/`rsqrtps`, ~12-bit
precision). These differ across ISAs (SSE vs NEON vs scalar `1/sqrt`).

- x86 vector backend: use the hardware estimate instructions (bit-identical to upstream SSE).
- ARM / scalar backend: use NEON estimates where LDC exposes them, otherwise exact division/sqrt.
- Consequence: **cross-backend tests use tolerances**, never bit equality (§9.3). Bit-exact
  comparisons are only used for pure decoding steps (half → float, quaternion unpack before
  normalization, GV4 decode).

### 6.3 Layout interop with `engine.math`

- `Float4x4` (four `SimdFloat4` columns) has **the same memory layout as `engine.math.Mat4`**
  (column-major `float[16]`, `m[col * 4 + row]`). A `@trusted` zero-cost view converts
  `Float4x4[]` → `Mat4[]` so model-space matrices upload to the GPU skinning buffer without copies.
- Scalar `Float3` / `Quaternion` (`x, y, z, w`) are layout-identical to `engine.math.Vec3` /
  `engine.math.Quat`; the port aliases them (adding missing operations to `engine.math` as needed
  rather than duplicating types). `Transform` (translation, rotation, scale) is added to
  `engine.math` if not present.
- Handedness/up-axis: ozz is right-handed, +Y up after `gltf2ozz` conversion; verify against the
  engine camera/scene conventions in OZ-13 and document the result.

### 6.4 SoA types

`SoaFloat3 { SimdFloat4 x, y, z; }`, `SoaQuaternion { x, y, z, w; }` (default identity),
`SoaTransform { SoaFloat3 translation; SoaQuaternion rotation; SoaFloat3 scale; }` (default
identity: t = 0, r = identity, s = 1 — the 0.17.0 default-initialization semantics). Each
`SoaTransform` holds 4 joints in 160 bytes. These are POD (`isPod!SoaTransform` must hold; add a
`static assert`) so pose buffers can be `Pod!SoaTransform[]`.

---

## 7. Phases

Each phase lists its deliverables, the upstream tests it ports, and its Definition of Done (DoD).

### OZ-0 — Scaffolding, Fixtures, Golden Harness

- [ ] Create `source/engine/animation/` with `package.d` and the license file.
- [ ] Vendor a minimal set of upstream `media/bin` archives into `assets/animation/test/`
      (MIT, attribution in a `README.md`): `pab/skeleton.ozz`, `pab/walk.ozz`, `pab/jog.ozz`,
      `pab/run.ozz` (blend), `pab/crossarms.ozz` (partial blend), `pab/crackhead_additive.ozz`
      (additive), `pab/walk_motion_track.ozz` (root motion), `ruby_skeleton.ozz` +
      `ruby_animation.ozz`, `robot_skeleton.ozz` + `robot_animation.ozz` +
      `robot_track_grasp.ozz` (user track), and from `versioning/`: `animation_v7_le.ozz`,
      `animation_v7_be.ozz`, `animation_v6_le.ozz` (rejection test), `skeleton_v2_le.ozz`,
      `skeleton_v2_be.ozz`, `skeleton_v1_le.ozz` (rejection test). Keep total size modest (< 2 MB).
- [ ] **Golden harness** `tools/ozz/golden/` (C++17 + CMake, *not* built by dub): links upstream
      ozz at the pinned commit and dumps reference outputs to binary fixtures
      `assets/animation/test/golden/*.bin`:
      sampled `SoaTransform`s at 64 ratios per clip (including 0, 1, backward seeks and large
      jumps that trigger iframes), blending results for fixed weight sets, model-space matrices,
      IK corrections for fixed targets, track sampling/triggering outputs, skinning outputs for a
      synthetic mesh. Fixtures are generated once and committed; CI never needs a C++ toolchain.
- [ ] D test helper `engine.animation.testing` (compiled only under `version(unittest)`):
      fixture loading, `expectNear` for floats/SoA/matrices with configurable ULP/absolute
      tolerance, readable diff output (joint index, component, expected/actual).

**DoD:** `dub test --config=library` runs an empty `engine.animation` test module; golden fixtures
and their generator are committed with a `README.md` describing regeneration.

### OZ-1 — Scalar Math, Reference SIMD Backend, Half Floats, SoA

- [ ] `math/scalar.d`: Float2/3/4, Quaternion (fromAxisAngle, fromEuler, fromVectors, nlerp, slerp,
      conjugate, transformVector), Transform, Box — aliasing `engine.math` types where identical.
- [ ] `math/simd_ref.d` + `math/simd.d` (ref-only selection for now): all `SimdFloat4`/`SimdInt4`
      operations needed by the runtime, `Float4x4` (identity, translation, scaling, rotation from
      quaternion, `fromAffine`, multiply, `transformPoint`, `transformVector`, `invert`, `transpose`,
      `toQuaternion`, `toAffine`).
- [ ] `math/simd_quat.d`: `SimdQuaternion` (multiply, conjugate, normalize(Est), `fromVectors`,
      `fromAxisAngle`, `transformVector`).
- [ ] `math/soa.d`: SoA arithmetic, `lerp`, `nlerp(Est)`, `dot`, `normalize(Est)`,
      `SoaFloat4x4.fromAffine`, `transpose16x16` (SoA → 4 AoS matrices).
- [ ] `math/half.d`: `floatToHalf` / `halfToFloat` (scalar and 4-wide), matching upstream bit
      behavior (denormals, infinities, NaN).
- Upstream tests ported: `vec_float_tests`, `quaternion_tests`, `transform_tests`, `box_tests`,
  `math_ex_tests`, `simd_float_math_tests`, `simd_int_math_tests`, `simd_float4x4_tests`,
  `simd_quaternion_math_tests`, `simd_math_transpose_tests`, `soa_float_tests`,
  `soa_quaternion_tests`, `soa_float4x4_tests`, `soa_transform_tests` (reachable subset).

**DoD:** all math tests green on the reference backend under DMD; `isPod!SoaTransform`;
`Float4x4.sizeof == Mat4.sizeof` and layout-equality test.

### OZ-2 — Vector SIMD Backend

- [ ] `math/simd_vec.d` implementing the same API with `core.simd`.
- [ ] Backend selection in `math/simd.d`; `version(EngineAnimScalarMath)` forces the reference
      backend (useful for debugging and for platforms without SIMD).
- [ ] Differential test: for every function, 10⁴ randomized inputs, vector vs reference backend,
      exact for bitwise/integer ops, tolerance for estimates.
- [ ] Verify codegen with LDC (`-O3 -mcpu=native`, `--output-s`) for the hot functions
      (`nlerpEst`, `fromAffine`, `transpose16x16`, `halfToFloat`): no scalarization, no calls.

**DoD:** all OZ-1 tests pass on both backends with DMD and LDC; DMD build of the vector backend
compiles on x86_64.

### OZ-3 — IO: Endianness, InputArchive, Group-Varint

- [ ] `io/endian.d`: native endianness detection (compile-time `version(LittleEndian)`), swap for
      `u16/i16/u32/i32/f32`, in-place array swap.
- [ ] `io/archive.d`: `InputArchive` over `const(ubyte)[]` (the whole file is read once with
      `std.file.read` at asset-load time). Reads the endianness byte; `readTag!T`,
      `peekTag!T` (non-consuming), `readVersion`, primitives, raw arrays into pre-carved slices,
      with bounds-checked cursor and error state (`ok`, `errorMessage`, `offset`).
- [ ] `io/math_archive.d`: loaders for `SoaTransform`, `Float3`, `Float4`, `Quaternion`, `Transform`.
- [ ] `io/group_varint.d`: `decodeGV4` / `decodeGV4Stream`. **Upstream reads 4 bytes unaligned at
      each value and relies on buffer padding**; the D version reads exactly `k + 1` bytes per
      value so it is bounds-safe even on the last group.
- Upstream tests ported: `endianness_tests`, `math_archive_tests`, `soa_math_archive_tests`,
  `simd_math_archive_tests` (load side), `io/archive_tests` and `io/stream_tests` (read side),
  `encode/group_varint_tests` (decode side, using encoded vectors produced by the golden harness).

**DoD:** archive reader round-trips all primitive fixtures in both endiannesses; GV4 decode matches
golden vectors; malformed-input tests (truncation at every byte offset of a small fixture) fail
cleanly without range errors escaping.

### OZ-4 — Skeleton

- [ ] `skeleton.d`: `Skeleton` (`numJoints`, `numSoaJoints`, `jointRestPoses`, `jointParents`,
      `jointName(i)`, `kMaxJoints = 1024`, `kMaxSoAJoints = 256`, `kNoParent = -1`) and
      `loadSkeleton(ref InputArchive, out Skeleton) → bool` with the §4.4 validation.
- [ ] `skeleton_utils.d`: `findJoint(name)`, `isLeaf`, `iterateJointsDF(skeleton, fn, from)`,
      `iterateJointsDFReverse`, `getJointRestPoseLocalSpace`, `getRestPoseModelSpace` (into a
      caller-provided `Mat4[]`, not a returned vector — no allocation).
- [ ] Optional `StringId` per joint (interned in the asset's `StringTable`) for O(1)
      name lookup from gameplay code.
- Upstream tests ported: `skeleton_archive_tests`, `skeleton_archive_versioning_tests`,
  `skeleton_utils_tests` (with fixtures in place of `SkeletonBuilder`).

**DoD:** all vendored skeletons load; rest-pose model matrices match golden fixtures.

### OZ-5 — Animation Clip (Compressed Keyframes)

- [ ] `keyframe.d`: `Float3Key { ushort[3] values; }`, `QuaternionKey { ushort[3] values; }`,
      `kMaxPreviousOffset = 65535`, `pack`/`unpack` bit layout (2 bits largest index, 1 bit sign,
      3 × 15 bits components, packed across 48 bits exactly as upstream).
- [ ] `clip.d`: `Animation` with `duration`, `numTracks`, `numSoaTracks`, `name`, `timepoints`,
      `KeyframesCtrl` (`ratios` as raw bytes + `ratioWidth`, `previouses`, `iframeEntries`,
      `iframeDesc`, `iframeInterval`) for translations / rotations / scales, and value arrays.
      `loadAnimation(ref InputArchive, out Animation) → bool` reading v7 only, single-block
      allocation, §4.4 validation.
- [ ] Each `Animation` gets a process-unique `ulong uid` (atomic counter at load). The sampling
      context keys its cache on `uid` instead of upstream's raw address, which removes the
      documented "address reused after delete/new" hazard (`SamplingJob::Context::Invalidate`).
- [ ] `clip_utils.d`: `countTranslationKeyframes`, `countRotationKeyframes`, `countScaleKeyframes`.
- Upstream tests ported: `animation_archive_tests`, `animation_archive_versioning_tests`
  (v7 LE + BE accepted, v6 rejected with error), `animation_utils_tests`.

**DoD:** all vendored animations load in both endiannesses; key counts per track match golden
values; `size()` reports the same byte count as upstream.

### OZ-6 — SamplingJob and Context

The core of the runtime. Port `sampling_job.cc` faithfully; the algorithm is subtle.

- [ ] `SamplingContext` (upstream `SamplingJob::Context`): `resize(maxTracks)`, `invalidate()`,
      `maxTracks`, `maxSoaTracks`; single block holding, in this order (alignment-descending):
      `InterpSoaFloat3[maxSoa]` (translations), `InterpSoaQuaternion[maxSoa]`, `InterpSoaFloat3[maxSoa]`
      (scales), `uint[maxTracks] × 3` cache entries, `ubyte[(maxSoa + 7) / 8] × 3` outdated bits.
      Allocated at character spawn, never in the frame path.
- [ ] `SamplingJob { float ratio; const(Animation)* animation; SamplingContext* context;
      SoaTransform[] output; bool validate(); bool run(); }`.
- [ ] Algorithm steps (per component: translations, rotations, scales):
  1. Clamp `ratio` to `[0, 1]`; `step()` the context (invalidate on clip change), get previous ratio.
  2. **UpdateCache:** if the cache is empty or `|ratio − previous| > iframeInterval / 2`, seek:
     with iframes, pick `iframe = int(0.5 + ratio / iframeInterval)` and restore cache entries
     from the GV4-compressed snapshot (`iframe_desc[2*(i-1)]` = offset,
     `iframe_desc[2*(i-1)+1]` = last key index → `next = that + 1`); without iframes, reset to the
     initial keys (`entries[i] = i + numTracks`, `next = 2 * numTracks`) when seeking backward.
     Mark all SoA entries outdated.
  3. Walk **forward**: while `timepoint(ratios[next − previouses[next]]) <= ratio`, find the track
     whose cached right key equals `next − previouses[next]` (`trackForward`, search starting at the
     last found track), set its outdated bit, advance its entry to `next`.
  4. Walk **backward**: while the key before `next` is beyond `ratio`, find its track
     (`trackBackward`), mark outdated, move its entry back by `previouses[entry]`.
  5. **Decompress** only outdated SoA groups: left key = `entry − previouses[entry]`, right key =
     `entry`; load the 4 key ratios through `timepoints[ratios[...]]` (u8 or u16 indices).
     Float3 keys: 4-wide `halfToFloat`. Quaternion keys: unpack, map components with
     `kCpntMapping = [[0,0,1,2],[0,0,1,2],[0,1,0,2],[0,1,2,0]]`, dequantize
     `c = k · (√2 / 32767) − √2/2`, mask out the largest component, restore it as
     `sqrt(1 − dot)` via `ww · rsqrtEst(ww)`, apply the stored sign bit.
  6. **Interpolate** `min(output.length, numSoaTracks)` groups:
     `alpha = (ratio − r0) · rcpEst(r1 − r0)`; translation/scale `lerp`, rotation `nlerpEst`.
- [ ] Output smaller than the animation: trailing tracks are not written; output larger: trailing
      `SoaTransform`s are left untouched (upstream contract, tested).
- Upstream tests ported: `sampling_job_tests` (all cases expressible with fixtures; builder-based
  cases are reproduced with harness-generated `.ozz` files).
- Golden tests: forward playback at 60 Hz, reverse playback, random seeks, seeks across
  iframe boundaries, ratio exactly 0 and 1, clip switching on the same context, `numTracks` not a
  multiple of 4.

**DoD:** all golden sampling fixtures match within tolerance (§9.3) on both backends; zero GC
allocations during `run()` (asserted with `GC.stats` delta in the test).

### OZ-7 — LocalToModelJob

- [ ] `LocalToModelJob { const(Skeleton)* skeleton; const(Mat4)* root; int from = kNoParent;
      int to = kMaxJoints; bool fromExcluded; const(SoaTransform)[] input; Mat4[] output; }`.
- [ ] Faithful port of the partial-hierarchy semantics: start at `max(from + fromExcluded, 0)`,
      continue while `i <= to` and `parents[i] >= from` (descendants of `from`, relying on
      depth-first order); build `SoaFloat4x4.fromAffine` per SoA group, `transpose16x16` to 4 AoS
      matrices, multiply by the parent (or `root`, default identity).
- Upstream tests ported: `local_to_model_job_tests` (largest file; covers `from`/`to`/excluded).

**DoD:** golden model-space matrices match for all vendored skeleton/clip pairs; partial updates
(`from`/`to`) produce identical results to full updates for the affected joints.

### OZ-8 — BlendingJob (Normal, Partial, Additive)

- [ ] `BlendingJob.Layer { float weight; const(SoaTransform)[] transform; const(SimdFloat4)[] jointWeights; }`
      and `BlendingJob { float threshold = 0.1f; const(Layer)[] layers; const(Layer)[] additiveLayers;
      const(SoaTransform)[] restPose; SoaTransform[] output; }`.
- [ ] Passes, exactly as upstream:
  1. `blendLayers`: first pass multiplies, later passes accumulate; quaternions sign-corrected with
     `sign(dot(out, in))` before accumulation (shortest path); per-joint weights multiply the layer
     weight and accumulate into `accumulatedWeights[kMaxSoAJoints]`.
  2. `blendRestPose`: if accumulated weight `< threshold`, blend the rest pose with weight
     `threshold − accumulated` (globally or per joint for partial passes).
  3. `normalize`: divide translations/scales by the accumulated weight, `normalizeEst` rotations.
  4. `addLayers`: positive weight → `t += in.t · w`, `r = r · normalizeEst(lerp(identity, signFix(in.r), w))`,
     `s *= madd(in.s, w, 1 − w)`; negative weight → subtract (conjugate rotation, `rcpEst` scale).
     Note the multiplication order fixed in upstream 0.15.0 (#152) — port the current order.
- Upstream tests ported: `blending_job_tests`.

**DoD:** golden blend fixtures match (2-clip, 3-clip, partial upper-body mask, additive on/off,
negative additive weight, all-zero weights → rest pose).

### OZ-9 — User-Channel Tracks

- [ ] `track.d`: `Track!T` for `float`, `Float2`, `Float3`, `Float4`, `Quaternion` with `ratios`,
      `values`, `steps` (bit-packed step flags), `name`; loaders for the five tags (version 1).
- [ ] `TrackPolicy!T`: `lerp` (`nlerp` for quaternions), `distance`, `identity`.
- [ ] `track_sampling.d`: `TrackSamplingJob!T { float ratio; const(Track!T)* track; T* result; }`
      (binary search on ratios, honour step keys).
- [ ] `track_triggering.d`: `TrackTriggeringJob { float from, to, threshold; const(FloatTrack)* track; }`
      exposing `edges()` → `@nogc` input range of `Edge { float ratio; bool rising; }`, supporting
      `from > to` (backward playback) and multi-loop spans (`|to − from| > 1`), like the upstream
      iterator. `track_triggering_job_trait` helpers become range algorithms.
- Upstream tests ported: `track_archive_tests`, `track_sampling_job_tests`,
  `track_triggering_job_tests`, `track_triggering_job_trait_tests`.

**DoD:** `robot_track_grasp.ozz` loads; golden sampling and edge lists match exactly (edge ratios
within 1e-6).

### OZ-10 — Inverse Kinematics

- [ ] `IKTwoBoneJob`: target, midAxis, poleVector, twistAngle, soften, weight, start/mid/end joint
      model matrices; outputs start/mid joint corrections and `reached`. Port the 0.17.0 NaN guard
      in target softening.
- [ ] `IKAimJob`: target, forward, offset, up, poleVector, twistAngle, weight, joint matrix;
      outputs joint correction and `reached`.
- [ ] Helper documented in `engine.animation.ik`: applying corrections back to local-space
      `SoaTransform`s and re-running `LocalToModelJob` from the corrected joint (the upstream
      `two_bone_ik` / `look_at` / `foot_ik` sample pattern), so gameplay code does not reimplement it.
- Upstream tests ported: `ik_two_bone_job_tests`, `ik_aim_job_tests`.

**DoD:** golden IK fixtures (reachable, unreachable, soften < 1, weight < 1, twist, degenerate
pole/target) match within tolerance.

### OZ-11 — MotionBlendingJob (Root Motion)

- [ ] `MotionBlendingJob.Layer { float weight; const(Transform)* delta; }`,
      `MotionBlendingJob { const(Layer)[] layers; Transform* output; }`.
- [ ] Root-motion tracks are plain `Float3Track` / `QuaternionTrack` produced by `*2ozz` motion
      extraction; document the playback accumulation pattern (sample delta between previous and
      current ratio, handle loop wrap) as a helper.
- Upstream tests ported: `motion_blending_job_tests`.

**DoD:** golden motion-blend fixtures match; a looping clip accumulates the same displacement as
upstream over 10 loops.

### OZ-12 — SkinningJob (CPU)

- [ ] `SkinningJob` with positions/normals/tangents, strides in bytes, `influencesCount` 1–N with
      specialized paths for 1, 2, 3, 4 influences (upstream generates them with macros; D uses
      `static foreach` / template specialization), optional inverse-transpose matrices for normals.
- [ ] Used as: reference for validating the GPU skinning shader, CPU fallback, and physics/picking
      on skinned meshes. The primary rendering path remains GPU skinning (plan-animation AN-4).
- Upstream tests ported: `skinning_job_tests`.

**DoD:** golden skinning fixtures match; strided input from an interleaved engine vertex buffer is
tested.

### OZ-13 — Engine Integration

- [ ] **Assets:** `.ozz` importer in `engine.project` `AssetDatabase` (GUID + `.meta`), producing
      `SkeletonAsset` / `AnimationAsset` / `TrackAsset` entries in engine-owned stores with
      `Handle!` references and generation checks. Hot-reload: reloading an `.ozz` replaces the asset
      under the same handle and invalidates contexts by `uid`.
- [ ] **Skin binding:** glTF loader extension for `JOINTS_0` / `WEIGHTS_0` / `inverseBindMatrices`
      (plan-animation AN-2 mesh half) and a `SkinBinding { Handle!SkeletonAsset; remap table;
      inverse binds }` built by matching glTF joint node names to skeleton joint names; mismatches
      are reported at load.
- [ ] **POD components** (all pass `isPod`):

      ```d
      struct AnimSkeleton  { Handle!SkeletonAssetTag skeleton; uint poseSlot; }
      struct AnimPlayback  { Handle!AnimationAssetTag clip; float time = 0; float speed = 1; bool loop = true; }
      struct AnimBlend2    { Handle!AnimationAssetTag a, b; float weight = 0; float timeA = 0, timeB = 0; }
      struct AnimAdditive  { Handle!AnimationAssetTag clip; float weight = 0; float time = 0; }
      struct AnimLookAt    { uint headJoint; Vec3 target; float weight = 1; }
      ```

- [ ] **PosePool:** per-character `Pod!SoaTransform[]` locals (one per layer + output),
      `Pod!Mat4[]` model matrices, `Pod!Mat4[]` skinning palette, and a `SamplingContext` per
      layer, indexed by `poseSlot`. Allocated on spawn, recycled on despawn.
- [ ] **Systems** (frame path, `@nogc`): `advancePlaybackSystem` → `sampleSystem` →
      `blendSystem` → `ikSystem` → `localToModelSystem` → `skinPaletteSystem`
      (`model[remap[j]] * inverseBind[j]`) → GPU upload (AN-4). Each character is independent,
      which makes this the first natural workload for [plan-parallel-ecs.md](plan-parallel-ecs.md).
- [ ] **Devtools:** draw skeletons with `engine.devtools.gizmos` (bone lines + joint axes), and an
      overlay line with sampled characters / ms.
- [ ] **Demo:** `dub run --config=anim` — loads an upstream-converted character, plays idle/walk
      blend driven by keyboard, optional look-at IK on the head.
- [ ] **Editor:** inspector fields for the components above; optional "Import with gltf2ozz"
      action calling the external tool when present on `PATH`.

**DoD:** `dub run --config=anim -- --headless-frames=600 --assert-no-gc` passes;
`dub run --config=lint` passes; skeleton gizmos visually match the upstream sample viewer for the
same asset.

### OZ-14 — Performance Pass and Documentation

- [ ] Benchmark executable `dub run --config=anim-bench --build=release --compiler=ldc2`:
      N ∈ {1, 100, 1000} characters on the `ruby` and `pab` skeletons, measuring sampling,
      blending (3 layers), local-to-model, and skinning palette separately; same scenarios in the
      golden C++ harness for comparison (same machine, same data, clang `-O3`).
- [ ] Profile-guided micro-optimizations only where measurements show gaps: `@trusted` unchecked
      indexing in decompress/interpolate/L2M inner loops (relying on §4.4), `pragma(inline, true)`
      on SoA helpers, avoiding struct return copies in DMD-hostile patterns.
- [ ] Write `docs/animation-guide.md` (user-facing: pipeline, components, systems, IK, root
      motion, tracks/events) and update [plan-animation.md](plan-animation.md) and
      [roadmap.md](roadmap.md) status.

**DoD:** §10 targets met (or deviations documented with measurements); docs merged.

---

## 8. Phase Dependency Graph

```
OZ-0 ─► OZ-1 ─► OZ-2 ─────────────────────────────────────────────► OZ-14
          │                                                            ▲
          └─► OZ-3 ─► OZ-4 ─► OZ-5 ─► OZ-6 ─► OZ-7 ─► OZ-8 ─► OZ-13 ───┘
                        │                       │        ▲
                        │                       ├─► OZ-10┤
                        │                       └─► OZ-12┤
                        └─► OZ-9 ─► OZ-11 ───────────────┘
```

OZ-2 (vector backend) can proceed in parallel with OZ-3…OZ-9 because every job is written against
the backend-neutral API; jobs are first validated on the reference backend.

---

## 9. Testing Strategy

### 9.1 Ported upstream unit tests

Upstream runtime tests total ~7.9 kLOC in `test/animation/runtime` plus the `test/base/maths`,
`test/base/io`, `test/base/encode`, and `test/geometry/runtime` suites. They are ported as D
`unittest` blocks in the corresponding module (or a sibling `*_test.d` module when large). Many
upstream tests build their inputs with offline builders (`RawAnimation` → `AnimationBuilder`);
those inputs are instead generated by the golden harness as `.ozz` fixtures, keeping the offline
code out of the D tree.

### 9.2 Differential (golden) tests against upstream C++

The harness in `tools/ozz/golden/` is the oracle. Every job has at least one golden test using
real production-like data (vendored `media/bin` assets), not only synthetic cases.

### 9.3 Tolerance policy

| Quantity | Same backend as upstream (x86 vector) | Other backends |
|:---|:---|:---|
| Decoded keys (half → float, quaternion unpack pre-normalization) | bit-exact | bit-exact |
| Sampled translation / scale | 1e-6 relative | 1e-5 relative |
| Sampled rotation (component-wise, sign-normalized) | 1e-6 | 2e-4 (estimate precision) |
| Model-space matrices | 1e-5 relative | 5e-4 relative |
| IK corrections (angle) | 1e-5 rad | 1e-3 rad |
| Track edges (ratio) | 1e-6 | 1e-6 |

### 9.4 Robustness tests

- Truncation at every byte offset and random bit flips on small fixtures: loaders must return
  `false` with a message, never trigger a `RangeError`/assert.
- Jobs with invalid inputs (null pointers, undersized outputs, context too small, mismatched
  rest-pose sizes) return `false` like upstream `Validate()`.
- GC assertion: a test harness runs 10⁴ frames of the full pipeline and asserts zero GC
  allocations (`GC.stats().allocatedInCurrentThread` delta == 0).

---

## 10. Performance Targets

Measured with LDC2 release (`-O3 -mcpu=native`, bounds checks as shipped) vs upstream C++ built
with clang `-O3 -msse4.1` at the pinned commit, same machine, same assets, single thread.

| Workload | Target (D / C++) |
|:---|:---|
| `SamplingJob` sequential playback (60 Hz steps), ruby clip | ≤ 1.25× |
| `SamplingJob` random seeks with iframes | ≤ 1.25× |
| `BlendingJob` 3 layers + 1 additive | ≤ 1.15× |
| `LocalToModelJob` full skeleton | ≤ 1.15× |
| `SkinningJob` 4 influences, positions + normals | ≤ 1.25× |
| Full pipeline, 1000 characters | ≤ 1.25×, zero GC allocations, no frame > 16.6 ms caused by animation |

DMD builds have functional targets only (correctness, zero GC), consistent with `AGENTS.md`.

---

## 11. Risks and Mitigations

| Risk | Impact | Mitigation |
|:---|:---|:---|
| DMD `core.simd` gaps (no vector compares/shuffles via operators, weak inlining) | DMD build fails or is very slow | `__simd(XMM.*)` intrinsics in the DMD branch; reference backend fallback; perf targets on LDC only |
| Estimate instruction differences across ISAs | Golden mismatches on ARM | Tolerance policy §9.3; bit-exact only for decode steps |
| Subtle sampling-cache bugs (forward/backward walk, iframe seek) | Popping, wrong poses only on some seeks | Faithful line-by-line port of `UpdateCache`; golden tests with seek patterns; assertions of the upstream invariants kept in debug builds |
| Upstream format change (Animation v8) | New `*2ozz` output unreadable | Pin upstream commit; pin `*2ozz` binaries in `tools/ozz/`; versioned loader with explicit error |
| Bounds checks in `@safe` hot loops | Misses perf target | Load-time validation (§4.4) enables narrowly-scoped `@trusted` unchecked access in OZ-14, measured |
| `SoaTransform` (vector fields) rejected by `isPod` / `Pod!T` | Cannot store poses in `Pod!` pools | Verify in OZ-1 (`static assert`); extend `engine.core.pod` if `__vector` types are misclassified |
| glTF ↔ ozz joint order / naming mismatch | Garbled skinning | Name-based remap built and validated at load; report missing joints |
| Coordinate convention mismatch (handedness, units) | Mirrored or scaled characters | Verify once in OZ-13 with a known asset; document conversion in `animation-guide.md` |
| Dependency on external C++ tools for content | Friction for users | Document `tools/ozz/import.sh`; consider a pure-D minimal builder as a separate future plan |

---

## 12. Open Decisions

1. **Vendored `*2ozz` binaries vs build script.** Recommendation: a script that builds the pinned
   upstream tools into `tools/ozz/bin/` on demand (no binaries in git).
2. **`engine.math` reuse depth.** Recommendation: alias scalar types (`Vec3`, `Quat`, `Mat4`) and
   add `Transform`; keep SIMD/SoA types private to `engine.animation.math` until another subsystem
   needs them.
3. **Thread model for OZ-13.** Recommendation: serial first; per-character jobs are embarrassingly
   parallel and should be the pilot workload of the parallel ECS plan.
4. **`iframe_interval` in the documented `*2ozz` config** (upstream `reference.json` default: `10`;
   `0` disables iframes). Recommendation: start with the upstream default and tune with the
   random-seek benchmark in OZ-14, trading archive size against seek cost.

---

## 13. Acceptance Criteria

1. `.ozz` archives produced by upstream `gltf2ozz`/`fbx2ozz` at the pinned commit load in the
   engine (skeleton v2, animation v7, all five track types, both endiannesses).
2. Every ported job matches the upstream C++ golden fixtures within §9.3 tolerances on DMD and LDC.
3. All modules are `@safe:`; jobs are `pure nothrow @nogc`; no GC allocation in the frame path
   (`--assert-no-gc` passes in the `anim` demo).
4. ECS components are POD; resources are referenced through `Handle!`; `dub run --config=lint` passes.
5. LDC release performance meets §10 or documents measured deviations.
6. No new dub dependencies; no C/C++ code in the engine build.

---

## 14. References

- Upstream repository: <https://github.com/guillaumeblanc/ozz-animation> (commit `744eb9d`, v0.17.0)
- Upstream documentation: <https://guillaumeblanc.github.io/ozz-animation/documentation/>
- Upstream changelog — notably 0.15.0 (indexed timepoints, previous-key offsets, iframes, GV4,
  additive order fix), 0.16.0 (`MotionBlendingJob`), 0.17.0 (IK NaN guard, default-initialized math types)
- [plan-animation.md](plan-animation.md) — engine-level skeletal animation plan (AN-1…AN-5)
- [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) — `Pod!T`, `Handle!T`, `StringId`, `FrameArena`
- [plan-parallel-ecs.md](plan-parallel-ecs.md) — future parallel execution of per-character jobs
- [jph-port-plan.md](jph-port-plan.md) — lessons from the cancelled Jolt port (measure D vs C++ performance early, which is why OZ-2 and OZ-14 set explicit LDC targets)
