// Jolt — Core/Atomics.h equivalent: thin re-exports over `core.atomic`.
//
// The Jolt source uses `std::atomic<T>` and `memory_order_*` enumerators
// directly. In D the equivalents live in `core.atomic`. We alias them so
// the ports read close to the originals (`atomicFetchAdd`, `atomicLoad`,
// etc.) while preserving `@safe @nogc nothrow` guarantees.
//
// Source: ref/JoltPhysics/Jolt/Core/Atomics.h.
module engine.jph.core.atomics;

public import core.atomic :
    atomicLoad, atomicStore, atomicFetchAdd, atomicFetchSub,
    atomicOp, atomicExchange, cas, atomicFence,
    MemoryOrder;

@safe:

// Convenience aliases mirroring std::memory_order_*.
enum MemoryOrder mo_relaxed = MemoryOrder.raw;
enum MemoryOrder mo_acquire = MemoryOrder.acq;
enum MemoryOrder mo_release = MemoryOrder.rel;
enum MemoryOrder mo_acq_rel = MemoryOrder.acq_rel;
enum MemoryOrder mo_seq_cst = MemoryOrder.seq;
