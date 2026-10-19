# Writing code for steadygc

The point of a collector that does not stop the program is that game code can be written the ordinary D way. This
page lists what that means in practice, the few things that still cost more than the collector, how to use the
game-engine calls, and the rules for C libraries.

## Allocate normally

* Use `new`, closures, `~=`, associative arrays, `format`, `.array`, ranges that allocate. No pools are needed.
* Do not call `GC.collect()` in the frame loop, and do not wrap levels in `GC.disable()`. The collector paces itself;
  forcing a full collection is the one way to get a long pause back. A `GC.collect()` at a loading screen is fine.
* Large pointer-free buffers cost the collector almost nothing: arrays of types without pointers (`ubyte[]`,
  `float[]`, `Vertex[]` where `Vertex` holds only numbers) are allocated `NO_SCAN` automatically and are never
  scanned. Keep textures, meshes, audio and level data in such arrays. Indices into arrays instead of pointers in big
  tables help twice: less to mark, and no barrier on the stores.

## What still costs more than the collector

These are the language's costs, not the GC's, and they show up in profiles of carelessly written games:

* **Shrink, then append.** `a = a[0 .. $ - 1]; a ~= x;` reallocates on every append, because the runtime cannot know
  nobody else uses the cut-off slot. Keep an index, or call `a.assumeSafeAppend()` after shrinking when you own the
  array. An A* written the naive way allocated 8 GiB/s in one of our tests.
* **Associative arrays allocate one node per entry.** In hot loops prefer arrays indexed by an id.
* **Closures that capture loop variables** allocate a context per iteration when they escape.

## The frame loop

With the druntime from this project, `core.memory.GC` has calls made for game loops. Guard them with `static if` so
the same code still builds with a stock compiler, where they do not exist:

```d
import core.memory : GC;
import core.time : Duration, MonoTime, msecs;

enum hasFrameStats = __traits(hasMember, GC, "frameStats");

struct GcHud
{
    Duration lastAlloc, lastCollect, lastPause;
    Duration frameAlloc, frameCollect, framePause; // this frame, this thread
}

void endOfFrame(ref GcHud hud, MonoTime frameStart, Duration frameBudget)
{
    static if (hasFrameStats)
    {
        // The times are totals since start-up: take the difference per frame.
        auto fs = GC.frameStats();
        hud.frameAlloc = fs.threadAllocTime - hud.lastAlloc;
        hud.frameCollect = fs.threadCollectTime - hud.lastCollect;
        hud.framePause = fs.threadPauseTime - hud.lastPause;
        hud.lastAlloc = fs.threadAllocTime;
        hud.lastCollect = fs.threadCollectTime;
        hud.lastPause = fs.threadPauseTime;
        // fs.isCycleActive, fs.usedSize and fs.numCollections are useful on a HUD too.
    }

    // Before waiting for vsync, give the time left in the frame to the sweep.
    static if (__traits(hasMember, GC, "step"))
    {
        auto left = frameBudget - (MonoTime.currTime - frameStart);
        if (left > 1.msecs)
            GC.step(left - 1.msecs);
    }
}
```

`GC.step` is optional: the sweep runs on its own thread anyway. It helps most on machines with few cores, where the
sweeper competes with the game for a core.

## Audio and other real-time threads

An audio callback must never wait for the GC. Exclude its thread once, when it starts:

```d
static if (__traits(hasMember, GC, "excludeCurrentThread"))
    GC.excludeCurrentThread();
```

The contract: an excluded thread is never stopped and its stack is never scanned, so

* it must not allocate on the GC heap: allocate its buffers before it starts, or with `malloc`;
* it must not hold the only reference to GC memory in a local variable: keep its data reachable from a global or a
  long-lived object.

In our test, a 1,000 Hz audio thread ran 28,556 ticks with no underrun through 27 collections.

## Loading screens and memory pressure

`GC.defrag()` (or the standard `GC.minimize()`) waits for the running sweep, returns completely empty slabs and every
free page to the OS, and returns the number of pages it gave back. Call it after unloading a level, or when the OS
reports memory pressure (on Android, `onTrimMemory`).

## C libraries

C libraries such as SDL, OpenGL, OpenAL and raylib have run under steadygc, with D pointers held by C code. The rules:

* **Holding and reading D pointers from C is fine**, as long as the object is also reachable from D (a global, a
  field, `GC.addRoot`), exactly as with druntime's GC.
* **C code writing a pointer to GC memory into GC memory**, while a collection may be running, is the one case the
  card barrier cannot see, because the C compiler did not emit it. A callback that stores a D object into a D array
  is D code and is fine; a C library filling a GC-allocated array of pointers is not. Give such libraries `malloc`
  memory and copy into D after the call, or register the memory with `GC.addRange` so it is scanned as a root in each
  pause. The kernel tracker (setup without cards) sees every write, C included.
* Do not hide pointers in integers or xor them; druntime's spec already forbids it, and a concurrent mark is less
  forgiving than a stop-the-world one.

## Checking that your program behaves

* `-version=Symgc_verify` builds the collector in verifier mode: freed memory is poisoned and checked when it is
  handed out again. Run your test suite with it once.
* The `mark_race.d` test in `plans/bench/core_bench/` is the canary for write tracking: it passes with cards or the
  kernel tracker and crashes when tracking is missing.
