module engine.core.gc;

@safe:

import core.time : Duration, usecs, hnsecs;
import core.memory : GC;

/**
 * 6-counter snapshot from steadygc hardware timers + collector profile stats.
 * All time fields are in nanoseconds.
 */
struct SteadyGcTimes {
    ulong pauseNs;          /// Total STW pause time across all cycles
    ulong workNs;           /// Total GC work (STW + concurrent mark/sweep assist)
    ulong pauseCount;       /// Total number of STW pauses (2 per concurrent cycle)
    ulong cycleCount;       /// Total completed GC cycles
    ulong maxPauseNs;       /// Worst individual STW pause duration
    ulong slowAllocWaitNs;  /// Total time mutator threads waited in slow-path allocation
    ulong binLockWaitNs;    /// Time spent waiting on thread-bin locks
    ulong freshSlabNs;      /// Time spent acquiring fresh slabs from page filler
    ulong fillerLockWaitNs; /// Time spent waiting on page-filler locks
}

/**
 * Per-frame delta metrics computed without heap allocations in App.endFrame().
 */
struct GcFrameDelta {
    ulong framePauseNs;     /// STW pause during this frame
    ulong frameWorkNs;      /// Concurrent work during this frame
    ulong frameSlowAllocNs; /// Slow allocation wait time during this frame
    uint  framePauseCount;  /// STW pauses during this frame
    uint  frameCycles;      /// Cycles completed during this frame
    ulong maxPauseNs;       /// Worst pause seen so far
}

// C ABI extern declarations matching vendor/symgc/source/d/gc/capi.d & gctime.d
extern (C) nothrow @nogc {
    void __sd_gc_step(ulong maxTimeHns);
    size_t __sd_gc_defrag();
    void __sd_gc_exclude_current_thread();
    void __sd_gc_include_current_thread();
    bool __sd_gc_is_thread_excluded();
    void __sd_gc_card_range(const(void)* dst, size_t size);
    void __sd_gc_time_total(ulong* dst);
    void __sd_gc_time_thread(ulong* dst);
    void __sd_gc_profile_stats(ulong* dst);
}

// Card window globals exported by druntime / steadygc
extern (C) extern __gshared size_t __sd_gc_card_lo;
extern (C) extern __gshared size_t __sd_gc_card_n;
extern (C) extern __gshared ubyte* __sd_gc_card_base;

/**
 * Returns true if the steadygc collector (gc:sdcq / gc:sdc) is active at runtime.
 * Because steadygc is attached optionally (enabled via `--DRT-gcopt=gc:sdcq` or
 * `rt_options`), this returns false when running under the stock druntime GC.
 */
bool gcIsSteadyGcActive() nothrow @nogc {
    return () @trusted {
        return __sd_gc_card_base !is null;
    }();
}

/**
 * Step incremental background sweeping during remaining frame budget / slack time.
 * Safe to call every frame in App.endFrame() before vsync presentation.
 * No-op if running on stock druntime GC.
 */
void gcStepFrameSlack(Duration slack) nothrow @nogc {
    if (!gcIsSteadyGcActive() || slack < 250.usecs) return;
    const ulong hns = cast(ulong) slack.total!"hnsecs";
    // Bound the slack slice up to 2000us (20_000 hnsecs)
    const ulong boundedHns = hns > 20_000 ? 20_000 : hns;
    () @trusted {
        __sd_gc_step(boundedHns);
    }();
}

/**
 * Perform defragmentation: drain quarantine and release physical pages back to the OS.
 * Call during scene transitions, play-mode stop, hot-reload unloads, and low-memory events.
 * Safe no-op if running on stock druntime GC.
 */
size_t gcDefragment() nothrow @nogc {
    if (!gcIsSteadyGcActive()) return 0;
    return () @trusted {
        return __sd_gc_defrag();
    }();
}

/**
 * Exclude the calling thread from stop-the-world GC pause handshakes.
 * Dedicated real-time audio threads or pure @nogc POD worker threads should call this on entry.
 */
void gcExcludeCurrentThread() nothrow @nogc {
    if (!gcIsSteadyGcActive()) return;
    () @trusted {
        __sd_gc_exclude_current_thread();
    }();
}

/**
 * Re-include the calling thread in stop-the-world GC pause handshakes.
 */
void gcIncludeCurrentThread() nothrow @nogc {
    if (!gcIsSteadyGcActive()) return;
    () @trusted {
        __sd_gc_include_current_thread();
    }();
}

/**
 * Check if the calling thread is currently excluded from GC pause handshakes.
 */
bool gcIsThreadExcluded() nothrow @nogc {
    if (!gcIsSteadyGcActive()) return false;
    return () @trusted {
        return __sd_gc_is_thread_excluded();
    }();
}

/**
 * Explicit card barrier for non-D code (C libraries, SDL3/WGPU callbacks, memcpy)
 * that bulk-writes pointers into GC-managed memory.
 * Safe even before steadygc initializes (becomes a branch-predicted no-op).
 */
void gcBarrierRange(scope const(void)* dst, size_t size) nothrow @nogc {
    if (dst is null || size == 0) return;
    () @trusted {
        __sd_gc_card_range(dst, size);
    }();
}

/**
 * Query total GC telemetry across all threads since process start.
 * Falls back to core.memory.GC.profileStats() when running on stock druntime GC.
 */
SteadyGcTimes gcTotalTimes() nothrow @nogc {
    SteadyGcTimes t;
    if (gcIsSteadyGcActive()) {
        ulong[6] times = 0;
        ulong[5] prof = 0;
        () @trusted {
            __sd_gc_time_total(times.ptr);
            __sd_gc_profile_stats(prof.ptr);
        }();
        // GcTimeKind order: 0=Alloc, 1=Collect, 2=Pause, 3=BinLock, 4=FreshSlab, 5=FillerLock
        t.slowAllocWaitNs  = times[0];
        t.workNs           = times[1] + times[2];
        t.pauseNs          = times[2];
        t.binLockWaitNs    = times[3];
        t.freshSlabNs      = times[4];
        t.fillerLockWaitNs = times[5];
        // profileStats order: 0=numCollections, 1=totalCollectionTime(hns), 2=totalPauseTime(hns), 3=maxPauseTime(hns)
        t.cycleCount       = prof[0];
        t.pauseCount       = prof[0] * 2;
        t.maxPauseNs       = prof[3] * 100;
    } else {
        const ps = GC.profileStats();
        t.cycleCount = ps.numCollections;
        t.pauseCount = ps.numCollections;
        t.pauseNs    = cast(ulong) ps.totalPauseTime.total!"nsecs";
        t.workNs     = cast(ulong) ps.totalCollectionTime.total!"nsecs";
        t.maxPauseNs = cast(ulong) ps.maxPauseTime.total!"nsecs";
    }
    return t;
}

/**
 * Query GC telemetry for the calling thread.
 */
SteadyGcTimes gcThreadTimes() nothrow @nogc {
    SteadyGcTimes t;
    if (gcIsSteadyGcActive()) {
        ulong[6] times = 0;
        () @trusted {
            __sd_gc_time_thread(times.ptr);
        }();
        t.slowAllocWaitNs  = times[0];
        t.workNs           = times[1] + times[2];
        t.pauseNs          = times[2];
        t.binLockWaitNs    = times[3];
        t.freshSlabNs      = times[4];
        t.fillerLockWaitNs = times[5];
    }
    return t;
}

/**
 * Compute the per-frame delta from the previous snapshot without allocating memory.
 */
GcFrameDelta gcComputeFrameDelta(ref SteadyGcTimes prevTimes) nothrow @nogc {
    const SteadyGcTimes cur = gcTotalTimes();
    GcFrameDelta delta;

    delta.framePauseNs     = cur.pauseNs >= prevTimes.pauseNs ? (cur.pauseNs - prevTimes.pauseNs) : 0;
    delta.frameWorkNs      = cur.workNs >= prevTimes.workNs ? (cur.workNs - prevTimes.workNs) : 0;
    delta.frameSlowAllocNs = cur.slowAllocWaitNs >= prevTimes.slowAllocWaitNs ? (cur.slowAllocWaitNs - prevTimes.slowAllocWaitNs) : 0;
    delta.framePauseCount  = cur.pauseCount >= prevTimes.pauseCount ? cast(uint)(cur.pauseCount - prevTimes.pauseCount) : 0;
    delta.frameCycles      = cur.cycleCount >= prevTimes.cycleCount ? cast(uint)(cur.cycleCount - prevTimes.cycleCount) : 0;
    delta.maxPauseNs       = cur.maxPauseNs;

    prevTimes = cur;
    return delta;
}

/**
 * Query the reserved card window size in bytes (256 GiB on desktop, 16 GiB on mobile,
 * or 0 if running on stock druntime GC).
 */
size_t gcCardWindowBytes() nothrow @nogc {
    return () @trusted {
        return __sd_gc_card_n << 9; // 512 bytes per card
    }();
}

/**
 * RAII guard to safely exclude a worker thread during pure @nogc operations.
 */
struct ScopedGcExcludedThread {
    @disable this(this);

    static ScopedGcExcludedThread enter() nothrow @nogc {
        gcExcludeCurrentThread();
        ScopedGcExcludedThread g;
        return g;
    }

    ~this() nothrow @nogc {
        gcIncludeCurrentThread();
    }
}

unittest {
    // Basic API test: safe to call even without active steadygc
    gcStepFrameSlack(Duration.zero);
    gcStepFrameSlack(100.usecs); // below threshold, no-op
    gcStepFrameSlack(500.usecs);
    gcStepFrameSlack(50_000.usecs); // capped to 20_000 hnsecs

    // Defragment safe no-op on stock GC
    const defragged = gcDefragment();
    assert(defragged >= 0);

    // Thread exclusion guard
    {
        auto guard = ScopedGcExcludedThread.enter();
        // Excluded
    }

    // Barrier range test
    int[16] dummy;
    gcBarrierRange(dummy.ptr, dummy.sizeof);

    // Telemetry test
    SteadyGcTimes t = gcTotalTimes();
    GcFrameDelta delta = gcComputeFrameDelta(t);
}
