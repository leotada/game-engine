module engine.core.gc;

@safe:

import core.time : Duration, usecs, hnsecs;
import core.memory : GC;

/**
 * 6-counter snapshot from steadygc hardware timers.
 * All fields are in nanoseconds / counts.
 */
struct SteadyGcTimes {
    ulong pauseNs;          /// Total STW pause time across all cycles
    ulong workNs;           /// Total GC work (STW + concurrent mark/sweep)
    ulong pauseCount;       /// Total number of STW pauses (2 per cycle)
    ulong cycleCount;       /// Total completed GC cycles
    ulong maxPauseNs;       /// Worst individual STW pause duration
    ulong slowAllocWaitNs;  /// Total time mutator threads waited in slow-path allocation
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

// C ABI extern declarations for steadygc (vendor/symgc/source/d/gc/capi.d & gctime.d)
extern (C) nothrow @nogc {
    void __sd_gc_step(ulong usecs);
    size_t __sd_gc_defrag();
    void __sd_gc_exclude_current_thread();
    void __sd_gc_include_current_thread();
    bool __sd_gc_is_thread_excluded();
    void __sd_gc_card_range(const(void)* dst, size_t size);

    void __sd_gc_time_total(
        ulong* pauseNs,
        ulong* workNs,
        ulong* pauseCount,
        ulong* cycleCount,
        ulong* maxPauseNs,
        ulong* slowAllocWaitNs
    );

    void __sd_gc_time_thread(
        ulong* pauseNs,
        ulong* workNs,
        ulong* pauseCount,
        ulong* cycleCount,
        ulong* maxPauseNs,
        ulong* slowAllocWaitNs
    );
}

// Card window globals exported by druntime / steadygc
extern (C) extern __gshared size_t __sd_gc_card_lo;
extern (C) extern __gshared size_t __sd_gc_card_n;
extern (C) extern __gshared ubyte* __sd_gc_card_base;

/**
 * Step incremental background sweeping during remaining frame budget / slack time.
 * Safe to call every frame in App.endFrame() before vsync presentation.
 */
void gcStepFrameSlack(Duration slack) nothrow @nogc {
    if (slack <= Duration.zero) return;
    const ulong us = cast(ulong) slack.total!"usecs";
    // Bound the slack slice to 250us .. 2000us so we never overrun the vsync deadline
    const ulong boundedUs = us > 2000 ? 2000 : (us < 250 ? 250 : us);
    () @trusted {
        __sd_gc_step(boundedUs);
    }();
}

/**
 * Perform defragmentation: drain quarantine and release physical pages back to the OS.
 * Call during scene transitions, play-mode stop, hot-reload unloads, and low-memory events.
 */
size_t gcDefragment() nothrow @nogc {
    return () @trusted {
        return __sd_gc_defrag();
    }();
}

/**
 * Exclude the calling thread from stop-the-world GC pause handshakes.
 * Dedicated real-time audio threads or pure @nogc POD worker threads should call this on entry.
 */
void gcExcludeCurrentThread() nothrow @nogc {
    () @trusted {
        __sd_gc_exclude_current_thread();
    }();
}

/**
 * Re-include the calling thread in stop-the-world GC pause handshakes.
 */
void gcIncludeCurrentThread() nothrow @nogc {
    () @trusted {
        __sd_gc_include_current_thread();
    }();
}

/**
 * Check if the calling thread is currently excluded from GC pause handshakes.
 */
bool gcIsThreadExcluded() nothrow @nogc {
    return () @trusted {
        return __sd_gc_is_thread_excluded();
    }();
}

/**
 * Explicit card barrier for non-D code (C libraries, SDL3/WGPU callbacks, memcpy)
 * that bulk-writes pointers into GC-managed memory.
 */
void gcBarrierRange(const(void)* dst, size_t size) nothrow @nogc {
    if (dst is null || size == 0) return;
    () @trusted {
        __sd_gc_card_range(dst, size);
    }();
}

/**
 * Query total GC telemetry across all threads since process start.
 */
SteadyGcTimes gcTotalTimes() nothrow @nogc {
    SteadyGcTimes t;
    () @trusted {
        __sd_gc_time_total(&t.pauseNs, &t.workNs, &t.pauseCount, &t.cycleCount, &t.maxPauseNs, &t.slowAllocWaitNs);
    }();
    return t;
}

/**
 * Query GC telemetry for the calling thread.
 */
SteadyGcTimes gcThreadTimes() nothrow @nogc {
    SteadyGcTimes t;
    () @trusted {
        __sd_gc_time_thread(&t.pauseNs, &t.workNs, &t.pauseCount, &t.cycleCount, &t.maxPauseNs, &t.slowAllocWaitNs);
    }();
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
 * Query the reserved card window size in bytes (256 GiB on desktop, 16 GiB on mobile).
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
