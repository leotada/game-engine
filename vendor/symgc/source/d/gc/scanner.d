module d.gc.scanner;

import symgc.intrinsics;

import d.gc.emap;
import d.gc.hooks;
import d.gc.range;
import d.gc.slab;
import d.gc.spec;
import d.gc.util;
import d.gc.tcache;

void startGCThreads(uint nThreads) {
	(cast(Scanner*)&gScanner).startThreads(nThreads);
}

void cleanupGCThreads() {
	(cast(Scanner*)&gScanner).joinThreads();
}

void markGC(ubyte gcCycle, AddressRange managedSpace) {
	gScanner.mark(gcCycle, managedSpace);
}

/**
 * One round of the concurrent mark, see `Scanner.markRound`.
 */
void markRoundGC(ubyte gcCycle, AddressRange managedSpace,
                 scope void delegate(shared(Scanner)*) seed) {
	gScanner.markRound(gcCycle, managedSpace, seed);
}

// Bytes handed to the scanner, a counter for the phase trace.
version(Symgc_phase_trace) {
	shared ulong gScanBytes;
}

void markBeginGC(ubyte gcCycle, AddressRange managedSpace) {
	gScanner.markBegin(gcCycle, managedSpace);
}

void markSeedGC(scope void delegate(shared(Scanner)*) seed) {
	seed(&gScanner);
}

void markEndGC() {
	gScanner.markEnd();
}

private:
struct ScanningList {
	@disable this(this);
	WorkItem[] worklist;
	int activeThreads;
	uint cursor;
	enum MaxRefill = 4;
	// we want to use the main thread's tcache when reallocating to avoid populating
	// the threadcache of all the scanning threads with stuff.
	ThreadCache* threadCache;

	version(Windows) {
		// The windows implementation uses a similar mechanism to the druntime GC,
		// since most locking schemes do not work on Windows with threads paused.
		// Synchronizing the work list is done via a spinlock and an event system.
		import core.internal.spinlock;
		import core.sync.event;

		shared SpinLock _spinlock;
		Event workReadyEvent;
		Event gcStartedEvent;

		void initialize() {
			this.threadCache = &.threadCache;
			_spinlock = SpinLock(SpinLock.Contention.brief);
			workReadyEvent.initialize(true, false);
			gcStartedEvent.initialize(true, false);
		}

		void addToWorkList(WorkItem[] items) shared {
			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			(cast(ScanningList*) &this).addToWorkListImpl(items);

			(cast(Event*)&workReadyEvent).setIfInitialized();
			(cast(Event*)&gcStartedEvent).setIfInitialized();
		}

		// Note: SpinLock does not provide this information, even though it could.
		bool mutexIsHeld() => true;

		void mainThreadStarted() shared {
			auto w = (cast(ScanningList*) &this);

			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			++w.activeThreads;
		}

		void stopScanningThreads() shared {
			auto w = (cast(ScanningList*) &this);

			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			// need to make the active threads go to -1
			--w.activeThreads;
			(cast(Event*)&gcStartedEvent).setIfInitialized();
		}

		bool waitForGCStart() shared {
			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			auto w = (cast(ScanningList*) &this);

			/**
			* We wait for work to be present in the worklist or the
			* active threads to be negative (meaning the scanning thread should exit)
			*/
			while(!w.hasStarted()) {
				w.gcStartedEvent.reset();
				_spinlock.unlock();
				w.gcStartedEvent.wait();
				_spinlock.lock();
			}

			if (w.activeThreads == -1) {
				// trying to stop GC threads. Wake up anyone else who is waiting.
				w.gcStartedEvent.setIfInitialized();
				return false;
			}

			// this thread now active
			++w.activeThreads;
			return true;
		}

		uint waitForWork(ref WorkItem[MaxRefill] refill) shared {
			_spinlock.lock();
			scope(exit) _spinlock.unlock();

			auto w = (cast(ScanningList*) &this);
			w.activeThreads--;

			/**
			* We wait for work to be present in the worklist.
			* If there is, then we pick it up and start marking.
			*
			* Alternatively, if there is no work to do, and the number
			* of active thread is 0, then we know no more work is coming
			* and we should stop.
			*/
			while(!w.hasWork()) {
				w.workReadyEvent.reset();
				_spinlock.unlock();
				w.workReadyEvent.wait();
				_spinlock.lock();
			}

			if (w.cursor == 0) {
				w.workReadyEvent.setIfInitialized(); // no more work, let everyone know.
				return 0;
			}

			w.activeThreads++;

			uint count = 1;
			uint top = w.cursor;

			refill[0] = w.worklist[top - count];
			auto length = refill[0].length;

			foreach (i; 1 .. min(top, MaxRefill)) {
				auto next = w.worklist[top - count - 1];

				auto nl = length + next.length;
				if (nl > WorkItem.WorkUnit / 2) {
					break;
				}

				count++;
				length = nl;
				refill[i] = next;
			}

			w.cursor = top - count;
			if (w.cursor == 0) {
				// reset the event, no work is ready any more
				w.workReadyEvent.reset();
			}
			return count;
		}
	}
	else
	{
		import d.sync.mutex;
		Mutex _mutex;
		void initialize() {
			this.threadCache = &.threadCache;
		}

		bool mutexIsHeld() => _mutex.isHeld();

		void addToWorkList(WorkItem[] items) shared {
			_mutex.lock();
			scope(exit) _mutex.unlock();

			(cast(ScanningList*) &this).addToWorkListImpl(items);
		}

		void mainThreadStarted() shared {
			auto w = (cast(ScanningList*) &this);

			_mutex.lock();
			scope(exit) _mutex.unlock();

			// ready to receive scan work.
			++w.activeThreads;
		}

		void stopScanningThreads() shared {
			auto w = (cast(ScanningList*) &this);

			_mutex.lock();
			scope(exit) _mutex.unlock();

			// need to make the active threads go to -1
			--w.activeThreads;
		}

		bool waitForGCStart() shared {
			_mutex.lock();
			scope(exit) _mutex.unlock();

			auto w = (cast(ScanningList*) &this);
			_mutex.waitFor(&w.hasStarted);

			if(w.activeThreads == -1) {
				// exiting GC threads
				return false;
			}

			// this thread is now active
			++w.activeThreads;
			return true;
		}

		uint waitForWork(ref WorkItem[MaxRefill] refill) shared {
			_mutex.lock();
			scope(exit) _mutex.unlock();

			auto w = (cast(ScanningList*) &this);
			w.activeThreads--;

			/**
			* We wait for work to be present in the worklist.
			* If there is, then we pick it up and start marking.
			*
			* Alternatively, if there is no work to do, and the number
			* of active thread is 0, then we know no more work is coming
			* and we should stop.
			*/
			_mutex.waitFor(&w.hasWork);

			if (w.cursor == 0) {
				return 0;
			}

			w.activeThreads++;

			uint count = 1;
			uint top = w.cursor;

			refill[0] = w.worklist[top - count];
			auto length = refill[0].length;

			foreach (i; 1 .. min(top, MaxRefill)) {
				auto next = w.worklist[top - count - 1];

				auto nl = length + next.length;
				if (nl > WorkItem.WorkUnit / 2) {
					break;
				}

				count++;
				length = nl;
				refill[i] = next;
			}

			w.cursor = top - count;
			return count;
		}
	}

	void startGCScan() shared {
		// note, we don't take the lock here, because there should be no work before a scan starts, and there should be no work when a scan ends.
		assert(cursor == 0, "starting a GC scan, but still data to scan!");
		this.threadCache = cast(shared)&.threadCache;

		mainThreadStarted(); // indicate the main thread is participating.
	}

	auto hasStarted() {
		return cursor != 0 || activeThreads < 0;
	}

	auto hasWork() {
		return cursor != 0 || activeThreads <= 0;
	}

	void ensureWorklistCapacity(size_t count) {
		assert(mutexIsHeld(), "mutex not held!");
		assert(count < uint.max, "Cannot reserve this much capacity!");
		assert(threadCache !is null, "threadCache is null!");

		if (likely(count <= worklist.length)) {
			return;
		}

		enum MinWorklistSize = 4 * PageSize;

		auto size = count * WorkItem.sizeof;
		if (size < MinWorklistSize) {
			size = MinWorklistSize;
		} else {
			import d.gc.sizeclass;
			size = getAllocSize(count * WorkItem.sizeof);
		}

		version(Symgc_phase_trace) {
			if (size >= (32 << 20)) {
				import core.stdc.stdio : fprintf, stderr;
				fprintf(stderr, "gcworklist grows to %zu MiB (%zu items)\n", size >> 20, size / WorkItem.sizeof);
			}
		}

		version(Posix) {
			/**
			 * The list does not live in the heap: the collector frees
			 * nothing in the heap while a concurrent mark runs, so every
			 * step of the growth (a quarter more each time) stayed until
			 * the next collection, six times the final size (200 MiB for a
			 * list of 32 MiB), and the heap seemed to grow by that much.
			 * A mapping goes back at once, and doubling keeps the copies
			 * few.
			 */
			import d.gc.memmap;
			import core.stdc.string : memcpy;
			size = alignUp(max(size, 2 * worklist.length * WorkItem.sizeof),
			               PageSize);

			auto ptr = pages_map(null, size, PageSize);
			if (unlikely(ptr is null)) {
				import core.stdc.stdio : fprintf, stderr;
				import core.stdc.stdlib : abort;
				fprintf(stderr, "symgc: cannot map %zu bytes for the mark list\n", size);
				abort();
			}

			if (cursor > 0) {
				memcpy(ptr, worklist.ptr, cursor * WorkItem.sizeof);
			}

			if (worklist.ptr !is null) {
				pages_unmap(worklist.ptr, worklist.length * WorkItem.sizeof);
			}
		} else {
			auto ptr = threadCache.realloc(worklist.ptr, size, false);
		}

		worklist = (cast(WorkItem*) ptr)[0 .. size / WorkItem.sizeof];
	}

	void addToWorkListImpl(WorkItem[] items) {
		assert(mutexIsHeld(), "mutex not held!");
		assert(0 < items.length && items.length < uint.max,
		       "Invalid item count!");

		auto capacity = cursor + items.length;
		ensureWorklistCapacity(capacity);

		foreach (item; items) {
			worklist[cursor++] = item;
		}
	}

	void cleanup() shared {
		assert(activeThreads == 0, "Still running threads!");

		// We now done, we can free the worklist.
		version(Posix) {
			if (worklist.ptr !is null) {
				import d.gc.memmap;
				pages_unmap(cast(void*) worklist.ptr,
				            worklist.length * WorkItem.sizeof);
			}
		} else {
			(cast(ThreadCache*)threadCache).free(cast(void*) worklist.ptr);
		}

		worklist = null;
		threadCache = null;
	}
}

package struct Scanner {
private:
	ScanningList work;

	ubyte _gcCycle;
	AddressRange _managedAddressSpace;

	ThreadHandle[] threads;

	/**
	 * Copies of the roots taken at the start pause of a concurrent mark.
	 * The stacks and TLS blocks listed in that pause are read after the world
	 * restarts, and a thread that exits in between unmaps them (glibc keeps
	 * static TLS in the stack mapping). So the pause copies each root range
	 * here and the mark reads the copy. The chunks are kept from one cycle to
	 * the next and reset at each start pause, when no work item refers to them.
	 */
	enum MaxRootChunks = 32;
	enum MinRootChunk = 1024 * 1024;
	void*[MaxRootChunks] rootChunks;
	size_t[MaxRootChunks] rootChunkSizes;
	size_t rootChunkCount;
	size_t rootChunkCurrent;
	size_t rootChunkUsed;

public:

	@property
	AddressRange managedAddressSpace() shared {
		return (cast(Scanner*) &this)._managedAddressSpace;
	}

	@property
	ubyte gcCycle() shared {
		return (cast(Scanner*) &this)._gcCycle;
	}

	private import symgc.thread;
	void startThreads(uint nThreads) {
		if (threads.length != 0) {
			// threads already running.
			return;
		}

		threads = (cast(ThreadHandle*)threadCache.alloc(ThreadHandle.sizeof * nThreads, false, false))[0 .. nThreads];

		work.initialize();
		static void markThreadEntry(void* ctx) {
			import d.gc.tcache;
			threadCache.activateGC(false);

			import d.gc.gctime;
			markGcThread();

			// Background work, like the sweeper: when it shares a core with a
			// mutator, the mutator comes first. A nice value applies to the
			// calling thread only on Linux.
			version(linux) {
				import core.stdc.stdlib : getenv, atoi;
				import core.sys.posix.sys.resource : setpriority, PRIO_PROCESS;
				int nice = 10;
				if (auto env = getenv("SYMGC_MARK_NICE")) {
					nice = atoi(env);
				}
				setpriority(PRIO_PROCESS, 0, nice);
			}

			// Set a flag saying we should not be using our local thread cache.
			// The only allocations/free we should be doing is to resize the work list.
			// Note that scanning threads DO NOT have their stack or TLS scanned,
			// so we can't put any pointers in there that will become garbage.
			threadCache.setIsScanningThread();

			auto scanner = cast(shared(Scanner)*) ctx;

			while(scanner.work.waitForGCStart()) {
				scanner.runMarkFromScanThread();
			}
		}

		// we use a static ThreadRunner because bad things happen if this memory
		// gets collected before the thread can start.
		static ThreadRunner!(typeof(&markThreadEntry)) staticRunner;

		// allocate an array to hold the threads.
		staticRunner.fun = &markThreadEntry;
		staticRunner.arg = cast(void*) &this;
		foreach (ref tid; threads) {
			createGCThread(&tid, &staticRunner);
		}
	}

	void joinThreads() {

		if (threads.length > 0) {
			(cast(shared ScanningList*)&work).stopScanningThreads();
			foreach (tid; threads) {
				joinGCThread(tid);
			}

			// free the thread array
			threadCache.free(threads.ptr);
			threads = null;
		}

		// destroy the work object, it might have OS resources allocated for it.
		destroy(work);
	}

	void mark(ubyte gcCycle, AddressRange managedSpace) shared {
		// set up the address space and the gc cycle. These change every mark phase.
		this._managedAddressSpace = managedSpace;
		this._gcCycle = gcCycle;

		// start the GC
		work.startGCScan();

		// Scan the roots.
		// TODO: this cast is awful, see if we can fix this.
		__sd_gc_global_scan(cast(void delegate(const(void*)[]))&processGlobal);

		// Now send this thread marking!
		runMarkFromMainThread();

		// all work is done, clean up the work list.
		work.cleanup();
	}

	/**
	 * One round of a concurrent mark, run by the GC thread while the program
	 * runs: `seed` puts the roots of the round on the work list, and the
	 * scanning threads and this one drain it. The caller is not a mutator and
	 * has no stack to scan.
	 */
	void markRound(ubyte gcCycle, AddressRange managedSpace,
	               scope void delegate(shared(Scanner)*) seed) shared {
		markBegin(gcCycle, managedSpace);
		seed(&this);
		markEnd();
	}

	/**
	 * A round in two parts, for the start pause: begin, seed with the world
	 * stopped (the threads' stacks are only valid then), restart the world,
	 * and drain with the program running. The scanning threads start on the
	 * work as soon as there is some.
	 */
	void markBegin(ubyte gcCycle, AddressRange managedSpace) shared {
		this._managedAddressSpace = managedSpace;
		this._gcCycle = gcCycle;

		work.startGCScan();
	}

	void markEnd() shared {
		runMarkFromGCThread();
		work.cleanup();
	}

	/**
	 * The pages of a range of the scannable heap that the program wrote since
	 * we last looked. We scan what a write can have changed: the part of each
	 * slot on the page, if the slot is allocated and the mark found it live (or
	 * it was born after the mark started, which has no mark and may point to
	 * anything). Everything else is garbage, or not a pointer holder, and
	 * scanning it only keeps its referents alive for one more cycle.
	 */
	void addDirtyRange(const(void)* start, size_t size) shared {
		import d.gc.tcache;
		auto emap = threadCache.emap;
		auto cycle = _gcCycle;

		import d.gc.extent : gSweepCycle;
		auto epoch = gSweepCycle.load();

		/**
		 * Neighbouring slots are one run: a page of small slots would
		 * otherwise be hundreds of work items, each taking the lock of the
		 * work list (measured: 1.4 s for 28 MiB of dirty pages).
		 */
		size_t runLo = 0;
		size_t runHi = 0;

		void flush() {
			if (runLo < runHi) {
				addToWorkList(makeRange(cast(void*) runLo, cast(void*) runHi));
			}

			runLo = runHi = 0;
		}

		void emit(size_t lo, size_t hi) {
			if (lo != runHi) {
				flush();
				runLo = lo;
			}

			runHi = hi;
		}

		scope(exit) flush();

		size_t end = cast(size_t) start + size;
		for (size_t p = cast(size_t) start & ~(PageSize - 1); p < end; p += PageSize) {
			auto pd = emap.lookup(cast(void*) p);
			auto e = pd.extent;
			if (e is null || !pd.containsPointers) {
				continue;
			}

			auto born = e.sweepTag == epoch;
			auto ec = pd.extentClass;

			// The part of this page that was asked for: all of it for a
			// range of pages, a few cards for a range of cards.
			auto pLo = max(p, cast(size_t) start);
			auto pHi = min(p + PageSize, end);

			if (ec.isLarge()) {
				if (!born && !e.isMarkedLarge(cycle)) {
					continue;
				}

				size_t eaddr = cast(size_t) e.address;
				auto lo = max(pLo, eaddr);
				auto hi = min(pHi, eaddr + e.size);
				if (lo < hi) {
					emit(lo, hi);
				}

				continue;
			}

			// A slab, dense or sparse: find the slots that overlap the page.
			auto bi = binInfos[ec.sizeClass];
			size_t slabBase = p - pd.index * PageSize;
			size_t slotSize = bi.slotSize;

			auto first = (pLo - slabBase) / slotSize;
			auto last = min((pHi - 1 - slabBase) / slotSize, bi.nslots - 1);

			ulong sparseMarks = 0;
			const(ulong)* denseMarks = null;
			if (!born) {
				if (ec.dense) {
					denseMarks = e.getMarksDense();
				} else {
					sparseMarks = e.getMarksSparse(cycle);
				}
			}

			foreach (index; first .. last + 1) {
				if (!e.slabData.valueAt(cast(uint) index)) {
					continue;
				}

				if (!born) {
					auto marked = ec.dense
						? ((denseMarks[index / 64] >> (index % 64)) & 1) != 0
						: ((sparseMarks >> index) & 1) != 0;
					if (!marked) {
						continue;
					}
				}

				size_t slot = slabBase + index * slotSize;
				auto lo = max(pLo, slot);
				auto hi = min(pHi, slot + slotSize);
				if (lo < hi) {
					emit(lo, hi);
				}
			}
		}
	}

	void addToWorkList(WorkItem item) shared {
		work.addToWorkList((&item)[0 .. 1]);
	}

	void processGlobal(const(void*)[] range) shared {
		addToWorkList(range);
	}

	/**
	 * Start of the start pause of a concurrent mark: the copies of the last
	 * cycle are no longer referred to.
	 */
	void resetRootCopies() shared {
		auto t = cast(Scanner*) &this;
		t.rootChunkCurrent = 0;
		t.rootChunkUsed = 0;
	}

	/**
	 * Like `processGlobal`, for the start pause of a concurrent mark: the
	 * range is copied, with the world stopped, and the copy is what the mark
	 * reads once the world runs again.
	 */
	void processGlobalCopy(const(void*)[] range) shared {
		auto t = cast(Scanner*) &this;
		auto bytes = range.length * PointerSize;
		if (bytes == 0) {
			return;
		}

		auto copy = t.rootCopySpace(bytes);
		if (copy is null) {
			// Out of chunks or of memory: the range is read in place, as before.
			addToWorkList(range);
			return;
		}

		import core.stdc.string : memcpy;
		memcpy(copy, range.ptr, bytes);
		addToWorkList((cast(const(void*)*) copy)[0 .. range.length]);
	}

	private void* rootCopySpace(size_t bytes) {
		while (rootChunkCurrent < rootChunkCount) {
			if (rootChunkUsed + bytes <= rootChunkSizes[rootChunkCurrent]) {
				auto p = rootChunks[rootChunkCurrent] + rootChunkUsed;
				rootChunkUsed += bytes;
				return p;
			}

			rootChunkCurrent++;
			rootChunkUsed = 0;
		}

		if (rootChunkCount == MaxRootChunks) {
			return null;
		}

		// A new chunk, twice the last one, and large enough for this range.
		size_t size = rootChunkCount == 0 ? MinRootChunk : 2 * rootChunkSizes[rootChunkCount - 1];
		while (size < bytes) {
			size *= 2;
		}

		void* p = null;
		version(Posix) {
			import core.sys.posix.sys.mman;
			p = mmap(null, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
			if (p == MAP_FAILED) {
				return null;
			}
		} else version(Windows) {
			import core.sys.windows.winbase : VirtualAlloc;
			import core.sys.windows.winnt : MEM_RESERVE, MEM_COMMIT, PAGE_READWRITE;
			p = VirtualAlloc(null, size, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
			if (p is null) {
				return null;
			}
		} else {
			return null;
		}

		rootChunks[rootChunkCount] = p;
		rootChunkSizes[rootChunkCount] = size;
		rootChunkCurrent = rootChunkCount;
		rootChunkCount++;
		rootChunkUsed = bytes;
		return p;
	}

	void addToWorkList(const(void*)[] range) shared {
		// In order to expose some parallelism, we split the range
		// into smaller chunks to be distributed.
		while (range.length > 0) {
			uint count;
			WorkItem[16] units;

			foreach (ref u; units) {
				if (range.length == 0) {
					break;
				}

				count++;
				u = WorkItem.extractFromRange(range);
			}

			work.addToWorkList(units[0 .. count]);
		}
	}

private:

	void runMarkFromMainThread() shared {
		runMarkImpl!true();
	}

	void runMarkFromScanThread() shared {
		runMarkImpl!false();
	}

	/**
	 * The GC thread that runs a concurrent cycle works like the main thread,
	 * but its own stack and TLS are not the program's: it has none to scan.
	 */
	void runMarkFromGCThread() shared {
		runMarkImpl!false();
	}

	void runMarkImpl(bool mainThread)() shared {
		/**
		 * Scan the stack and TLS.
		 *
		 * It may seems counter intuitive that we do so for worker threads
		 * as well, but it turns out to be necessary. NPTL caches resources
		 * necessary to start a thread after a thread exits, to be able to
		 * restart new ones quickly and cheaply.
		 *
		 * Because we start and stop threads during the mark phase, we are
		 * at risk of missing pointers allocated for thread management resources
		 * and corrupting the internal of the standard C library.
		 *
		 * This is NOT good! So we scan here to make sure we don't miss anything.
		 *
		 * Note: this is only relevant if the C malloc calls are replaced with the
		 * GC allocation calls which is not a thing we can do universally. Since
		 * this prospect is dicey, there is no reason to do this, and this allows
		 * us to avoid an extra startup sync.
		 */
		// import d.gc.thread;
		// threadScan(&worker.scan);

		auto worker = Worker(&this);

		static if(mainThread) {
			// on the main thread, scan the stack and TLS of the thread.
			worker.setScanParameters();
			import d.gc.thread;
			threadScan(&worker.scan);
		}

		WorkItem[ScanningList.MaxRefill] refill;

		while (true) {
			auto count = work.waitForWork(refill);
			if (count == 0) {
				// We are done, there is no more work items.
				return;
			}
			// wait until we get work to set the scan parameters (gc cycle and address range).
			worker.setScanParameters();

			foreach (i; 0 .. count) {
				worker.scan(refill[i]);
			}
		}
	}
}

struct LastDenseSlabCache {
	AddressRange slab;
	PageDescriptor pageDescriptor;
	BinInfo bin;

	this(AddressRange slab, PageDescriptor pageDescriptor, BinInfo bin) {
		this.slab = slab;
		this.pageDescriptor = pageDescriptor;
		this.bin = bin;
	}
}

struct Worker {
private:
	shared(Scanner)* scanner;

	// TODO: Use a different caching layer that
	//       can cache negative results.
	CachedExtentMap emap;

	/**
	 * Cold elements that benefit from being kept alive
	 * across scan calls.
	 */
	AddressRange managedAddressSpace;
	ubyte gcCycle;

	// The epoch of the collection, see `Extent._sweepTag`.
	uint epoch;

	LastDenseSlabCache ldsCache;

public:
	this(shared(Scanner)* scanner) {
		this.scanner = scanner;

		import d.gc.tcache;
		this.emap = threadCache.emap;
	}

	void setScanParameters() {
		// set up the scan parameters for this batch of scanning.
		this.managedAddressSpace = scanner.managedAddressSpace;
		this.gcCycle = scanner.gcCycle;

		import d.gc.extent : gSweepCycle;
		this.epoch = gSweepCycle.load();
	}

	void scan(const(void*)[] range) {
		while (range.length > 0) {
			scan(WorkItem.extractFromRange(range));
		}
	}

	void scan(WorkItem item) {
		version(Symgc_phase_trace) {
			import core.atomic : atomicOp;
			atomicOp!"+="(gScanBytes, item.length);
		}

		scanImpl!true(item, ldsCache);
	}

	void scanBreadthFirst(WorkItem item, LastDenseSlabCache cache) {
		scanImpl!false(item, cache);
	}

	void scanImpl(bool DepthFirst)(WorkItem item, LastDenseSlabCache cache) {
		auto ms = managedAddressSpace;

		scope(success) {
			if (DepthFirst) {
				ldsCache = cache;
			}
		}

		// Depth first doesn't really need a worklist,
		// but this makes sharing code easier.
		enum WorkListCapacity = DepthFirst ? 1 : 16;

		uint cursor;
		WorkItem[WorkListCapacity] worklist;

		while (true) {
			auto r = item.range;
			auto current = r.ptr;
			auto top = current + r.length;

			for (; current < top; current++) {
				auto ptr = *current;
				if (!ms.contains(ptr)) {
					// This is not a pointer, move along.
					continue;
				}

				if (cache.slab.contains(ptr)) {
				MarkDense:
					auto base = cache.slab.ptr;
					auto offset = ptr - base;

					auto ldb = cache.bin;
					auto index = ldb.computeIndex(offset);

					auto pd = cache.pageDescriptor;
					assert(pd.extent !is null);
					assert(pd.extent.contains(ptr));

					// Created since the mark started (a concurrent mark):
					// it has no marks, and counts as live.
					if (pd.extent.sweepTag == epoch) {
						continue;
					}

					if (!markDense(pd, index)) {
						continue;
					}

					if (!pd.containsPointers) {
						continue;
					}

					auto slotSize = ldb.slotSize;
					auto i = WorkItem(base + index * slotSize, slotSize);
					if (DepthFirst) {
						scanBreadthFirst(i, cache);
						continue;
					}

					if (likely(cursor < WorkListCapacity)) {
						worklist[cursor++] = i;
						continue;
					}

					scanner.work.addToWorkList(worklist[0 .. WorkListCapacity]);

					cursor = 1;
					worklist[0] = i;
					continue;
				}

				auto aptr = alignDown(ptr, PageSize);
				auto pd = emap.lookup(aptr);

				auto e = pd.extent;
				if (e is null) {
					// We have no mapping here, move on.
					continue;
				}

				// Created since the mark started: live, nothing to mark.
				if (e.sweepTag == epoch) {
					continue;
				}

				auto ec = pd.extentClass;
				if (ec.dense) {
					assert(e !is cache.pageDescriptor.extent);

					auto ldb = binInfos[ec.sizeClass];
					auto lds = AddressRange(aptr - pd.index * PageSize,
					                        ldb.npages * PageSize);

					cache = LastDenseSlabCache(lds, pd, ldb);
					goto MarkDense;
				}

				if (ec.isLarge()) {
					if (!markLarge(pd, gcCycle)) {
						continue;
					}

					/*
					auto capacity = e.usedCapacity;
					/*/
					auto capacity = e.size;
					// */
					if (!pd.containsPointers || capacity < PointerSize) {
						continue;
					}

					auto range = makeRange(e.address, e.address + capacity);

					// Make sure we do not starve ourselves. If we do not have
					// work in advance, then just keep some of it for ourselves.
					if (DepthFirst && cursor == 0) {
						worklist[cursor++] = WorkItem.extractFromRange(range);
					}

					scanner.addToWorkList(range);
					continue;
				}

				auto se = SlabEntry(pd, ptr);
				if (!markSparse(pd, se.index, gcCycle)) {
					continue;
				}

				if (!pd.containsPointers) {
					continue;
				}

				// Make sure we do not starve ourselves. If we do not have
				// work in advance, then just keep some of it for ourselves.
				auto i = WorkItem(se.computeRange());
				if (DepthFirst && cursor == 0) {
					worklist[cursor++] = i;
				} else {
					scanner.addToWorkList(i);
				}
			}

			// In case we reached our limit, we bail. This ensures that
			// we can scan iteratively.
			if (cursor == 0) {
				return;
			}

			item = worklist[--cursor];
		}
	}

private:
	pragma(inline, true)
	static bool markDense(PageDescriptor pd, uint index) {
		auto e = pd.extent;

		/**
		 * /!\ This is not thread safe.
		 *
		 * In the context of concurrent scans, slots might be
		 * allocated/deallocated from the slab while we scan.
		 * It is unclear how to handle this at this time.
		 */
		if (!e.slabData.valueAt(index)) {
			return false;
		}

		auto ec = pd.extentClass;
		return e.markDenseSlot(index);
	}

	pragma(inline, true)
	static bool markSparse(PageDescriptor pd, uint index, ubyte cycle) {
		auto e = pd.extent;
		return e.markSparseSlot(cycle, index);
	}

	pragma(inline, true)
	static bool markLarge(PageDescriptor pd, ubyte cycle) {
		auto e = pd.extent;
		return e.markLarge(cycle);
	}
}

struct WorkItem {
private:
	size_t payload;

	// Verify our assumptions.
	static assert(LgAddressSpace <= 48, "Address space too large!");

	// Useful constants for bit manipulations.
	enum LengthShift = 48;
	enum FreeBits = 8 * PointerSize - LengthShift;

	// Scan parameter.
	enum WorkUnit = 16 * PointerInPage;

public:
	@property
	void* ptr() {
		return cast(void*) (payload & AddressMask);
	}

	@property
	size_t length() {
		auto ptrlen = 1 + (payload >> LengthShift);
		return ptrlen * PointerSize;
	}

	@property
	const(void*)[] range() {
		auto base = cast(void**) ptr;
		return base[0 .. length / PointerSize];
	}

	this(const void* ptr, size_t length) {
		assert(isAligned(ptr, PointerSize), "Invalid ptr!");
		assert(length >= PointerSize, "WorkItem cannot be empty!");

		auto storedLength = length / PointerSize - 1;
		assert(storedLength < (1 << FreeBits), "Invalid length!");

		payload = cast(size_t) ptr;
		payload |= storedLength << LengthShift;
	}

	this(const(void*)[] range) {
		assert(range.length > 0, "WorkItem cannot be empty!");
		assert(range.length <= (1 << FreeBits), "Invalid length!");

		payload = cast(size_t) range.ptr;
		payload |= (range.length - 1) << LengthShift;
	}

	static extractFromRange(ref const(void*)[] range) {
		assert(range.length > 0, "range cannot be empty!");

		enum SplitThresold = 3 * WorkUnit / 2;

		// We use this split strategy as it guarantee that any straggler
		// work item will be between 1/2 and 3/2 work unit.
		if (range.length <= SplitThresold) {
			scope(success) range = [];
			return WorkItem(range);
		}

		scope(success) range = range[WorkUnit .. range.length];
		return WorkItem(range[0 .. WorkUnit]);
	}
}

shared Scanner gScanner;

@"WorkItem" unittest {
	void* stackPtr;
	void* ptr = &stackPtr;

	foreach (i; 0 .. 1 << WorkItem.FreeBits) {
		auto n = i + 1;

		foreach (k; 0 .. PointerSize) {
			auto item = WorkItem(ptr, n * PointerSize + k);
			assert(item.ptr is ptr);
			assert(item.length == n * PointerSize);

			auto range = item.range;
			assert(range.ptr is cast(const(void*)*) ptr);
			assert(range.length == n);

			auto ir = WorkItem(range);
			assert(item.payload == ir.payload);
		}
	}

	enum WorkUnit = WorkItem.WorkUnit;
	enum MaxUnit = 3 * WorkUnit / 2;

	foreach (size; 1 .. MaxUnit + 1) {
		auto range = (cast(const(void*)*) ptr)[0 .. size];
		auto w = WorkItem.extractFromRange(range);
		assert(w.ptr is ptr);
		assert(w.length is size * PointerSize);

		assert(range.length == 0);
	}

	foreach (size; MaxUnit + 1 .. MaxUnit + WorkUnit + 1) {
		auto range = (cast(const(void*)*) ptr)[0 .. size];
		auto w = WorkItem.extractFromRange(range);

		assert(w.ptr is ptr);
		assert(w.length is WorkUnit * PointerSize);

		assert(range.length == size - WorkUnit);

		w = WorkItem.extractFromRange(range);
		assert(w.ptr is ptr + WorkUnit * PointerSize);
		assert(w.length is (size - WorkUnit) * PointerSize);

		assert(range.length == 0);
	}
}
