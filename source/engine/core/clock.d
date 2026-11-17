/// Fixed-timestep accumulator clock with delta clamping, spiral-of-death cap, and time scaling.
module engine.core.clock;

import engine.core.pod : isPod;

@safe:

/// Result returned by `GameClock.advance(realDt)`.
struct StepResult {
    uint  steps = 0;       /// Number of fixed simulation steps to execute this frame.
    float alpha = 0.0f;    /// Normalized remainder in `[0, 1)` for render interpolation.
    float fixedDt = 0.0f;  /// Fixed simulation step duration in seconds.
    float scaledDt = 0.0f; /// Effective scaled frame delta (`clampedRealDt * timeScale`).
}

static assert(isPod!StepResult);

/// Deterministic fixed-timestep accumulator (`60 Hz` default).
struct GameClock {
    float fixedDt = 1.0f / 60.0f;
    float timeScale = 1.0f;
    uint  maxSteps = 8;
    float maxFrameDt = 0.25f;

    private float accumulator = 0.0f;
    private double elapsedScaled = 0.0;
    private double elapsedReal = 0.0;
    private ulong totalSteps = 0;

    /// Construct a `GameClock` for a fixed step frequency (e.g. `60.0f` Hz).
    static GameClock create(float hz = 60.0f, uint maxStepsPerFrame = 8) nothrow @nogc pure {
        GameClock c;
        c.fixedDt = hz > 0.0f ? (1.0f / hz) : (1.0f / 60.0f);
        c.maxSteps = maxStepsPerFrame > 0 ? maxStepsPerFrame : 8;
        return c;
    }

    /// Advance the clock by `realDt` seconds and compute how many fixed steps to run.
    StepResult advance(float realDt) nothrow @nogc {
        float clamped = realDt;
        if (clamped < 0.0f) clamped = 0.0f;
        else if (clamped > maxFrameDt) clamped = maxFrameDt;

        elapsedReal += clamped;
        immutable float ts = timeScale < 0.0f ? 0.0f : timeScale;
        immutable float sdt = clamped * ts;
        elapsedScaled += sdt;

        StepResult res;
        res.fixedDt = fixedDt;
        res.scaledDt = sdt;
        if (fixedDt <= 0.0f) return res;

        accumulator += sdt;
        uint s = 0;
        while (accumulator >= fixedDt && s < maxSteps) {
            accumulator -= fixedDt;
            s++;
            totalSteps++;
        }
        if (s == maxSteps && accumulator >= fixedDt) {
            // Drop excess accumulated lag to avoid spiral-of-death stalls
            accumulator %= fixedDt;
        }

        res.steps = s;
        res.alpha = accumulator / fixedDt;
        return res;
    }

    /// Reset accumulator and elapsed totals while keeping configured step/scale rates.
    void reset() nothrow @nogc {
        accumulator = 0.0f;
        elapsedScaled = 0.0;
        elapsedReal = 0.0;
        totalSteps = 0;
    }

    double totalScaledTime() const nothrow @nogc pure { return elapsedScaled; }
    double totalRealTime() const nothrow @nogc pure { return elapsedReal; }
    ulong fixedStepCount() const nothrow @nogc pure { return totalSteps; }
    float remainder() const nothrow @nogc pure { return accumulator; }
}

static assert(isPod!GameClock);

unittest {
    // Same simulated duration (1 second) at 30 Hz and 144 Hz yields identical 60 fixed steps
    auto c30 = GameClock.create(60.0f);
    foreach (_; 0 .. 30) {
        c30.advance(1.0f / 30.0f);
    }

    auto c144 = GameClock.create(60.0f);
    foreach (_; 0 .. 144) {
        c144.advance(1.0f / 144.0f);
    }

    assert(c30.fixedStepCount() == 60);
    // Allow 1-step floating-point boundary epsilon for 144*(1/144)
    assert(c144.fixedStepCount() >= 59 && c144.fixedStepCount() <= 60);

    // Pause / slow-mo timeScale
    auto cSlow = GameClock.create(60.0f);
    cSlow.timeScale = 0.0f;
    immutable auto rPaused = cSlow.advance(0.1f);
    assert(rPaused.steps == 0);
    assert(rPaused.scaledDt == 0.0f);

    // Spiral-of-death cap
    auto cCap = GameClock.create(60.0f, 4);
    immutable auto rHuge = cCap.advance(5.0f);
    assert(rHuge.steps == 4);
    assert(rHuge.alpha >= 0.0f && rHuge.alpha < 1.0f);
}
