# Helping test steadygc

This is a preview. What it needs most is reports from programs and machines other than the one it was developed on:
other operating systems, other CPUs, other compilers, and real games. This page says what to run and what to send.

## Try it on your own program

The cheapest useful test: build your program once with steadygc linked in (`integration.md`), then run the same binary
twice.

```sh
./mygame                          # druntime's GC
./mygame --DRT-gcopt=gc:sdc       # steadygc (prints "using SYM GC!")
```

Compare what you care about: frame times (p50, p99, worst, frames over 16.7 ms), memory, load times. If your program
has a test suite, run it under steadygc too (`--DRT-gcopt=gc:sdcq`), and once with the collector built in verifier
mode (`-version=Symgc_verify`), which catches use-after-free in the collector or in your program.

## The benchmark kit

The programs live in `plans/bench/core_bench/` of the dmd repository. They are written the careless way on purpose
(no pools, `new` everywhere, closures, rebuilt arrays, formatted strings) and print one line of frame statistics.

| Program | What it models | Arguments used for the published numbers |
|---|---|---|
| `bullet_hell_stress.d` | A shooter that churns garbage with few live objects | `30 2048 100000 0.05 256 0` (30 s, 2 GiB level, 100k bullets/s, +256 B per shot); the last argument `1` disables collection, as the reference for the game's own cost |
| `bullet_hell.d` | The same game with a heavy per-frame cost | `30 2048 40000` |
| `aaa_sim.d` | City builder, RTS and open world with 6 job threads and 2 GiB of assets | `city 60 2048 6 0 500000`, `rts 60 2048 6 0 100000`, `openworld 60 2048 6 0 100000` |
| `gcb.d` | Allocation throughput and fragmentation | `alloc 1 8000000`, `alloc 8 4000000`, `frag 3000000 100000` |

`dmd_bench.sh` builds all of them with DMD (druntime's GC, upstream symgc, steadygc with and without the concurrent
mark) and with the card-barrier LDC, runs them, and writes one line per run to `results.txt`. Read it before running
it: the paths at the top point at the build locations of the project.

Run benchmarks on an idle machine, plugged in, and note the CPU frequency setting
(`/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` and `energy_performance_preference` on Linux): a
power-saving setting moves frame times a lot.

## The correctness battery, for anyone porting to a new OS

In `plans/bench/core_bench/`:

| Test | Passes when |
|---|---|
| `mark_race.d` | Pointers moved through locals during collections are never lost. Crashes when write tracking is missing, which makes it the canary for any port of the barrier or a tracker |
| `finalizer_order.d` | A destructor never sees another dead object's memory reused |
| `phobos_stress.d` | A mix of Phobos code allocating from several threads runs clean |
| `thread_exit_race.d` | Threads exiting during a concurrent mark do not crash it |
| `cards_window.d` (run it with `cards_window.sh`) | With the card barrier: the window exists before `main` and holds the memory with pointers; a store marks its card and only that one; stores and copies to `malloc` memory, ranges at odd addresses (below and above the window, with a tag in the top byte) mark nothing; a range running past the end is cut; the collector settles for a smaller window when the address space is limited. Run it first on any new platform |
| `mark_race_glue.d` | Eight ways of storing a pointer into a node (field, element, array literal, struct literal, closure, `atomicStore`, `cas`, a copy) lose nothing. Built without the barrier it reports 1,600 to 1,900 violations in a run. The test for a compiler's barrier pass |
| `cards_precision.d` | The barrier marks the cards of what was written and no others: an array, a field of every object, a struct array, a copy, the same field 100,000 times, a neighbour nobody wrote to. A barrier that marks more makes the collector rescan for nothing |
| `gcbarrier_codegen_check.sh` | DMD only: counts the calls to the barrier in small functions (a field store has one, an int store none, a global none, an array literal one per element); run with and without `EXTRA=-fPIC` |

DMD with the barrier is built with `plans/bench/core_bench/dmd_gcbarrier.sh build OUT FILE.d`, which links the
instrumented druntime and Phobos; run the programs with `--DRT-gcopt=gc:sdcq`.

And the collector's unit tests, from the dmd repository root:

```sh
D=generated/linux/release/64/dmd
$D -unittest -main -g -version=Symgc_testing -version=Symgc_druntime_hooks \
   -Isymgc/source -Idruntime/import -defaultlib= -L-L$PWD/generated/linux/release/64 \
   -L-ldruntime -of=symgc_ut $(find symgc/source -name "*.d") && ./symgc_ut
```

All 113 pass on Linux x86-64.

## What to send

Copy this, fill it in, and attach the full output of the runs:

```markdown
**Machine:** CPU, cores/threads, RAM
**OS:** name, version, kernel (uname -r)
**CPU frequency setting:** governor / energy preference, or "default"
**Compiler:** dmd/ldc2/gdc --version (first line)
**Setup:** plugin / plugin + project druntime / card barrier
**Flags:** compiler flags and --DRT-gcopt options; SYMGC_* environment variables
**Program:** benchmark name and arguments, or your project (what it does, threads, live heap size)
**Result:** the frame_p50_us line (or your own numbers) for druntime's GC and for steadygc
**Problems:** crash output, backtrace (gdb/lldb `bt`), whether -version=Symgc_verify reports anything
```

Until the fork has a public issue tracker, send reports to the maintainer of this work.
