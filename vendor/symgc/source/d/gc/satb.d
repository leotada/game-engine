module d.gc.satb;

/**
 * Snapshot-at-the-beginning (SATB) support for concurrent marking.
 *
 * While a concurrent mark is running (`satbMarking()`), every deletion of a
 * pointer edge has to be logged, or the object it reached may be swept while a
 * mutator still holds it. Overwriting a pointer field is covered by the
 * compiler's store barrier, which calls `satbLog`. This module also covers the
 * deletions that are not stores:
 *
 *  - releasing a block (`free`, `delete`, a `realloc` that moves or shrinks);
 *  - removing a root range;
 *  - overwriting a range in bulk (`memcpy`, `memset`, array assignment).
 *
 * All of them go through `satbShadeRange`: every word of the range that points
 * into the managed address space is logged. The model checker found each of
 * these as a way to lose a live object (plans/model/README.md, finding 6 and
 * `--rootrm`); see plans/audit/druntime_edge_deletions.md.
 *
 * Nothing sets the marking flag in the stop-the-world collector, so today this
 * module is inert. The concurrent mark phase turns it on with `satbBegin` and
 * consumes the logged pointers with `satbDrain`.
 */

import d.sync.atomic;
import d.sync.mutex;

import symgc.intrinsics;

enum SatbBufferSize = 256;

struct SatbBuffer {
	uint count;
	void*[SatbBufferSize] entries;
}

/**
 * Per-thread buffer. A thread flushes it into the global queue when it is full,
 * at its handshake, and when it exits. Module-level variables are thread local.
 */
SatbBuffer threadBuffer;

struct SatbGlobal {
	Mutex mutex;

	Atomic!ubyte marking;

	/**
	 * Only pointers inside [lo, hi) are logged. This is the managed address
	 * space at the start of the cycle: anything allocated later is born black
	 * and does not need to be shaded.
	 */
	Atomic!size_t lo;
	Atomic!size_t hi;

	// Protected by the mutex.
	void** queue;
	size_t length;
	size_t capacity;
}

shared SatbGlobal gSatb;

bool satbMarking() nothrow @nogc {
	return gSatb.marking.load() != 0;
}

/**
 * Start logging. Called by the collector in the pause that starts the cycle
 * (STW-1), with the current bounds of the managed address space.
 */
void satbBegin(const(void)* lo, const(void)* hi) nothrow @nogc {
	gSatb.lo.store(cast(size_t) lo);
	gSatb.hi.store(cast(size_t) hi);
	gSatb.marking.store(1);
}

/**
 * Stop logging. Called in the pause that ends marking (STW-2), after the
 * final drain.
 */
void satbEnd() nothrow @nogc {
	gSatb.marking.store(0);
}

/**
 * Log one pointer. The barrier calls this with the value being overwritten.
 */
void satbLog(const(void)* p) {
	auto v = cast(size_t) p;
	if (v < gSatb.lo.load() || v >= gSatb.hi.load()) {
		return;
	}

	if (unlikely(threadBuffer.count == SatbBufferSize)) {
		satbFlushThread();
	}

	threadBuffer.entries[threadBuffer.count++] = cast(void*) p;
}

/**
 * Log every word of [start, start + size) that points into the managed
 * address space. `start` is rounded up to a word boundary.
 */
void satbShadeRange(const(void)* start, size_t size) {
	if (!satbMarking()) {
		return;
	}

	enum W = (void*).sizeof;
	auto b = (cast(size_t) start + W - 1) & ~(W - 1);
	auto e = (cast(size_t) start + size) & ~(W - 1);

	for (auto p = b; p < e; p += W) {
		satbLog(*cast(void**) p);
	}
}

/**
 * Move this thread's buffer into the global queue.
 */
void satbFlushThread() {
	auto n = threadBuffer.count;
	if (n == 0) {
		return;
	}

	gSatb.mutex.lock();
	scope(exit) gSatb.mutex.unlock();

	auto g = cast(SatbGlobal*) &gSatb;
	if (g.length + n > g.capacity) {
		import core.stdc.stdlib : realloc;
		auto newCapacity = g.capacity == 0 ? 4096 : g.capacity * 2;
		while (newCapacity < g.length + n) {
			newCapacity *= 2;
		}

		auto q = cast(void**) realloc(g.queue, newCapacity * (void*).sizeof);
		assert(q !is null, "Out of memory growing the SATB queue!");

		g.queue = q;
		g.capacity = newCapacity;
	}

	g.queue[g.length .. g.length + n] = threadBuffer.entries[0 .. n];
	g.length += n;
	threadBuffer.count = 0;
}

/**
 * Hand every queued pointer to `dg` and empty the queue. The caller makes
 * sure the threads' buffers were flushed (handshake) before the final drain.
 */
size_t satbDrain(scope void delegate(void*) dg) {
	// Take the queue under the lock, then call out without it.
	gSatb.mutex.lock();
	auto g = cast(SatbGlobal*) &gSatb;
	auto q = g.queue;
	auto n = g.length;
	g.queue = null;
	g.length = 0;
	g.capacity = 0;
	gSatb.mutex.unlock();

	foreach (p; q[0 .. n]) {
		dg(p);
	}

	import core.stdc.stdlib : free;
	free(q);
	return n;
}

@"satbLog" unittest {
	static void[8 * (void*).sizeof] area;
	auto base = cast(void*) area.ptr;
	satbBegin(base, base + area.length);
	scope(exit) {
		satbEnd();
		satbDrain((void*) {});
		threadBuffer.count = 0;
	}

	// Inside the range: logged. Outside, null: ignored.
	satbLog(base);
	satbLog(base + 8);
	satbLog(null);
	satbLog(base + area.length);
	satbLog(cast(void*) 42);
	assert(threadBuffer.count == 2);

	satbFlushThread();
	assert(threadBuffer.count == 0);

	void*[4] got;
	size_t n;
	satbDrain((void* p) { got[n++] = p; });
	assert(n == 2 && got[0] is base && got[1] is base + 8);

	// Once drained, the queue is empty.
	assert(satbDrain((void*) { assert(false); }) == 0);
}

@"satbShadeRange" unittest {
	void*[6] block;
	void* target0 = cast(void*) 0x1000;
	void* target1 = cast(void*) 0x1008;
	block[0] = target0;
	block[2] = cast(void*) 7; // not a managed address
	block[3] = target1;

	satbBegin(cast(void*) 0x1000, cast(void*) 0x2000);
	scope(exit) {
		satbEnd();
		satbDrain((void*) {});
		threadBuffer.count = 0;
	}

	satbShadeRange(block.ptr, block.sizeof);
	satbFlushThread();

	void*[4] got;
	size_t n;
	satbDrain((void* p) { got[n++] = p; });
	assert(n == 2 && got[0] is target0 && got[1] is target1);

	// Not marking: nothing is logged.
	satbEnd();
	satbShadeRange(block.ptr, block.sizeof);
	assert(threadBuffer.count == 0);
}

@"satbOverflow" unittest {
	satbBegin(cast(void*) 0x1000, cast(void*) 0x100000);
	scope(exit) {
		satbEnd();
		satbDrain((void*) {});
		threadBuffer.count = 0;
	}

	// More entries than one buffer holds: the buffer spills to the queue.
	enum N = 3 * SatbBufferSize + 17;
	foreach (i; 0 .. N) {
		satbLog(cast(void*) (0x1000 + 8 * i));
	}

	satbFlushThread();

	size_t n, sum;
	satbDrain((void* p) { n++; sum += cast(size_t) p; });
	assert(n == N);
	assert(sum == N * 0x1000 + 8 * (N * (N - 1) / 2));
}
