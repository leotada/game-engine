# Benchmarks

The short version. Every number here comes from one machine in one session (2026-10-12) and is reproducible with the
programs in [`bench/`](bench/README.md); [`guide/benchmarks.md`](guide/benchmarks.md) has the long version, with the
other tables and the history of each change.

## Setup

* AMD Ryzen 7 3800X (8 cores, 16 threads), 31 GiB RAM, openSUSE Leap 16, Linux 6.12.
* CPU frequency `powersave` / `power` (a performance setting would lower every frame time and not change the comparison).
* DMD 2.113-beta with `-O -release -inline`; LDC 1.43-git with `-O3 -release -gc-card-marking`, runtime built with the
  barrier.
* Games run at 60 fps. **Worst** is the longest frame of the run, **over 16 ms** counts the frames that missed 60 fps.
  Frame time is the game's own work plus whatever the collector costs it.

| Label | Collector | Write tracking |
|---|---|---|
| druntime GC | druntime's conservative GC (same binary, no `gcopt`) | — |
| upstream symgc | symgc before this work | — (stop-the-world) |
| steadygc, STW mark | this fork, `SYMGC_CONCURRENT_MARK=0` | none: the mark stops the program, the sweep does not |
| steadygc | this fork, concurrent mark | the kernel's dirty pages (Linux 6.7+) |
| steadygc, LDC + cards | this fork, concurrent mark | the compiler's card barrier |

## 1. A shooter with a lot of garbage

`bullet_hell_stress.d 30 <level MiB> 100000 0.05 256`: 100,000 bullets a second, each with a closure and 256 bytes of
garbage, a level of 2 or 8 GiB alive. 30 s, 1,800 frames.

| 2 GiB level | p50 | p99 | p99.9 | Worst | Over 16 ms | Peak memory |
|---|---|---|---|---|---|---|
| druntime GC | 0.18 ms | 0.70 ms | 138 ms | 139-141 ms | 4 | 4.4 GB |
| upstream symgc | 0.20 ms | 0.99 ms | 24.7 ms | 28.0 ms | 3 | 3.0 GB |
| steadygc, STW mark | 0.21 ms | 0.94 ms | 10.3 ms | 11.1 ms | 0 | 3.0 GB |
| **steadygc** | 0.22 ms | 0.98 ms | 1.1 ms | **1.2-1.3 ms** | 0 | 3.0 GB |
| **steadygc, LDC + cards** | 0.11 ms | 0.63 ms | 0.77 ms | **0.87 ms** | 0 | 3.0 GB |
| No collection at all | 0.18 ms | 0.80 ms | 0.97 ms | 0.98 ms | 0 | 4.8 GB, growing |

| 8 GiB level | p50 | p99.9 | Worst | Over 16 ms | Peak memory |
|---|---|---|---|---|---|
| druntime GC | 0.18 ms | 539 ms | 548 ms | 2 | 16.9 GB |
| upstream symgc | 0.20 ms | 1.25 ms | 63.6 ms | 1 | 10.9 GB |
| **steadygc** | 0.21 ms | 1.19 ms | **1.22 ms** | 0 | 11.3 GB |
| **steadygc, LDC + cards** | 0.11 ms | 0.84 ms | **0.84 ms** | 0 | 11.3 GB |

Under DMD, with no compiler change, the worst frame is within 0.3 ms of the game with no collector at 2 and at 8 GiB.
At 8 GiB a stop-the-world collector runs only once or twice in 30 s, so its p99.9 looks fine and its worst frame does
not: look at the worst frame.

## 2. Game models with six job threads

`aaa_sim.d <mode> 60 2048 6 0 <population>`: classes, closures, rebuilt arrays, associative arrays, strings, six job
threads, 2 GiB of assets, 60 s (3,600 frames).

**City builder, 500,000 citizens:**

| Collector | p50 | p99.9 | Worst | Over 16 ms | Peak memory |
|---|---|---|---|---|---|
| druntime GC | 9.1 ms | 131-152 ms | 137-193 ms | 37 | 3.0 GB |
| upstream symgc | 3.8 ms | 107-109 ms | 107-113 ms | 40 | 2.8 GB |
| steadygc, STW mark | 3.6 ms | 57.9 ms | 60.7 ms | 25 | 3.3 GB |
| **steadygc** | 4.3 ms | 8.6-8.9 ms | **9.7 ms** | 0 | 3.6 GB |
| **steadygc, LDC + cards** | 3.1 ms | 5.8 ms | **6.9 ms** | 0 | 3.1 GB |

**Other models** (DMD, one run each; median / p99.9 / worst / frames over 16 ms):

| Collector | City, 100,000 citizens | RTS, 4,000 units | Open world, streaming |
|---|---|---|---|
| druntime GC | 1.74 / 31.9 / 40.4 ms / 18 | 2.60 / 10.8 / 13.2 ms / 0 | 0.29 / 14.9 / 16.6 ms / 2 |
| upstream symgc | 1.12 / 45.0 / 48.5 ms / 14 | 2.21 / 33.5 / 36.9 ms / 14 | 0.29 / 0.64 / 14.1 ms / 0 |
| **steadygc** | 1.13 / 2.73 / 3.68 ms / 0 | 2.45 / 4.13 / 4.71 ms / 0 | 0.30 / 0.64 / 1.34 ms / 0 |

With several threads allocating, the allocator matters as much as the pauses: druntime's GC takes one lock for every
allocation. steadygc keeps every frame of every model under 10 ms. The price is memory (3.6 GB against 3.0 GB in the 500k
city), because the heap keeps growing while a cycle runs beside the program.

## 3. Allocation throughput

`gcb.d`, one binary with and without `gcopt`, medians of three (DMD):

| Workload | druntime GC | steadygc | Ratio |
|---|---|---|---|
| One thread allocating small objects | 19.6 M/s | 15.5 M/s | 0.79x |
| Eight threads | 4.2 M/s | 36.0 M/s | **8.6x** |
| Mixed sizes, long and short lives | 2.08 s, 1.00 GB | 3.83 s, 0.91 GB | 0.54x speed, 9% less memory |

One thread: druntime's GC is faster and keeps a much smaller heap (552 collections against 15). The fragmentation
workload is the weak spot, and where its time goes has not been measured yet.

## 4. The cost of the card barrier

Per store, pinned to one core, medians of five (`barrier_micro.d`, ns per operation):

| Store | No barrier | LDC barrier | DMD barrier (`-preview=gcbarrier`) |
|---|---|---|---|
| Class field | 0.58 | 1.30 | 1.30 |
| Array element | 0.14 | 0.49 | 1.29 (no flag: 0.28) |
| Four field stores in a row to one object | 0.68 each | — | 0.46 each (one shared barrier) |
| Copy of 1,024 pointers | 73 | 73 | — |

Stores of ints, to the stack and to globals cost nothing. On whole programs the barrier is lost in the noise: LDC with
cards has the lowest tail of all the setups, and DMD with the barrier matches DMD with the kernel tracker (stress 2 GiB
worst frame 1.14-1.40 ms against 1.14-1.27 ms; 500k city 7.6 ms against 9.8 ms) without needing Linux 6.7+. The price
shows in the median at large heaps (8 GiB: 304 against 214 µs).

## 5. A big scene full of pointers

`entity_init.d`: 10.3 million entities with eight pointer fields (1 GiB), a window of them rewritten every frame and new
ones allocated every frame, 60 fps, 60 s. Marking such a heap takes one to two seconds.

`entity_init.d 60 1024 20000 <entities created per frame> 60`, two runs each, DMD:

| Allocation | Worst frame | Over 16 ms (of 3,588) | Peak memory |
|---|---|---|---|
| 11 MB/s (2,000 entities a frame) | 4.7 and 7.1 ms | 0 and 0 | 1.44-1.47 GB |
| 115 MB/s (20,000 entities a frame) | 12.1 and 14.6 ms | 0 and 0 | 6.2-6.3 GB |

(The frames themselves take 2 to 6 ms; the worst is the frame the collector's work added to.) Before the mark's work
list was moved out of the heap, the same runs had a first collection that made the program wait 0.64 s, and 8 to 10
frames over 16 ms with a worst frame of 1.5 to 1.9 s at 115 MB/s (`guide/benchmarks.md`, "the growth was the mark's own
work list"). That is the kind of defect this benchmark exists to find: a bug that only shows with a big scene full of
pointers.

**Overload.** Run unpaced (`FPS=0`) and allocating 230 MB/s, the program rewrites its whole scene faster than the mark
can scan it, and any concurrent collector stalls: worst frame 3.8 s, 8.2 GB. That is a limit of the design, not a bug
to fix by tuning (`guide/how-it-works.md`).

## Not measured

* Windows, macOS, Android and Linux arm64 (the code compiles for the first, third and fourth; see `guide/platforms.md`).
* Soak runs of half an hour or more.
* A real game: the models are written to resemble one, and are not one.
* Other machines. A different CPU, core count or frequency setting moves every number here; compare the collectors on
  the same machine, with `bench/compare.sh`.

## 6. Small live heap, paced engine GC (2026-10-13)

`bench/engine_gc_compare.sh` (two binaries). 16-core Linux, DMD 2.113 `-O -release -inline`, medians of 5
where noted. Frame time is work only.

| Scenario | druntime mean | steadygc mean | ratio | worst frames | over16 sum |
|---|---|---|---|---|---|
| `--worst` (before 0056) | ~5.2 ms | ~8.1 ms | ~1.55× | steady often worse | steady often >0 |
| `--worst` (after 0056) | ~5.3–5.6 ms | ~6.5–7.1 ms | ~1.23–1.27× | often ≤ druntime | often 0 |
| `--openworld` (after 0056) | ~0.53–0.59 ms | ~0.70–0.77 ms | ~1.3× | mixed | 0 |
| `--worst-safe` (after 0056) | ~2.7 ms | ~2.7 ms | ~1.0× | ~7 ms both | 0 |
| `--worst` (after 0058) | 5.087 ms | 5.818 ms | **1.14×** | 10.784 / 10.963 | 0 / 0 |
| `--openworld` (after 0058) | 0.527 ms | 0.591 ms | **1.12×** | 1.321 / 1.658 | 0 / 0 |
| `--worst-safe` (after 0058) | 2.589 ms | 2.619 ms | ~1.01× | 5.564 / 6.981 | 0 / 0 |
| `--worst` (after 0060) | 4.832 ms | 5.483 ms | **1.14×** | 9.671 / **8.490** | 0 / 0 |
| `--openworld` (after 0060) | 0.481 ms | 0.534 ms | **1.11×** | 1.278 / **1.266** | 0 / 0 |
| `--worst-safe` (after 0060) | 2.419 ms | 2.392 ms | **0.99×** | 5.348 / 6.556 | 0 / 0 |
| `--worst` (after 0062) | 4.864 ms | 5.524 ms | **1.14×** | 9.607 / **8.758** | 0 / 0 |
| `--openworld` (after 0062) | 0.484 ms | 0.565 ms | **1.17×** | 1.260 / **1.256** | 0 / 0 |
| `--worst-safe` (after 0062) | 2.456 ms | 2.438 ms | **0.99×** | 5.421 / 6.556 | 0 / 0 |
| `--worst` (after 0064) | 4.806 ms | 4.898 ms | **1.02×** | 9.449 / **7.616** | 0 / 0 |
| `--openworld` (after 0064) | 0.502 ms | 0.505 ms | **1.01×** | 1.366 / 1.426 | 0 / 0 |
| `--worst-safe` (after 0064) | 2.487 ms | 2.471 ms | **0.99×** | 5.418 / 6.293 | 0 / 0 |
| `--worst` (after 0066) | 5.014 ms | 5.072 ms | **1.01×** | 10.398 / **7.965** | 0 / 0 |
| `--openworld` (after 0066) | 0.515 ms | 0.504 ms | **0.98×** | 1.278 / **1.223** | 0 / 0 |
| `--worst-safe` (after 0066) | 2.545 ms | 2.508 ms | **0.99×** | 5.695 / 6.603 | 0 / 0 |

**0058** floors Phobos `Appender`/`format` `GC.qalloc(…, NO_SCAN)` (no `APPENDABLE`) to 64 bytes and
caches soft `GC.extend` page-descriptor lookups. **0060** skips redundant `SlabEntry`/emap work on
`allocAppendable`. **0062** adds a per-bin page-descriptor cache, drops the redundant 64B floor from
`allocAppendable` (qalloc keeps it), a 2-way slab append cache plus a large-extent append cache,
fixes explicit `GC.collect` target refresh / epoch-0 decay, and word-clears slab metadata flags on
sweep. **0064** lowers `SeqCst` atomic loads on x86-64 to plain `mov` (acquire), adds inline `lock or`/`lock and`
and `RTree` release/acquire L1 lookup, eliminates false conservative roots in `ThreadBin`/`ThreadCache`,
fixes `lastRecycleTime` update in `recycleBins()`, skips redundant `reassociateArena()` under `busyState`,
returns `BlkInfo` directly in `qalloc`, and makes `SnazzyGC.frameStats()` lock-free.
`steadygc` now matches `druntime` within **1–2%** on mean across `--worst`, `--openworld`, and `--worst-safe`,
while beating `druntime` on `--worst` p99 (**6.618 ms** vs **9.150 ms**), worst frame (**7.616 ms** vs **9.449 ms**),
and user CPU (**3.97 s** vs **4.51 s**). **0066** eliminates unconditional global `gAnyFinalizers` `xchg` writes on every
finalized allocation (`Extent.setHasFinalizers` and `Extent.setFinalizer`), skips two `clock_gettime` calls on the
`allocLargeExtent` fast path, and blends the heap collection target above 64 MiB live to `1.625×` (cutting peak RSS on
500 MiB–2 GiB heaps below `druntime` on `gcb frag`, `gcb frames 512`, `bullet_hell_stress`, and `entity_init`).

```sh
DC=path/to/dmd bash bench/engine_gc_compare.sh
```

## Reproduce

```sh
bench/compare.sh bullet_hell_stress.d 30 2048 100000 0.05 256      # section 1, three collectors
bench/compare.sh aaa_sim.d city 60 2048 6 0 500000                 # section 2
bench/compare.sh gcb.d alloc 8 4000000                             # section 3
bench/compare.sh entity_init.d 60 1024 20000 2000 60               # section 5
```

`compare.sh` runs the druntime GC, steadygc with a stop-the-world mark and steadygc with the concurrent mark on the same
binary. The LDC and card-barrier rows need the project's compiler builds (`guide/usage.md`, recipes E and F).
