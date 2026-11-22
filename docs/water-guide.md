# Water Guide

> **Status:** being ported from `source/demo/water.d` into `engine.water` — see
> [plan-water-engine-port.md](plan-water-engine-port.md). This guide documents
> what is already available from the engine; sections are added per phase.

`engine.water` is opt-in (not re-exported by `import engine;`):

```d
import engine.water;
```

## Wave Model (`engine.water.waves`)

Water uses a sum of directional **Gerstner waves**. A `WaveSet` is POD data
(safe for engine storage and GPU upload) with up to `MAX_WAVE_COMPONENTS` (8)
components and three optional modifiers.

```d
WaveSet waves = WaveSet.ocean();       // or WaveSet.river(), or build your own
waves.amplitudeScale = 1.75f;          // calm 0.35 / moderate 1 / stormy 1.75

// Rendering-style sample: displaced point of an undisplaced grid coordinate.
WaveSample s = sampleWaves(waves, x, z, time);
// s.position, s.normal, s.tangent, s.crest (foam/spray factor in [0, 1])

// Gameplay: water height above a world XZ.
float y = waveHeightAt(waves, x, z, time, 3);
```

### `WaveComponent`

| Field | Meaning |
|:---|:---|
| `dirX`, `dirZ` | Unit propagation direction on XZ |
| `wavelength` | Crest-to-crest distance (m, clamped to ≥ 0.1) |
| `amplitude` | Vertical amplitude (m) before `amplitudeScale` |
| `steepness` | Gerstner Q in [0, 1]; sharpens crests by moving points horizontally |
| `speedScale` | Multiplier on the deep-water phase speed `sqrt(g / k)` |

Keep `Σ steepness · k · amplitude` below 1, or the surface folds over itself
(the crest factor reports folding through the surface Jacobian).

### Modifiers

- **`WaveModulation`** — slow wave-group envelope (`groupBase`, `groupAmp0/1`)
  and phase warp (`warpAmp0/1`) that break the periodic look of a pure sum of
  sines. The default (`groupBase = 1`, everything else 0) disables both.
- **`WaveChannel`** — tapers amplitude away from a center line: scale 1 within
  `halfWidth`, falling linearly to `edgeScale` over `falloff` meters. Use it
  for rivers whose waves die out at the banks. `halfWidth <= 0` disables it.
- **`amplitudeScale`** — global runtime multiplier.

### Presets

| Preset | Components | Notes |
|:---|:---|:---|
| `WaveSet.ocean()` | 6, 9.5 m → 1.15 m | Open-ocean swell (Beaufort ~5 at scale 1), modulated |
| `WaveSet.river()` | 6, 4.4 m → 0.68 m, faster | Flows toward +X; channel taper from \|z\| = 4.5 m to 15% at 8 m |

### Choosing an evaluator

- `sampleWaves(set, x, z, t)` takes an **undisplaced** coordinate and returns
  where that surface point moved to. Use it to place things that ride the
  surface (it is what the water vertex shader does).
- `waveHeightAt(set, x, z, t, iterations)` takes a **world** XZ and returns
  the height of the water there. Gerstner waves move points sideways, so it
  undoes that displacement with fixed-point iterations. `iterations = 1`
  matches the GPU wetline exactly; 3–4 iterations are accurate to millimeters
  for typical steepness. Use it for buoyancy, splashes and "is under water"
  tests.

Both are `pure nothrow @nogc` and cheap (a few dozen `sin`/`cos` per call).

## Demo

`dub run --config=water` (ocean) or `-- --river`. The demo currently builds
with LDC only (`--compiler=ldc2`); DMD 2.113 crashes compiling its legacy
pipeline setup (tracked in the port plan, fixed in WP-3).
`--capture=<file.bmp>` uses a fixed 1/60 s step, so captures are reproducible
pixel-for-pixel.
