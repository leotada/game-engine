# Platforms and compilers

State on 2026-10-12. "Checked" means run on the project's test machine (openSUSE Leap 16, Linux 6.12, Ryzen 7
3800X). Everything else is marked as expected or unknown. Reports from other systems are what this preview is for;
see `testing.md`.

## Compilers

| Compiler | Frontend | Upstream symgc | steadygc | Concurrent mark | Card barrier | Status |
|---|---|---|---|---|---|---|
| DMD 2.109 and older | ≤ 2.109 | Does not build (no `ThreadBase.tlsGCData`) | Same | — | — | Checked |
| LDC 1.40 | 2.110 | Does not build (same) | Same | — | — | Checked |
| GDC 15.3 | 2.111 | Builds; works with one thread; dies at the first collection once a second druntime thread exists | Same | Same crash | — | Checked |
| Unpatched druntime from dmd `master` (2.113 in development) | 2.113 | Not tried | Works | Kernel tracker, Linux 6.7+ (`mark_race`, `finalizer_order` pass) | — | Checked |
| DMD 2.112 or newer, stock release | ≥ 2.112 | Supported by upstream | Builds | Kernel tracker expected, as above | — | Expected; please report |
| LDC with a 2.112+ frontend, stock | ≥ 2.112 | Supported by upstream | Builds | Kernel tracker expected, as above | — | Expected; please report |
| DMD 2.113 from this project (patched druntime) | 2.113 | Works | Works | Kernel tracker, Linux 6.7+ | — | Checked |
| LDC 1.43-git from this project (`gc-card-marking`) | 2.113 | Does not run on this runtime | Works | Cards, or the kernel tracker | Yes | Checked |
| DMD 2.113 from this project, `-preview=gcbarrier` | 2.113 | Does not run on this runtime | Works | Cards, on Linux x86-64 (the only target DMD builds for) | Yes, expanded in place for a pointer store | Checked |

**Why GDC 15 fails:** its druntime (2.111) has `tlsGCData` but not the GC's thread-init hook, which druntime gained
in April 2025 (2.112). The collector never learns about the threads druntime starts and asserts when it tries to
stop them. Supporting 2.111 inside the fork is planned (attach a thread on its first allocation). Until then, GDC
needs a release whose druntime is 2.112 or newer.

**The druntime from this project** adds two things: the game-engine calls in `core.memory.GC` (`frameStats`,
`excludeCurrentThread`, `step`, `defrag`, ...) and a 2-line fix that lets a collector stop the world from its own
thread. steadygc needs neither: without the calls it simply does not offer them, and without the fix its GC thread
poses as a placeholder thread while it scans (`core/thread/symthread.d`), which an unpatched druntime accepts.

## Operating systems

| OS | Upstream symgc | steadygc | Write tracking available | Known blockers |
|---|---|---|---|---|
| Linux x86-64 | Supported | Measured (every number in `benchmarks.md`) | Cards (patched LDC); kernel tracker on 6.7+ | None |
| Linux arm64 | Tested upstream (4 KiB pages) | Compiles, with the card barrier (checked 2026-10-12). Never run | Cards (patched LDC); the kernel tracker is x86-64 only (`d/gc/dirty.d` hard-codes its syscall numbers) | Needs a machine or an emulator to run the battery |
| Windows x64 | Supported with DMD 2.112+ | Compiles for `x86_64-windows-msvc`, with the card barrier (checked 2026-10-12). Never linked or run | Cards (patched LDC); a `GetWriteWatch` tracker is planned | Needs a Windows machine; pacing sleeps are coarse (see below) |
| macOS (Intel, Apple Silicon) | Unknown | Does **not** compile | Cards (patched LDC) | No `Waiter` (no futex on Darwin), and the stop-the-world protocol is Linux (signals) or Windows only: see "macOS and iOS" below |
| Android arm64 | Unknown | Compiles for `aarch64-linux-android`, with the card barrier (checked 2026-10-12). Never linked or run | Cards (patched LDC) | Needs an NDK, a runtime cross-built for Android, and a device or emulator. The barrier and the card table are ready for it (tagged pointers, `.so` start-up, 39-bit address spaces: see `how-it-works.md`) |
| iOS | Unknown | Does **not** compile (same as macOS) | Cards (patched LDC), after the macOS work | Same as macOS, plus Apple's limits on virtual memory |

"Compiles" means the whole collector builds with `ldc2 -mtriple=<target> -c -gc-card-marking
-d-version=Symgc_cards`; it says nothing yet about running. Before 2026-10-12 the Windows, Android and macOS code had
never been compiled for its target. Compiling it found, and fixed: the Windows constants imported from the wrong
module; `usleep` and a scoping error in code written for Linux only; `sched_getcpu`, which Android only has from API
level 29 (a thread now picks its arena from its id there).

### macOS and iOS

Two pieces are missing, both inside the collector:

1. **A waiter.** `d/sync/waiter.d` has a futex implementation for Linux and a `WaitOnAddress` one for Windows. Darwin
   has neither. A futex can be emulated with a table of `pthread` mutexes and condition variables keyed by address
   (the compare-and-wait done under the bucket's lock), which keeps `FutexWaiter` unchanged.
2. **Stopping the threads.** On Linux the collector signals each thread and waits for it to reach a safe point; on
   Windows it suspends it and checks that it is not inside the collector. druntime stops Darwin threads with Mach
   `thread_suspend`, so the Windows-style protocol is the natural base, but it relies on Win32 events in
   `d/gc/thread.d` (`waitForGCBusy`, delayed threads) that need a Darwin counterpart.

Neither can be tested without a Mac, so neither is written yet. The card barrier itself is ready for both: it is plain
LLVM IR and its table is set up with `mmap`.

Without write tracking the collector still works everywhere it builds: the mark stops the program, and the sweep
runs beside it.

## Which compiler for which target

| | Linux x86-64 | Linux arm64 | Windows x64 | macOS Intel | macOS Apple Silicon | Android | iOS |
|---|---|---|---|---|---|---|---|
| DMD | Yes | No | Yes | Yes | Through Rosetta | No | No |
| LDC | Yes | Yes | Yes | Yes | Yes | Yes | Yes, less tested |
| GDC | Yes | Yes | MinGW | Unknown | Unknown | No | No |

Phones mean LDC. The barrier is not emitted by the shared frontend: a frontend rewrite would miss the pointer stores
the code generator makes by itself (the elements of an array literal, a struct literal, a closure frame). What the
compilers share is the switch, the card ABI and the two druntime functions; each backend has a pass of its own: an
LLVM pass in LDC (done), a pass over the element trees in DMD (done, `backend/gcbarrier.d`), a GIMPLE pass for GDC
(not started). The plan is in `plans/cross_platform_gc_plan.md` of the dmd repository.

## Machine requirements

* With cards: the collector reserves the address space for its pointer-holding memory (the window) when it starts,
  256 GiB on a desktop and 16 GiB on Android and iOS, plus a card table of 1/512 of it (512 MiB and 32 MiB). On Posix
  that is `MAP_NORESERVE`, so `vm.overcommit_memory` must be 0 or 1; on Windows it is `MEM_RESERVE`, which costs no
  memory. If the system will not give that much, the collector asks for half, down to 2 GiB.
  `SYMGC_HEAP_RESERVE_GIB` sets the first request. A program cannot grow its pointer-holding heap past the window.
* Windows pacing: the sweeper and the helpers sleep for 50 to 100 microseconds on Posix. Windows sleeps in ticks of the
  system timer (a millisecond at best), so a shorter wait yields the core instead, which spins a little; a high
  resolution waitable timer would be better and has not been tried.
* Kernel tracker: Linux 6.7+ with `userfaultfd` available to unprivileged processes in user mode
  (`UFFD_USER_MODE_ONLY`, the default on most distributions). If it is not available, the collector falls back to the
  stop-the-world mark without telling you; `SYMGC_DIRTY=0` forces that fallback for comparisons.
