# Multiplatform Integration of `steadygc` (`symgc`)

This document defines the complete architecture and integration of [`leotada/symgc`](file:///home/leonardo/Projetos/game-engine/ref/symgc/README.md) (`steadygc`), the custom **DMD** compiler (`-preview=gcbarrier`), and the custom **LDC** compiler (`-gc-card-marking`) into the D 3D game engine.

---

## 1. Architectural Foundation: Multiplatform Compiler Card Barrier

The engine standardizes exclusively on the **Multiplatform Compiler Card Barrier (`-version=Symgc_cards` + `-version=Symgc_druntime_hooks`)** across all target platforms:
- **Linux** (`x86_64`, `aarch64`)
- **Windows** (`x86_64-pc-windows-msvc`)
- **Android** (`aarch64-linux-android`)
- **macOS** (`x86_64-apple-darwin`, `aarch64-apple-darwin`)
- **iOS** (`aarch64-apple-ios`)

The Linux-x86_64-only dirty-page tracking path (`userfaultfd` + `PAGEMAP_SCAN` / Stock DMD) is completely omitted. By relying on compiler-lowered inline card marking, the runtime avoids OS kernel version requirements, root/capabilities permissions, signal handler race conditions, and platform-specific page-table scanning syscalls.

### Why Compiler Card-Marking Excels

1. **Deterministic User-Space Tracking:**
   Every pointer mutation inside GC-tracked memory executes a bounds-checked byte write into a 512-byte-per-card byte table:
   ```d
   // Lowered by DMD (-preview=gcbarrier) or LDC (-gc-card-marking):
   if (((cast(size_t)addr - __sd_gc_card_lo) >> 9) < __sd_gc_card_n)
       __sd_gc_card_base[(cast(size_t)addr - __sd_gc_card_lo) >> 9] = 1;
   ```
2. **Safe Pre-Initialization & Android Shared Library Support:**
   Before `steadygc` reserves its address window, `__sd_gc_card_lo`, `__sd_gc_card_n`, and `__sd_gc_card_base` are all `0`. Early stores inside shared libraries (e.g., Android `.so` loading where `.preinit_array` is skipped by the dynamic linker) harmlessly fail the unsigned range check `(addr - 0) >> 9 < 0` and execute as a branch-predicted no-op.
3. **Hardware Tagged Pointers & Non-GC Addresses:**
   Pointers on the stack, globals, C `malloc` memory, and Android 11+ top-byte-tagged pointers (TBI) wrap or exceed `__sd_gc_card_n`, executing zero card writes.
4. **Sub-Millisecond Pauses:**
   512-byte card granularity is 8x finer than 4 KiB OS pages. During the remark phase, the collector only scans dirty 512-byte slices rather than entire 4096-byte pages, sustaining **0.09–0.13 ms p99 STW pauses** across multi-threaded workloads.

---

## 2. Heap Layout & POD Separation

`steadygc` divides memory into two primary regions:
1. **`gPointerRegionAllocator` (Tracked Window):**
   Holds objects containing GC-scanned pointers. Reserved within the card window (`__sd_gc_card_lo .. __sd_gc_card_lo + (__sd_gc_card_n << 9)`).
2. **`gDataRegionAllocator` (Leaf / Untracked Window):**
   Holds memory allocated with `BlkAttr.NO_SCAN`.

### Synergy with Engine [`Pod!T`](file:///home/leonardo/Projetos/game-engine/source/engine/core/pod.d) Architecture

The game engine strictly mandates POD structs for ECS components ([`ComponentStore!T`](file:///home/leonardo/Projetos/game-engine/source/engine/ecs/store.d)), scene graph nodes ([`SceneGraph`](file:///home/leonardo/Projetos/game-engine/source/engine/scene/graph.d)), rendering vertex/index arrays, and frame allocators ([`FrameArena`](file:///home/leonardo/Projetos/game-engine/source/engine/core/arena.d)).

Because these types satisfy `isPod!T` (`!hasIndirections!T`), they are allocated with `BlkAttr.NO_SCAN` in `gDataRegionAllocator`. Furthermore, compiler card barriers are **only emitted on pointer-type stores**. Consequently:
- Zero card-barrier instructions are executed when mutating ECS component arrays.
- Zero card-table memory is dirtied during hot gameplay loops.
- High-frequency mutations in gameplay systems pay **0.0 ns** GC overhead.

---

## 3. Platform Matrix & OS Primitives

| Target Platform | Compiler | Card Window (`SYMGC_HEAP_RESERVE_GIB`) | Card Table Size | Synchronization & Thread Suspension |
| :--- | :--- | :--- | :--- | :--- |
| **Linux x86-64** | DMD (dev) / LDC (release) | 256 GiB | 512 MiB (`MAP_NORESERVE`) | `FutexWaiter` + POSIX signals (`SIGUSR1`/`SIGUSR2`) |
| **Linux arm64** | LDC | 256 GiB | 512 MiB (`MAP_NORESERVE`) | `FutexWaiter` + POSIX signals (`SIGUSR1`/`SIGUSR2`) |
| **Windows x64** | DMD / LDC | 256 GiB | 512 MiB (`MEM_RESERVE` + committed on demand) | `Win32Waiter` (`WaitOnAddress`) + `SuspendThread` + High-Res Timer |
| **Android arm64** | LDC | 16 GiB (39-bit VA safe) | 32 MiB (`MAP_NORESERVE`) | `FutexWaiter` + POSIX signals (`SIGUSR1`/`SIGUSR2`) |
| **macOS (Intel/M-series)** | DMD / LDC | 256 GiB | 512 MiB (`MAP_NORESERVE`) | `DarwinWaiter` (striped mutex/condvar) + Mach `thread_suspend` |
| **iOS arm64** | LDC | 16 GiB | 32 MiB (`MAP_NORESERVE`) | `DarwinWaiter` (striped mutex/condvar) + Mach `thread_suspend` |

### Platform-Specific Implementations

- **macOS / iOS Darwin Waiter:** Implemented in `vendor/symgc/source/d/sync/darwin/waiter.d` using a 64-bucket cache-line-padded table of `pthread_mutex_t` and `pthread_cond_t` pairs to match `FutexWaiter` semantics. Stop-the-world threads are suspended via Mach kernel calls `thread_suspend()` / `thread_resume()`.
- **Windows High-Resolution Pacing:** High-precision sweeper pacing (`SYMGC_SWEEP_SLEEP_US=50`) uses `CreateWaitableTimerExW(..., CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, ...)` avoiding busy-spin CPU burn.
- **Android Memory Trimming:** Handles `SDL_EVENT_LOW_MEMORY` by calling `GC.defrag()` to release physical pages back to the mobile operating system immediately.

---

## 4. Engine Architecture Integration Across Every Level

### Level 1: Collector Core (`vendor/symgc`)
`symgc` is vendored directly under `vendor/symgc` and built with `-version=Symgc_cards -version=Symgc_druntime_hooks`. The Linux-only `userfaultfd` tracking in `d/gc/dirty.d` is disabled.

### Level 2: Build & Toolchain Configuration
- **DMD Flags:** `-preview=dip1000 -preview=gcbarrier -version=Symgc_cards -version=Symgc_druntime_cards -version=Symgc_druntime_hooks`
- **LDC Flags:** `-preview=dip1000 -gc-card-marking -d-version=Symgc_cards -d-version=Symgc_druntime_hooks`
- **Host Linkage:** Linked with `-L--export-dynamic` (POSIX) or `/EXPORT` (Windows) so `__sd_gc_card_lo`, `__sd_gc_card_n`, and `__sd_gc_card_base` are exported to dynamic script modules.

### Level 3: Runtime Interface (`source/engine/core/gc.d`)
The engine wraps runtime telemetry and GC control in `@safe nothrow @nogc` functions:
- `gcStepFrameSlack(Duration slack)`: Steps incremental sweeping during pre-vsync idle time.
- `gcDefragment()`: Drains quarantine and decommits free pages during scene changes or low-memory signals.
- `gcExcludeCurrentThread()` / `gcIncludeCurrentThread()`: Excludes dedicated real-time threads (audio mixer, worker threads) from STW handshakes.
- `gcBarrierRange(const(void)* dst, size_t size)`: Explicit card marking for C/FFI memory copies.
- `gcTotalTimes()` / `gcThreadTimes()`: Real-time telemetry query returning pause times, cycle counts, and work duration.

### Level 4: Frame Loop & App Lifecycle (`source/engine/app.d`)
- In `App.endFrame()`, remaining frame slack is calculated and passed to `gcStepFrameSlack()`.
- On `SDL_EVENT_LOW_MEMORY` and `SDL_EVENT_WILL_ENTER_BACKGROUND`, `gcDefragment()` is triggered.
- `App` enforces zero GC allocations on the core engine frame loop when running with `--assert-no-gc`.

### Level 5: Audio Engine & Physics Workers
- `AudioEngine` runs an SDL3 audio callback thread excluded from GC STW cycles via `gcExcludeCurrentThread()`.
- Box3D and WGPU driver threads are unmanaged C threads and remain invisible to GC tracking.
- Parallel ECS task threads utilize lock-free per-thread caches in `steadygc`.

### Level 6: Script Hot-Reload (`source/engine/hotreload/build_runner.d`)
- Script libraries (`.so` / `.dll` / `.dylib`) are built with the compiler card barrier enabled.
- On library unload, `HotReloadManager` calls `gcDefragment()` to sweep orphaned objects without a full blocking STW pause.

### Level 7: Developer Tools & Profiler (`source/engine/devtools/overlay.d`)
- `DebugOverlay` displays real-time GC metrics: pause duration, cycle count, and card window usage.
- `gc_benchmark.d` measures p50, p99, and max pause times across multi-threaded scenarios.

### Level 8: Standalone Player Export Pipeline (`source/editor/build_export.d`)
- `BuildExporter` cross-compiles standalone player binaries using LDC with `-gc-card-marking`, targeting Desktop (256 GiB window) and Mobile (16 GiB window) configurations.
