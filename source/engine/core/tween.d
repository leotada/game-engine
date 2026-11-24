/// Lightweight POD easing tweens and countdown/interval timers.
/// Zero heap allocation per tween or timer; designed for `@nogc` frame loops.
module engine.core.tween;

import core.stdc.math : cosf, sinf, powf;
import engine.core.pod : isPod;

@safe:

/// Standard easing curves.
enum Ease : ubyte {
    linear = 0,
    inQuad,
    outQuad,
    inOutQuad,
    inCubic,
    outCubic,
    inOutCubic,
    outBack,
    outBounce,
}

/// Evaluate easing curve `e` at normalized time `t` in `[0, 1]`.
float evalEase(Ease e, float t) nothrow @nogc pure {
    if (t <= 0.0f) return 0.0f;
    if (t >= 1.0f) return 1.0f;
    final switch (e) {
        case Ease.linear:
            return t;
        case Ease.inQuad:
            return t * t;
        case Ease.outQuad: {
            immutable float u = 1.0f - t;
            return 1.0f - u * u;
        }
        case Ease.inOutQuad:
            if (t < 0.5f) return 2.0f * t * t;
            return 1.0f - ((-2.0f * t + 2.0f) * (-2.0f * t + 2.0f)) * 0.5f;
        case Ease.inCubic:
            return t * t * t;
        case Ease.outCubic: {
            immutable float u = 1.0f - t;
            return 1.0f - u * u * u;
        }
        case Ease.inOutCubic:
            if (t < 0.5f) return 4.0f * t * t * t;
            immutable float u = -2.0f * t + 2.0f;
            return 1.0f - (u * u * u) * 0.5f;
        case Ease.outBack: {
            enum float c1 = 1.70158f;
            enum float c3 = c1 + 1.0f;
            immutable float u = t - 1.0f;
            return 1.0f + c3 * u * u * u + c1 * u * u;
        }
        case Ease.outBounce: {
            enum float n1 = 7.5625f;
            enum float d1 = 2.75f;
            if (t < 1.0f / d1) {
                return n1 * t * t;
            } else if (t < 2.0f / d1) {
                immutable float u = t - 1.5f / d1;
                return n1 * u * u + 0.75f;
            } else if (t < 2.5f / d1) {
                immutable float u = t - 2.25f / d1;
                return n1 * u * u + 0.9375f;
            } else {
                immutable float u = t - 2.625f / d1;
                return n1 * u * u + 0.984375f;
            }
        }
    }
}

/// Generational handle identifying a running tween (`0` = invalid).
alias TweenId = ulong;

private struct TweenSlot {
    float from = 0.0f;
    float to = 0.0f;
    float duration = 0.0f;
    float elapsed = 0.0f;
    float delay = 0.0f;
    Ease  ease = Ease.linear;
    bool  active = false;
    bool  justCompleted = false;
    uint  generation = 1;
}

static assert(isPod!TweenSlot);

/// Pre-allocated pool of value tweens (`MAX_TWEENS = 256`).
struct Tweens {
    enum uint MAX_TWEENS = 256;

    private TweenSlot[MAX_TWEENS] slots;

    private static bool decodeId(TweenId id, out uint idx, out uint gen) nothrow @nogc pure {
        if (id == 0) return false;
        idx = cast(uint)(id & 0xFFFF_FFFFu) - 1u;
        gen = cast(uint)(id >> 32);
        return idx < MAX_TWEENS;
    }

    /// Start interpolating from `from` to `to` over `duration` seconds. Returns a `TweenId`.
    TweenId start(
        float from, float to, float duration,
        Ease ease = Ease.outCubic,
        float delay = 0.0f
    ) nothrow @nogc {
        foreach (uint i; 0 .. MAX_TWEENS) {
            auto s = &slots[i];
            if (!s.active && !s.justCompleted) {
                if (s.generation == 0) s.generation = 1;
                s.from = from;
                s.to = to;
                s.duration = duration > 0.0f ? duration : 0.0f;
                s.elapsed = 0.0f;
                s.delay = delay > 0.0f ? delay : 0.0f;
                s.ease = ease;
                s.active = true;
                s.justCompleted = false;
                return (cast(TweenId) s.generation << 32) | cast(TweenId)(i + 1);
            }
        }
        return 0;
    }

    /// Advance all active tweens by `dt` seconds.
    void update(float dt) nothrow @nogc {
        if (dt < 0.0f) return;
        foreach (ref s; slots) {
            if (s.justCompleted) {
                s.justCompleted = false;
                s.generation++;
            }
            if (!s.active) continue;

            float remDt = dt;
            if (s.delay > 0.0f) {
                if (remDt <= s.delay) {
                    s.delay -= remDt;
                    continue;
                }
                remDt -= s.delay;
                s.delay = 0.0f;
            }

            s.elapsed += remDt;
            if (s.elapsed >= s.duration) {
                s.elapsed = s.duration;
                s.active = false;
                s.justCompleted = true;
            }
        }
    }

    /// Query the current interpolated value into `outValue`.
    /// Returns true while running AND on the completion frame (delivering exact `to`),
    /// then returns false on subsequent frames once retired.
    bool tryGet(TweenId id, out float outValue) const nothrow @nogc pure {
        uint idx, gen;
        if (!decodeId(id, idx, gen)) {
            outValue = 0.0f;
            return false;
        }
        const s = &slots[idx];
        if (s.generation != gen || (!s.active && !s.justCompleted)) {
            outValue = 0.0f;
            return false;
        }
        if (s.delay > 0.0f) {
            outValue = s.from;
            return true;
        }
        if (s.duration <= 0.0f || s.elapsed >= s.duration) {
            outValue = s.to;
            return true;
        }
        immutable float t = s.elapsed / s.duration;
        immutable float k = evalEase(s.ease, t);
        outValue = s.from + (s.to - s.from) * k;
        return true;
    }

    /// Returns true on the single frame the tween finished during the latest `update()`.
    bool justFinished(TweenId id) const nothrow @nogc pure {
        uint idx, gen;
        if (!decodeId(id, idx, gen)) return false;
        const s = &slots[idx];
        return s.generation == gen && s.justCompleted;
    }

    /// True while the tween is still running (or delaying).
    bool isActive(TweenId id) const nothrow @nogc pure {
        uint idx, gen;
        if (!decodeId(id, idx, gen)) return false;
        const s = &slots[idx];
        return s.generation == gen && s.active;
    }

    void cancel(TweenId id) nothrow @nogc {
        uint idx, gen;
        if (!decodeId(id, idx, gen)) return;
        auto s = &slots[idx];
        if (s.generation == gen && (s.active || s.justCompleted)) {
            s.active = false;
            s.justCompleted = false;
            s.generation++;
        }
    }

    void clear() nothrow @nogc {
        foreach (ref s; slots) {
            if (s.active || s.justCompleted) {
                s.active = false;
                s.justCompleted = false;
                s.generation++;
            }
        }
    }
}

static assert(isPod!Tweens);

/// Generational handle identifying a countdown or repeating timer (`0` = invalid).
alias TimerId = ulong;

/// Optional `@nogc` callback signature invoked when a timer fires.
alias TimerCallback = void function(void* userData) nothrow @nogc;

private struct TimerSlot {
    float interval = 0.0f;
    float remaining = 0.0f;
    TimerCallback callback = null;
    void* userData = null;
    bool repeat = false;
    bool active = false;
    bool firedThisFrame = false;
    uint generation = 1;
}

/// Pre-allocated pool of one-shot and repeating timers (`MAX_TIMERS = 128`).
struct Timers {
    enum uint MAX_TIMERS = 128;

    private TimerSlot[MAX_TIMERS] slots;

    private static bool decodeId(TimerId id, out uint idx, out uint gen) nothrow @nogc pure {
        if (id == 0) return false;
        idx = cast(uint)(id & 0xFFFF_FFFFu) - 1u;
        gen = cast(uint)(id >> 32);
        return idx < MAX_TIMERS;
    }

    /// Schedule a one-shot timer that fires after `seconds`.
    TimerId after(float seconds, TimerCallback cb = null, void* userData = null) nothrow @nogc {
        return createSlot(seconds, false, cb, userData);
    }

    /// Schedule a repeating timer that fires every `interval` seconds.
    TimerId every(float interval, TimerCallback cb = null, void* userData = null) nothrow @nogc {
        return createSlot(interval, true, cb, userData);
    }

    private TimerId createSlot(float secs, bool repeat, TimerCallback cb, void* userData) nothrow @nogc {
        foreach (uint i; 0 .. MAX_TIMERS) {
            auto s = &slots[i];
            if (!s.active && !s.firedThisFrame) {
                if (s.generation == 0) s.generation = 1;
                s.interval = secs > 0.0f ? secs : 0.0f;
                s.remaining = s.interval;
                s.callback = cb;
                s.userData = userData;
                s.repeat = repeat;
                s.active = true;
                s.firedThisFrame = false;
                return (cast(TimerId) s.generation << 32) | cast(TimerId)(i + 1);
            }
        }
        return 0;
    }

    /// Advance all active timers by `dt` seconds and invoke any registered callbacks.
    void update(float dt) nothrow @nogc {
        if (dt < 0.0f) return;
        foreach (ref s; slots) {
            if (s.firedThisFrame && !s.active) {
                s.firedThisFrame = false;
                s.generation++;
                continue;
            }
            s.firedThisFrame = false;
            if (!s.active) continue;

            s.remaining -= dt;
            if (s.remaining <= 0.0f) {
                s.firedThisFrame = true;
                if (s.callback !is null) {
                    immutable gen = s.generation;
                    () @trusted { s.callback(s.userData); }();
                    // The callback canceled this timer; the slot may already hold a new one.
                    if (s.generation != gen) continue;
                }
                if (s.repeat) {
                    if (s.interval > 0.0f) {
                        import core.stdc.math : fmodf;
                        // Skip missed periods in O(1): a loop would stall when dt is much larger than interval.
                        s.remaining = s.interval - fmodf(-s.remaining, s.interval);
                    } else {
                        s.remaining = 0.0f;
                    }
                } else {
                    s.active = false;
                }
            }
        }
    }

    /// Returns true if `id` fired during the most recent `update()`.
    bool fired(TimerId id) const nothrow @nogc pure {
        uint idx, gen;
        if (!decodeId(id, idx, gen)) return false;
        const s = &slots[idx];
        return s.generation == gen && s.firedThisFrame;
    }

    bool isActive(TimerId id) const nothrow @nogc pure {
        uint idx, gen;
        if (!decodeId(id, idx, gen)) return false;
        const s = &slots[idx];
        return s.generation == gen && s.active;
    }

    void cancel(TimerId id) nothrow @nogc {
        uint idx, gen;
        if (!decodeId(id, idx, gen)) return;
        auto s = &slots[idx];
        if (s.generation == gen && (s.active || s.firedThisFrame)) {
            s.active = false;
            s.firedThisFrame = false;
            s.generation++;
        }
    }

    void clear() nothrow @nogc {
        foreach (ref s; slots) {
            if (s.active || s.firedThisFrame) {
                s.active = false;
                s.firedThisFrame = false;
                s.generation++;
            }
        }
    }
}

unittest {
    Tweens tw;
    TweenId id = tw.start(10.0f, 50.0f, 1.0f, Ease.linear, 0.5f);
    assert(tw.isActive(id));

    float v;
    tw.update(0.25f);
    assert(tw.tryGet(id, v) && v == 10.0f); // still in delay
    assert(!tw.justFinished(id));

    tw.update(0.75f); // 0.25s delay left consumed + 0.5s active elapsed -> halfway (30)
    assert(tw.tryGet(id, v) && v > 29.9f && v < 30.1f);

    tw.update(0.5f); // finished -> delivers exact 50 and marks justFinished
    assert(tw.justFinished(id));
    assert(tw.tryGet(id, v) && v == 50.0f);

    tw.update(0.1f); // retired on following frame
    assert(!tw.tryGet(id, v));

    // Timers: one-shot + repeating
    Timers tm;
    TimerId tOnce = tm.after(0.5f);
    TimerId tRep  = tm.every(0.4f);

    tm.update(0.3f);
    assert(!tm.fired(tOnce) && !tm.fired(tRep));

    tm.update(0.25f); // elapsed 0.55 -> both fire
    assert(tm.fired(tOnce));
    assert(tm.fired(tRep));

    tm.update(0.1f); // tOnce retired, tRep still active
    assert(!tm.isActive(tOnce));
    assert(tm.isActive(tRep));
    assert(!tm.fired(tRep));
}

@("timers: a timer created by the callback that cleared its own slot survives")
unittest {
    static Timers tm;
    static TimerId created;
    tm.after(0.1f, (void*) nothrow @nogc {
        tm.clear();
        created = tm.after(1.0f);
    });
    tm.update(0.2f);
    assert(tm.isActive(created));
    assert(!tm.fired(created));
    tm.update(1.1f);
    assert(tm.fired(created));
}

@("timers: tiny repeat interval does not stall on a large dt")
unittest {
    Timers tm;
    immutable id = tm.every(1e-7f);
    tm.update(10.0f);
    assert(tm.fired(id) && tm.isActive(id));

    immutable rep = tm.every(0.4f);
    tm.update(1.0f); // two periods and a half
    assert(tm.fired(rep));
    tm.update(0.19f);
    assert(!tm.fired(rep));
    tm.update(0.02f);
    assert(tm.fired(rep));
}
