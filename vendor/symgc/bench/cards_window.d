// The card window: where the collector's memory is, and what the barrier does
// outside it. Build with the card barrier (ldc2 -gc-card-marking
// -d-version=Symgc_cards) against the fork's symgc, run with
// --DRT-gcopt=gc:sdcq. See cards_window.sh.
//
//   cards_window [checksum]
//
// With `checksum` the whole card table is summed before and after the checks
// that must not mark anything (that reads every page of it: use a small window,
// SYMGC_HEAP_RESERVE_GIB=4).
//
// What it checks:
//  * the window exists before main, is block aligned, and holds the memory
//    that has pointers (small objects, a large one);
//  * a store of a pointer into that memory marks its card, and only that one;
//  * a store into malloc memory, and a copy of pointers to it, mark nothing;
//  * a range outside the window marks nothing, whatever it looks like: low
//    addresses, just below or above the window, and addresses with a tag in
//    the top byte (what Android's allocator hands out);
//  * a range that starts inside and ends past the window's end is cut there
//    (a write past the table would fault).
import core.memory : GC;
import core.stdc.stdio : printf;
import core.stdc.stdlib : malloc, free, getenv, atoi;
import core.stdc.string : memcpy;

// Declared, not defined: symgc defines them (LDC's barrier) or druntime does
// (DMD's, -version=Symgc_druntime_cards).
extern(C) extern __gshared size_t __sd_gc_card_lo;
extern(C) extern __gshared size_t __sd_gc_card_n;
extern(C) extern __gshared ubyte* __sd_gc_card_base;
// The range function of the barrier in use: symgc's for LDC, druntime's for DMD.
version(Symgc_druntime_cards) {
	extern(C) void _d_gcBarrierRange(void* dst, size_t size);
	alias __sd_gc_card_range = _d_gcBarrierRange;
} else {
	extern(C) void __sd_gc_card_range(void* dst, size_t size);
}

enum CardShift = 9;
enum Block = size_t(2) << 20;

final class Obj {
	Obj next;
	Obj other;
	ubyte[200] pad;
}

int failures;

void check(bool ok, const(char)* what) {
	if (!ok) {
		printf("FAIL: %s\n", what);
		failures++;
	}
}

size_t sumTable() {
	size_t s = 0;
	foreach (i; 0 .. __sd_gc_card_n) {
		s += __sd_gc_card_base[i];
	}
	return s;
}

bool inWindow(const(void)* p) {
	return cast(size_t) p - __sd_gc_card_lo < (__sd_gc_card_n << CardShift);
}

size_t cardOf(const(void)* p) {
	return (cast(size_t) p - __sd_gc_card_lo) >> CardShift;
}

int main(string[] args) {
	GC.disable();

	immutable doSum = args.length > 1 && args[1] == "checksum";
	immutable lo = __sd_gc_card_lo;
	immutable n = __sd_gc_card_n;
	immutable size = n << CardShift;

	check(n != 0 && __sd_gc_card_base !is null, "the card table exists before main");
	check(lo % Block == 0, "the window starts on a block boundary");
	check(size >= (size_t(2) << 30), "the window holds at least 2 GiB");

	if (auto want = getenv("SYMGC_HEAP_RESERVE_GIB")) {
		auto gib = size_t(atoi(want));
		check(size <= gib << 30, "the window is not larger than asked for");
	}

	printf("window: [%p, +%llu MiB), %llu cards, table %llu MiB\n",
	       cast(void*) lo, cast(ulong) (size >> 20), cast(ulong) n, cast(ulong) (n >> 20));

	// The memory with pointers is in the window.
	auto a = new Obj;
	auto b = new Obj;
	auto big = cast(void**) GC.malloc(48 << 20);
	auto src = new void*[256];
	src[] = cast(void*) a;
	auto m = cast(void**) malloc(8192);
	check(inWindow(cast(void*) a) && inWindow(cast(void*) b), "small objects are in the window");
	check(inWindow(big), "a large allocation with pointers is in the window");
	check(!inWindow(m), "malloc memory is outside the window");

	// Memory without pointers is allowed to be anywhere, and the barrier does
	// not care: nothing to check there.

	// Allocating marked cards too (the runtime copies the class initializer
	// with the barrier). Start from clear ones around what is tested.
	auto mid = big + (24 << 20) / (void*).sizeof;
	foreach (o; [a, b]) {
		auto p = cast(void*) o;
		foreach (c; cardOf(p) .. cardOf(p + Obj.classinfo.initializer.length) + 1) {
			__sd_gc_card_base[c] = 0;
		}
	}
	__sd_gc_card_base[cardOf(mid)] = 0;
	const sumStart = doSum ? sumTable() : 0;

	// A store of a pointer into the window marks its card.
	auto cardA = cardOf(&a.next);
	a.next = b;
	check(__sd_gc_card_base[cardA] == 1, "a pointer store marks its card");

	// ... only that one (two fields of one object share it or its neighbour).
	a.other = b;
	if (doSum) {
		auto marked = sumTable() - sumStart;
		check(marked >= 1 && marked <= 2, "two stores to an object mark one or two cards");
	}

	// A store into the middle of the large allocation marks the card there.
	auto cardMid = cardOf(mid);
	*mid = cast(void*) a;
	check(__sd_gc_card_base[cardMid] == 1, "a store into a large allocation marks its card");

	// From here on nothing may be marked.
	const before = doSum ? sumTable() : 0;

	// Stores and copies into malloc memory.
	*m = cast(void*) a;
	m[1000] = cast(void*) b;
	memcpy(m, src.ptr, 256 * (void*).sizeof);
	m[0 .. 256] = src[];

	// Ranges that must be ignored.
	immutable tag = size_t(0xB4) << 56;
	__sd_gc_card_range(cast(void*) 0x1000, 4096);
	__sd_gc_card_range(m, 8192);
	__sd_gc_card_range(cast(void*) (cast(size_t) m | tag), 8192);
	__sd_gc_card_range(cast(void*) (lo | tag), 1 << 20);
	__sd_gc_card_range(cast(void*) (lo - 4096), 4096);
	__sd_gc_card_range(cast(void*) (lo + size), 4096);
	__sd_gc_card_range(cast(void*) (lo + size + (1 << 20)), 1 << 20);
	__sd_gc_card_range(cast(void*) size_t.max, 4096);

	// A zero size marks nothing, even inside.
	__sd_gc_card_range(cast(void*) lo, 0);

	// A range that starts below the window and reaches into it is not an
	// object's: it is ignored too.
	__sd_gc_card_range(cast(void*) (lo - 4096), 8192);

	if (doSum) {
		check(sumTable() == before, "stores and ranges outside the window mark nothing");
	}

	// A range that starts in the last card and runs past the end is cut.
	__sd_gc_card_range(cast(void*) (lo + size - 100), 1 << 20);
	check(__sd_gc_card_base[n - 1] == 1, "a range running past the end marks the last card");

	// A range inside marks exactly the cards it covers.
	immutable start = cast(size_t) big + 1000;
	auto first = cardOf(cast(void*) start);
	auto last = cardOf(cast(void*) (start + 3000 - 1));
	foreach (c; first .. last + 1) {
		__sd_gc_card_base[c] = 0;
	}
	__sd_gc_card_range(cast(void*) start, 3000);
	foreach (c; first .. last + 1) {
		check(__sd_gc_card_base[c] == 1, "a range marks every card it covers");
	}
	check(__sd_gc_card_base[first - 1] == 0 && __sd_gc_card_base[last + 1] == 0,
	      "a range marks no card it does not cover");

	free(m);

	if (failures == 0) {
		printf("CARD WINDOW OK\n");
		return 0;
	}

	printf("CARD WINDOW: %d failures\n", failures);
	return 1;
}
