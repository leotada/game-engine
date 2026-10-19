module d.gc.page;

import d.gc.allocclass;
import d.gc.arena;
import d.gc.block;
import d.gc.emap;
import d.gc.extent;
import d.gc.size;
import d.gc.sizeclass : BinCount;
import d.gc.spec;
import d.gc.util;

import symgc.intrinsics;

import d.gc.time;
__gshared ulong[8] gSweepT;

version(Symgc_phase_trace) {
	// Pages given out and taken back since the start, for the trace
	// (extents: allocated, freed; and how many of the allocated were slabs).
	shared Atomic!ulong gTracePagesAdded, gTracePagesFreed, gTraceSlabPages, gTracePagesGrown;
}

/**
 * What a thread that helps with the sweep found: nothing to do (no sweep, or
 * it is over), it did a step, or the work is there but it is not for it now.
 */
enum AssistResult : ubyte {
	Done,
	Worked,
	Waiting,
}

/**
 * The share of the time, in percent, the background sweeper may run. 100
 * disables pacing.
 */
__gshared uint gSweepDutyPercent = 50;

/**
 * The sweeper stops pacing itself when the heap, in pages, grows past this
 * limit during a sweep. The collector sets it when the sweep starts.
 */
__gshared size_t gSweepGrowthLimit = size_t.max;

/**
 * Past this heap size, in pages, a thread that is about to allocate helps
 * with the sweep instead of letting the heap grow. The collector sets it
 * when the sweep starts.
 */
__gshared size_t gSweepHardLimit = size_t.max;

/**
 * How many free pages each arena keeps warm during a sweep instead of
 * returning them to the OS. The collector sets it when the sweep starts.
 */
__gshared size_t gSweepRetainPages = 0;

/**
 * Counts the extents freed, in all arenas. A thread that remembers where an
 * array lives (see `ThreadCache.resize`) knows it is stale when this changed:
 * freed pages may come back as a slab of another size class.
 */
import d.sync.atomic : Atomic;
shared Atomic!uint gSlabFreeEpoch;

struct PageFiller {
private:
	@property package
	shared(Arena)* arena() shared {
		auto a = cast(Arena*) null;
		auto offset = cast(size_t) &(a.filler);

		auto base = cast(size_t) &this;
		return cast(shared(Arena)*) (base - offset);
	}

	import d.sync.mutex;
	shared Mutex mutex;

	// Who held the lock last, see `gHolderCount`.
	version(Symgc_lock_hist) shared ubyte lastHolder;

	/**
	 * We separate dense from sparse allocations.
	 *
	 * Dense allocations are slabs which contains a lot of elements.
	 * In practice, these slabs tends to be long lived, because it
	 * is unlikely that all of their slots get freed at the same time.
	 * In addition, all slabs that require spacial care, such as slabs
	 * that cannot do inline marking, are dense, so segregating them
	 * allows to iterate over all of them efficiently.
	 *
	 * The second set of heaps is used for sparse allocations.
	 * Sparse allocation are slabs with few elements, and large
	 * allocations.
	 */
	enum HeapCount = getAllocClass(PagesInBlock - 1);
	static assert(HeapCount <= 32, "Too many heaps to fit in the filter!");

	uint denseFilter;
	uint sparseFilter;

	PriorityBlockHeap[8] denseHeaps;
	PriorityBlockHeap[HeapCount] sparseHeaps;

	AllBlockRing denseBlocks;
	AllBlockRing sparseBlocks;

	import d.sync.atomic;
	shared Atomic!size_t usedPageCount;

	import d.gc.ring;
	Ring!BlockDescriptor fullBlocks;

	UnusedExtentHeap unusedExtents;
	UnusedBlockHeap unusedBlockDescriptors;

	OutlinedBitmap* outlinedBitmaps;

	/**
	 * The sweep runs one block at a time, releasing the mutex in between.
	 * `sweepNext` is the next block to visit in the ring of all blocks of the
	 * current phase; it is fixed up when a block leaves the ring.
	 */
	enum SweepPhase : ubyte {
		Idle,

		/**
		 * Run the finalizers of every dead object first. Only then are dead
		 * slots released, so a finalizer that reads another dead object
		 * finds it as it was, even though threads allocate while we sweep.
		 */
		DenseFinalize,
		SparseFinalize,

		DenseScan,
		DenseMinimize,
		SparseScan,
		SparseMinimize,
	}

	SweepPhase sweepPhase;
	BlockDescriptor* sweepNext;

	// The block a scan is in the middle of, and the page to resume at.
	BlockDescriptor* sweepCurrent;
	uint sweepPage;

	// The cycle being swept, its epoch, and what the sweep found so far.
	ubyte sweepGcCycle;
	uint sweepEpoch;
	CollectStats sweepStats;

	// A step is running. See `sweepStep`.
	bool sweepStepping;

	// The concurrent prepare of the mark bits: where it is, like the sweep.
	bool preparing;
	uint prepareEpoch;
	ushort prepareSerial;
	BlockDescriptor* prepareNext;
	BlockDescriptor* prepareCurrent;
	uint preparePage;
	ulong[] prepareBitmaps;

	// How many more free pages this sweep may keep instead of returning them
	// to the OS, see `minimizeBlock`.
	size_t sweepRetain;

	// The block whose free pages are being returned to the OS, a chunk per
	// step, see `minimizeStepImpl`.
	BlockDescriptor* minimizeCur;

	// A step holds the lock for about this long (time unit is 100 ns).
	enum SweepStepBudget = 100;

	import d.gc.base;
	shared Base base;

	import d.gc.region;
	import d.gc.slab;
	package shared(RegionAllocator)* regionAllocator;

public:
	/**
	 * Slabs facilities.
	 */
	Extent* allocSlab(ref CachedExtentMap emap, ubyte sizeClass) shared {
		import d.gc.slab;
		auto neededPages = binInfos[sizeClass].npages;

		auto ec = ExtentClass.slab(sizeClass);
		auto e = allocSmallRun(neededPages, neededPages - 1, ec);
		if (unlikely(e is null)) {
			return null;
		}

		if (likely(emap.remap(e, ec))) {
			// Pages may be recycled and hold anything. The verifier expects a
			// slot to be either zero or poison, so start from zero.
			version(Symgc_verify) {
				import core.stdc.string : memset;
				memset(e.address, 0, neededPages * PageSize);
			}

			return e;
		}

		// We failed to map the extent, unwind!
		freePages(e);
		return null;
	}

	/**
	 * Large allocation facilities.
	 * Returns the Extent* so appendable setup can set capacity without a
	 * second emap lookup of the pointer we just mapped.
	 */
	Extent* allocLarge(ref CachedExtentMap emap, uint pages, bool zero) shared {
		bool dirty;
		auto e = allocPages(pages, dirty);
		if (unlikely(e is null)) {
			return null;
		}

		if (!likely(emap.remap(e))) {
			// We failed to map the extent, unwind!
			freePages(e);
			return null;
		}

		if (zero && dirty) {
			import d.gc.memmap;
			pages_zero(e.address, e.size);
		}

		return e;
	}

	bool growLarge(ref CachedExtentMap emap, Extent* e, uint pages) shared {
		assert(e !is null, "Extent is null!");
		assert(e.isLarge(), "Expected a large extent!");
		assert(pages > e.npages, "Invalid page count!");

		auto n = e.blockIndex;
		uint currentPages = e.npages;

		uint start = n + currentPages - 1;
		uint stop = n + pages - 1;
		uint delta = pages - currentPages;

		if ((start ^ stop) < PagesInBlock) {
			assert(delta < PagesInBlock, "Invalid delta!");

			// We cannot hugify an extant that isn't block aligned.
			import d.gc.size;
			if (n != 0 && isHugePageCount(pages)) {
				return false;
			}

			uint index = (n + currentPages) % PagesInBlock;
			if (!growAlloc(e, index, delta)) {
				return false;
			}
		} else {
			// We cannot hugify an extent that isn't block aligned.
			if (n != 0) {
				return false;
			}

			uint currentBlocks = ((currentPages - 1) / PagesInBlock) + 1;
			uint newBlocks = ((pages - 1) / PagesInBlock) + 1;
			assert(newBlocks > currentBlocks, "Invalid block count!");

			auto extraBlocks = newBlocks - currentBlocks;
			if (!growHuge(e, extraBlocks, pages, delta)) {
				return false;
			}
		}

		auto pd = PageDescriptor(e, ExtentClass.large());
		auto endPtr = e.address + currentPages * PageSize;
		if (likely(emap.map(endPtr, delta, pd.next(currentPages)))) {
			return true;
		}

		// We failed to map the new pages, unwind!
		bool success = shrinkLarge(emap, e, currentPages);
		assert(success,
		       "Failed to shrink back the extent to its original size!");

		return false;
	}

	bool shrinkLarge(ref CachedExtentMap emap, Extent* e, uint pages) shared {
		assert(e !is null, "Extent is null!");
		assert(e.isLarge(), "Expected a large extent!");
		assert(pages > 0 && pages < e.npages, "Invalid page count!");

		auto n = e.blockIndex;
		uint currentPages = e.npages;

		uint start = n + pages - 1;
		uint stop = n + currentPages - 1;

		if ((start ^ stop) >= PagesInBlock) {
			// We check that the old size and the new size
			// terminate in the same block.
			return false;
		}

		uint delta = currentPages - pages;
		assert(delta < PagesInBlock, "Invalid delta!");

		emap.clear(e.address + pages * PageSize, delta);

		uint index = (n + pages) % PagesInBlock;
		shrinkAlloc(e, index, delta);

		return true;
	}

	/**
	 * Allocate and free Pages.
	 */
	Extent* allocPages(uint pages, ref bool dirty) shared {
		if (unlikely(pages > MaxPagesInLargeAlloc)) {
			return allocHuge(pages);
		}

		auto allocClass = getAllocClass(pages);
		return allocRun(pages, allocClass, ExtentClass.large(), dirty);
	}

	Extent* allocSmallRun(uint pages, uint allocClass, ExtentClass ec) shared {
		bool dirty;
		return allocRun(pages, allocClass, ec, dirty);
	}

	Extent* allocRun(uint pages, uint allocClass, ExtentClass ec,
	                 ref bool dirty) shared {
		assert(0 < pages && pages <= MaxPagesInLargeAlloc,
		       "Invalid page count!");
		assert(allocClass == getAllocClass(pages), "Invalid allocClass!");

		auto mask = uint.max << allocClass;

		version(Symgc_lock_hist) {
			import d.gc.gctime;
			auto lockTimer = GcTimer.begin(GcTimeKind.FillerLock);
			mutex.lock();
			lockTimer.end();
			import d.gc.time;
			holderHist(lastHolder, getMonotonicTime() - lockTimer.start);
			lastHolder = 1;
		} else {
			mutex.lock();
		}

		scope(exit) mutex.unlock();

		return (cast(PageFiller*) &this).allocRunImpl(pages, mask, ec, dirty);
	}

	Extent* allocHuge(uint pages) shared {
		assert(pages > MaxPagesInLargeAlloc, "Invalid page count!");

		uint extraBlocks = (pages - 1) / PagesInBlock;
		pages = modUp(pages, PagesInBlock);

		version(Symgc_lock_hist) {
			import d.gc.gctime;
			auto lockTimer = GcTimer.begin(GcTimeKind.FillerLock);
			mutex.lock();
			lockTimer.end();
			import d.gc.time;
			holderHist(lastHolder, getMonotonicTime() - lockTimer.start);
			lastHolder = 1;
		} else {
			mutex.lock();
		}

		scope(exit) mutex.unlock();

		return (cast(PageFiller*) &this).allocHugeImpl(pages, extraBlocks);
	}

	void freeExtent(ref CachedExtentMap emap, Extent* e) shared {
		assert(e.arenaIndex == arena.index, "Invalid arena!");
		batchFreeExtents(emap, (&e)[0 .. 1]);
	}

	void batchFreeExtents(ref CachedExtentMap emap, Extent*[] extents) shared {
		// FIXME: in contract.
		foreach (e; extents) {
			assert(e.arenaIndex == arena.index, "Invalid arena!");
		}

		// Avoid locking if there is nothing to do.
		if (extents.length == 0) {
			return;
		}

		// Clear the emap.
		foreach (e; extents) {
			emap.clear(e);
		}

		// Free the pages.
		mutex.lock();
		scope(exit) mutex.unlock();
		version(Symgc_lock_hist) lastHolder = 2;

		foreach (e; extents) {
			(cast(PageFiller*) &this).freePagesImpl(e);
		}
	}

	void freePages(Extent* e) shared {
		assert(isAligned(e.address, PageSize), "Invalid extent address!");
		assert(e.arenaIndex == arena.index, "Invalid arena!");

		uint n = e.blockIndex;
		uint pages = modUp(e.npages, PagesInBlock);

		mutex.lock();
		scope(exit) mutex.unlock();
		version(Symgc_lock_hist) lastHolder = 2;

		(cast(PageFiller*) &this).freePagesImpl(e, n, pages);
	}

	/**
	 * GC facilities.
	 */
	void prepareGCCycle(ref CachedExtentMap emap) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(PageFiller*) &this).prepareGCCycleImpl(emap);
	}

	/**
	 * Prepare the mark bits with the program running (a concurrent mark),
	 * one step at a time with the mutex released in between, like the sweep.
	 * The epoch of the collection must have started: extents and blocks
	 * created from then on are born, need no marks, and are skipped.
	 */
	void prepareConcurrent(ref CachedExtentMap emap, ubyte gcCycle) shared {
		auto self = cast(PageFiller*) &this;

		{
			mutex.lock();
			scope(exit) mutex.unlock();

			self.beginPrepareImpl(gcCycle);
		}

		// Paced like the sweep: flat out, the prepare of a big heap slows
		// the thread that allocates for as long as it takes.
		ulong owed = 0;
		while (true) {
			bool more;
			ulong spent;

			{
				mutex.lock();
				scope(exit) mutex.unlockFairly();
				version(Symgc_lock_hist) lastHolder = 3;

				auto tStep = getMonotonicTime();
				more = self.prepareStepImpl(emap);
				spent = getMonotonicTime() - tStep;
			}

			if (!more) {
				break;
			}

			import symgc.thread : sched_yield;
			for (uint i = 0; mutex.hasContenders && i < 64; i++) {
				sched_yield();
			}

			owed = paceSweeper(owed, spent);
		}
	}

	/**
	 * Sweep this filler. The work is done one block at a time, and the mutex
	 * is released between blocks.
	 */
	void collect(ref CachedExtentMap emap, ubyte gcCycle, ref CollectStats stats) shared {
		beginSweep(gcCycle);
		sweepFinalizers(emap, gcCycle);
		finishSweep(emap, gcCycle, stats);
	}

	/**
	 * The sweep of a cycle in three stages, so that the collector can run the
	 * finalizers of all the arenas before any arena releases a slot.
	 */
	void beginSweep(ubyte gcCycle) shared {
		auto self = cast(PageFiller*) &this;

		mutex.lock();
		scope(exit) mutex.unlock();

		self.beginSweepImpl(gcCycle);
	}

	/**
	 * Run the finalizer phases, and stop when the sweep moves on to the next.
	 */
	void sweepFinalizers(ref CachedExtentMap emap, ubyte gcCycle) shared {
		auto self = cast(PageFiller*) &this;

		// Paced and polite like the rest of the sweep: flat out, with the
		// lock changing hands only when a waiter gets lucky, the mutators
		// that need a slab wait for most of the pass.
		ulong owed = 0;
		while (true) {
			ulong spent;

			{
				mutex.lock();
				scope(exit) mutex.unlockFairly();
				version(Symgc_lock_hist) lastHolder = 4;

				if (self.sweepPhase != SweepPhase.DenseFinalize
					    && self.sweepPhase != SweepPhase.SparseFinalize) {
					return;
				}

				auto tStep = getMonotonicTime();
				self.sweepStep(emap, gcCycle, self.sweepStats);
				spent = getMonotonicTime() - tStep;
			}

			import symgc.thread : sched_yield;
			for (uint i = 0; mutex.hasContenders && i < 64; i++) {
				sched_yield();
			}

			owed = paceSweeper(owed, spent);
		}
	}

	void finishSweep(ref CachedExtentMap emap, ubyte gcCycle, ref CollectStats stats) shared {
		auto self = cast(PageFiller*) &this;

		// Mutators may do some of the work too, see `assistSweep`, so the
		// stats of the sweep live in the filler.
		scope(exit) {
			mutex.lock();
			scope(exit) mutex.unlock();

			stats.bytesCollected += self.sweepStats.bytesCollected;
			stats.pagesCommitted += self.sweepStats.pagesCommitted;
			stats.bytesAllocated += self.sweepStats.bytesAllocated;
		}

		/**
		 * Mutators allocate while we sweep and need this lock for new slabs
		 * and large allocations. A plain unlock followed by a lock lets us
		 * barge in again before a waiter wakes up, so hand the lock over.
		 */
		ulong owed = 0;
		while (true) {
			bool more;
			ulong spent;

			{
				mutex.lock();
				scope(exit) mutex.unlockFairly();
				version(Symgc_lock_hist) lastHolder = 5;

				auto tStep = getMonotonicTime();
				more = self.sweepStep(emap, gcCycle, self.sweepStats);
				spent = getMonotonicTime() - tStep;

				version(Symgc_phase_trace) {
					// Longest time the lock was held by one step.
					if (spent > gSweepT[7]) {
						gSweepT[7] = spent;
					}
				}
			}

			if (!more) {
				break;
			}

			/**
			 * A mutator that wants the lock spins in short bursts, and we
			 * would take the lock again before it looks. Let it have it.
			 */
			import symgc.thread : sched_yield;
			for (uint i = 0; mutex.hasContenders && i < 64; i++) {
				sched_yield();
			}

			owed = paceSweeper(owed, spent);
		}
	}

	/**
	 * A sweeper that runs flat out slows the mutators down, a lot more than
	 * its share of the CPU would suggest (measured: a 2 GiB heap, the frame
	 * time of the thread that allocates goes from 0.8 ms to 8 to 10 ms while
	 * the sweep runs). So the sweeper is paced: it sleeps after each step to
	 * stay under `gSweepDutyPercent` of the time, unless the heap is growing
	 * quickly, in which case the sweep must end sooner than the next cycle.
	 *
	 * `owed` is the sleep we did not take yet, to avoid many tiny sleeps.
	 */
	static ulong paceSweeper(ulong owed, ulong spent) {
		auto duty = gSweepDutyPercent;
		if (duty >= 100) {
			return 0;
		}

		if (Arena.computeUsedPageCount() > gSweepGrowthLimit) {
			return 0;
		}

		// Time unit is 100 ns.
		owed += spent * (100 - duty) / duty;
		enum MinSleep = 1000; // 100 us
		if (owed < MinSleep) {
			return owed;
		}

		auto t0 = getMonotonicTime();

		import d.gc.time : sleepMicros;
		sleepMicros(cast(uint) (owed / 10));

		auto slept = getMonotonicTime() - t0;
		return slept >= owed ? 0 : owed - slept;
	}

	/**
	 * Usage stats.
	 */
	@property
	size_t usedPages() shared {
		return usedPageCount.load();
	}

private:
	/**
	 * Allocate and free pages, private implementation.
	 */
	Extent* allocRunImpl(uint pages, uint mask, ExtentClass ec,
	                     ref bool dirty) {
		assert(mutex.isHeld(), "Mutex not held!");

		version(Symgc_lock_hist) {
			import d.gc.time, d.gc.gctime;
			auto t0 = getMonotonicTime();
			scope(exit) segHist(0, getMonotonicTime() - t0);
		}

		auto e = getOrAllocateExtent();
		if (unlikely(e is null)) {
			return null;
		}

		version(Symgc_lock_hist) {
			auto t1 = getMonotonicTime();
			segHist(1, t1 - t0);
		}

		auto block = extractBlock(pages, mask, ec.dense);
		if (unlikely(block is null)) {
			unusedExtents.insert(e);
			return null;
		}

		version(Symgc_lock_hist) {
			auto t2 = getMonotonicTime();
			segHist(2, t2 - t1);
		}

		auto n = block.reserve(pages, dirty);
		registerBlock(block);

		version(Symgc_lock_hist) segHist(4, getMonotonicTime() - t2);

		usedPageCount.fetchAdd(pages);
		version(Symgc_phase_trace) {
			gTracePagesAdded.fetchAdd(pages);
			if (ec.isSlab()) {
				gTraceSlabPages.fetchAdd(pages);
			}
		}

		auto ptr = block.address + n * PageSize;
		e.at(ptr, pages, block, ec);

		// Created while a sweep runs: the sweep must leave it alone.
		e.sweepTag = gSweepCycle.load();
		return e;
	}

	Extent* allocHugeImpl(uint pages, uint extraBlocks) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(pages <= PagesInBlock, "Invalid page count!");

		auto e = getOrAllocateExtent();
		if (unlikely(e is null)) {
			return null;
		}

		auto block = acquireSparseBlock(extraBlocks);
		if (unlikely(block is null)) {
			unusedExtents.insert(e);
			return null;
		}

		bool dirty;
		auto n = block.reserve(pages, dirty);
		registerBlock(block);

		assert(n == 0, "Unexpected page allocated!");
		assert(!dirty, "Huge allocations shouldn't be dirty!");

		auto npages = pages + extraBlocks * PagesInBlock;
		usedPageCount.fetchAdd(npages);
		version(Symgc_phase_trace) {
			gTracePagesGrown.fetchAdd(npages);
			if (npages >= 256) {
				import core.stdc.stdio : fprintf, stderr;
				fprintf(stderr, "gchuge: alloc %u pages\n", npages);
			}
		}

		auto leadSize = extraBlocks * BlockSize;
		auto ptr = block.address - leadSize;
		// need to commit all pages that aren't in the last page.
		import d.gc.memmap;
		pages_commit(ptr, leadSize);

		e.at(ptr, npages, block);
		e.sweepTag = gSweepCycle.load();
		return e;
	}

	void freePagesImpl(Extent* e) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(isAligned(e.address, PageSize), "Invalid extent address!");

		uint n = e.blockIndex;
		uint pages = modUp(e.npages, PagesInBlock);

		freePagesImpl(e, n, pages);
	}

	void freePagesImpl(Extent* e, uint n, uint pages) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(pages > 0 && pages <= PagesInBlock, "Invalid number of pages!");
		assert(n <= PagesInBlock - pages, "Invalid index!");

		// Before the pages can be handed out again.
		gSlabFreeEpoch.fetchAdd(1);

		auto block = e.block;
		unregisterBlock(block);

		block.release(n, pages);
		if (block.empty) {
			releaseBlock(e, block);
		} else {
			/**
			 * The block goes back in its heap before the lock is released
			 * for the region. With the block out of every heap and the lock
			 * dropped, another thread that frees (or grows) an extent of
			 * the same block calls `unregisterBlock` on a block that is
			 * not in a heap, which unlinks a node that is not linked and
			 * leaves a cycle in the heap: the hang seen in the
			 * multi-threaded game, in the pairwise merge of the heap.
			 */
			registerBlock(block);

			// If the extent is larger than a block,
			// we need to release the extra region.
			if (e.npages > PagesInBlock) {
				mutex.unlock();
				scope(exit) mutex.lock();

				regionAllocator.release(e.address, e.npages / PagesInBlock);
			}
		}

		usedPageCount.fetchSub(e.npages);
		version(Symgc_phase_trace) gTracePagesFreed.fetchAdd(e.npages);
		unusedExtents.insert(e);
	}

	/**
	 * Large allocation resizing facilities, private implementation.
	 */
	bool growAlloc(Extent* e, uint index, uint delta) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(PageFiller*) &this).growAllocImpl(e, index, delta);
	}

	bool growAllocImpl(Extent* e, uint index, uint delta) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(delta > 0 && delta < PagesInBlock, "Invalid delta!");
		assert(index > 0 && index <= PagesInBlock - delta, "Invalid index!");

		auto block = e.block;
		unregisterBlock(block);
		scope(success) registerBlock(block);

		if (!block.growAt(index, delta)) {
			return false;
		}

		usedPageCount.fetchAdd(delta);
		version(Symgc_phase_trace) gTracePagesGrown.fetchAdd(delta);
		e.growBy(delta);

		return true;
	}

	bool growHuge(Extent* e, uint extraBlocks, uint pages, uint delta) shared {
		pages = modUp(pages, PagesInBlock);

		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(PageFiller*) &this)
			.growHugeImpl(e, extraBlocks, pages, delta);
	}

	bool growHugeImpl(Extent* e, uint extraBlocks, uint pages, uint delta) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(extraBlocks > 0, "Invalid extraBlocks!");
		assert(pages > 0 && pages <= PagesInBlock, "Invalid pages!");
		assert(delta > 0, "Invalid delta!");

		auto block = e.block;
		assert(!block.dense, "Large must be sparse!");

		if (block.allocCount > 1) {
			// There are allocations after this one in the block.
			return false;
		}

		auto address = block.address;
		if (!regionAllocator.acquireAt(address + BlockSize, extraBlocks)) {
			return false;
		}

		unregisterBlock(block);
		sweepForgetBlock(block);
		sparseBlocks.remove(block);

		auto sweepSerial = block.sweepSerial;
		auto bornEpoch = block.bornEpoch;
		block.at(address + extraBlocks * BlockSize, false);
		block.sweepSerial = sweepSerial;
		block.bornEpoch = bornEpoch;
		sparseBlocks.insert(block);

		bool dirty;
		auto n = block.reserve(pages, dirty);
		registerBlock(block);

		assert(n == 0, "Unexpected page allocated!");
		assert(!dirty, "Huge allocations shouldn't be dirty!");

		usedPageCount.fetchAdd(delta);
		version(Symgc_phase_trace) {
			gTracePagesGrown.fetchAdd(delta);
			if (delta >= 256) {
				import core.stdc.stdio : fprintf, stderr;
				fprintf(stderr, "gchuge: grow by %u pages to %u\n", delta, e.npages + delta);
			}
		}
		e.growBy(delta);

		// Need to commit all pages that were previously uncommitted, but are
		// *before* the final block. This might include pages already committed,
		// but that operation is allowed.
		import d.gc.memmap;
		pages_commit(address, extraBlocks * BlockSize);

		return true;
	}

	void shrinkAlloc(Extent* e, uint index, uint delta) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(PageFiller*) &this).shrinkAllocImpl(e, index, delta);
	}

	void shrinkAllocImpl(Extent* e, uint index, uint delta) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(delta > 0 && delta < PagesInBlock, "Invalid delta!");
		assert(index > 0 && index <= PagesInBlock - delta, "Invalid index!");

		auto block = e.block;
		unregisterBlock(block);
		scope(success) registerBlock(block);

		block.clear(index, delta);
		assert(!block.empty);

		usedPageCount.fetchSub(delta);
		e.shrinkBy(delta);
	}

	/**
	 * BlockDescriptor management.
	 */
	bool refillBlockDescriptors() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (!unusedBlockDescriptors.empty) {
			return true;
		}

		auto page = base.allocMetadataPage();
		if (page.address is null) {
			return false;
		}

		unusedBlockDescriptors = BlockDescriptor.fromPage(page);
		return true;
	}

	BlockDescriptor* getOrAllocateBlockDescriptor() {
		assert(mutex.isHeld(), "Mutex not held!");

		if (!refillBlockDescriptors()) {
			return null;
		}

		return unusedBlockDescriptors.pop();
	}

	/**
	 * Heaps management.
	 */
	auto getFilterPtr(bool dense) {
		return dense ? &denseFilter : &sparseFilter;
	}

	auto getHeaps(bool dense) {
		return dense ? denseHeaps.ptr : sparseHeaps.ptr;
	}

	BlockDescriptor* extractBlock(uint pages, uint mask, bool dense) {
		assert(mutex.isHeld(), "Mutex not held!");

		return dense
			? extractBlockImpl!true(pages, mask)
			: extractBlockImpl!false(pages, mask);
	}

	BlockDescriptor* extractBlockImpl(bool Dense)(uint pages, uint mask) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto filter = getFilterPtr(Dense);
		auto acfilter = *filter & mask;
		if (acfilter == 0) {
			return acquireBlock!Dense();
		}

		auto index = countTrailingZeros(acfilter);
		auto heaps = getHeaps(Dense);

		auto block = heaps[index].pop();
		*filter &= ~(uint(heaps[index].empty) << index);

		assert(block !is null);
		assert(block.dense == Dense);
		return block;
	}

	static uint cappedIndex(BlockDescriptor* block) {
		auto index = block.freeRangeClass;
		if (block.sparse) {
			return index;
		}

		return min!uint(index, 7);
	}

	void unregisterBlock(BlockDescriptor* block) {
		assert(mutex.isHeld(), "Mutex not held!");

		if (block.full) {
			fullBlocks.remove(block);
			return;
		}

		auto index = cappedIndex(block);
		auto filter = getFilterPtr(block.dense);
		auto heaps = getHeaps(block.dense);

		heaps[index].remove(block);
		*filter &= ~(ulong(heaps[index].empty) << index);
	}

	void registerBlock(BlockDescriptor* block) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(!block.empty, "Block is empty!");

		if (block.full) {
			fullBlocks.insert(block);
			return;
		}

		auto index = cappedIndex(block);
		auto filter = getFilterPtr(block.dense);
		auto heaps = getHeaps(block.dense);

		heaps[index].insert(block);
		*filter |= 1 << index;
	}

	auto getAllBlocks(bool dense) {
		return dense ? &denseBlocks : &sparseBlocks;
	}

	BlockDescriptor* acquireDenseBlock() {
		assert(mutex.isHeld(), "Mutex not held!");

		return acquireBlock!true(0);
	}

	BlockDescriptor* acquireSparseBlock(uint extraBlocks = 0) {
		assert(mutex.isHeld(), "Mutex not held!");

		return acquireBlock!false(extraBlocks);
	}

	BlockDescriptor* acquireBlock(bool Dense)(uint extraBlocks = 0) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(!Dense || extraBlocks == 0, "Huge allocations cannot be dense!");

		version(Symgc_lock_hist) {
			import d.gc.time, d.gc.gctime;
			auto tAcq = getMonotonicTime();
			scope(exit) segHist(3, getMonotonicTime() - tAcq);
		}

		if (!refillBlockDescriptors()) {
			return null;
		}

		void* address;
		if (!regionAllocator.acquire(address, extraBlocks)) {
			return null;
		}

		auto block = unusedBlockDescriptors.pop();
		assert(block !is null);

		block.at(address, Dense);

		// Created while a collection runs: there is nothing in it to sweep,
		// and it may not be in the extent map yet.
		block.bornEpoch = gSweepCycle.load();

		getAllBlocks(Dense).insert(block);
		return block;
	}

	void releaseBlock(Extent* e, BlockDescriptor* block) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(block.empty, "Block is not empty!");
		assert(e.block is block, "Invalid Block!");

		// We do not manage this block anymore.
		sweepForgetBlock(block);
		getAllBlocks(block.dense).remove(block);
		unusedBlockDescriptors.insert(block);

		mutex.unlock();
		scope(exit) mutex.lock();

		auto nblocks = alignUp(e.npages, PagesInBlock) / PagesInBlock;
		assert(nblocks <= uint.max);

		auto ptr = alignDown(e.address, BlockSize);
		regionAllocator.release(ptr, nblocks & uint.max);
	}

	/**
	 * Extent and BlockDescriptior allocation.
	 */
	auto getOrAllocateExtent() {
		assert(mutex.isHeld(), "Mutex not held!");

		auto e = unusedExtents.pop();
		if (e !is null) {
			return e;
		}

		{
			mutex.unlock();
			scope(success) mutex.lock();

			auto slot = base.allocSlot();
			if (slot.address is null) {
				goto Exit;
			}

			auto sharedThis = cast(shared(PageFiller)*) &this;
			e = Extent.fromSlot(sharedThis.arena.index, slot);
		}

		unusedExtents.insert(e);

	Exit:
		return unusedExtents.pop();
	}

	/**
	 * GC facilities.
	 */
	struct OutlinedBitmap {
		OutlinedBitmap* next;
		Extent* extent;

		@property
		ulong[] bitmaps() {
			/**
			 * Bitmaps are stored on a page. The OutlinedBitmap lives at
			 * the start of the page, and the bitmaps nimble come next.
			 */
			enum NimbleCount =
				(PageSize - OutlinedBitmap.sizeof) / ulong.sizeof;

			auto ptr = cast(ulong*) (&this + 1);
			return ptr[0 .. NimbleCount];
		}
	}

	ulong[] allocGCBitmap() {
		assert(mutex.isHeld(), "Mutex not held!");

		// Allocate one page.
		bool dirty;
		auto e = allocRunImpl(1, uint.max, ExtentClass.large(), dirty);
		if (unlikely(e is null)) {
			return [];
		}

		if (dirty) {
			import d.gc.memmap;
			pages_zero(e.address, e.size);
		}

		auto ob = cast(OutlinedBitmap*) e.address;
		ob.next = outlinedBitmaps;
		ob.extent = e;

		outlinedBitmaps = ob;
		return ob.bitmaps;
	}

	void beginPrepareImpl(ubyte gcCycle) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(!preparing, "A prepare is already running!");

		prepareEpoch = gSweepCycle.load();
		// Distinct from the serials of the sweep (up to 767) and of the cycle before.
		prepareSerial = cast(ushort) (768 + gcCycle);
		assert(prepareEpoch != 0, "No collection is running!");

		preparing = true;
		prepareNext = denseBlocks.first;
		prepareCurrent = null;
		prepareBitmaps = [];
	}

	/**
	 * Same walk as `nextSweepBlock`, with a cursor of its own, and its own
	 * serial (a prepare is a pass over the blocks like those of the sweep).
	 */
	BlockDescriptor* nextPrepareBlock() {
		assert(mutex.isHeld(), "Mutex not held!");


		while (true) {
			auto b = prepareNext;
			if (b is null || b.sweepSerial == prepareSerial) {
				prepareNext = null;
				return null;
			}

			b.sweepSerial = prepareSerial;
			prepareNext = b.allNext;

			if (b.bornEpoch == prepareEpoch) {
				continue;
			}

			return b;
		}
	}

	bool prepareStepImpl(ref CachedExtentMap emap) {
		assert(mutex.isHeld(), "Mutex not held!");

		if (prepareCurrent is null) {
			prepareCurrent = nextPrepareBlock();
			preparePage = 0;

			if (prepareCurrent is null) {
				// The bitmap pages we did not use stay on the list, and are
				// freed with the others by the sweep.
				preparing = false;
				prepareBitmaps = [];
				return false;
			}
		}

		if (prepareDenseBlock(emap, prepareCurrent, preparePage, SweepStepBudget)) {
			prepareCurrent = null;
		}

		return true;
	}

	/**
	 * `prepareGCCycleImpl` for one dense block, in a step of bounded length,
	 * with the program running. Returns true when the block is done.
	 */
	bool prepareDenseBlock(ref CachedExtentMap emap, BlockDescriptor* block,
	                       ref uint i, ulong budget) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto deadline = getMonotonicTime() + budget;
		auto bem = emap.blockLookup(block.address);

		while (i < PagesInBlock) {
			if (getMonotonicTime() >= deadline) {
				return false;
			}

			i = block.nextAllocatedPage(i);
			if (i >= PagesInBlock) {
				break;
			}

			auto pd = bem.lookup(i);
			auto e = pd.extent;

			// An allocation in flight: born after the epoch started.
			if (e is null) {
				i++;
				continue;
			}

			auto ec = pd.extentClass;
			auto sc = ec.sizeClass;

			import d.gc.slab;
			i += binInfos[sc].npages;

			if (e.sweepTag == prepareEpoch) {
				continue;
			}

			if (ec.supportsInlineMarking) {
				import d.gc.bitmap;
				auto bmp = cast(Bitmap!128*) &e.slabMetadataMarks();
				bmp.clear();
				continue;
			}

			auto nslots = binInfos[sc].nslots;
			auto nimble = alignUp(nslots, 64) / 64;
			if (prepareBitmaps.length < nimble) {
				prepareBitmaps = allocGCBitmap();
			}

			assert(prepareBitmaps.length >= nimble,
			       "Failed to allocate GC bitmaps.");

			e.outlineMarksBuffer = prepareBitmaps.ptr;
			prepareBitmaps = prepareBitmaps[nimble .. prepareBitmaps.length];
		}

		return true;
	}

	void prepareGCCycleImpl(ref CachedExtentMap emap) {
		assert(mutex.isHeld(), "Mutex not held!");

		ulong[] bitmaps;

		for (auto r = denseBlocks.range; !r.empty; r.popFront()) {
			auto block = r.front;
			auto bem = emap.blockLookup(block.address);

			uint i = 0;
			while (i < PagesInBlock) {
				i = block.nextAllocatedPage(i);
				if (i >= PagesInBlock) {
					break;
				}

				auto pd = bem.lookup(i);
				auto e = pd.extent;
				assert(e !is null);

				auto ec = pd.extentClass;
				auto sc = ec.sizeClass;

				/**
				 * Because we might not be touching the first half of the Extent,
				 * we make sure we don't take a miss and use binInfos instead.
				 */
				import d.gc.slab;
				i += binInfos[sc].npages;

				import d.gc.sizeclass;
				if (ec.supportsInlineMarking) {
					import d.gc.bitmap;
					auto bmp = cast(Bitmap!128*) &e.slabMetadataMarks();
					bmp.clear();
					continue;
				}

				auto nslots = binInfos[sc].nslots;
				auto nimble = alignUp(nslots, 64) / 64;
				if (bitmaps.length < nimble) {
					bitmaps = allocGCBitmap();
				}

				assert(bitmaps.length >= nimble,
				       "Failed to allocate GC bitmaps.");

				e.outlineMarksBuffer = bitmaps.ptr;
				bitmaps = bitmaps[nimble .. bitmaps.length];
			}
		}
	}

	/**
	 * A mutator that allocates faster than the sweeper reclaims helps with
	 * the sweep: it does one step, and returns whether there is more to do.
	 */
	package AssistResult assistSweep(ref CachedExtentMap emap) shared {
		auto self = cast(PageFiller*) &this;

		// Finalizers are user code, and it does not run on a thread that
		// is in the middle of an allocation: leave them to the sweeper. A
		// racy look at the phase, to not queue up for the lock of a sweeper
		// that wants it for the next step.
		auto phase = self.sweepPhase;
		if (phase == SweepPhase.DenseFinalize || phase == SweepPhase.SparseFinalize) {
			return AssistResult.Waiting;
		}

		// Another arena may still be running its finalizers.
		import d.gc.extent : gFinalizeStage;
		if (gFinalizeStage.load() != 0) {
			return AssistResult.Waiting;
		}

		mutex.lock();
		scope(exit) mutex.unlockFairly();
		version(Symgc_lock_hist) lastHolder = 6;

		if (self.sweepPhase == SweepPhase.Idle) {
			return AssistResult.Done;
		}

		if (self.sweepPhase == SweepPhase.DenseFinalize
			    || self.sweepPhase == SweepPhase.SparseFinalize) {
			return AssistResult.Waiting;
		}

		// Another thread in the middle of a step counts as waiting.
		if (self.sweepStepping) {
			return AssistResult.Waiting;
		}

		return self.sweepStep(emap, self.sweepGcCycle, self.sweepStats)
			? AssistResult.Worked
			: AssistResult.Done;
	}

	/**
	 * Give the free pages of a block back to the OS, except for a budget of
	 * pages that we keep warm. Returning every free page to the OS right away
	 * makes a program that allocates a lot pay for the system call, and then
	 * for the page faults when it uses the pages again, every cycle: in the
	 * `alloc` benchmark it is 30% of the time.
	 */
	enum MinimizeChunkPages = 16;

	/**
	 * One step of the minimize pass. Returns false when no block is left.
	 * The pages of a block are returned a chunk per step, with the lock
	 * released in between, see `BlockDescriptor.minimizeChunk`.
	 */
	bool minimizeStepImpl(ushort serial) {
		assert(mutex.isHeld(), "Mutex not held!");

		while (minimizeCur is null) {
			auto block = nextSweepBlock(serial);
			if (block is null) {
				return false;
			}

			auto n = block.purgeablePages;
			if (n == 0) {
				continue;
			}

			if (n <= sweepRetain) {
				sweepRetain -= n;
				continue;
			}

			minimizeCur = block;
		}

		if (minimizeCur.minimizeChunk(MinimizeChunkPages) == 0) {
			minimizeCur = null;
		}

		return true;
	}

	/**
	 * Freeing pages can release the mutex for a moment, and the sweeper and
	 * the assisting mutators all drive the same state machine. Only one of
	 * them may be in a step at a time. Returns true if there is more to do,
	 * which includes "someone else is stepping".
	 */
	bool sweepStep(ref CachedExtentMap emap, ubyte gcCycle, ref CollectStats stats) {
		assert(mutex.isHeld(), "Mutex not held!");

		if (sweepPhase == SweepPhase.Idle) {
			return false;
		}

		if (sweepStepping) {
			return true;
		}

		sweepStepping = true;
		scope(exit) sweepStepping = false;

		return sweepStepImpl(emap, gcCycle, stats);
	}

	void beginSweepImpl(ubyte gcCycle) {
		assert(mutex.isHeld(), "Mutex not held!");
		assert(sweepPhase == SweepPhase.Idle, "A sweep is already running!");

		sweepGcCycle = gcCycle;
		sweepEpoch = gSweepCycle.load();
		assert(sweepEpoch != 0, "No collection is running!");
		sweepStats = CollectStats();

		// The heap grows back to the collection target before the next
		// cycle, so there is no point in returning that much to the OS.
		enum MinRetainedPages = 1024;
		sweepRetain = max(MinRetainedPages, gSweepRetainPages);

		/**
		 * Finalizers run before anything is released, see `SweepPhase`.
		 * The bins were emptied while the world was stopped (`cycleStart`).
		 */
		import d.gc.extent : gAnyFinalizers;
		if (gAnyFinalizers.load() == 0) {
			sweepPhase = SweepPhase.DenseScan;
			sweepNext = denseBlocks.first;
			return;
		}

		sweepPhase = SweepPhase.DenseFinalize;
		sweepNext = denseBlocks.first;
	}

	/**
	 * Each pass over the blocks marks the blocks it visits with its own
	 * serial. They must differ from each other, from 0 (a block that no
	 * sweep has seen), and from the serials of the sweep before.
	 */
	static ushort scanSerialOf(ubyte gcCycle) {
		return gcCycle;
	}

	static ushort minimizeSerialOf(ubyte gcCycle) {
		return cast(ushort) (gcCycle + 256);
	}

	static ushort finalizeSerialOf(ubyte gcCycle) {
		return cast(ushort) (gcCycle + 512);
	}

	/**
	 * The ring of all blocks is circular, and new blocks are inserted at its
	 * head, so a pass walks forward from the block that was first when it
	 * started and ends when it meets a block it already visited.
	 *
	 * Blocks created since the collection started are skipped, and marked as
	 * visited so that the walk still ends where it began: they have nothing to
	 * sweep, and may not be in the extent map yet.
	 */
	BlockDescriptor* nextSweepBlock(ushort serial) {
		assert(mutex.isHeld(), "Mutex not held!");

		while (true) {
			auto b = sweepNext;
			if (b is null || b.sweepSerial == serial) {
				sweepNext = null;
				return null;
			}

			b.sweepSerial = serial;
			sweepNext = b.allNext;

			if (b.bornEpoch == sweepEpoch) {
				continue;
			}

			return b;
		}
	}

	/**
	 * A block is about to leave the ring of all blocks, or to be reinitialized.
	 */
	void sweepForgetBlock(BlockDescriptor* block) {
		assert(mutex.isHeld(), "Mutex not held!");

		if (sweepNext is block) {
			sweepNext = block.allNext;
		}

		if (prepareNext is block) {
			prepareNext = block.allNext;
		}

		if (prepareCurrent is block) {
			prepareCurrent = null;
		}

		if (minimizeCur is block) {
			minimizeCur = null;
		}

		// A block that leaves the ring is empty, or about to be reused for a
		// single huge allocation: nothing is left to sweep in it.
		if (sweepCurrent is block) {
			sweepCurrent = null;
		}
	}

	/**
	 * Do one block's worth of sweeping. Returns false when the sweep is over.
	 */
	bool sweepStepImpl(ref CachedExtentMap emap, ubyte gcCycle, ref CollectStats stats) {
		assert(mutex.isHeld(), "Mutex not held!");

		import d.gc.sizeclass;
		auto minimizeSerial = minimizeSerialOf(gcCycle);
		auto finalizeSerial = finalizeSerialOf(gcCycle);

		while (true) {
			final switch (sweepPhase) with(SweepPhase) {
				case Idle:
					return false;

				case DenseFinalize:
					if (sweepCurrent is null) {
						sweepCurrent = nextSweepBlock(finalizeSerial);
						sweepPage = 0;
					}

					if (sweepCurrent is null) {
						sweepPhase = SparseFinalize;
						sweepNext = sparseBlocks.first;
						continue;
					}

					if (finalizeDenseBlock(emap, sweepCurrent, sweepPage, SweepStepBudget, gcCycle)) {
						sweepCurrent = null;
					}

					return true;

				case SparseFinalize:
					if (sweepCurrent is null) {
						sweepCurrent = nextSweepBlock(finalizeSerial);
						sweepPage = 0;
					}

					if (sweepCurrent is null) {
						sweepPhase = DenseScan;
						sweepNext = denseBlocks.first;

						// The other arenas may still be finalizing: nothing
						// is released before all of them are done.
						import d.gc.extent : gFinalizeStage;
						if (gFinalizeStage.load() != 0) {
							return true;
						}

						continue;
					}

					if (finalizeSparseBlock(emap, sweepCurrent, sweepPage, SweepStepBudget, gcCycle)) {
						sweepCurrent = null;
					}

					return true;

				case DenseScan:
					if (sweepCurrent is null) {
						sweepCurrent = nextSweepBlock(gcCycle);
						sweepPage = 0;
					}

					if (sweepCurrent is null) {
						version(Symgc_phase_trace) auto tO0 = getMonotonicTime();
						collectOutlinedBitmaps();
						version(Symgc_phase_trace) gSweepT[2] += getMonotonicTime() - tO0;

						sweepPhase = DenseMinimize;
						sweepNext = denseBlocks.first;
						continue;
					}

					// This may release the block, see `sweepForgetBlock`.
					if (collectDenseBlock(emap, sweepCurrent, sweepPage, SweepStepBudget, gcCycle, stats)) {
						sweepCurrent = null;
					}

					return true;

				case DenseMinimize:
					version(Symgc_phase_trace) auto tM0 = getMonotonicTime();
					if (!minimizeStepImpl(minimizeSerial)) {
						sweepPhase = SparseScan;
						sweepNext = sparseBlocks.first;
						continue;
					}

					version(Symgc_phase_trace) gSweepT[3] += getMonotonicTime() - tM0;
					return true;

				case SparseScan:
					if (sweepCurrent is null) {
						sweepCurrent = nextSweepBlock(gcCycle);
						sweepPage = 0;
					}

					if (sweepCurrent is null) {
						sweepPhase = SparseMinimize;
						sweepNext = sparseBlocks.first;
						continue;
					}

					if (collectSparseBlock(emap, sweepCurrent, sweepPage, SweepStepBudget, gcCycle, stats)) {
						sweepCurrent = null;
					}

					return true;

				case SparseMinimize:
					version(Symgc_phase_trace) auto tM0 = getMonotonicTime();
					if (!minimizeStepImpl(minimizeSerial)) {
						sweepPhase = Idle;
						sweepNext = null;

						version(Symgc_verify) {
							// Every block was visited by the scan and by the
							// minimize pass, or was created during the sweep.
							foreach (ring; [&denseBlocks, &sparseBlocks]) {
								for (auto r = ring.range; !r.empty; r.popFront()) {
									auto s = r.front.sweepSerial;
									assert(s == gcCycle || s == minimizeSerial
										       || r.front.bornEpoch == sweepEpoch,
									       "A block was not swept!");
								}
							}
						}

						return false;
					}

					version(Symgc_phase_trace) gSweepT[6] += getMonotonicTime() - tM0;
					return true;
			}
		}
	}


	/**
	 * Dense collection.
	 */
	void collectOutlinedBitmaps() {
		assert(mutex.isHeld(), "Mutex not held!");

		auto ob = outlinedBitmaps;
		scope(success) outlinedBitmaps = null;

		while (ob !is null) {
			// We could free and then fetch next, because we are the GC,
			// but I'd rather avoid this kind of tricks.
			auto next = ob.next;
			scope(success) ob = next;

			auto e = ob.extent;
			freePagesImpl(e, e.blockIndex, 1);
		}
	}

	/**
	 * Verifier mode (`-version=Symgc_verify`): fill every slot the sweep frees
	 * with the poison byte, so a mutator that still reads a lost object sees
	 * an impossible pointer, and `d.gc.verify.checkSlotOnAlloc` can tell
	 * a write through a dangling pointer when the slot is handed out again.
	 */
	version(Symgc_verify) static
	void poisonEvictedSlots(ulong evicted, int sizeClass, Extent* e, size_t nimbleIndex) {
		import d.gc.slab;
		import d.gc.verify;
		auto slotSize = binInfos[sizeClass].slotSize;
		void* nimbleBase = e.address + (nimbleIndex * 64 * slotSize);

		while (evicted != 0) {
			auto index = countTrailingZeros(evicted);
			poisonSlot(nimbleBase + index * slotSize, slotSize);
			evicted &= (evicted - 1);
		}
	}

	static
	void finalizeSlabNimble(ulong evicted, ulong metadataFlags, int sizeClass,
	                        Extent* e, size_t nimbleIndex) {
		import d.gc.slab;
		auto slotSize = binInfos[sizeClass].slotSize;
		void* nimbleBase = e.address + (nimbleIndex * 64 * slotSize);

		// Objects that got their finalizer after their allocation, which have
		// no room for it in their slot, see `d.gc.late`.
		import d.gc.late;
		if (evicted != 0 && e.hasFinalizers && lateAny()) {
			auto late = evicted;
			while (late != 0) {
				auto index = countTrailingZeros(late);
				late &= late - 1;

				void* ptr = nimbleBase + index * slotSize;
				if (lateRemove(ptr)) {
					import d.gc.hooks;
					__sd_gc_finalize_late(ptr);
				}
			}
		}

		auto toFinalize = evicted & metadataFlags;
		if (toFinalize == 0) {
			return;
		}

		// All set bits in toFinalize have metadata. If no slot of the slab
		// ever had a finalizer, there is nothing to call, and no reason to
		// touch the memory of the dead slots.
		if (!e.hasFinalizers) {
			toFinalize = 0;
		}

		while (toFinalize != 0) {
			auto index = countTrailingZeros(toFinalize);
			void* ptr = nimbleBase + index * slotSize;

			auto metadata = SlotMetadata.fromBlock(ptr, slotSize);
			auto finalizer = metadata.finalizer;
			if (finalizer) {
				import d.gc.hooks;
				__sd_gc_finalize(ptr, slotSize - metadata.freeSpace, finalizer);
			}

			toFinalize &= (toFinalize - 1);
		}

		/**
		 * Clear the metadata of the elements we collected. This is atomic,
		 * because mutators clear and set flags of other slots of the same
		 * slab while we sweep it. One word RMW instead of up to 64 bit clears.
		 */
		auto toClear = evicted & metadataFlags;
		if (toClear != 0) {
			atomicFetchOp!"&"(e.slabMetadataFlags.rawContent[nimbleIndex],
			                  ~toClear);
		}
	}

	/**
	 * Sweep one slab. Returns true if it is empty, in which case the caller
	 * frees it.
	 *
	 * Mutators run during the sweep. They never allocate from a slab that is
	 * not in a bin, and the bins were emptied while the world was stopped, so
	 * nothing is allocated from this slab until we put it back. They can free
	 * into it though (explicit free, thread cache flush): that clears slots
	 * and nothing else, see `Bin.batchFreeImpl`. The steps are:
	 *
	 *  1. Find the dead slots. A slot that is dead now stays dead: nobody
	 *     holds a pointer to it, and only live slots are freed.
	 *  2. Run finalizers and poison, outside of any lock.
	 *  3. Under the bin lock, clear the dead slots (a free may have cleared
	 *     others since step 1), mark the slab swept, and put it back in its
	 *     bin if it has room.
	 */
	bool sweepSlab(Extent* e, int sc, bool supportsMetadata,
	               const(ulong)* marks, uint nimble, ubyte gcCycle,
	               ref CollectStats stats) {
		assert(nimble <= 8, "Too many nimbles!");

		import d.gc.slab;
		auto sharedThis = cast(shared(PageFiller)*) &this;
		auto bin = &sharedThis.arena.bins[sc];
		auto slotSize = binInfos[sc].slotSize;

		/**
		 * No lock for this read: a concurrent free can only clear a bit, and
		 * it only frees live slots, which are marked and so are not in
		 * `evicted` either way.
		 */
		ulong[8] evicted;
		ulong occupancyPreview = 0;
		foreach (j; 0 .. nimble) {
			evicted[j] = e.slabData.rawContent[j] & ~marks[j];
			occupancyPreview |= e.slabData.rawContent[j] & ~evicted[j];
		}

		// Empty slab with no finalizers: metadata dies with the extent; skip
		// per-nimble atomic flag clears.
		const skipFinalize = supportsMetadata && !e.hasFinalizers
			&& occupancyPreview == 0;

		foreach (j; 0 .. nimble) {
			if (supportsMetadata && !skipFinalize) {
				finalizeSlabNimble(evicted[j], e.slabMetadataFlags.rawContent[j], sc, e, j);
			}

			version(Symgc_verify) {
				poisonEvictedSlots(evicted[j], sc, e, j);
			}
		}

		// Completely dead slab: no live slots exist so no mutator can free
		// into it, and it is freed back to the filler without touching the bin.
		if (occupancyPreview == 0) {
			uint deadCount = 0;
			foreach (j; 0 .. nimble) {
				deadCount += popCount(evicted[j]);
			}

			stats.bytesCollected += deadCount * slotSize;
			return true;
		}

		bin.mutex.lock();
		scope(exit) bin.mutex.unlock();

		uint count = 0;
		ulong occupancy = 0;
		foreach (j; 0 .. nimble) {
			auto occ = e.slabData.rawContent[j] & ~evicted[j];
			e.slabData.rawContent[j] = occ;
			occupancy |= occ;
			count += popCount(evicted[j]);
		}

		stats.bytesCollected += count * slotSize;
		e.bits += count * Extent.FreeSlotsUnit;
		e.sweepTag = sweepEpoch;

		// The slab is empty.
		if (occupancy == 0) {
			return true;
		}

		auto nfree = e.nfree;
		if (nfree > 0) {
			import d.gc.bin;
			(cast(Bin*) bin).slabs.insert(e);
		}

		stats.bytesAllocated += (binInfos[sc].nslots - nfree) * slotSize;
		stats.pagesCommitted += binInfos[sc].npages;
		return false;
	}

	/**
	 * Run the finalizers of the dead objects of a dense block, see
	 * `SweepPhase`. Nothing is released here: the slots stay allocated, and
	 * `finalizeSlabNimble` clears the flag so the sweep does not call the
	 * finalizer a second time. The arguments are those of `collectDenseBlock`.
	 */
	bool finalizeDenseBlock(ref CachedExtentMap emap, BlockDescriptor* block,
	                        ref uint i, ulong budget, ubyte gcCycle) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto deadline = getMonotonicTime() + budget;
		auto bem = emap.blockLookup(block.address);

		while (i < PagesInBlock) {
			if (getMonotonicTime() >= deadline) {
				return false;
			}

			i = block.nextAllocatedPage(i);
			if (i >= PagesInBlock) {
				break;
			}

			auto pd = bem.lookup(i);
			auto e = pd.extent;

			// An allocation in flight, see collectDenseBlock.
			if (e is null) {
				i++;
				continue;
			}

			auto ec = pd.extentClass;
			auto sc = ec.sizeClass;

			import d.gc.slab;
			i += e.npages;

			// Created after the mark, or no slot ever had a finalizer.
			if (e.sweepTag == sweepEpoch || !ec.supportsMetadata || !e.hasFinalizers) {
				continue;
			}

			auto nimble = alignUp(binInfos[sc].nslots, 64) / 64;
			auto marks = e.getMarksDense();
			foreach (j; 0 .. nimble) {
				auto dead = e.slabData.rawContent[j] & ~marks[j];
				finalizeSlabNimble(dead, e.slabMetadataFlags.rawContent[j], sc, e, j);
			}
		}

		return true;
	}

	/**
	 * The same for a sparse block: sparse slabs, and large extents.
	 */
	bool finalizeSparseBlock(ref CachedExtentMap emap, BlockDescriptor* block,
	                         ref uint i, ulong budget, ubyte gcCycle) {
		assert(mutex.isHeld(), "Mutex not held!");

		auto deadline = getMonotonicTime() + budget;
		auto bem = emap.blockLookup(block.address);

		while (i < PagesInBlock) {
			if (getMonotonicTime() >= deadline) {
				return false;
			}

			i = block.nextAllocatedPage(i);
			if (i >= PagesInBlock) {
				break;
			}

			auto pd = bem.lookup(i);
			auto e = pd.extent;
			if (e is null) {
				i++;
				continue;
			}

			auto npages = e.npages;
			auto ec = pd.extentClass;
			if (ec.isLarge()) {
				// Make sure we handle huge extents correctly.
				npages = modUp(npages, PagesInBlock);
			}

			scope(success) i += npages;

			if (e.sweepTag == sweepEpoch) {
				continue;
			}

			if (ec.isLarge()) {
				if (e.isMarkedLarge(gcCycle)) {
					continue;
				}

				auto f = e.finalizer;
				if (f !is null) {
					import d.gc.hooks;
					__sd_gc_finalize(e.address, e.usedCapacity, f);
					e.setFinalizer(null);
				}

				continue;
			}

			if (!e.hasFinalizers) {
				continue;
			}

			auto marks = e.getMarksSparse(gcCycle);
			auto dead = e.slabData.rawContent[0] & ~marks;
			finalizeSlabNimble(dead, e.slabMetadataFlags.rawContent[0], ec.sizeClass, e, 0);
		}

		return true;
	}

	/**
	 * `GC.runFinalizers`: run the finalizers of the allocations of this filler
	 * whose destructor lies in `segment` (a library that is being unloaded),
	 * and forget them. Nothing is freed: the memory goes back to the heap when
	 * the objects are collected, without a second finalization. Run with no
	 * collection going on, see `Collector.runFinalizers`.
	 *
	 * A slot that was freed and is still in a thread's bin looks allocated
	 * from here; its finalizer is cleared when the slot is freed again.
	 */
	package void runFinalizersInSegment(ref CachedExtentMap emap,
	                                    const(void)[] segment) shared {
		auto self = cast(PageFiller*) &this;

		mutex.lock();
		scope(exit) mutex.unlock();

		for (auto r = self.denseBlocks.range; !r.empty; r.popFront()) {
			self.runBlockFinalizers(emap, r.front, segment);
		}

		for (auto r = self.sparseBlocks.range; !r.empty; r.popFront()) {
			self.runBlockFinalizers(emap, r.front, segment);
		}
	}

	void runBlockFinalizers(ref CachedExtentMap emap, BlockDescriptor* block,
	                        const(void)[] segment) {
		assert(mutex.isHeld(), "Mutex not held!");

		import d.gc.hooks, d.gc.slab;
		auto bem = emap.blockLookup(block.address);

		uint i = 0;
		while (i < PagesInBlock) {
			i = block.nextAllocatedPage(i);
			if (i >= PagesInBlock) {
				break;
			}

			auto pd = bem.lookup(i);
			auto e = pd.extent;
			if (e is null) {
				i++;
				continue;
			}

			auto ec = pd.extentClass;
			auto npages = e.npages;
			if (ec.isLarge()) {
				npages = modUp(npages, PagesInBlock);
			}

			i += npages;

			if (ec.isLarge()) {
				auto f = e.finalizer;
				auto size = e.usedCapacity;
				if (f !is null && __sd_gc_has_finalizer_in_segment(e.address, size, f, segment)) {
					// Forget it first: an Error from the finalizer goes up.
					e.setFinalizer(null);
					__sd_gc_finalize_from_gc(e.address, size, f);
				}

				continue;
			}

			if (!ec.supportsMetadata || !e.hasFinalizers) {
				continue;
			}

			auto sc = ec.sizeClass;
			auto slotSize = binInfos[sc].slotSize;
			auto nimble = alignUp(binInfos[sc].nslots, 64) / 64;
			foreach (j; 0 .. nimble) {
				auto live = e.slabData.rawContent[j] & e.slabMetadataFlags.rawContent[j];
				while (live != 0) {
					auto index = countTrailingZeros(live);
					live &= live - 1;

					void* ptr = e.address + (j * 64 + index) * slotSize;
					auto metadata = SlotMetadata.fromBlock(ptr, slotSize);
					auto f = metadata.finalizer;
					if (f is null) {
						continue;
					}

					auto size = slotSize - metadata.freeSpace;
					if (!__sd_gc_has_finalizer_in_segment(ptr, size, f, segment)) {
						continue;
					}

					metadata.clearFinalizer();
					__sd_gc_finalize_from_gc(ptr, size, f);
				}
			}
		}
	}

	/**
	 * Sweep the dense slabs of a block, starting at page `i`, for no longer
	 * than `budget` (the sweep holds the lock, and a mutator that wants it
	 * waits for the rest of our step). Returns true when the block is done.
	 * When it returns false, `i` is where to resume.
	 */
	bool collectDenseBlock(ref CachedExtentMap emap, BlockDescriptor* block,
	                       ref uint i, ulong budget, ubyte gcCycle,
	                       ref CollectStats stats) {
		assert(mutex.isHeld(), "Mutex not held!");

		Extent*[PagesInBlock] deadExtents = void;
		uint ndead = 0;
		auto tD0 = getMonotonicTime();
		auto deadline = tD0 + budget;

		bool done = true;
		{
			auto bem = emap.blockLookup(block.address);

			while (i < PagesInBlock) {
				if (getMonotonicTime() >= deadline) {
					done = false;
					break;
				}

				i = block.nextAllocatedPage(i);
				if (i >= PagesInBlock) {
					break;
				}

				auto pd = bem.lookup(i);
				auto e = pd.extent;

				/**
				 * A thread reserved this page (under the lock we hold) but
				 * has not registered its extent in the map yet. It was born
				 * after the mark: leave it alone, one page at a time as we
				 * do not know how long the run is.
				 */
				if (e is null) {
					i++;
					continue;
				}

				assert(e.isSlab());

				auto ec = pd.extentClass;
				auto sc = ec.sizeClass;

				assert(ec.dense);

				auto npages = e.npages;
				i += npages;

				import d.gc.slab;
				auto nslots = binInfos[sc].nslots;
				auto nimble = alignUp(nslots, 64) / 64;

				// Created after the mark: nothing to sweep. It is not counted
				// in the stats either: they estimate what survived, which
				// sets the next collection target.
				if (e.sweepTag == sweepEpoch) {
					continue;
				}

				ulong* bmp = e.getMarksDenseAndClearOutlines();
				assert(bmp !is null);

				if (sweepSlab(e, sc, ec.supportsMetadata, bmp, cast(uint) nimble, gcCycle, stats)) {
					deadExtents[ndead++] = e;
				}
			}
		}

		version(Symgc_phase_trace) auto tD1 = getMonotonicTime();

		// Freeing the last extent of the block releases the block itself,
		// so nothing may touch it after this point.
		if (ndead > 0) {
			gSlabFreeEpoch.fetchAdd(1);
			unregisterBlock(block);
			size_t freedPages = 0;

			foreach (k; 0 .. ndead - 1) {
				auto de = deadExtents[k];
				emap.clear(de);
				block.release(de.blockIndex, de.npages);
				freedPages += de.npages;
				unusedExtents.insert(de);
			}

			auto lastE = deadExtents[ndead - 1];
			emap.clear(lastE);
			block.release(lastE.blockIndex, lastE.npages);
			freedPages += lastE.npages;

			if (block.empty) {
				releaseBlock(lastE, block);
			} else {
				registerBlock(block);
			}

			usedPageCount.fetchSub(freedPages);
			version(Symgc_phase_trace) gTracePagesFreed.fetchAdd(freedPages);
			unusedExtents.insert(lastE);
		}

		version(Symgc_phase_trace) {
			gSweepT[0] += tD1 - tD0;
			gSweepT[1] += getMonotonicTime() - tD1;
		}
		return done;
	}

	/**
	 * Sparse collection, see `collectDenseBlock` for the arguments.
	 */
	bool collectSparseBlock(ref CachedExtentMap emap, BlockDescriptor* block,
	                        ref uint i, ulong budget, ubyte gcCycle,
	                        ref CollectStats stats) {
		assert(mutex.isHeld(), "Mutex not held!");

		Extent*[PagesInBlock] deadExtents = void;
		uint ndead = 0;
		auto tS0 = getMonotonicTime();
		auto deadline = tS0 + budget;

		bool done = true;
		{
			auto bem = emap.blockLookup(block.address);

			while (i < PagesInBlock) {
				if (getMonotonicTime() >= deadline) {
					done = false;
					break;
				}

				i = block.nextAllocatedPage(i);
				if (i >= PagesInBlock) {
					break;
				}

				auto pd = bem.lookup(i);
				auto e = pd.extent;

				// An allocation in flight, see collectDenseBlock.
				if (e is null) {
					i++;
					continue;
				}

				auto npages = e.npages;
				scope(success) i += npages;

				auto ec = pd.extentClass;

				// Created after the mark: nothing to sweep, nor to count.
				if (e.sweepTag == sweepEpoch) {
					continue;
				}

				if (ec.isLarge()) {
					// Make sure we handle huge extents correctly.
					npages = modUp(npages, PagesInBlock);

					if (e.isMarkedLarge(gcCycle)) {
						// It's alive.
						stats.pagesCommitted += e.npages;
						continue;
					}

					// We have not marked this extent this cycle.
					auto f = e.finalizer;
					if (f !is null) {
						import d.gc.hooks;
						__sd_gc_finalize(e.address, e.usedCapacity, f);
					}

					stats.bytesCollected += e.npages;
					deadExtents[ndead++] = e;
					continue;
				}

				// Sparse slabs have at most 64 slots: one nimble.
				ulong[1] marks;
				marks[0] = e.getMarksSparse(gcCycle);

				if (sweepSlab(e, ec.sizeClass, true, marks.ptr, 1, gcCycle, stats)) {
					deadExtents[ndead++] = e;
				}
			}
		}

		version(Symgc_phase_trace) auto tS1 = getMonotonicTime();
		if (ndead > 0) {
			// Huge extents (> PagesInBlock) may unlock mutex to release
			// extra regions; handle them via freeExtentLocked if present.
			bool anyHuge = false;
			foreach (k; 0 .. ndead) {
				if (unlikely(deadExtents[k].npages > PagesInBlock)) {
					anyHuge = true;
					break;
				}
			}

			if (unlikely(anyHuge)) {
				foreach (k; 0 .. ndead) {
					freeExtentLocked(emap, deadExtents[k]);
				}
			} else {
				gSlabFreeEpoch.fetchAdd(1);
				unregisterBlock(block);
				size_t freedPages = 0;

				foreach (k; 0 .. ndead - 1) {
					auto de = deadExtents[k];
					emap.clear(de);
					block.release(de.blockIndex, de.npages);
					freedPages += de.npages;
					unusedExtents.insert(de);
				}

				auto lastE = deadExtents[ndead - 1];
				emap.clear(lastE);
				block.release(lastE.blockIndex, lastE.npages);
				freedPages += lastE.npages;

				if (block.empty) {
					releaseBlock(lastE, block);
				} else {
					registerBlock(block);
				}

				usedPageCount.fetchSub(freedPages);
				version(Symgc_phase_trace) gTracePagesFreed.fetchAdd(freedPages);
				unusedExtents.insert(lastE);
			}
		}
		version(Symgc_phase_trace) {
			gSweepT[4] += tS1 - tS0;
			gSweepT[5] += getMonotonicTime() - tS1;
		}
		return done;
	}

	void freeExtentLocked(ref CachedExtentMap emap, Extent* e) {
		assert(isAligned(e.address, PageSize), "Invalid extent address!");

		emap.clear(e);
		freePagesImpl(e);
	}

	/**
	 * Immediately minimize all blocks (dense and sparse) by returning all
	 * free dirty pages to the OS via pages_purge, ignoring sweepRetain.
	 * Returns total number of pages purged to the OS.
	 */
	package size_t minimizeAll() shared {
		auto self = cast(PageFiller*) &this;
		mutex.lock();
		scope(exit) mutex.unlock();
		version(Symgc_lock_hist) lastHolder = 6;

		size_t purgedPages = 0;
		foreach (ring; [&self.denseBlocks, &self.sparseBlocks]) {
			for (auto r = ring.range; !r.empty; r.popFront()) {
				auto b = r.front;
				if (b !is null) {
					purgedPages += b.minimize();
				}
			}
		}

		return purgedPages;
	}
}

@"allocPages" unittest {
	import d.gc.arena;
	shared Arena arena;

	auto base = &arena.base;
	scope(exit) arena.base.clear();

	import d.gc.region;
	shared RegionAllocator regionAllocator;
	regionAllocator.base = base;

	auto filler = &arena.filler;
	filler.regionAllocator = &regionAllocator;

	size_t expectedUsedPages = 0;

	void checkFreePages(Extent* e) {
		filler.freePages(e);
		expectedUsedPages -= e.npages;
		assert(filler.usedPages == expectedUsedPages);
	}

	auto checkAllocPage(uint pages, bool clean) {
		bool dirty;
		auto e = filler.allocPages(pages, dirty);

		assert(e !is null);
		assert(e.npages == pages);
		assert(dirty == !clean);

		expectedUsedPages += pages;
		assert(filler.usedPages == expectedUsedPages);

		return e;
	}

	auto e0 = checkAllocPage(1, true);
	auto e1 = checkAllocPage(2, true);
	assert(e1.address is e0.address + e0.size);

	auto e0Addr = e0.address;
	checkFreePages(e0);

	// Do not reuse the free slot is there is no room.
	auto e2 = checkAllocPage(3, true);
	assert(e2.address is e1.address + e1.size);

	// But do reuse that free slot if there isn't.
	auto e3 = checkAllocPage(1, false);
	assert(e3.address is e0Addr);

	// Free everything.
	checkFreePages(e1);
	checkFreePages(e2);
	checkFreePages(e3);

	// Check a wide range of sizes.
	foreach (pages; 1 .. 2 * PagesInBlock) {
		auto e = checkAllocPage(pages, true);
		checkFreePages(e);
	}
}

@"allocHuge" unittest {
	import d.gc.arena;
	shared Arena arena;

	auto base = &arena.base;
	scope(exit) arena.base.clear();

	import d.gc.region;
	shared RegionAllocator regionAllocator;
	regionAllocator.base = base;

	auto filler = &arena.filler;
	filler.regionAllocator = &regionAllocator;

	size_t expectedUsedPages = 0;

	void checkFreePages(Extent* e) {
		filler.freePages(e);
		expectedUsedPages -= e.npages;
		assert(filler.usedPages == expectedUsedPages);
	}

	auto checkAllocPage(uint pages, bool clean, bool huge) {
		bool dirty;
		auto e = filler.allocPages(pages, dirty);

		assert(e !is null);
		assert(e.npages == pages);
		assert(dirty == !clean);

		expectedUsedPages += pages;
		assert(filler.usedPages == expectedUsedPages);

		assert(e.isHuge() == huge);
		return e;
	}

	enum uint AllocSize = PagesInBlock + 1;

	// Allocate a huge extent.
	auto e0 = checkAllocPage(AllocSize, true, true);

	// Free the huge extent.
	auto e0Addr = e0.address;
	checkFreePages(e0);

	// Reallocating the same run will yield the same memory back.
	e0 = checkAllocPage(AllocSize, true, true);
	assert(e0.address is e0Addr);

	// Allocate one page on the borrowed block.
	auto e1 = checkAllocPage(1, true, false);
	assert(e1.address is e0.address + e0.size);

	// Now, freeing the huge extent will leave a page behind.
	checkFreePages(e0);

	// Allocating another huge extent will use a new range.
	auto e2 = checkAllocPage(AllocSize, true, true);
	assert(e2.address is alignUp(e1.address, BlockSize));

	// Allocating new small extents fill the borrowed page.
	auto e3 = checkAllocPage(1, false, false);
	assert(e3.address is alignDown(e1.address, BlockSize));

	// But allocating just the right size will reuse the region.
	auto e4 = checkAllocPage(PagesInBlock, true, true);
	assert(e4.address is e0Addr);

	// Free everything.
	checkFreePages(e1);
	checkFreePages(e2);
	checkFreePages(e3);
	checkFreePages(e4);

	// Check boundaries.
	auto e5 = checkAllocPage(MaxPagesInLargeAlloc, true, false);
	auto e6 = checkAllocPage(MaxPagesInLargeAlloc + 1, true, true);

	checkFreePages(e5);
	checkFreePages(e6);
}
