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

The shader-side twins of these functions are `waterWaveY` / `waterSurfaceY`
in `common/waves.wgsl` (see below).


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

## Shared GPU Water Data (`engine.water.gpu_data`)

Every scene-space shader can see the water through frame `@group(0)
@binding(10)` (`assets/shaders/common/waves.wgsl`). The binding holds up to
`MAX_WATER_BODIES` (4) bodies. Each body has XZ bounds, a rest level and its
own `WaveSet`, so a river and an ocean can coexist in one scene.

```d
import engine.water;

WaterSurfaceGpuParams surf;
surf.bounds = [-16, -16, 16, 16];  // minX, minZ, maxX, maxZ: cover every prop the water touches
surf.level = 0.0f;                 // rest water height (world Y)
surf.recentPeakScale = peak;       // storm wet marks dry out instead of vanishing
surf.contactChop = 1.38f;          // extra run-up where water hits props

GpuWaterData data;
data.add(packWaterBody(waves, surf));
scene.setTime(time);               // waves animate with the frame time
scene.setWaterData(data);          // zero bodies = no water anywhere
```

`WaterRenderer` (WP-3) fills this for you; call it directly only for custom
water rendering.

| `WaterSurfaceGpuParams` field | Meaning |
|:---|:---|
| `bounds` | World XZ rectangle where shaders treat fragments as "in this body" |
| `level` | Rest water height; waves are added on top |
| `recentPeakScale` | Largest amplitude scale reached recently (0 = current) |
| `contactChop` | Wave height multiplier used for wet marks on props (default 1.2) |
| `causticsStrength` | Caustics brightness on submerged surfaces (0 disables them) |
| `flowSpeed` | Caustics drift speed along the flow (m/s); 0 = slow ocean drift |
| `wetline` | Enable wave-contact wet marks |

### Wet marks on props

Set `MaterialFlags.waterWetCaustics` on materials that waves wash over (rocks,
piers, banks). Inside a body with `wetline = true`, the PBR shader evaluates
the body's waves at the fragment (`waterWaveY`, scaled by `contactChop`).
Surfaces the water reached in the last ~5 s stay wet and dry out over time.
Surfaces above the highest possible wave stay dry and matte. Outside every
body the flag has no effect.

## Sky reflection

The water surface reflects the engine sky and fades into it at the horizon
(`frameSky` from `common/sky_frame.wgsl`). Turn the sky on with
`scene.setSkyEnabled(true)`; sun, clouds (`setWeather`) and time of day drive
both the visible sky and the reflection. See the sky section of
[graphics.md](graphics.md).

## Demo

`dub run --config=water` (ocean) or `-- --river`. The demo currently builds
with LDC only (`--compiler=ldc2`); DMD 2.113 crashes compiling its legacy
pipeline setup (tracked in the port plan, fixed in WP-3).
`--capture=<file.bmp>` uses a fixed 1/60 s step, so captures are reproducible
pixel-for-pixel.
