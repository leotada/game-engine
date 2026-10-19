module d.gc.tcache;

import d.gc.base;
import d.gc.emap;
import d.gc.ring;
import d.gc.size;
import d.gc.sizeclass;
import d.gc.slab;
import d.gc.spec;
import d.gc.tbin;
import d.gc.util;

import symgc.intrinsics;

enum DefaultEventWait = 65536;

enum ShouldZeroFreeSlabs = true;

alias RNode = Node!ThreadCache;
alias ThreadRing = Ring!ThreadCache;

ThreadCache threadCache;

version(linux) {
	import core.sys.posix.unistd: pid_t;
	extern(C) pid_t gettid();
}

struct ThreadCache {
private:
	size_t allocated;
	size_t nextAllocationEvent;
	size_t deallocated;
	size_t nextDeallocationEvent;

	/**
	 * Slots of the last arrays this thread appended to, so that appending
	 * again skips the extent map lookup and the work to find the slot's
	 * index. Two entries: StringTable and similar alternate `storage ~=`
	 * and `offsets ~=`; a single entry thrashes every time. Good as long
	 * as no slab was freed anywhere since: `appendEpoch` is `gSlabFreeEpoch`.
	 */
	enum AppendCacheCount = 2;
	// Heap-pointing cache tags are stored bitwise-inverted (~cast(size_t) ptr)
	// so conservative TLS root scanning ignores them.
	size_t[AppendCacheCount] appendBaseInv;
	size_t[AppendCacheCount] appendEndInv;
	import d.gc.extent : Extent;
	Extent*[AppendCacheCount] appendExtent;
	uint[AppendCacheCount] appendIndex;
	uint[AppendCacheCount] appendSlotSize;
	uint appendEpoch;
	ubyte appendCacheNext;

	/**
	 * Last page looked up for soft lookups (`GC.extend`, shrink). One entry is
	 * enough there; appendable allocs that cycle size classes use binExtentCache.
	 */
	PageDescriptor pdCachePD;
	size_t pdCachePageInv;

	/**
	 * Per-bin slab-extent cache for appendable small allocs. Paced engine
	 * frames cycle size classes every NPC and multi-page slabs (npages = 2..7)
	 * cross 4 KB page boundaries every few slots; caching the slab Extent*,
	 * inverted base address, and slab byte span hits across the entire slab.
	 */
	Extent*[ThreadBinCount] binExtentCache;
	size_t[ThreadBinCount] binBaseInvCache;
	uint[ThreadBinCount] binSlabBytesCache;

	/**
	 * Last two large appendable extents this thread grew with `~=`. StringTable
	 * alternates `storage ~= s` and `offsets ~= ...` past MaxSmallSize and
	 * would otherwise emap-lookup every append.
	 */
	size_t[AppendCacheCount] appendLargeBaseInv;
	Extent*[AppendCacheCount] appendLargeExtent;
	uint[AppendCacheCount] appendLargePages;
	ubyte appendLargeCacheNext;

	/**
	 * BlkInfo for the allocation this thread just made. `GC.qalloc` (Appender,
	 * format) re-queries the block; the emap + metadata bit dominate that path
	 * on small heaps. Valid only until the next alloc/free on this thread.
	 */
	size_t lastBlkPtrInv;
	size_t lastBlkSize;
	uint lastBlkAttr;

	package CachedExtentMap emap;

	/**
	 * The bins themselves.
	 *
	 * The thread cache allocates numerous slots that it stores
	 * in bins. This ensures most allocation can be served from
	 * bins directly without requiring any kind of lock.
	 *
	 * This also ensure that, when we take the locks, we amortize
	 * the cost of doing over numerous allocations.
	 */
	ThreadBin[ThreadBinCount] bins;
	void*[ThreadCacheSize] binBuffer;

	/**
	 * Section for fields that are unused for "regular" operations.
	 *
	 * These fields are only necessary for infrequent operation, so we
	 * segregate them in order to get better locality on the frequently
	 * used ones.
	 */
	uint associatedArena;

	import d.gc.tstate;
	package ThreadState state;

	import symgc.thread;
	package ThreadId self;
	version(Windows) {
		import core.sys.windows.winbase;
 		private ThreadHandle suspendHandle = INVALID_HANDLE_VALUE;
	}
	version(linux) {
		import core.sys.posix.sys.types;
		package pid_t tid;
	}

	RNode rnode;

	package void* stackBottom;
	package void* stackTop;
	package const(void*)[][] tlsSegments;

	/**
	 * Tracks GC runs.
	 */
	size_t nextGCRun;
	bool enableGC;
	bool runningFinalization;
	bool isScanningThread;

	int nextGCRunClassOffset;
	uint consecutiveSuccessfulGCRuns;
	uint consecutiveFailedGCRuns;

	/**
	 * Bin stats and recycling mechanism.
	 */
	static assert(ThreadBinCount < ubyte.max, "Too many thread bin!");
	ubyte nextBinToRecycle;
	ulong lastRecycleTime;

	ThreadBinState[ThreadBinCount] binStates;

	version(Windows) {
		import d.sync.waiter;
		shared(Waiter)* waiter;
	}

public:
	bool isInitialized() {
		return nextAllocationEvent > 0;
	}

	bool ensureThreadCacheIsInitialized() {
		if (likely(isInitialized())) {
			return false;
		}

		initialize(&gExtentMap, &gBase);
		return true;
	}

	void setIsScanningThread() {
		isScanningThread = true;
	}

	size_t totalCachedAllocationSize() {
		// Note, this is called from outside the thread, but we don't care too much
		// about exactness, because it's data that can be rapidly changing anyway.
		size_t cachedSize = 0;
		foreach(idx, ref bin; bins) {
			// lower bit is whether it contains pointers or not. Upper bits are size class.
			auto slotSize = binInfos[idx / 2].slotSize;
			cachedSize += bin.numCached * slotSize;
		}
		return cachedSize;
	}

	@property
	auto suspendState() => state.suspendState;

	auto sendSuspendSignal() => state.sendSuspendSignal();

	auto sendResumeSignal() => state.sendResumeSignal();

	auto onResumeSignal() => state.onResumeSignal();

	auto onSuspendSignal() => state.onSuspendSignal();

	auto markSuspended() => state.markSuspended();

	auto clearProbationState() => state.clearProbationState();

	ulong allocatedInThread() nothrow @nogc => allocated;

	version(Windows) {
		void checkLockWaiting() {
			// If there is a waiter registered, check if it's busy. If it's busy, then we are going to do a weird busy state switcheroo.
			if(waiter is null) {
				return;
			}

			// If the waiter says that it is in the middle of a wait, then we can't leave the thread suspended. On resuming the world, this thread should be resuspended so the call to resume will be valid.
			if(waiter.setGCBusy()) {
				// TODO: maybe it would be nice to be able to get this handle from Thread itself.
				import core.sys.windows.winbase;
				import core.sys.windows.winnt;
				// need to convert thread id into a handle, and then suspend it.
				suspendHandle = OpenThread(THREAD_ALL_ACCESS, false, this.self);
				assert(suspendHandle != INVALID_HANDLE_VALUE);
				ResumeThread(suspendHandle);
			}
		}

		void resolveLockWaiting() {
			if(waiter is null) {
				return;
			}
			import core.sys.windows.winbase;
			import core.sys.windows.winnt;
			waiter.clearGCBusy();
			if (suspendHandle != INVALID_HANDLE_VALUE) {
				import core.sys.windows.winbase;
				auto ret = SuspendThread(suspendHandle);
				assert(ret != 0xFFFFFFFF, "Unable to resuspend thread!");
				CloseHandle(suspendHandle);
				suspendHandle = INVALID_HANDLE_VALUE;
			}
		}
	}

	void initialize(shared(ExtentMap)* emap, shared(Base)* base) {
		this.emap = CachedExtentMap(emap, base);

		// Make sure initialize can be called multiple
		// times on the same thread cache.
		if (isInitialized()) {
			assert(self == currentThreadId(), "Invalid current thread handle!");
			return;
		}

		self = currentThreadId();

		/**
		 * You'd think linux would provide a way to get the tid from
		 * a pthread_t, and if, so, you'd be wrong! So we need to cache it.
		 */
		//import core.sys.linux.unistd;
		// NOTE: not included in druntime so we have to define it locally
		version(linux) tid = gettid();

		nextAllocationEvent = DefaultEventWait;
		nextDeallocationEvent = DefaultEventWait;
		nextGCRun = DefaultEventWait;

		uint sp = 0;
		uint i = 0;

		foreach (s; 0 .. BinCount) {
			auto capacity = computeThreadBinCapacity(s);

			bins[sp++] = ThreadBin(binBuffer[i .. i + capacity]);
			i += capacity;

			bins[sp++] = ThreadBin(binBuffer[i .. i + capacity]);
			i += capacity;
		}

		// The thread cache will default to arena zero.
		// In order to avoid this, we force the thread to
		// pick an arena at initialization time.
		reassociateArena(true);

		version(Windows) {
			// hack to avoid pausing on WaitOnAddress.
			import d.sync.mutex;
			this.waiter = Mutex.getWaiterAddress();
		}

		// Because this may allocate, we do it last.
		import symgc.rt;
		stackBottom = getStackBottom();
	}

	bool activateGC(bool activated = true) nothrow @nogc {
		scope(exit) enableGC = activated;
		return enableGC;
	}

	package void startCollection() {
		runningFinalization = true;
	}

	package void endCollection() {
		runningFinalization = false;
	}

	// Is the current code being run from a finalizer?
	@property bool inFinalizer() @safe @nogc nothrow => runningFinalization;

	void destroyThread() {
		state.enterBusyState();
		scope(exit) state.exitBusyState();

		free(tlsSegments.ptr);
		tlsSegments = [];

		// A thread's SATB entries must not die with it (model: exitnoflush).
		import d.gc.satb;
		satbFlushThread();

		flush();
	}

	pragma(inline, true)
	void* alloc(size_t size, bool containsPointers, bool zero,
	            size_t* outSize = null, uint* outAttr = null) {
		if (!isAllocatableSize(size)) {
			return null;
		}

		if (isSmallSize(size)) {
			return allocSmall(size, containsPointers, zero, outSize, outAttr);
		}

		auto pages = getPageCount(size);
		return allocLarge(pages, containsPointers, zero, outSize, outAttr);
	}

	pragma(inline, true)
	void* allocAppendable(size_t size, bool containsPointers, bool zero,
	                      Finalizer finalizer = null, size_t capacity = 0,
	                      size_t* outSize = null, uint* outAttr = null) {
		// Reserve bytes for the finalizer if needed.
		capacity = max(capacity, size);
		auto asize = capacity + (finalizer !is null) * PointerSize;
		if (!isAllocatableSize(asize)) {
			return null;
		}

		asize = max(asize, 2 * Quantum);
		// No 64B floor here: SnazzyGC.qalloc floors Appender/format; per-bin
		// slab cache absorbs size-class churn; short .idup keeps a tight slot.

		assert(sizeClassSupportsMetadata(getSizeClass(asize)),
		       "allocAppendable got size class without metadata support!");

		if (isSmallSize(asize)) {
			import d.gc.slab;
			auto sc = getSizeClass(asize);
			auto slotSize = binInfos[sc].slotSize;
			auto ptr = allocSmallForAppendable(sc, slotSize, containsPointers,
			                                   zero, asize);
			if (unlikely(ptr is null)) {
				return null;
			}

			// Fresh slot: ptr is the slot base; per-bin slab cache hits across
			// all pages of a single- or multi-page slab.
			auto binIndex = getBinIndex(sc, containsPointers);
			auto e = binExtentCache[binIndex];
			size_t offset = (cast(size_t) ptr) - (~binBaseInvCache[binIndex]);
			if (unlikely(e is null || offset >= binSlabBytesCache[binIndex])) {
				e = cacheBinSlabExtent(binIndex, sc, ptr);
				offset = (cast(size_t) ptr) - (~binBaseInvCache[binIndex]);
			}
			auto index = binInfos[sc].computeIndex(offset);
			writeNewSlotMetadata(e, index, slotSize, ptr, finalizer, size);
			// BlkAttr bits (core.memory): APPENDABLE=8, NO_SCAN=2, FINALIZE=1.
			uint attr = 0b1000;
			if (!containsPointers) {
				attr |= 0b0010;
			}
			if (finalizer !is null) {
				attr |= 0b0001;
			}
			auto blkSize = slotSize - (finalizer !is null ? PointerSize : 0);
			if (outSize !is null) {
				*outSize = blkSize;
				*outAttr = attr;
			}
			return ptr;
		}

		auto pages = getPageCount(capacity);
		auto e = allocLargeExtent(pages, containsPointers, zero);
		if (unlikely(e is null)) {
			return null;
		}

		e.setUsedCapacity(size);
		e.setFinalizer(finalizer);
		uint attr = 0b1000;
		if (!containsPointers) {
			attr |= 0b0010;
		}
		if (finalizer !is null) {
			attr |= 0b0001;
		}
		if (outSize !is null) {
			*outSize = e.size;
			*outAttr = attr;
		}
		return e.address;
	}

	void free(void* ptr) {
		if (ptr is null) {
			return;
		}

		// Like the other collectors, ignore what we did not hand out: a
		// pointer to the stack, to malloc'd memory, or into the middle of a
		// block.
		auto pd = maybeGetPageDescriptor(ptr);
		if (!isBlockStart(pd, ptr)) {
			return;
		}

		free(pd, ptr);
	}

	/**
	 * Whether `ptr` is the first byte of an allocation of ours.
	 */
	bool isBlockStart(PageDescriptor pd, const void* ptr) {
		if (pd.extent is null) {
			return false;
		}

		if (pd.isSlab()) {
			return SlabAllocInfo(pd, ptr).address is ptr;
		}

		return ptr is pd.extent.address;
	}

	void free(PageDescriptor pd, void* ptr) {
		/**
		 * `-version=Symgc_check_free`: stop at the call that frees a slot
		 * twice (the second free of a slot in a thread's cache, or of a slot
		 * the slab already got back), where the stack trace tells who frees
		 * it. Without it the double free shows only when the cache is flushed.
		 */
		version(Symgc_check_free) {
			if (pd.isSlab()) {
				assert(!isFreeInCache(pd, ptr),
				       "Double free: the slot is free in this thread's cache!");
				assert(pd.extent.slabData.valueAt(SlabEntry(pd, ptr).index),
				       "Double free: the slot is free in its slab!");
			}
		}

		shadeReleasedBlock(pd, ptr);

		if (likely(pd.isSlab())) {
			// A finalizer given after the allocation dies with the slot.
			if (unlikely(pd.extent.hasFinalizers)) {
				import d.gc.late;
				lateRemove(ptr);
			}

			freeSmall(pd, ptr);
		} else {
			freeLarge(pd);
		}
	}

	void destroy(void* ptr) {
		if (ptr is null) {
			return;
		}

		auto pd = getPageDescriptor(ptr);
		auto e = pd.extent;

		if (likely(pd.isSlab())) {
			auto si = SlabAllocInfo(pd, ptr);
			auto finalizer = si.finalizer;
			if (finalizer !is null) {
				assert(cast(void*) si.address == ptr,
				       "destroy() was invoked on an interior pointer!");

				import d.gc.hooks;
				__sd_gc_finalize(ptr, si.usedCapacity, finalizer);
			} else if (unlikely(e.hasFinalizers)) {
				// A finalizer given after the allocation, see d.gc.late.
				import d.gc.late, d.gc.hooks;
				if (lateRemove(ptr)) {
					__sd_gc_finalize_late(ptr);
				}
			}

			shadeReleasedBlock(pd, ptr);
			freeSmall(pd, ptr);
		} else {
			if (e.finalizer !is null) {
				import d.gc.hooks;
				__sd_gc_finalize(ptr, e.usedCapacity, e.finalizer);
			}

			shadeReleasedBlock(pd, ptr);
			freeLarge(pd);
		}
	}

	/**
	 * `GC.setAttr(ptr, FINALIZE)`: the block is a class instance to finalize
	 * when it dies (`finalizer` is what an allocation with FINALIZE stores for
	 * one). A slab slot has no room for the pointer, so it goes in the table
	 * of `d.gc.late`. Returns whether the block now has a finalizer.
	 */
	bool setFinalizerAttr(void* ptr, void* finalizer) {
		auto pd = maybeGetPageDescriptor(ptr);
		if (!isBlockStart(pd, ptr)) {
			return false;
		}

		auto e = pd.extent;
		if (!pd.isSlab()) {
			if (e.finalizer is null) {
				e.setFinalizer(finalizer);
			}

			return true;
		}

		auto si = SlabAllocInfo(pd, ptr);
		if (si.finalizer !is null) {
			return true;
		}

		if (!pd.extentClass.supportsMetadata) {
			return false;
		}

		import d.gc.late;
		if (!lateAdd(ptr)) {
			return false;
		}

		e.setHasFinalizers();
		return true;
	}

	/**
	 * `GC.clrAttr(ptr, FINALIZE)`: the block is not finalized when it dies.
	 */
	void clearFinalizerAttr(void* ptr) {
		auto pd = maybeGetPageDescriptor(ptr);
		if (!isBlockStart(pd, ptr)) {
			return;
		}

		auto e = pd.extent;
		if (!pd.isSlab()) {
			e.setFinalizer(null);
			return;
		}

		import d.gc.late;
		if (lateRemove(ptr)) {
			return;
		}

		auto si = SlabAllocInfo(pd, ptr);
		if (si.finalizer !is null) {
			SlotMetadata.fromBlock(si.address, binInfos[pd.extentClass.sizeClass].slotSize).clearFinalizer();
		}
	}

	/**
	 * Whether the slot is free in this thread's cache: allocated as far as
	 * the slab knows, but not in use (never handed out, or freed by this
	 * thread). The slots of other threads' caches cannot be seen from here.
	 */
	bool isFreeInCache(PageDescriptor pd, const void* slot) {
		auto bin = &bins[getBinIndex(pd.extentClass.sizeClass, pd.containsPointers)];
		return bin.holds(slot);
	}

	/**
	 * Whether the block has a finalizer, for `GC.getAttr`.
	 */
	bool hasFinalizerAttr(PageDescriptor pd, void* base) {
		if (!pd.isSlab() || !pd.extent.hasFinalizers) {
			return false;
		}

		import d.gc.late;
		return lateContains(base);
	}

	/**
	 * Releasing a block deletes every pointer it holds. While a concurrent
	 * mark is running, the targets have to be logged, or a mutator that
	 * loaded one of them from this block beforehand can be left holding an
	 * object that is swept (plans/audit/druntime_edge_deletions.md, items 1-4).
	 */
	void shadeReleasedBlock(PageDescriptor pd, void* ptr) {
		import d.gc.satb;
		if (likely(!satbMarking()) || !pd.containsPointers) {
			return;
		}

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, ptr);
			satbShadeRange(si.address, binInfos[pd.extentClass.sizeClass].slotSize);
		} else {
			auto e = pd.extent;
			satbShadeRange(e.address, e.size);
		}
	}

	void* realloc(void* ptr, size_t size, bool containsPointers) {
		if (size == 0) {
			free(ptr);
			return null;
		}

		if (!isAllocatableSize(size)) {
			return null;
		}

		if (ptr is null) {
			return alloc(size, containsPointers, false);
		}

		// Not ours, or not the start of a block: the other collectors
		// refuse these, and so do we.
		auto pd = maybeGetPageDescriptor(ptr);
		if (!isBlockStart(pd, ptr)) {
			return null;
		}

		auto copySize = size;

		auto ec = pd.extentClass;
		auto samePointerness = containsPointers == pd.containsPointers;

		// Whether the block has a used capacity of its own, which a plain block
		// does not: a large one then has all its pages used. Resizing must not
		// turn a plain block into an appendable one (see `hook_fetchAllocInfo`).
		bool appendable = false;
		Finalizer oldFinalizer = null;
		size_t oldUsedCapacity = 0;
		if (ec.isSlab()) {
			auto si0 = SlabAllocInfo(pd, ptr);
			appendable = si0.hasMetadata;
			if (appendable) {
				oldFinalizer = si0.finalizer;
				oldUsedCapacity = si0.usedCapacity;
			}
		} else {
			oldUsedCapacity = pd.extent.usedCapacity;
			appendable = oldUsedCapacity != pd.extent.size;
			if (appendable) {
				oldFinalizer = pd.extent.finalizer;
			}
		}

		if (ec.isSlab()) {
			auto newSizeClass = getSizeClass(size);
			auto oldSizeClass = ec.sizeClass;

			if (samePointerness && newSizeClass == oldSizeClass) {
				if (!ec.supportsMetadata) {
					return ptr;
				}

				auto si = SlabAllocInfo(pd, ptr);

				// A plain block has no used capacity to update, and must not
				// become appendable (GC.getAttr would tell).
				bool isAppendCached = false;
				auto ptrInv = ~cast(size_t) ptr;
				foreach (bInv; appendBaseInv[]) {
					if (ptrInv == bInv) {
						isAppendCached = true;
						break;
					}
				}

				if (!si.hasMetadata && !isAppendCached) {
					return ptr;
				}

				if (si.setUsedCapacity(size)) {
					return ptr;
				}
			}

			if (newSizeClass > oldSizeClass) {
				copySize = getSizeFromClass(oldSizeClass);
			}
		} else {
			auto e = pd.extent;
			if (samePointerness && size > MaxSmallSize) {
				auto epages = e.npages;
				auto npages = getPageCount(size);

				if (epages < npages) {
					if (!growLarge(e, npages)) {
						goto LargeResizeFailed;
					}

					triggerAllocationEvent((npages - epages) * PageSize);
				} else if (epages > npages) {
					// The released tail deletes the pointers it holds.
					import d.gc.satb;
					if (unlikely(satbMarking()) && pd.containsPointers) {
						satbShadeRange(e.address + npages * PageSize,
						               (epages - npages) * PageSize);
					}

					if (!shrinkLarge(pd, npages)) {
						goto LargeResizeFailed;
					}

					triggerDeallocationEvent((epages - npages) * PageSize);
				}

				e.setUsedCapacity(appendable ? size : e.size);
				return ptr;
			}

		LargeResizeFailed:
			copySize = min(size, e.usedCapacity);
		}

		void* newPtr = alloc(size, containsPointers, false);
		if (newPtr is null) {
			return null;
		}

		import core.stdc.string : memcpy;
		memcpy(newPtr, ptr, copySize);
		free(pd, ptr);

		return newPtr;
	}

	void flush() {
		state.enterBusyState();
		scope(exit) state.exitBusyState();

		foreach (ref b; bins) {
			b.fullFlush(emap);
		}

		pdCachePageInv = 0;
		pdCachePD = PageDescriptor.init;
		binExtentCache[] = null;
		binBaseInvCache[] = 0;
		binSlabBytesCache[] = 0;
		appendBaseInv[] = 0;
		appendEndInv[] = 0;
		appendExtent[] = null;
		lastBlkPtrInv = 0;
		clearAppendLargeCache();
	}

private:
	/**
	 * Small allocations.
	 */
	pragma(inline, true)
	void* allocSmall(size_t size, bool containsPointers, bool zero,
	                 size_t* outSize = null, uint* outAttr = null) {
		// TODO: in contracts
		assert(isSmallSize(size));

		import d.gc.slab;
		auto sizeClass = getSizeClass(size);
		return allocSmallInClass(sizeClass, containsPointers, zero, size,
		                         outSize, outAttr);
	}

	pragma(inline, true)
	void* allocSmallInClass(ubyte sizeClass, bool containsPointers, bool zero,
	                        size_t clearSize = size_t.max,
	                        size_t* outSize = null, uint* outAttr = null) {
		auto ptr = allocSmallSlot(sizeClass, containsPointers, zero, clearSize);
		if (unlikely(ptr is null)) {
			return null;
		}

		if (outSize !is null) {
			import d.gc.slab;
			*outSize = binInfos[sizeClass].slotSize;
			*outAttr = containsPointers ? 0 : 0b0010;
		}
		return ptr;
	}

	/**
	 * Small alloc for appendable: same as allocSmallInClass but leaves BlkInfo
	 * recording to the caller (which sets APPENDABLE / FINALIZE bits once).
	 */
	pragma(inline, true)
	void* allocSmallForAppendable(ubyte sizeClass, uint slotSize,
	                              bool containsPointers, bool zero,
	                              size_t clearSize) {
		assert(slotSize == binInfos[sizeClass].slotSize, "Invalid slot size!");
		return allocSmallSlot(sizeClass, containsPointers, zero, clearSize);
	}

	pragma(inline, true)
	void* allocSmallSlot(ubyte sizeClass, bool containsPointers, bool zero,
	                     size_t clearSize) {
		import d.gc.slab;
		auto slotSize = binInfos[sizeClass].slotSize;
		if (clearSize == size_t.max || clearSize > slotSize) {
			clearSize = slotSize;
		}

		bool wasZeroed;
		auto ptr = allocSmallBin(sizeClass, slotSize, containsPointers, wasZeroed);
		if (unlikely(ptr is null)) {
			return null;
		}

		version(Symgc_verify) {
			import d.gc.verify;
			checkSlotOnAlloc(ptr, clearSize, slotSize);
		}

		import core.stdc.string : memset;
		// Pointer bins memset on free; skip a second full clear when we can.
		if (unlikely(zero)) {
			if (!wasZeroed) {
				memset(ptr, 0, slotSize);
			}
		} else if (containsPointers && !wasZeroed) {
			memset(ptr + clearSize, 0, slotSize - clearSize);
		}

		triggerAllocationEvent(slotSize);
		return ptr;
	}

	pragma(inline, true)
	static uint getBinIndex(ubyte sizeClass, bool containsPointers) nothrow @nogc {
		return 2 * sizeClass | containsPointers;
	}

	pragma(inline, true)
	void* allocSmallBin(ubyte sizeClass, uint slotSize, bool containsPointers,
	                    ref bool wasZeroed) {
		assert(slotSize == binInfos[sizeClass].slotSize, "Invalid slot size!");
		assert(!isScanningThread, "Trying to free while in scanning thread!");

		auto index = getBinIndex(sizeClass, containsPointers);
		void* ptr;
		if (likely(bins[index].allocate(ptr, wasZeroed))) {
			return ptr;
		}

		return allocSmallBinSlow(sizeClass, slotSize, containsPointers, index,
		                         wasZeroed);
	}

	void* allocSmallBinSlow(ubyte sizeClass, uint slotSize,
	                        bool containsPointers, uint index,
	                        ref bool wasZeroed) {
		ensureThreadCacheIsInitialized();
		auto bin = &bins[index];

		void* ptr;
		if (bin.allocate(ptr, wasZeroed)) {
			return ptr;
		}

		wasZeroed = false;

		// The slow path: time lost to memory management.
		import d.gc.gctime;
		auto gcTimer = GcTimer.begin(GcTimeKind.Alloc);
		scope(exit) gcTimer.end();

		// We are about to allocate, make room for it if needed.
		version(Symgc_phase_trace) {
			import d.gc.time;
			auto tG0 = getMonotonicTime();
		}

		auto ranCycle = maybeRunGCCycle();

		version(Symgc_phase_trace) {
			auto dtG = getMonotonicTime() - tG0;
			if (dtG > 3000) { // 300 us
				import core.stdc.stdio : fprintf, stderr;
				fprintf(stderr, "slowmaybegc ran=%d %.0f us\n", cast(int) ranCycle, dtG / 10.0);
			}
		}

		if (ranCycle) {
			// The bin might have gained a pointer through a
			// finalizer.
			if (bin.allocate(ptr, wasZeroed)) {
				return ptr;
			}
		}

		// The bin is empty, refill.
		{
			version(Symgc_phase_trace) {
				import d.gc.time;
				auto tR0 = getMonotonicTime();
				scope(exit) {
					auto dt = getMonotonicTime() - tR0;
					if (dt > 5000) { // 500 us
						import core.stdc.stdio : fprintf, stderr;
						fprintf(stderr, "slowrefill class=%d %.0f us\n", cast(int) sizeClass, dt / 10.0);
					}
				}
			}

			state.enterBusyState();
			scope(exit) state.exitBusyState();

			auto arena = chooseArena(containsPointers);
			bin.refill(emap, arena, binStates[index], sizeClass, slotSize);
		}

		wasZeroed = false;
		if (bin.allocateEasy(ptr)) {
			return ptr;
		}

		return null;
	}

	void freeSmall(PageDescriptor pd, void* ptr) {
		assert(pd.isSlab(), "Slab expected!");
		assert(!isScanningThread, "Trying to allocate while in scanning thread!");


		auto ec = pd.extentClass;
		auto sc = ec.sizeClass;

		// We trigger the de-allocation event first as it might
		// recycle the bin we are interested in, which increase
		// our chances that free works.
		auto slotSize = binInfos[sc].slotSize;
		triggerDeallocationEvent(slotSize);

		// If the allocation contains pointers, zero it before freeing it
		const zeroedOnFree = ShouldZeroFreeSlabs && pd.containsPointers;
		if (zeroedOnFree) {
			import core.stdc.string : memset;
			memset(ptr, 0, slotSize);
		}

		version(Symgc_verify) {
			import d.gc.verify;
			poisonSlot(ptr, slotSize);
		}

		/**
		 * If the allocation has metadata, we need to clear that flag.
		 * Note: we do this on free and not alloc because explicit
		 * freeing is not common in a GC language. The danger situation
		 * we avoid is:
		 * 1. allocate slab slot with metadata
		 * 2. explicitly free slot, do not clear metadata flag
		 * 3. reallocate slot without expecting metadata
		 * 4. Overwrite slot metadata with inadvertent finalizer bit
		 * 5. GC frees slot, tries to call finalizer that is garbage.
		 *    Segfault or even attack vector.
		 *
		 * This clearing of the bit is slightly expensive, definitely
		 * more expensive than not accessing the extent at all. But the
		 * alternative is worse!
		 */
		if (ec.supportsMetadata) {
			auto e = pd.extent;
			auto se = SlabEntry(pd, ptr);
			auto index = se.index;
			e.disableMetadata(index);
		}

		auto index = getBinIndex(sc, pd.containsPointers);
		auto bin = &bins[index];
		if (likely(zeroedOnFree ? bin.freeZeroed(ptr) : bin.free(ptr))) {
			return;
		}

		// The bin is full, make space.
		{
			state.enterBusyState();
			scope(exit) state.exitBusyState();

			bin.flushToFree(emap, binStates[index]);
		}

		auto success = zeroedOnFree ? bin.freeZeroed(ptr) : bin.free(ptr);
		assert(success, "Unable to free!");
	}

	/**
	 * Large allocations.
	 */
	void* allocLarge(uint pages, bool containsPointers, bool zero,
	                 size_t* outSize = null, uint* outAttr = null) {
		auto e = allocLargeExtent(pages, containsPointers, zero);
		if (unlikely(e is null)) {
			return null;
		}
		if (outSize !is null) {
			*outSize = pages * PageSize;
			*outAttr = containsPointers ? 0 : 0b0010;
		}
		return e.address;
	}

	/**
	 * Same as allocLarge, but keeps the Extent* so appendable metadata can be
	 * written without a second emap lookup.
	 */
	Extent* allocLargeExtent(uint pages, bool containsPointers, bool zero) {
		assert(!isScanningThread, "Trying to allocate while in scanning thread!");
		ensureThreadCacheIsInitialized();

		auto nbytes = pages * PageSize;
		if (unlikely(allocated + nbytes >= nextGCRun) && enableGC && !state.busy) {
			maybeRunGCCycleAt(allocated + nbytes);
		}

		Extent* e;

		{
			state.enterBusyState();
			scope(exit) state.exitBusyState();

			auto arena = chooseArena(containsPointers);
			e = arena.allocLarge(emap, pages, zero);
		}

		if (unlikely(e is null)) {
			return null;
		}

		triggerAllocationEvent(nbytes);
		return e;
	}

	pragma(inline, true)
	void noteLastBlk(void* ptr, size_t blkSize, uint attr) nothrow @nogc {
		lastBlkPtrInv = ~cast(size_t) ptr;
		lastBlkSize = blkSize;
		lastBlkAttr = attr;
	}

public:
	/**
	 * If `ptr` is the block this thread just allocated, return its BlkInfo
	 * without an emap lookup. Clears the hit so a later free cannot observe it.
	 */
	pragma(inline, true)
	bool consumeLastBlk(void* ptr, ref size_t blkSize, ref uint attr) nothrow @nogc {
		if (ptr is null || (~cast(size_t) ptr) != lastBlkPtrInv) {
			return false;
		}

		blkSize = lastBlkSize;
		attr = lastBlkAttr;
		lastBlkPtrInv = 0;
		return true;
	}

private:
	void freeLarge(PageDescriptor pd) {
		assert(!pd.isSlab(), "Slab are not supported!");
		assert(!isScanningThread, "Trying to free while in scanning thread!");

		auto e = pd.extent;
		auto npages = e.npages;
		foreach (i; 0 .. AppendCacheCount) {
			if (e is appendLargeExtent[i]) {
				clearAppendLargeCache();
				break;
			}
		}

		{
			state.enterBusyState();
			scope(exit) state.exitBusyState();

			pd.arena.freeLarge(emap, e);
		}

		triggerDeallocationEvent(npages * PageSize);
	}

	/**
	 * Bytes accounting and bin maintenance.
	 */
	pragma(inline, true)
	void triggerAllocationEvent(size_t bytes) {
		allocated += bytes;

		if (unlikely(allocated >= nextAllocationEvent)) {
			triggerAllocationEventSlow();
		}
	}

	void triggerAllocationEventSlow() {
		reassociateArena();
		recycleBins();
		nextAllocationEvent = allocated + DefaultEventWait;
	}

	void triggerDeallocationEvent(size_t bytes) {
		deallocated += bytes;

		if (deallocated >= nextDeallocationEvent) {
			recycleBins();

			nextDeallocationEvent = deallocated + DefaultEventWait;
		}
	}

	void recycleBins() {
		import d.gc.time;
		enum RecycleInterval = 10 * Millisecond;

		auto now = getMonotonicTime();
		assert(now >= lastRecycleTime, "Expected monotonic time!");

		if ((now - lastRecycleTime) < RecycleInterval) {
			// We only trigger recycling every 10ms.
			return;
		}
		lastRecycleTime = now;

		state.enterBusyState();
		scope(exit) state.exitBusyState();

		// Flush at most MaxFlush thread bins.
		enum MaxFlush = ThreadBinCount / 8;
		uint nflushed = 0;

		auto index = nextBinToRecycle;
		for (uint i = 0; i < ThreadBinCount && nflushed < MaxFlush; i++) {
			ubyte sizeClass = index / 2;
			if (bins[index].recycle(emap, binStates[index], sizeClass)) {
				nflushed++;
			}

			index++;
			if (index >= ThreadBinCount) {
				index = 0;
			}
		}

		nextBinToRecycle = index;
	}

	/**
	 * Appendable facilities.
	 */
	public size_t getCapacity(const void[] slice) {
		auto pd = maybeGetPageDescriptor(slice.ptr);
		auto e = pd.extent;
		if (e is null) {
			return 0;
		}

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, slice.ptr);

			if (!validateCapacity(slice, si.address, si.usedCapacity)) {
				return 0;
			}

			auto startIndex = slice.ptr - si.address;
			return si.slotCapacity - startIndex;
		}

		if (!validateCapacity(slice, e.address, e.usedCapacity)) {
			return 0;
		}

		auto startIndex = slice.ptr - e.address;
		return e.size - startIndex;
	}

	public void[] getAllocationSlice(const void* ptr) {
		auto pd = maybeGetPageDescriptor(ptr);
		auto e = pd.extent;
		if (e is null) {
			return [];
		}

		void* base;
		size_t size;

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, ptr);
			base = si.address;
			size = si.usedCapacity;
		} else {
			base = e.address;
			size = e.usedCapacity;
		}

		if (ptr >= base + size) {
			return [];
		}

		return base[0 .. size];
	}

	public bool extend(const void[] slice, size_t size) {
		return resize!true(slice, size);
	}

	public bool reserve(const void[] slice, size_t size) {
		return resize!false(slice, size);
	}

	/**
	 * GC facilities
	 */
	bool maybeRunGCCycle() {
		// If the GC is disabled or we have not reached the point
		// at which we try to collect, move on.
		if (likely(allocated < nextGCRun) || !enableGC) {
			return false;
		}

		// Do not run GC cycles when we are busy as another thread
		// might be trying to run its own GC cycle and waiting on us.
		if (state.busy) {
			return false;
		}

		return maybeRunGCCycleAt(allocated);
	}

	bool maybeRunGCCycleAt(size_t currentAllocated) {
		nextGCRun = currentAllocated + BlockSize;

		import d.gc.gctime;
		auto gcTimer = GcTimer.begin(GcTimeKind.Collect);
		scope(exit) gcTimer.end();

		import d.gc.collector;
		auto collector = Collector(&this);

		// If a sweep is running and the heap is running away, help it.
		collector.assistSweep();

		return collector.maybeRunGCCycle();
	}

	/**
	 * TLS registration.
	 */
	package void addTLSSegment(const void[] range) {
		auto ptr = cast(void*) tlsSegments.ptr;
		auto index = tlsSegments.length;
		auto length = index + 1;

		// We realloc every time. It doesn't really matter at this point.
		ptr = realloc(ptr, length * void*[].sizeof, true);
		tlsSegments = (cast(const(void*)[]*) ptr)[0 .. length];

		import d.gc.range;
		tlsSegments[index] = makeRange(range);
	}

private:
	/**
	 * Appendable's mechanics:
	 *
	 *  __data__  _____free space_______
	 * /        \/                      \
	 * -----sss s....... ....... ........
	 *      \___________________________/
	 * 	           Capacity is 27
	 *
	 * If the slice's end doesn't match the used capacity,
	 * then we return 0 in order to force a reallocation
	 * when appending:
	 *
	 *  ___data____  ____free space_____
	 * /           \/                   \
	 * -----sss s---.... ....... ........
	 *      \___________________________/
	 * 	           Capacity is 0
	 *
	 * See also: https://dlang.org/spec/arrays.html#capacity-reserve
	 */
	public bool validateCapacity(const void[] slice, const void* address,
	                      size_t usedCapacity) {
		// Slice must not end before valid data ends, or capacity is zero.
		// To be appendable, the slice end must match the alloc's used
		// capacity, and the latter may not be zero.
		auto startIndex = slice.ptr - address;
		auto stopIndex = startIndex + slice.length;

		return stopIndex != 0 && stopIndex == usedCapacity;
	}

	bool resize(bool AdjustUsedCapacity)(const void[] slice, size_t size) {
		if (size == 0) {
			return true;
		}

		import d.gc.page : gSlabFreeEpoch;
		import d.sync.atomic : MemoryOrder;
		auto epoch = gSlabFreeEpoch.load!(MemoryOrder.Relaxed)();

		// Appending to a slot we appended to recently (2-way, for alternating ~=).
		auto slicePtr = cast(size_t) slice.ptr;
		if (appendEpoch == epoch) {
			foreach (i; 0 .. AppendCacheCount) {
				auto baseAddr = ~appendBaseInv[i];
				auto endAddr = ~appendEndInv[i];
				if (slicePtr >= baseAddr && slicePtr < endAddr
					    && appendExtent[i] !is null) {
					auto si = SlabAllocInfo(appendExtent[i], appendIndex[i],
					                        appendSlotSize[i],
					                        cast(void*) baseAddr);
					return resizeSlab!AdjustUsedCapacity(si, slice, size);
				}
			}
		}

		// Large appendable: same idea, skip the emap walk on the hot ~= path.
		if (appendEpoch == epoch) {
			foreach (i; 0 .. AppendCacheCount) {
				auto le = appendLargeExtent[i];
				auto largeBase = ~appendLargeBaseInv[i];
				if (le !is null && slicePtr >= largeBase
					    && slicePtr < largeBase
					                    + (cast(size_t) appendLargePages[i]) * PageSize) {
					return resizeLarge!AdjustUsedCapacity(le, i, slice, size);
				}
			}
		}

		auto pd = maybeGetPageDescriptor(slice.ptr);
		auto e = pd.extent;
		if (e is null) {
			return false;
		}

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, slice.ptr);
			if (si.metadataSupported) {
				auto i = appendCacheNext++ % AppendCacheCount;
				appendBaseInv[i] = ~cast(size_t) si.address;
				appendEndInv[i] = ~cast(size_t) (si.address + si.slotBytes);
				appendExtent[i] = si.slabExtent;
				appendIndex[i] = si.slotIndex;
				appendSlotSize[i] = si.slotBytes;
				appendEpoch = epoch;
			}

			return resizeSlab!AdjustUsedCapacity(si, slice, size);
		}

		auto li = appendLargeCacheNext++ % AppendCacheCount;
		appendLargeBaseInv[li] = ~cast(size_t) e.address;
		appendLargeExtent[li] = e;
		appendLargePages[li] = e.npages;
		appendEpoch = epoch;
		return resizeLarge!AdjustUsedCapacity(e, li, slice, size);
	}

	bool resizeLarge(bool AdjustUsedCapacity)(Extent* e, size_t cacheIdx,
	                                          const void[] slice, size_t size) {
		auto usedCapacity = e.usedCapacity;
		if (!validateCapacity(slice, e.address, usedCapacity)) {
			return false;
		}

		auto epages = e.npages;
		auto newCapacity = usedCapacity + size;

		auto npages = getPageCount(newCapacity);
		if (epages < npages) {
			if (!growLarge(e, npages)) {
				return false;
			}

			triggerAllocationEvent((npages - epages) * PageSize);
			appendLargePages[cacheIdx] = e.npages;
		}

		if (AdjustUsedCapacity) {
			e.setUsedCapacity(newCapacity);
		}

		return true;
	}

	bool resizeSlab(bool AdjustUsedCapacity)(ref SlabAllocInfo si,
	                                         const void[] slice, size_t size) {
		auto usedCapacity = si.usedCapacity;

		if (!validateCapacity(slice, si.address, usedCapacity)) {
			return false;
		}

		auto newCapacity = usedCapacity + size;
		if (AdjustUsedCapacity) {
			return si.setUsedCapacity(newCapacity);
		}

		return newCapacity <= si.slotCapacity;
	}

	bool growLarge(Extent* e, uint npages) {
		state.enterBusyState();
		scope(exit) state.exitBusyState();

		import d.gc.arena;
		return Arena.getInitialized(e.arenaIndex).growLarge(emap, e, npages);
	}

public:
	/**
	 * In-place grow for `GC.extend` (Appender large buffers). Returns false
	 * when the arena cannot attach more pages to this extent.
	 */
	bool growLargeForExtend(PageDescriptor pd, uint npages) {
		auto oldPages = pd.extent.npages;
		if (npages <= oldPages) {
			return true;
		}

		if (!growLarge(pd.extent, npages)) {
			return false;
		}

		triggerAllocationEvent((npages - oldPages) * PageSize);
		return true;
	}

private:

	bool shrinkLarge(PageDescriptor pd, uint npages) {
		foreach (i; 0 .. AppendCacheCount) {
			if (pd.extent is appendLargeExtent[i]) {
				clearAppendLargeCache();
				break;
			}
		}

		state.enterBusyState();
		scope(exit) state.exitBusyState();

		return pd.arena.shrinkLarge(emap, pd.extent, npages);
	}

	void clearAppendLargeCache() {
		appendLargeBaseInv[] = 0;
		appendLargeExtent[] = null;
		appendLargePages[] = 0;
	}

	auto getPageDescriptor(void* ptr) {
		auto pd = maybeGetPageDescriptor(ptr);
		assert(pd.extent !is null);
		assert(pd.isSlab() || ptr is pd.extent.address);

		return pd;
	}

	/**
	 * Same as getPageDescriptor, but remembers the last page. Soft paths
	 * (`GC.extend`) share this one-page cache.
	 */
	auto getPageDescriptorCached(void* ptr) {
		auto aptr = alignDown(ptr, PageSize);
		auto aptrInv = ~cast(size_t) aptr;
		if (likely(aptrInv == pdCachePageInv) && pdCachePD.extent !is null) {
			return pdCachePD;
		}

		auto pd = getPageDescriptor(ptr);
		pdCachePageInv = aptrInv;
		pdCachePD = pd;
		return pd;
	}

	/**
	 * Per-bin slab-extent cache miss handler for allocAppendable. Caches the
	 * slab's Extent*, inverted base address, and total slab byte span so
	 * multi-page slabs hit across every page of the slab.
	 */
	Extent* cacheBinSlabExtent(uint binIndex, ubyte sc, void* ptr) {
		assert(binIndex < ThreadBinCount, "Invalid bin index!");

		auto aptr = alignDown(ptr, PageSize);
		auto pd = emap.lookup(aptr);
		assert(pd.extent !is null && pd.isSlab());

		import d.gc.slab;
		auto e = pd.extent;
		binExtentCache[binIndex] = e;
		binBaseInvCache[binIndex] = ~cast(size_t) e.address;
		binSlabBytesCache[binIndex] = cast(uint) binInfos[sc].npages * PageSize;
		pdCachePageInv = ~cast(size_t) aptr;
		pdCachePD = pd;
		return e;
	}

	/**
	 * Soft page-descriptor lookup with the same one-page cache. Used by
	 * `GC.extend` / array shrink, which must return 0 for unknown / slab
	 * pointers without asserting.
	 */
	public auto maybeGetPageDescriptorCached(void* ptr) {
		auto aptr = alignDown(ptr, PageSize);
		auto aptrInv = ~cast(size_t) aptr;
		if (likely(aptrInv == pdCachePageInv) && pdCachePD.extent !is null) {
			return pdCachePD;
		}

		auto pd = maybeGetPageDescriptor(ptr);
		if (pd.extent !is null) {
			pdCachePageInv = aptrInv;
			pdCachePD = pd;
		}
		return pd;
	}

	package auto maybeGetPageDescriptor(const void* ptr) {
		auto aptr = alignDown(ptr, PageSize);
		return emap.lookup(aptr);
	}

	void reassociateArena(bool force = false) {
		state.enterBusyState();
		scope(exit) state.exitBusyState();

		import d.gc.cpu, d.gc.thread;
		if (!force && associatedArena < ArenaCount &&
		    getRunningThreadCount() <= 2 * getCoreCount()) {
			return;
		}

		if (getRunningThreadCount() > 2 * getCoreCount()) {
			// When large number of thread are runnign, select arena
			// based on the CPU core this trhead runs on.
			associatedArena = -1;
		} else {
			if (force) {
				associatedArena = -1;
			}

			// When the number of thread is low, pick and arena
			// and stick to it.
			associatedArena = selectArenaGroup();
		}
	}

	uint selectArenaGroup() {
		if (associatedArena < ArenaCount) {
			return associatedArena;
		}

		/**
		 * We assume this call is cheap.
		 * This is true on modern linux with modern versions
		 * of glibc thanks to rseqs, but we might want to find
		 * an alternative on other systems.
		 */
		 version(Android) {
			// sched_getcpu needs API level 29, and the loader refuses a
			// library that names a symbol the device does not have. A thread
			// picks its arena from its id instead: same spread over the
			// arenas, and a thread keeps its arena for as long as it lives.
			return cast(uint) tid & ((ArenaCount >> 1) - 1);
		 }
		 else version(linux) {
			import core.sys.linux.sched;
			return sched_getcpu();
		 }
		 else version(Windows) {
			import core.sys.windows.winntex;
			PROCESSOR_NUMBER pnum;
			GetCurrentProcessorNumberEx(&pnum);
			// Each processor group has 64 logical cores. So a 6-bit number with the group id added as the upper bits.
			return (pnum.Group << 6) + pnum.Number;
		 }
	}

	auto chooseArena(bool containsPointers) {
		assert(state.busy, "Must be busy!");
		auto group = selectArenaGroup();

		import d.gc.arena;
		return Arena.getOrInitialize((group << 1) | containsPointers);
	}
}

private:

@"nonAllocatableSizes" unittest {
	ThreadCache tc;

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == 0);
		assert(tc.allocated == tc.deallocated);
	}

	// Prohibited sizes of allocations
	assert(tc.alloc(0, false, false) is null);
	assert(tc.alloc(MaxAllocationSize + 1, false, false) is null);
	assert(tc.allocAppendable(0, false, false) is null);
	assert(tc.allocAppendable(MaxAllocationSize + 1, false, false) is null);
}

@"trackAllocatedBytes" unittest {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	size_t expected = 0;

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == expected);
		assert(tc.allocated == tc.deallocated);
	}

	// Check that small allocations are accounted for.
	foreach (size; 1 .. MaxSmallSize + 1) {
		expected += getAllocSize(size);

		auto ptr0 = tc.alloc(size, false, false);
		assert(tc.allocated == expected);

		tc.free(ptr0);
		assert(tc.deallocated == expected);

		expected += getAllocSize(max(size, 2 * Quantum));

		auto ptr1 = tc.allocAppendable(size, false, false);
		assert(tc.allocated == expected);

		tc.free(ptr1);
		assert(tc.deallocated == expected);
	}

	// Check that large allocations are accounted for.
	for (size_t size = MaxSmallSize + 1; size < 12345; size += 97) {
		auto asize = getPageCount(size) * PageSize;
		expected += asize;

		auto ptr0 = tc.alloc(size, false, false);
		assert(tc.allocated == expected);

		tc.free(ptr0);
		assert(tc.deallocated == expected);

		expected += asize;

		auto ptr1 = tc.allocAppendable(size, false, false);
		assert(tc.allocated == expected);

		tc.free(ptr1);
		assert(tc.deallocated == expected);
	}
}

// The verifier poisons freed slots, which is the opposite of what this test
// looks for (dirty memory coming back after a free).
version(Symgc_verify) {} else
@"zero" unittest {
	enum LargeSize = 5 * PageSize;
	enum SmallSize = 8;

	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	// Check that zeroing large allocations works as expected.
	void* ptr0 = null;
	auto ptr = tc.alloc(LargeSize, false, true);

	// Make sure this isn't the only allocation on the block.
	if (isAligned(ptr, BlockSize)) {
		ptr0 = ptr;
		ptr = tc.alloc(LargeSize, false, true);
	}

	void checkValue(ulong value) {
		auto x = cast(ulong*) ptr;

		foreach (_; 0 .. LargeSize / ulong.sizeof) {
			assert(*x++ == value);
		}
	}

	void setValue(ulong value) {
		auto x = cast(ulong*) ptr;

		foreach (_; 0 .. LargeSize / ulong.sizeof) {
			*x++ = value;
		}

		checkValue(value);
	}

	checkValue(0);
	setValue(0xbadc0ffee0ddf00d);

	// We free and reallocate, we should get the same dirty chunk.
	tc.free(ptr);
	assert(tc.alloc(LargeSize, false, false) is ptr);
	checkValue(0xbadc0ffee0ddf00d);

	// We free and reallocate, but asking for zeroed memory.
	tc.free(ptr);
	assert(tc.alloc(LargeSize, false, true) is ptr);
	checkValue(0);

	// Cleanup after ourselves.
	tc.free(ptr);
	tc.free(ptr0);

	// Now lets check we zero correctly small allocation.
	ptr0 = tc.alloc(SmallSize, false, true);
	ptr = tc.alloc(SmallSize, false, true);

	// Make sure we keep the slab alive?
	while (alignDown(ptr, PageSize) !is alignDown(ptr0, PageSize)) {
		auto old = ptr0;
		ptr0 = ptr;
		ptr = tc.alloc(SmallSize, false, true);
		tc.free(old);
	}

	if (isAligned(ptr, BlockSize)) {
		ptr0 = ptr;
		ptr = tc.alloc(SmallSize, false, true);
	}

	auto uptr = cast(ulong*) ptr;
	assert(*uptr == 0);

	*uptr = 0xbadc0ffee0ddf00d;
	assert(*uptr == 0xbadc0ffee0ddf00d);

	static reallocatePtr(ref ThreadCache tc, void* ptr, bool zero) {
		void* nptr;
		while (nptr !is ptr) {
			auto old = nptr;
			nptr = tc.alloc(SmallSize, false, zero);

			if (old) {
				tc.free(old);
			}
		}
	}

	// Now free and reallocate.
	tc.free(ptr);
	reallocatePtr(tc, ptr, false);
	assert(*uptr == 0xbadc0ffee0ddf00d);

	// We free and reallocate, but asking for zeroed memory.
	tc.free(ptr);
	reallocatePtr(tc, ptr, true);
	assert(*uptr == 0);

	// Cleanup after ourselves.
	tc.free(ptr);
	tc.free(ptr0);
}

@"queryAllocInfos" unittest {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	void checkAllocationSlice(void* ptr, void* base, size_t size) {
		auto slice = tc.getAllocationSlice(ptr);
		assert(slice.ptr is base);
		assert(slice.length == size);
	}

	// Non-appendable size class 6 (56 bytes)
	auto nonAppendable = tc.alloc(50, false, false);
	scope(exit) tc.free(nonAppendable);

	assert(tc.getCapacity(nonAppendable[0 .. 0]) == 0);
	assert(tc.getCapacity(nonAppendable[0 .. 50]) == 0);
	assert(tc.getCapacity(nonAppendable[0 .. 56]) == 56);

	foreach (i; 0 .. 56) {
		checkAllocationSlice(nonAppendable + i, nonAppendable, 56);
	}

	// Capacity of any slice in space unknown to the GC is zero:
	void* nullPtr = null;
	assert(tc.getCapacity(nullPtr[0 .. 0]) == 0);
	assert(tc.getCapacity(nullPtr[0 .. 100]) == 0);
	checkAllocationSlice(nullPtr, null, 0);

	void* stackPtr = &nullPtr;
	assert(tc.getCapacity(stackPtr[0 .. 0]) == 0);
	assert(tc.getCapacity(stackPtr[0 .. 100]) == 0);
	checkAllocationSlice(stackPtr, null, 0);

	static size_t tlValue;
	void* tlPtr = &tlValue;
	assert(tc.getCapacity(tlPtr[0 .. 0]) == 0);
	assert(tc.getCapacity(tlPtr[0 .. 100]) == 0);
	checkAllocationSlice(tlPtr, null, 0);

	void* allocAppendableWithCapacity(size_t size, size_t capacity) {
		auto ptr = tc.allocAppendable(size, false, false, null, capacity);
		assert(ptr !is null);

		auto pd = tc.getPageDescriptor(ptr);
		auto e = pd.extent;
		assert(e !is null);

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, ptr);
			foreach (i; size .. si.slotCapacity) {
				checkAllocationSlice(ptr + i, null, 0);
			}
		} else {
			foreach (i; size .. e.size) {
				checkAllocationSlice(ptr + i, null, 0);
			}
		}

		foreach (i; 0 .. size) {
			checkAllocationSlice(ptr + i, ptr, size);
		}

		return ptr;
	}

	// Check capacity for an appendable large GC allocation.
	auto p0 = allocAppendableWithCapacity(100, 16384);
	scope(exit) tc.free(p0);

	// p0 is appendable and has the minimum large size.
	// Capacity of segment from p0, length 100 is 16384:
	assert(tc.getCapacity(p0[0 .. 100]) == 16384);
	assert(tc.getCapacity(p0[1 .. 100]) == 16383);
	assert(tc.getCapacity(p0[50 .. 100]) == 16334);
	assert(tc.getCapacity(p0[99 .. 100]) == 16285);
	assert(tc.getCapacity(p0[100 .. 100]) == 16284);

	// If the slice doesn't go the end of the allocated area
	// then the capacity must be 0.
	assert(tc.getCapacity(p0[0 .. 0]) == 0);
	assert(tc.getCapacity(p0[0 .. 1]) == 0);
	assert(tc.getCapacity(p0[0 .. 50]) == 0);
	assert(tc.getCapacity(p0[0 .. 99]) == 0);

	assert(tc.getCapacity(p0[0 .. 99]) == 0);
	assert(tc.getCapacity(p0[1 .. 99]) == 0);
	assert(tc.getCapacity(p0[50 .. 99]) == 0);
	assert(tc.getCapacity(p0[99 .. 99]) == 0);

	// This would almost certainly be a bug in user land,
	// but let's make sure be behave reasonably there.
	assert(tc.getCapacity(p0[0 .. 101]) == 0);
	assert(tc.getCapacity(p0[1 .. 101]) == 0);
	assert(tc.getCapacity(p0[50 .. 101]) == 0);
	assert(tc.getCapacity(p0[100 .. 101]) == 0);
	assert(tc.getCapacity(p0[101 .. 101]) == 0);

	// Check capacity for an appendable small GC allocation.
	auto p1 = allocAppendableWithCapacity(100, 4096);
	scope(exit) tc.free(p1);

	// p1 is appendable and has the minimum large size.
	// Capacity of segment from p1, length 100 is 4096:
	assert(tc.getCapacity(p1[0 .. 100]) == 4096);
	assert(tc.getCapacity(p1[1 .. 100]) == 4095);
	assert(tc.getCapacity(p1[50 .. 100]) == 4046);
	assert(tc.getCapacity(p1[99 .. 100]) == 3997);
	assert(tc.getCapacity(p1[100 .. 100]) == 3996);

	// If the slice doesn't go the end of the allocated area
	// then the capacity must be 0.
	assert(tc.getCapacity(p1[0 .. 0]) == 0);
	assert(tc.getCapacity(p1[0 .. 1]) == 0);
	assert(tc.getCapacity(p1[0 .. 50]) == 0);
	assert(tc.getCapacity(p1[0 .. 99]) == 0);

	assert(tc.getCapacity(p1[0 .. 99]) == 0);
	assert(tc.getCapacity(p1[1 .. 99]) == 0);
	assert(tc.getCapacity(p1[50 .. 99]) == 0);
	assert(tc.getCapacity(p1[99 .. 99]) == 0);

	// This would almost certainly be a bug in user land,
	// but let's make sure be behave reasonably there.
	assert(tc.getCapacity(p1[0 .. 101]) == 0);
	assert(tc.getCapacity(p1[1 .. 101]) == 0);
	assert(tc.getCapacity(p1[50 .. 101]) == 0);
	assert(tc.getCapacity(p1[100 .. 101]) == 0);
	assert(tc.getCapacity(p1[101 .. 101]) == 0);
}

@"realloc" unittest {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	size_t allocated = 0;
	size_t deallocated = 0;

	void checkAllocatedByteTracking() {
		assert(tc.allocated == allocated);
		assert(tc.deallocated == deallocated);
	}

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		checkAllocatedByteTracking();
		assert(tc.allocated == tc.deallocated);
	}

	// Realloc.
	auto p0 = tc.allocAppendable(20000, false, false);
	auto asize = getPageCount(20000) * PageSize;
	allocated += asize;
	checkAllocatedByteTracking();

	assert(tc.getCapacity(p0[0 .. 19999]) == 0);
	assert(tc.getCapacity(p0[0 .. 20000]) == 20480);
	assert(tc.getCapacity(p0[0 .. 20001]) == 0);

	// Decreasing the size of the allocation
	// should adjust capacity accordingly.
	auto p1 = tc.realloc(p0, 19999, false);
	assert(p1 is p0);

	assert(tc.getCapacity(p1[0 .. 19999]) == 20480);
	assert(tc.getCapacity(p1[0 .. 20000]) == 0);
	assert(tc.getCapacity(p1[0 .. 20001]) == 0);

	// Increasing the size of the allocation increases capacity.
	auto p2 = tc.realloc(p1, 20001, false);
	assert(p2 is p1);

	assert(tc.getCapacity(p2[0 .. 19999]) == 0);
	assert(tc.getCapacity(p2[0 .. 20000]) == 0);
	assert(tc.getCapacity(p2[0 .. 20001]) == 20480);

	// This realloc happens in-place when they shrink a large alloc.
	auto p3 = tc.realloc(p2, 16000, false);
	assert(p3 is p2);
	assert(tc.getCapacity(p3[0 .. 16000]) == 16384);

	deallocated += PageSize;
	checkAllocatedByteTracking();

	// The also happen in-place when extending
	// if there is room for it in the block.
	auto p4 = tc.realloc(p3, 20000, false);
	assert(p4 is p3);
	assert(tc.getCapacity(p4[0 .. 20000]) == 20480);

	allocated += PageSize;
	checkAllocatedByteTracking();

	// Realloc from large to small size class results in new allocation.
	auto p5 = tc.realloc(p4, 100, false);
	assert(p5 !is p4);

	allocated += 112;
	deallocated += 5 * PageSize;
	checkAllocatedByteTracking();

	// Cleanup after ourselves.
	tc.free(p5);
	deallocated += 112;
	checkAllocatedByteTracking();
}

@"extendSmall" unittest {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	// Non-appendable size class 6 (56 bytes)
	auto nonAppendable = tc.alloc(50, false, false);
	scope(exit) tc.free(nonAppendable);

	assert(tc.getCapacity(nonAppendable[0 .. 50]) == 0);
	assert(tc.allocated == 56);

	// Attempt to extend a non-appendable (always considered fully occupied)
	assert(!tc.extend(nonAppendable[50 .. 50], 1));
	assert(!tc.extend(nonAppendable[0 .. 0], 1));

	// Extend by zero is permitted even when no capacity:
	assert(tc.extend(nonAppendable[50 .. 50], 0));

	// Extend in space unknown to the GC. Can only extend by zero.
	void* nullPtr = null;
	assert(tc.extend(nullPtr[0 .. 100], 0));
	assert(!tc.extend(nullPtr[0 .. 100], 1));
	assert(!tc.extend(nullPtr[100 .. 100], 1));

	void* stackPtr = &nullPtr;
	assert(tc.extend(stackPtr[0 .. 100], 0));
	assert(!tc.extend(stackPtr[0 .. 100], 1));
	assert(!tc.extend(stackPtr[100 .. 100], 1));

	static size_t tlValue;
	void* tlPtr = &tlValue;
	assert(tc.extend(tlPtr[0 .. 100], 0));
	assert(!tc.extend(tlPtr[0 .. 100], 1));
	assert(!tc.extend(tlPtr[100 .. 100], 1));

	// Check that small appendable alloc can be extended.
	auto s0 = tc.allocAppendable(42, false, false);
	assert(tc.allocated == 104);

	assert(tc.getCapacity(s0[0 .. 42]) == 48);
	assert(tc.extend(s0[0 .. 0], 0));
	assert(!tc.extend(s0[0 .. 0], 10));
	assert(!tc.extend(s0[0 .. 41], 10));
	assert(!tc.extend(s0[1 .. 41], 10));
	assert(!tc.extend(s0[0 .. 20], 10));

	assert(!tc.extend(s0[0 .. 42], 7));
	assert(!tc.extend(s0[32 .. 42], 7));
	assert(tc.extend(s0[0 .. 42], 3));
	assert(tc.getCapacity(s0[0 .. 45]) == 48);

	// Check that there are no interference.
	auto s1 = tc.allocAppendable(42, false, false);
	assert(tc.allocated == 152);

	assert(tc.extend(s1[0 .. 42], 1));
	assert(tc.getCapacity(s1[0 .. 43]) == 48);
	assert(tc.getCapacity(s0[0 .. 45]) == 48);

	// Extend to the maximum.
	assert(tc.getCapacity(s0[0 .. 42]) == 0);
	assert(tc.extend(s0[40 .. 45], 2));
	assert(tc.getCapacity(s0[0 .. 45]) == 0);
	assert(tc.getCapacity(s0[0 .. 47]) == 48);
	assert(!tc.extend(s0[0 .. 47], 2));
	assert(tc.extend(s0[0 .. 47], 1));

	// Decreasing the size of the allocation
	// should adjust capacity accordingly.
	auto s2 = tc.realloc(s0, 42, false);
	assert(s2 is s0);
	assert(tc.getCapacity(s2[0 .. 42]) == 48);
	assert(tc.allocated == 152);

	// Increasing the size of the allocation
	// should adjust capacity too.
	auto s3 = tc.realloc(s2, 45, false);
	assert(s3 is s2);
	assert(tc.getCapacity(s3[0 .. 45]) == 48);
	assert(tc.allocated == 152);

	// Increasing the size past what's supported by
	// the size class will cause a reallocation.
	auto s4 = tc.realloc(s3, 70, false);
	assert(s4 !is s3);
	assert(tc.getCapacity(s4[0 .. 80]) == 80);
	assert(tc.allocated == 232);
	assert(tc.deallocated == 48);

	// Decreasing the size of the allocation so that
	// it drops down to a lower size class also causes
	// a reallocation.
	auto s5 = tc.realloc(s4, 60, false);
	assert(s5 !is s4);
	assert(tc.getCapacity(s5[0 .. 64]) == 64);
	assert(tc.allocated == 296);
	assert(tc.deallocated == 128);

	// Cleanup after ourselves.
	tc.free(s1);
	tc.free(s5);
}

@"extendLarge" unittest {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	size_t allocated = 0;
	size_t deallocated = 0;

	void checkAllocatedByteTracking() {
		assert(tc.allocated == allocated);
		assert(tc.deallocated == deallocated);
	}

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		checkAllocatedByteTracking();
		assert(tc.allocated == tc.deallocated);
	}

	enum DeadZoneSize = getPageCount(MaxSmallSize + 1) * PageSize;

	void* allocAppendableWithCapacity(size_t size, size_t capacity) {
		// Make sure we keep track of all allocations.
		scope(exit) checkAllocatedByteTracking();

		auto ptr = tc.allocAppendable(size, false, false, null, capacity);
		assert(ptr !is null);

		auto asize = getPageCount(capacity) * PageSize;
		allocated += asize + DeadZoneSize;

		// We make sure we can't resize the allocation
		// by allocating a dead zone after it.
		import d.gc.size;
		auto deadzone = tc.alloc(DeadZoneSize, false, false);
		if (deadzone !is alignUp(ptr + capacity, PageSize)) {
			tc.free(deadzone);
			deallocated += DeadZoneSize;

			scope(success) {
				tc.free(ptr);
				deallocated += asize;
			}

			return allocAppendableWithCapacity(size, capacity);
		}

		auto pd = tc.getPageDescriptor(ptr);
		auto e = pd.extent;
		assert(e !is null);
		assert(e.isLarge());

		return ptr;
	}

	// Make an appendable alloc:
	auto p0 = allocAppendableWithCapacity(100, 16384);
	assert(tc.getCapacity(p0[0 .. 100]) == 16384);

	// Attempt to extend valid slices with capacity 0.
	// See getCapacity tests.
	assert(tc.extend(p0[0 .. 0], 0));
	assert(!tc.extend(p0[0 .. 0], 50));
	assert(!tc.extend(p0[0 .. 99], 50));
	assert(!tc.extend(p0[1 .. 99], 50));
	assert(!tc.extend(p0[0 .. 50], 50));

	// Extend by size zero is permitted but has no effect.
	assert(tc.extend(p0[100 .. 100], 0));
	assert(tc.extend(p0[0 .. 100], 0));
	assert(tc.getCapacity(p0[0 .. 100]) == 16384);
	assert(tc.extend(p0[50 .. 100], 0));
	assert(tc.getCapacity(p0[50 .. 100]) == 16334);

	// Attempt extend with insufficient space.
	assert(tc.getCapacity(p0[100 .. 100]) == 16284);
	assert(!tc.extend(p0[0 .. 100], 16285));
	assert(!tc.extend(p0[50 .. 100], 16285));

	// Extending to the limit succeeds.
	assert(tc.extend(p0[50 .. 100], 16284));

	// Now we're full, and can only extend by zero.
	assert(tc.extend(p0[0 .. 16384], 0));
	assert(!tc.extend(p0[0 .. 16384], 1));

	// Unless we clear the dead zone, in which case we can extend again.
	tc.free(p0 + DeadZoneSize);
	deallocated += DeadZoneSize;
	checkAllocatedByteTracking();

	assert(tc.extend(p0[0 .. 16384], 1));
	assert(tc.getCapacity(p0[0 .. 16385]) == 16384 + PageSize);

	allocated += PageSize;
	checkAllocatedByteTracking();

	// Check extensions of slices.
	auto p1 = allocAppendableWithCapacity(100, 16384);
	assert(tc.getCapacity(p1[0 .. 100]) == 16384);

	assert(tc.extend(p1[0 .. 100], 50));
	assert(tc.getCapacity(p1[100 .. 150]) == 16284);
	assert(tc.extend(p1[0 .. 150], 0));

	assert(tc.getCapacity(p1[0 .. 100]) == 0);
	assert(tc.extend(p1[0 .. 100], 0));
	assert(tc.getCapacity(p1[0 .. 150]) == 16384);

	// Extent the upper half.
	assert(tc.extend(p1[125 .. 150], 100));
	assert(tc.getCapacity(p1[150 .. 250]) == 16234);

	assert(tc.getCapacity(p1[125 .. 150]) == 0);
	assert(tc.extend(p1[125 .. 150], 0));

	assert(tc.extend(p1[125 .. 250], 0));
	assert(tc.getCapacity(p1[125 .. 250]) == 16259);
	assert(tc.getCapacity(p1[0 .. 250]) == 16384);

	// Extend at the very end of the slice.
	assert(tc.extend(p1[250 .. 250], 200));
	assert(tc.getCapacity(p1[250 .. 450]) == 16134);

	assert(tc.getCapacity(p1[0 .. 250]) == 0);
	assert(tc.getCapacity(p1[0 .. 450]) == 16384);

	// Extend up to all the available space.
	assert(tc.extend(p1[0 .. 450], 15933));
	assert(tc.getCapacity(p1[16383 .. 16383]) == 1);
	assert(tc.extend(p1[16383 .. 16383], 1));
	assert(tc.getCapacity(p1[0 .. 16384]) == 16384);

	// When full, we can't extend any more.
	assert(!tc.extend(p1[0 .. 16384], 1));
	assert(tc.extend(p1[0 .. 16384], 0));

	// De-allocate everything.
	tc.free(p0);
	deallocated += 5 * PageSize;
	checkAllocatedByteTracking();

	tc.free(p1 + DeadZoneSize);
	deallocated += DeadZoneSize;
	checkAllocatedByteTracking();

	tc.free(p1);
	deallocated += 4 * PageSize;
	checkAllocatedByteTracking();
}

@"reserve" unittest {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	size_t allocated = 0;
	size_t deallocated = 0;

	void checkAllocatedByteTracking() {
		assert(tc.allocated == allocated);
		assert(tc.deallocated == deallocated);
	}

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		checkAllocatedByteTracking();
		assert(tc.allocated == tc.deallocated);
	}

	// Non-appendable size class 6 (56 bytes)
	auto nonAppendable = tc.alloc(50, false, false);
	scope(exit) {
		deallocated += 56;
		tc.free(nonAppendable);
	}

	allocated += 56;
	checkAllocatedByteTracking();
	assert(tc.getCapacity(nonAppendable[0 .. 50]) == 0);

	// Attempt to reserve a non-appendable (always considered fully occupied)
	assert(!tc.reserve(nonAppendable[50 .. 50], 1));
	assert(!tc.reserve(nonAppendable[0 .. 0], 1));

	// Reserve by zero is permitted even when no capacity:
	assert(tc.reserve(nonAppendable[50 .. 50], 0));

	// Reserve in space unknown to the GC.
	void* nullPtr = null;
	assert(tc.reserve(nullPtr[0 .. 100], 0));
	assert(!tc.reserve(nullPtr[0 .. 100], 1));
	assert(!tc.reserve(nullPtr[100 .. 100], 1));

	void* stackPtr = &nullPtr;
	assert(tc.reserve(stackPtr[0 .. 100], 0));
	assert(!tc.reserve(stackPtr[0 .. 100], 1));
	assert(!tc.reserve(stackPtr[100 .. 100], 1));

	static size_t tlValue;
	void* tlPtr = &tlValue;
	assert(tc.reserve(tlPtr[0 .. 100], 0));
	assert(!tc.reserve(tlPtr[0 .. 100], 1));
	assert(!tc.reserve(tlPtr[100 .. 100], 1));

	// Check that we can reserve after small appendable allocations.
	auto s0 = tc.allocAppendable(42, false, false);
	scope(exit) {
		deallocated += 48;
		tc.free(s0);
	}

	allocated += 48;
	checkAllocatedByteTracking();
	assert(tc.getCapacity(s0[0 .. 42]) == 48);

	assert(tc.reserve(s0[0 .. 0], 0));
	assert(!tc.reserve(s0[0 .. 0], 10));
	assert(!tc.reserve(s0[0 .. 41], 10));
	assert(!tc.reserve(s0[1 .. 41], 10));
	assert(!tc.reserve(s0[0 .. 20], 10));

	assert(tc.reserve(s0[0 .. 42], 3));
	assert(tc.reserve(s0[0 .. 42], 6));
	assert(tc.reserve(s0[32 .. 42], 6));
	assert(!tc.reserve(s0[0 .. 42], 7));
	assert(!tc.reserve(s0[32 .. 42], 7));
	assert(tc.getCapacity(s0[0 .. 42]) == 48);

	// Check that we can reserve after large appendable allocations.
	enum DeadZoneSize = getPageCount(MaxSmallSize + 1) * PageSize;

	void* allocAppendableWithCapacity(size_t size, size_t capacity) {
		// Make sure we keep track of all allocations.
		scope(exit) checkAllocatedByteTracking();

		auto ptr = tc.allocAppendable(size, false, false, null, capacity);
		assert(ptr !is null);

		auto asize = getPageCount(capacity) * PageSize;
		allocated += asize + DeadZoneSize;

		// We make sure we can't resize the allocation
		// by allocating a dead zone after it.
		import d.gc.size;
		auto deadzone = tc.alloc(DeadZoneSize, false, false);
		if (deadzone !is alignUp(ptr + capacity, PageSize)) {
			tc.free(deadzone);
			deallocated += DeadZoneSize;

			scope(success) {
				tc.free(ptr);
				deallocated += asize;
			}

			return allocAppendableWithCapacity(size, capacity);
		}

		auto pd = tc.getPageDescriptor(ptr);
		auto e = pd.extent;
		assert(e !is null);
		assert(e.isLarge());

		return ptr;
	}

	auto p0 = allocAppendableWithCapacity(100, 16384);
	assert(tc.getCapacity(p0[0 .. 100]) == 16384);

	// Reserve from an invalid slice.
	assert(tc.reserve(p0[0 .. 0], 0));
	assert(!tc.reserve(p0[0 .. 0], 50));
	assert(!tc.reserve(p0[0 .. 99], 50));
	assert(!tc.reserve(p0[1 .. 99], 50));
	assert(!tc.reserve(p0[0 .. 50], 50));

	// Reserve an extra 0 byte is permitted but has no effect.
	assert(tc.reserve(p0[100 .. 100], 0));
	assert(tc.reserve(p0[0 .. 100], 0));
	assert(tc.reserve(p0[50 .. 100], 0));
	assert(tc.getCapacity(p0[50 .. 100]) == 16334);

	// Attempt to reserve past the end of the allocation.
	assert(tc.getCapacity(p0[100 .. 100]) == 16284);
	assert(!tc.reserve(p0[0 .. 100], 16285));
	assert(!tc.reserve(p0[50 .. 100], 16285));

	// Reserving to the limit succeeds.
	assert(tc.reserve(p0[50 .. 100], 16284));
	assert(tc.getCapacity(p0[0 .. 100]) == 16384);

	// Unless we clear the dead zone, in which case we can reserve more.
	tc.free(p0 + DeadZoneSize);
	deallocated += DeadZoneSize;
	checkAllocatedByteTracking();

	assert(tc.reserve(p0[0 .. 100], 16285));
	assert(tc.getCapacity(p0[0 .. 100]) == 16384 + PageSize);

	allocated += PageSize;
	checkAllocatedByteTracking();

	// De-allocate everything.
	tc.free(p0);
	deallocated += 5 * PageSize;
	checkAllocatedByteTracking();
}

@"arraySpill" unittest {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
		assert(tc.allocated == tc.deallocated);
	}

	void setAllocationUsedCapacity(void* ptr, size_t usedCapacity) {
		assert(ptr !is null);

		auto pd = tc.getPageDescriptor(ptr);
		auto e = pd.extent;
		assert(e !is null);

		if (pd.isSlab()) {
			auto si = SlabAllocInfo(pd, ptr);
			si.setUsedCapacity(usedCapacity);
		} else {
			e.setUsedCapacity(usedCapacity);
		}
	}

	// Get two allocs of given size guaranteed to be adjacent.
	void*[2] makeTwoAdjacentAllocs(uint size) {
		void* alloc() {
			return tc.alloc(size, false, false);
		}

		void*[2] tryPair(void* a, void* b) {
			assert(a !is null);
			assert(b !is null);

			if (a + size is b) {
				return [a, b];
			}

			if (b + size is a) {
				return [b, a];
			}

			auto pair = tryPair(b, alloc());
			tc.free(a);
			return pair;
		}

		return tryPair(alloc(), alloc());
	}

	void testSpill(uint arraySize, uint[] capacities) {
		auto pair = makeTwoAdjacentAllocs(arraySize);
		void* a0 = pair[0];
		void* a1 = pair[1];
		assert(a1 == a0 + arraySize);

		void testZeroLengthSlices() {
			foreach (a0Capacity; capacities) {
				setAllocationUsedCapacity(a0, a0Capacity);
				// For all possible zero-length slices of a0:
				foreach (s; 0 .. arraySize + 1) {
					// A zero-length slice has non-zero capacity
					// if and only if it resides at the start of
					// the free space of a non-empty allocation:
					auto sliceCapacity = tc.getCapacity(a0[s .. s]);
					auto haveCapacity = sliceCapacity > 0;
					assert((s == a0Capacity && s > 0 && s < arraySize)
						== haveCapacity);

					// Capacity in non-degenerate case follows standard rule:
					assert(!haveCapacity || sliceCapacity == arraySize - s);
				}
			}
		}

		// Try it with various capacities for a1:
		foreach (a1Capacity; capacities) {
			setAllocationUsedCapacity(a1, a1Capacity);
			testZeroLengthSlices();
		}

		// Same rules apply if the space above a0 is not allocated:
		tc.free(a1);
		testZeroLengthSlices();

		tc.free(a0);
	}

	testSpill(64, [0, 1, 2, 32, 63, 64]);
	testSpill(80, [0, 1, 2, 32, 79, 80]);
	testSpill(16384, [0, 1, 2, 500, 16000, 16383, 16384]);
	testSpill(20480, [0, 1, 2, 500, 20000, 20479, 20480]);
}

@"finalization" unittest {
	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);

	// Make sure we leave things in a clean state.
	scope(exit) {
		tc.destroyThread();
	}

	// Faux destructor which simply records most recent kill:
	static size_t lastKilledUsedCapacity = 0;
	static void* lastKilledAddress;
	static uint destroyCount = 0;
	static void destroyfn(void* ptr, size_t size) {
		lastKilledUsedCapacity = size;
		lastKilledAddress = ptr;
		destroyCount++;
	}

	version(Symgc_druntime_hooks) {
		// use a static struct to get the correct typeinfo
		static struct Destroyer(size_t realSize)
		{
			// subtract 1 since we add 1 for allocating a block with metadata
			ubyte[realSize-1] data;
			~this() { destroyfn(&this, realSize); }
		}

		auto destruct(size_t size)() => cast(void*)typeid(Destroyer!size);
	} else {
		// using sdc-style hook.
		auto destruct(size_t size)() => &destroyfn;
	}

	// Finalizers for large allocs:
	auto s0 = tc.allocAppendable(16384, false, false, destruct!16384);
	tc.destroy(s0);
	assert(lastKilledAddress == s0);
	assert(lastKilledUsedCapacity == 16384);

	// Destroy on non-finalized alloc is harmless:
	auto s1 = tc.allocAppendable(20000, false, false);
	auto oldDestroyCount = destroyCount;
	tc.destroy(s1);
	assert(destroyCount == oldDestroyCount);

	// Finalizers for small allocs:
	auto s2 = tc.allocAppendable(45, false, false, destruct!48);
	assert(tc.getCapacity(s2[0 .. 45]) == 48);
	assert(!tc.extend(s2[0 .. 45], 4));
	assert(tc.extend(s2[0 .. 45], 3));
	assert(tc.getCapacity(s2[0 .. 48]) == 48);
	tc.destroy(s2);
	assert(lastKilledAddress == s2);
	assert(lastKilledUsedCapacity == 48);

	// Behavior of realloc() on small allocs with finalizers:
	auto s3 = tc.allocAppendable(70, false, false, destruct!70);
	assert(tc.getCapacity(s3[0 .. 70]) == 72);
	auto s4 = tc.realloc(s3, 70, false);
	assert(s3 == s4);

	// This is in the same size class, but will not work in-place
	// given as finalizer occupies final 8 of the 80 bytes in the slot:
	auto s5 = tc.realloc(s4, 75, false);
	assert(s5 != s4);

	// So we end up with a new alloc, without metadata:
	assert(tc.getCapacity(s5[0 .. 80]) == 80);

	// And the finalizer has been discarded:
	oldDestroyCount = destroyCount;
	tc.destroy(s5);
	assert(destroyCount == oldDestroyCount);

	assert(tc.allocated == tc.deallocated);
}

/**
 * Releasing a block while a concurrent mark is running must log its pointers.
 */
@"satb release barrier" unittest {
	import d.gc.satb;
	enum LargeSize = 8 * PageSize;

	ThreadCache tc;
	tc.initialize(&gExtentMap, &gBase);
	scope(exit) tc.destroyThread();

	static bool drainedContains(void* needle) {
		bool found;
		satbFlushThread();
		satbDrain((void* p) { found |= p is needle; });
		return found;
	}

	void startMarking() {
		satbBegin(cast(void*) 0x1000, cast(void*) (1UL << 47));
	}

	void stopMarking() {
		satbEnd();
		satbFlushThread();
		satbDrain((void*) {});
	}

	// A small block that holds a pointer.
	{
		auto child = tc.alloc(64, true, true);
		auto parent = cast(void**) tc.alloc(64, true, true);
		parent[0] = child;

		// Not marking: free logs nothing.
		auto spare = cast(void**) tc.alloc(64, true, true);
		spare[0] = child;
		tc.free(spare);
		assert(!drainedContains(child));

		startMarking();
		scope(exit) stopMarking();

		tc.free(parent);
		assert(drainedContains(child), "free() did not log the freed block's pointers");
		tc.free(child);
	}

	// A no-scan block holds no pointers: nothing to log.
	{
		auto fake = cast(void*) 0x2000;
		auto data = cast(void**) tc.alloc(64, false, true);
		data[0] = fake;

		startMarking();
		scope(exit) stopMarking();

		tc.free(data);
		assert(!drainedContains(fake));
	}

	// A large block that holds a pointer.
	{
		auto child = tc.alloc(64, true, true);
		auto parent = cast(void**) tc.alloc(LargeSize, true, true);
		parent[0] = child;

		startMarking();
		scope(exit) stopMarking();

		tc.free(parent);
		assert(drainedContains(child));
		tc.free(child);
	}

	// realloc that moves a block frees the old one: its pointers are logged.
	{
		auto child = tc.alloc(64, true, true);
		auto parent = cast(void**) tc.alloc(64, true, true);
		parent[0] = child;

		startMarking();
		scope(exit) stopMarking();

		auto moved = cast(void**) tc.realloc(parent, 4096, true);
		assert(moved !is parent);
		assert(moved[0] is child);
		assert(drainedContains(child));
		tc.free(moved);
		tc.free(child);
	}

	// realloc that shrinks a large block releases a tail: its pointers are logged.
	{
		auto child = tc.alloc(64, true, true);
		auto parent = cast(void**) tc.alloc(LargeSize, true, true);
		auto tail = cast(void**) (cast(void*) parent + 6 * PageSize);
		tail[0] = child;

		startMarking();
		scope(exit) stopMarking();

		auto shrunk = tc.realloc(parent, 4 * PageSize, true);
		if (shrunk is parent) {
			assert(drainedContains(child), "shrinking realloc did not log the released tail");
		}

		tc.free(shrunk);
		tc.free(child);
	}
}
