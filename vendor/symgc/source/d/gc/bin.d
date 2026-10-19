module d.gc.bin;

import d.gc.arena;
import d.gc.emap;
import d.gc.page;
import d.gc.slab;
import d.gc.spec;

import symgc.intrinsics;

/**
 * A bin is used to keep track of runs of a certain
 * size class. There is one bin per small size class.
 */
struct Bin {
	import d.sync.mutex;
	shared Mutex mutex;

	// XXX: We might want to consider targeting Extents
	// on old blocks instead of just address.
	import d.gc.extent;
	PriorityExtentHeap slabs;

	void** batchAllocate(
		shared(PageFiller)* filler,
		ref CachedExtentMap emap,
		ubyte sizeClass,
		void** top,
		void** bottom,
		void** requested,
		size_t slotSize,
	) shared {
		import d.gc.sizeclass;
		assert(isSmallSizeClass(sizeClass), "Invalid size class!");
		assert(&filler.arena.bins[sizeClass] is &this,
		       "Invalid arena or sizeClass!");
		assert(slotSize == binInfos[sizeClass].slotSize, "Invalid slot size!");

		assert(bottom < top, "Invalid stack boundaries!");
		assert((top - bottom) < uint.max, "Invalid stack size!");

		assert(bottom < requested && requested <= top,
				"Invalid requested slot count!");

		/**
		 * When we run out of slab with free space, we allocate a fresh slab.
		 * However, while we do so, another thread may have returned slabs to
		 * the bin, so we might end up not using our fresh slab.
		 */
		Extent* freshSlab = null;

		/**
		 * Allocating fresh slab might fail, for instance if the system
		 * runs out of memory. Before we attempt to allocate one, we make
		 * sure we made progress since the last attempt.
		 */
		bool progressed = true;

		/**
		 * We insert from the bottom up!
		 */
		auto insert = bottom;

		Refill: {
			version(Symgc_lock_hist) {
				import d.gc.gctime;
				auto lockTimer = GcTimer.begin(GcTimeKind.BinLock);
				mutex.lock();
				lockTimer.end();
			} else {
				mutex.lock();
			}

			scope(exit) mutex.unlock();

			auto slabs = &(cast(Bin*) &this).slabs;

			while (insert !is top) {
				assert(insert < top, "Insert out of bounds!");

				auto e = slabs.top;
				if (unlikely(e is null)) {
					if (freshSlab !is null) {
						/**
						 * We have a fresh slab, use it! It may have been made
						 * before a collection started its epoch and reach the
						 * bin after the bins were emptied. It is new and empty:
						 * born in the epoch, so nothing marks it or sweeps it.
						 */
						import d.gc.extent : gSweepCycle;
						auto epoch = gSweepCycle.load();
						if (unlikely(epoch != 0 && freshSlab.sweepTag != epoch)) {
							freshSlab.sweepTag = epoch;
						}

						uint nfill = (top - insert) & uint.max;
						insert = freshSlab.batchAllocate(insert, nfill, slotSize);
						if (freshSlab.nfree > 0) {
							slabs.insert(freshSlab);
						}

						freshSlab = null;
						progressed = true;
						continue;
					}

					if (progressed) {
						// Let's go fetch a new fresh slab.
						goto FreshSlab;
					}

					break;
				}

				assert(e.nfree > 0);
				uint nfill = (top - insert) & uint.max;
				insert = e.batchAllocate(insert, nfill, slotSize);
				assert(bottom <= insert && insert <= top);

				progressed = true;

				// If the slab is not full, we are done.
				if (e.nfree > 0) {
					break;
				}

				// The slab is full, remove from the heap.
				slabs.remove(e);
				continue;
			}
		}

		if (freshSlab !is null) {
			filler.freeExtent(emap, freshSlab);
		}

		return insert;

	FreshSlab:
		assert(insert !is top);
		assert(freshSlab is null);
		assert(progressed);

		/**
		 * We want to avoid leaving partially filled slabs behind us,
		 * so, before allocating a new slab, we make sure that it'll
		 * either be required to meet the requested number of slot,
		 * or that it'll be completely filled.
		 */
		assert(bottom <= insert && insert < top, "Invalid insertion point!");
		auto navailable = top - insert;
		auto nslots = binInfos[sizeClass].nslots;
		if (requested <= insert && navailable <= nslots) {
			return insert;
		}

		version(Symgc_lock_hist) {
			import d.gc.gctime;
			auto slabTimer = GcTimer.begin(GcTimeKind.FreshSlab);
			freshSlab = filler.allocSlab(emap, sizeClass);
			slabTimer.end();
		} else {
			freshSlab = filler.allocSlab(emap, sizeClass);
		}

		assert(freshSlab is null || freshSlab.nfree == nslots);

		progressed = false;
		goto Refill;
	}

	uint batchFree(inout(void)*[] worklist, PageDescriptor* pds,
	               Extent** dallocSlabs, ref uint ndalloc) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Bin*) &this)
			.batchFreeImpl(worklist, pds, dallocSlabs, ndalloc);
	}

private:
	uint batchFreeImpl(inout(void)*[] worklist, PageDescriptor* pds,
	                   Extent** dallocSlabs, ref uint ndalloc) {
		// FIXME: in contract.
		assert(mutex.isHeld(), "Mutex not held!");
		assert(worklist.length > 0, "Worklist is empty!");

		uint ndeferred = 0;

		auto a = pds[0].arenaIndex;
		auto ec = pds[0].extentClass;
		auto bi = binInfos[ec.sizeClass];
		auto nslots = bi.nslots;

		foreach (i, ptr; worklist) {
			auto pd = pds[i];

			// This isn't the right arena, move on to the next slot.
			if (pd.arenaIndex != a) {
				worklist[ndeferred] = ptr;
				pds[ndeferred] = pd;
				ndeferred++;
				continue;
			}

			auto e = pd.extent;
			assert(e.contains(ptr), "ptr not in the Extent!");

			auto se = SlabEntry(pd, ptr);
			assert(se.computeAddress() is ptr,
			       "ptr does not point to the start of the slot!");

			e.free(se.index);

			/**
			 * The sweep has not visited this slab yet: it is not in the
			 * bin, and the sweep will decide what to do with it, including
			 * inserting it, or freeing it if it is empty. Doing it here
			 * would insert it twice, or free it from under the sweep.
			 */
			if (unlikely(e.isUnswept)) {
				continue;
			}

			auto nfree = e.nfree;
			if (nfree == nslots) {
				// If we only had one slot, we never got added to the heap.
				if (nslots > 1) {
					slabs.remove(e);
				}

				dallocSlabs[ndalloc++] = e;
				continue;
			}

			if (nfree == 1) {
				// Newly non empty.
				assert(nslots > 1);
				slabs.insert(e);
			}
		}

		return ndeferred;
	}

/**
 * GC facilities.
 */
package:
	void clearForCollection() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(PriorityExtentHeap*) &slabs).clear();
	}

	bool clearLocked() shared {
		assert(mutex.isHeld(), "Mutex not held!");

		auto heap = cast(PriorityExtentHeap*) &slabs;
		auto wasActive = !heap.empty;
		heap.clear();
		return wasActive;
	}

	/**
	 * Put a fresh slab in the bin before the program asks for one. A
	 * collection that starts empties the bins, and the program would then
	 * have to make a slab for each size class it uses, all in its next
	 * frame. Called by the collector thread, with the epoch started: the slab
	 * is born in it, like any slab made from now on.
	 */
	void prewarm(shared(PageFiller)* filler, ref CachedExtentMap emap, ubyte sizeClass) shared {
		auto fresh = filler.allocSlab(emap, sizeClass);
		if (fresh is null) {
			return;
		}

		import d.gc.extent : gSweepCycle;
		auto epoch = gSweepCycle.load();

		mutex.lock();
		scope(exit) mutex.unlock();

		if (epoch != 0 && fresh.sweepTag != epoch) {
			fresh.sweepTag = epoch;
		}

		(cast(PriorityExtentHeap*) &slabs).insert(fresh);
	}

	void combineAfterCollection(ref PriorityExtentHeap cSlabs) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(PriorityExtentHeap*) &slabs).combine(cSlabs);
	}

	/**
	 * Defragment the bin: inspect all cached slabs in `slabs` heap.
	 * Slabs that have become completely free (nfree == nslots) are
	 * removed from the bin and returned to the page filler via `batchFreeExtents`,
	 * reclaiming the block pages so they can be purged to the OS.
	 * Returns the number of freed extents.
	 */
	size_t defrag(ref CachedExtentMap emap, shared(PageFiller)* filler) shared {
		Extent*[64] retainBuf = void;
		size_t retainCount = 0;
		Extent*[64] freedBuf = void;
		size_t freedCount = 0;

		{
			mutex.lock();
			scope(exit) mutex.unlock();

			auto self = cast(Bin*) &this;
			auto heap = cast(PriorityExtentHeap*) &slabs;
			if (heap.empty) {
				return 0;
			}

			while (!heap.empty) {
				auto e = heap.pop();
				if (e.nfree == e.nslots && freedCount < freedBuf.length) {
					freedBuf[freedCount++] = e;
				} else {
					if (retainCount < retainBuf.length) {
						retainBuf[retainCount++] = e;
					} else {
						heap.insert(e);
						break;
					}
				}
			}

			foreach (i; 0 .. retainCount) {
				heap.insert(retainBuf[i]);
			}
		}

		if (freedCount > 0) {
			filler.batchFreeExtents(emap, freedBuf[0 .. freedCount]);
		}

		return freedCount;
	}
}
