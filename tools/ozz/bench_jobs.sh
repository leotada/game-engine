#!/bin/sh
# Job-level benchmarks (random-seek sampling, 3 layers + additive blending, skinning) with LDC.
# C++ counterpart: `golden_gen <media> <out> --bench-jobs` (build with clang++ -O3 -msse4.1).
set -e
cd "$(dirname "$0")/../.."
OUT=${TMPDIR:-/tmp}/game-engine-bench-jobs
SRC="tools/ozz/bench_jobs.d $(ls source/engine/animation/*.d source/engine/animation/io/*.d source/engine/animation/math/*.d source/engine/animation/ecs/*.d | grep -v 'testing.d\|golden_tests' | tr '\n' ' ') source/engine/math/vec.d source/engine/math/mat.d source/engine/math/quat.d source/engine/core/pod.d source/engine/core/handle.d source/engine/reflect/attrs.d source/engine/ecs/store.d source/engine/ecs/world.d source/engine/core/strings.d source/engine/graphics/types.d"
ldc2 -O3 -release -preview=dip1000 -Isource "$@" -of="$OUT" -od="${TMPDIR:-/tmp}" $SRC
"$OUT"
