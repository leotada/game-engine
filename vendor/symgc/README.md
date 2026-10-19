# steadygc: a garbage collector for D that does not stop your game

steadygc is a fork of [symgc](https://github.com/symmetryinvestments/symgc), the [SDC](https://github.com/snazzy-d/sdc)
garbage collector ported to ordinary D. It keeps symgc's allocator (no global lock) and moves the two expensive parts
of a collection, the **mark** and the **sweep**, beside the program. A game written the ordinary D way, with `new`,
closures, `~=` and associative arrays and no pools, should not lose a frame to the collector.

> **Status: a preview for testing.** Everything is measured on Linux x86-64. Windows, macOS and Android code exists but
> has not been run (`guide/platforms.md`). It is meant to be tried, measured and reported on, not shipped yet.

## What it does

A shooter that creates 100,000 short-lived bullets per second on top of a 2 GiB level, 30 s at 60 fps, no object
pools (Ryzen 7 3800X, Linux 6.12, DMD 2.113):

| Collector | Worst frame | p99.9 frame | Frames over 16 ms (of 1,800) |
|---|---|---|---|
| druntime's GC | 141 ms | 138 ms | 4 |
| Upstream symgc | 28.0 ms | 24.7 ms | 3 |
| **steadygc** (DMD, no compiler change) | **1.3 ms** | 1.1 ms | **0** |
| **steadygc** (LDC with the card barrier) | **0.87 ms** | 0.77 ms | **0** |
| No collection at all (the game's own cost) | 0.98 ms | 0.97 ms | 0 |

And a city builder with six job threads allocating, 500,000 citizens, 2 GiB of assets, 60 s:

| Collector | Median frame | Worst frame | Frames over 16 ms (of 3,600) | Peak memory |
|---|---|---|---|---|
| druntime's GC | 9.1 ms | 137-193 ms | 37 | 3.0 GB |
| Upstream symgc | 3.8 ms | 107-113 ms | 40 | 2.8 GB |
| **steadygc** (DMD) | 4.3 ms | **9.7 ms** | **0** | 3.6 GB |
| **steadygc** (LDC with the card barrier) | 3.1 ms | **6.9 ms** | **0** | 3.1 GB |

The price is memory: the heap keeps growing while a cycle runs beside the program, so the peak is higher than upstream's
(3.6 GB against 2.8-3.0 GB in the city model, 11.3 GB against 10.9 GB at the 8 GiB level). All numbers, conditions and the commands that produced them: [`BENCHMARKS.md`](BENCHMARKS.md).

## Try it in five minutes

Linux, DMD 2.112+ (or the project's DMD, see below). In an empty directory:

```sh
git clone https://github.com/leotada/symgc
mkdir -p source && cat > source/app.d <<'EOF'
import symgc.gcobj;                                          // links the collector in
extern(C) __gshared string[] rt_options = ["gcopt=gc:sdc"];  // selects it

class Node { Node next; int[8] payload; }

void main()
{
    import std.stdio : writeln;
    Node head;
    foreach (i; 0 .. 20_000_000)
    {
        auto n = new Node;
        n.next = (i % 1000) ? head : null;   // the newest chain stays alive, older ones become garbage
        head = n;
    }
    writeln("done");
}
EOF
cat > dub.sdl <<'EOF'
name "trygc"
targetType "executable"
dependency "symgc" path="symgc"
EOF
dub build -b release
./trygc                          # prints "using SYM GC!", then done
./trygc --DRT-gcopt=gc:conservative   # the same binary with druntime's GC
```

Always build in release mode (`-b release`): the collector is compiled with your settings, and a debug collector is slow.

## Ways to use it

| Way | You need | You get | Recipe |
|---|---|---|---|
| **A. dub dependency** | DMD 2.112+ or LDC with a 2.112+ frontend | The allocator without a global lock, the paced concurrent sweep, and (Linux 6.7+) the concurrent mark through the kernel's dirty-page tracker | [`guide/usage.md`](guide/usage.md#a-a-dub-dependency) |
| **B. One compiler command** | The same, without dub | The same | [`guide/usage.md`](guide/usage.md#b-one-compiler-command-no-dub) |
| **C. Switch at run time** | Nothing | One binary, two collectors: `--DRT-gcopt=gc:sdcq` or not | [`guide/usage.md`](guide/usage.md#c-choosing-the-collector-at-run-time) |
| **D. The project's DMD** | A dmd built from the fork | `GC.frameStats`, `excludeCurrentThread` (audio threads), `step`, `defrag` | [`guide/usage.md`](guide/usage.md#d-this-projects-dmd-and-the-game-engine-calls) |
| **E. LDC with the card barrier** | An LDC built from the `gc-card-marking` branch | The concurrent mark on any kernel, without page faults, with the lowest tail | [`guide/usage.md`](guide/usage.md#e-ldc-with-the-card-barrier) |
| **F. DMD with `-preview=gcbarrier`** | A dmd built from the fork | The same card barrier in DMD, for programs that cannot move to LDC | [`guide/usage.md`](guide/usage.md#f-dmd-with--previewgcbarrier) |

D, E and F need the compiler forks, [leotada/dmd](https://github.com/leotada/dmd) and
[leotada/ldc](https://github.com/leotada/ldc); [`guide/usage.md`](guide/usage.md#where-the-code-is) says which branch.
Start with A or B. Move to E or F if page faults from the kernel tracker show up in your frame times (a game that
writes to the pages of tens of thousands of live objects every frame) or your kernel is older than 6.7.

## What changes in your code

Nothing, to start with. Then, optionally and only with the project's druntime (guard them with `static if`):

```d
import core.memory : GC;

static if (__traits(hasMember, GC, "excludeCurrentThread"))
    GC.excludeCurrentThread();          // in the audio thread: never stopped, never waits for the GC
static if (__traits(hasMember, GC, "step"))
    GC.step(timeLeftInTheFrame);        // give the sweep the idle time before vsync
```

Do not call `GC.collect()` in the frame loop and do not wrap levels in `GC.disable()`: the collector paces itself.
[`guide/writing-code.md`](guide/writing-code.md) has the rules (what still costs more than the collector, the audio
thread contract, C libraries).

## How it works, in a minute

```
program threads  ===========|=|=================================|=|=========================
                            start                          remark
                            pause                           pause
GC thread                     [ mark, beside the program ][rounds]  [ finalize ][ sweep, paced ]
mark threads (2-6)            [ mark ................... ]
```

* **Two short pauses per cycle**, a fraction of a millisecond (0.1 to 0.6 ms at 2 GiB of live data): list the roots,
  and fix up what the program wrote during the mark. Everything else runs on other threads.
* **Write tracking** tells the collector what the program changed during the mark: a compiler-emitted barrier that
  marks a 512-byte "card" per pointer store (LDC, DMD), or the kernel's dirty-page tracker (Linux 6.7+, any compiler).
* **A paced sweep** returns memory a block at a time, holding a lock for about 10 µs per step, at most half the time.
* **Objects allocated during a mark are born live**, so the heap grows while a cycle runs: that is the memory price.

[`guide/how-it-works.md`](guide/how-it-works.md) is the full account.

## Where it runs

| | Status |
|---|---|
| Linux x86-64 | **Measured**: every number in this repository |
| Linux arm64, Windows x64, Android arm64 | Compiles with the card barrier; never run |
| macOS, iOS | Does not compile yet (no waiter, different thread-stopping protocol) |

Compilers: DMD 2.112+ and LDC with a 2.112+ frontend. Checked with the project's DMD 2.113 and with an unpatched
druntime built from dmd's `master`; a released 2.112 is expected to work and has not been tried. GDC 15 has druntime
2.111 and fails in programs with a second thread. Details: [`guide/platforms.md`](guide/platforms.md).

## Limits worth knowing

* The heap is larger while a cycle runs (up to 30% over upstream symgc in the benchmarks, 4% in the largest one).
* A program that rewrites its whole heap faster than the collector can scan it (unpaced loops, 50 million pointer
  stores a second) overloads any concurrent collector; frames stall there.
* Single-thread allocation throughput and a fragmentation-heavy workload are slower than druntime's GC (0.79x and
  0.54x); with eight threads the allocator is 8.6x faster.
* C code that writes GC pointers into GC memory during a mark is invisible to the card barrier
  ([`guide/writing-code.md`](guide/writing-code.md#c-libraries)).

## Repository layout

| Path | What |
|---|---|
| `source/` | The collector (`symgc/gcobj.d` is the entry point) |
| `guide/` | The documentation: [`guide/README.md`](guide/README.md) is its index |
| `bench/` | Benchmarks and the correctness battery, runnable with one command each ([`bench/README.md`](bench/README.md)) |
| `test/`, `example/` | The collector's unit tests and a minimal dub example |
| `BENCHMARKS.md` | The results, summarised |

## Testing it

```sh
bench/correctness.sh            # the race and ordering tests against the collector
bench/compare.sh bullet_hell_stress.d 30 2048 100000 0.05 256    # your machine against the table above
```

Reports from other machines, operating systems and real programs are what the preview needs most:
[`guide/testing.md`](guide/testing.md) says what to run and has a template for the report.

## Credits and licence

MIT licence (`LICENCE`). The collector is SDC's, by Amaury Sachet, ported to D by Steven Schveighoffer (symgc). The
latency work (concurrent mark and sweep, card barrier, game-engine controls, compiler passes) is documented patch by
patch, with the measurement behind each change, in [`guide/`](guide/) and the patch notes of the project.
[Symmetry Investments](https://symmetryinvestments.com/) sponsors symgc.

---

# Upstream README: SDC Garbage collector, ported to normal D

> The text below is upstream symgc's README. It still describes the base collector; steadygc's own documentation is above
> and in [`guide/README.md`](guide/README.md).

This is a port of the [SDC](https://github.com/snazzy-d/sdc) garbage collector to D code that builds with DMD/LDC/gdc.

The idea is to extract the GC portions of the SDC runtime (and everything needed) in order to be able to build using standard compilers.

## Requirements

### OS/Arch

* Intel/AMD 64-bit CPU.
* AArch64 Linux 4k pages tested only!
* Linux or Windows (so far)

### Compiler
* ~~DMD 2.111 -> Linux only, does not include features needed for Windows support.~~ EDIT: this is not actually correct, and further tests have shown that Fiber-based cases do not work properly. For that reason, I recommend waiting for 2.112.
* DMD 2.112 (or unreleased master) or later. This is required for Windows support. It will also increase Linux performance.

## Using

In order to use symgc, you should import the `symgc.gcobj` module. This will incorporate the symgc garbage collector as an option for your code to use. In order to use this GC, you must give druntime the name `sdc` as the gc requested. There are 2 ways to do this:

1. Use an `rt_options` static configuration. e.g.:

```d
extern(C) __gshared rt_options = ["gcopt=gc:sdc"];
```

2. Pass the runtime parameter `--DRT-gcopt=gc:sdc` when starting your program.

Without either of these, your program will NOT use the symgc, but the default D conservative GC.

Using the GC in this way will print the message "using SYM GC!" to the console on stdout. If you wish to avoid this message, you can use the gc option `sdcq` instead of `sdc`.

Note that if you use symgc as a dub dependency, it will be copmpiled in the same mode as your code. This means, if you build in debug mode (the default), then the GC will not be optimized.

We are working on getting this set up as a dub dependency so you can include the GC optimized, regardless of your project's build settings.

## Performance expectations

In our testing, the GC performs very well in terms of maximum physical RAM required. In some cases saving over 50% of the RAM needed for certain programs. This is likely to be the case for very high memory usage programs, but not nesessarily for small memory programs.

The performance of collection cycles is still a work in progress, and we are hoping to make this more efficient, but at the moment, some tests run much slower than the default GC, and some run faster.

Multithreaded performance should be much better than the default GC, as symgc does not have a global lock.

## Todo

- [ ] Provide mechanism to always include optimized GC.
- [X] ARM 64-bit support.
- [ ] ARM 64-bit support with 16k pages.
- [ ] Mac/FreeBSD support.
- [ ] Explore tuning parameters for memory consumption/performance
- [ ] SIMD improvements for scanner.

## Acknowledgements

[Symmetry Investments](https://symmetryinvestments.com/) is sponsoring this work.
