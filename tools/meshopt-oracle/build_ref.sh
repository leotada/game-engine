#!/bin/sh
# Build the meshoptimizer v1.3 oracle. Output is gitignored (*.a, *.o).
# Never linked into library, editor, or player.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
SRC="$ROOT/ref/meshoptimizer/src"
OBJ="$ROOT/libs/meshopt-ref-obj"
if ! command -v clang++ >/dev/null 2>&1; then
    echo "clang++ is not installed; goldens cannot be regenerated" >&2
    exit 1
fi
mkdir -p "$OBJ" "$ROOT/libs"
rm -f "$OBJ"/*.o
for f in "$SRC"/*.cpp; do
    base=$(basename "$f" .cpp)
    clang++ -O2 -ffp-contract=off -DMESHOPTIMIZER_NO_WRAPPERS -I"$SRC" -c -o "$OBJ/$base.o" "$f"
done
clang++ -O2 -ffp-contract=off -DMESHOPTIMIZER_NO_WRAPPERS -I"$SRC" -c \
    -o "$OBJ/ref_api.o" "$ROOT/tools/meshopt-oracle/ref_api.cpp"
ar rcs "$ROOT/libs/libmeshoptimizer_ref.a" "$OBJ"/*.o
echo "built $ROOT/libs/libmeshoptimizer_ref.a"
