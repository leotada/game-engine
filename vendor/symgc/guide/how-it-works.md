# How steadygc works

steadygc is a fork of [symgc](https://github.com/symmetryinvestments/symgc) (the SDC garbage collector ported to
ordinary D, by Steven Schveighoffer and Amaury Sachet). Its allocator comes from symgc unchanged. What the fork
changes is *when* the program has to stop: the mark and the sweep run beside the program, and the only stops left
are two short pauses per cycle.

This page explains the design well enough to reason about pauses, costs and the rules your code has to follow. The
patch-by-patch history, with the measurement behind each change, is in `plans/symgc-patches/README.md` of the dmd
repository this work lives in.

## Where it plugs in

druntime has a pluggable GC interface (`core.gc.gcinterface.GC`) and a registry of collectors
(`core.gc.registry`). Importing `symgc.gcobj` links the collector in. A `pragma(crt_constructor)` registers it under
two names before `main` runs:

* `sdc`, which prints `using SYM GC!` at start-up;
* `sdcq`, the same collector without the message.

druntime only uses it when asked, through `--DRT-gcopt=gc:sdcq` on the command line or through
`extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];` in the program. Otherwise the program keeps
druntime's conservative GC, even with symgc linked in. That makes A/B comparisons easy: one binary, two collectors.

With `-version=Symgc_druntime_hooks` (set by the dub package), symgc also takes over druntime's array hooks
(appending, capacity, `assumeSafeAppend`), so `~=` uses symgc's own size classes.

## The allocator (from symgc)

* **No global lock on the fast path.** Each thread allocates from its own thread cache. Small sizes are served from
  per-thread bins; a thread only takes a lock to refill a bin or to get a new slab.
* **Size classes and slabs.** Small objects live in slabs, runs of pages cut into equal slots. Large objects get
  their own extent of pages.
* **Arenas by kind.** Memory with pointers and memory without (`NO_SCAN`) live in different arenas, so the mark never
  touches pixels, meshes or audio buffers. Objects with finalizers carry metadata and live apart too.
* **Blocks and pages.** Address space is taken from the OS in 2 MiB blocks of 4 KiB pages, and pages are committed
  and returned to the OS as the heap grows and shrinks.

The allocator is why upstream symgc already makes the median frame of a multi-threaded game up to 5x faster than
druntime's GC, whose single allocation lock serialises every thread. Upstream symgc still stops the whole program
for the mark and the sweep, which is what the fork removes.

## A collection cycle

A cycle starts when the heap passes a target derived from what survived the last cycle. A GC thread runs it; the
thread that crossed the target carries on.

```
program threads  ===========|=|=================================|=|=========================
                            start                          remark
                            pause                           pause
GC thread                     [ mark, beside the program ][rounds]  [ finalize ][ sweep, paced ]
mark threads (2-6)            [ mark ................... ]
```

1. **Arm write tracking.** Clear the card table, or arm the kernel's dirty-page tracker (see below).
2. **Start pause.** Stop the threads, list the roots, the stacks and the thread-local storage as work, start a new
   epoch, restart the threads. The ranges are read and traced after the restart; only the listing needs the stop.
3. **Concurrent mark.** Mark threads trace the heap while the program runs. By default a quarter of the cores, at
   least 2 and at most 6 (`SYMGC_MARK_THREADS`), at a nice value of 10 on Linux so that game threads win a shared
   core. Objects allocated during the mark are *born live*: they are not traced and not freed this cycle.
4. **Dirty rounds.** The program kept writing while the mark ran. The GC rescans what was written since, in rounds,
   until fewer than 512 pages' worth are dirty. With cards the unit rescanned is the card (512 bytes), not the page:
   a program that writes one pointer into each of many pages (a hash table, a tree) would otherwise make the rounds
   rescan eight times what it wrote, and they would not converge. The kernel tracker can only say "this page".
5. **Remark pause.** Stop the threads again, rescan the roots, stacks, thread-local storage and the last dirty
   memory, restart. Typically 0.1 to 0.6 ms at 2 GiB of live data. After it, everything reachable is marked.
6. **Finalize.** Every finalizer of the cycle runs, in every arena, before any dead slot is reused. A destructor
   may therefore read another dead object, which many programs do even though the spec forbids it.
7. **Sweep, paced.** The GC thread returns dead slots to their slabs and slabs to their bins, one block at a time,
   holding a lock for about 10 µs per step. It runs at most half of the time (`SYMGC_SWEEP_DUTY`). A thread that
   allocates while the heap is past the hard limit helps with the sweep, so the heap cannot run away. Free pages
   are kept warm up to the target and returned to the OS in small chunks.

**The hard limit during the mark.** A thread that allocates past the hard limit while the mark runs cannot help it
(the mark is not work an allocator can take); it waits until the mark ends. The limit is the target plus an
allowance, and a fixed quarter of the target is too little when the mark is long: a heap of a gigabyte, with 10 million
objects, grows by about 70,000 pages (280 MB) during a mark of one to two seconds, and the program stalled for the
rest of it. The allowance now follows the growth seen during the last marks: 1.5 times the largest of them, with a
slow decay, between a quarter and a half of the target. When a thread had to wait, the heap stopped growing at
that moment, so the growth is scaled up to the whole length of the mark (at most eight times). The first mark after a
burst of allocation, such as loading a level, has no history and still pays the old limit. A program that would need
more than half the target is allocating faster than the mark can follow, and more room only makes its heap bigger, so
it keeps the quarter (`SYMGC_ADAPTIVE_LIMIT=0` turns the whole mechanism off).

*Update.* Most of that growth was the collector's own: the mark's work list was allocated in the heap and grown by
realloc, and a concurrent mark frees nothing, so each step of its growth stayed until the next cycle (197 MiB for a
list of 32 MiB). The list now has a mapping of its own, so a heap of a gigabyte grows by what the program allocates
(about 3,000 pages in a mark of a second and a half), the stalls this section describes are gone in the measurements
(`benchmarks.md`, "the growth was the mark's own work list"), and the adaptive allowance has no measured effect left.

The mark is the algorithm of Boehm, Demers and Shenker ("Mostly parallel garbage collection", PLDI 1991): mark while
the program runs, then fix up what it changed. Pauses depend mostly on the number of threads and on how much was
written during the last round. Only the remark's read of the card table grows with the heap, slowly (about 0.2 ms
at 2 GiB).

## Write tracking: why the barrier matters

While the mark runs, the program can store a pointer to an object the GC has not reached into an object the GC has
already scanned, then drop the other path to it. Without help the GC would never see that object again and would
free it while it is in use. Write tracking finds every memory region written during the mark so it can be scanned
again. steadygc has three ways, chosen once, at the first collection:

| Mode | How it knows what was written | Needs | Cost to the program |
|---|---|---|---|
| **Card barrier** | The compiler emits `if ((addr - lo) >> 9 < n) cards[(addr - lo) >> 9] = 1` after each pointer store; one byte per 512 bytes of the collector's memory (see "The card window" below) | LDC built from the `gc-card-marking` branch, everything compiled with `-gc-card-marking`, symgc built with `-version=Symgc_cards` | A compare and a byte store per pointer store (0.5 to 1.4 ns in microbenchmarks). Pointer-free stores and copies cost nothing; a store outside the window costs only the compare |
| **Kernel dirty pages** | Linux write-protects the pointer-holding heap asynchronously (`userfaultfd` write-protect) and reports written pages (`PAGEMAP_SCAN`) | Linux 6.7 or newer, x86-64; any compiler | A fault of about 1.5 µs on the first write to each page in each cycle |
| **None** | Nothing: the mark stops the program | Nothing | No barrier cost; the pause is the whole mark, which grows with the heap |

Even with no tracking, the sweep still runs beside the program, so the pause is the mark alone. In the DMD stress
benchmark at 2 GiB that is 10.3 ms against 24.7 ms for upstream symgc's stop-the-world cycle (`benchmarks.md`).

What the card barrier cannot see: pointer writes made by code compiled without `-gc-card-marking`, which includes C
libraries. C code may hold pointers to GC memory and read through them; that is fine. C code that *writes* a GC
pointer into GC memory while a mark runs is not seen. The kernel tracker sees every write, C included.

### The card window

With cards, the memory that holds your program's pointers is one contiguous range of address space, the window,
reserved when the collector starts (before `main`). The card table covers the window and nothing else, one byte per
512 bytes, so its size follows the heap the program can have and not the address space of the machine: 512 MiB of
table for a 256 GiB window, 32 MiB for 16 GiB. Memory is only committed as the heap grows and the table is only
touched where pointers are written.

The barrier is range checked. `lo` is the start of the window and `n` the number of cards in it, both zero until the
collector starts:

```
if ((addr - lo) >> 9 < n)  cards[(addr - lo) >> 9] = 1;
```

Three things follow, and they are what makes the same barrier usable on every platform:

* A store to memory outside the window costs the compare and marks nothing. That is every store into `malloc` memory,
  and every store through a pointer with a tag in its top byte, which is what Android's allocator returns for malloc
  memory since Android 11: such an address minus `lo` is enormous, so the compare fails. The collector's own memory
  is never tagged.
* Before the collector starts, every barrier is a no-op, so there is nothing that has to run before everyone else's
  start-up code. The table is set up by the collector itself, and a shared library loaded later (an Android game is
  one) works the same as an executable.
* A machine with little address space (many phones have 39 bits, 512 GiB for everything) still runs: the collector
  asks for the window it wants and halves the request until the system agrees, down to 2 GiB. Run out of the window
  and the program is out of memory, as it would be at any other heap limit.

Memory that holds pointers but is not in the window (the program's static data, thread stacks, ranges added with
`GC.addRange`) is not tracked by cards. It is scanned again as a root in the remark pause, as before.

## What still stops your threads

* The start and remark pauses (sub-millisecond at 2 GiB with tracking).
* Handshakes: each thread is stopped with a signal (Posix) or `SuspendThread` (Windows) and must reach a safe state.
  A thread descheduled by the OS delays the pause; on an overloaded machine that is the long tail.
* An allocating thread that finds the heap far past its target waits or helps with the sweep. This is the
  back-pressure that keeps memory bounded when the program allocates faster than the GC can collect.

## Threads the GC never stops

`GC.excludeCurrentThread()` puts the calling thread in a *detached* state: it is not stopped in the pauses and its
stack is not scanned. It is meant for audio callbacks and other real-time threads. The rules that come with it:

* **Its stack is not a root.** An object reachable only from a local variable of an excluded thread can be freed.
  Keep what the thread uses reachable from somewhere else: a global, a field of a long-lived object, `GC.addRoot`, or
  memory from `malloc`.
* It must not allocate on the GC heap (the contract of `GC.excludeCurrentThread` in `core.memory`). Pre-allocate
  what the callback needs, or use `malloc`. The collector does not enforce this today: an excluded thread that
  allocates never starts a collection, but its allocations can take locks.
* `GC.includeCurrentThread()` undoes it. The stacks of up to 8 excluded threads are skipped; more threads can be
  excluded, but their stacks are scanned.

## Finalizers

Finalizers (class destructors, struct destructors of GC arrays) run on the GC thread, not on the thread that
allocated the object, and before any memory of the cycle is reused. Allocating from a finalizer throws
`InvalidMemoryOperationError`, as with druntime's GC.

## Game-engine controls

These need the druntime from this project (they live in `core.memory.GC`); see `integration.md`.

| Call | What it does |
|---|---|
| `GC.frameStats()` | Time this thread lost to the GC (allocation slow paths, assists, pauses), totals for all threads, whether a cycle is running, live heap, number of collections. Cheap enough to read every frame for a HUD |
| `GC.excludeCurrentThread()` / `includeCurrentThread()` / `isThreadExcluded()` | The detached state above |
| `GC.step(Duration maxTime)` | Gives spare frame time (for example before waiting for vsync) to the sweep |
| `GC.defrag()` / `GC.minimize()` | Finishes the running sweep, returns completely empty slabs and every free page to the OS; returns the number of pages returned |

Under druntime's own GC these calls fall back: `frameStats` reports `GC.stats()`, `defrag` calls `minimize()`, and
the others do nothing.

## Diagnostics built in

| Build flag | Effect |
|---|---|
| `-version=Symgc_verify` | Verifier mode: freed slots are poisoned and checked when handed out again. Slower; use it when you suspect the GC |
| `-version=Symgc_phase_trace` | Prints the duration of each phase of each cycle |
| `-version=Symgc_gctime` | Per-thread counters of time lost to memory management (what `frameStats` reads) |

## Limits worth knowing

* Measured on Linux x86-64 only. See `platforms.md` for the other systems.
* With cards, the collector reserves its memory as one window of address space up front (256 GiB on a desktop, 16
  GiB on Android and iOS, `SYMGC_HEAP_RESERVE_GIB` to change it) and cannot grow past it. The reservation is
  `MAP_NORESERVE` on Posix, which needs `vm.overcommit_memory` 0 or 1, and `MEM_RESERVE` on Windows, which costs no
  memory. If the system will not give that much address space, the collector halves the request down to 2 GiB.
* Objects never move. Slices, interior pointers and pointers held by C stay valid; fragmentation is handled by
  returning empty slabs and pages, not by compaction.
