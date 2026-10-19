#!/bin/bash
# Build the paced engine GC benchmark as TWO separate binaries.
# Linking symgc into the druntime binary makes the conservative GC scan
# symgc's static data; comparisons must use separate links.
#
#   bench/engine_gc_build.sh [OUT_DIR]
#
#   DC=dmd|ldc2   compiler (default: project DMD 2.113 if present, else dmd)
#   SYMGC=DIR     collector source (default ../source)
#   EXTRA="..."   extra flags
#
# Writes OUT_DIR/gcb_druntime and OUT_DIR/gcb_steady.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SYMGC=${SYMGC:-$HERE/../source}
OUT=${1:-$HERE/../.bench-out}
mkdir -p "$OUT"

if [ -z "${DC:-}" ]; then
	if [ -x /home/leonardo/Projetos/dmd/generated/linux/release/64/dmd ]; then
		DC=/home/leonardo/Projetos/dmd/generated/linux/release/64/dmd
	else
		DC=dmd
	fi
fi

CORE=(
	"$HERE/engine_core/pod.d"
	"$HERE/engine_core/handle.d"
	"$HERE/engine_core/strings.d"
	"$HERE/engine_core/arena.d"
	"$HERE/engine_core/attrs.d"
)
PROG="$HERE/engine_gc_benchmark.d"

case $(basename "$DC") in
	ldc2|ldmd2*)
		# Prefer the project's LDC with FrameStats if DC was left as bare ldc2.
		FLAGS=(-O3 -release -I"$HERE" ${EXTRA:-})
		$DC "${FLAGS[@]}" -of="$OUT/gcb_druntime" "$PROG" "${CORE[@]}"
		$DC "${FLAGS[@]}" -d-version=Symgc_druntime_hooks -d-version=SymGC \
			-I"$SYMGC" \
			-of="$OUT/gcb_steady" "$PROG" "${CORE[@]}" $(find "$SYMGC" -name '*.d')
		;;
	*)
		FLAGS=(-O -release -inline -preview=dip1000 -I"$HERE" ${EXTRA:-})
		$DC "${FLAGS[@]}" -of="$OUT/gcb_druntime" "$PROG" "${CORE[@]}"
		$DC "${FLAGS[@]}" -version=Symgc_druntime_hooks -version=SymGC \
			-I"$SYMGC" \
			-of="$OUT/gcb_steady" "$PROG" "${CORE[@]}" $(find "$SYMGC" -name '*.d')
		;;
esac
rm -f "$OUT/gcb_druntime.o" "$OUT/gcb_steady.o"
echo "built $OUT/gcb_druntime and $OUT/gcb_steady with DC=$DC"
