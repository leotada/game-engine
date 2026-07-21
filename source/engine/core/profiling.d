// 
module engine.core.profiling;

import bindings.sdl3 : SDL_GetPerformanceCounter, SDL_GetPerformanceFrequency;
import std.math : sqrt;

@safe:

// 
enum FRAMETIMER_CAPACITY = 1000;

// 
struct FrameTimer {
    @disable this(this);

    private ulong[FRAMETIMER_CAPACITY] samples; // ticks per frame
    private size_t head;                        // next write slot
    private size_t count;                       // saturates at capacity
    private ulong freq;                         // ticks per second
    private ulong lastCounter;                  // previous SDL counter
    private ulong lastDelta;                    // most-recent delta in ticks
    private bool started;

    /// Construct a timer and prime the reference counter.
    static FrameTimer create() @trusted @nogc nothrow {
        FrameTimer t;
        t.freq = SDL_GetPerformanceFrequency();
        t.lastCounter = SDL_GetPerformanceCounter();
        t.started = true;
        return t;
    }

    /// Record one frame delta. Call exactly once per frame, before or after
    /// rendering — position is up to the caller but must be consistent.
    void tick() @trusted @nogc nothrow {
        immutable now = SDL_GetPerformanceCounter();
        immutable delta = now - lastCounter;
        lastCounter = now;
        lastDelta = delta;

        samples[head] = delta;
        head = (head + 1) % FRAMETIMER_CAPACITY;
        if (count < FRAMETIMER_CAPACITY) ++count;
    }

    /// Last frame's delta in seconds (useful for integration).
    double dtSeconds() const @nogc nothrow {
        if (freq == 0) return 0.0;
        return cast(double) lastDelta / cast(double) freq;
    }

    /// Number of samples currently buffered.
    size_t sampleCount() const @nogc nothrow { return count; }

    /// Mean frame time in milliseconds.
    double avgMs() const @nogc nothrow {
        if (count == 0 || freq == 0) return 0.0;
        ulong sum = 0;
        foreach (i; 0 .. count) sum += samples[i];
        immutable meanTicks = cast(double) sum / cast(double) count;
        return ticksToMs(meanTicks);
    }

    /// Population standard deviation of frame times in milliseconds.
    double stdDevMs() const @nogc nothrow {
        if (count == 0 || freq == 0) return 0.0;
        ulong sum = 0;
        foreach (i; 0 .. count) sum += samples[i];
        immutable mean = cast(double) sum / cast(double) count;
        double acc = 0.0;
        foreach (i; 0 .. count) {
            immutable d = cast(double) samples[i] - mean;
            acc += d * d;
        }
        immutable varTicks2 = acc / cast(double) count;
        immutable stdTicks = sqrt(varTicks2);
        return ticksToMs(stdTicks);
    }

    /// 1% Low frame time — average of the slowest 1% of frames, in ms.
    /// With a full 1000-frame window this averages the worst 10 frames.
    double onePercentLowMs() const @nogc nothrow {
        if (count == 0 || freq == 0) return 0.0;

        // Copy samples to a stack-allocated scratch buffer and sort descending.
        double[FRAMETIMER_CAPACITY] scratch = void;
        foreach (i; 0 .. count) scratch[i] = cast(double) samples[i];

        // Partial selection sort of the top-K largest values is enough and
        // avoids pulling in std.algorithm.sort which is not @nogc here.
        immutable size_t k = count / 100 == 0 ? 1 : count / 100;
        foreach (i; 0 .. k) {
            size_t maxIdx = i;
            foreach (j; i + 1 .. count) {
                if (scratch[j] > scratch[maxIdx]) maxIdx = j;
            }
            if (maxIdx != i) {
                immutable tmp = scratch[i];
                scratch[i] = scratch[maxIdx];
                scratch[maxIdx] = tmp;
            }
        }

        double sum = 0.0;
        foreach (i; 0 .. k) sum += scratch[i];
        immutable meanTicks = sum / cast(double) k;
        return ticksToMs(meanTicks);
    }

    /// Derived FPS from average frame time.
    double avgFps() const @nogc nothrow {
        immutable ms = avgMs();
        return ms > 0.0 ? 1000.0 / ms : 0.0;
    }

    /// Clear all samples but preserve the SDL reference counter.
    void reset() @nogc nothrow {
        head = 0;
        count = 0;
        lastDelta = 0;
    }

    private double ticksToMs(double ticks) const @nogc nothrow {
        return ticks * 1000.0 / cast(double) freq;
    }
}

// -----------------------------------------------------------------------------
// Unit tests — use a crafted freq so we don't depend on SDL initialization.
// -----------------------------------------------------------------------------

unittest {
    // Build a timer with synthetic samples. freq = 1_000_000 → 1 tick = 1 µs.
    FrameTimer t;
    t.freq = 1_000_000;
    t.started = true;

    // 999 frames of 16ms (16_000 ticks) + 1 frame of 100ms (100_000 ticks).
    foreach (_; 0 .. 999) {
        t.samples[t.head] = 16_000;
        t.head = (t.head + 1) % FRAMETIMER_CAPACITY;
        if (t.count < FRAMETIMER_CAPACITY) ++t.count;
    }
    t.samples[t.head] = 100_000;
    t.head = (t.head + 1) % FRAMETIMER_CAPACITY;
    if (t.count < FRAMETIMER_CAPACITY) ++t.count;

    assert(t.sampleCount == 1000);

    immutable avg = t.avgMs();
    // Expected: (999*16 + 100) / 1000 = 16.084 ms
    assert(avg > 16.07 && avg < 16.10);

    // 1% Low averages worst 10 frames: one 100ms and nine 16ms → 24.4 ms
    immutable low = t.onePercentLowMs();
    assert(low > 24.0 && low < 25.0);

    // stdDev is positive and finite.
    immutable sd = t.stdDevMs();
    assert(sd > 0.0 && sd < 10.0);
}

unittest {
    // All identical samples → stdDev = 0, 1% low = avg.
    FrameTimer t;
    t.freq = 1_000_000;
    t.started = true;
    foreach (_; 0 .. 500) {
        t.samples[t.head] = 16_666;
        t.head = (t.head + 1) % FRAMETIMER_CAPACITY;
        if (t.count < FRAMETIMER_CAPACITY) ++t.count;
    }
    assert(t.stdDevMs() < 1e-6);
    immutable d = t.avgMs() - t.onePercentLowMs();
    assert(d > -1e-6 && d < 1e-6);
}
