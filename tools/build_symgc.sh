#!/usr/bin/env bash
# tools/build_symgc.sh — Builds libsymgc-cards.a from vendor/symgc for multiplatform game-engine targets.
#
# Usage:
#   tools/build_symgc.sh [dmd|ldc2] [target-triple]
#
# Defaults:
#   Compiler: $DC or dmd
#   Target: host (e.g. linux-x86_64)
#
# Flags used:
#   -version=Symgc_cards           Card-marking write barrier (512B cards)
#   -version=Symgc_druntime_hooks  Use core.memory.GC / core.thread hooks
#   -version=Symgc_druntime_cards  (DMD only) bind to druntime __sd_gc_card_* symbols

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_SRC="$ROOT_DIR/vendor/symgc/source"
LIBS_DIR="$ROOT_DIR/libs"

DC_BIN="${1:-${DC:-dmd}}"
TARGET="${2:-}"

# Detect OS and architecture
detect_target() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$os" in
        linux*) os="linux" ;;
        darwin*) os="macos" ;;
        msys*|mingw*|cygwin*) os="windows" ;;
    esac
    case "$arch" in
        x86_64|amd64) arch="x86_64" ;;
        aarch64|arm64) arch="arm64" ;;
    esac
    echo "${os}-${arch}"
}

HOST_TARGET="$(detect_target)"
if [[ -z "$TARGET" ]]; then
    TARGET="$HOST_TARGET"
fi

OUT_DIR="$LIBS_DIR/$TARGET"
mkdir -p "$OUT_DIR"
if [[ "$TARGET" == *"windows"* ]]; then
    OUT_LIB="$OUT_DIR/symgc-cards.lib"
else
    OUT_LIB="$OUT_DIR/libsymgc-cards.a"
fi

echo "=== Building steadygc (symgc) for $TARGET with $DC_BIN ==="
echo "Source: $VENDOR_SRC"
echo "Output: $OUT_LIB"

# Collect all source files
mapfile -t SOURCES < <(find "$VENDOR_SRC" -name "*.d")
if [[ ${#SOURCES[@]} -eq 0 ]]; then
    echo "Error: No D source files found in $VENDOR_SRC" >&2
    exit 1
fi

TMP_OBJDIR="$(mktemp -d -t symgc_build_XXXXXX)"
trap 'rm -rf "$TMP_OBJDIR"' EXIT

COMPILER_NAME="$(basename "$DC_BIN")"

case "$COMPILER_NAME" in
    ldc2|ldmd2*)
        EXTRA_FLAGS=(
            "-O3" "-release" "-oq" "-od=$TMP_OBJDIR"
            "-d-version=Symgc_cards"
            "-d-version=Symgc_druntime_hooks"
            "-I=$VENDOR_SRC"
        )
        if [[ "$TARGET" == *"windows"* ]]; then
            EXTRA_FLAGS+=("-mtriple=x86_64-pc-windows-msvc")
        else
            EXTRA_FLAGS+=("-fPIC")
            if [[ "$TARGET" == *"android"* ]]; then
                EXTRA_FLAGS+=("-mtriple=aarch64-linux-android28")
            elif [[ "$TARGET" == *"macos"* ]]; then
                EXTRA_FLAGS+=("-mtriple=arm64-apple-macos")
            fi
        fi
        echo "Building library with $DC_BIN: $OUT_LIB..."
        "$DC_BIN" -lib "-of=$OUT_LIB" "${EXTRA_FLAGS[@]}" "${SOURCES[@]}"
        ;;
    *)
        EXTRA_FLAGS=(
            "-O" "-release" "-inline" "-boundscheck=off" "-oq" "-od=$TMP_OBJDIR"
            "-version=Symgc_cards"
            "-version=Symgc_druntime_hooks"
            "-I=$VENDOR_SRC"
            "-fPIC"
        )
        echo "Building library with $DC_BIN: $OUT_LIB..."
        "$DC_BIN" -lib "-of=$OUT_LIB" "${EXTRA_FLAGS[@]}" "${SOURCES[@]}"
        ;;
esac

# Only update the host symlink when building for the current non-Windows host.
if [[ "$TARGET" == "$HOST_TARGET" && "$TARGET" != *"windows"* ]]; then
    ln -sf "$OUT_LIB" "$LIBS_DIR/libsymgc-cards.a"
fi

echo "=== Successfully built $OUT_LIB ($(du -h "$OUT_LIB" | cut -f1)) ==="
