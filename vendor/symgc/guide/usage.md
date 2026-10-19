# Every way to use steadygc

Short recipes, one per way of using the collector. `integration.md` has the long explanations of the same steps,
`writing-code.md` says what to write once it runs, `platforms.md` says where it runs.

In all recipes `$SYMGC` is a clone of this repository. "Checked" means it was run on the project's test machine
(Linux 6.12, x86-64); "expected" means it follows from what was checked but was not run.

## Where the code is

| Repository | Branch | For |
|---|---|---|
| [leotada/symgc](https://github.com/leotada/symgc) | `main` | The collector, this documentation and `bench/`. Recipes A, B and C need only this |
| [leotada/dmd](https://github.com/leotada/dmd) | [`gc-phase0-discovery`](https://github.com/leotada/dmd/tree/gc-phase0-discovery) | The DMD and druntime of recipes D and F; `plans/` has the patch notes, the RFC and the benchmark sources |
| [leotada/ldc](https://github.com/leotada/ldc) | [`gc-card-marking`](https://github.com/leotada/ldc/tree/gc-card-marking) | The LDC of recipe E |

```sh
git clone https://github.com/leotada/symgc
git clone -b gc-phase0-discovery https://github.com/leotada/dmd      # recipes D and F
git clone -b gc-card-marking https://github.com/leotada/ldc          # recipe E
```

Phobos needs no fork: build the stock one against the project's druntime.

## Pick one

| | Way | Compiler | Concurrent mark | Needs | Status |
|---|---|---|---|---|---|
| A | [dub dependency](#a-a-dub-dependency) | DMD 2.112+ or LDC with a 2.112+ frontend | Linux 6.7+ (kernel tracker) | a clone | Checked with an unpatched druntime built from dmd `master`; expected with a 2.112 release |
| B | [One compiler command](#b-one-compiler-command-no-dub) | DMD, LDC, GDC 2.112+ druntime | as A | a clone | Checked (DMD) |
| C | [Choosing the collector at run time](#c-choosing-the-collector-at-run-time) | any of the above | — | nothing | Checked |
| D | [This project's DMD](#d-this-projects-dmd-and-the-game-engine-calls) | DMD built from the fork | as A | a dmd + Phobos build | Checked |
| E | [LDC with the card barrier](#e-ldc-with-the-card-barrier) | LDC built from the `gc-card-marking` branch | any Linux kernel, no page faults, lowest tail | an LDC build | Checked |
| F | [DMD with `-preview=gcbarrier`](#f-dmd-with--previewgcbarrier) | DMD built from the fork | any Linux kernel | a dmd, druntime and Phobos built with the flag | Checked |
| G | [GDC with the barrier plugin](#g-gdc-with-the-barrier-plugin) | GDC built with plugin support (GCC 15.3 tested) | any Linux kernel | a GCC build, the plugin, a libphobos built with it | Checked on Linux x86-64 |

Without a concurrent mark (an old kernel and no barrier) everything still works, with the mark as a pause and the
sweep still beside the program. Start with A or B; move to E or F when the kernel tracker's page faults or the kernel
version matter.

## A. A dub dependency

`dub.sdl`:

```sdl
name "mygame"
targetType "executable"
dependency "symgc" path="$SYMGC"
```

`source/app.d`:

```d
import symgc.gcobj;                                            // links the collector in
extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];   // selects it

void main() { /* ... */ }
```

```sh
dub build -b release --compiler=dmd      # or ldc2
./mygame
```

Build in release mode: dub compiles the collector with your settings and a debug collector is slow.

## B. One compiler command, no dub

The collector is plain D source. Compile it with the program:

```sh
# DMD
dmd -O -release -inline -version=Symgc_druntime_hooks -I$SYMGC/source \
    mygame.d $(find $SYMGC/source -name '*.d')

# LDC
ldc2 -O3 -release -d-version=Symgc_druntime_hooks -I$SYMGC/source \
    mygame.d $(find $SYMGC/source -name '*.d')

# GDC: a druntime of 2.112 or newer is needed (GDC 15 has 2.111 and fails with a second thread)
gdc -O2 -frelease -fversion=Symgc_druntime_hooks -I$SYMGC/source \
    mygame.d $(find $SYMGC/source -name '*.d') -o mygame
```

`-version=Symgc_druntime_hooks` lets the collector take over the array hooks (`~=`, capacity). To avoid compiling the
collector on every build, compile it once to an object (`-c`) or a static library and link that.

## C. Choosing the collector at run time

Linking the collector in does not turn it on. druntime picks the collector named by `gcopt`:

| How | Example |
|---|---|
| In the program | `extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];` |
| On the command line (overrides the program) | `./mygame --DRT-gcopt=gc:sdcq` |

`gc:sdc` prints `using SYM GC!` at start-up, `gc:sdcq` does not, and leaving `gcopt` out runs druntime's own GC. So
**one binary can be compared with itself**: run it with and without the option and compare frame times and memory.

The tuning knobs are environment variables read at start-up (`integration.md`, section 5). The ones you will use:

| Variable | Use |
|---|---|
| `SYMGC_CONCURRENT_MARK=0` | Stop-the-world mark: the baseline to compare against |
| `SYMGC_MARK_THREADS=n` | Threads that mark (default a quarter of the cores, 2 to 6) |
| `SYMGC_SWEEP_DUTY=n` | Percent of the time the background sweeper may run (default 50) |
| `SYMGC_ADAPTIVE_LIMIT=0` | Fixed memory limit during the mark, instead of one that follows the heap's growth |
| `SYMGC_HEAP_RESERVE_GIB=n` | With the card barrier: address space reserved at start-up (default 256) |

## D. This project's DMD and the game-engine calls

The fork's druntime adds calls to `core.memory.GC` made for frame loops: `frameStats` (collector time spent in each
thread, per frame), `excludeCurrentThread` (an audio thread the collector never stops), `step` (give the sweep the
time left in a frame) and `defrag` (give memory back at a loading screen). Build the compiler and Phobos from the
fork's branch (`integration.md`, section 4):

```sh
make -j$(nproc)                                      # the compiler and druntime
make -C ../phobos -j$(nproc) BUILD=release           # Phobos against this druntime
```

then use `generated/linux/release/64/dmd` as the compiler for recipe A or B. Guard the calls so the same code builds
with a stock compiler:

```d
import core.memory : GC;

static if (__traits(hasMember, GC, "excludeCurrentThread"))
    GC.excludeCurrentThread();      // in the audio thread, once, before it allocates anything
```

`writing-code.md` has the whole frame-loop example and the rules for audio threads.

## E. LDC with the card barrier

The compiler marks a small table (a "card" per 512 bytes) at each pointer store, so the collector knows what changed
during a mark without asking the kernel. No page faults, any kernel, and the lowest tail in the benchmarks. Build the
fork's `gc-card-marking` LDC with its runtime and Phobos built with the flag (`integration.md`, section 4), then:

```sh
ldc2 -O3 -release -gc-card-marking -d-version=Symgc_cards -d-version=Symgc_druntime_hooks \
     -I$SYMGC/source mygame.d $(find $SYMGC/source -name '*.d')
```

**Every piece of D code that stores pointers into the GC heap must be built with `-gc-card-marking`**, druntime and
Phobos included; a store made by code built without it can be missed by the concurrent mark, and an object lost.
`mark_race.d` finds this within seconds (`testing.md`).

## F. DMD with `-preview=gcbarrier`

The same barrier in DMD's backend, for a program built with DMD that cannot move to LDC. Build druntime and Phobos
with the flag into their own directory (`dmd_gcbarrier.sh libs` in `bench/` does it), then:

```sh
dmd -conf= -I<druntime>/import -I<phobos> -fPIC -O -release -inline -preview=gcbarrier \
    -version=Symgc_druntime_hooks -version=Symgc_cards -version=Symgc_druntime_cards \
    -I$SYMGC/source -defaultlib= mygame.d $(find $SYMGC/source -name '*.d') \
    <phobos>/generated/gcb/linux/release/64/libphobos2.a \
    -L-L<druntime>/generated/gcb/linux/release/64 -L-ldruntime -L-lpthread -L-lm -L-ldl -L-lz
```

The rules of E apply. The barrier is a plain byte store, valid on x86 only (`integration.md`, section 4, lists what it
does not cover: inline assembly and C code).

## G. GDC with the barrier plugin

The same barrier as a GCC plugin (the `gdc-gcbarrier` repository, a sibling of `symgc` and `ldc`; not published yet),
for a program built with GDC. A
distribution's GCC usually has no plugin headers, so the reference setup is GCC 15.3.0 built from source with
`--enable-languages=c,c++,d --enable-plugin`; the plugin README has the commands. Then build the plugin
(`make -C gdc-gcbarrier`), rebuild GCC's libphobos with it, and link that one:

```sh
make -C <gcc-build>/x86_64-pc-linux-gnu/libphobos clean
make -C <gcc-build>/x86_64-pc-linux-gnu/libphobos -j GDCFLAGS="-g -O2 -fplugin=<repo>/gdc-gcbarrier/gcbarrier.so"

gdc -O2 -fplugin=<repo>/gdc-gcbarrier/gcbarrier.so \
    -fversion=Symgc_cards -fversion=Symgc_druntime_hooks -fversion=SymGC \
    -I$SYMGC/source mygame.d $(find $SYMGC/source -name '*.d') \
    -static-libphobos -L<gcc-build>/x86_64-pc-linux-gnu/libphobos/src/.libs
```

(`bench/` and `plans/bench/core_bench/gdc_cards.sh` do the second command.) The plugin also defines
`version (D_GCBarrier)`; `-fversion=D_GCBarrier` is refused by gdc, which reserves every `D_*` name. The rules of E apply:
a store made by code built without the plugin can be missed. GCC 15 ships druntime 2.111, which has no thread-init hook;
the collector then attaches each druntime thread itself, with one limit: a thread-local constructor of another module
that allocates before `symgc.gcobj`'s runs on a thread the collector does not know yet, so keep such constructors free of
GC allocation.

## Check that it is running

* `--DRT-gcopt=gc:sdc` prints `using SYM GC!`.
* With the card barrier, `nm mygame | grep __sd_gc_card_base` finds the table. If it does not, the collector falls
  back to the kernel tracker or a stop-the-world mark.
* `-version=Symgc_phase_trace` prints every phase of every collection with its duration.
* `-version=Symgc_verify` builds a verifier that poisons freed memory and catches use after free: run your tests with it
  once.

## Go back

Run without `gcopt` for druntime's GC, or remove the dependency. Nothing else changes: the language and the library
see the same `GC` interface.

## Next

| Question | Page |
|---|---|
| What should my code do differently? | `writing-code.md` |
| How does a collection work, what still pauses? | `how-it-works.md` |
| Does it run on my OS? | `platforms.md` |
| How fast is it? | `benchmarks.md` and `../BENCHMARKS.md` |
| I found a bug / want to help test | `testing.md` |
