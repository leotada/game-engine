#!/bin/sh
# Scalar (MESHOPTIMIZER_NO_SIMD) codec archive for byte-exact oracle diffs.
# The default libs/libmeshoptimizer_ref.a is built by build_ref.sh and uses
# SSE2 filter kernels; 8-bit octahedral decode there is an rsqrt approximation.
# This archive is the SIMD_FALLBACK reference. Both are gitignored (*.a).
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
SRC="$ROOT/ref/meshoptimizer/src"
OBJ="$ROOT/libs/meshopt-codec-scalar-obj"
if ! command -v clang++ >/dev/null 2>&1; then
    echo "clang++ is not installed" >&2
    exit 1
fi
mkdir -p "$OBJ" "$ROOT/libs"
rm -f "$OBJ"/*.o
for f in indexcodec vertexcodec vertexfilter; do
    clang++ -O2 -ffp-contract=off -DMESHOPTIMIZER_NO_SIMD -I"$SRC" -c -o "$OBJ/$f.o" "$SRC/$f.cpp"
done
ar rcs "$ROOT/libs/libmeshoptimizer_codec_scalar.a" "$OBJ"/*.o
echo "built $ROOT/libs/libmeshoptimizer_codec_scalar.a"
