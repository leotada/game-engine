module d.sync.atomic;

import drta = core.atomic;
import symgc.intrinsics;

enum MemoryOrder : drta.MemoryOrder {
	Relaxed = drta.MemoryOrder.raw,
	Consume = drta.MemoryOrder.acq, // currently a synonym for acquire.
	Acquire = drta.MemoryOrder.acq,
	Release = drta.MemoryOrder.rel,
	AcqRel = drta.MemoryOrder.acq_rel,
	SeqCst = drta.MemoryOrder.seq,
}

/**
 * For now, this simply uses the strongest possible memory order,
 * rather than the one specified by the user.
 *
 * FIXME: Actually use the provided ordering.
 */
struct Atomic(T) {
private:
	T value;

public:
	pragma(inline, true)
	T load(MemoryOrder order = MemoryOrder.SeqCst)() shared {
		version (X86_64) {
			// On x86-64 TSO, atomicStore(SeqCst) already uses XCHG, so a
			// SeqCst load is a plain MOV (Acquire in druntime; druntime's
			// MemoryOrder.seq load emits a non-inlined lock cmpxchg).
			enum drtaOrder = (order == MemoryOrder.SeqCst)
				? drta.MemoryOrder.acq
				: cast(drta.MemoryOrder) order;
			return drta.atomicLoad!drtaOrder(value);
		} else version (X86) {
			enum drtaOrder = (order == MemoryOrder.SeqCst)
				? drta.MemoryOrder.acq
				: cast(drta.MemoryOrder) order;
			return drta.atomicLoad!drtaOrder(value);
		} else {
			return drta.atomicLoad!order(value);
		}
	}

	pragma(inline, true)
	void store(MemoryOrder order = MemoryOrder.SeqCst)(T value) shared {
		drta.atomicStore!order(this.value, value);
	}

	pragma(inline, true)
	T fetchAdd(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return drta.atomicFetchAdd(value, n);
	}

	pragma(inline, true)
	T fetchSub(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return drta.atomicFetchSub(value, n);
	}

	pragma(inline, true)
	T fetchAnd(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return atomicFetchOp!"&"(value, n);
	}

	pragma(inline, true)
	T fetchOr(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return atomicFetchOp!"|"(value, n);
	}

	pragma(inline, true)
	T fetchXor(T n, MemoryOrder order = MemoryOrder.SeqCst) shared {
		return atomicFetchOp!"^"(value, n);
	}

	pragma(inline, true)
	bool cas(MemoryOrder order = MemoryOrder.SeqCst)(ref T expected, T desired) shared {
		return drta.cas(&value, &expected, desired);
	}

	pragma(inline, true)
	bool casWeak(MemoryOrder order = MemoryOrder.SeqCst)(ref T expected, T desired) shared {
		return drta.casWeak(&value, &expected, desired);
	}
}
