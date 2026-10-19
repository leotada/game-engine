// D runtime hook to include symgc as an option for garbage collection.
module symgc.gcobj;

import core.gc.gcinterface;
static import core.memory;

import core.thread.threadbase : ThreadBase;

import core.stdc.string : memset;

// The game-engine interface (GC.frameStats, thread exclusion, step, defrag)
// only exists in a patched druntime. Without it the collector still builds
// and runs; the methods are there but nothing in druntime calls them.
enum hasGCTelemetry = is(GCTelemetry);

static if (hasGCTelemetry)
	private alias SnazzyBases = AliasSeq!(GC, GCTelemetry);
else
	private alias SnazzyBases = AliasSeq!(GC);

private template AliasSeq(T...) { alias AliasSeq = T; }

// when running unittests and druntime is involved, set the GC to the symmetry GC
version(Symgc_testing) version(Symgc_druntime_hooks) {
	extern(C) __gshared rt_options = ["gcopt=gc:sdc"];
}

extern(C) nothrow {
	void onOutOfMemoryError(void* pretend_sideffect = null, string file = __FILE__, size_t line = __LINE__) @trusted nothrow @nogc;

	// c api from gc
	void __sd_gc_init();
	void __sd_gc_collect();
	void __sd_gc_free(void *ptr) @nogc;
	void __sd_gc_add_roots(void[] range) @nogc;
	void __sd_gc_remove_roots(void *ptr) @nogc;
	uint __sd_gc_enable();
	uint __sd_gc_disable();
	void __sd_gc_run_finalizers(const void[] segment);
	bool __sd_gc_set_finalizer_attr(void* ptr, void* finalizer);
	void __sd_gc_clear_finalizer_attr(void* ptr);
	void __sd_gc_profile_stats(ulong* dst);
	void __sd_gc_exclude_current_thread();
	void __sd_gc_include_current_thread();
	bool __sd_gc_is_thread_excluded();
	void __sd_gc_step(ulong maxTimeHns);
	void __sd_gc_time_thread(ulong* dst);
	void __sd_gc_time_total(ulong* dst);
	size_t __sd_gc_defrag();

	// hook prototypes needed for druntime api (see below)
	void* __sd_gc_hook_alloc(size_t size, bool containsPointers, bool zeroData);
	void* __sd_gc_hook_alloc_appendable(size_t size, bool containsPointers, bool zeroData, void* finalizer);
	BlkInfo __sd_gc_hook_fetch_alloc_info(void *ptr) @nogc;
	void *__sd_gc_hook_realloc(void *ptr, size_t size, bool hasPointers);
	size_t __sd_gc_hook_get_array_capacity(void[] slice) @nogc;
	void[] __sd_gc_hook_get_allocation_slice(void *ptr) @nogc;
	bool __sd_gc_hook_extend_array_used(void* ptr, size_t newUsed, size_t existingUsed);
	bool __sd_gc_hook_shrink_array_used(void* ptr, size_t newUsed, size_t existingUsed);
	bool __sd_gc_hook_reserve_array_capacity(void* ptr, size_t request, size_t existingUsed);
}

enum TYPEINFO_IN_BLOCK = cast(void*)1;

void initSDCThread(ThreadBase t) nothrow @nogc
{
	// if we are using the pthread hook, this is already done by the pthread hook.
	version(Symgc_pthread_hook) {} else {
		import d.gc.thread;
		// TODO: see if this can be correctly marked
		// createThread!false();
		(cast(void function() nothrow @nogc)&createThread!false)();
	}

	// set up the thread to point at our thread cache;
	import d.gc.tcache;
	t.tlsGCData = &threadCache;
}

private pragma(crt_constructor) void gc_sdc_ctor()
{
	_d_register_sdc_gc();
}

// A druntime older than 2.112 (GDC 15 ships 2.111) has no thread-init hook in
// registerGCFactory: it never tells the collector about the threads it creates, so
// the first stop-the-world finds a druntime thread without a thread cache.
// Such a druntime runs every module's thread-local constructor when a thread
// starts, before its function, and the destructor when the function returns,
// before the thread leaves druntime's list: the same two moments the hook has.
enum druntimeCallsThreadHooks = __traits(compiles, {
	import core.gc.registry;
	registerGCFactory("sdc", &initialize, &initSDCThread);
});

static if (!druntimeCallsThreadHooks) version (Posix)
{
	// The lock of druntime's thread list is taken and released through these two (their names say
	// what the collector uses them for).
	extern(C) private void thread_preStopTheWorld() nothrow @nogc;
	extern(C) private void thread_postRestartTheWorld() nothrow @nogc;

	// Set on the thread that created the process state (the one that ran initialize):
	// it is registered already, and lives as long as the collector.
	private bool processThread;

	static this()
	{
		import core.thread : Thread;
		import d.gc.tcache;

		auto t = Thread.getThis();
		if (t is null || t.tlsGCData !is null)
			return;

		if (processThread)
		{
			t.tlsGCData = &threadCache;
			return;
		}

		// The stop-the-world holds the list's lock (thread_preStopTheWorld) before it takes
		// its own, so registering under that lock puts this thread either wholly before the
		// stop (it is signalled like any other) or wholly after it (it never saw the world
		// stopped half way through registering).
		thread_preStopTheWorld();
		scope(exit) thread_postRestartTheWorld();
		initSDCThread(t);
	}

	static ~this()
	{
		import core.thread : Thread;
		import d.gc.tcache;

		auto t = Thread.getThis();
		if (t is null || processThread || t.tlsGCData !is &threadCache)
			return;

		import d.gc.thread;
		(cast(void function() nothrow @nogc)&destroyThread)();
	}
}

extern(C) void thread_setGCSignals(int suspendSignalNo, int resumeSignalNo) nothrow @nogc;

extern(C) void _d_register_sdc_gc()
{
	version(Symgc_pthread_hook)
	{
		// need to initialize early, as the pthread create hook needs stuff set up.
		import d.gc.thread;
		createProcess();
	}
	else version(Posix)
	{
		// set druntime's signals to match ours, we are going to use their
		// signal mechanisms. Have to do this before dmain2/thread_init.
		import d.gc.signal;
		thread_setGCSignals(SIGSUSPEND, SIGRESUME);
	}

	import core.gc.registry;
	static if(__traits(compiles, registerGCFactory("sdc", &initialize, &initSDCThread)))
	{
		registerGCFactory("sdc", &initialize, &initSDCThread);
		registerGCFactory("sdcq", &initializeQuiet, &initSDCThread);
	}
	else
	{
		version(Posix) {
			registerGCFactory("sdc", &initialize);
			registerGCFactory("sdcq", &initializeQuiet);
		}
		else
			static assert(false, "No support for threadInit in gcinterface!");
	}
}


// since all the real work is done in the SDC library, the class is just a
// shim, and can just be initialized at compile time.
private __gshared SnazzyGC instance = new SnazzyGC;

private GC initializeQuiet()
{
	version(Symgc_pthread_hook) { }
	else {
		// now it is ok to initialize
		import d.gc.thread;
		createProcess();
		static if (!druntimeCallsThreadHooks) version (Posix)
			processThread = true;
	}

	// check the config to see if we should set the thread count for scanning.
	import core.gc.config;
	// ignore the thread count if it's the default.
	if (config.parallel != typeof(config).init.parallel)
	{
		import d.gc.collector;
		setScanningThreads(config.parallel + 1);
	}

	static if (is(typeof(config.heapSizeLimit)))
	{
		import d.gc.collector;
		setHeapSizeLimit(config.heapSizeLimit);
	}

	return instance;
}

private GC initialize()
{
	import core.stdc.stdio;
	printf("using SYM GC!\n");
	return initializeQuiet();
}

final class SnazzyGC : SnazzyBases
{
	void enable()
	{
		__sd_gc_enable();
	}

	/**
	 *
	 */
	void disable()
	{
		__sd_gc_disable();
	}

	/**
	 *
	 */
	void collect() nothrow
	{
		__sd_gc_collect();
	}

	/**
	 * minimize free space usage
	 */
	void minimize() nothrow
	{
		__sd_gc_defrag();
	}

	/**
	 *
	 */
	uint getAttr(void* p) nothrow
	{
		auto blkinfo = query(p);
		return blkinfo.attr;
	}

	/**
	 *
	 */
	uint setAttr(void* p, uint mask) nothrow
	{
		// Only FINALIZE can be given after the allocation (the monitor of an
		// object needs it, see rt.monitor_). The others are fixed when the
		// block is allocated: where it is, and whether it is scanned.
		if (mask & BlkAttr.FINALIZE) {
			__sd_gc_set_finalizer_attr(p, TYPEINFO_IN_BLOCK);
		}

		return getAttr(p);
	}

	/**
	 *
	 */
	uint clrAttr(void* p, uint mask) nothrow
	{
		if (mask & BlkAttr.FINALIZE) {
			__sd_gc_clear_finalizer_attr(p);
		}

		return getAttr(p);
	}

	/**
	 *
	 */
	void *malloc(size_t size, uint bits, const TypeInfo ti) nothrow
	{
		return sdcAllocate(size, bits, false, ti);
	}

	/*
	 *
	 */
	BlkInfo qalloc(size_t size, uint bits, const scope TypeInfo ti) nothrow
	{
		// Phobos Appender (std.format) calls qalloc with NO_SCAN only — never
		// APPENDABLE — and starts at 8 bytes, then 8→16→32→64 with a failed
		// GC.extend between each step. Floor plain small NO_SCAN requests so
		// one slot covers a typical format line; bi.size reports the full slot.
		enum qallocNoScanFloor = 64;
		// Floor small NO_SCAN qalloc (Appender/format). APPENDABLE is allowed:
		// the allocAppendable path no longer floors, so qalloc is the only
		// place that keeps a typical format line in one slot. FINALIZE stays out.
		if (size > 0 && size < qallocNoScanFloor
		    && (bits & BlkAttr.NO_SCAN) != 0
		    && (bits & BlkAttr.FINALIZE) == 0) {
			size = qallocNoScanFloor;
		}

		size_t blkSize;
		uint attr;
		auto ptr = sdcAllocate(size, bits, false, ti, &blkSize, &attr);
		if (!ptr)
			return BlkInfo.init;

		if (blkSize != 0) {
			BlkInfo bi;
			bi.base = ptr;
			bi.size = blkSize;
			bi.attr = attr;
			return bi;
		}

		return __sd_gc_hook_fetch_alloc_info(ptr);
	}

	/*
	 *
	 */
	void *calloc(size_t size, uint bits, const TypeInfo ti) nothrow
	{
		return sdcAllocate(size, bits, true, ti);
	}

	/*
	 *
	 */
	void* realloc(void* p, size_t size, uint bits, const TypeInfo ti) nothrow
	{
		checkNotInFinalizer();

		// As in the other collectors, no attributes means to keep those of the
		// block (the part that we have, whether it is scanned).
		bool noScan = (bits & BlkAttr.NO_SCAN) != 0;
		if (bits == 0 && p !is null) {
			noScan = (query(p).attr & BlkAttr.NO_SCAN) != 0;
		}

		return __sd_gc_hook_realloc(p, size, !noScan);
	}

	/**
	 * Attempt to in-place enlarge the memory block pointed to by p by at least
	 * minsize bytes, up to a maximum of maxsize additional bytes.
	 * This does not attempt to move the memory block (like realloc() does).
	 *
	 * Returns:
	 *  0 if could not extend p,
	 *  total size of entire memory block if successful.
	 */
	size_t extend(void* p, size_t minsize, size_t maxsize, const TypeInfo ti) nothrow
	{
		// Grow a large block in place when free pages follow (same idea as
		// druntime). Small slabs already return full slot capacity from qalloc.
		return (cast(size_t function(void*, size_t, size_t) nothrow)&extendLarge)(
			p, minsize, maxsize);
	}

	/**
	 *
	 */
	size_t reserve(size_t size) nothrow
	{
		// Our GC does not support reserving memory from the OS. In practice,
		// this would not work anyway, as all preallocated memory would be handed
		// back to the OS on the next collect.
		return 0;
	}

	/**
	 *
	 */
	void free(void* p) nothrow @nogc
	{
		// Note: p is not supposed to be freed if it is an interior pointer,
		// but it is freed in SDC in this case.
		__sd_gc_free(p);
	}

	/**
	 * Determine the base address of the block containing p.  If p is not a gc
	 * allocated pointer, return null.
	 */
	void* addrOf(void* p) nothrow @nogc
	{
		auto blkinfo = query(p);
		return blkinfo.base;
	}

	/**
	 * Determine the allocated size of pointer p.  If p is an interior pointer
	 * or not a gc allocated pointer, return 0.
	 */
	size_t sizeOf(void* p) nothrow @nogc
	{
		auto blkinfo = query(p);
		return blkinfo.size;
	}

	/**
	 * Determine the base address of the block containing p.  If p is not a gc
	 * allocated pointer, return null.
	 */
	BlkInfo query(void* p) nothrow @nogc
	{
		return __sd_gc_hook_fetch_alloc_info(p);
	}

	/**
	 * Retrieve statistics about garbage collection.
	 * Useful for debugging and tuning.
	 */
	core.memory.GC.Stats stats() @trusted nothrow @nogc
	{
		import d.gc.collector;
		// TODO: remove this when nothrow is properly tagged everywhere.
		auto stats = (cast(typeof(lastCollectionInfo()) function() nothrow @nogc)&lastCollectionInfo)();
		import d.gc.spec : PageSize;
		return core.memory.GC.Stats(
			usedSize : stats.usedPages * PageSize,
			freeSize: stats.freeBytes,
			allocatedInCurrentThread : threadCache.allocatedInThread()
		);
	}

	/**
	 * Retrieve profile statistics about garbage collection.
	 * Useful for debugging and tuning.
	 */
	core.memory.GC.ProfileStats profileStats() @trusted nothrow @nogc
	{
		import core.time : hnsecs;
		ulong[5] v;
		(cast(void function(ulong*) nothrow @nogc) &__sd_gc_profile_stats)(v.ptr);

		core.memory.GC.ProfileStats ps;
		ps.numCollections = cast(size_t) v[0];
		ps.totalCollectionTime = hnsecs(v[1]);
		ps.totalPauseTime = hnsecs(v[2]);
		ps.maxPauseTime = hnsecs(v[3]);
		ps.maxCollectionTime = hnsecs(v[4]);
		return ps;
	}

	/**
	 * Retrieve real-time frame telemetry about garbage collection.
	 * Designed for game loops, profilers, and HUDs.
	 */
	static if (hasGCTelemetry)
	core.memory.GC.FrameStats frameStats() nothrow @nogc @safe
	{
		import core.time : nsecs;
		import d.gc.extent : gMarkActive, gSweepCycle;

		ulong[6] threadTimes = void;
		ulong[6] totalTimes = void;
		() @trusted nothrow @nogc {
			(cast(void function(ulong*) nothrow @nogc)&__sd_gc_time_thread)(threadTimes.ptr);
			(cast(void function(ulong*) nothrow @nogc)&__sd_gc_time_total)(totalTimes.ptr);
		}();

		core.memory.GC.FrameStats fs;
		fs.threadAllocTime = nsecs(threadTimes[0]);
		fs.threadCollectTime = nsecs(threadTimes[1]);
		fs.threadPauseTime = nsecs(threadTimes[2]);

		fs.totalAllocTime = nsecs(totalTimes[0]);
		fs.totalCollectTime = nsecs(totalTimes[1]);
		fs.totalPauseTime = nsecs(totalTimes[2]);

		fs.isCycleActive = (gMarkActive.load() != 0) || (gSweepCycle.load() != 0);

		import d.gc.collector : lastCollectionStatsFast;
		import d.gc.arena : Arena;
		import d.gc.spec : PageSize;
		size_t lastUsedPages;
		size_t freeBytes;
		size_t numColls;
		() @trusted nothrow @nogc {
			lastCollectionStatsFast(lastUsedPages, freeBytes, numColls);
		}();
		size_t activeUsed = () @trusted nothrow @nogc {
			return (cast(size_t function() nothrow @nogc)&Arena.computeUsedPageCount)() * PageSize;
		}();
		fs.usedSize = activeUsed > 0 ? activeUsed : lastUsedPages * PageSize;
		fs.freeSize = freeBytes;
		fs.numCollections = numColls;

		return fs;
	}

	void excludeCurrentThread() @trusted nothrow @nogc
	{
		(cast(void function() nothrow @nogc)&__sd_gc_exclude_current_thread)();
	}

	void includeCurrentThread() @trusted nothrow @nogc
	{
		(cast(void function() nothrow @nogc)&__sd_gc_include_current_thread)();
	}

	bool isThreadExcluded() @trusted nothrow @nogc
	{
		return (cast(bool function() nothrow @nogc)&__sd_gc_is_thread_excluded)();
	}

	void step(ulong maxTimeHns) @trusted nothrow @nogc
	{
		(cast(void function(ulong) nothrow @nogc)&__sd_gc_step)(maxTimeHns);
	}

	size_t defrag() @trusted nothrow @nogc
	{
		return (cast(size_t function() nothrow @nogc)&__sd_gc_defrag)();
	}

	/**
	 * add p to list of roots
	 */
	void addRoot(void* p) nothrow @nogc
	{
		__sd_gc_add_roots(p[0 .. 0]);
	}

	/**
	 * remove p from list of roots
	 */
	void removeRoot(void* p) nothrow @nogc
	{
		__sd_gc_remove_roots(p);
	}

	/**
	 *
	 */
	@property RootIterator rootIter() @nogc
	{
		return &iterateRoots!Root;
	}

	/**
	 * add range to scan for roots
	 */
	void addRange(void* p, size_t sz, const TypeInfo ti) nothrow @nogc
	{
		__sd_gc_add_roots(p[0 .. sz]);
	}

	/**
	 * remove range
	 */
	void removeRange(void* p) nothrow @nogc
	{
		__sd_gc_remove_roots(p);
	}

	/**
	 *
	 */
	@property RangeIterator rangeIter() @nogc
	{
		return &iterateRoots!Range;
	}

	private int iterateRoots(T)(scope int delegate(ref T) nothrow dg) nothrow {
		import d.gc.global;
		return gState.iterateRoots(dg);
	}

	/**
	 * run finalizers
	 */
	void runFinalizers(const scope void[] segment) nothrow
	{
		__sd_gc_run_finalizers(segment);
	}

	/*
	 *
	 */
	bool inFinalizer() nothrow @nogc @safe
	{
		import d.gc.tcache;
		return threadCache.inFinalizer;
	}

	/**
	 * Returns the number of bytes allocated for the current thread
	 * since program start. It is the same as
	 * GC.stats().allocatedInCurrentThread, but faster.
	 */
	ulong allocatedInCurrentThread() nothrow
	{
		import d.gc.tcache;
		return threadCache.allocatedInThread();
	}

	/**
	 * Get array metadata for a specific pointer. Note that the resulting
	 * metadata will point at the block start, not the pointer.
	 */
	void[] getArrayUsed(void *ptr, bool atomic) @nogc nothrow
	{
		return __sd_gc_hook_get_allocation_slice(ptr);
	}

	bool expandArrayUsed(void[] slice, size_t newUsed, bool atomic = false) nothrow @trusted
	{
		return __sd_gc_hook_extend_array_used(slice.ptr, newUsed, slice.length);
	}

	size_t reserveArrayCapacity(void[] slice, size_t request, bool atomic = false) nothrow @trusted
	{
		if(request > slice.length)
			if(!__sd_gc_hook_reserve_array_capacity(slice.ptr, request, slice.length))
				return 0;
		return __sd_gc_hook_get_array_capacity(slice);
	}

	bool shrinkArrayUsed(void[] slice, size_t existingUsed, bool atomic = false) nothrow
	{
		return __sd_gc_hook_shrink_array_used(slice.ptr, slice.length, existingUsed);
	}

	void initThread(ThreadBase t) nothrow @nogc
	{
		initSDCThread(t);
	}

	void cleanupThread(ThreadBase t) nothrow @nogc
	{
		import d.gc.tcache;
		if (t.tlsGCData is &threadCache)
		{
			// called from the current thread.
			import d.gc.thread;
			(cast(void function() nothrow @nogc)&destroyThread)();
		}
	}

	~this() {
		// clean up any lingering GC threads.
		import d.gc.scanner;
		cleanupGCThreads();

		import d.gc.collector;
		cleanupSweeper();
	}
}

// HELPER FUNCTIONS

size_t extendLarge(void* p, size_t minsize, size_t maxsize)
{
	if (p is null || minsize == 0 || minsize > maxsize) {
		return 0;
	}

	import d.gc.tcache;
	import d.gc.size;
	// Soft cached lookup: Appender's first growth tries GC.extend on a slab
	// pointer; a pd-cache hit avoids an uncached radix-tree walk before the 0.
	auto pd = threadCache.maybeGetPageDescriptorCached(p);
	auto e = pd.extent;
	if (e is null || pd.isSlab() || p !is e.address) {
		return 0;
	}

	auto oldPages = e.npages;
	auto needPages = getPageCount(e.size + minsize);
	auto wantPages = getPageCount(e.size + maxsize);
	if (needPages <= oldPages) {
		return e.size;
	}

	auto target = wantPages > needPages ? wantPages : needPages;
	if (!threadCache.growLargeForExtend(pd, target)) {
		if (target == needPages) {
			return 0;
		}
		if (!threadCache.growLargeForExtend(pd, needPages)) {
			return 0;
		}
	}

	return e.size;
}

pragma(inline, true)
void* getContextPointer(uint bits, const TypeInfo ti) nothrow @nogc
{
	if (bits & BlkAttr.FINALIZE) {
		return (ti !is null && typeid(ti) is typeid(TypeInfo_Struct)) ?
			cast(void*)ti : TYPEINFO_IN_BLOCK;
	}
	return null;
}

/**
 * A finalizer runs while the collector holds the page filler's lock, so an
 * allocation from it would wait for itself forever. It is an error in D too:
 * the other collectors throw InvalidMemoryOperationError.
 */
pragma(inline, true)
void checkNotInFinalizer() nothrow
{
	import d.gc.tcache;
	if (threadCache.inFinalizer) {
		import core.exception : onInvalidMemoryOperationError;
		onInvalidMemoryOperationError();
	}
}

pragma(inline, true)
void *sdcAllocate(size_t size, uint bits, bool zeroData, const TypeInfo ti,
                  size_t* outSize = null, uint* outAttr = null) nothrow
{
	checkNotInFinalizer();

	if (size == 0)
		return null;

	auto ctx = getContextPointer(bits, ti);

	bool containsPointers = (bits & BlkAttr.NO_SCAN) == 0;

	import d.gc.tcache;
	if ((bits & BlkAttr.APPENDABLE) || ctx)
		return (cast(void* function(ref ThreadCache, size_t, bool, bool, void*, size_t, size_t*, uint*) nothrow)
			&allocAppendableDirect)(threadCache, size + 1, containsPointers, zeroData, ctx, 0, outSize, outAttr);

	return (cast(void* function(ref ThreadCache, size_t, bool, bool, size_t*, uint*) nothrow)
		&allocDirect)(threadCache, size, containsPointers, zeroData, outSize, outAttr);
}

private void* allocDirect(ref ThreadCache tc, size_t size, bool containsPointers,
                          bool zeroData, size_t* outSize, uint* outAttr)
{
	return tc.alloc(size, containsPointers, zeroData, outSize, outAttr);
}

private void* allocAppendableDirect(ref ThreadCache tc, size_t size,
                                    bool containsPointers, bool zeroData,
                                    void* ctx, size_t capacity,
                                    size_t* outSize, uint* outAttr)
{
	return tc.allocAppendable(size, containsPointers, zeroData, ctx, capacity,
	                          outSize, outAttr);
}

// BEGIN C API HOOKS
// These hooks are prototyped at the top, but may have different attributes
// than required, so we need to cheat to get the attributes right.
//
// For a function __sd_gc_hook_foo_bar, we will name it hook_fooBar, and use pragma
// mangle to get the right symbol name.
//
// Hooks that already exist as part of the C api are not implemented here, but
// instead in d.gc.capi.

import d.gc.tcache;

extern(C):

pragma(mangle, "__sd_gc_hook_fetch_alloc_info")
BlkInfo hook_fetchAllocInfo(void* ptr) {
	BlkInfo result;
	import d.gc.capi;
	auto pd = __sd_gc_maybe_get_page_descriptor(ptr);
	auto e = pd.extent;
	if (e is null) {
		return result;
	}

	if (!pd.containsPointers) {
		result.attr |= BlkAttr.NO_SCAN;
	}

	if (pd.isSlab()) {
		import d.gc.slab;
		auto si = SlabAllocInfo(pd, ptr);

		// A slot in this thread's cache is free: never handed out, or freed by
		// this thread (GC.free, delete). The stock collector says so as well.
		if (threadCache.isFreeInCache(pd, si.address)) {
			return BlkInfo.init;
		}

		result.base = cast(void*) si.address;

		if (si.hasMetadata) {
			result.attr |= BlkAttr.APPENDABLE;
			if (si.finalizer) {
				result.attr |= BlkAttr.FINALIZE;
			}
		}

		// A finalizer given after the allocation, see d.gc.late.
		if (!(result.attr & BlkAttr.FINALIZE)
			    && threadCache.hasFinalizerAttr(pd, si.address)) {
			result.attr |= BlkAttr.FINALIZE;
		}

		result.size = si.slotCapacity;
	} else {
		// A large block has a used capacity of its own when it was allocated
		// to be appended to; a plain one has all its pages in use.
		if (e.usedCapacity != e.size) {
			result.attr |= BlkAttr.APPENDABLE;
		}

		if (e.finalizer) {
			result.attr |= BlkAttr.FINALIZE;
		}

		result.base = e.address;

		result.size = e.size;
	}

	return result;
}

pragma(mangle, "__sd_gc_hook_realloc")
void* hook_realloc(void* ptr, size_t size, bool containsPointers) {
	return threadCache.realloc(ptr, size, containsPointers);
}

pragma(mangle, "__sd_gc_hook_alloc")
void* hook_alloc(size_t size, bool containsPointers, bool zeroData) {
	return threadCache.alloc(size, containsPointers, zeroData);
}

pragma(mangle, "__sd_gc_hook_alloc_appendable")
void* hook_allocAppendable(size_t size, bool containsPointers, bool zeroData, void* context) {
	return threadCache.allocAppendable(size, containsPointers, zeroData, context);
}

pragma(mangle, "__sd_gc_hook_get_array_capacity")
size_t hook_getArrayCapacity(void[] slice) {
	auto capacity = threadCache.getCapacity(slice.ptr[0 .. slice.length + 1]);
	if (capacity == 0) {
		return 0;
	}

	return capacity - 1;
}

pragma(mangle, "__sd_gc_hook_get_allocation_slice")
void[] hook_getAllocationSlice(const void* ptr) {
	auto slice = threadCache.getAllocationSlice(ptr);
	return slice[0 .. $ > 0 ? $-1 : 0]; // remove padding byte
}

pragma(mangle, "__sd_gc_hook_shrink_array_used")
bool hook_shrinkArrayUsed(void* ptr, size_t newUsed, size_t existingUsed) {
	assert(newUsed <= existingUsed);
	auto pd = threadCache.maybeGetPageDescriptorCached(ptr);
	auto e = pd.extent;
	if (e is null) {
		return false;
	}

	if (pd.isSlab()) {
		import d.gc.slab;
		auto si = SlabAllocInfo(pd, ptr);
		if (!threadCache.validateCapacity(ptr[0 .. existingUsed + 1],
		                                  si.address, si.usedCapacity)) {
			return false;
		}

		auto offset = ptr - si.address;
		return si.setUsedCapacity(newUsed + offset + 1);
	}

	// Large allocation.
	if (!threadCache.validateCapacity(ptr[0 .. existingUsed + 1], e.address,
	                                  e.usedCapacity)) {
		return false;
	}

	auto offset = ptr - e.address;
	e.setUsedCapacity(newUsed + offset + 1);
	return true;
}


pragma(mangle, "__sd_gc_hook_extend_array_used")
bool hook_extendArrayUsed(void* ptr, size_t newUsed, size_t existingUsed) {
	assert(newUsed >= existingUsed);
	return
		threadCache.extend(ptr[0 .. existingUsed + 1], newUsed - existingUsed);
}

pragma(mangle, "__sd_gc_hook_reserve_array_capacity")
bool hook_reserveArrayCapacity(void* ptr, size_t request,
									size_t existingUsed) {
	assert(request >= existingUsed);
	return
		threadCache.reserve(ptr[0 .. existingUsed + 1], request - existingUsed);
}
