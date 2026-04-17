// Jolt — Physics/Body/BodyID.h port.
//
// Opaque 32-bit body handle. Layout:
//   bits  0..22 — body index (max 8 388 607 simultaneous bodies)
//   bits 23..30 — sequence number (rolls, used to detect reuse races)
//   bit  31     — broadphase reserved bit (must be 0 for valid IDs)
//
// Source: ref/JoltPhysics/Jolt/Physics/Body/BodyID.h.
module engine.jph.physics.body.bodyid;

@safe:

struct BodyID {
@safe:
    enum uint cInvalidBodyID      = 0xffff_ffffu;
    enum uint cBroadPhaseBit      = 0x8000_0000u;
    enum uint cMaxBodyIndex       = 0x007f_ffffu;
    enum ubyte cMaxSequenceNumber = 0xffu;
    enum uint cSequenceNumberShift = 23u;

    private uint mID = cInvalidBodyID;

    /// Construct directly from a packed (index | sequence) word. The caller
    /// must ensure the broadphase bit is clear unless the value is the
    /// invalid sentinel.
    this(uint inID) pure nothrow @nogc {
        assert((inID & cBroadPhaseBit) == 0 || inID == cInvalidBodyID,
               "broadphase bit must not be set in a regular BodyID");
        mID = inID;
    }

    this(uint inIndex, ubyte inSequenceNumber) pure nothrow @nogc {
        assert(inIndex <= cMaxBodyIndex, "index overflows BodyID layout");
        mID = (cast(uint) inSequenceNumber << cSequenceNumberShift) | inIndex;
    }

    uint  GetIndex()                   const pure nothrow @nogc { return mID & cMaxBodyIndex; }
    ubyte GetSequenceNumber()          const pure nothrow @nogc { return cast(ubyte)(mID >> cSequenceNumberShift); }
    uint  GetIndexAndSequenceNumber()  const pure nothrow @nogc { return mID; }
    bool  IsInvalid()                  const pure nothrow @nogc { return mID == cInvalidBodyID; }

    bool opEquals(const BodyID r) const pure nothrow @nogc { return mID == r.mID; }
    int  opCmp   (const BodyID r) const pure nothrow @nogc {
        if (mID < r.mID) return -1;
        if (mID > r.mID) return  1;
        return 0;
    }
}

unittest {
    immutable a = BodyID(42, 7);
    assert(a.GetIndex() == 42);
    assert(a.GetSequenceNumber() == 7);
    assert(!a.IsInvalid());

    BodyID inv;
    assert(inv.IsInvalid());

    immutable b = BodyID(42, 8);
    assert(a != b && a < b);
}
