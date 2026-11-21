#!/usr/bin/env bash
# tools/build_sdl3_deps.sh — Builds and stages static (and dev symlink) SDL3, SDL3_image,
# SDL3_ttf, FreeType, Box3D, and SymGC libraries into libs/<target>/.
#
# Usage:
#   tools/build_sdl3_deps.sh [target] [--stage-only]
#
# Targets:
#   linux-x86_64 (default)
#   linux-arm64
#   windows-x86_64
#   macos-arm64
#   macos-x86_64
#   web-wasm32

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REFS_DIR="$ROOT_DIR/ref/sdl3-deps"
LIBS_DIR="$ROOT_DIR/libs"

TARGET="linux-x86_64"
STAGE_ONLY=0

for arg in "$@"; do
    case "$arg" in
        --stage-only) STAGE_ONLY=1 ;;
        -h|--help)
            sed -n '2,15p' "${BASH_SOURCE[0]}"
            exit 0
            ;;
        *) TARGET="$arg" ;;
    esac
done

SDL3_TAG="${SDL3_TAG:-release-3.4.0}"
SDL3_IMAGE_TAG="${SDL3_IMAGE_TAG:-release-3.2.4}"
SDL3_TTF_TAG="${SDL3_TTF_TAG:-release-3.2.2}"
FREETYPE_TAG="${FREETYPE_TAG:-VER-2-13-3}"

OUT_DIR="$LIBS_DIR/$TARGET"
STAGE_PREFIX="$REFS_DIR/stage/$TARGET"
BUILD_ROOT="$REFS_DIR/build/$TARGET"

mkdir -p "$OUT_DIR" "$REFS_DIR" "$STAGE_PREFIX" "$BUILD_ROOT"

NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"

echo "=== Preparing dependencies for target: $TARGET ==="
echo "Output dir: $OUT_DIR"

# Stage pre-existing engine archives into target directory on host linux-x86_64
stage_host_libs() {
    if [[ "$TARGET" == "linux-x86_64" ]]; then
        for lib in libwgpu_native.a libbox3d.a librecast_shim.a; do
            if [[ -f "$LIBS_DIR/$lib" && ! -e "$OUT_DIR/$lib" ]]; then
                ln -sf "$LIBS_DIR/$lib" "$OUT_DIR/$lib"
            fi
        done
        if [[ -f "$OUT_DIR/libsymgc-cards.a" && ! -e "$LIBS_DIR/libsymgc-cards.a" ]]; then
            ln -sf "$OUT_DIR/libsymgc-cards.a" "$LIBS_DIR/libsymgc-cards.a"
        fi
        # Dev shared library symlinks when installed on system
        for pair in \
            "libSDL3.so:/usr/lib64/libSDL3.so.0" \
            "libSDL3_image.so:/usr/lib64/libSDL3_image.so.0" \
            "libSDL3_ttf.so:/usr/lib64/libSDL3_ttf.so.0" \
            "libSDL3.so:/usr/lib/x86_64-linux-gnu/libSDL3.so.0" \
            "libSDL3_image.so:/usr/lib/x86_64-linux-gnu/libSDL3_image.so.0" \
            "libSDL3_ttf.so:/usr/lib/x86_64-linux-gnu/libSDL3_ttf.so.0"
        do
            local name="${pair%%:*}"
            local sys="${pair#*:}"
            if [[ -e "$sys" && ! -e "$OUT_DIR/$name" ]]; then
                ln -sf "$sys" "$OUT_DIR/$name"
            fi
        done
    fi
}

stage_host_libs

if [[ "$STAGE_ONLY" -eq 1 ]]; then
    echo "=== Stage-only completed for $TARGET ==="
    exit 0
fi

clone_repo() {
    local url="$1"
    local tag="$2"
    local dir="$3"
    if [[ ! -d "$dir/.git" ]]; then
        echo "Cloning $url ($tag) -> $dir"
        git clone --depth 1 --branch "$tag" "$url" "$dir"
    fi
}

CMAKE_BIN="cmake"
CMAKE_GEN_ARGS=()
CMAKE_TARGET_ARGS=(
    "-DCMAKE_BUILD_TYPE=Release"
    "-DCMAKE_POSITION_INDEPENDENT_CODE=ON"
    "-DCMAKE_INSTALL_PREFIX=$STAGE_PREFIX"
    "-DCMAKE_INSTALL_LIBDIR=lib"
)

if command -v ninja >/dev/null 2>&1; then
    CMAKE_GEN_ARGS=("-G" "Ninja")
fi

case "$TARGET" in
    linux-x86_64)
        if command -v clang >/dev/null 2>&1 && command -v clang++ >/dev/null 2>&1; then
            CMAKE_TARGET_ARGS+=(
                "-DCMAKE_C_COMPILER=clang"
                "-DCMAKE_CXX_COMPILER=clang++"
            )
        fi
        ;;
    linux-arm64)
        CMAKE_TARGET_ARGS+=(
            "-DCMAKE_SYSTEM_NAME=Linux"
            "-DCMAKE_SYSTEM_PROCESSOR=aarch64"
        )
        if command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
            CMAKE_TARGET_ARGS+=(
                "-DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc"
                "-DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++"
            )
        elif command -v zig >/dev/null 2>&1; then
            CMAKE_TARGET_ARGS+=(
                "-DCMAKE_C_COMPILER=zig;cc;-target;aarch64-linux-gnu"
                "-DCMAKE_CXX_COMPILER=zig;c++;-target;aarch64-linux-gnu"
            )
        else
            echo "Error: linux-arm64 requires aarch64-linux-gnu-gcc or zig in PATH." >&2
            exit 1
        fi
        ;;
    windows-x86_64)
        CMAKE_TARGET_ARGS+=(
            "-DCMAKE_SYSTEM_NAME=Windows"
            "-DCMAKE_SYSTEM_PROCESSOR=AMD64"
        )
        if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
            CMAKE_TARGET_ARGS+=(
                "-DCMAKE_C_COMPILER=x86_64-w64-mingw32-gcc"
                "-DCMAKE_CXX_COMPILER=x86_64-w64-mingw32-g++"
                "-DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres"
            )
        elif command -v zig >/dev/null 2>&1; then
            CMAKE_TARGET_ARGS+=(
                "-DCMAKE_C_COMPILER=zig;cc;-target;x86_64-windows-msvc"
                "-DCMAKE_CXX_COMPILER=zig;c++;-target;x86_64-windows-msvc"
            )
        else
            echo "Error: windows-x86_64 cross-build requires zig or x86_64-w64-mingw32-gcc (or build natively on Windows)." >&2
            exit 1
        fi
        ;;
    macos-arm64|macos-x86_64)
        local_arch="${TARGET#macos-}"
        [[ "$local_arch" == "arm64" ]] && darwin_arch="arm64" || darwin_arch="x86_64"
        CMAKE_TARGET_ARGS+=(
            "-DCMAKE_SYSTEM_NAME=Darwin"
            "-DCMAKE_OSX_ARCHITECTURES=$darwin_arch"
        )
        if [[ "$(uname -s)" != "Darwin" ]]; then
            if command -v zig >/dev/null 2>&1; then
                CMAKE_TARGET_ARGS+=(
                    "-DCMAKE_C_COMPILER=zig;cc;-target;${darwin_arch}-macos"
                    "-DCMAKE_CXX_COMPILER=zig;c++;-target;${darwin_arch}-macos"
                )
            else
                echo "Error: macOS cross-build from Linux requires osxcross or zig (or run on macOS)." >&2
                exit 1
            fi
        fi
        ;;
    web-wasm32)
        if ! command -v emcmake >/dev/null 2>&1; then
            echo "Error: web-wasm32 requires Emscripten SDK (emcmake / emcc) in PATH." >&2
            exit 1
        fi
        CMAKE_BIN="emcmake cmake"
        CMAKE_TARGET_ARGS=(
            "-DCMAKE_BUILD_TYPE=Release"
            "-DCMAKE_INSTALL_PREFIX=$STAGE_PREFIX"
            "-DCMAKE_INSTALL_LIBDIR=lib"
        )
        ;;
    *)
        echo "Error: unsupported target '$TARGET'" >&2
        exit 1
        ;;
esac

SDL_SRC="$REFS_DIR/SDL"
IMG_SRC="$REFS_DIR/SDL_image"
TTF_SRC="$REFS_DIR/SDL_ttf"
FT_SRC="$REFS_DIR/freetype"

clone_repo "https://github.com/libsdl-org/SDL.git" "$SDL3_TAG" "$SDL_SRC"
clone_repo "https://github.com/libsdl-org/SDL_image.git" "$SDL3_IMAGE_TAG" "$IMG_SRC"
clone_repo "https://github.com/freetype/freetype.git" "$FREETYPE_TAG" "$FT_SRC"
clone_repo "https://github.com/libsdl-org/SDL_ttf.git" "$SDL3_TTF_TAG" "$TTF_SRC"

# 1. Build static SDL3
echo "--- [1/4] Building static SDL3 ($SDL3_TAG) ---"
SDL_EXTRA_FLAGS=()
if [[ "$TARGET" == "linux-"* ]]; then
    # Keep SDL3 dynamic runtime loading for X11/Wayland/PipeWire/Pulse/ALSA so final
    # binaries have zero hard .so dependencies beyond glibc.
    SDL_EXTRA_FLAGS+=(
        "-DSDL_X11_SHARED=ON"
        "-DSDL_WAYLAND_SHARED=ON"
        "-DSDL_PIPEWIRE_SHARED=ON"
        "-DSDL_PULSEAUDIO_SHARED=ON"
        "-DSDL_ALSA_SHARED=ON"
        "-DSDL_LIBUDEV=OFF"
    )
fi

$CMAKE_BIN -S "$SDL_SRC" -B "$BUILD_ROOT/sdl3" "${CMAKE_GEN_ARGS[@]}" "${CMAKE_TARGET_ARGS[@]}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSDL_STATIC=ON \
    -DSDL_SHARED=OFF \
    -DSDL_TESTS=OFF \
    -DSDL_EXAMPLES=OFF \
    -DSDL_TEST_LIBRARY=OFF \
    "${SDL_EXTRA_FLAGS[@]}"
cmake --build "$BUILD_ROOT/sdl3" -j"$NPROC"
cmake --install "$BUILD_ROOT/sdl3"

# 2. Build static FreeType 2 (minimal zero-external-dep configuration)
echo "--- [2/4] Building static FreeType ($FREETYPE_TAG) ---"
$CMAKE_BIN -S "$FT_SRC" -B "$BUILD_ROOT/freetype" "${CMAKE_GEN_ARGS[@]}" "${CMAKE_TARGET_ARGS[@]}" \
    -DBUILD_SHARED_LIBS=OFF \
    -DFT_DISABLE_ZLIB=ON \
    -DFT_DISABLE_BZIP2=ON \
    -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_HARFBUZZ=ON \
    -DFT_DISABLE_BROTLI=ON
cmake --build "$BUILD_ROOT/freetype" -j"$NPROC"
cmake --install "$BUILD_ROOT/freetype"

# 3. Build static SDL3_image (stb backend + QOI + SVG + BMP + TGA + GIF)
echo "--- [3/4] Building static SDL3_image ($SDL3_IMAGE_TAG) ---"
$CMAKE_BIN -S "$IMG_SRC" -B "$BUILD_ROOT/sdl3_image" "${CMAKE_GEN_ARGS[@]}" "${CMAKE_TARGET_ARGS[@]}" \
    -DCMAKE_PREFIX_PATH="$STAGE_PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSDLIMAGE_VENDORED=OFF \
    -DSDLIMAGE_BACKEND_STB=ON \
    -DSDLIMAGE_SVG=ON \
    -DSDLIMAGE_QOI=ON \
    -DSDLIMAGE_BMP=ON \
    -DSDLIMAGE_GIF=ON \
    -DSDLIMAGE_JPG=ON \
    -DSDLIMAGE_LBM=ON \
    -DSDLIMAGE_PCX=ON \
    -DSDLIMAGE_PNG=ON \
    -DSDLIMAGE_PNM=ON \
    -DSDLIMAGE_TGA=ON \
    -DSDLIMAGE_XCF=ON \
    -DSDLIMAGE_XPM=ON \
    -DSDLIMAGE_XV=ON \
    -DSDLIMAGE_AVIF=OFF \
    -DSDLIMAGE_JXL=OFF \
    -DSDLIMAGE_TIF=OFF \
    -DSDLIMAGE_WEBP=OFF \
    -DSDLIMAGE_SAMPLES=OFF \
    -DSDLIMAGE_TESTS=OFF
cmake --build "$BUILD_ROOT/sdl3_image" -j"$NPROC"
cmake --install "$BUILD_ROOT/sdl3_image"

# 4. Build static SDL3_ttf against staged SDL3 + FreeType
echo "--- [4/4] Building static SDL3_ttf ($SDL3_TTF_TAG) ---"
FT_STATIC_LIB="$STAGE_PREFIX/lib/libfreetype.a"
[[ -f "$STAGE_PREFIX/lib/freetype.lib" ]] && FT_STATIC_LIB="$STAGE_PREFIX/lib/freetype.lib"

$CMAKE_BIN -S "$TTF_SRC" -B "$BUILD_ROOT/sdl3_ttf" "${CMAKE_GEN_ARGS[@]}" "${CMAKE_TARGET_ARGS[@]}" \
    -DCMAKE_PREFIX_PATH="$STAGE_PREFIX" \
    -DBUILD_SHARED_LIBS=OFF \
    -DSDLTTF_VENDORED=OFF \
    -DSDLTTF_HARFBUZZ=OFF \
    -DSDLTTF_PLUTOSVG=OFF \
    -DSDLTTF_SAMPLES=OFF \
    -DFREETYPE_INCLUDE_DIRS="$STAGE_PREFIX/include/freetype2" \
    -DFREETYPE_LIBRARY="$FT_STATIC_LIB"
cmake --build "$BUILD_ROOT/sdl3_ttf" -j"$NPROC"
cmake --install "$BUILD_ROOT/sdl3_ttf"

# Copy built static libraries into libs/<target>/
for f in \
    libSDL3.a libSDL3_image.a libSDL3_ttf.a libfreetype.a \
    SDL3-static.lib SDL3_image-static.lib SDL3_ttf-static.lib freetype.lib
do
    if [[ -f "$STAGE_PREFIX/lib/$f" ]]; then
        cp -f "$STAGE_PREFIX/lib/$f" "$OUT_DIR/$f"
    fi
done

# Cross-compile Box3D if building a non-host target
if [[ "$TARGET" != "linux-x86_64" && -d "$ROOT_DIR/vendor/box3d" ]]; then
    echo "--- Building static Box3D for $TARGET ---"
    $CMAKE_BIN -S "$ROOT_DIR/vendor/box3d" -B "$BUILD_ROOT/box3d" "${CMAKE_GEN_ARGS[@]}" "${CMAKE_TARGET_ARGS[@]}" \
        -DBUILD_SHARED_LIBS=OFF \
        -DBOX3D_SAMPLES=OFF \
        -DBOX3D_BENCHMARKS=OFF \
        -DBOX3D_DOCS=OFF \
        -DBOX3D_UNIT_TESTS=OFF
    cmake --build "$BUILD_ROOT/box3d" -j"$NPROC"
    find "$BUILD_ROOT/box3d" -maxdepth 3 \( -name "libbox3d.a" -o -name "box3d.lib" \) -exec cp -f {} "$OUT_DIR/" \;
fi

# Build static recast_shim (recastnavigation + fastlz + C shim) if vendored
build_recast_shim() {
    local recast_dir="$ROOT_DIR/vendor/recastnavigation"
    local shim_dir="$ROOT_DIR/source/bindings/recast"
    if [[ ! -d "$recast_dir" || ! -f "$shim_dir/recast_shim.cpp" ]]; then
        return 0
    fi
    if [[ "$TARGET" != "linux-x86_64" && "$TARGET" != "linux-arm64" && "$TARGET" != "macos-arm64" && "$TARGET" != "macos-x86_64" ]]; then
        echo "--- Skipping recast_shim auto-build for $TARGET (use target toolchain CMake/MSVC) ---"
        return 0
    fi
    local obj_dir="$BUILD_ROOT/recast_shim"
    mkdir -p "$obj_dir"
    local cxx="${CXX:-g++}"
    local cc="${CC:-gcc}"
    local ar="${AR:-ar}"
    echo "--- Building static librecast_shim.a for $TARGET ---"
    for f in \
        "$recast_dir/Recast/Source/"*.cpp \
        "$recast_dir/Detour/Source/"*.cpp \
        "$recast_dir/DetourTileCache/Source/"*.cpp \
        "$recast_dir/DetourCrowd/Source/"*.cpp \
        "$shim_dir/recast_shim.cpp"
    do
        local obj="$obj_dir/$(basename "${f%.cpp}").o"
        "$cxx" -std=c++11 -O2 -fPIC -DDT_POLYREF64 \
            -I"$recast_dir/Recast/Include" \
            -I"$recast_dir/Detour/Include" \
            -I"$recast_dir/DetourTileCache/Include" \
            -I"$recast_dir/DetourCrowd/Include" \
            -I"$recast_dir/RecastDemo/Contrib/fastlz" \
            -I"$shim_dir" \
            -c "$f" -o "$obj"
    done
    "$cc" -O2 -fPIC -c "$recast_dir/RecastDemo/Contrib/fastlz/fastlz.c" -o "$obj_dir/fastlz.o"
    "$ar" rcs "$OUT_DIR/librecast_shim.a" "$obj_dir/"*.o
    if [[ "$TARGET" == "linux-x86_64" ]]; then
        ln -sf "$OUT_DIR/librecast_shim.a" "$LIBS_DIR/librecast_shim.a"
    fi
}

build_recast_shim

stage_host_libs

echo "=== Built libraries in $OUT_DIR ==="
ls -lh "$OUT_DIR"
