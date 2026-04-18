// Jolt — Physics/Collision/Shape/SubShapeID.{h} port.
//
// `SubShapeID` packs a stack of indices into a single uint32, used to identify
// which leaf sub-shape inside a (possibly nested) compound shape a contact
// occurred against. New IDs are pushed at the *low* free bit region;
// consumers `PopID` from there. The "no path" sentinel `cEmpty` is all-ones
// (0xFFFFFFFF) so an empty path always reads back as zero with no usable
// bits.
//
// `SubShapeIDPair` couples two body+sub-shape IDs (used as the key in the
// contact persistence map).
//
// `SubShapeIDCreator` is the write-side cursor that builds a `SubShapeID`
// during recursive shape traversal.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/Shape/SubShapeID.h
//         ref/JoltPhysics/Jolt/Physics/Collision/Shape/SubShapeIDPair.h
module engine.jph.physics.shape.sub_shape_id;

import engine.jph.physics.body.bodyid : BodyID;

@safe:

/// Bit-packed identifier of a sub-shape inside a compound hierarchy.
struct SubShapeID {
@safe:
    enum uint MaxBits = 32;
    enum uint cEmpty  = 0xffff_ffffu;

    private uint mValue = cEmpty;

    static SubShapeID sFromValue(uint inValue) pure nothrow @nogc {
        SubShapeID r;
        r.mValue = inValue;
        return r;
    }

    uint GetValue() const pure nothrow @nogc { return mValue; }
    void SetValue(uint inValue) pure nothrow @nogc { mValue = inValue; }
    bool IsEmpty() const pure nothrow @nogc { return mValue == cEmpty; }

    /// Pop the lowest `inBits` from this id, returning them as the next
    /// index in the path and writing the remaining (right-shifted,
    /// ones-filled) bits to `outRemainder`. 64-bit math used so
    /// `inBits == 32` is well defined.
    uint PopID(uint inBits, ref SubShapeID outRemainder) const pure nothrow @nogc {
        immutable ulong mask = (cast(ulong) 1 << inBits) - 1UL;
        immutable ulong fill = cast(ulong) cEmpty << (MaxBits - inBits);
        immutable uint v = cast(uint)(cast(ulong) mValue & mask);
        outRemainder.mValue = cast(uint)((cast(ulong) mValue >> inBits) | fill);
        return v;
    }

    /// Internal helper used by `SubShapeIDCreator`: clear `inBits` at
    /// `inFirstBit` then OR `inValue` into them.
    void pushBits(uint inValue, uint inFirstBit, uint inBits) pure nothrow @nogc {
        immutable uint mask = cast(uint)(((cast(ulong) 1 << inBits) - 1UL) << inFirstBit);
        mValue = (mValue & ~mask) | (inValue << inFirstBit);
    }

    bool opEquals(const SubShapeID r) const pure nothrow @nogc { return mValue == r.mValue; }

    int opCmp(const SubShapeID r) const pure nothrow @nogc {
        if (mValue < r.mValue) return -1;
        if (mValue > r.mValue) return  1;
        return 0;
    }
}

/// Write-side cursor used during recursive shape traversal to build up a
/// `SubShapeID` by pushing fixed-width index segments at the low end.
struct SubShapeIDCreator {
@safe:
    private SubShapeID mID;
    private uint mCurrentBit = 0;

    SubShapeIDCreator PushID(uint inValue, uint inBits) const pure nothrow @nogc {
        assert(cast(ulong) inValue < (cast(ulong) 1 << inBits),
               "value does not fit in inBits");
        SubShapeIDCreator r = this;
        r.mID.pushBits(inValue, mCurrentBit, inBits);
        r.mCurrentBit += inBits;
        assert(r.mCurrentBit <= SubShapeID.MaxBits, "SubShapeID overflow");
        return r;
    }

    SubShapeID GetID() const pure nothrow @nogc { return mID; }
    uint GetNumBitsWritten() const pure nothrow @nogc { return mCurrentBit; }
}

/// Pair of body+sub-shape IDs identifying a single contact point.
struct SubShapeIDPair {
@safe:
    BodyID     mBody1ID;
    SubShapeID mSubShapeID1;
    BodyID     mBody2ID;
    SubShapeID mSubShapeID2;

    bool opEquals(const SubShapeIDPair r) const pure nothrow @nogc {
        return mBody1ID == r.mBody1ID
            && mBody2ID == r.mBody2ID
            && mSubShapeID1 == r.mSubShapeID1
            && mSubShapeID2 == r.mSubShapeID2;
    }

    int opCmp(const SubShapeIDPair r) const pure nothrow @nogc {
        if (auto c = mBody1ID.opCmp(r.mBody1ID))         return c;
        if (auto c = mSubShapeID1.opCmp(r.mSubShapeID1)) return c;
        if (auto c = mBody2ID.opCmp(r.mBody2ID))         return c;
        return mSubShapeID2.opCmp(r.mSubShapeID2);
    }

    /// FNV-1a-ish 64-bit hash combining all four fields.
    ulong GetHash() const pure nothrow @nogc {
        ulong h = 1469598103934665603UL;
        void mix(uint v) {
            h ^= v;
            h *= 1099511628211UL;
        }
        mix(mBody1ID.GetIndexAndSequenceNumber());
        mix(mSubShapeID1.GetValue());
        mix(mBody2ID.GetIndexAndSequenceNumber());
        mix(mSubShapeID2.GetValue());
        return h;
    }
}

unittest {
    SubShapeIDCreator c;
    c = c.PushID(5, 4);
    c = c.PushID(3, 3);

    auto id = c.GetID();
    assert(c.GetNumBitsWritten() == 7);

    SubShapeID rest;
    immutable outer = id.PopID(4, rest);
    assert(outer == 5);

    SubShapeID rest2;
    immutable inner = rest.PopID(3, rest2);
    assert(inner == 3);
    assert(rest2.IsEmpty());
}

unittest {
    SubShapeID empty;
    assert(empty.IsEmpty());
    SubShapeID rest;
    immutable v = empty.PopID(8, rest);
    assert(v == 0xffu);
    assert(rest.IsEmpty());
}

unittest {
    SubShapeIDPair a = SubShapeIDPair(BodyID(1, 0), SubShapeID.sFromValue(0),
                                       BodyID(2, 0), SubShapeID.sFromValue(0));
    SubShapeIDPair b = a;
    assert(a == b);
    assert(a.GetHash() == b.GetHash());

    SubShapeIDPair c = SubShapeIDPair(BodyID(1, 0), SubShapeID.sFromValue(0),
                                       BodyID(3, 0), SubShapeID.sFromValue(0));
    assert(a != c);
    assert(a < c);
}
