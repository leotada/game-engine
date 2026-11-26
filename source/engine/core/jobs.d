/**
 * Background job queue: run CPU-heavy work (mesh deformation, decoding,
 * baking) on worker threads instead of inside the frame.
 *
 * ---
 * JobQueue jobs;
 * jobs.start(1);                               // at load: allocates the workers
 *
 * struct Dent { TexVert[] verts; Vec3 point; } // lives until the job is finished
 * static void dent(ref Dent d) @safe nothrow { ... }
 *
 * auto t = jobs.submit!dent(&slot.dent);       // frame N: returns at once
 * ...
 * if (jobs.isDone(t)) {                        // frame N+1 (or `finish` to wait)
 *     immutable ms = jobs.finish(t);           // frees the ticket
 *     mesh.updateVertices(gpu, slot.dent.verts);
 * }
 * ---
 *
 * Rules:
 * - `submit`, `isDone` and `finish` belong to one owner thread (the frame
 *   loop). Jobs run in submission order per worker; with several workers
 *   they run concurrently, so they must not share data they write.
 * - The context passed to `submit` belongs to the job until `finish`
 *   returns: the owner must not read or write it before. It must outlive the
 *   job, so it cannot be a stack local (DIP1000 rejects one in `@safe` code).
 * - Every ticket must be finished: that frees its slot. A full queue makes
 *   `submit` return a null ticket instead of blocking.
 * - With 0 workers (and on WebAssembly) `submit` runs the job at once on the
 *   calling thread: same results, same tickets, handy for tests.
 * - The profiler is thread-local, so zones opened inside a job are not
 *   recorded. `finish` returns the job's run time: push it from the owner
 *   thread with `profileSample!"name"(ms)`.
 * - Workers are ordinary D threads: jobs may allocate on the GC heap and
 *   touch GC memory, and they pause with the other threads during a
 *   collection.
 */
module engine.core.jobs;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;

@safe:

/// A submitted job. The zero ticket is null (`submit` on a full queue).
struct JobTicket {
    private uint index;
    private uint gen;

    bool isNull() const pure nothrow @nogc { return gen == 0; }
}

/// Fixed-capacity queue of jobs run by `workerCount` background threads.
struct JobQueue {
    private State* s;

    @disable this(this);

    /// Start `workers` threads with room for `capacity` unfinished jobs.
    /// Allocates: call it at load time, not in the frame. 0 workers runs jobs inline.
    void start(uint workers = 1, uint capacity = 64) @trusted {
        assert(s is null, "JobQueue already started");
        assert(capacity > 0);
        version (WebAssembly) workers = 0;
        s = new State;
        s.slots = new Slot[capacity];
        s.ring = new uint[capacity];
        foreach (ref slot; s.slots) slot.gen = 1;
        if (workers == 0) return;
        import core.sync.event : Event;
        import core.sync.mutex : Mutex;
        import core.thread : Thread;
        s.lock = new Mutex;
        s.wake = new Event(false, false);
        s.done = new Event(false, false);
        s.threads = new Thread[workers];
        auto st = s;
        foreach (ref t; s.threads) {
            t = new Thread(() { workerLoop(st); });
            t.start();
        }
    }

    /// Let the workers finish every queued job, then join them. Unfinished
    /// tickets become invalid. Safe to call when not started.
    void stop() @trusted {
        if (s is null) return;
        if (s.threads.length) {
            s.lock.lock_nothrow();
            s.stopping = true;
            s.lock.unlock_nothrow();
            s.wake.setIfInitialized();
            foreach (t; s.threads) t.join();
            s.wake.terminate();
            s.done.terminate();
        }
        s = null;
    }

    /// True between `start` and `stop`.
    bool running() const pure nothrow @nogc { return s !is null; }

    /// Number of worker threads (0 = inline).
    uint workerCount() const pure nothrow @nogc @trusted {
        return s is null ? 0 : cast(uint) s.threads.length;
    }

    /// Queue `fn(*ctx)` and return at once. `fn` must be `@safe nothrow`.
    /// Returns a null ticket when `capacity` jobs are unfinished. With workers
    /// it does not allocate; inline (0 workers) it runs `fn` here.
    JobTicket submit(alias fn, T)(T* ctx) nothrow @trusted {
        static assert(__traits(compiles, () @safe nothrow { T* c; fn(*c); }),
            "JobQueue.submit: `" ~ __traits(identifier, fn) ~ "` must be callable as @safe nothrow with ref "
            ~ T.stringof);
        static void run(void* p) nothrow @trusted { fn(*cast(T*) p); }
        assert(s !is null, "JobQueue not started");
        assert(ctx !is null);
        if (s.threads.length == 0) {
            immutable i = s.freeSlot();
            if (i == NONE) return JobTicket.init;
            auto slot = &s.slots[i];
            slot.run = &run;
            slot.ctx = ctx;
            runSlot(*slot);
            return JobTicket(i, slot.gen);
        }
        s.lock.lock_nothrow();
        immutable i = s.freeSlot();
        if (i == NONE) {
            s.lock.unlock_nothrow();
            return JobTicket.init;
        }
        auto slot = &s.slots[i];
        slot.run = &run;
        slot.ctx = ctx;
        atomicStore!(MemoryOrder.rel)(slot.state, SlotState.queued);
        s.ring[(s.head + s.queued) % s.ring.length] = i;
        ++s.queued;
        s.lock.unlock_nothrow();
        s.wake.setIfInitialized();
        return JobTicket(i, slot.gen);
    }

    /// True once the job ran: its context may be read (then `finish` it).
    bool isDone(JobTicket t) const nothrow @nogc @trusted {
        if (s is null || t.isNull || t.index >= s.slots.length) return false;
        const slot = &s.slots[t.index];
        return slot.gen == t.gen && atomicLoad!(MemoryOrder.acq)(slot.state) == SlotState.done;
    }

    /// Wait for the job (blocking the caller if it has not run yet), free its
    /// ticket and return how long it ran, in milliseconds.
    double finish(JobTicket t) nothrow @nogc @trusted {
        assert(s !is null && !t.isNull && t.index < s.slots.length && s.slots[t.index].gen == t.gen,
            "JobQueue.finish: unknown or already finished ticket");
        auto slot = &s.slots[t.index];
        while (atomicLoad!(MemoryOrder.acq)(slot.state) != SlotState.done)
            s.done.wait();
        immutable ms = slot.runNs / 1e6;
        slot.run = null;
        slot.ctx = null;
        if (++slot.gen == 0) slot.gen = 1;
        atomicStore!(MemoryOrder.rel)(slot.state, SlotState.free);
        return ms;
    }
}

private:

enum uint NONE = uint.max;

enum SlotState : ubyte { free, queued, running, done }

struct Slot {
    void function(void*) nothrow run;
    void* ctx;
    uint gen;
    shared SlotState state;
    long runNs;
}

struct State {
    import core.sync.event : Event;
    import core.sync.mutex : Mutex;
    import core.thread : Thread;

    Slot[] slots;
    uint[] ring;          /// queued slot indices, FIFO
    uint head, queued;    /// guarded by `lock`
    bool stopping;        /// guarded by `lock`
    Mutex lock;
    Event* wake;          /// auto-reset: one worker per signal, which passes it on
    Event* done;          /// auto-reset: a job finished
    Thread[] threads;

    /// First free slot, or NONE. With workers, the caller holds `lock`.
    uint freeSlot() nothrow @nogc {
        foreach (i, ref slot; slots)
            if (atomicLoad!(MemoryOrder.acq)(slot.state) == SlotState.free)
                return cast(uint) i;
        return NONE;
    }
}

void runSlot(ref Slot slot) nothrow @trusted {
    import core.time : MonoTime;
    immutable t0 = MonoTime.currTime;
    slot.run(slot.ctx);
    slot.runNs = (MonoTime.currTime - t0).total!"nsecs";
    atomicStore!(MemoryOrder.rel)(slot.state, SlotState.done);
}

void workerLoop(State* s) nothrow @trusted {
    for (;;) {
        s.lock.lock_nothrow();
        if (s.queued == 0) {
            immutable stop = s.stopping;
            s.lock.unlock_nothrow();
            if (stop) {
                s.wake.setIfInitialized(); // let the next worker see it too
                return;
            }
            s.wake.wait();
            continue;
        }
        immutable i = s.ring[s.head];
        s.head = cast(uint)((s.head + 1) % s.ring.length);
        immutable more = --s.queued > 0;
        atomicStore!(MemoryOrder.rel)(s.slots[i].state, SlotState.running);
        s.lock.unlock_nothrow();
        if (more) s.wake.setIfInitialized();
        runSlot(s.slots[i]);
        s.done.setIfInitialized();
    }
}

version (unittest) {
    struct Work {
        uint[] values;
        uint add;
        uint sum;
    }

    void addAll(ref Work w) @safe nothrow {
        foreach (ref v; w.values) v += w.add;
        foreach (v; w.values) w.sum += v;
    }
}

@("jobs.inline runs at submit") unittest {
    JobQueue q;
    q.start(0, 4);
    scope (exit) q.stop();
    auto w = new Work([1, 2, 3], 10);
    auto t = q.submit!addAll(w);
    assert(!t.isNull && q.isDone(t));
    assert(w.sum == 36);
    assert(q.finish(t) >= 0);
    assert(!q.isDone(t), "finished tickets are stale");
}

@("jobs.workers run every job once") unittest {
    foreach (workers; [1u, 3u]) {
        JobQueue q;
        q.start(workers, 16);
        auto work = new Work*[16];
        JobTicket[16] tickets;
        foreach (i, ref w; work) {
            w = new Work(new uint[1000], cast(uint) i);
            tickets[i] = q.submit!addAll(w);
            assert(!tickets[i].isNull);
        }
        foreach (i, t; tickets) {
            q.finish(t);
            assert(work[i].sum == 1000 * i);
            foreach (v; work[i].values) assert(v == i);
        }
        q.stop();
    }
}

@("jobs.full queue returns a null ticket") unittest {
    JobQueue q;
    q.start(0, 2);
    scope (exit) q.stop();
    auto a = new Work([1]), b = new Work([2]), c = new Work([3]);
    auto ta = q.submit!addAll(a), tb = q.submit!addAll(b);
    assert(q.submit!addAll(c).isNull);
    q.finish(ta);
    auto tc = q.submit!addAll(c);
    assert(!tc.isNull && tc != ta, "a reused slot gets a new generation");
    q.finish(tb);
    q.finish(tc);
}

@("jobs.stop runs what is queued") unittest {
    JobQueue q;
    q.start(2, 8);
    auto work = new Work*[8];
    foreach (ref w; work) {
        w = new Work(new uint[200], 1);
        assert(!q.submit!addAll(w).isNull);
    }
    q.stop();
    foreach (ref w; work) assert(w.sum == 200);
    assert(!q.running);
}
