# Benchmarks and correctness tests

Self-contained: everything here builds against the collector in `../source` and needs only a D compiler.
`BENCHMARKS.md` (one level up) has the results; this page says how to produce them.

## Quick start

```sh
# One program, three collectors (druntime's GC, steadygc with a stop-the-world mark, steadygc with a concurrent mark)
bench/compare.sh bullet_hell_stress.d 30 2048 100000 0.05 256

# The correctness battery (about two minutes)
bench/correctness.sh
```

`compare.sh` prints one line per collector with the frame statistics and the peak memory. The number to read first is
`max`: the longest frame of the run, the one that was missed. `DC=ldc2` (or `gdc`) selects the compiler, `SYMGC=`
another source directory, `EXTRA=` more flags.

Needs: Linux, a D compiler with a druntime of 2.112 or newer (`platforms.md` in the guide), and `/usr/bin/time`.
The concurrent mark needs Linux 6.7+ in this setup (the kernel tracker); on an older kernel the "concurrent" line
falls back to the stop-the-world mark, which `compare.sh` does not tell you. Run on an idle machine, plugged in, and
note the CPU frequency setting: it moves frame times a lot.

## The programs

All run headless and paced at 60 frames per second, and are written the careless way on purpose: `new` everywhere,
closures, rebuilt arrays, formatted strings, no pools.

| Program | What it models | Arguments of the published numbers |
|---|---|---|
| `bullet_hell_stress.d` | A shooter that churns garbage with few live objects | `30 2048 100000 0.05 256 0`: seconds, level MiB, bullets per second, bullet life scale, extra bytes per shot, `1` to disable the collector (the game's own cost) |
| `bullet_hell.d` | The same game with a heavy per-frame cost | `30 2048 40000` |
| `aaa_sim.d` | City builder, RTS, open world with six job threads | `city 60 2048 6 0 500000`, `rts 60 2048 6 0 100000`, `openworld 60 2048 6 0 100000`: mode, seconds, asset MiB, job threads, no-GC flag, population |
| `entity_init.d` | A scene of 10 million linked entities with eight pointers each, rewritten every frame | `60 1024 20000 2000 60`: seconds, live MiB, entities relinked per frame, entities created per frame, frames per second (`0` is unpaced, which no collector keeps up with) |
| `gcb.d` | Allocation throughput and fragmentation (no frames) | `alloc 1 8000000`, `alloc 8 4000000`, `frag 3000000 100000` |

## The correctness battery

| Test | Passes when |
|---|---|
| `mark_race.d` | Pointers moved through locals during collections are never lost. Crashes when write tracking is missing: the canary for any port of the barrier or tracker |
| `mark_race_glue.d` | Eight ways of storing a pointer into a node (field, array literal, struct literal, closure, append, associative array, atomic store, compare-and-swap) lose nothing. The test for a compiler's barrier pass |
| `finalizer_order.d` | A destructor never sees another dead object's memory reused |
| `thread_exit_race.d` | Threads exiting during a concurrent mark do not crash it |
| `cards_window.d`, `cards_precision.d` | With the card barrier only: the window exists before `main`, a store marks exactly its card, nothing outside the window is marked. Run them first on a new platform (`../guide/testing.md`) |

## With the card barrier

`dmd_gcbarrier.sh` builds a program with this project's DMD and `-preview=gcbarrier` (druntime and Phobos are built
with the flag by its `libs` command):

```sh
export DMD_REPO=<this project's dmd checkout> PHOBOS=<phobos checkout>
bench/dmd_gcbarrier.sh libs
bench/dmd_gcbarrier.sh build /tmp/mark_race bench/mark_race.d
/tmp/mark_race 20 --DRT-gcopt=gc:sdcq
```

For LDC, `guide/usage.md` (recipe E) has the command line.

## Reading the numbers

* Compare the same binary under different options, not different binaries: linking a collector changes what the
  other collector scans as roots.
* "Frames over 16 ms" is the count of dropped frames at 60 fps; p99.9 and the worst frame are what a player notices.
* A run with the collector disabled (`bullet_hell_stress.d`'s last argument, `aaa_sim.d`'s no-GC flag) is the game's
  own cost: the collector cannot be better than that.
