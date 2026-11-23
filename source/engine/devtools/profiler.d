/// Native frame profiler: hierarchical CPU zones, GPU pass timings and external samples.
///
/// One profiler per thread (module state, thread-local). Off by default: a disabled zone costs
/// one branch. Enable it once, outside the frame loop:
///
/// ---
/// enableProfiler(true);
/// // in engine or game code:
/// {
///     auto z = profileZone!"scene.end"();     // closes at scope exit
///     ...
/// }
/// profileSample!"physics.solve"(ms);        // external measurement, child of the open zone
/// // App.endFrame calls profilerEndFrame(); GpuProfiler feeds the "gpu.*" zones.
/// auto rows = profilerReport();             // tree-ordered stats (allocates; not per frame)
/// ---
///
/// Zone names are compile-time strings, so a call site resolves its id once (a TLS static per
/// template instance) and never allocates. A zone's parent is the zone open when it is first
/// seen. Statistics: mean per frame (frames where it did not run count as 0), p50/p95/p99 over
/// the last `PROFILE_HISTORY` frames, max, and calls per frame. `startProfilerTrace` records
/// individual events for a Chrome Trace Event JSON (open in https://ui.perfetto.dev).
module engine.devtools.profiler;

import core.time : MonoTime;

@safe:

enum ZoneKind : ubyte {
    cpu,    /// wall-clock CPU scope (`profileZone`)
    gpu,    /// GPU timestamps (`engine.gpu.gpu_profiler`), reported a few frames late
    sample, /// value pushed by code (`profileSample`), e.g. Box3D's own step profile
}

enum uint MAX_PROFILE_ZONES = 512;   /// distinct zones
enum uint PROFILE_HISTORY = 600;     /// frames kept per zone for percentiles
enum uint MAX_ZONE_DEPTH = 64;
enum ushort NO_ZONE = ushort.max;
enum size_t MAX_ZONE_NAME = 62;     /// longer names are truncated

/// One row of `profilerReport()`.
struct ZoneReport {
    char[MAX_ZONE_NAME] nameBuf;
    ubyte nameLen;
    ZoneKind kind;
    ushort id, parent;  /// parent is NO_ZONE for roots
    ubyte depth;
    double meanMs = 0;  /// per frame
    float p50 = 0, p95 = 0, p99 = 0, maxMs = 0;
    double callsPerFrame = 0;
    ulong frames;       /// frames measured since registration (or the last reset)

    const(char)[] name() const return nothrow @nogc { return nameBuf[0 .. nameLen]; }
}

/// One recorded event of the trace (`startProfilerTrace`).
struct ProfileEvent {
    ushort zone;
    ubyte depth;
    ZoneKind kind;
    long startNs, endNs; /// since the profiler epoch (GPU events are aligned to their frame's submit)
}

private struct ZoneInfo {
    char[MAX_ZONE_NAME] nameBuf;
    ubyte nameLen;
    ZoneKind kind;
    ushort parent;
    ubyte depth;

    const(char)[] name() const return nothrow @nogc { return nameBuf[0 .. nameLen]; }
}

private struct ZoneAccum {
    double frameMs = 0;
    uint frameCalls;
    double totalMs = 0;
    ulong totalCalls;
    ulong frames;
    float maxMs = 0;
    uint histCursor, histFilled;
}

private struct ProfilerState {
    bool enabled;
    ulong frameIndex;
    MonoTime epoch;
    long lastFrameNs = -1;
    ushort frameZone = NO_ZONE;
    ZoneInfo[MAX_PROFILE_ZONES] zones;
    ZoneAccum[MAX_PROFILE_ZONES] acc;
    uint zoneCount;
    float[] history;                  /// MAX_PROFILE_ZONES * PROFILE_HISTORY, allocated on enable
    ushort[MAX_ZONE_DEPTH] stackZone;
    long[MAX_ZONE_DEPTH] stackStart;
    uint stackDepth;
    uint overflow;                    /// zones dropped (table full or nesting too deep)
    ProfileEvent[] trace;
    size_t traceLen;
    bool tracing;
}

private ProfilerState prof; // thread-local

// ----------------------------------------------------------------------------- control

/// Turn the profiler on/off. The first enable allocates the history table (~1.2 MB).
void enableProfiler(bool on) {
    if (on && prof.history.length == 0) {
        prof.history = new float[MAX_PROFILE_ZONES * PROFILE_HISTORY];
        prof.epoch = MonoTime.currTime;
    }
    prof.enabled = on;
}

bool profilerEnabled() nothrow @nogc { return prof.enabled; }

/// Frames closed by `profilerEndFrame` so far.
ulong profilerFrameIndex() nothrow @nogc { return prof.frameIndex; }

/// Nanoseconds since the profiler epoch (the clock used by zones and the trace).
long profilerNowNs() nothrow @nogc {
    return (MonoTime.currTime - prof.epoch).total!"nsecs";
}

/// Clear the statistics (zone table and ids stay valid), e.g. after a warm-up.
void resetProfilerStats() nothrow @nogc {
    foreach (ref a; prof.acc[0 .. prof.zoneCount])
        a = ZoneAccum.init;
    prof.overflow = 0;
}

/// Zones dropped because the table was full or nesting was too deep.
uint profilerOverflow() nothrow @nogc { return prof.overflow; }

// ----------------------------------------------------------------------------- zones

/// Scoped CPU zone returned by `profileZone`; closes on destruction.
struct ProfileZone {
    private bool active;
    @disable this(this);
    ~this() nothrow @nogc {
        if (active)
            endZone();
    }
}

/// Open a CPU zone named `name` until the end of the enclosing scope.
ProfileZone profileZone(string name)() nothrow @nogc {
    static ushort id = NO_ZONE;
    if (!prof.enabled)
        return ProfileZone.init;
    if (id == NO_ZONE)
        id = registerZone(name, ZoneKind.cpu, currentZone(), cast(ubyte) prof.stackDepth);
    if (id == NO_ZONE || !beginZone(id))
        return ProfileZone.init;
    return ProfileZone(true);
}

/// Report an externally measured duration as a child of the currently open zone.
void profileSample(string name)(double ms) nothrow @nogc {
    static ushort id = NO_ZONE;
    if (!prof.enabled)
        return;
    if (id == NO_ZONE)
        id = registerZone(name, ZoneKind.sample, currentZone(), cast(ubyte) prof.stackDepth);
    if (id != NO_ZONE)
        addZoneTime(id, ms);
}

/// Register (or find) a zone. `parent`/`depth` only apply the first time a name is seen.
ushort registerZone(scope const(char)[] name, ZoneKind kind, ushort parent, ubyte depth) nothrow @nogc {
    if (name.length > MAX_ZONE_NAME)
        name = name[0 .. MAX_ZONE_NAME];
    foreach (i; 0 .. prof.zoneCount)
        if (prof.zones[i].kind == kind && prof.zones[i].name == name)
            return cast(ushort) i;
    if (prof.zoneCount >= MAX_PROFILE_ZONES) {
        ++prof.overflow;
        return NO_ZONE;
    }
    immutable id = cast(ushort) prof.zoneCount++;
    ZoneInfo z;
    z.nameBuf[0 .. name.length] = name[];
    z.nameLen = cast(ubyte) name.length;
    z.kind = kind;
    z.parent = parent;
    z.depth = depth;
    prof.zones[id] = z;
    prof.acc[id] = ZoneAccum.init;
    return id;
}

/// The innermost open CPU zone, or NO_ZONE.
ushort currentZone() nothrow @nogc {
    return prof.stackDepth ? prof.stackZone[prof.stackDepth - 1] : NO_ZONE;
}

/// Add `ms` to zone `id` for the current frame (GPU timings and samples use this).
void addZoneTime(ushort id, double ms) nothrow @nogc {
    if (id >= prof.zoneCount)
        return;
    prof.acc[id].frameMs += ms;
    ++prof.acc[id].frameCalls;
}

/// Record a finished event for the trace (no-op unless tracing).
void traceEvent(ushort id, ubyte depth, ZoneKind kind, long startNs, long endNs) nothrow @nogc {
    if (!prof.tracing || prof.traceLen >= prof.trace.length)
        return;
    prof.trace[prof.traceLen++] = ProfileEvent(id, depth, kind, startNs, endNs);
}

private bool beginZone(ushort id) nothrow @nogc {
    if (prof.stackDepth >= MAX_ZONE_DEPTH) {
        ++prof.overflow;
        return false;
    }
    prof.stackZone[prof.stackDepth] = id;
    prof.stackStart[prof.stackDepth] = profilerNowNs();
    ++prof.stackDepth;
    return true;
}

private void endZone() nothrow @nogc {
    if (prof.stackDepth == 0)
        return;
    --prof.stackDepth;
    immutable id = prof.stackZone[prof.stackDepth];
    immutable start = prof.stackStart[prof.stackDepth];
    immutable end = profilerNowNs();
    addZoneTime(id, (end - start) / 1e6);
    traceEvent(id, cast(ubyte) prof.stackDepth, ZoneKind.cpu, start, end);
}

// ----------------------------------------------------------------------------- frames

/// Close the CPU frame: commits every CPU and sample zone (App.endFrame calls it). The root
/// zone "frame" holds the time between consecutive calls.
void profilerEndFrame() nothrow @nogc {
    if (!prof.enabled)
        return;
    immutable now = profilerNowNs();
    if (prof.frameZone == NO_ZONE)
        prof.frameZone = registerZone("frame", ZoneKind.cpu, NO_ZONE, 0);
    if (prof.lastFrameNs >= 0 && prof.frameZone != NO_ZONE) {
        addZoneTime(prof.frameZone, (now - prof.lastFrameNs) / 1e6);
        traceEvent(prof.frameZone, 0, ZoneKind.cpu, prof.lastFrameNs, now);
    }
    prof.lastFrameNs = now;
    foreach (i; 0 .. prof.zoneCount)
        if (prof.zones[i].kind != ZoneKind.gpu)
            commit(cast(ushort) i);
    ++prof.frameIndex;
}

/// Close a GPU frame (GpuProfiler calls it after reading one frame of timestamps).
void profilerEndGpuFrame() nothrow @nogc {
    if (!prof.enabled)
        return;
    foreach (i; 0 .. prof.zoneCount)
        if (prof.zones[i].kind == ZoneKind.gpu)
            commit(cast(ushort) i);
}

private void commit(ushort id) nothrow @nogc {
    auto a = &prof.acc[id];
    immutable ms = cast(float) a.frameMs;
    a.totalMs += a.frameMs;
    a.totalCalls += a.frameCalls;
    ++a.frames;
    if (ms > a.maxMs)
        a.maxMs = ms;
    if (prof.history.length) {
        prof.history[id * PROFILE_HISTORY + a.histCursor] = ms;
        a.histCursor = (a.histCursor + 1) % PROFILE_HISTORY;
        if (a.histFilled < PROFILE_HISTORY)
            ++a.histFilled;
    }
    a.frameMs = 0;
    a.frameCalls = 0;
}

// ----------------------------------------------------------------------------- reports

/// Statistics of every zone, depth-first (children after their parent, in registration order).
/// Allocates: call it outside the frame loop.
ZoneReport[] profilerReport() {
    import std.algorithm : sort;
    ZoneReport[] rows;
    void visit(ushort parent) {
        foreach (i; 0 .. prof.zoneCount) {
            if (prof.zones[i].parent != parent || i == parent)
                continue;
            const z = &prof.zones[i];
            const a = &prof.acc[i];
            ZoneReport r;
            r.nameBuf = z.nameBuf;
            r.nameLen = z.nameLen;
            r.kind = z.kind;
            r.id = cast(ushort) i;
            r.parent = z.parent;
            r.depth = z.depth;
            r.frames = a.frames;
            if (a.frames) {
                r.meanMs = a.totalMs / a.frames;
                r.callsPerFrame = cast(double) a.totalCalls / a.frames;
            }
            r.maxMs = a.maxMs;
            if (a.histFilled && prof.history.length) {
                float[] h = prof.history[i * PROFILE_HISTORY .. i * PROFILE_HISTORY + a.histFilled].dup;
                sort(h);
                float at(float p) { return h[cast(size_t)((h.length - 1) * p / 100.0f)]; }
                r.p50 = at(50);
                r.p95 = at(95);
                r.p99 = at(99);
            }
            rows ~= r;
            visit(cast(ushort) i);
        }
    }
    visit(NO_ZONE);
    return rows;
}

/// Start recording individual events (up to `maxEvents`, then recording stops by itself).
void startProfilerTrace(size_t maxEvents = 1 << 18) {
    if (prof.trace.length < maxEvents)
        prof.trace = new ProfileEvent[maxEvents];
    prof.traceLen = 0;
    prof.tracing = true;
}

void stopProfilerTrace() nothrow @nogc { prof.tracing = false; }

/// Recorded events so far.
const(ProfileEvent)[] profilerTraceEvents() nothrow @nogc { return prof.trace[0 .. prof.traceLen]; }

/// The recorded events as Chrome Trace Event JSON ("X" events; CPU on tid 1, GPU on tid 2).
string profilerTraceJson() {
    import std.array : appender;
    import std.format : formattedWrite;
    auto o = appender!string();
    o.put(`{"displayTimeUnit":"ms","traceEvents":[`);
    o.put(`{"name":"thread_name","ph":"M","pid":1,"tid":1,"args":{"name":"CPU"}},`);
    o.put(`{"name":"thread_name","ph":"M","pid":1,"tid":2,"args":{"name":"GPU"}}`);
    foreach (ref e; prof.trace[0 .. prof.traceLen]) {
        const z = &prof.zones[e.zone];
        o.formattedWrite(`,{"name":"%s","cat":"%s","ph":"X","pid":1,"tid":%d,"ts":%.3f,"dur":%.3f}`, z.name(),
            e.kind == ZoneKind.gpu ? "gpu" : "cpu", e.kind == ZoneKind.gpu ? 2 : 1, e.startNs / 1000.0,
            (e.endNs - e.startNs) / 1000.0);
    }
    o.put("]}");
    return o[];
}

/// Forget every zone and statistic (tests; ids held by call sites become stale).
void resetProfilerForTests() {
    immutable on = prof.enabled;
    prof = ProfilerState.init;
    enableProfiler(on);
}

unittest {
    resetProfilerForTests();
    enableProfiler(true);
    scope (exit) enableProfiler(false);
    static void work() nothrow @nogc {
        auto outer = profileZone!"test.outer"();
        {
            auto inner = profileZone!"test.inner"();
            profileSample!"test.inner.sample"(1.5);
        }
        auto inner2 = profileZone!"test.inner"(); // second call in the same frame
    }
    foreach (_; 0 .. 10) {
        work();
        profilerEndFrame();
    }
    auto rows = profilerReport();
    size_t outer = size_t.max, inner = size_t.max, sample = size_t.max;
    foreach (i, ref r; rows) {
        if (r.name == "test.outer") outer = i;
        if (r.name == "test.inner") inner = i;
        if (r.name == "test.inner.sample") sample = i;
    }
    assert(outer != size_t.max && inner == outer + 1 && sample == inner + 1);
    assert(rows[inner].parent == rows[outer].id && rows[inner].depth == 1);
    assert(rows[sample].parent == rows[inner].id && rows[sample].kind == ZoneKind.sample);
    assert(rows[inner].callsPerFrame == 2.0);
    assert(rows[sample].meanMs == 1.5 && rows[sample].p50 == 1.5f && rows[sample].maxMs == 1.5f);
    assert(rows[outer].frames == 10);
}

unittest {
    // Disabled profiler: zones are no-ops; GPU zones commit only on GPU frames; trace JSON.
    resetProfilerForTests();
    {
        auto z = profileZone!"test.off"();
    }
    assert(profilerReport().length == 0);
    enableProfiler(true);
    scope (exit) enableProfiler(false);
    startProfilerTrace(16);
    immutable g = registerZone("gpu.test", ZoneKind.gpu, NO_ZONE, 0);
    addZoneTime(g, 2.0);
    {
        auto z = profileZone!"test.traced"();
    }
    profilerEndFrame();
    traceEvent(g, 0, ZoneKind.gpu, 0, 2_000_000);
    profilerEndGpuFrame();
    stopProfilerTrace();
    import std.algorithm : canFind;
    immutable json = profilerTraceJson();
    assert(json.canFind(`"name":"test.traced"`) && json.canFind(`"tid":2`));
    foreach (r; profilerReport())
        if (r.name == "gpu.test")
            assert(r.frames == 1 && r.meanMs == 2.0);
}
