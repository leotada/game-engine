# Profiling: CPU zones, GPU pass timings and traces

The engine ships a native frame profiler (`engine.devtools.profiler`) and a GPU timestamp profiler
(`engine.gpu.gpu_profiler`). Together they break a frame down into hierarchical CPU zones, per-pass GPU
times and Box3D's own step profile, with percentiles and an optional Chrome/Perfetto trace.

## Quick start

```d
import engine.devtools.profiler;

enableProfiler(true);            // once, outside the frame loop (allocates ~1.2 MB of history)
startProfilerTrace();            // optional: record individual events for a trace file

while (app.running()) {
    // ... App.beginFrame / your systems / App.endFrame
    // App.endFrame calls profilerEndFrame() for you.
}

foreach (r; profilerReport())    // tree order, allocates: not per frame
    writefln("%*s%-40s %s mean %.3f p95 %.3f max %.3f calls %.1f", r.depth * 2, "", r.name, r.kind,
        r.meanMs, r.p95, r.maxMs, r.callsPerFrame);
std.file.write("trace.json", profilerTraceJson()); // open in https://ui.perfetto.dev
```

The profiler is **off by default**. While off, a zone costs one branch and the GPU profiler records
nothing. Everything on the frame path is `@nogc nothrow`.

## Concepts

| Kind | Source | When it is committed |
|---|---|---|
| `ZoneKind.cpu` | `profileZone!"name"()` scoped wall-clock timers | `profilerEndFrame()` (called by `App.endFrame`) |
| `ZoneKind.gpu` | timestamp pairs (`gpuScope`, `gpuFrameScope`, ...) | when the GPU frame's readback is mapped, 2-3 frames later |
| `ZoneKind.sample` | `profileSample!"name"(ms)` values pushed by code | `profilerEndFrame()` |

- **Names are compile-time strings.** Each call site resolves its zone id once (a thread-local static
  per template instance) and never allocates. Use dotted names (`scene.end.opaque`) for readability.
- **The tree** comes from nesting: a zone's parent is the zone open when its name is first seen. GPU
  scopes nest the same way under the root `gpu.frame`; samples are children of the open CPU zone.
- **Statistics per zone:** mean per frame (frames where the zone did not run count as 0), p50/p95/p99
  over the last `PROFILE_HISTORY` (600) frames, max, and calls per frame. `resetProfilerStats()`
  clears them (for example after a warm-up) without invalidating zone ids.
- **Per thread:** the state is thread-local. Zones opened on worker threads go to that thread's own
  (disabled by default) profiler.

## CPU zones

```d
void update() {
    auto z = profileZone!"mygame.ai"();       // closes at the end of the scope
    ...
}

auto a = profileZone!"mygame.phaseA"();
...
a.close();                                     // sequential phases in one scope (LIFO order)
auto b = profileZone!"mygame.phaseB"();
```

`profileSample!"mygame.pathfind"(ms)` adds a value you measured yourself (several calls per frame add up).

## GPU scopes

Available when the device was created with the timestamp features. `GpuContext` requests
`TimestampQuery`, `TimestampQueryInsideEncoders` and `TimestampQueryInsidePasses` when the adapter
has all three; `GpuContext.timestampsSupported()` and `gpuProfilerSupported()` report the result.
Set `ENGINE_NO_GPU_TIMESTAMPS=1` to opt out (tests the fallback: GPU calls become no-ops).

| API | Writes the timestamps on | Use it for |
|---|---|---|
| `gpuScope!"gpu.x"(encoder)` | the command encoder | work between passes (no pass may be open) |
| `gpuPassScope!"gpu.x"(pass)` / `gpuPassBegin` + `gpuPassEnd` | one render pass | segments of one pass; begin and end on the same pass object |
| `gpuComputeScope!"gpu.x"(pass)` / `gpuComputeBegin` + `gpuComputeEnd` | one compute pass | dispatches |
| `gpuFrameScope!"gpu.x"(frame)` | whatever is open on the `FrameContext` at each end (pass, else encoder) | scene code that may `suspendScenePass` / `resumeScenePass` in the middle (decals and water snapshot the opaque scene) |

Frame cycle (handled by `Renderer`):

1. `Renderer.beginFrame` → `gpuProfilerCollect()`: polls the device without blocking and commits every
   frame whose readback buffer is mapped.
2. Scopes write timestamps into one query set (up to `MAX_GPU_SCOPES` = 256 per frame; extra scopes are
   ignored).
3. `Renderer.endFrame` → `gpuProfilerResolve(encoder)` before finishing the encoder: resolve the queries
   and copy them into one of `GPU_READBACK_SLOTS` (4) mappable buffers. If all are still in flight the
   frame is skipped (`gpuProfilerDroppedFrames()`).
4. After submit → `gpuProfilerAfterSubmit()` maps that buffer asynchronously.

Scopes recorded on other encoders in the same frame (the water simulation, the IBL bake) use the same
query set and are resolved by the frame's main encoder.

`gpu.frame` is the **sum of the top-level scopes**: the measured GPU work of the frame. It excludes idle
gaps between submissions, so compare it to the CPU frame time to see which side limits the frame. Work
that no scope covers (pass load/store, clears) is not in it.

## What the engine instruments

| Area | CPU zones | GPU scopes |
|---|---|---|
| App / Renderer | `app.beginFrame` (`renderer.gpuReadback`), `app.resolvePost` (`renderer.acquire`, `renderer.post`, `post.autoExposure`, `post.fxaaQuality`, `post.smaa`, `post.cmaa2`, `post.sharpen`), `app.endFrame` (`renderer.submit`, `renderer.present`, `gc.frameSlack`), `renderer.snapshotOpaque`, root `frame` | `gpu.post` (`autoExposure`, `bloom`, `tonemap`, `fxaa`, `fxaaQuality`, `smaa` (`edges`, `weights`, `blend`), `cmaa2` (`edges`, `shapes`, `apply`, `copy`), `sharpen`, custom passes), `gpu.ui`, `gpu.snapshotOpaque`, `gpu.post.afterUi` |
| `Scene3DTextured` | `scene.begin`; `scene.shadows` (`lights`, `prepare`, `upload`, `casters`, `encode`); `scene.end` (`uniforms`, `clusterCull`, `skinUpload`, `prepare`, and per pass `opaque` / `ssr` / `alpha` / `additive` with `sort`, `batches`, `static`, `hooks`, `postHooks`, `sky`, `transparentHooks`) | `gpu.shadows` (`cascades`, `directional`, `points`, `spots`), `gpu.clusterCull`, `gpu.scene.<pass>` and the same segments |
| Static GPU culling | `scene.staticCull` | `gpu.staticCull` |
| Ambient occlusion | `scene.gtao` | `gpu.gtao` (`depth`, `ao`, `blur`, `composite`) |
| Volumetric light | `scene.volumetric` | `gpu.volumetric` (`march`, `blur`, `composite`) |
| Terrain / decals / water | `terrain.update`, `terrain.draw`, `decals.update`, `decals.draw`, `water.update`, `water.draw` | `gpu.terrain`, `gpu.decals`, `gpu.water`, `gpu.water.sim` |
| IBL | `ibl.bakeStep` | `gpu.ibl.bakeStep` |
| UI | `ui.flush` | (inside `gpu.ui`) |
| Physics | `physics.step` | `box3d.*` samples from `b3World_GetProfile` (`box3d.step` is Box3D's total; `constraints`, `integrate*`, `warmStart`, `solveImpulses`, ... nest inside `solve`) |

`renderer.submit` is CPU time: wgpu-native validates and records the Vulkan/Metal/DX12 commands at
submit, so a large value there means expensive command recording, not GPU work.

## Reports, overlay and traces

- `profilerReport()` returns `ZoneReport[]` (name, kind, id, parent, depth, mean/p50/p95/p99/max, calls
  per frame) in depth-first order. It allocates; call it outside the frame loop.
- `profilerVisit(dg, window)` walks the tree without allocating and gives the mean of the last `window`
  frames. `DebugOverlay.addProfiler(minMs)` uses it to print the tree in the overlay.
- `startProfilerTrace(maxEvents)` / `stopProfilerTrace()` / `profilerTraceJson()` produce Chrome Trace
  Event JSON: CPU zones on thread 1, GPU scopes on thread 2. GPU events are aligned to their frame's
  submit time, which is an approximation; their durations are exact.

## Costs and limits

- Disabled: one branch per zone or scope. Enabled: two `MonoTime` reads per CPU zone (tens of
  nanoseconds) and two timestamp writes per GPU scope. The readback poll (`renderer.gpuReadback`) is
  non-blocking.
- Timestamps written **inside** a render pass are approximate on some drivers (a child scope can read a
  little longer than its parent). Encoder-level timestamps (shadows, compute, post) are exact.
- GPU timings arrive 2-3 frames late; the last frames of a run may be missing from the statistics.
- The zone table holds `MAX_PROFILE_ZONES` (512) names; nesting is limited to `MAX_ZONE_DEPTH` (64).
  Overflows are counted in `profilerOverflow()`.
- Not available on WebAssembly (no native timestamp features); CPU zones still work.
