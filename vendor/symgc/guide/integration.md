# Using steadygc in a project

This guide gets steadygc into a D program with DMD, LDC or GDC, shows how to select it, and how to check it is the
collector actually running. Read `platforms.md` first if you are not on Linux x86-64.

## 1. Pick a setup

| Setup | Compiler | What you install | What you get |
|---|---|---|---|
| **Plugin** | Stock DMD 2.112+, or LDC with a 2.112+ frontend | Nothing; steadygc is a dub dependency | The allocator without a global lock, the concurrent paced sweep, and on Linux 6.7+ the concurrent mark through the kernel tracker. Elsewhere the mark is a pause |
| **Plugin + this project's druntime** | DMD 2.113 built from this project | A dmd and Phobos build | The same, plus the game-engine calls (`GC.frameStats`, `excludeCurrentThread`, `step`, `defrag`) |
| **Card barrier** | LDC built from this project's `gc-card-marking` branch | An LDC build with its runtime | The concurrent mark on any Linux kernel without page faults, the lowest tail, and the game-engine calls |
| **Card barrier, DMD** | DMD built from this project, with `-preview=gcbarrier` | A dmd, plus druntime and Phobos rebuilt with the flag | The same concurrent mark through cards instead of the kernel tracker: it does not need Linux 6.7+. A pointer store costs about 0.7 to 1 ns more, as with LDC |

GDC: GDC 15 (druntime 2.111) cannot run symgc in a program with more than one thread yet; see `platforms.md`.

The concurrent mark on a stock druntime was checked on 2026-10-12 with an unpatched druntime built from dmd's
`master` (2.113 in development): `mark_race.d` passes, and fails with 11,126 lost objects when the tracker is
disabled on purpose, so the mark really runs beside the program. A released 2.112 has not been tried; please report.

Where the sources are: the fork is not on a public package registry yet. This guide assumes a clone of the fork
(branch `latency-p3`) at `$SYMGC`. The same changes are kept as patches in `plans/symgc-patches/` of the dmd
repository, and apply to upstream symgc (`github.com/symmetryinvestments/symgc`, commit `4a4cb2b`) with
`git am plans/symgc-patches/*.patch`.

## 2. Add it to the program

### With dub

`dub.sdl`:

```sdl
name "mygame"
targetType "executable"
dependency "symgc" path="$SYMGC"
```

`source/app.d`:

```d
import symgc.gcobj;                                            // links the collector in
extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];   // and selects it

void main() { /* ... */ }
```

Build optimized. The collector is compiled with your project's settings, and a debug build of a collector is slow:

```sh
dub build -b release --compiler=dmd     # or ldc2, or gdc
./mygame
```

### Without dub

The collector is a set of D sources compiled with the program:

```sh
# DMD
dmd -O -release -inline -version=Symgc_druntime_hooks -I$SYMGC/source \
    mygame.d $(find $SYMGC/source -name '*.d')

# LDC
ldc2 -O3 -release -d-version=Symgc_druntime_hooks -I$SYMGC/source \
    mygame.d $(find $SYMGC/source -name '*.d')

# GDC (single-threaded programs only on GDC 15)
gdc -O2 -frelease -fversion=Symgc_druntime_hooks -I$SYMGC/source \
    mygame.d $(find $SYMGC/source -name '*.d') -o mygame
```

`-version=Symgc_druntime_hooks` lets symgc take over druntime's array hooks (`~=`, capacity); the dub package sets
it for you.

## 3. Select the collector

Linking it in is not enough: druntime uses its own GC unless told otherwise. Either in the program:

```d
extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];
```

or on the command line, which overrides the program: `./mygame --DRT-gcopt=gc:sdcq`.

* `gc:sdc` is the same collector and prints `using SYM GC!` at start-up: the quickest check that it is active.
* `gc:sdcq` is quiet.
* Leaving both out runs druntime's conservative GC. One binary can therefore compare the two collectors.

## 4. The setups that need a build

### This project's DMD (concurrent mark with the kernel tracker, game-engine calls)

```sh
git clone <dmd repository of this project> dmd && cd dmd
git checkout gc-phase0-discovery
make -j$(nproc)                                      # the compiler and druntime
git clone --depth 1 --branch v2.113.0-beta.1 https://github.com/dlang/phobos ../phobos
make -C ../phobos -j$(nproc) BUILD=release           # Phobos against this druntime
```

Use `generated/linux/release/64/dmd` as the compiler (`dub --compiler=<path>`). Phobos embeds a copy of druntime,
so rebuild Phobos after every druntime change, or programs link the old one.

### This project's LDC with the card barrier

You need the LLVM 19 development package and a D compiler to bootstrap. In the dmd repository root, with the LDC
checkout at `ldc/` (branch `gc-card-marking`) and Phobos beside it:

```sh
cmake -G Ninja -S ldc -B ldc-build-rt2 -DCMAKE_BUILD_TYPE=Release \
  -DLLVM_CONFIG=$(which llvm-config) -DD_COMPILER=$(which ldmd2) \
  -DPHOBOS2_DIR=<phobos checkout> -DBUILD_SHARED_LIBS=OFF -DLDC_DYNAMIC_COMPILE=OFF \
  -DD_EXTRA_FLAGS="-gc-card-marking"
ninja -C ldc-build-rt2
```

`-DD_EXTRA_FLAGS=-gc-card-marking` builds druntime and Phobos with the barrier, which is required: every piece of D
code that stores pointers into the GC heap must carry it. Then a wrapper, saved as `ldc2` in a directory of its own:

```sh
#!/bin/sh
R=<dmd repository>/ldc-build-rt2
exec $R/bin/ldc2 -conf=$R/etc/ldc2.conf -I<phobos checkout> \
  -gc-card-marking -d-version=Symgc_cards "$@"
```

and build with `PATH=<wrapper dir>:$PATH dub build -b release --compiler=ldc2`. `-d-version=Symgc_cards` makes the
collector read the card table instead of asking the kernel. The LDC changes are also kept as patches in
`plans/ldc-patches/` of the dmd repository.

### This project's DMD with the card barrier (`-preview=gcbarrier`)

The flag makes DMD's backend mark a card after each store of a pointer into memory that is not a local variable or a
global: in place (`if ((addr - __sd_gc_card_lo) >> 9 < __sd_gc_card_n) __sd_gc_card_base[...] = 1`), and by calling
`_d_gcBarrierRange(addr, n)` after a copy or a store of a slice, delegate or struct. The three variables and the range
function are in druntime (`core.internal.gc.cardbarrier`), and the variables are zero until a collector that wants the
barrier starts, so with the default GC the cost is a compare. steadygc sets up the card table when it starts. The
barrier assumes x86 store ordering (a plain byte store); an AArch64 DMD backend would have to use the call.

**Every piece of D code that stores pointers into the GC heap must carry the flag**, as with LDC: a store made by code
built without it is invisible to the concurrent mark and can lose an object. That means druntime and Phobos too.
Build the dmd as above, then build druntime and Phobos into their own directory so the normal ones stay usable
(`plans/bench/core_bench/dmd_gcbarrier.sh libs` does exactly this, into `generated/gcb`):

```sh
make -C druntime -j$(nproc) ROOT_OF_THEM_ALL=../generated/gcb OBJDIR=obj/gcb \
  DFLAGS="-conf= -Isrc -Iimport -w -de -preview=dip1000 -preview=fieldwise -m64 -fPIC -preview=dtorfields -O -release -inline -preview=gcbarrier" \
  ../generated/gcb/linux/release/64/libdruntime.a
make -C ../phobos -j$(nproc) BUILD=release ROOT_OF_THEM_ALL=generated/gcb DMDEXTRAFLAGS=-preview=gcbarrier \
  generated/gcb/linux/release/64/libphobos2.a
```

Then compile the program and the collector with the flag, and tell the collector to read the cards:

```sh
dmd -conf= -Idruntime/import -I../phobos -fPIC -O -release -inline -preview=gcbarrier \
    -version=Symgc_druntime_hooks -version=Symgc_cards -version=Symgc_druntime_cards \
    -Isymgc/source -defaultlib= mygame.d $(find symgc/source -name '*.d') \
    ../phobos/generated/gcb/linux/release/64/libphobos2.a \
    -L-Lgenerated/gcb/linux/release/64 -L-ldruntime -L-lpthread -L-lm -L-ldl -L-lz
```

`-version=Symgc_druntime_cards` makes the collector use the card variables that druntime defines, so that code built
with the flag and the collector see the same table. The collector's own code is never instrumented (its names are
skipped by the pass).

What the flag does not cover, and the rule for each:

* **Inline assembly and C code** that stores pointers into GC memory: call `_d_gcBarrier` yourself afterwards.
* **`core.atomic`** is covered (`atomicStore`, `atomicExchange`, `cas`, `casWeak` call the barrier under the version
  `D_GCBarrier`, which the flag defines).
* **Memory outside the window** (`malloc`, a stack, a global) needs no barrier, and the barrier ignores it.

To check a build, `plans/bench/core_bench/gcbarrier_codegen_check.sh` counts barrier calls in small functions, and
`mark_race.d` / `mark_race_glue.d` fail within seconds if a store is missed (see `testing.md`).

## 5. Runtime options

Environment variables, read at start-up:

| Variable | Default | Meaning |
|---|---|---|
| `SYMGC_CONCURRENT_MARK=0` | on where tracking exists | Use the stop-the-world mark (the safe fallback, and the baseline for comparisons) |
| `SYMGC_DIRTY=0` | on | Do not use the kernel tracker |
| `SYMGC_MARK_THREADS=n` | a quarter of the cores, 2 to 6 (all cores for a stop-the-world mark) | Threads that mark |
| `SYMGC_MARK_NICE=n` | 10 | Nice value of the mark threads (Linux) |
| `SYMGC_SWEEP_DUTY=n` | 50 | Percent of the time the background sweeper may run |
| `SYMGC_SWEEP_NICE=n` | 10 | Nice value of the sweeper (Linux) |
| `SYMGC_ADAPTIVE_LIMIT=0` | on | Use a fixed hard limit (the target plus a quarter) during the mark, instead of one that follows how much the heap grew in the last marks (`how-it-works.md`) |
| `SYMGC_CARD_SUMMARY=1` | off | With cards: also keep a summary byte per 64 KiB (faster remark at 8 GiB, slower stores with many threads) |
| `SYMGC_HEAP_RESERVE_GIB=n` | 256 (16 on Android and iOS) | With cards: address space to reserve at start-up for the memory that holds pointers, the most that part of the heap can grow to. The collector halves the request, down to 2 GiB, if the system will not give it |

druntime's own options still apply where they make sense: `--DRT-gcopt=parallel:N` sets the mark threads too.

## 6. Check that it works

* `--DRT-gcopt=gc:sdc` prints `using SYM GC!`.
* With cards, `nm mygame | grep __sd_gc_card_base` must find the card table. If it does not, the program was built
  without `-d-version=Symgc_cards` and falls back to the kernel tracker or a stop-the-world mark.
* Frame times: `GC.frameStats()` (this project's druntime) gives per-thread GC time; see `writing-code.md`.
* `-version=Symgc_phase_trace` prints every phase of every cycle, with its duration.

## 7. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `no property tlsGCData for ThreadBase` | Compiler older than 2.111 | Use DMD 2.112+ or an LDC with a 2.112+ frontend |
| `tlsGCData was not set for this thread!` (or `SIGILL` in `suspendDruntimeThreads`) | druntime 2.111 (GDC 15) and a second thread | Use a compiler with druntime 2.112+ |
| `undefined identifier GCTelemetry` | An older checkout of the fork | Update the fork; it builds without this project's druntime since 2026-10-12 |
| Programs run slower than with druntime's GC | A debug build of the collector | Build with `-b release` (dub) or `-O -release` |
| `symgc: cannot map the card table` or `cannot reserve address space for the heap` at start-up | `vm.overcommit_memory=2`, or an address-space limit (`ulimit -v`) smaller than 2 GiB plus its card table | Use `vm.overcommit_memory` 0 or 1, raise the limit, or build without cards |
| Out of memory with plenty of RAM free, built with cards | The program used up the window | Raise `SYMGC_HEAP_RESERVE_GIB` |
| Long pauses that grow with the heap | No write tracking: kernel older than 6.7, no cards, or `SYMGC_CONCURRENT_MARK=0` | Check the setup table above |
| A crash or a corrupted object only under steadygc | A bug, or C code writing GC pointers into GC memory | Rebuild with `-version=Symgc_verify` and report it (`testing.md`) |
