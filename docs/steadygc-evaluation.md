# steadygc evaluation

[steadygc](https://github.com/leotada/symgc) (branch `main`, vendored in `vendor/symgc`) is a druntime plug-in
collector: allocator without a global lock, mark and sweep beside the program. This page records how it is wired into
the engine and what it measured against druntime's GC on the engine's own `gc_benchmark`.

## How it is wired

- `vendor/symgc` — git submodule, pinned to a commit of `leotada/symgc` `main`.
- `dub.json` — the `game`, `golf` and `gc-benchmark` configs depend on `symgc`; `versions-linux-x86_64` defines
  `SteadyGC`. dub has no per-platform `dependencies`, which is why the dependency is per config.
- `engine.core.gc` — `mixin UseSteadyGC;` in an executable's main module imports `symgc.gcobj` and sets
  `rt_options = ["gcopt=gc:sdcq"]`. It is empty without `version(SteadyGC)`, and lives in a mixin so a library module
  never forces the collector on programs that link the engine.
- Back to druntime's GC with the same binary: `--DRT-gcopt=gc:conservative`. Check which one runs:
  `--DRT-gcopt=gc:sdc` prints `using SYM GC!`.
- Build in `--build=release`: dub compiles the collector with the project's flags.

## Method

DMD 2.113.0 and LDC 1.43.0, Linux 6.18 (Firecracker VM), 4 cores, 15 GB. Medians of 5 runs unless noted.
`gc_benchmark` `default` mode, `precise:1` for druntime. Linked against stub SDL3/wgpu libraries because the
benchmark does not call them (the `gc-benchmark` config links the whole engine).

- **Unpaced** is the benchmark as committed: frames run back to back.
- **Paced** is a scratch copy that sleeps to the 60 Hz deadline after each frame (like vsync) and records work time
  only; it is not committed. Concurrent collectors need the idle time that vsync gives a real game.

`GC.profileStats().maxPauseTime` is not used below: it includes the harness's own explicit `GC.collect()` calls,
which are stop-the-world with a synchronous sweep in steadygc (~8 ms even on an empty heap).

## Results: the engine's gc_benchmark (live heap 11-64 MB)

Frame work time in ms. `>16.7` counts frames over budget, summed over the 5 runs of 600 frames.

| Scenario | Build | GC | mean | p99 | worst frame | >16.7 | peak RSS MB |
|---|---|---|---|---|---|---|---|
| worst-safe | DMD unpaced | druntime | 1.96 | 3.59 | 9.4 | - | 64 |
| worst-safe | DMD unpaced | steadygc | 2.11 | 3.71 | 10.0 | - | 69 |
| worst | DMD unpaced | druntime | 4.17 | 11.4 | 14.7 | - | 102 |
| worst | DMD unpaced | steadygc | 8.32 | 15.4 | 20.4 | - | 110 |
| openworld | DMD unpaced | druntime | 0.45 | 0.89 | 2.1 | - | 76 |
| openworld | DMD unpaced | steadygc | 0.85 | 2.42 | 3.6 | - | 72 |
| worst-safe | DMD paced | druntime / steadygc | 2.69 / 2.49 | 5.5 / 4.8 | 9.7 / 10.2 | 0 / 1 | 46 / 54 |
| worst | DMD paced | druntime / steadygc | 5.23 / 9.49 | 12.3 / 15.9 | 15.8 / 21.3 | 1 / 27 | 93 / 98 |
| openworld | DMD paced | druntime / steadygc | 0.59 / 0.96 | 1.3 / 2.1 | 3.3 / 4.4 | 0 / 0 | 74 / 46 |
| worst-safe | LDC paced | druntime / steadygc | 2.84 / 2.92 | 5.1 / 4.9 | 9.6 / 10.0 | 0 / 0 | 46 / 45 |
| worst | LDC paced | druntime / steadygc | 4.62 / 6.23 | 13.2 / 11.1 | 15.4 / 16.5 | 0 / 2 | 93 / 87 |
| openworld | LDC paced | druntime / steadygc | 0.49 / 0.70 | 1.1 / 1.5 | 1.8 / 2.7 | 0 / 0 | 54 / 36 |

On these workloads steadygc does not shorten the worst frame, and the frame itself usually costs more (0.9-1.9x the mean, worst in `--worst` and `--openworld`).
The `--worst` scenario shows lower total pause with steadygc (80-110 ms against 140-165 ms over 600 frames) but a
median frame about twice as long; STW mark, one mark thread and a 100% sweep duty (`SYMGC_*`) left that unchanged,
so the extra cost is in the mutator (allocation and pointer stores), not in the concurrent collection. The cause was
not isolated. The fork's own README gives single-thread allocation throughput at 0.79x of druntime's and a
fragmentation-heavy load at 0.54x.

The `--worst-safe` layout (`Pod!T`, `Handle!T`, `StringId`, `FrameArena`) is equal under both collectors: with a
disciplined heap the choice of collector barely matters.

## Results: the fork's bullet_hell_stress (2 GiB level, 100k bullets/s, 30 s at 60 fps)

`vendor/symgc/bench/compare.sh bullet_hell_stress.d 30 2048 100000 0.05 256`, one run each.

| Compiler | Collector | p99.9 frame | worst frame | >16 ms of 1800 | peak RSS MB |
|---|---|---|---|---|---|
| DMD | druntime | 164 ms | 166 ms | 4 | 4311 |
| DMD | steadygc, STW mark | 37 ms | 50 ms | 2 | 2921 |
| DMD | steadygc, concurrent | 10.6 ms | 10.6 ms | 0 | 2929 |
| LDC | druntime | 185 ms | 206 ms | 4 | 4311 |
| LDC | steadygc, STW mark | 18 ms | 19 ms | 2 | 2916 |
| LDC | steadygc, concurrent | 10.0 ms | 11.9 ms | 0 | 2895 |

This reproduces the shape of the fork's claim (about 16x lower worst frame, no missed frame, a third less memory) on a
4-core VM; the absolute worst frame is higher than the 0.9-1.3 ms published for the fork's 8-core machine.

## Reading

steadygc pays off when the live heap is large (GBs) and a stop-the-world mark would stall a frame. The engine's
benchmarks keep tens of MB live, where druntime's pauses are 7-10 ms and the allocator's speed matters more. Decide
with a heap and allocation rate like the real game's; the knob is `--DRT-gcopt=gc:sdcq` against
`--DRT-gcopt=gc:conservative` on the same binary.

Not measured: the real demos (`game`, `golf`) — this environment has no GPU or display; SDL3/wgpu/Box3D callbacks under
the collector; Windows; the card-barrier setups (custom LDC/DMD).
