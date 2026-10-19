module d.gc.verify;

/**
 * Verifier mode, enabled with `-version=Symgc_verify`. It is for tests and
 * CI, not for production: it touches every freed slot.
 *
 * The collector (and explicit `free`) fill a freed slot with `PoisonByte`.
 * That has two effects:
 *
 *  - A mutator that still uses an object the collector lost reads
 *    `0xDBDBDBDBDBDBDBDB`, which is not a valid pointer in a 47-bit address
 *    space, and crashes at once instead of silently reading reused memory.
 *  - When a slot is handed out again it must hold either only zeros (fresh
 *    from the OS) or only poison. Anything else means someone wrote through
 *    a dangling pointer, and the check reports the slot and aborts.
 *
 * The same switch is what the concurrent mark and the lazy sweep are
 * validated with (plans, "Reviewed work order", step 2a).
 */

version(Symgc_verify):

enum ubyte PoisonByte = 0xDB;

void poisonSlot(void* ptr, size_t slotSize) {
	import core.stdc.string : memset;
	memset(ptr, PoisonByte, slotSize);
}

/**
 * Called before a slot is returned by the small allocator. `size` is the
 * requested size and `slotSize` the size class; both are used only to report.
 */
void checkSlotOnAlloc(const(void)* ptr, size_t size, size_t slotSize) {
	auto p = cast(const(ubyte)*) ptr;

	bool allZero = true;
	bool allPoison = true;
	size_t firstBad = size_t.max;
	foreach (i; 0 .. slotSize) {
		if (p[i] != 0) {
			allZero = false;
		}

		if (p[i] != PoisonByte) {
			allPoison = false;
			if (firstBad == size_t.max && p[i] != 0) {
				firstBad = i;
			}
		}

		if (!allZero && !allPoison) {
			break;
		}
	}

	if (allZero || allPoison) {
		return;
	}

	import core.stdc.stdio : fprintf, stderr;
	import core.stdc.stdlib : abort;
	fprintf(stderr, "symgc verify: write after free: slot %p (size class %zu, request %zu) holds mixed data, first foreign byte at offset %zu\n",
	        ptr, slotSize, size, firstBad);
	abort();
}
