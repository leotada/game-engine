// Jolt — Physics/Body/AllowedDOFs.h port.
//
// Bitfield enum for restricting body degrees of freedom.
module engine.jph.physics.body.alloweddofs;

@safe:

enum EAllowedDOFs : ubyte {
    None         = 0b000000,
    All          = 0b111111,
    TranslationX = 0b000001,
    TranslationY = 0b000010,
    TranslationZ = 0b000100,
    RotationX    = 0b001000,
    RotationY    = 0b010000,
    RotationZ    = 0b100000,
    /// Convenience: top-down 2D motion.
    Plane2D      = TranslationX | TranslationY | RotationZ,
}

EAllowedDOFs dofOr (EAllowedDOFs a, EAllowedDOFs b) pure nothrow @nogc @safe {
    return cast(EAllowedDOFs)(cast(ubyte) a | cast(ubyte) b);
}
EAllowedDOFs dofAnd(EAllowedDOFs a, EAllowedDOFs b) pure nothrow @nogc @safe {
    return cast(EAllowedDOFs)(cast(ubyte) a & cast(ubyte) b);
}
EAllowedDOFs dofXor(EAllowedDOFs a, EAllowedDOFs b) pure nothrow @nogc @safe {
    return cast(EAllowedDOFs)(cast(ubyte) a ^ cast(ubyte) b);
}
EAllowedDOFs dofNot(EAllowedDOFs a)                pure nothrow @nogc @safe {
    return cast(EAllowedDOFs)(~cast(ubyte) a & 0b111111);
}
bool dofHas(EAllowedDOFs a, EAllowedDOFs flag) pure nothrow @nogc @safe {
    return (cast(ubyte) a & cast(ubyte) flag) == cast(ubyte) flag;
}

unittest {
    assert(dofHas(EAllowedDOFs.All, EAllowedDOFs.RotationX));
    assert(!dofHas(EAllowedDOFs.Plane2D, EAllowedDOFs.RotationX));
    assert(dofHas(EAllowedDOFs.Plane2D, EAllowedDOFs.RotationZ));
    assert(dofOr(EAllowedDOFs.TranslationX, EAllowedDOFs.RotationY)
        == cast(EAllowedDOFs)(0b010001));
}
