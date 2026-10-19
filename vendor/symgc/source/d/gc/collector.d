module d.gc.collector;

import d.gc.arena;
import d.gc.emap;
import d.gc.range;
import d.gc.hooks : __sd_gc_global_scan;
import d.gc.scanner : Scanner;
import d.gc.types : ScanDg;
import d.gc.spec;
import d.gc.tcache;
import d.gc.time;
import d.gc.util;
import core.thread.symthread;

struct CollectionInfo {
	size_t usedPages;
	size_t freeBytes;
	size_t pauseTime;
	size_t start;
	size_t stop;
}

// Only the thread that runs a cycle touches it, under the collector lock.
__gshared uint gEpochCounter;

/**
 * What the second half of a cycle (the sweep) needs from the first half.
 */
struct CycleContext {
	ubyte gcCycle;
	size_t threadCount;
	CollectionInfo info;

	// The mark is concurrent: the GC thread does the whole cycle.
	bool concurrent;

	// The kernel stopped tracking writes and the remark marked everything again.
	bool fellBack;

	// Only used by the phase trace.
	ulong pauseStartTime, tStopped, tPrepared, tMarked, tFlushed;
	ulong startPause, remarkPause, concurrentMark;
	ulong[4] remarkParts; // stop, dirty pages, mark, restart
	ulong[3] preamble;    // arm, epoch and bins, prepare
	ulong scanBytesBeforeRemark, scanBytesRemark;
	uint rounds;
	size_t lastRoundPages, remarkPages;
}

/**
 * Ranges of the heap the program wrote, to scan again.
 */
struct DirtyList {
	struct Range {
		const(void)* start;
		size_t size;
	}

	Range* ptr;
	size_t length;
	size_t capacity;

	void clear() {
		length = 0;
	}

	void add(const(void)* start, size_t size) {
		if (length == capacity) {
			import core.stdc.stdlib : realloc;
			auto newCapacity = capacity == 0 ? 1024 : capacity * 2;
			auto p = cast(Range*) realloc(ptr, newCapacity * Range.sizeof);
			assert(p !is null, "Out of memory listing the dirty ranges!");

			ptr = p;
			capacity = newCapacity;
		}

		ptr[length++] = Range(start, size);
	}

	void seed(shared(Scanner)* scanner) {
		foreach (r; ptr[0 .. length]) {
			scanner.addDirtyRange(r.start, r.size);
		}
	}

	void free() {
		import core.stdc.stdlib : free;
		free(ptr);
		ptr = null;
		length = capacity = 0;
	}
}

version(Symgc_phase_trace) {
	// When the concurrent mark started, for the trace lines.
	__gshared ulong gTraceMarkStart;
	// Pages added, freed and added as slabs when the mark started.
	__gshared ulong gTraceAdded0, gTraceFreed0, gTraceSlab0, gTraceGrown0;
}

/**
 * How far the heap may grow past the collection target while the mark runs.
 *
 * A thread that allocates past the hard limit during a mark waits for it
 * (`assistSweep`): it cannot help. A fixed quarter of the target is not enough
 * when the mark is long, as for a heap of a gigabyte or more: the program stalls
 * for as long as the mark has left. The allowance follows what the heap grew by
 * during the last marks, as pages. When a thread had to wait, the growth is
 * cut short by the wait itself, so it is extrapolated to the length of the mark.
 */
import d.sync.atomic : Atomic;
shared Atomic!ulong gMarkBlockedAt;     // when a thread first waited for the mark, 0 if none did
__gshared size_t gMarkStartUsed;        // pages in use when the mark started
__gshared size_t gMarkGrowthDemand;     // pages the heap wants to grow by during a mark

struct Collector {
	ThreadCache* treadCache;

	this(ThreadCache* tc) {
		this.treadCache = tc;
	}

	@property
	ref CachedExtentMap emap() {
		return threadCache.emap;
	}

	bool maybeRunGCCycle() {
		return gCollectorState.maybeRunGCCycle(this);
	}

	/**
	 * While a sweep runs, a thread that is about to allocate and finds the
	 * heap too far past where the cycle started helps the sweeper, until the
	 * sweep is over or the heap is back under the limit. This is what keeps
	 * a program that allocates faster than the sweeper reclaims from growing
	 * without bound: the sweeper is paced to stay out of the way of the
	 * mutators, not to let them run away.
	 */
	void assistSweep() {
		import d.gc.extent : gSweepCycle, gMarkActive;
		import d.gc.page : gSweepHardLimit, AssistResult;

		if (gSweepCycle.load() == 0 || Arena.computeUsedPageCount() <= gSweepHardLimit) {
			return;
		}

		/**
		 * The mark runs beside the program, and a program that allocates
		 * faster than the mark traces makes the remark pause scan all of
		 * it (measured: 5.7 GiB, 5.4 s, with four threads allocating
		 * garbage flat out). It cannot help the mark, so it waits for it.
		 * Waiting is not a hazard to the pause: a thread asleep here is not
		 * busy, and is stopped like any other.
		 */
		if (gMarkActive.load() != 0) {
			import d.gc.time : sleepMicros;
			ulong none = 0;
			gMarkBlockedAt.cas(none, getMonotonicTime());

			version(Symgc_phase_trace) {
				import core.stdc.stdio : fprintf, stderr;
				fprintf(stderr, "gcwait: %.0f us into the mark, used=%zu pages over hardLimit=%zu pages\n",
				        cast(double) (getMonotonicTime() - gTraceMarkStart) / Microsecond,
				        cast(size_t) Arena.computeUsedPageCount(), cast(size_t) gSweepHardLimit);
			}

			while (gMarkActive.load() != 0 && Arena.computeUsedPageCount() > gSweepHardLimit) {
				sleepMicros(100);
			}

			return;
		}

		threadCache.startCollection();
		scope(exit) threadCache.endCollection();

		while (gSweepCycle.load() != 0 && Arena.computeUsedPageCount() > gSweepHardLimit) {
			bool worked = false;
			bool waiting = false;
			foreach (i; 0 .. ArenaCount) {
				auto a = Arena.getIfInitialized(i);
				if (a !is null) {
					auto r = a.assistSweep(emap);
					worked |= r == AssistResult.Worked;
					waiting |= r == AssistResult.Waiting;
				}
			}

			if (!worked && !waiting) {
				break;
			}

			if (!worked) {
				// The sweeper is on a part that is not ours (finalizers) or
				// another thread is in a step: do not fight it for the lock.
				import d.gc.time : sleepMicros;
				sleepMicros(50);
			}
		}
	}

	/**
	 * Helps background sweeping up to maxTimeHns (100ns units).
	 * If maxTimeHns is 0, performs a single pass across arenas.
	 */
	void assistSweepTimed(ulong maxTimeHns) {
		import d.gc.extent : gSweepCycle;
		import d.gc.page : AssistResult;
		import d.gc.time : getMonotonicTime;

		if (gSweepCycle.load() == 0) {
			return;
		}

		auto start = getMonotonicTime();

		threadCache.startCollection();
		scope(exit) threadCache.endCollection();

		while (gSweepCycle.load() != 0) {
			bool worked = false;
			bool waiting = false;
			foreach (i; 0 .. ArenaCount) {
				auto a = Arena.getIfInitialized(i);
				if (a !is null) {
					auto r = a.assistSweep(emap);
					worked |= r == AssistResult.Worked;
					waiting |= r == AssistResult.Waiting;
				}
			}

			if (!worked && !waiting) {
				break;
			}

			if (maxTimeHns > 0 && (getMonotonicTime() - start) >= maxTimeHns) {
				break;
			}
			if (maxTimeHns == 0) {
				break;
			}
		}
	}

	/**
	 * Defragment heap and purge unused physical memory back to the OS:
	 * 1. Flushes current thread's local cache.
	 * 2. Waits for any running background sweep to finish.
	 * 3. Defragments all small bins across all arenas (reclaiming empty slabs).
	 * 4. Purges all free pages to the OS across all arenas.
	 * Returns total pages purged to the OS.
	 */
	size_t defrag() {
		threadCache.flush();

		import d.gc.extent : gSweepCycle;
		while (gSweepCycle.load() != 0) {
			assistSweep();
		}

		size_t purgedPages = 0;
		foreach (i; 0 .. ArenaCount) {
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				purgedPages += a.defrag(emap);
			}
		}

		return purgedPages;
	}

	void runGCCycle() {
		threadCache.flush();

		/**
		 * An explicit collection is synchronous: let a running background
		 * sweep end first, it needs the collector lock to finish, so we
		 * cannot wait for it with the lock held. Another thread may start
		 * a collection, and hand its sweep over, between the wait and the
		 * lock: a sweep is only handed over with the lock held, so look
		 * again once we have it, and go back to waiting if there is one.
		 */
		while (true) {
			gSweeper.waitIdle();

			gCollectorState.mutex.lock();
			if (!gSweeper.isActive) {
				break;
			}

			gCollectorState.mutex.unlock();
		}

		scope(exit) gCollectorState.mutex.unlock();

		CollectionInfo info;
		runGCCycleLocked(info, false);
		auto state = cast(CollectorState*) &gCollectorState;
		state.lastCollectionInfo = info;
		state.recordProfile(info);
		// Explicit GC.collect must refresh the heap target; otherwise paced
		// benches that collect+minimize before the run leave a stale nextTarget
		// that decays below minHeapSize on the first needCollection check.
		state.updateTargetPageCount();
	}

	/**
	 * `GC.runFinalizers`: run the finalizers that lie in `segment`. Like an
	 * explicit collection, with no sweep running and none starting.
	 */
	void runFinalizers(const(void)[] segment) {
		while (true) {
			gSweeper.waitIdle();

			gCollectorState.mutex.lock();
			if (!gSweeper.isActive) {
				break;
			}

			gCollectorState.mutex.unlock();
		}

		scope(exit) gCollectorState.mutex.unlock();

		// Finalizers run as in a sweep: they may not allocate.
		threadCache.startCollection();
		scope(exit) threadCache.endCollection();

		foreach (i; 0 .. ArenaCount) {
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.runFinalizersInSegment(emap, segment);
			}
		}
	}

private:
	/**
	 * Run a collection cycle. The stop-the-world part always runs on this
	 * thread. The sweep, which happens after the world restarts, runs here
	 * too unless `allowAsync` is set and the background sweeper takes it, in
	 * which case this returns true and the sweeper does the rest, including
	 * updating `info` in the collector state.
	 */
	bool runGCCycleLocked(ref CollectionInfo info, bool allowAsync) {
		CycleContext ctx;
		ctx.info.start = getMonotonicTime();
		scope(exit) info = ctx.info;
		assert(gCollectorState.mutex.isHeld(), "Mutex not held!");
		assert(!threadCache.state.busy, "Cannot run GC cycle while busy!");

		// Make sure we do not try to collect during a collection.
		auto oldGCActivationState = threadCache.activateGC(false);
		scope(exit) threadCache.activateGC(oldGCActivationState);

		/**
		 * With a concurrent mark, the thread that triggered the collection
		 * does not do any of it: the GC thread does, and the program only
		 * stops for the two short pauses.
		 */
		if (allowAsync && concurrentMarkWanted()) {
			ctx.concurrent = true;
			if (gSweeper.submit(ctx)) {
				return true;
			}

			ctx.concurrent = false;
		}

		import d.gc.global;
		auto gcCycle = gState.nextGCCycle();
		ctx.gcCycle = gcCycle;

		// set up the scanner
		import d.gc.scanner;

		// start the threads
		auto threadCount = gCollectorState.scanningThreads;
		if (threadCount == 0) {
			import core.stdc.stdlib : getenv, atoi;
			auto env = getenv("SYMGC_MARK_THREADS");
			if (env !is null && atoi(env) > 0) {
				threadCount = atoi(env);
			} else {
				import d.gc.cpu;
				threadCount = getCoreCount();
				assert(threadCount >= 1, "Expected at least one thread!");
			}
		}

		import symgc.thread;
		auto nScanningThreads = threadCount - 1;
		startGCThreads(nScanningThreads);
		ctx.threadCount = threadCount;

		import d.gc.thread;
		auto pauseStartTime = getMonotonicTime();
		ctx.pauseStartTime = pauseStartTime;
		stopTheWorld();
		ctx.tStopped = getMonotonicTime();

		import d.gc.region;
		auto dataRange = gDataRegionAllocator.computeAddressRange();
		auto ptrRange = gPointerRegionAllocator.computeAddressRange();

		import d.gc.range;
		auto managedAddressSpace = dataRange.merge(ptrRange);

		// Start pause: prepare the arenas and turn the SATB log on.
		cycleStart(managedAddressSpace, gcCycle);
		ctx.tPrepared = getMonotonicTime();

		// Go on and on until all worklists are empty.
		markGC(gcCycle, managedAddressSpace);

		// Remark pause: nothing is queued yet, because the world is still stopped.
		cycleRemark();
		ctx.tMarked = getMonotonicTime();

		version(Symgc_druntime_hooks) {
			import core.thread.symthread;
			// note, this skips our own threadcache's cache, but that's OK we're about to flush it.
			ctx.info.freeBytes = getTotalCachedAllocations();
		}
		restartTheWorld();
		ctx.info.pauseTime = getMonotonicTime() - pauseStartTime;

		/**
		 * We might have allocated, and therefore refilled the bin
		 * during the collection process. As a result, slots in the
		 * bins may not be marked at this point.
		 *
		 * The straightforward way to handle this is simply to flush
		 * the bins.
		 *
		 * Alternatively, we could make sure the slots are marked.
		 */
		threadCache.flush();

		/**
		 * The mark is over and the bins are empty, so threads can run and
		 * allocate while we sweep: they only get slabs the sweep has put
		 * back, or fresh ones. Thread creation is allowed again too.
		 */
		clearWorldProbation();

		ctx.tFlushed = getMonotonicTime();

		version(Windows) {
			enum canSweepAsync = false;
		} else version(Symgc_sync_sweep) {
			enum canSweepAsync = false;
		} else {
			enum canSweepAsync = true;
		}

		if (canSweepAsync && allowAsync && gSweeper.submit(ctx)) {
			return true;
		}

		finishCycle(ctx);
		return false;
	}

	/**
	 * A cycle with a mostly-concurrent mark (Boehm, Demers and Shenker, 1991),
	 * run by the GC thread while the program runs. Only the two pauses stop it.
	 *
	 *  1. Arm the dirty page tracker. The program runs.
	 *  2. Start pause: prepare the mark bits, empty the bins, start the epoch.
	 *     Short: it does not scan anything.
	 *  3. Mark from the global roots, with the program running. Then, in
	 *     rounds, scan again what the program wrote meanwhile, until little is
	 *     left. Stacks and thread local storage are not scanned yet.
	 *  4. Remark pause: scan the roots, the stacks and the thread local
	 *     storage, and what the program wrote since the last round.
	 *
	 * Everything reachable when the world stops in 4 is marked: marks only
	 * ever get added, a pointer stored into an object that was already
	 * scanned dirties its page, and the stacks and roots are scanned last,
	 * while nothing can move a pointer. What was reachable earlier and is
	 * not anymore may stay marked (floating garbage, freed by the next cycle).
	 * Objects created since step 2 are not marked: they count as live and
	 * the mark does not look at them (see `Extent._sweepTag`), while the pages
	 * they are written to are scanned like any other.
	 *
	 * The program cannot free a large extent while the mark runs (see
	 * `gMarkActive`), and cannot free a slab at all until the sweep.
	 */
	void runConcurrentMark(ref CycleContext ctx) {
		import d.gc.dirty;
		import d.gc.extent;
		import d.gc.global;
		import d.gc.page : gSweepHardLimit;
		import d.gc.range;
		import d.gc.region;
		import d.gc.scanner;
		import d.gc.thread;

		assert(!threadCache.state.busy, "Cannot run GC cycle while busy!");

		auto gcCycle = gState.nextGCCycle();
		ctx.gcCycle = gcCycle;

		/**
		 * The mark shares the machine with the program, so it gets a few
		 * cores, not all of them: a quarter, between 2 and 6. The threads
		 * stay, so an explicit collection later uses the same.
		 * SYMGC_MARK_THREADS overrides, and so does setScanningThreads.
		 */
		auto threadCount = gCollectorState.scanningThreads;
		if (threadCount == 0) {
			import core.stdc.stdlib : getenv, atoi;
			auto env = getenv("SYMGC_MARK_THREADS");
			if (env !is null && atoi(env) > 0) {
				threadCount = atoi(env);
			} else {
				import d.gc.cpu;
				auto cores = getCoreCount();
				threadCount = cores / 4;
				threadCount = threadCount < 2 ? 2 : (threadCount > 6 ? 6 : threadCount);
				if (threadCount > cores) {
					threadCount = cores;
				}
			}
		}

		ctx.threadCount = threadCount;
		startGCThreads(threadCount - 1);

		/**
		 * 1. Arm the tracker, with the program running. This comes before
		 *    anything else: the mark skips the extents born from the epoch
		 *    on, relying on their pages being reported when written, and a
		 *    write that happened before the arm is not reported afterwards.
		 */
		auto tPre0 = getMonotonicTime();
		dirtyArm();
		auto tPre1 = getMonotonicTime();

		/**
		 * 2. Start the epoch. From now on the extents and blocks the program
		 *    creates are born, need no marks and are skipped, so preparing
		 *    the marks of the others can take its time. The regions that
		 *    exist now hold everything that is not born.
		 */
		// Start the epoch and empty the bins as one step, with the lock of
		// every bin held: in either order as two steps, a slab can slip in
		// between (an old one into a bin, or a born one that is then dropped).
		startEpochAndClearBins();
		setSweepLimits();
		gMarkActive.store(1);
		auto tPre2 = getMonotonicTime();

		auto dataRange = gDataRegionAllocator.computeAddressRange();
		auto ptrRange = gPointerRegionAllocator.computeAddressRange();
		auto space = dataRange.merge(ptrRange);

		// 3. Prepare the mark bits, still without a pause.
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.prepareConcurrent(emap, gcCycle);
			}
		}

		ctx.tPrepared = getMonotonicTime();
		ctx.preamble = [tPre1 - tPre0, tPre2 - tPre1, ctx.tPrepared - tPre2];

		// 4. The start pause: only to copy the roots.
		ctx.pauseStartTime = getMonotonicTime();
		stopTheWorld();
		ctx.tStopped = getMonotonicTime();

		/**
		 * Put the roots, the stacks and the thread local storage on the work
		 * list now: the stacks are only valid while the world is stopped, and
		 * most of a D program hangs off its thread locals. The ranges are
		 * copied, not traced: the copies are traced after the world restarts.
		 * Reading the ranges themselves then would fault when a thread exits
		 * meanwhile (its stack and TLS are unmapped). The remark pause scans
		 * the live roots again.
		 */
		markBeginGC(gcCycle, space);
		markSeedGC((shared(Scanner)* s) {
			// Copied now: a thread that exits after the restart takes its
			// stack and TLS with it.
			s.resetRootCopies();
			__sd_gc_global_scan(cast(ScanDg) &s.processGlobalCopy);
		});

		restartTheWorld();
		clearWorldProbation();
		ctx.startPause = getMonotonicTime() - ctx.pauseStartTime;

		// 3. The mark, with the program running.
		auto tMark0 = getMonotonicTime();
		version(Symgc_phase_trace) {
			gTraceMarkStart = tMark0;
		}

		markEndGC();

		DirtyList list;
		scope(exit) list.free();

		enum MaxRounds = 8;
		enum RemarkPages = 512; // 2 MiB

		uint rounds = 0;
		size_t lastPages = 0;
		foreach (i; 0 .. MaxRounds) {
			list.clear();
			lastPages = dirtyCollect((const(void)* start, size_t size) {
				list.add(start, size);
			});

			rounds++;

			version(Symgc_phase_trace) {
				import core.stdc.stdio : fprintf, stderr;
				version(Symgc_cards) {
					import d.gc.cards : gCardsFound;
					fprintf(stderr, "gcround %u dirty_pages=%zu cards=%zu used=%zu at %.0f us\n", rounds, lastPages,
					        gCardsFound, cast(size_t) Arena.computeUsedPageCount(), cast(double) (getMonotonicTime() - tMark0) / Microsecond);
					gCardsFound = 0;
				} else {
					fprintf(stderr, "gcround %u dirty_pages=%zu at %.0f us\n", rounds, lastPages,
					        cast(double) (getMonotonicTime() - tMark0) / Microsecond);
				}
			}

			// Tracking failed: the remark will mark again from scratch.
			if (!dirtyAvailable()) {
				break;
			}

			if (lastPages <= RemarkPages) {
				// What is left is little: the remark pause will do it.
				// Put it back for the pause to find.
				if (lastPages > 0) {
					markRoundGC(gcCycle, space, (shared(Scanner)* s) {
						list.seed(s);
					});
				}
				break;
			}

			version(Symgc_phase_trace) {
				import core.stdc.stdio : fprintf, stderr;
				ulong seedTime = 0;
				auto tRound0 = getMonotonicTime();
				markRoundGC(gcCycle, space, (shared(Scanner)* s) {
					auto t0 = getMonotonicTime();
					list.seed(s);
					seedTime = getMonotonicTime() - t0;
				});
				fprintf(stderr, "gcround %u scan: seed %.0f us, total %.0f us\n", rounds,
				        cast(double) seedTime / Microsecond,
				        cast(double) (getMonotonicTime() - tRound0) / Microsecond);
			} else {
				markRoundGC(gcCycle, space, (shared(Scanner)* s) {
					list.seed(s);
				});
			}
		}

		ctx.concurrentMark = getMonotonicTime() - tMark0;
		ctx.rounds = rounds;
		ctx.lastRoundPages = lastPages;

		// 4. The remark pause.
		auto tRemark0 = getMonotonicTime();
		stopTheWorld();
		auto tR1 = getMonotonicTime();

		list.clear();
		auto remarkPages = dirtyCollect((const(void)* start, size_t size) {
			list.add(start, size);
		}, false);
		auto tR2 = getMonotonicTime();

		version(Symgc_phase_trace) {
			import d.gc.scanner : gScanBytes;
			ctx.scanBytesBeforeRemark = gScanBytes;
		}

		/**
		 * If the kernel stopped tracking at some point (a mapping it could
		 * not register, an error), the pages we were told about are not all
		 * of them, and the mark above cannot be trusted. Mark again, from
		 * scratch, with the world stopped: new mark bits, and a cycle number
		 * of its own so that the sparse and large marks of the first try do
		 * not count.
		 */
		bool tracked = dirtyAvailable();
		version(Symgc_verify) {
			import core.stdc.stdlib : getenv;
			auto fail = getenv("SYMGC_DIRTY_FAIL");
			if (fail !is null && fail[0] == '1') {
				tracked = false;
			}
		}

		if (!tracked) {
			gcCycle = gState.nextGCCycle();
			ctx.gcCycle = gcCycle;
			ctx.fellBack = true;

			/**
			 * A new epoch, so the extents born since the mark started are
			 * ordinary ones now: the new mark bits cover them, the mark
			 * traces them (it skipped them before, relying on the pages we
			 * can no longer trust), and the sweep sweeps them. Slabs that
			 * the program got from the bins meanwhile are unswept for the
			 * new epoch, so the bins must be empty again.
			 */
			startEpoch();
			clearBins();

			prepareGCCycle();
			markRoundGC(gcCycle, space, (shared(Scanner)* s) {
				__sd_gc_global_scan(cast(ScanDg) &s.processGlobal);
			});
		} else {
			markRoundGC(gcCycle, space, (shared(Scanner)* s) {
				// The roots, the stacks, the thread local storage...
				__sd_gc_global_scan(cast(ScanDg) &s.processGlobal);

				// ...and what the program wrote since the last round.
				list.seed(s);
			});
		}

		auto tR3 = getMonotonicTime();
		version(Symgc_phase_trace) {
			import d.gc.scanner : gScanBytes;
			ctx.scanBytesRemark = gScanBytes - ctx.scanBytesBeforeRemark;
		}

		gMarkActive.store(0);
		updateMarkGrowthDemand(tMark0);

		version(Symgc_druntime_hooks) {
			import core.thread.symthread;
			ctx.info.freeBytes = getTotalCachedAllocations();
		}

		restartTheWorld();
		clearWorldProbation();
		auto tR4 = getMonotonicTime();
		ctx.remarkParts = [tR1 - tRemark0, tR2 - tR1, tR3 - tR2, tR4 - tR3];

		/**
		 * This thread is not scanned, so what its thread cache holds (the
		 * memory of the mark's work list, for one) looks dead to the sweep,
		 * which would free it under the cache. Give it back before.
		 */
		threadCache.flush();

		ctx.remarkPause = getMonotonicTime() - tRemark0;
		ctx.remarkPages = remarkPages;
		ctx.info.pauseTime = ctx.startPause + ctx.remarkPause;
		ctx.tMarked = getMonotonicTime();
		ctx.tFlushed = ctx.tMarked;
	}

	/**
	 * The part of the cycle that runs after the world restarted: the sweep
	 * and the bookkeeping. It runs on the sweeper thread when there is one.
	 */
	void finishCycle(ref CycleContext ctx) {
		auto pageCollectStats = collect(ctx.gcCycle);

		import d.gc.extent;
		gSweepCycle.store(0);

		version(Symgc_phase_trace) {
			import core.stdc.stdio : fprintf, stderr;
			auto tSwept = getMonotonicTime();
			enum us = 10.0; // time unit is 100 ns
			fprintf(stderr, "gcphase part1=%.0f threads=%zu start_threads=%.0f stop=%.0f prepare=%.0f mark=%.0f restart=%.0f sweep=%.0f total=%.0f us\n",
				(ctx.tFlushed - ctx.info.start) / us,
				cast(size_t) ctx.threadCount,
				(ctx.pauseStartTime - ctx.info.start) / us, (ctx.tStopped - ctx.pauseStartTime) / us,
				(ctx.tPrepared - ctx.tStopped) / us, (ctx.tMarked - ctx.tPrepared) / us,
				(ctx.pauseStartTime + ctx.info.pauseTime - ctx.tMarked) / us,
				(tSwept - ctx.tFlushed) / us, (tSwept - ctx.info.start) / us);
			if (ctx.concurrent) {
				fprintf(stderr, "gcconc startpause=%.0f remarkpause=%.0f concurrent_mark=%.0f rounds=%u last_round_pages=%zu remark_pages=%zu us\n",
					ctx.startPause / us, ctx.remarkPause / us, ctx.concurrentMark / us,
					ctx.rounds, ctx.lastRoundPages, ctx.remarkPages);
				fprintf(stderr, "gcpre arm=%.0f epoch_and_bins=%.0f prepare=%.0f us\n",
					ctx.preamble[0] / us, ctx.preamble[1] / us, ctx.preamble[2] / us);

				if (ctx.fellBack) {
					fprintf(stderr, "gcfallback: dirty tracking failed, the remark marked everything again\n");
				}

				fprintf(stderr, "gcremark stop=%.0f dirty=%.0f mark=%.0f restart=%.0f us, scanned in the remark %.1f MiB, before it %.1f MiB\n",
					ctx.remarkParts[0] / us, ctx.remarkParts[1] / us, ctx.remarkParts[2] / us, ctx.remarkParts[3] / us,
					ctx.scanBytesRemark / 1048576.0, ctx.scanBytesBeforeRemark / 1048576.0);
			}

			import d.gc.page : gSweepT, gSweepHardLimit;
			fprintf(stderr, "gcheap hardLimit=%zu pages, used now=%zu pages, survivors=%zu pages\n",
				cast(size_t) gSweepHardLimit, Arena.computeUsedPageCount(), cast(size_t) pageCollectStats.pagesCommitted);
			fprintf(stderr, "sweepparts dense: scan=%.0f deadfree=%.0f outlined=%.0f minimize=%.0f | sparse: scan=%.0f deadfree=%.0f minimize=%.0f | longest step=%.0f us\n",
				gSweepT[0] / us, gSweepT[1] / us, gSweepT[2] / us, gSweepT[3] / us,
				gSweepT[4] / us, gSweepT[5] / us, gSweepT[6] / us, gSweepT[7] / us);
			gSweepT[] = 0;
		}

		ctx.info.usedPages = pageCollectStats.pagesCommitted;
		ctx.info.freeBytes += pageCollectStats.pagesCommitted * PageSize - pageCollectStats.bytesAllocated;

		/**
		 * Removing roots cannot realloc while inside a finalizer,
		 * because that could cause a deadlock. So we must periodically
		 * minimize the roots array, never when inside the collect
		 * phase.
		 */
		import d.gc.global;
		gState.minimizeRoots();

		ctx.info.stop = getMonotonicTime();
	}

	/**
	 * The cycle is split in a start pause, the mark, and a remark pause. For
	 * now all three run with the world stopped, which must behave exactly as
	 * before: mutators cannot log anything, so the SATB queue stays empty.
	 * Making the mark concurrent moves the restart between the first two.
	 */
	void cycleStart(AddressRange managedAddressSpace, ubyte gcCycle, bool satb = true) {
		import d.gc.satb;
		assert(!satbMarking(), "Marking flag already set!");

		prepareGCCycle();

		startEpoch();
		clearBins();
		setSweepLimits();

		// The SATB log is for a mark that stops the world; the concurrent
		// mark tracks the pages the program writes instead.
		if (satb) {
			auto lo = managedAddressSpace.ptr;
			satbBegin(lo, lo + managedAddressSpace.size);
		}
	}

	/**
	 * The sweeper is paced unless the heap grows past 1/8 over the
	 * collection target, and the threads that allocate help when it
	 * grows past 1/4. The limits are relative to the target, which
	 * comes from what survived, and not to the heap size now: that
	 * one includes whatever the heap grew by during the last sweep, so
	 * limits based on it would grow from one cycle to the next.
	 */
	void setSweepLimits() {
		import d.gc.page : gSweepGrowthLimit, gSweepHardLimit, gSweepRetainPages;
		auto usedPages = Arena.computeUsedPageCount();
		auto target = (cast(CollectorState*) &gCollectorState).nextTarget;
		version(Symgc_phase_trace) {
			import core.stdc.stdio : fprintf, stderr;
			fprintf(stderr, "gcstart used=%zu pages nextTarget=%zu pages\n", usedPages, cast(size_t) target);
		}

		// A quarter of the target, or 1.5 times what the heap grew by during
		// the last marks if that is more, up to half the target. A program
		// that would need more than that is allocating faster than the mark
		// can follow: extra room only lets the heap grow (measured: twice
		// the memory and as many stalls), so it keeps the quarter.
		__gshared int adaptive = -1;
		if (adaptive < 0) {
			import core.stdc.stdlib : getenv;
			auto env = getenv("SYMGC_ADAPTIVE_LIMIT");
			adaptive = env !is null && env[0] == '0' ? 0 : 1;
		}

		auto allowance = target / 4;
		auto wanted = adaptive ? gMarkGrowthDemand + gMarkGrowthDemand / 2 : 0;
		if (wanted > allowance && wanted <= target / 2) {
			allowance = wanted;
		}

		gSweepGrowthLimit = target + target / 8;
		gSweepHardLimit = target + allowance;
		gSweepRetainPages = target;

		gMarkStartUsed = usedPages;
		gMarkBlockedAt.store(0);
		version(Symgc_phase_trace) {
			import d.gc.page : gTracePagesAdded, gTracePagesFreed, gTraceSlabPages, gTracePagesGrown;
			gTraceGrown0 = gTracePagesGrown.load();
			gTraceAdded0 = gTracePagesAdded.load();
			gTraceFreed0 = gTracePagesFreed.load();
			gTraceSlab0 = gTraceSlabPages.load();
		}
	}

	/**
	 * The mark is over: remember how much the heap grew by while it ran
	 * (see `gMarkGrowthDemand`). If a thread waited at the hard limit, the heap
	 * stopped growing then, so the growth is scaled up to the whole mark.
	 */
	void updateMarkGrowthDemand(ulong markStart) {
		auto now = getMonotonicTime();
		auto used = Arena.computeUsedPageCount();
		size_t growth = used > gMarkStartUsed ? used - gMarkStartUsed : 0;

		auto blockedAt = gMarkBlockedAt.load();
		if (blockedAt > markStart) {
			// Up to eight times: a wait right at the start says little.
			auto before = max((blockedAt - markStart), (now - markStart) / 8);
			growth = cast(size_t) (cast(double) growth * (now - markStart) / before);
		}

		// Remember the larger of this mark and the last ones, forgetting slowly.
		auto remembered = gMarkGrowthDemand - gMarkGrowthDemand / 4;
		gMarkGrowthDemand = max(growth, remembered);

		version(Symgc_phase_trace) {
			import core.stdc.stdio : fprintf, stderr;
			fprintf(stderr, "gcgrowth: heap grew %zu pages in %.0f us of mark%s, demand now %zu pages\n",
			        cast(size_t) (used > gMarkStartUsed ? used - gMarkStartUsed : 0),
			        cast(double) (now - markStart) / Microsecond,
			        (blockedAt > markStart ? " (a thread waited)" : "").ptr, gMarkGrowthDemand);

			import d.gc.page : gTracePagesAdded, gTracePagesFreed, gTraceSlabPages, gTracePagesGrown;
			fprintf(stderr, "gcgrowth:   extents added %zu pages (%zu as slabs), grown %zu, freed %zu pages\n",
			        cast(size_t) (gTracePagesAdded.load() - gTraceAdded0),
			        cast(size_t) (gTraceSlabPages.load() - gTraceSlab0),
			        cast(size_t) (gTracePagesGrown.load() - gTraceGrown0),
			        cast(size_t) (gTracePagesFreed.load() - gTraceFreed0));
		}
	}

	/**
	 * Empty the bins while the world is stopped. From now on a slab can only
	 * be allocated from once the sweep has visited it and put it back, so
	 * threads can allocate during the mark and the sweep.
	 */
	void clearBins() {
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.clearBinsForCollection();
			}
		}
	}

	/**
	 * Start the epoch and empty the bins as one step, with every bin locked,
	 * for a collection that starts with the program running (see
	 * `Arena.lockBins`).
	 */
	void startEpochAndClearBins() {
		import d.gc.arena;

		/**
		 * The set of arenas is taken once: an arena can be initialized by
		 * another thread at any time, and unlocking one we did not lock would
		 * release a lock somebody else holds.
		 */
		shared(Arena)*[ArenaCount] locked;
		import d.gc.sizeclass : BinCount;
		ulong[(BinCount + 63) / 64][ArenaCount] active;
		uint count = 0;

		foreach (i; 0 .. ArenaCount) {
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.lockBins();
				locked[count++] = a;
			}
		}

		startEpoch();

		foreach (i, a; locked[0 .. count]) {
			active[i] = a.clearLockedBins();
		}

		foreach_reverse (a; locked[0 .. count]) {
			a.unlockBins();
		}

		// The program is about to ask for a slab per size class it uses.
		foreach (i, a; locked[0 .. count]) {
			a.prewarmBins(emap, active[i]);
		}
	}

	/**
	 * Extents created from now on are born after the mark. Each collection
	 * has an epoch of its own, which never repeats and is never 0.
	 */
	void startEpoch() {
		import d.gc.extent;
		gEpochCounter++;
		if (gEpochCounter == 0) {
			gEpochCounter = 1;
		}

		gSweepCycle.store(gEpochCounter);
	}

	void cycleRemark() {
		import d.gc.satb;
		satbFlushThread();
		auto n = satbDrain((void*) { assert(false, "Pointer logged while the world was stopped!"); });
		assert(n == 0);
		satbEnd();
	}

	void prepareGCCycle() {
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.prepareGCCycle(emap);
			}
		}
	}

	CollectStats collect(ubyte gcCycle) {
		threadCache.startCollection();
		scope(exit) threadCache.endCollection();

		/**
		 * Every finalizer of the cycle runs before any dead slot is
		 * released, in any arena: a destructor may read an object that is
		 * dead too, and it can be in another arena than the one it is in.
		 */
		import d.gc.extent : gFinalizeStage;
		gFinalizeStage.store(1);

		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.beginSweep(gcCycle);
			}
		}

		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.sweepFinalizers(emap, gcCycle);
			}
		}

		gFinalizeStage.store(0);

		CollectStats stats;
		foreach (i; 0 .. ArenaCount) {
			import d.gc.arena;
			auto a = Arena.getIfInitialized(i);
			if (a !is null) {
				a.finishSweep(emap, gcCycle, stats);
			}
		}
		return stats;
	}
}

/**
 * Does the mark run beside the program? It needs the kernel to track the
 * pages the program writes (SYMGC_CONCURRENT_MARK=1, Linux 6.7 or later), and
 * the GC thread that runs it.
 */
bool concurrentMarkWanted() {
	version(Windows) {
		return false;
	} else version(Symgc_sync_sweep) {
		return false;
	} else {
		import d.gc.dirty;
		return dirtyAvailable();
	}
}

uint disableAutomaticCollections() {
	return gCollectorState.disableAutomaticCollections();
}

uint enableAutomaticCollections() {
	return gCollectorState.enableAutomaticCollections();
}

void collectorPrepareForFork() {
	// The child would not have the sweeper thread, so let a sweep end first.
	while (true) {
		gCollectorState.mutex.lock();
		if (!gSweeper.isActive) {
			return;
		}

		gCollectorState.mutex.unlock();
		gSweeper.waitIdle();
	}
}

void collectorPostForkParent() {
	gCollectorState.mutex.unlock();
}

void collectorPostForkChild() {
	gSweeper.resetAfterFork();
	gCollectorState.mutex.__clear();
}

void setScanningThreads(uint nThreads) {
	gCollectorState.setScanningThreads(nThreads);
}

void setHeapSizeLimit(size_t limit) {
	gCollectorState.setHeapSizeLimit(limit);
}

CollectionInfo lastCollectionInfo() {
	gCollectorState.mutex.lock();
	scope(exit) gCollectorState.mutex.unlock();

	return (cast(CollectorState*)&gCollectorState).lastCollectionInfo;
}

/**
 * Lock-free snapshot of last-collection counters for `GC.frameStats()`.
 * Taking `gCollectorState.mutex` twice per frame contends with the sweeper's
 * `completeAsyncCycle` and blocks mutators at frame boundaries.
 */
void lastCollectionStatsFast(out size_t usedPages, out size_t freeBytes,
                             out size_t numCollections) nothrow @nogc {
	import core.atomic : atomicLoad, MemoryOrder;
	auto s = cast(const shared CollectorState*) &gCollectorState;
	usedPages = atomicLoad!(MemoryOrder.acq)(s.lastCollectionInfo.usedPages);
	freeBytes = atomicLoad!(MemoryOrder.acq)(s.lastCollectionInfo.freeBytes);
	numCollections = cast(size_t) atomicLoad!(MemoryOrder.acq)(s.numCollections);
}

/**
 * The totals of all the cycles since the start, five values: the number of
 * collections, the time spent collecting, the time threads were paused, and
 * the longest pause and collection (100 ns).
 */
void profileStats(ulong* dst) {
	gCollectorState.mutex.lock();
	scope(exit) gCollectorState.mutex.unlock();

	auto s = cast(CollectorState*) &gCollectorState;
	dst[0] = s.numCollections;
	dst[1] = s.totalCollectionTime;
	dst[2] = s.totalPauseTime;
	dst[3] = s.maxPauseTime;
	dst[4] = s.maxCollectionTime;
}

/**
 * Stop the background sweeper thread, if there is one. Called when the GC
 * is torn down.
 */
void cleanupSweeper() {
	gSweeper.stop();
}

/**
 * The sweep and the end of cycle bookkeeping run on a thread of their own, so
 * the thread that triggered the collection is back to its work as soon as the
 * world restarts. It is a GC thread: never paused for a collection, and not
 * scanned. A new cycle does not start while it is running.
 *
 * Finalizers run on this thread, with `inFinalizer` set as usual.
 */
struct Sweeper {
private:
	import d.sync.mutex;
	Mutex mutex;

	bool started;
	bool pending;
	bool active;
	bool stopping;

	CycleContext ctx;

	import symgc.thread : ThreadHandle;
	ThreadHandle thread;

public:
	/**
	 * Hand a cycle over to the sweeper. Returns false if there is no sweeper
	 * thread and none could be started, in which case the caller sweeps.
	 */
	bool submit(ref CycleContext c) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		auto self = cast(Sweeper*) &this;
		assert(!self.active, "A sweep is already running!");

		if (!self.started && !self.startThread()) {
			return false;
		}

		self.ctx = c;
		self.pending = true;
		self.active = true;
		return true;
	}

	@property
	bool isActive() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(Sweeper*) &this).active;
	}

	void waitIdle() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		mutex.waitFor(&(cast(Sweeper*) &this).isIdle);
	}

	void stop() shared {
		auto self = cast(Sweeper*) &this;

		{
			mutex.lock();
			scope(exit) mutex.unlock();

			if (!self.started) {
				return;
			}

			self.stopping = true;
		}

		import symgc.thread : joinGCThread;
		joinGCThread(self.thread);

		mutex.lock();
		scope(exit) mutex.unlock();

		self.started = false;
		self.stopping = false;
	}

	/**
	 * The child of a fork has no sweeper thread. The parent made sure no
	 * sweep was running when it forked.
	 */
	void resetAfterFork() shared {
		mutex.__clear();

		auto self = cast(Sweeper*) &this;
		self.started = false;
		self.pending = false;
		self.active = false;
		self.stopping = false;
	}

private:
	bool isIdle() {
		return !active;
	}

	bool hasWork() {
		return pending || stopping;
	}

	bool startThread() {
		import symgc.thread;

		static void entry(void* arg) {
			import d.gc.tcache;

			// Never collect from the sweeper.
			threadCache.activateGC(false);

			version(Symgc_phase_trace) {
				import core.stdc.stdio : fprintf, stderr;
				import core.sys.posix.pthread : pthread_self;
				fprintf(stderr, "sweeper thread=%p\n", cast(void*) pthread_self());
			}

			// Tuning knob, percent of the time the sweeper may run.
			import core.stdc.stdlib : getenv, atoi;
			if (auto duty = getenv("SYMGC_SWEEP_DUTY")) {
				import d.gc.page : gSweepDutyPercent;
				auto percent = atoi(duty);
				gSweepDutyPercent = percent < 1 ? 1 : (percent > 100 ? 100 : percent);
			}

			/**
			 * Background work: when it shares a core with a mutator, the
			 * mutator comes first. On Linux a nice value applies to the
			 * calling thread only.
			 */
			version(linux) {
				import core.sys.posix.sys.resource : setpriority, PRIO_PROCESS;
				int nice = 10;
				if (auto env = getenv("SYMGC_SWEEP_NICE")) {
					nice = atoi(env);
				}

				setpriority(PRIO_PROCESS, 0, nice);
			}

			import d.gc.gctime;
			markGcThread();

			(cast(shared(Sweeper)*) arg).run();
		}

		// Static, because it must survive until the thread starts.
		static ThreadRunner!(typeof(&entry)) runner;
		runner.fun = &entry;
		runner.arg = cast(void*) &this;

		started = createGCThread(&thread, &runner);
		return started;
	}

	void run() shared {
		auto self = cast(Sweeper*) &this;

		while (true) {
			CycleContext c;

			{
				mutex.lock();
				scope(exit) mutex.unlock();

				mutex.waitFor(&self.hasWork);
				if (self.stopping) {
					return;
				}

				self.pending = false;
				c = self.ctx;
			}

			import d.gc.tcache;
			auto collector = Collector(&threadCache);
			if (c.concurrent) {
				c.info.start = getMonotonicTime();
				collector.runConcurrentMark(c);
			}

			collector.finishCycle(c);

			/**
			 * This thread is not scanned. Anything it allocated (finishing
			 * the cycle reallocates the roots) and kept in its thread cache
			 * would look dead to the next cycle's sweep, and be freed from
			 * under it. So nothing stays in the cache between cycles.
			 */
			threadCache.flush();

			gCollectorState.completeAsyncCycle(c.info);

			mutex.lock();
			scope(exit) mutex.unlock();

			self.active = false;
		}
	}
}

shared Sweeper gSweeper;

private:
struct CollectorState {
private:
	import d.sync.mutex;
	Mutex mutex;
	uint disableCount;

	// This makes for a 32MB default target.
	enum DefaultMinHeapSize = 32 * 1024 * 1024 / PageSize;
	enum DefaultMaxHeapSize = AddressSpace / PageSize;

	/**
	 * Data about the last collection cycle.
	 */
	CollectionInfo lastCollectionInfo;

	/**
	 * Filtered data over several collection.
	 */
	ulong amortizedDuration;

	// What GC.profileStats reports.
	ulong numCollections;
	ulong totalCollectionTime;
	ulong totalPauseTime;
	ulong maxPauseTime;
	ulong maxCollectionTime;

	size_t amortizedHeapSize = 0;
	size_t peakHeapSize = 0;

	/**
	 * Track the targets to meet before collecting.
	 */
	ulong lastTargetAdjustment;

	size_t nextTarget = DefaultMinHeapSize;

	/**
	 * Configuration.
	 */
	// Do not try to collect bellow this heap size.
	size_t minHeapSize = DefaultMinHeapSize;
	size_t maxHeapSize = DefaultMaxHeapSize;

	// Decay by 12.5% per time interval.
	ubyte lgTargetDecay = 3;

	// Keep a minimum overhead of 12.5% over the current heap size.
	ubyte lgMinOverhead = 3;

	// How many threads to run for scanning. 0 to use the cpu count.
	uint scanningThreads = 0;

public:
	bool maybeRunGCCycle(ref Collector collector) shared {
		// Do not unnecessarily create contention on this mutex.
		if (!mutex.tryLock()) {
			return false;
		}

		scope(exit) mutex.unlock();
		return (cast(CollectorState*) &this).maybeRunGCCycleImpl(collector);
	}

	void setScanningThreads(uint nThreads) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(CollectorState*) &this).scanningThreads = nThreads;
	}

	void setHeapSizeLimit(size_t limit) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(CollectorState*) &this).maxHeapSize = limit / PageSize;
	}

	uint disableAutomaticCollections() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(CollectorState*) &this).disableAutomaticCollectionsImpl();
	}

	uint enableAutomaticCollections() shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(CollectorState*) &this).enableAutomaticCollectionsImpl();
	}

private:
	bool maybeRunGCCycleImpl(ref Collector collector) {
		assert(mutex.isHeld(), "mutex not held!");

		if (!needCollection()) {
			return false;
		}

		runGCCycle(collector);
		return true;
	}

	bool needCollection() {
		auto now = getMonotonicTime();
		auto interval = max(amortizedDuration, 100 * Millisecond);

		// First check: do not decay from epoch 0 across the whole uptime.
		if (lastTargetAdjustment == 0) {
			lastTargetAdjustment = now;
		}

		enum LargeLivePages = 64 * 1024 * 1024 / PageSize;
		auto used = lastCollectionInfo.usedPages;
		auto liveTarget = used <= LargeLivePages
			? 2 * used
			: 2 * LargeLivePages + (used - LargeLivePages) + ((used - LargeLivePages) >> 1) + ((used - LargeLivePages) >> 3);
		auto floorTarget = max(liveTarget, minHeapSize);
		while (now - lastTargetAdjustment >= interval) {
			auto delta = nextTarget - lastCollectionInfo.usedPages;
			delta -= delta >> lgTargetDecay;
			delta += lastCollectionInfo.usedPages >> (lgTargetDecay + lgMinOverhead);

			auto newTarget = max(lastCollectionInfo.usedPages + delta, floorTarget);
			if (newTarget == nextTarget) {
				// Limit reached.
				lastTargetAdjustment = now;
				break;
			}

			lastTargetAdjustment += interval;
			nextTarget = newTarget;
		}

		if (disableCount > 0) {
			return false;
		}

		// A cycle is still sweeping.
		if (gSweeper.isActive) {
			return false;
		}

		auto currentHeapSize = Arena.computeUsedPageCount();
		return currentHeapSize >= nextTarget;
	}

	void runGCCycle(ref Collector collector) {
		assert(mutex.isHeld(), "mutex not held!");

		CollectionInfo info;
		if (collector.runGCCycleLocked(info, true)) {
			// The sweeper ends the cycle, see `completeAsyncCycle`.
			return;
		}

		lastCollectionInfo = info;
		recordProfile(info);
		updateTargetPageCount();
	}

public:
	/**
	 * Called by the sweeper when it is done with a cycle it was handed.
	 */
	void completeAsyncCycle(ref CollectionInfo info) shared {
		mutex.lock();
		scope(exit) mutex.unlock();

		auto self = cast(CollectorState*) &this;
		self.lastCollectionInfo = info;
		self.recordProfile(info);
		self.updateTargetPageCount();
	}

	/**
	 * Count a finished cycle for `GC.profileStats`; times are in 100 ns.
	 * Called for every cycle, with the collector lock held.
	 */
	void recordProfile(ref CollectionInfo info) {
		auto duration = info.stop - info.start;
		numCollections++;
		totalCollectionTime += duration;
		totalPauseTime += info.pauseTime;
		maxPauseTime = max(maxPauseTime, info.pauseTime);
		maxCollectionTime = max(maxCollectionTime, duration);
	}

private:

	void updateTargetPageCount() {
		// This creates a low pass filter.
		static next(size_t base, size_t n) {
			return base - (base >> 3) + (n >> 3);
		}

		amortizedDuration =
			next(amortizedDuration, lastCollectionInfo.stop - lastCollectionInfo.start);

		amortizedHeapSize = next(amortizedHeapSize, lastCollectionInfo.usedPages);
		peakHeapSize = max(next(peakHeapSize, lastCollectionInfo.usedPages), lastCollectionInfo.usedPages);

		// Peak target at 1.625x the peak to prevent heap explosion.
		auto tpeak = peakHeapSize + (peakHeapSize >> 1) + (peakHeapSize >> 3);

		// Baseline target at 2x so we don't shrink the heap too fast.
		auto tbaseline = 2 * amortizedHeapSize;

		// We set the target at 2x the current heap size, or keep it elevated
		// at min(tbaseline, tpeak) when live size drops after a peak.
		// Once the live heap exceeds 64 MiB, blend smoothly down toward 1.625x
		// so 512 MiB - 2 GiB heaps do not double RSS while small heaps keep 2x.
		enum LargeLivePages = 64 * 1024 * 1024 / PageSize; // 16384 pages (64 MiB)
		auto used = lastCollectionInfo.usedPages;
		size_t liveTarget;
		if (used <= LargeLivePages) {
			liveTarget = 2 * used;
		} else {
			auto above = used - LargeLivePages;
			auto scaledAbove = above + (above >> 1) + (above >> 3); // 1.625x above 64 MiB
			liveTarget = 2 * LargeLivePages + scaledAbove;
		}
		auto target = max(liveTarget, min(tbaseline, tpeak));

		// Clamp the target based on configuration.
		target = max(target, minHeapSize);
		target = min(target, maxHeapSize);

		// Update target.
		lastTargetAdjustment = lastCollectionInfo.stop;
		nextTarget = target;
	}

	uint disableAutomaticCollectionsImpl() {
		assert(mutex.isHeld(), "mutex not held!");

		return disableCount++;
	}

	uint enableAutomaticCollectionsImpl() {
		assert(mutex.isHeld(), "mutex not held!");
		assert(disableCount > 0);

		return disableCount--;
	}
}

shared CollectorState gCollectorState;
