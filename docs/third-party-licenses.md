# Third-party licenses

## meshoptimizer

The mesh processing code under `source/engine/meshopt/` is a pure-D port of
[meshoptimizer](https://github.com/zeux/meshoptimizer) v1.3 (commit `9e1f07b`).
The upstream library is MIT licensed. The reference clone lives in gitignored
`ref/meshoptimizer/` and is never linked into the engine.

```
MIT License

Copyright (c) 2016-2026 Arseny Kapoulkine

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Test corpus

`assets/models/meshopt/pirate.obj` is upstream `demo/pirate.obj`.

```
Pirate by Clint Bellanger
https://opengameart.org/content/pirate
Distributed under CC-BY-SA 3.0
```

Procedural grid, sphere, torus, UV-seam, and soup meshes are generated in
tests and are not separate licensed assets. No scanned mesh is committed.

## SDL3, SDL3_image, and SDL3_ttf

Windowing, input, audio, image decoding (`SDL3_image` 3.2.4), and font
rasterization (`SDL3_ttf` 3.2.2) use SDL3 (`release-3.4.0`), distributed under
the zlib license (`ref/sdl3-deps/` is gitignored and built via
`tools/build_sdl3_deps.sh`):

```
Copyright (C) 1997-2025 Sam Lantinga <slouken@libsdl.org>

This software is provided 'as-is', without any express or implied
warranty.  In no event will the authors be held liable for any damages
arising from the use of this software.

Permission is granted to anyone to use this software for any purpose,
including commercial applications, and to alter it and redistribute it
freely, subject to the following restrictions:

1. The origin of this software must not be misrepresented; you must not
   claim that you wrote the original software. If you use this software
   in a product, an acknowledgment in the product documentation would be
   appreciated but is not required.
2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.
3. This notice may not be removed or altered from any source distribution.
```

## FreeType 2

Portions of this software are copyright © 1996-2025 The FreeType Project
(https://freetype.org). All rights reserved.

Font shaping, hinting, and SDF glyph generation via `SDL3_ttf` are backed by
FreeType 2 (`VER-2-13-3`), used under the **FreeType License (FTL)**
(`ref/sdl3-deps/freetype/docs/FTL.TXT`). Every exported game bundle must retain
this attribution alongside the distributed binary.

## stb_vorbis

OGG Vorbis compressed audio streaming (`vendor/stb/stb_vorbis.c`) is by
Sean Barrett / [nothings/stb](https://github.com/nothings/stb), dual-licensed
under **MIT** and **Public Domain (Unlicense)**.

## Recast Navigation & FastLZ

3D navigation mesh generation, pathfinding, dynamic `TileCache` obstacles, and
crowd local avoidance (`vendor/recastnavigation/`, `v1.6.0`) are provided by
[recastnavigation/recastnavigation](https://github.com/recastnavigation/recastnavigation)
under the **zlib license**.

The `TileCache` LZ77 compression helper (`vendor/recastnavigation/RecastDemo/Contrib/fastlz/`)
is **FastLZ** by Ariya Hidayat, licensed under the **MIT License**.

## zipd (zstd codec)

- Source: the author's `zipd` project (`packages/compressor`), a pure-D, `@safe` implementation of the Zstandard format
  (RFC 8878). The modules `zstd_*`, `errors`, `xxhash` and `bitreader` are vendored in `vendor/zipd/`, with one local
  addition (`scratch.d`, malloc-backed buffers) and local `@nogc`/`nothrow` changes: the GC scratch buffers of the
  upstream encoder/decoder were replaced by `malloc`, and the upstream unit tests were dropped from the copy (the
  engine tests the codec through `engine.assets.zstd`).
- License: the upstream `dub.sdl` declares BSL-1.0 while the repository `LICENSE` file is MIT; both are permissive and
  the project is owned by the engine author. The shipped text is `vendor/zipd/LICENSE`.
- Used by: `engine.assets.zstd` (chunk and pack compression). Replaces the former C zstd 1.5.7 (BSD-3-Clause), which
  is no longer vendored or linked.

## Post-processing algorithms

`assets/shaders/post_cas.wgsl` follows the formulation of AMD FidelityFX Contrast Adaptive Sharpening
(Copyright (c) 2019 Advanced Micro Devices, Inc., MIT license). `assets/shaders/post_fxaa_hq.wgsl` is an
independent implementation of the published FXAA 3.x description by Timothy Lottes; no NVIDIA source is included.

## SMAA

`assets/shaders/post_smaa.wgsl` is a WGSL port of [SMAA](https://github.com/iryoku/smaa) (`SMAA.hlsl`), and
`assets/shaders/smaa_tables.bin` holds its precomputed area (subtexture 0) and search tables. MIT license:

```
Copyright (C) 2013 Jorge Jimenez (jorge@iryoku.com)
Copyright (C) 2013 Jose I. Echevarria (joseignacioechevarria@gmail.com)
Copyright (C) 2013 Belen Masia (bmasia@unizar.es)
Copyright (C) 2013 Fernando Navarro (fernandn@microsoft.com)
Copyright (C) 2013 Diego Gutierrez (diegog@unizar.es)

Permission is hereby granted, free of charge, to any person obtaining a copy
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software. As clarification, there is no
requirement that the copyright notice and permission be included in binary
distributions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## CMAA2

`assets/shaders/post_cmaa2.wgsl` is a modified WGSL port of
[CMAA2](https://github.com/GameTechDev/CMAA2) v2.3 (`CMAA2.hlsl`), Copyright (c) 2018, Intel Corporation, Apache License 2.0
([full text](licenses/Apache-2.0.txt)). The file header lists the changes.
