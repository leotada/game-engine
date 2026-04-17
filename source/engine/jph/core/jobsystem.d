// Jolt — Core/JobSystem.h + JobSystemSingleThreaded equivalents.
//
// `JobSystem` is the abstract API used by `PhysicsSystem::Update` to schedule
// units of work with dependencies. The single-threaded implementation runs
// every job synchronously the moment its dependency counter hits zero, so
// barriers degenerate to no-ops. This is sufficient for the MVP and matches
// `JobSystemSingleThreaded.{h,cpp}` semantics in Jolt.
//
// Job storage uses a fixed-size pool to avoid per-frame allocations. The pool
// size is set via `Init(maxJobs)`; exceeding it is a fatal assertion.
//
// Source: ref/JoltPhysics/Jolt/Core/JobSystem.{h,inl},
//          ref/JoltPhysics/Jolt/Core/JobSystemSingleThreaded.{h,cpp}.
module engine.jph.core.jobsystem;

import engine.jph.core.atomics;
import engine.jph.core.color    : Color, ColorArg;
import engine.jph.core.memory   : jphAlloc, jphFree;
import engine.jph.core.types    : uint32, uint_, int32;

@safe:

/// Function pointer + opaque context — the `@nogc nothrow` analogue of
/// `std::function<void()>`. Mirrors how Jolt physics jobs only need to call
/// one entry point with one captured pointer.
struct JobFunction {
    void function(void*) @nogc nothrow @safe entry;
    void* ctx;

    void invoke() @trusted @nogc nothrow {
        if (entry !is null) entry(ctx);
    }

    bool isNull() const nothrow @nogc { return entry is null; }
}

/// Forward declaration of internal Job, exposed only via JobHandle.
final class Job {
    private string         mName;
    private Color          mColor;
    private JobSystem      mJobSystem;
    private JobFunction    mFunction;
    private shared int32   mDependencies;
    private shared uint32  mRefCount;

    this(string name, Color color, JobSystem sys, JobFunction fn, uint32 deps)
        @trusted @nogc nothrow
    {
        mName = name;
        mColor = color;
        mJobSystem = sys;
        mFunction = fn;
        mDependencies = cast(int32) deps;
        mRefCount = 0;
    }

    /// Returns the JobSystem that owns this job.
    JobSystem GetJobSystem() @nogc nothrow { return mJobSystem; }

    void AddRef() const @trusted @nogc nothrow {
        atomicFetchAdd!(MemoryOrder.raw)(*cast(shared(uint32)*) &mRefCount, 1);
    }

    void Release() const @trusted @nogc nothrow {
        immutable old = atomicFetchSub!(MemoryOrder.rel)(
            *cast(shared(uint32)*) &mRefCount, 1);
        if (old == 1) {
            atomicFence!(MemoryOrder.acq);
            (cast(JobSystem) mJobSystem).freeJobInternal(cast(Job) this);
        }
    }

    /// Add to the dependency counter.
    void AddDependency(int32 count = 1) @trusted @nogc nothrow {
        atomicFetchAdd!(MemoryOrder.raw)(mDependencies, count);
    }

    /// Decrement and queue if it reached zero.
    void RemoveDependencyAndQueue(int32 count = 1) @trusted @nogc nothrow {
        immutable prev = atomicFetchSub!(MemoryOrder.acq_rel)(mDependencies, count);
        if (prev - count == 0) {
            mJobSystem.queueJobInternal(this);
        }
    }

    bool IsDone() const @trusted @nogc nothrow {
        return atomicLoad!(MemoryOrder.acq)(mDependencies) < 0;
    }

    void Execute() @trusted @nogc nothrow {
        mFunction.invoke();
        atomicStore!(MemoryOrder.rel)(mDependencies, int32.min); // mark done
    }
}

/// Equivalent of Jolt's `JobSystem::JobHandle` — a ref-counted pointer to a Job.
struct JobHandle {
@safe:
    private Job mJob = null;

    this(Job j) @trusted @nogc nothrow {
        mJob = j;
        if (mJob !is null) mJob.AddRef();
    }

    this(this) @trusted @nogc nothrow {
        if (mJob !is null) mJob.AddRef();
    }

    ~this() @trusted @nogc nothrow {
        if (mJob !is null) mJob.Release();
    }

    void opAssign(JobHandle rhs) @trusted @nogc nothrow {
        if (mJob is rhs.mJob) return;
        if (mJob !is null) mJob.Release();
        mJob = rhs.mJob;
        if (mJob !is null) mJob.AddRef();
    }

    bool IsValid() const @nogc nothrow { return mJob !is null; }
    bool IsDone() const @nogc nothrow { return mJob !is null && mJob.IsDone(); }

    void AddDependency(int32 count = 1) @trusted @nogc nothrow {
        assert(mJob !is null);
        mJob.AddDependency(count);
    }

    void RemoveDependency(int32 count = 1) @trusted @nogc nothrow {
        assert(mJob !is null);
        mJob.RemoveDependencyAndQueue(count);
    }

    Job GetPtr() @nogc nothrow { return mJob; }
}

/// Abstract barrier (waitable group of jobs).
abstract class Barrier {
    void AddJob(JobHandle inJob) @nogc nothrow @safe;
    void AddJobs(JobHandle[] handles) @nogc nothrow @safe;
}

/// Abstract job system.
abstract class JobSystem {
    int GetMaxConcurrency() const @nogc nothrow @safe;
    JobHandle CreateJob(string name, ColorArg color, JobFunction fn, uint32 numDeps = 0)
        @nogc nothrow @safe;
    Barrier   CreateBarrier() @nogc nothrow @safe;
    void      DestroyBarrier(Barrier b) @nogc nothrow @safe;
    void      WaitForJobs(Barrier b) @nogc nothrow @safe;

    /// Implemented by concrete subclasses; called by Job internals.
    abstract void queueJobInternal(Job j) @nogc nothrow @safe;
    abstract void queueJobsInternal(Job*[] jobs) @nogc nothrow @safe;
    abstract void freeJobInternal(Job j) @nogc nothrow @safe;
}

// ---------------------------------------------------------------------------
// JobSystemSingleThreaded
// ---------------------------------------------------------------------------

final class JobSystemSingleThreaded : JobSystem {
    private static final class BarrierImpl : Barrier {
        override void AddJob(JobHandle h) @nogc nothrow {}
        override void AddJobs(JobHandle[] h) @nogc nothrow {}
    }

    private BarrierImpl mDummy;
    private uint_       mMaxJobs = 0;
    private uint_       mLiveJobs = 0;

    this() @trusted @nogc nothrow {
        import engine.jph.core.memory : jphNew;
        mDummy = jphNew!BarrierImpl();
    }

    this(uint_ maxJobs) @trusted @nogc nothrow {
        this();
        Init(maxJobs);
    }

    ~this() @trusted @nogc nothrow {
        import engine.jph.core.memory : jphDelete;
        if (mDummy !is null) {
            jphDelete!BarrierImpl(mDummy);
            mDummy = null;
        }
    }

    void Init(uint_ maxJobs) @nogc nothrow {
        mMaxJobs = maxJobs;
    }

    override int GetMaxConcurrency() const @nogc nothrow { return 1; }

    override JobHandle CreateJob(string name, ColorArg color, JobFunction fn, uint32 numDeps = 0)
        @trusted @nogc nothrow
    {
        import engine.jph.core.memory : jphNew;
        assert(mMaxJobs == 0 || mLiveJobs < mMaxJobs, "JobSystemSingleThreaded job pool exhausted");
        ++mLiveJobs;
        auto j = jphNew!Job(name, color, this, fn, numDeps);
        auto h = JobHandle(j);  // refcount 1
        if (numDeps == 0) queueJobInternal(j);
        return h;
    }

    override Barrier CreateBarrier() @nogc nothrow { return mDummy; }
    override void DestroyBarrier(Barrier b) @nogc nothrow {} // shared dummy
    override void WaitForJobs(Barrier b) @nogc nothrow {}    // jobs already ran

    override void queueJobInternal(Job j) @trusted @nogc nothrow {
        j.Execute();
    }

    override void queueJobsInternal(Job*[] jobs) @trusted @nogc nothrow {
        foreach (jp; jobs) jp.Execute();
    }

    override void freeJobInternal(Job j) @trusted @nogc nothrow {
        import engine.jph.core.memory : jphDelete;
        if (mLiveJobs > 0) --mLiveJobs;
        jphDelete!Job(j);
    }
}

// ---------------------------------------------------------------------------
// Smoke test
// ---------------------------------------------------------------------------
unittest {
    import engine.jph.core.memory : jphNew, jphDelete;

    auto sys = jphNew!JobSystemSingleThreaded(64u);
    scope(exit) () @trusted { jphDelete!JobSystemSingleThreaded(sys); }();

    static int counter = 0;

    extern(D) static void inc(void* ctx) @system @nogc nothrow {
        // Counter is module-static; safe in a single-threaded test.
        (*cast(int*) ctx) += 1;
    }

    JobFunction fn;
    () @trusted {
        fn.entry = cast(typeof(fn.entry)) &inc;
        fn.ctx   = cast(void*) &counter;
    }();

    auto h = sys.CreateJob("inc", Color.sRed, fn);  // runs immediately
    assert(counter == 1);
    assert(h.IsDone);
}
