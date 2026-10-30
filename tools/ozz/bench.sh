#!/bin/sh
# Builds and runs the animation benchmark with LDC (`dub --compiler=ldc2` cannot link this project:
# libs/libsymgc is built with DMD). Usage: tools/ozz/bench.sh [characters] [frames] [skeleton] [extra ldc flags]
# Example: tools/ozz/bench.sh 1000 300 ruby -boundscheck=off
set -e
cd "$(dirname "$0")/../.."
OUT=${TMPDIR:-/tmp}/game-engine-anim-bench
SRC="source/demo/anim_demo.d $(ls source/engine/animation/*.d source/engine/animation/io/*.d source/engine/animation/math/*.d source/engine/animation/ecs/*.d | grep -v 'testing.d\|golden_tests' | tr '\n' ' ') source/engine/math/vec.d source/engine/math/mat.d source/engine/math/quat.d source/engine/ecs/store.d source/engine/ecs/world.d source/engine/core/pod.d source/engine/reflect/attrs.d source/engine/core/handle.d source/engine/core/strings.d source/engine/graphics/types.d"
N=${1:-1000}; F=${2:-300}; S=${3:-pab}; shift 3 2>/dev/null || true
ldc2 -O3 -release -preview=dip1000 -Isource "$@" -of="$OUT" -od="${TMPDIR:-/tmp}" $SRC
"$OUT" --headless-frames="$F" --characters="$N" --skeleton="$S"
