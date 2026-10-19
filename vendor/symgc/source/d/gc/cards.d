module d.gc.cards;

/**
 * Card marking, the compiler-assisted way to know what the program wrote.
 *
 * With `-version=Symgc_cards` the collector does not ask the kernel which
 * pages were written (d.gc.dirty); the compiler says so. Code built with
 * ldc2 `-gc-card-marking` sets one byte in the card table after each store of
 * a pointer to memory that is not on the stack or a global, and after each
 * memcpy/memmove to such memory. The collector reads and clears the table to
 * find the 512 byte cards to scan again.
 *
 * Compared to the kernel route: a store that is not a pointer (a float in an
 * object that is written every frame) dirties nothing, nothing faults after a
 * collection cycle starts, and the pause only depends on the pointers the
 * program wrote. The price: every store of a pointer costs a few more
 * instructions, and writes that do not come from instrumented code (a C
 * library, `read()` into a buffer) are not seen.
 *
 * The memory that holds the program's pointers is one contiguous range, the
 * window: [`__sd_gc_card_lo`, `__sd_gc_card_lo` + `__sd_gc_card_n` * 512). The
 * card table covers the window and nothing else, so its size follows the heap
 * the program can have, not the address space of the machine (a phone with 39
 * bits of address space cannot give 256 GiB to a table). The barrier is range
 * checked:
 *
 *     if ((addr - lo) >> 9 < n) base[(addr - lo) >> 9] = 1;
 *
 * so a store to memory outside the window (malloc, a pointer with a tag in
 * its top byte, as the Android allocator hands out) costs a compare and marks
 * nothing. `lo`, `n` and `base` are zero until the collector starts: until
 * then every barrier is a no-op, which is right, because no memory of the
 * collector exists. The tables are set up when the collector starts, before
 * `main`, not by a constructor that has to run before every other one, which
 * is what `.preinit_array` was for and what a shared library cannot have.
 */

version(Windows) {
	import core.sys.windows.winbase : VirtualAlloc, VirtualFree;
	import core.sys.windows.winnt : MEM_RESERVE, MEM_COMMIT, MEM_DECOMMIT, PAGE_READWRITE;
} else version(Posix) {
	version(linux) {
		import core.sys.linux.sys.mman;
		enum MAP_NORESERVE = 0x4000;
	} else version(OSX) {
		import core.sys.darwin.sys.mman;
		enum MAP_NORESERVE = 0;
		enum MAP_ANONYMOUS = MAP_ANON;
	} else version(iOS) {
		import core.sys.darwin.sys.mman;
		enum MAP_NORESERVE = 0;
		enum MAP_ANONYMOUS = MAP_ANON;
	} else version(TVOS) {
		import core.sys.darwin.sys.mman;
		enum MAP_NORESERVE = 0;
		enum MAP_ANONYMOUS = MAP_ANON;
	} else version(WatchOS) {
		import core.sys.darwin.sys.mman;
		enum MAP_NORESERVE = 0;
		enum MAP_ANONYMOUS = MAP_ANON;
	} else {
		import core.sys.posix.sys.mman;
		enum MAP_NORESERVE = 0x4000;
	}
}
import core.atomic;

enum CardShift = 9;
enum CardSize = size_t(1) << CardShift;

// One summary byte per 64 KiB (128 cards): set with each card, it lets the
// collector skip the 64 KiB regions with nothing dirty without reading their
// cards, which is what keeps the pause small for a heap of many GiB.
enum SummaryShift = 16;
enum CardsPerSummary = size_t(1) << (SummaryShift - CardShift);

/**
 * What the code the compiler emits loads on each barrier.
 *
 * With `-version=Symgc_druntime_cards` the barrier is the compiler's own
 * (`-preview=gcbarrier`, `core.internal.gc.cardbarrier` in druntime), and the
 * variables are druntime's: defining them here too would be a duplicate symbol.
 * druntime's barrier does not mark the summary, so the summary is off.
 */
version(Symgc_druntime_cards) {
	extern(C) extern __gshared size_t __sd_gc_card_lo;
	extern(C) extern __gshared size_t __sd_gc_card_n;
	extern(C) extern __gshared ubyte* __sd_gc_card_base;
	extern(C) extern __gshared ubyte* __sd_gc_card_summary_base;
} else {
	extern(C) __gshared size_t __sd_gc_card_lo;
	extern(C) __gshared size_t __sd_gc_card_n;
	extern(C) __gshared ubyte* __sd_gc_card_base;
	extern(C) __gshared ubyte* __sd_gc_card_summary_base;
}

// The window is carved in blocks of this many bytes (see d.gc.region).
enum WindowGranule = size_t(1) << 30;

/**
 * How much address space to reserve for the memory that holds pointers: the
 * most the heap can grow to. SYMGC_HEAP_RESERVE_GIB overrides it. The default
 * leaves room on a machine with a small address space.
 */
size_t windowSizeWanted() {
	import core.stdc.stdlib : getenv, atoi;

	if (auto env = getenv("SYMGC_HEAP_RESERVE_GIB")) {
		auto gib = atoi(env);
		if (gib > 0) {
			return size_t(gib) * WindowGranule;
		}
	}

	// A phone has 39 bits of address space on many devices (512 GiB for
	// everything: libraries, stacks, the GPU driver's mappings).
	version(Android) {
		enum DefaultGiB = 16;
	} else version(iOS) {
		enum DefaultGiB = 16;
	} else version(D_LP64) {
		enum DefaultGiB = 256;
	} else {
		enum DefaultGiB = 1;
	}

	return size_t(DefaultGiB) * WindowGranule;
}

/// The smallest window worth having: smaller than this and the program is
/// better off failing at start-up than running out of heap a minute in.
enum WindowMinimum = size_t(2) * WindowGranule;

void cardsFatal(string msg) {
	import core.stdc.stdio : fprintf, stderr;
	import core.stdc.stdlib : abort;
	fprintf(stderr, "symgc: %.*s\n", cast(int) msg.length, msg.ptr);
	abort();
}

private void* mapTable(size_t size) {
	version(Windows) {
		// Reserved here, committed with the memory it covers (cardsCommit).
		return VirtualAlloc(null, size, MEM_RESERVE, PAGE_READWRITE);
	} else version(Posix) {
		enum Flags = MAP_PRIVATE | MAP_ANON | MAP_NORESERVE;
		auto p = mmap(null, size, PROT_READ | PROT_WRITE, Flags, -1, 0);
		return p is MAP_FAILED ? null : p;
	}
}

/**
 * Set up the tables for a window the collector has reserved. Called once,
 * before any pointer is stored into the window's memory, from the thread that
 * starts the collector.
 */
void cardsInit(void* lo, size_t size) {
	assert(__sd_gc_card_base is null, "The card table is already set up!");
	assert(size % WindowGranule == 0, "Invalid window size!");

	auto cards = mapTable(size >> CardShift);
	if (cards is null) {
		cardsFatal("cannot map the card table");
	}

	// The summary is small (4 MiB for 256 GiB) and mapped even when unused.
	version(Windows) {
		auto summary = VirtualAlloc(null, size >> SummaryShift, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
	} else {
		auto summary = mapTable(size >> SummaryShift);
	}
	if (summary is null) {
		cardsFatal("cannot map the card summary");
	}

	__sd_gc_card_summary_base = cast(ubyte*) summary;
	__sd_gc_card_base = cast(ubyte*) cards;
	__sd_gc_card_lo = cast(size_t) lo;

	// Last: this is what switches the barriers on.
	atomicStore!(MemoryOrder.rel)(*cast(shared(size_t)*) &__sd_gc_card_n, size >> CardShift);
}

/**
 * Where, in the table, are the cards of [addr, addr + size)? Windows commits
 * the table in step with the memory it covers; elsewhere nothing is needed.
 */
version(Windows) {
	private bool cardSlice(void* addr, size_t size, out size_t first, out size_t bytes) {
		auto rel = cast(size_t) addr - __sd_gc_card_lo;
		if (__sd_gc_card_base is null || rel >= (__sd_gc_card_n << CardShift)) {
			return false;
		}

		first = rel >> CardShift;
		bytes = size >> CardShift;
		return true;
	}

	void cardsCommit(void* addr, size_t size) {
		size_t first, bytes;
		if (!cardSlice(addr, size, first, bytes)) {
			return;
		}

		if (bytes == 0) {
			bytes = 1;
		}

		// Whole pages of the table that cover the cards.
		auto from = first & ~4095UL;
		auto to = (first + bytes + 4095UL) & ~4095UL;
		VirtualAlloc(__sd_gc_card_base + from, to - from, MEM_COMMIT, PAGE_READWRITE);
	}

	void cardsDecommit(void* addr, size_t size) {
		size_t first, bytes;
		if (!cardSlice(addr, size, first, bytes) || bytes == 0) {
			return;
		}

		// Only the pages of the table that hold nothing but these cards:
		// the neighbours' cards share the pages at both ends.
		auto from = (first + 4095UL) & ~4095UL;
		auto to = (first + bytes) & ~4095UL;
		if (to > from) {
			VirtualFree(__sd_gc_card_base + from, to - from, MEM_DECOMMIT);
		}
	}
}

private __gshared bool gSummaryEnabled = false;
private __gshared bool gSummaryChecked = false;

private bool isSummaryEnabled() {
	version(Symgc_druntime_cards) {
		return false;
	}

	if (!gSummaryChecked) {
		import core.stdc.stdlib : getenv;
		auto env = getenv("SYMGC_CARD_SUMMARY");
		gSummaryEnabled = (env !is null && env[0] == '1');
		gSummaryChecked = true;
	}
	return gSummaryEnabled;
}

/**
 * Mark every card of a range. The compiler calls this after a copy that
 * may carry pointers into memory it cannot see through.
 */
extern(C) void __sd_gc_card_range(void* dst, size_t size) {
	if (size == 0) {
		return;
	}

	// A copy to memory outside the window marks nothing. Objects do not
	// straddle the window's edges, so one that starts outside is outside.
	auto limit = __sd_gc_card_n << CardShift;
	auto rel = cast(size_t) dst - __sd_gc_card_lo;
	if (rel >= limit) {
		return;
	}

	auto lastByte = rel + size - 1;
	if (lastByte >= limit || lastByte < rel) {
		lastByte = limit - 1;
	}

	auto first = rel >> CardShift;
	auto last = lastByte >> CardShift;
	auto cards = __sd_gc_card_base;
	auto sums = __sd_gc_card_summary_base;
	const bool useSummary = isSummaryEnabled();

	/**
	 * A copy of up to a few cards is the common one (an array of a few
	 * elements, a struct): plain byte stores. The slice assignments below
	 * are calls to memset, which cost more than the copy itself for a small
	 * array (copying 8 ints: 2.3 ns without the barrier, 8.3 ns with it).
	 * The stores are atomic, relaxed, so that the compiler does not turn
	 * the loop back into a memset.
	 */
	enum SmallRange = 4;
	if (last - first < SmallRange) {
		foreach (c; first .. last + 1) {
			atomicStore!(MemoryOrder.raw)(*cast(shared(ubyte)*) (cards + c), ubyte(1));
		}

		if (useSummary && sums !is null) {
			auto s = first >> (SummaryShift - CardShift);
			atomicStore!(MemoryOrder.raw)(*cast(shared(ubyte)*) (sums + s), ubyte(1));
			auto e = last >> (SummaryShift - CardShift);
			if (e != s) {
				atomicStore!(MemoryOrder.raw)(*cast(shared(ubyte)*) (sums + e), ubyte(1));
			}
		}

		return;
	}

	cards[first .. last + 1] = 1;
	if (useSummary && sums !is null) {
		sums[(first >> (SummaryShift - CardShift)) .. (last >> (SummaryShift - CardShift)) + 1] = 1;
	}
}

version(Symgc_phase_trace) {
	// Dirty cards found by collectCards, for the phase trace (collector thread only).
	__gshared size_t gCardsFound;
}

/**
 * Read and clear the cards of [start, start + size), which lies in the window,
 * calling `dg` with the card aligned runs that cover the dirty ones. Returns
 * the size of the runs in pages, rounded up.
 */
size_t collectCards(size_t start, size_t size, scope void delegate(const(void)*, size_t) dg) {
	enum PageSize = 4096;
	enum CardsPerPage = PageSize / CardSize;

	// The window starts on a block boundary, so a card index counted from it
	// maps to a page address by plain arithmetic.
	auto windowLo = __sd_gc_card_lo;
	assert(start >= windowLo && start + size <= windowLo + (__sd_gc_card_n << CardShift),
	       "Range outside the card window!");

	auto lo = (start - windowLo) >> CardShift;
	auto hi = (start + size - windowLo) >> CardShift;
	auto base = __sd_gc_card_base;

	size_t bytes = 0;
	size_t runLo = 0;
	size_t runHi = 0;

	void flush() {
		if (runLo < runHi) {
			bytes += runHi - runLo;
			if (dg !is null) {
				dg(cast(const(void)*) runLo, runHi - runLo);
			}
		}

		runLo = runHi = 0;
	}

	/**
	 * One dirty card. The runs handed to `dg` are cards, not pages: a program
	 * that writes one pointer in each of many pages (a hash table, a tree)
	 * would otherwise make the collector rescan eight times what it wrote.
	 */
	void card(size_t cardIndex) {
		version(Symgc_phase_trace) {
			gCardsFound++;
		}

		auto s = windowLo + (cardIndex << CardShift);
		if (s == runHi && runHi != 0) {
			runHi = s + CardSize;
			return;
		}

		flush();
		runLo = s;
		runHi = s + CardSize;
	}

	// If summary byte tracking is enabled, skip 64 KiB regions via the summary table
	if (isSummaryEnabled() && __sd_gc_card_summary_base !is null) {
		auto sbase = __sd_gc_card_summary_base;
		auto slo = lo >> (SummaryShift - CardShift);
		auto shi = (hi + CardsPerSummary - 1) >> (SummaryShift - CardShift);

		foreach (si; slo .. shi) {
			auto sb = cast(shared(ubyte)*) (sbase + si);
			if (atomicLoad!(MemoryOrder.raw)(*sb) == 0) {
				continue;
			}

			atomicStore!(MemoryOrder.rel)(*sb, ubyte(0));

			auto from = si << (SummaryShift - CardShift);
			auto to = from + CardsPerSummary;
			if (from < lo) {
				from = lo;
			}
			if (to > hi) {
				to = hi;
			}

			size_t i = from;
			while (i < to) {
				if ((i & 7) == 0 && i + 8 <= to) {
					auto w = cast(shared(ulong)*) (base + i);
					if (atomicLoad!(MemoryOrder.raw)(*w) == 0) {
						i += 8;
						continue;
					}

					auto v = atomicExchange!(MemoryOrder.acq_rel)(w, 0UL);
					foreach (j; 0 .. 8) {
						if ((v >> (8 * j)) & 0xff) {
							card(i + j);
						}
					}

					i += 8;
					continue;
				}

				auto b = cast(shared(ubyte)*) (base + i);
				if (atomicExchange!(MemoryOrder.acq_rel)(b, ubyte(0))) {
					card(i);
				}

				i++;
			}
		}
	} else {
		// Fast direct card scan with unrolled 32-card (16 KiB) zero check
		size_t i = lo;
		while (i < hi && (i & 7) != 0) {
			auto b = cast(shared(ubyte)*) (base + i);
			if (atomicExchange!(MemoryOrder.acq_rel)(b, ubyte(0))) {
				card(i);
			}
			i++;
		}

		while (i + 32 <= hi) {
			auto w0 = cast(shared(ulong)*) (base + i);
			auto w1 = cast(shared(ulong)*) (base + i + 8);
			auto w2 = cast(shared(ulong)*) (base + i + 16);
			auto w3 = cast(shared(ulong)*) (base + i + 24);

			if ((atomicLoad!(MemoryOrder.raw)(*w0) |
			     atomicLoad!(MemoryOrder.raw)(*w1) |
			     atomicLoad!(MemoryOrder.raw)(*w2) |
			     atomicLoad!(MemoryOrder.raw)(*w3)) == 0) {
				i += 32;
				continue;
			}

			foreach (chunk; 0 .. 4) {
				auto w = cast(shared(ulong)*) (base + i + chunk * 8);
				if (atomicLoad!(MemoryOrder.raw)(*w) != 0) {
					auto v = atomicExchange!(MemoryOrder.acq_rel)(w, 0UL);
					foreach (j; 0 .. 8) {
						if ((v >> (8 * j)) & 0xff) {
							card(i + chunk * 8 + j);
						}
					}
				}
			}
			i += 32;
		}

		while (i + 8 <= hi) {
			auto w = cast(shared(ulong)*) (base + i);
			if (atomicLoad!(MemoryOrder.raw)(*w) != 0) {
				auto v = atomicExchange!(MemoryOrder.acq_rel)(w, 0UL);
				foreach (j; 0 .. 8) {
					if ((v >> (8 * j)) & 0xff) {
						card(i + j);
					}
				}
			}
			i += 8;
		}

		while (i < hi) {
			auto b = cast(shared(ubyte)*) (base + i);
			if (atomicExchange!(MemoryOrder.acq_rel)(b, ubyte(0))) {
				card(i);
			}
			i++;
		}
	}

	flush();
	return (bytes + PageSize - 1) / PageSize;
}

/**
 * Forget what was written so far (a collection is about to start).
 */
void clearCards(size_t start, size_t size) {
	collectCards(start, size, null);
}
