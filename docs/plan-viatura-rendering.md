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
| E9 | Soft, lit particles with an animated atlas | — | planned |
| E10 | BC7 / BC5 textures, conversion tool, RGBA8 fallback | Memory and load time measured | planned |
| E13 | Minimum 1 px width for thin geometry, per material | No sorted alpha if possible | planned |
| S1 | Round, soft stars instead of hard-edged voxels | — | done |
| E14 | GPU occlusion culling (Hi-Z, two-phase), after E11, main view only | Same image on/off, counter, measured gain | planned |

## Delivery order

Foundation (bindings, `MaterialParams` block, `render-check`), then wave 1 (S1, E1, E12, E2, E11),
wave 2 (E3, E4, E5, E7), wave 3 (E6, E8, E9, E10) and wave 4 (E13, E14).
