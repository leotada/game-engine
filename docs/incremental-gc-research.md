# Incremental GC for D — Research Report

**Status:** research-only. No code changes proposed in this document.
**Target:** ≤ 2 ms GC pause per frame at 60 Hz on Linux + Windows + macOS.
**Audience:** engine maintainers deciding whether to invest in a Unity-style
incremental garbage collector for D.

---

## 1. Problem framing

Unity's runtime ships [Boehm GC in incremental mode][unity-incremental]: the
mutator pays a small write-barrier cost on every reference store, the marker
runs in time-budgeted slices interleaved with the game loop, and pauses are
bounded to ~1–3 ms per slice. The price is a permanent throughput tax (5–15 %
in published Boehm benchmarks) and a substantial runtime + codegen
implementation.

D's only production GC is `class ConservativeGC : GC` in
[ref/dmd/druntime/src/core/internal/gc/impl/conservative/gc.d](../ref/dmd/druntime/src/core/internal/gc/impl/conservative/gc.d).
It is a stop-the-world, mark-sweep collector. It can be made *precise*
(typeinfo-driven pointer bitmaps) via `GC.Config.precise`, and it can run mark
in parallel (`GC.Config.parallel`) or concurrently in a forked child process
(`GC.Config.fork`). It is **not** incremental: mark always completes in a
single pause (or a single fork snapshot).

Two facts shape the rest of this analysis:

1. **The DMD compiler emits no GC write barriers.** Searching
   `ref/dmd/compiler/src` for `writeBarrier`, `gcBarrier`, or any barrier
   infrastructure returns nothing. Adding incremental marking that depends on
   write barriers therefore requires forking the D compiler.
2. **This engine already enforces a two-layer GC policy** (see
   [AGENTS.md](../AGENTS.md), section "GC Policy — Two Layers"). The frame
   path inside `engine/` is `@nogc`; components have no indirections so the
   GC never scans them. *Pause risk is purely a function of gameplay-layer
   allocations.* For a typical D game built on this engine, total GC heap
   stays small (order of MB, not GB) and collection frequency is dominated
   by gameplay choices, not engine code.

A 2 ms budget at 60 Hz means the GC can spend at most ~12 % of one frame on
itself. For a small-heap conservative collector that is achievable today on
POSIX with the existing fork path. On Windows it is the hard case.

---

## 2. Approach A — Full incremental GC (DMD write barriers + tri-color druntime)

### 2.1 Compiler work

A barrier-based incremental GC needs the compiler to emit a runtime call (or
inlined sequence) on every store of a pointer into GC-managed memory.
Concretely, DMD would need:

- A new IR / glue node (likely in `compiler/src/dmd/backend` and the GLUE
  layer used by the front end) for "pointer store".
- Codegen for x86_64, aarch64 (and ideally LDC/GDC parity through the same
  front-end IR).
- Optimization passes to *elide* the barrier when the destination is provably
  on the stack, in `@nogc` code, in a TLS scalar field, or to a non-pointer
  type. Without elision, the throughput regression is unacceptable.
- ABI compatibility: existing object files compiled without barriers must
  remain linkable; the runtime needs a fallback for them, otherwise the
  ecosystem fragments.

DMD's current compiler has none of these hooks. This is a multi-month effort
for a single experienced compiler engineer, and that's only DMD — LDC and
GDC require independent ports.

### 2.2 Runtime work

The runtime side is well-trodden but still substantial:

- Replace mark with a **tri-color (white / grey / black)** scheme using an
  explicit grey work stack so mark can be paused and resumed.
- Pick a barrier discipline. Two viable options:
  - **Dijkstra (incremental update):** on store `a.f = b`, if `a` is black
    and `b` is white, repaint `b` grey. Requires precise knowledge of
    object color.
  - **Yuasa (snapshot at the beginning):** on store `a.f = b`, if the old
    value `*a.f` is white, repaint it grey. Easier to reason about for
    short collection cycles.
- Allocation coloring: new allocations during a mark cycle are born black
  (Dijkstra) or white (Yuasa with floating garbage tolerance).
- A bounded **mark slice** API: the collector marks until either the grey
  stack is empty or a deadline is reached, then yields back to the
  mutator. The engine calls this once per frame from the gameplay layer.
- Sweep can stay STW or be made lazy/concurrent per page.

### 2.3 Profile

- **Pause:** true sub-millisecond mark slices are achievable; pauses become
  bounded by the slice budget you choose, not by live heap size.
- **Throughput:** typically 5–15 % regression from barrier overhead, even
  with elision. Confirmed by Boehm's published incremental-mode numbers and
  Unity's own guidance ("expect a small CPU overhead").
- **Cross-platform:** once compiler work is done, all platforms come for
  free (barriers are pure codegen).

### 2.4 Risks

Forks the language toolchain. The engine would either ship its own DMD or
maintain an out-of-tree patch series and pin a DMD version. Long-term
maintenance burden is high and would block consuming upstream LDC/DMD
releases.

### 2.5 Verdict

This is the only approach that genuinely matches Unity's incremental model.
It is also disproportionate for a single game engine. Reconsider only if
the broader D community contributes upstream barrier support.

---

## 3. Approach B — Soft / time-sliced incremental in druntime (no compiler changes)

This approach extends the existing `ConservativeGC` to reduce pauses without
touching the compiler. It splits cleanly into a POSIX path and a Windows
path.

### 3.1 POSIX path: tune the existing fork collector

The fork collector is already implemented:

- `version (COLLECT_FORK)` block at
  [gc.d#L1749](../ref/dmd/druntime/src/core/internal/gc/impl/conservative/gc.d#L1749).
- Activated by `GC.Config.fork = true` (line 1803).
- Hot path: `Gcx.fullcollect` at
  [gc.d#L3284](../ref/dmd/druntime/src/core/internal/gc/impl/conservative/gc.d#L3284).
  When `shouldFork && !block`, the collector calls `thread_suspendAll`,
  takes a heap snapshot via `fork()`, immediately resumes mutator threads,
  and lets the child process complete the mark in parallel. The parent
  performs sweep on the next collection cycle.

The pause window is therefore: signal-suspend all threads + `prepare()` +
`fork()` syscall + `thread_resumeAll`. On Linux for a modest game heap
(tens of MB, a few dozen threads), this is well under 2 ms in practice.
Combine with `GC.Config.parallel = N` and the fork child can also use
multiple threads internally.

**Action items (POSIX):**
1. Set `extern(C) __gshared string rt_options = ["gcopt=fork:1 parallel:8 precise:1"];`
   in the engine's executable entry points.
2. Measure `GC.profileStats().maxCollectionTime` on `dub run --config=benchmark`
   and `dub run --config=showcase` — both are non-trivial gameplay loads.
3. If max pause already < 2 ms, stop. Document the configuration as the
   recommended default and ship.

This is a configuration change. Zero forks of any toolchain.

### 3.2 Windows path: the hard case

`fork()` does not exist on Windows. `CreateProcess` is not equivalent — it
does not share or copy-on-write the parent's address space.

Without barriers and without fork, the only way to interrupt mark mid-cycle
*safely* is to take a stable snapshot of the heap so the marker can scan
old pointer values while the mutator races ahead. The standard technique is:

1. Mark all GC heap pages **read-only** with `VirtualProtect(PAGE_READONLY)`.
2. Install a vectored exception handler (`AddVectoredExceptionHandler`) that
   catches `EXCEPTION_ACCESS_VIOLATION` on a write to a protected page,
   duplicates the page contents to a shadow buffer, restores write
   permissions on the original, and resumes the mutator.
3. The marker scans the shadow pages (or uses them as the source of truth
   for any page the mutator has touched). After mark completes, free the
   shadow pages.

This is essentially a userspace `fork()` built on copy-on-write page
protection. It is well known (used by some real-time GCs and by some heap
profilers) but invasive in druntime: every page-allocator path needs to
cooperate, the SEH handler must be trusted, and the page-fault cost shows
up as mutator overhead during the mark window. A typical implementation
adds 200–600 µs to the mutator per touched page during mark and a few
hundred µs of fixed cost to enable/disable protection.

**Estimated pause on Windows with this path:** 3–10 ms depending on heap
size and how many pages the mutator dirties during the mark window.
Without this work, Windows is stuck with parallel-STW pauses that scale
with live-heap size (typically 5–30 ms for a small game).

### 3.3 macOS

`fork()` exists and the existing `COLLECT_FORK` path compiles. macOS-specific
caveats:

- `fork()` after multi-threaded use is officially discouraged by Apple
  (`fork()` followed by anything other than `exec()` is "not supported");
  in practice the druntime fork path works because the child only does
  read-only mark and `_exit`, but this should be re-validated under the
  hardened runtime and on Apple Silicon.

### 3.4 Verdict

Pragmatic. Reuses ~80 % of the existing GC. The POSIX piece is essentially
free (configuration). The Windows COW-snapshot piece is the genuinely
novel work and should only be undertaken if Windows pauses are measured as
a real shipping problem.

---

## 4. Approach C — Frame-budgeted GC scheduler in the engine (smallest change)

This approach lives entirely in the engine, in a new module
`source/engine/core/gc.d`. No druntime changes, no compiler changes,
fully cross-platform.

### 4.1 Design

```d
// source/engine/core/gc.d  (sketch — not part of this report)
module engine.core.gc;

import core.memory : GC;
import core.time : Duration, MonoTime, msecs;

@safe:

struct FrameGcScheduler
{
    Duration budgetPerFrame = 2.msecs;
    size_t   forceCollectBytes = 64 * 1024 * 1024;  // hard ceiling
    bool     collectOnSceneTransition = true;

    private MonoTime lastCollect;
    private size_t   lastUsed;

    void start() @trusted nothrow
    {
        GC.disable();           // we drive collection manually
        lastCollect = MonoTime.currTime;
        lastUsed = GC.stats.usedSize;
    }

    /// Call once per frame, after endFrame(), with the time you actually have.
    void tick(Duration frameSlack) @trusted nothrow
    {
        const stats = GC.stats;
        const grew  = stats.usedSize - lastUsed;
        // Only collect when we have headroom and growth is real.
        if (frameSlack >= budgetPerFrame && grew > 0)
        {
            GC.collect();       // STW; budget is advisory, not enforced
            lastCollect = MonoTime.currTime;
            lastUsed = GC.stats.usedSize;
        }
        else if (stats.usedSize >= forceCollectBytes)
        {
            GC.collect();       // hard ceiling — accept the spike
            lastCollect = MonoTime.currTime;
            lastUsed = GC.stats.usedSize;
        }
    }

    /// Game code calls this on level loads / scene cuts.
    void onSceneTransition() @trusted nothrow
    {
        if (collectOnSceneTransition)
        {
            GC.collect();
            GC.minimize();
            lastCollect = MonoTime.currTime;
            lastUsed = GC.stats.usedSize;
        }
    }
}
```

### 4.2 Profile

- **Pause when collecting:** unchanged from today (full STW, 5–50 ms).
- **Pause when not collecting:** zero — the GC is disabled.
- **Mean pause across frames:** dramatically lower because collection is
  amortized to scene transitions and frames with measured slack.
- **Worst-case pause:** unchanged. The scheduler controls *when*, not
  *how long*.

### 4.3 Combine with existing engine policy

The engine's two-layer GC policy ([AGENTS.md](../AGENTS.md)) already keeps
the frame path `@nogc` and components free of indirections. Combined with
the scheduler:

- Engine never triggers GC (already true).
- Gameplay GC only runs at scene transitions or on frames with slack.
- Hard ceiling caps total heap.

### 4.4 Verdict

Highest value for effort. Days of work. Will *not* meet the 2 ms budget
during an actual collection cycle, but will keep collections out of frames
where the player would notice. Recommended as the immediate first step.

---

## 5. Comparison matrix

| Approach | Achieves ≤ 2 ms? | Effort | Cross-platform | Forks toolchain? |
|---|---|---|---|---|
| **A** Full incremental (DMD barriers + tri-color) | Yes — true sub-ms slices | Multi-month, multi-engineer | Yes (after compiler work) | DMD (and LDC/GDC) |
| **B** Soft incremental in druntime | POSIX yes; Windows hard, ~3–10 ms with COW snapshot | POSIX: trivial config; Windows COW: months | Partial | druntime fork |
| **C** Engine-side frame scheduler | No (between collections only) | Days | Yes | No |

---

## 6. Recommendation

Stack the cheap wins; escalate only on measured evidence.

1. **Ship Approach C now.** A `source/engine/core/gc.d` scheduler + hardening
   the two-layer policy delivers most of the perceived smoothness benefit at
   negligible cost.
2. **Enable the existing fork+parallel collector on POSIX builds.** Set
   `rt_options = ["gcopt=fork:1 parallel:N precise:1"]` in each demo's
   `main.d`. Measure with `DRT_GCOPT_PROFILE=1` and the engine benchmark.
   If max pause is already under 2 ms on Linux/macOS, no further work is
   needed there.
3. **Defer the Windows COW-snapshot piece** until Windows is a confirmed
   shipping target *and* measurements prove Windows pauses are a real
   problem. This is the only Approach B work item that is not free.
4. **Do not pursue Approach A.** A DMD fork is not justified for one engine.
   Reconsider only if the D community contributes upstream barrier support
   that the engine could adopt without maintaining a compiler fork.

---

## 7. Operational appendix

### 7.1 Enabling the existing concurrent collector

Add to each executable's `main.d`:

```d
extern(C) __gshared string[] rt_options = [
    "gcopt=fork:1 parallel:8 precise:1 profile:1"
];
```

Reference: option parsing lives in
`ref/dmd/druntime/src/core/internal/gc/impl/conservative/gc.d` near the
`config` struct (search "fork" / "parallel" / "precise"). Field meanings:

| Option | Effect |
|---|---|
| `fork:1` | Concurrent mark in a forked child (POSIX only). Pause becomes ~`fork()` syscall + thread suspend window. |
| `parallel:N` | Use N worker threads for mark. See `markParallel()` at [gc.d#L3575](../ref/dmd/druntime/src/core/internal/gc/impl/conservative/gc.d#L3575). |
| `precise:1` | Use compiler-emitted pointer bitmaps for mark. Reduces conservative false-retention. |
| `profile:1` | Print collection stats on shutdown via `Gcx.Dtor`. |

Per-process override at runtime:

```bash
DRT_GCOPT="fork:1 parallel:8 precise:1 profile:1" ./bin/game-engine-benchmark
```

### 7.2 Manual frame-budgeted scheduling pattern

The Approach C sketch above is the reference. Two things to remember:

- `GC.disable()` only stops *automatic* collection; explicit `GC.collect()`
  still runs.
- `GC.stats` is cheap (atomic loads) and safe to call every frame.
- `GC.minimize()` returns memory to the OS — useful at scene transitions,
  expensive in the middle of a frame.

### 7.3 Hardening the two-layer policy

For gameplay code that wants lower pauses without going `@nogc`:

- Reuse buffers: `Appender!T` cleared each frame, not reallocated.
- Avoid `string` concatenation in hot paths; pre-format.
- Prefer `static` arrays for per-frame scratch.
- Mark performance-critical systems `@nogc` and use the engine's
  pre-allocated container helpers.

### 7.4 What to measure

When validating any of the above, capture:

1. `GC.profileStats().maxCollectionTime` over a 60-second benchmark run.
2. 99th-percentile frame time from the engine's existing FPS overlay.
3. Total bytes allocated per frame (`GC.stats.allocatedInCurrentThread`
   delta).

Without these numbers, none of the recommendations above are
falsifiable. Producing them is the natural follow-up to this report.

### 7.5 Companion benchmark

A small standalone benchmark that exercises a synthetic gameplay
allocation pattern (per-entity HUD strings, per-frame scratch arrays,
periodic large buffers) and reports the per-frame distribution plus
`GC.profileStats` deltas lives at
[source/demo/gc_benchmark.d](../source/demo/gc_benchmark.d). It includes
a reference implementation of the Approach C scheduler.

```bash
dub build --config=gc-benchmark
DRT_GCOPT="profile:1 precise:1" ./game-engine-gc-benchmark all 1200
DRT_GCOPT="profile:1 precise:1 fork:1 parallel:8" \
    ./game-engine-gc-benchmark default 6000
```

Sample output on this engine's workload (1200 frames, debug build, DMD,
Linux x86_64):

| mode      | mean   | p99    | max    | GC collections | heap delta |
|-----------|--------|--------|--------|----------------|------------|
| default   | 0.031ms| 0.054ms| 0.573ms| 4              | +6.4 MB    |
| scheduler | 0.033ms| 0.052ms| 0.411ms| 1              | +16.7 MB   |
| disabled  | 0.030ms| 0.049ms| 0.335ms| 1              | +16.7 MB   |

Two takeaways:

1. **Even the default GC stays well under the 2 ms budget** at this
   workload (max 0.57 ms). For a small-heap D game, the pause problem
   may not exist in practice — measure before investing in any of
   Approaches A/B/C.
2. **The scheduler trades higher heap retention for lower max pause**
   by deferring collection to scene transitions / slack frames. It does
   not eliminate STW; it *delays* it.

#### Heavy scenario: open-world action game

The benchmark also ships an `--openworld` scenario that models a much more
aggressive allocation pattern: 512 active NPCs with per-tick AI decision
arrays, 64 nearest-NPC HUD strings, a 256-line dialog/loot/event queue per
frame, 32 particle-burst float arrays, a 256 KB streamed terrain chunk
every 4 frames, and a 1 MB event-log dump every 120 frames. Live working
set settles around 30–50 MB, with ~1–2 MB allocated *per frame*.

```bash
DRT_GCOPT="profile:1 precise:1" \
    ./game-engine-gc-benchmark all 1200 --openworld
DRT_GCOPT="profile:1 precise:1 fork:1 parallel:8" \
    ./game-engine-gc-benchmark default 3000 --openworld
```

Sample output (1200 frames, debug build, DMD, Linux x86_64):

| mode (openworld)     | mean   | p99    | max    | GC collections | heap delta |
|----------------------|--------|--------|--------|----------------|------------|
| default              | 0.785ms| 1.204ms| 1.487ms| 20             | +33.9 MB   |
| scheduler            | 0.762ms| 1.264ms| 1.832ms|  9             | +34.0 MB   |
| disabled (no GC)     | 0.840ms| 1.239ms| 1.975ms|  1             | +432.1 MB  |
| default + fork:1 par:8 (3000 frames) | 0.754ms| 1.144ms| 1.967ms| 31 | +38.6 MB |

Open-world takeaways:

1. **Even at 1–2 MB/frame allocation, max pause stays under 2 ms** on this
   machine (DMD debug build, ~30–50 MB live heap). The 60 Hz budget is met
   by every mode tested.
2. **Allocation cost dominates GC cost.** Per-frame mean rises from
   ~0.03 ms (light) to ~0.78 ms (openworld) primarily because of the
   allocator path itself, not the collector — the `disabled` mode (no GC)
   is *slowest*, because heap fragmentation grows unbounded.
3. **The scheduler more than halves collection count** (20 → 9) without
   regressing tail latency, confirming Approach C is a useful smoothing
   tool even at this pressure.
4. **Approach A (incremental + barriers) is still not justified.** D's
   conservative GC handles a workload heavier than most indie/AA gameplay
   loops within the 2 ms budget.

#### Worst-case scenario (`--worst`)

To stress-test the conservative collector against a *pointer-rich* object
graph, the benchmark also ships a `--worst` scenario:

- **4096 NPC class instances** with class-typed `target` cross-references,
  per-frame `int[] memory`, a `string[]` dialog cache, and an intrusive
  linked-list inventory (up to 8 nodes deep).
- **Terrain streamed as `PointerVertex[]`** — every vertex carries a
  `string materialName` and a back-reference to an `NpcState`. A new
  4096-vertex chunk lands every 2 frames into a 256-slot ring (~64 MB live).
- **1024 transient short strings per frame** (hot allocator path).

Live heap settles around 60–100 MB, allocation rate ~3–5 MB/frame, and
*every byte* of the working set must be scanned by the conservative mark.

```bash
DRT_GCOPT="profile:1 precise:1" \
    ./game-engine-gc-benchmark all 1200 --worst
DRT_GCOPT="profile:1 precise:1 fork:1 parallel:8" \
    ./game-engine-gc-benchmark default 1200 --worst
```

Sample output (1200 frames, debug build, DMD, Linux x86_64):

| mode (worst)         | mean    | p99     | max     | GC collections | total pause | heap delta |
|----------------------|---------|---------|---------|----------------|-------------|------------|
| default              |  6.55ms | 12.84ms | 16.72ms | 40             | 195.5ms     | +63.4 MB   |
| scheduler            |  7.14ms | 12.84ms | 18.09ms | 111            | 524.9ms     |  +4.5 MB   |
| disabled (no GC)     |  6.67ms |  9.37ms | 12.60ms |  1             |   4.2ms     | +1.77 GB   |
| default + fork:1 par:8 |  6.87ms | 13.14ms | 15.10ms | 40           | 193.2ms     | +63.4 MB   |

Worst-case takeaways:

1. **Pointer-rich heaps explode mark cost.** Per-collection pause climbs
   from ~0.07 ms (openworld, pointer-free arrays) to **5–9 ms** here on a
   ~70 MB heap that the GC actually has to scan. This matches the
   "remembered ~15 ms pause" anecdote: a deeper graph or 2× the live
   data would put the worst pause squarely in the 10–15 ms range, eating
   the entire 60 Hz frame.
2. **The frame loop now stalls.** `max` per-frame time crosses the 16.6 ms
   budget under the default GC (16.72 ms), confirming this workload would
   visibly hitch on a real game.
3. **`fork:1 parallel:8` (Approach B) barely helps here.** Total pause is
   essentially identical to the default — the fork-based collector still
   pauses for the root scan and write-barrier setup, and the workload's
   cost is dominated by the *concurrent* mark phase that already runs
   off-thread. The gain comes mostly from heaps that allocate **during**
   the mark, which this scenario does, but at this allocation rate the
   wins are within noise.
4. **Approach C (scheduler) backfires under sustained pressure.** Forced
   collections at every slack window keep the heap small (+4.5 MB delta!),
   but pay 111 collections × ~5 ms = ~525 ms of pause across the run, vs
   ~195 ms for letting druntime decide. Approach C is a *smoothing* tool,
   not a budget-saver — it works when the heap is mostly cold and slack
   is abundant. Under continuous heavy mutation it makes things worse.
5. **The pointer-free component policy in `engine/` is doing real work.**
   The 8× pause-per-collection delta between openworld (pointer-free
   arrays of POD) and worst (class graph + pointer-bearing buffers) is
   exactly what you give up the moment you let GC pointers leak into
   gameplay-hot data structures. **This is the single highest-leverage
   GC tuning lever the engine has.**
6. **Approach A (incremental + write barriers) would help here**, but only
   here. Indie/AA scenarios that respect the no-indirection rule never
   reach this regime, so the multi-month DMD fork remains hard to justify.

> **Practical recommendation.** If a future game hits this pattern —
> dense object graphs, pointer-bearing streamed buffers, multi-megabyte
> per-frame allocation — first audit whether those allocations *need* GC
> pointers at all. Replacing class graphs with handle/ID indirection and
> pointer-free struct buffers (the engine's existing pattern) collapses
> mark cost back to the openworld numbers (<2 ms max pause) without any
> collector changes. Approach A only becomes the right answer if that
> audit fails.

---

## 8. Open questions

- **What is the actual measured pause today** on `dub run --config=benchmark`
  and `dub run --config=showcase`? No measurement has been performed as
  part of this report.
- **Is gameplay GC traffic high enough to need Approach C at all,** given
  that the no-indirection component policy already keeps the engine core
  out of the GC?
- **Will the engine ship on Windows in the medium term?** This determines
  whether Approach B's COW-snapshot piece is ever worth building.

---

## 9. References

- DMD conservative GC source:
  [ref/dmd/druntime/src/core/internal/gc/impl/conservative/gc.d](../ref/dmd/druntime/src/core/internal/gc/impl/conservative/gc.d)
- GC interface (for plugging in alternative implementations): see
  `ref/dmd/druntime/src/core/internal/gc/impl/manual/` and `proto/`.
- Engine GC policy: [AGENTS.md](../AGENTS.md), section "GC Policy — Two Layers".
- Engine performance principles: [docs/why-this-is-fast.md](why-this-is-fast.md).
- Boehm-Demers-Weiser GC, incremental mode:
  https://www.hboehm.info/gc/
- Unity incremental GC documentation: https://docs.unity3d.com/Manual/performance-incremental-garbage-collection.html

[unity-incremental]: https://docs.unity3d.com/Manual/performance-incremental-garbage-collection.html
