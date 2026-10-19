# Benchmarks

All numbers on this page come from one session on 2026-10-12, produced by `plans/bench/core_bench/dmd_bench.sh` of
the dmd repository, so the collectors and the two compilers are compared under the same conditions. Older numbers,
from the development of each patch, are in `plans/symgc-patches/README.md`.

## Conditions

* AMD Ryzen 7 3800X (8 cores, 16 threads), 31 GiB RAM, openSUSE Leap 16, Linux 6.12.
* CPU frequency: `amd-pstate-epp`, governor `powersave`, energy preference `power`. A performance setting would lower
  every frame time; it would not change the comparison.
* DMD 2.113.0-beta.1 from the dmd repository (its druntime includes the faster associative arrays of
  `plans/ldc-patches/0005`, which also speed up druntime's own GC in the game models). Flags
  `-O -release -inline`.
* LDC 1.43-git from the `gc-card-marking` branch, `-O3 -release -gc-card-marking -d-version=Symgc_cards`, runtime
  built with the barrier.
* Frames are 60 fps; "worst" is the longest frame of the run; "frames over 16 ms" counts frames that missed 60 fps.
  Frame time is the game's own work plus whatever the collector costs it.

| Label | Collector | Write tracking |
|---|---|---|
| druntime GC | druntime's conservative GC (same binary, no `gcopt`) | — |
| upstream symgc | symgc at `4a4cb2b`, before this work | — (stop-the-world) |
| steadygc, STW mark | steadygc, `SYMGC_CONCURRENT_MARK=0` | none: the mark stops the program, the sweep does not |
| steadygc | steadygc, concurrent mark | Linux kernel dirty pages |
| steadygc, LDC + cards | steadygc, concurrent mark | the compiler's card barrier |

## Bullet-hell stress: lots of garbage, few live objects

`bullet_hell_stress.d 30 <level MiB> 100000 0.05 256`: 100,000 bullets per second, each with a closure and 256 bytes of
extra garbage, short lives, a level of 2 or 8 GiB kept alive. 30 s, 1,800 frames.

**2 GiB level** (two runs for druntime GC and steadygc, one for the others):

| Collector | p50 | p99 | p99.9 | Worst | Frames over 16 ms | Peak RSS |
|---|---|---|---|---|---|---|
| druntime GC (DMD) | 0.18 ms | 0.70 ms | 138 ms | 139-141 ms | 4 | 4.4 GB |
| upstream symgc (DMD) | 0.20 ms | 0.99 ms | 24.7 ms | 28.0 ms | 3 | 3.0 GB |
| steadygc, STW mark (DMD) | 0.21 ms | 0.94 ms | 10.3 ms | 11.1 ms | 0 | 3.0 GB |
| steadygc (DMD) | 0.22 ms | 0.97-0.98 ms | 1.11-1.15 ms | 1.19-1.27 ms | 0 | 3.0 GB |
| No collection (DMD, the game's own cost) | 0.18 ms | 0.80 ms | 0.97 ms | 0.98 ms | 0 | 4.8 GB, growing |
| steadygc, LDC + cards | 0.11 ms | 0.63 ms | 0.77 ms | 0.87 ms | 0 | 3.0 GB |

**8 GiB level** (one run each):

| Collector | p50 | p99 | p99.9 | Worst | Frames over 16 ms | Peak RSS |
|---|---|---|---|---|---|---|
| druntime GC (DMD) | 0.18 ms | 0.74 ms | 539 ms | 548 ms | 2 | 16.9 GB |
| upstream symgc (DMD) | 0.20 ms | 0.93 ms | 1.25 ms | 63.6 ms | 1 | 10.9 GB |
| steadygc, STW mark (DMD) | 0.21 ms | 0.95 ms | 1.11 ms | 35.3 ms | 1 | 11.3 GB |
| steadygc (DMD) | 0.21 ms | 0.95 ms | 1.19 ms | 1.22 ms | 0 | 11.3 GB |
| steadygc, LDC + cards | 0.11 ms | 0.64 ms | 0.84 ms | 0.84 ms | 0 | 11.3 GB |

Reading: under DMD, without any compiler change, steadygc's worst frame is within 0.3 ms of the game run with no
collection at all, at 2 and at 8 GiB. druntime's GC stops the game for 0.14 s at 2 GiB and over half a second at
8 GiB. At 8 GiB only one or two collections happen in 30 s, so a stop-the-world collector's p99.9 looks fine and its
worst frame does not: the worst frame is the number that matters.

## Bullet hell: a heavy game frame

`bullet_hell.d 30 2048 40000`: the same game with long-lived bullets (45,000 alive), each updated every frame, so
the game's own cost dominates. 30 s, 1,800 frames, one run each.

| Collector | p50 | p99 | p99.9 | Worst | Frames over 16 ms | Peak RSS |
|---|---|---|---|---|---|---|
| druntime GC (DMD) | 1.21 ms | 1.55 ms | 1.75 ms | 151 ms | 1 | 5.4 GB |
| upstream symgc (DMD) | 1.45 ms | 2.11 ms | 24.5 ms | 25.4 ms | 7 | 3.0 GB |
| steadygc, STW mark (DMD) | 1.45 ms | 2.05 ms | 13.2 ms | 13.3 ms | 0 | 3.1 GB |
| steadygc (DMD) | 1.48 ms | 2.53 ms | 4.05 ms | 4.26 ms | 0 | 3.1 GB |
| steadygc, LDC + cards | 0.65 ms | 0.99 ms | 1.24 ms | 1.30 ms | 0 | 3.1 GB |

Reading: this is the kernel tracker's worst case. Every frame writes to the pages of 45,000 live bullets, and the
first write to each page in a cycle costs a fault, so steadygc under DMD pays about 0.3 ms at the median and 2 ms at
p99.9 over druntime's GC in exchange for removing the 151 ms stop. The card barrier has no faults: LDC's frames are
half of DMD's, mostly because LDC's code is faster.

## Game models: six job threads, 2 GiB of assets

`aaa_sim.d <mode> 60 2048 6 0 <population>`: models of big games, 60 s (3,600 frames), six job threads allocating
the careless way (classes, closures, rebuilt arrays, associative arrays, strings), 2 GiB of resident assets.

**City builder, 500,000 citizens**, the reference workload (two runs for druntime GC, upstream and steadygc):

| Collector | p50 | p99 | p99.9 | Worst | Frames over 16 ms | Peak RSS |
|---|---|---|---|---|---|---|
| druntime GC (DMD) | 9.1-9.2 ms | 79-81 ms | 131-152 ms | 137-193 ms | 37 | 3.0 GB |
| upstream symgc (DMD) | 3.8-3.9 ms | 97-98 ms | 107-109 ms | 107-113 ms | 40 | 2.8 GB |
| steadygc, STW mark (DMD) | 3.6 ms | 5.8 ms | 57.9 ms | 60.7 ms | 25 | 3.3 GB |
| steadygc (DMD) | 4.3 ms | 7.0-7.1 ms | 8.6-8.9 ms | 9.7-9.8 ms | 0 | 3.6 GB |
| steadygc, LDC + cards | 3.1 ms | 4.7 ms | 5.8 ms | 6.9 ms | 0 | 3.1 GB |

**The other models**, one run each (p50 / p99.9 / worst / frames over 16 ms):

| Collector (DMD) | City, 100,000 citizens | RTS, 4,000 units | Open world, streaming |
|---|---|---|---|
| druntime GC | 1.74 / 31.9 / 40.4 ms / 18 | 2.60 / 10.8 / 13.2 ms / 0 | 0.29 / 14.9 / 16.6 ms / 2 |
| upstream symgc | 1.12 / 45.0 / 48.5 ms / 14 | 2.21 / 33.5 / 36.9 ms / 14 | 0.29 / 0.64 / 14.1 ms / 0 |
| steadygc, STW mark | 1.00 / 17.0 / 17.5 ms / 10 | 2.24 / 9.8 / 11.0 ms / 0 | 0.29 / 1.90 / 8.8 ms / 0 |
| steadygc | 1.13 / 2.73 / 3.68 ms / 0 | 2.45 / 4.13 / 4.71 ms / 0 | 0.30 / 0.64 / 1.34 ms / 0 |

Reading: with six threads allocating, the allocator matters as much as the pauses. druntime's GC serialises every
allocation behind one lock, and its median city frame is twice steadygc's. Upstream symgc fixes the median but stops
the program for about 0.1 s at 500k. steadygc under DMD, with no compiler change, keeps every frame of every model
under 10 ms. The price is memory: 3.6 GB against 3.0 GB in the 500k city, because the heap keeps growing while a
cycle runs beside the program.

## Allocator throughput and fragmentation

`gcb.d`, one binary run with and without `gcopt`, medians of three runs (DMD):

| Workload | druntime GC | steadygc | Ratio |
|---|---|---|---|
| `alloc 1 8000000`: one thread allocating small objects | 19.6 M allocs/s, 5.5 MB peak | 15.5 M allocs/s, 84 MB peak | 0.79x |
| `alloc 8 4000000`: eight threads | 4.2 M allocs/s (8.1 s), 5.9 MB peak | 36.0 M allocs/s (0.94 s), 132 MB peak | 8.6x |
| `frag 3000000 100000`: mixed sizes, long and short lives | 2.08 s, 1.00 GB | 3.83 s, 0.91 GB | 0.54x speed, 9% less memory |

Reading: with one thread, druntime's GC allocates faster and keeps a much smaller heap: it collects 552 times where
steadygc collects 15, so steadygc trades memory for fewer cycles. With eight threads druntime's single lock collapses
and steadygc is 8.6 times faster. The fragmentation workload is the weak spot: steadygc takes 1.8 times as long, and spends
about 3 s in collection work against 0.11 s for druntime's GC; where that time goes has not been measured yet.
Single-thread throughput and `frag` are both open items.

## The cost of the range-checked barrier

The card barrier checks that the address it marks is inside the collector's window (`how-it-works.md`, "The card
window"). That is one more compare and one more load per store, which is what lets one barrier serve Android (tagged
pointers), Windows and the others. Measured on 2026-10-12 against the barrier without the check, with the same
program, same machine and CPU setting, pinned to one core, medians of five runs, LDC -O3
(`barrier_micro.d`, ns per operation):

| Store pattern | No barrier | Without the check | With the check | Check vs without |
|---|---|---|---|---|
| Pointer array element | 0.14 | 0.45 | 0.49 | +9% |
| Class field | 0.58 | 1.30 | 1.30 | 0% |
| Two fields of an object | 0.35 | 0.97 | 0.97 | 0% |
| Two fields of a struct | 0.28 | 0.91 | 0.91 | 0% |
| Linked list | 0.77 | 1.30 | 1.30 | 0% |
| Copy of 8 pointers | 2.66 | 7.81 | 8.20 | +5% |
| Copy of 64 pointers | 6.86 | 12.87 | 14.82 | +15% |
| Copy of 1,024 pointers | 72.95 | 71.35 | 73.15 | +3% |
| Append pointers (library) | 20.92 | 20.82 | 22.30 | +7% |
| AA insert, pointer values (library) | 33.56 | 33.47 | 34.17 | +2% |

The two loads are invariant and are hoisted out of loops, which is why a loop of field stores does not slow down.
Short copies pay a little more: a check, then a call that clips the range. Two stores to the same object share one
check. The controls (stores of ints, to the stack, to globals) are unchanged.

On real workloads, run back to back in the same session (LDC + cards), the check changes nothing you can measure: stress test 2 GiB worst frame 0.67-0.72 ms with the check against 0.67-0.89 ms without; 8 GiB 0.89-1.35 ms
against 0.91-0.97 ms (and one 8.5 ms outlier in the unchecked runs); 500k city p50 2.68-2.95 ms against 2.86-3.06 ms,
worst 7.3-8.3 ms against 8.3-8.4 ms; no frame over 16 ms in any run.

## DMD with `-preview=gcbarrier`

Same machine, DMD -O -release -inline, druntime and Phobos built with the flag (`integration.md`, section 4).

**Cost per store** (`barrier_micro.d`, pinned, medians of five), DMD against DMD without the flag: a class field
0.61 -> 1.30 ns, a linked list 0.73 -> 1.80 ns, an array element 0.28 -> 1.29 ns. The single-store barrier is expanded
in place (a subtract, a shift, a compare and a byte store, with no call), which brought it level with LDC's
(class field 1.30 ns in both); the first version called `_d_gcBarrier` and cost +0.9 to +1.4 ns, so the gain of
expanding it is modest, about 0.2 ns, because the cost is mostly the loads of the window and the store to the table.
Three or more pointer stores in a row to one object (`t.a = x; t.b = x; t.c = x;`) share one barrier for the lowest
and the highest address (at most 511 bytes apart), after the last of them: four field stores cost 0.68 ns each
without it and 0.46 ns with it. Two stores cost as much with a shared barrier as with two, so they keep their own.
A call, a store of something else, or a different base variable ends the run.
Copies and stores of slices, delegates and structs still call `_d_gcBarrierRange`. Stores of ints, to the stack
and to globals are unchanged. The instrumented druntime is about 1% larger and Phobos 0.3%.

**Frames, DMD with cards against DMD with the kernel tracker:**

| Workload | DMD + barrier | DMD + kernel tracker |
|---|---|---|
| Stress, 2 GiB, worst frame | 1.14-1.40 ms | 1.14-1.27 ms |
| Stress, 8 GiB, worst frame | 1.43 ms (p50 304 us) | 1.22 ms (p50 214 us) |
| Bullet hell, 2 GiB, p99.9 / worst | 3.3 / 3.35 ms | 4.0 / 4.3 ms |
| City, 500k citizens, worst frame | 7.6 ms (p50 3.84 ms), none over 16 ms | 9.8 ms |

(The table is from the expanded barrier; with the call, the 8 GiB stress was 1.66 ms and the city 8.3 ms.) So the
barrier gives DMD what the kernel tracker gives on Linux 6.7+, without needing that kernel, and it is the route to the
other systems where DMD runs. The price is the median at large heaps (8 GiB: 304 against 214 us).

**The 500k city used to stall for 2 s** with this build. The cause was in the collector, not the barrier: it handed
the scanner whole 4 KiB pages for each dirty card, and this program writes one pointer into a very large number of
pages, so a round rescanned eight times what had been written, took 0.15 to 1 s, and the program dirtied more in
the meantime; rounds of 80k, 150k, 250k, 450k pages never converged. The collector now hands over cards (512
bytes), and rounds shrink (7-10k pages, then about 1k). LDC with cards went from 6.9 to 6.1 ms worst at the same
time. Not re-run after this change: the 8 GiB stress and the bullet hell in the table above.

## Large heaps with many pointers: the hard limit follows the mark

`entity_init.d`: a scene of entities with 8 pointer fields each, 1 GiB (10.3 million entities, 80 million pointers),
a window of it rewritten every frame, new entities allocated every frame, paced at 60 frames per second. Marking
such a heap takes one to two seconds (about 1.2 GB/s scanned), and the heap grows by about 70,000 pages (280 MB)
meanwhile. With the old fixed limit (the target plus a quarter) a thread that allocated past it waited for the
mark to end:

The same binary with and without the new limit (`SYMGC_ADAPTIVE_LIMIT=0` is the old one), 60 s runs:

| Run | Limit | Frames over 16 ms | Worst frame | Frames over 5 ms | Peak RSS |
|---|---|---|---|---|---|
| 1 GiB, 11 MB/s allocation (2,000 entities a frame) | fixed | 1 (first mark, 0.64 s) | 0.64 s | 33 | 1.82 GB |
| | follows the mark | 1 (the same) | 0.62 s | 3 | 1.79 GB |
| 1 GiB, 115 MB/s (20,000 entities a frame) | fixed | 10 and 8 (two runs) | 1.55 s, 1.95 s | all (frames take 6 ms) | 6.9-7.1 GB |
| | follows the mark | 5 and 6 | 0.88 s, 1.04 s | all | 7.5-7.6 GB |
| 512 MiB unpaced, 40 s (overload, see below) | fixed | 7 | 1.04 s | 36 | 1.76 GB |
| | follows the mark | 7 and 6 | 1.17 s, 1.18 s | 56, 32 | 1.69-1.74 GB |

At the lower rate the gain is in the tail below the stalls (frames over 5 ms: 33 to 3); at the higher one the stalls
are fewer and shorter but not gone, and the memory is 5 to 10% larger. The first mark after a burst of allocation,
such as building the scene, has no history to follow and still waits. The existing models are unchanged within noise
(DMD with the barrier, one run each, fixed limit against follows the mark, from before the final rule below): stress 2 GiB worst
1.27 / 1.47 ms, stress 8 GiB 1.85 / 1.91 ms, city 500k 9.7 / 8.8 ms, RTS 7.0 / 4.5 ms, open world 2.1 / 1.7 ms;
peak RSS equal (RTS 2.5 / 1.8 GB).

**Overload.** Run unpaced (`FPS=0`), the program rewrites the whole scene every 1.6 s, the dirty rounds do not
converge and the mark takes 9 to 15 s: no collector keeps up with it. There, giving the allocator more room only made
the heap bigger: 3.9-4.0 GB of RSS against 1.76 GB, with as many stalls. So the allowance is granted only up to half
the target; when the growth the last marks needed is more than that, the program keeps the quarter. This rule was
added after that measurement and was checked on this run (memory back to 1.7 GB) and on the 115 MB/s run above,
but not on the other models. Where the heap's growth during a mark comes from (about 50,000 pages a second at 1 GiB,
regardless of the program's own allocation, which is about 6,000 pages in the same time) is not explained yet.

### Update: the growth was the mark's own work list

The growth during the mark has an explanation, and it was not the program. The scanner's work list is allocated from
the collector's own heap, and it grows by realloc (a quarter more each time). A concurrent mark frees nothing in the
heap (a free during the mark is left for the next collection, since the mark may hold the block), so every step of the
growth stayed: 17 reallocations from 512 to 8,192 pages, 50,432 pages (197 MiB) of garbage per cycle for a final list
of 32 MiB, counted as heap growth. The 70,000 pages above were about 50,000 of those and about 3,000 of the
program's own allocation (the trace `gcgrowth` lines now print both). The list now lives in its own mapping, grown by
doubling, and goes back to the OS at once (`scanner.d`, Posix; Windows keeps the heap list, untested).

With the fix, same binary and parameters as the table above, 60 s runs, two runs each:

| Run | Limit | Frames over 16 ms | Worst frame | Frames over 5 ms | Peak RSS |
|---|---|---|---|---|---|
| 1 GiB, 11 MB/s | follows the mark | 0 and 0 | 7.1 and 4.7 ms | 10 and 0 | 1.44-1.47 GB |
| | fixed | 0 and 0 | 6.4 and 8.9 ms | 5 and 4 | 1.45 GB |
| 1 GiB, 115 MB/s | follows the mark | 0 and 0 | 12.1 and 14.6 ms | all (frames take 6 ms) | 6.2-6.3 GB |
| | fixed | 0 and 0 | 13.5 and 13.0 ms | all | 6.2-6.4 GB |

Against the table above: the first mark after building the scene no longer waits (0.64 s worst became 7 ms), the
115 MB/s run went from 8-10 frames over 16 ms and a worst frame of 1.5-1.9 s to none and 13 ms, and the peak memory
fell by 0.4 GB and 0.7 GB. The adaptive limit makes no measurable difference any more: it was compensating for the
work list. It stays on (it follows real growth now, and costs nothing), but it has no measured benefit and is a
candidate for removal. The overload case is still overloaded: 512 MiB, unpaced, 20,000 entities created per frame
(about 230 MB/s), one run each: the old collector's worst frame was 5.4 s with 7.6 GB, the new one's 3.8 s with 8.2 GB
(8.5 GB with the adaptive limit). The existing 500k city, run again against the collector without this fix, in the
same session: worst frame 10.3 and 11.2 ms before, 11.7 and 10.4 ms after (the machine was slower than in the
session of the tables above, whose city worst frame was 9.7 ms). The 2 GiB stress still has a worst frame of 1.16 ms,
and the correctness battery passes (`mark_race` 11.6M moves, `mark_race_glue` 2.6M, `finalizer_order`, `thread_exit_race`), and the collector still
compiles for Android, Windows and arm64 Linux (not run there).

## Small-heap paced engine GC (2026-10-13)

Paced `bench/engine_gc_benchmark.d` via `bench/engine_gc_compare.sh` (two binaries). Machine: 16 cores,
Linux 6.12, DMD 2.113 `-O -release -inline`. Frame time is work only; 60 Hz sleep is not included.

### Phase 1 attribution (--worst, one run each, after harness)

| | mean | quiet residual | alloc timer sum | collect timer | pause | user CPU (compare) |
|---|---|---|---|---|---|---|
| druntime `precise:1` | ~5.1 ms | (no frameStats) | — | — | — | ~4.7 s |
| steadygc | ~8.0 ms before fixes; ~6.3–6.5 ms after | ~6.0–7.7 ms | ~0.22 ms/frame | small | small | ~7.4 s |

**Mutator bucket:** Quiet-frame residual dominates the mean. `threadAllocTime` only covers bin-miss /
large alloc; the hot path is Appender/`format` → `GC.qalloc` (appendable NO_SCAN) plus metadata writes.
Microbenches with `GC.disable`: `new Node` ties; `new char[]` nearly ties; `format` was ~1.6× until
qalloc BlkInfo cache + appendable `realloc` fix + mid-size NO_SCAN size floor.

**Other-thread bucket:** `totalCollectionTime` (~0.7–0.8 s cycle wall) and markers explain process
user CPU above mutator frame sum, and the cycle-frame tail — not the quiet median. Confirmed:
`SYMGC_CONCURRENT_MARK=0` leaves quiet residual ~unchanged; `SYMGC_SWEEP_DUTY=1` does not cut the mean;
`-version=Symgc_sync_sweep` makes --worst worse (more over-budget frames). `strace -c -e madvise`:
~60 calls / ~0.6 ms per --worst run — hypothesis 2 (purge) dropped.

### 0058: Appender qalloc floor (mean acceptance)

Phobos `Appender.ensureAddable` calls `GC.qalloc(nbytes, BlkAttr.NO_SCAN)` without `APPENDABLE`, so
the 0056 floor inside `allocAppendable` never applied to `std.format`. 0058 floors plain small
`NO_SCAN` `qalloc` to 64 bytes and uses a soft pd-cache in `extendLarge`.

| Scenario (medians of 5, DMD 2.113, 16-core) | ratio vs same-session druntime |
|---|---|
| `--worst` mean | **1.14×** (was ~1.23–1.27× after 0056) |
| `--openworld` mean | **1.12×** (was ~1.3×); after 0060 **1.11×** |
| `--worst-safe` mean / p99 | ~1.01× / ~1.01× (tie within noise); worst still higher |

**0060:** small `allocAppendable` skips `SlabEntry` rebuild; large path keeps `Extent*` from
`allocLarge` (no second emap lookup). Fresh 0060 session: `--worst`/`--openworld` worst ≤
druntime; `--worst-safe` worst still ~+1.2 ms. bullet_hell concurrent max ~1.5 ms, 0 over 16 ms,
RSS ~2.9 GB. `correctness.sh` OK.

**0062:** per-bin pd cache for appendable size-class churn; remove `allocAppendable` 64B floor
(keep qalloc floor); 2-way slab + large-extent append caches; `GC.collect` refreshes heap target;
word-level slab metadata clear on sweep. After 0062: `--worst` **1.14×**, `--openworld` **1.17×**,
`--worst-safe` mean **0.99×** / p99 **better than druntime**, worst still ~+1.1 ms. bullet_hell
max **1.5 ms**, 0 over 16 ms, RSS ~2.9 GB. `correctness.sh` OK.

**0064:** x86-64 `SeqCst` load as plain `mov` (acquire), inline `lock or`/`lock and`, compile-time `RTree`
`subKey!level` + release/acquire leaf ops, false-root elimination in `ThreadBin`/`ThreadCache`, per-bin
multi-page slab extent cache, `lastRecycleTime = now` fix in `recycleBins()`, `reassociateArena()` fast return,
direct `qalloc` `BlkInfo` output, and lock-free `frameStats()`. After 0064: `--worst` **1.02×** (p99 **6.62 ms**
vs dru **9.15 ms**, worst **7.62 ms** vs **9.45 ms**, user CPU **3.97 s** vs **4.51 s**), `--openworld` **1.01×**
(RSS **57 MB** vs **73 MB**), `--worst-safe` **0.99×** (p99 **3.56 ms** vs **3.60 ms**). `113/113` unit tests
and `correctness.sh` OK.

**0066:** check-before-write on `gAnyFinalizers` and `_sweepTag` in `Extent.setHasFinalizers` and `Extent.setFinalizer`
(eliminating an unconditional `xchg` on a global cacheline on every `new Class` allocation), skip `GcTimer` on the
`allocLargeExtent` fast path, and blend `CollectorState` target growth above 64 MiB live from `2.0×` to `1.625×`.
After 0066: `gcb alloc 8 4000000` **68.26 / 73.83 Mops/s** (**16.4×–17.8×** faster than druntime **4.15 Mops/s**);
`gcb frag` RSS **853 / 865 MB** vs druntime **977 MB**; `gcb frames 512` concurrent max **1.11 ms** vs druntime
**128.7 ms** (RSS **982 MB** vs **1032 MB**); `bullet_hell_stress` (2 GiB) max **1.30 / 1.95 ms** vs druntime
**141.2 ms** (RSS **2984 MB** vs **4253 MB**); `aaa_sim city` (6 threads) p50 **2.64 ms** vs **4.69 ms**, p99
**4.04 ms** vs **10.33 ms**, max **4.85 ms** vs **76.45 ms** (`0` frames over 5 ms or 16 ms vs `282` / `8`);
`aaa_sim rts` (6 threads) p99 **4.08 ms** vs **5.41 ms**, max **5.96 ms** vs **7.55 ms**; `entity_init` p99
**3.13 ms** vs **3.23 ms** (RSS **710 MB** vs **765 MB**); `engine_gc_compare.sh` `--worst` **1.01×** mean
(p99 **7.09 ms** vs **9.23 ms**, worst **7.97 ms** vs **10.40 ms**, user CPU **4.04 s** vs **4.59 s**),
`--openworld` **0.98×** mean (worst **1.22 ms** vs **1.28 ms**), `--worst-safe` **0.99×** mean (p99 **3.52 ms**
vs **3.58 ms**). `113/113` unit tests and `correctness.sh` OK.

### Phase 2 falsification numbers

| Experiment | Result |
|---|---|
| Micro A (class list) | steadygc ≤ druntime |
| Micro B (`new int[](32)`) | ~1.1–1.2× |
| Micro C (large scanned `PtrVert[]`) | with GC on much slower (mark); with GC.disable ties |
| `SYMGC_SWEEP_DUTY=1` | mean not improved |
| `Symgc_sync_sweep` | mean 7.0 ms, 40 frames >16 ms on --worst — worse |
| `madvise` count | ≪ 0.2 s — drop H2 |

## Reproducing

```sh
# in the dmd repository root, with this project's dmd, Phobos and LDC built (integration.md, section 4)
git -C symgc archive 4a4cb2b source | tar -x -C /tmp/upstream-symgc
plans/bench/core_bench/dmd_bench.sh /tmp/bench-out /tmp/upstream-symgc/source
cat /tmp/bench-out/results.txt

# paced small-heap engine benchmark (two binaries)
DC=path/to/dmd bash symgc/bench/engine_gc_compare.sh
```

The run takes about an hour. Each line of `results.txt` is one run: the frame statistics in microseconds, the peak
RSS in KiB and the exit code; the full output of each run sits beside it.
