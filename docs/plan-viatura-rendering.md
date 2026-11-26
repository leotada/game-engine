# Rendering requests from Viatura VI (E1–E14, S1)

Two inbox messages from the external game Viatura VI (2026-11-24) asked for the renderer
features below. This file keeps the requests and their status.

## Constraints

- No TAA, no MSAA, no temporal accumulation of images.
- Features are generic, opt-in and can be turned off. Other projects keep their image and cost.
  S1 fixes a visual defect and is the only default change.
- Each item ships with tests, docs, a CHANGELOG entry and CPU + GPU profiler zones for new passes.
- An item that is not viable or too expensive is reported with numbers, not shipped half done.
- Game budget: 12 ms average at 1080p. Baseline at 1600x900 (release, RX 6600): 6.67 ms frame,
  4.43 ms GPU, 1,043 scene draws (860 static), 927 shadow draws, `renderer.submit` 2.17 ms.

## Requests, in priority order

| Item | Request | Acceptance | Status |
|---|---|---|---|
| E1 | sRGB color textures (`Texture`, `TextureArray`, terrain, glTF), mips averaged in linear | Unlit sRGB grey 128 with linear tone map returns 128 | done |
| E12 | Quality FXAA (edge search, subpixel blend) and adaptive sharpening after any AA mode | Sharper high-contrast texture, fewer steps, timings | done |
| E2 | Alpha mask in color and shadows (skinned, static, `displaceEx`), coverage-preserving mips, glTF `MASK` | No cost for opaque users | done |
| E11 | GPU culling and indirect draws for `StaticInstanceBuffer`, scene and shadows | Same image, much lower submit, no dropped instance | done |
| E3 | Depth, normals (or documented reconstruction), camera matrices and intermediate targets in `addPass` | — | done |
| E4 | GTAO applied to ambient light only, half-resolution option | — | done |
| E5 | SMAA 1x and CMAA2 modes, specular antialiasing, license check | — | done |
| E6 | Volumetric light: sun with cascades, clustered spots and points | — | done |
| E7 | Optional vertex color (glTF `COLOR_0`): static, instanced, skinned | No larger vertex for other meshes | done |
| E8 | Auto exposure and 3D color LUT | Only the exposure value persists between frames | done |
| E9 | Soft, lit particles with an animated atlas | — | done |
| E10 | BC7 / BC5 textures, conversion tool, RGBA8 fallback | Memory and load time measured | done |
| E13 | Minimum 1 px width for thin geometry, per material | No sorted alpha if possible | done |
| S1 | Round, soft stars instead of hard-edged voxels | — | done |
| E14 | GPU occlusion culling (Hi-Z, two-phase), after E11, main view only | Same image on/off, counter, measured gain | not included: measured cost above the gain (numbers in graphics.md) |

## Delivery order

Foundation (bindings, `MaterialParams` block, `render-check`), then wave 1 (S1, E1, E12, E2, E11),
wave 2 (E3, E4, E5, E7), wave 3 (E6, E8, E9, E10) and wave 4 (E13, E14).

## Final measurements in the game

Game copy, release (LDC), RX 6600, headless compositor, `city` benchmark script, 600 frames, one run per row (frame times
vary by about 0.3 ms between runs). Frame is the average, with the GPU frame from timestamps. Budget: 12 ms at 1080p.

| Setting | Frame 1080p | GPU 1080p | Frame 900p | GPU 900p |
|:---|:---|:---|:---|:---|
| All off (two runs) | 7.24 to 7.42 ms | 4.99 to 5.06 ms | 7.04 to 7.29 ms | 4.33 to 4.78 ms |
| `gpuCull` (E11) | 6.81 ms | 5.13 ms | 6.88 ms | 4.39 ms |
| `fxaaQuality` (E12) | 7.36 ms | 5.09 ms | 7.35 ms | 4.61 ms |
| Sharpening 0.5 (E12) | 7.35 ms | 5.12 ms | 7.44 ms | 5.07 ms |
| `smaa` (E5) | 7.28 ms | 5.14 ms | 7.38 ms | 4.81 ms |
| `cmaa2` (E5) | 7.71 ms | 5.16 ms | 7.65 ms | 4.96 ms |
| AO medium, full / half (E4) | 7.56 / 7.75 ms | 6.11 / 5.61 ms | 7.66 / 7.56 ms | 5.38 / 4.93 ms |
| Volumetric medium, half / quarter (E6) | 7.59 / 7.43 ms | 5.90 / 5.40 ms | 7.48 / 7.29 ms | 4.93 / 4.67 ms |
| Auto exposure (E8) | 7.64 ms | 5.21 ms | 7.51 ms | 4.95 ms |
| Combined, AO half | 7.66 ms | 6.99 ms | 7.59 ms | 5.84 ms |
| Combined, AO full | 7.97 ms | 7.51 ms | 7.60 ms | 6.21 ms |

Combined: `gpuCull`, SMAA, sharpening, AO, half-resolution volumetric light, auto exposure, exact sRGB output, alpha mask on
foliage and soft particles. The foliage has no transparent texels and few particles are on screen, so the last two
cost nothing measurable here. E7, E9 (lit, flipbook), E10 and E13 need game content and were only measured in engine scenes.

With everything off, the engine before this work (c54cf83) and after it give the same game image (0 pixels differ) and the
same cost (four interleaved runs at 1080p: 7.07 to 7.41 against 7.17 to 7.36 ms; GPU 5.00 to 5.32 against 4.98 to 5.11 ms).

## Commits

| Item | Commits |
|:---|:---|
| Foundation | 1eac0ad, fd264f8, 08b4c55 |
| S1 | b012147 |
| E1 | b736e43 |
| E2 | a9dbf8f, 4842ea6, daf94c1 |
| E3 | 9380984, 491eef0, 434d2c9 |
| E4 | f32576b, a53b8b2, 54df578 |
| E5 | a2eecb4, f98182d, 74b97a5, f2e58ac |
| E6 | f8a2d1e, 0e0357a, 14ecce4 |
| E7 | cf1bc76, 964fbc5, 2ff5596 |
| E8 | 2490cbb, 5bcd064, a58e5c9, 72f6983 |
| E9 | d6add4d, b9e5f2a, 49405b3, a15cc9d |
| E10 | 4b77412, 4bb2cb8, 9ee82b3, 52be662, 5cf4fac |
| E11 | b8412a6, 8dd1f2d, fd86180, 52f0957, 86db433 |
| E12 | f72adac |
| E13 | b63b0e6, 34fe46e, 7f28ec2 |
| E14 | 275eb20 on `feat/hiz`, unmerged; numbers in ee4829c |

## Follow-up: tree cost

Requested after E14: make vegetation cost as little as possible for every engine user. Five changes on
`feat/tree-cost` (d8b4931 surface parameter pool, 90bd053 batched displaced shadow casters, 52665da closed-mesh
back faces, 10b5d13 thin-wall shadow tap, fc59b1e + f3693ef whole-object LOD, b6b1fe3 culling scan). The first four
are on by default with opt-outs; whole-object LOD needs the game to build its trees with it. Impostors are deferred
until requested. Game numbers and the API: `docs/graphics.md`, "Cheap trees and foliage".

## Deviations and open items

- **E13:** the optional expansion in shadow passes is not implemented.
- **E14:** built without history instead of two-phase, measured, not merged. Terrain was not an occluder. A later static
  analysis found defects in the branch (sphere-cube bounds, occluder selection before the frustum test, strict default
  `occluderPixels`) and ruled out the early-depth explanation first given. The ceiling in that game is small anyway
  (`docs/graphics.md`).
- **E5:** specular antialiasing is checked over five light angles, because one angle was unstable.
- **E11:** point and spot shadows stay on the CPU path; visible instance counts are not read back.
- **Not verified:** external KTX2 validator, a complete export with `.ktx2`, game timings of E7, E9 (lit, flipbook), E10 and E13.
- **Recommendation:** `smaa` over `cmaa2` (smaller error in `render-check`, cheaper CPU in the game).
