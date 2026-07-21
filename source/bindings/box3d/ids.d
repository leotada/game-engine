module bindings.box3d.ids;

import bindings.box3d.raw;

@safe:

bool b3IsNull(T)(const T id) pure nothrow @nogc {
    return id.index1 == 0;
}

bool b3IsNonNull(T)(const T id) pure nothrow @nogc {
    return id.index1 != 0;
}

bool b3IdEquals(T)(const T a, const T b) pure nothrow @nogc {
    return a.index1 == b.index1 && a.world0 == b.world0 && a.generation == b.generation;
}

uint b3StoreWorldIdD(const b3WorldId id) pure nothrow @nogc {
    return (cast(uint) id.index1 << 16) | cast(uint) id.generation;
}

b3WorldId b3LoadWorldIdD(const uint value) pure nothrow @nogc {
    return b3WorldId(cast(ushort)(value >> 16), cast(ushort) value);
}

ulong b3StoreBodyIdD(const b3BodyId id) pure nothrow @nogc {
    return (cast(ulong) cast(uint) id.index1 << 32) |
        (cast(ulong) id.world0 << 16) |
        cast(ulong) id.generation;
}

b3BodyId b3LoadBodyIdD(const ulong value) pure nothrow @nogc {
    return b3BodyId(cast(int)(value >> 32), cast(ushort)(value >> 16), cast(ushort) value);
}

ulong b3StoreShapeIdD(const b3ShapeId id) pure nothrow @nogc {
    return (cast(ulong) cast(uint) id.index1 << 32) |
        (cast(ulong) id.world0 << 16) |
        cast(ulong) id.generation;
}

b3ShapeId b3LoadShapeIdD(const ulong value) pure nothrow @nogc {
    return b3ShapeId(cast(int)(value >> 32), cast(ushort)(value >> 16), cast(ushort) value);
}

ulong b3StoreJointIdD(const b3JointId id) pure nothrow @nogc {
    return (cast(ulong) cast(uint) id.index1 << 32) |
        (cast(ulong) id.world0 << 16) |
        cast(ulong) id.generation;
}

b3JointId b3LoadJointIdD(const ulong value) pure nothrow @nogc {
    return b3JointId(cast(int)(value >> 32), cast(ushort)(value >> 16), cast(ushort) value);
}
