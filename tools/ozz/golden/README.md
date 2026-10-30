# Golden harness for the D ozz-animation port

`golden.cc` links upstream ozz-animation (pinned at commit `744eb9d`, v0.17.0) and dumps reference
outputs that `source/engine/animation/golden_tests.d` compares the D port against. It is **not**
built by dub; the dumps are committed in `assets/animation/test/golden/`, so CI and normal builds
need no C++ toolchain.

## Regenerate

```sh
git clone https://github.com/guillaumeblanc/ozz-animation /tmp/ozz && git -C /tmp/ozz checkout 744eb9d
tools/ozz/golden/build.sh /tmp/ozz /tmp/golden_gen
/tmp/golden_gen assets/animation/test assets/animation/test/golden          # fixtures
/tmp/golden_gen assets/animation/test /tmp/golden-out --bench                # + C++ timings
```

## Contents (raw little-endian float32)

| File | What |
|:---|:---|
| `sampling_pab_walk.bin`, `sampling_pab_jog.bin` | `SoaTransform`s at 63 ratios: forward sweep, jumps, backward sweep, edge values (40 floats per SoA element) |
| `sampling_ruby.bin` | first 12 ratios of the 368-joint ruby clip |
| `blend_pab.bin` | walk/jog blended at weights 0, .3, .5, .8, 1 |
| `model_pab.bin` | model-space matrices of those blends (column-major) |
| `ik.bin` | two-bone IK (3 targets) and aim IK (2 targets) corrections on synthetic chains, plus `reached` |

Upstream is built with SSE4.2, i.e. `rcpps` / `rsqrtps` estimates. The DMD x86_64 vector backend
uses the same instructions and matches to 1e-5; backends with exact division (LDC, scalar) are
checked with a looser tolerance. See `golden_tests.d`.

`track_float3_walk.bin`, `track_float_grasp.bin` (41 ratios), `trigger_grasp.bin` (8 ranges incl. reversed and looping), `motion.bin` (4 weight cases), `skinning.bin` (64 vertices, 4 influences, positions/normals/tangents; inputs are stored in the file).

## Benchmark

`tools/ozz/bench.sh [characters] [frames] [pab|ruby] [ldc flags]` builds the D pipeline with LDC
and runs it; `golden_gen ... --bench` runs the same scenario (2-clip blend, continuous playback)
in C++ (g++ -O2 here).
