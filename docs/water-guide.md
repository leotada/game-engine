# Water Guide

> **Status:** being ported from `source/demo/water.d` into `engine.water` — see
> [plan-water-engine-port.md](plan-water-engine-port.md). Rendering, simulation,
> obstacles, caustics, gameplay queries and buoyancy are in the engine; wet
> material presets and the editor component follow.

`engine.water` is opt-in (not re-exported by `import engine;`):

```d
import engine.water;
```

## Quick Start

```d
import engine.water;

auto water = WaterRenderer.create(app.gpu, scene);
scope(exit) water.destroy();
water.attach(scene, app.renderer);       // registers the draw hook; keep all three at stable addresses

WaterBody body = WaterBody.ocean();      // or WaterBody.river()
body.level = 0.0f;
immutable id = water.addBody(body);      // up to 4 bodies

// Every frame, before app.beginFrame():
body.waves.amplitudeScale = storminess;  // tweak any field...
water.setBody(id, body);                 // ...and push it (no allocation)
water.setObstacles(id, rocks[]);         // optional: WaterObstacle(x, z, radius, strength)
water.update(camera, time);              // shared wave data + uniforms + simulation step
```

`update` also calls `scene.setTime(time)`, so the sky, the wetline and the
water all animate with the same clock. Turn on the engine sky
(`scene.setSkyEnabled(true)`) so the water has something to reflect.

## Water Bodies (`engine.water.water_body`)

`WaterBody` is a POD value (safe for ECS storage and scene files):

| Field | Meaning |
|:---|:---|
| `centerX`, `centerZ`, `halfExtent` | Square surface grid (m). Ocean bodies stretch the outer ring to 12× `halfExtent` (horizon skirt) |
| `level` | Rest water height (world Y) |
| `gridResolution` | Cells per side (2..254); change it with `setGridResolution` (rebuilds the mesh) |
| `style` | `WaterStyle.ocean` (skirt, swells, whitecaps, horizon haze) or `.river` (current along the channel, wakes, shore foam) |
| `waves` | `WaveSet` (see below); `waves.channel` also defines the river's center line |
| `optics` | `WaterOptics`: absorption, shallow/deep color, coat color, SSS tint, roughness, anisotropy (`.ocean()` / `.river()`) |
| `features` | `WaterFeature` bits: `refraction`, `ssr`, `transparent`, `simulation`, `openPbr`, `wetline` (default: all) |
| `flow`, `flowProfileWidth` | Surface current (m/s) and, for rivers, the half width of the current profile |
| `bedDepth` | Fallback water depth when refraction is off (no depth buffer) |
| `contactChop`, `recentPeakScale`, `causticsStrength`, `wetMargin` | Wet marks and caustics on props (see below) |

Presets: `WaterBody.ocean()` (14 m grid + skirt, navy optics) and
`WaterBody.river()` (channel along +X, ±4.5 m, 1.35 m/s current, clear
mineral optics, contact chop 1.38).

## Renderer (`engine.water.renderer`)

- **Draw order:** a `Scene3DTextured.addTransparentHook` after the sky. It
  takes one `Renderer.snapshotOpaque` (only when a body uses refraction or
  SSR), then draws every body with one pipeline. The surface writes depth.
- **Simulation:** with `WaterFeature.simulation`, each body has a 256²
  `rgba16float` ping-pong texture (short-wave slopes, advected foam, wakes)
  stepped by one compute dispatch per frame inside `update`.
- **Obstacles:** up to `MAX_WATER_OBSTACLES` (16) per body deflect the current,
  raise chop near them, and spawn contact rings and downstream wakes.
- **Cost:** about 3.7 ms for a full-screen ocean at 1280×720 with every
  feature on (GPU-bound; see the plan's benchmark table).
- **Not for the frame loop:** `addBody`, `setGridResolution` and `create`
  allocate. `setBody`, `setObstacles`, `update` and the draw are `@nogc`.

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

`WaterRenderer` fills this for you; call it directly only for custom
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

## Gameplay queries (`engine.water.query`)

The CPU evaluates the same waves the GPU draws, so gameplay agrees with
what the player sees:

```d
WaterSurfacePoint p;
if (water.surfaceAt(x, z, time, p)) {       // WaterRenderer: first body containing xz
    // p.height  world Y of the surface (level + waves)
    // p.normal  surface normal
    // p.current river current in m/s (zero for oceans)
}
float y = waterSurfaceHeight(body, x, z, time);   // one WaterBody
```

- `waterSurfaceAt(body, x, z, time, iterations = 3)` and
  `waterBodyContains(body, x, z)` work on a plain `WaterBody`, without a
  renderer. `WaterQuery { const(WaterBody)[] bodies; }` does the same lookup
  as the renderer over your own array (servers, tools, tests).
- `iterations` refines the horizontal Gerstner pullback: 1 matches the GPU
  wetline, 3 is accurate for gameplay.
- River current: `WaterBody.flow`, faster in the channel center and down to
  35% at `flowProfileWidth`. An ocean's `flow` only drifts foam and caustics.

## Buoyancy (`engine.water.buoyancy`)

Floating Box3D bodies are sampled by spherical probes in their local frame.
Each submerged probe gets Archimedes' force (density × gravity × submerged
volume, exact spherical cap) at its world point plus drag against the water's
relative velocity, so bodies bob, tilt with the slope and follow river
currents.

```d
auto probes = sphereProbes(0.425f);   // center + 4 ring probes, same volume
// every frame, before physics.step(dt):
applyBuoyancy(physics, bodyId, probes[],
    (float x, float z, ref WaterSurfacePoint p) => water.surfaceAt(x, z, time, p));
physics.step(dt);
```

- The body's density sets how deep it floats: 380 kg/m³ against fresh water
  (`BuoyancySettings.waterDensity = 1000`) floats about 40% submerged.
- `BuoyancySettings`: `waterDensity`, `linearDrag` and `verticalDrag` (1/s,
  scaled by the body mass).
- Use your own `BuoyancyProbe[]` for boats and crates (e.g. one probe per
  hull corner). `applyBuoyancy` returns the mean submerged fraction.
- The surface callback is `scope`, so the lambda does not allocate.

## Caustics

Anything under water is lit by animated sun caustics: PBR meshes
(`textured3d_pbr.wgsl`), terrain and decals (`common/simple_pbr.wgsl`). No
material flag or extra mesh is needed. A fragment gets caustics when it is
inside a body's bounds, at least 0.2 m below its `level`, facing up and in
sunlight. Brightness is `WaterBody.causticsStrength` (0.18 ocean, 0.09 river;
0 disables), scaled by the wave amplitude. Rivers scroll the pattern
downstream and fade it beyond the channel's half width. The pattern lives in
`assets/shaders/common/caustics.wgsl` (`waterCausticsAt`).

A seabed is just geometry: the water demo draws a flat PBR quad with a
procedural sand texture at Y = -1.15.

## Sky reflection

The water surface reflects the engine sky and fades into it at the horizon
(`frameSky` from `common/sky_frame.wgsl`). Turn the sky on with
`scene.setSkyEnabled(true)`; sun, clouds (`setWeather`) and time of day drive
both the visible sky and the reflection. See the sky section of
[graphics.md](graphics.md).

## Demo

`dub run --config=water` (ocean) or `-- --river`. Builds with DMD and LDC.

> **DMD gotcha:** using a CTFE-built shader `enum` (e.g.
> `waterSurfaceShaderSource`) directly inside a function makes DMD 2.113's
> backend overflow its stack. Copy it into a module-level
> `immutable string` first and pass that to `createShaderModule`.
`--capture=<file.bmp>` uses a fixed 1/60 s step, so captures are reproducible
pixel-for-pixel.
