// Jolt — Physics/Body/BodyPair.h port.
module engine.jph.physics.body.bodypair;

import engine.jph.physics.body.bodyid;

@safe:

/// Pair of body IDs, packed for cache efficiency (8 bytes total).
align(8)
struct BodyPair {
@safe:
    BodyID mBodyA;
    BodyID mBodyB;

    this(BodyID inA, BodyID inB) pure nothrow @nogc { mBodyA = inA; mBodyB = inB; }

    /// Pack into a single uint64 for hashing / comparison.
    ulong toU64() const pure nothrow @nogc {
        return (cast(ulong) mBodyB.GetIndexAndSequenceNumber() << 32)
             |  cast(ulong) mBodyA.GetIndexAndSequenceNumber();
    }

    bool opEquals(const BodyPair r) const pure nothrow @nogc { return toU64() == r.toU64(); }
    int  opCmp   (const BodyPair r) const pure nothrow @nogc {
        immutable l = toU64(), x = r.toU64();
        if (l < x) return -1;
        if (l > x) return  1;
        return 0;
    }
}

static assert(BodyPair.sizeof == 8, "BodyPair must pack to a single uint64");

unittest {
    immutable p = BodyPair(BodyID(1, 0), BodyID(2, 0));
    immutable q = BodyPair(BodyID(1, 0), BodyID(3, 0));
    assert(p != q && p < q);
    assert(p == BodyPair(BodyID(1, 0), BodyID(2, 0)));
}
