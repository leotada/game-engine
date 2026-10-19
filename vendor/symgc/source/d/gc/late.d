module d.gc.late;

/**
 * Class instances that were given a finalizer after they were allocated:
 * `GC.setAttr(p, GC.BlkAttr.FINALIZE)`, which druntime does on an object that
 * gets a monitor, so that the monitor is freed when the object dies.
 *
 * A slot of a small slab only has room for a finalizer when it was allocated
 * with one (the pointer lives in the slot's last word), and the size of an
 * object is not known here, so the slot cannot be changed afterwards. These
 * are kept in a table of their addresses instead, outside of the heap (so that
 * it does not keep them alive). The sweep looks a dead slot up in it when the
 * slab is flagged `hasFinalizers`, and the free paths remove the entry.
 */

import d.sync.mutex;

private shared Mutex gLateMutex;

// Open addressing, linear probing, power of two capacity, 1 marks a removed
// entry. Only touched with the mutex held, except for the count.
private __gshared void** gTable;
private __gshared size_t gCapacity;
private __gshared size_t gUsed; // entries and removed entries
private shared size_t gCount; // entries

private enum Removed = cast(void*) 1;

/**
 * Whether there may be an entry at all: a relaxed read, to keep the paths
 * that need not look at the table out of the lock.
 */
bool lateAny() {
	import core.atomic : atomicLoad, MemoryOrder;
	return atomicLoad!(MemoryOrder.raw)(gCount) != 0;
}

private size_t slotOf(void* p, size_t mask) {
	return ((cast(size_t) p >> 3) * 0x9E3779B97F4A7C15UL >> 20) & mask;
}

/**
 * Remember that the allocation at `p` (its first byte) is a class instance
 * to finalize when it dies. Returns false when the table cannot grow.
 */
bool lateAdd(void* p) {
	gLateMutex.lock();
	scope(exit) gLateMutex.unlock();

	if ((gUsed + 1) * 4 > gCapacity * 3 && !grow()) {
		return false;
	}

	auto mask = gCapacity - 1;
	auto i = slotOf(p, mask);
	size_t firstRemoved = size_t.max;
	while (true) {
		auto q = gTable[i];
		if (q is null) {
			break;
		}

		if (q is p) {
			return true;
		}

		if (q is Removed && firstRemoved == size_t.max) {
			firstRemoved = i;
		}

		i = (i + 1) & mask;
	}

	if (firstRemoved != size_t.max) {
		i = firstRemoved;
	} else {
		gUsed++;
	}

	gTable[i] = p;

	import core.atomic : atomicOp;
	atomicOp!"+="(gCount, 1);
	return true;
}

/**
 * Forget `p`. Returns whether it was there.
 */
bool lateRemove(void* p) {
	if (!lateAny()) {
		return false;
	}

	gLateMutex.lock();
	scope(exit) gLateMutex.unlock();

	auto mask = gCapacity - 1;
	auto i = slotOf(p, mask);
	while (true) {
		auto q = gTable[i];
		if (q is null) {
			return false;
		}

		if (q is p) {
			gTable[i] = Removed;

			import core.atomic : atomicOp;
			atomicOp!"-="(gCount, 1);
			return true;
		}

		i = (i + 1) & mask;
	}
}

bool lateContains(void* p) {
	if (!lateAny()) {
		return false;
	}

	gLateMutex.lock();
	scope(exit) gLateMutex.unlock();

	auto mask = gCapacity - 1;
	auto i = slotOf(p, mask);
	while (true) {
		auto q = gTable[i];
		if (q is null) {
			return false;
		}

		if (q is p) {
			return true;
		}

		i = (i + 1) & mask;
	}
}

private bool grow() {
	import core.stdc.stdlib : calloc, free;

	// Rehash into a table big enough for the live entries, dropping the
	// removed ones.
	auto live = gCount;
	auto newCapacity = gCapacity == 0 ? 64 : gCapacity;
	while (newCapacity * 3 < (live + 1) * 4 * 2) {
		newCapacity *= 2;
	}

	auto table = cast(void**) calloc(newCapacity, (void*).sizeof);
	if (table is null) {
		return false;
	}

	auto mask = newCapacity - 1;
	foreach (j; 0 .. gCapacity) {
		auto q = gTable[j];
		if (q is null || q is Removed) {
			continue;
		}

		auto i = slotOf(q, mask);
		while (table[i] !is null) {
			i = (i + 1) & mask;
		}

		table[i] = q;
	}

	free(gTable);
	gTable = table;
	gCapacity = newCapacity;
	gUsed = live;
	return true;
}

@"late" unittest {
	void* a = cast(void*) 0x1000;
	void* b = cast(void*) 0x2000;

	assert(!lateContains(a));
	assert(lateAdd(a));
	assert(lateAdd(a));
	assert(lateAdd(b));
	assert(lateContains(a) && lateContains(b));
	assert(lateRemove(a));
	assert(!lateRemove(a));
	assert(!lateContains(a) && lateContains(b));

	// Growth and removed entries.
	foreach (i; 0 .. 1000) {
		assert(lateAdd(cast(void*) (0x10000 + i * 16)));
	}

	foreach (i; 0 .. 1000) {
		assert(lateContains(cast(void*) (0x10000 + i * 16)));
		assert(lateRemove(cast(void*) (0x10000 + i * 16)));
	}

	assert(lateRemove(b));
	assert(!lateAny());
}
