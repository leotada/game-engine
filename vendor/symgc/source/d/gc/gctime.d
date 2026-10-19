module d.gc.gctime;

/**
 * Time the program's own threads lose to memory management, so a program
 * can tell its own frame time from the collector's:
 *  - Alloc: the allocator's slow paths (refilling a thread bin from an arena,
 *    with its lock waits, and large allocations);
 *  - Collect: deciding on, starting or waiting for a collection, and helping
 *    the sweep (assist);
 *  - Pause: stopped by the collector (start and remark pauses).
 *
 *  - BinLock, FreshSlab, FillerLock: parts of Alloc, timed on their own to see
 *    where a refill waits: the bin's lock, getting a new slab from the page
 *    filler (its work, without its lock wait), and the page filler's lock.
 *
 * Each timer counts its own time only: whatever an inner timer recorded
 * meanwhile (a pause during a refill, a collection during an allocation) is
 * taken out, so the kinds add up without counting anything twice. Alloc is
 * what is left of a slow path once its parts are taken out.
 *
 * Only the program's threads count: the collector's own threads (marking,
 * sweeping) take the same locks, and that is not time the program lost.
 *
 * Times are in hnsecs internally and reported in nanoseconds.
 */
enum GcTimeKind : uint {
	Alloc,
	Collect,
	Pause,
	BinLock,
	FreshSlab,
	FillerLock,
}

enum GcTimeKindCount = 6;

/// Set on the collector's own threads: they record nothing.
bool tIsGcThread;

void markGcThread() {
	tIsGcThread = true;
}

/// All threads since the start.
shared ulong[GcTimeKindCount] gGcTimeTotal;

/// This thread since it started.
ulong[GcTimeKindCount] tGcTime;
ulong tGcTimeSum;

struct GcTimer {
	ulong start;
	ulong innerAtStart;
	GcTimeKind kind;

	pragma(inline, true)
	static GcTimer begin(GcTimeKind kind) {
		if (tIsGcThread) {
			return GcTimer(0, 0, kind);
		}

		import d.gc.time;
		return GcTimer(getMonotonicTime(), tGcTimeSum, kind);
	}

	pragma(inline, true)
	void end() {
		if (tIsGcThread) {
			return;
		}

		import d.gc.time;
		auto elapsed = getMonotonicTime() - start;
		auto inner = tGcTimeSum - innerAtStart;
		version(Symgc_lock_hist) {
			lockHist(kind, elapsed);
		}

		record(kind, elapsed > inner ? elapsed - inner : 0);
	}
}

version(Symgc_lock_hist) {
	// Count and total of the waits of each kind, by power of two of 100 ns.
	shared ulong[24][GcTimeKindCount] gHistCount;
	shared ulong[24][GcTimeKindCount] gHistTime;

	void lockHist(GcTimeKind kind, ulong hnsecs) {
		import core.atomic : atomicOp;
		uint b = 0;
		while (b < 23 && (hnsecs >> b) > 1) {
			b++;
		}

		atomicOp!"+="(gHistCount[kind][b], 1);
		atomicOp!"+="(gHistTime[kind][b], hnsecs);
	}

	// Waits for the page filler's lock by who held it before: 0 other,
	// 1 allocation, 2 free, 3 prepare, 4 finalizer sweep, 5 sweep, 6 assist.
	shared ulong[24][8] gHolderCount;
	shared ulong[24][8] gHolderTime;

	void holderHist(ubyte holder, ulong hnsecs) {
		if (tIsGcThread) {
			return;
		}

		import core.atomic : atomicOp;
		uint b = 0;
		while (b < 23 && (hnsecs >> b) > 1) {
			b++;
		}

		atomicOp!"+="(gHolderCount[holder][b], 1);
		atomicOp!"+="(gHolderTime[holder][b], hnsecs);
	}

	// How long the page filler's lock is held in the parts of an allocation:
	// 0 the whole hold, 1 getting an extent, 2 getting a block (heaps),
	// 3 acquiring a new block (region), 4 reserving the pages.
	shared ulong[24][8] gSegCount;
	shared ulong[24][8] gSegTime;

	void segHist(uint seg, ulong hnsecs) {
		if (tIsGcThread) {
			return;
		}

		import core.atomic : atomicOp;
		uint b = 0;
		while (b < 23 && (hnsecs >> b) > 1) {
			b++;
		}

		atomicOp!"+="(gSegCount[seg][b], 1);
		atomicOp!"+="(gSegTime[seg][b], hnsecs);
	}

	extern(C) void __sd_gc_seg_hist(ulong* count, ulong* time) {
		foreach (h; 0 .. 8) {
			foreach (b; 0 .. 24) {
				count[h * 24 + b] = gSegCount[h][b];
				time[h * 24 + b] = gSegTime[h][b] * 100;
			}
		}
	}

	extern(C) void __sd_gc_holder_hist(ulong* count, ulong* time) {
		foreach (h; 0 .. 8) {
			foreach (b; 0 .. 24) {
				count[h * 24 + b] = gHolderCount[h][b];
				time[h * 24 + b] = gHolderTime[h][b] * 100;
			}
		}
	}

	extern(C) void __sd_gc_lock_hist(ulong* count, ulong* time) {
		foreach (k; 0 .. GcTimeKindCount) {
			foreach (b; 0 .. 24) {
				count[k * 24 + b] = gHistCount[k][b];
				time[k * 24 + b] = gHistTime[k][b] * 100;
			}
		}
	}
}

void record(GcTimeKind kind, ulong hnsecs) {
	if (tIsGcThread) {
		return;
	}

	tGcTime[kind] += hnsecs;
	tGcTimeSum += hnsecs;

	import core.atomic : atomicOp;
	atomicOp!"+="(gGcTimeTotal[kind], hnsecs);
}

/**
 * The counters as nanoseconds, in `GcTimeKind` order.
 */
void readThread(ulong* dst) {
	foreach (i; 0 .. GcTimeKindCount) {
		dst[i] = tGcTime[i] * 100;
	}
}

void readTotal(ulong* dst) {
	import core.atomic : atomicLoad, MemoryOrder;
	foreach (i; 0 .. GcTimeKindCount) {
		dst[i] = atomicLoad!(MemoryOrder.raw)(gGcTimeTotal[i]) * 100;
	}
}
