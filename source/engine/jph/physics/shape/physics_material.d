// Jolt — Physics/Collision/PhysicsMaterial.h port (minimal stub).
//
// In Jolt `PhysicsMaterial` is a polymorphic, ref-counted, serialisable base
// class that user code may subclass to attach friction/restitution/debug-name
// metadata to sub-shapes. Phase 4 of the port only needs the type to exist
// so other shape modules can hold `RefConst!PhysicsMaterial` fields and the
// `sDefault` singleton; full implementation (serialisation, debug colour,
// per-sub-shape lookup) lands in Phase 8.
//
// Source: ref/JoltPhysics/Jolt/Physics/Collision/PhysicsMaterial.h
module engine.jph.physics.shape.physics_material;

import engine.jph.core.reference : RefTargetMixin, RefConst;

@safe:

/// Minimal ref-counted stand-in for Jolt's PhysicsMaterial. Subclassable
/// later; for now only the singleton matters.
class PhysicsMaterial {
    mixin RefTargetMixin!PhysicsMaterial;

    /// Human-readable name returned by debug overlays.
    string GetDebugName() const pure nothrow @nogc { return "Default"; }

    /// Process-wide default material. Allocated on first call via the GC and
    /// pinned with `SetEmbedded()` so its refcount never drops to zero.
    static PhysicsMaterial sDefault() @trusted nothrow {
        if (gDefault is null) {
            gDefault = new PhysicsMaterial();
            gDefault.SetEmbedded();
        }
        return gDefault;
    }
}

/// `RefConst!PhysicsMaterial` — alias mirroring Jolt's `PhysicsMaterialRefC`.
alias PhysicsMaterialRefC = RefConst!PhysicsMaterial;

private __gshared PhysicsMaterial gDefault;

unittest {
    auto m1 = PhysicsMaterial.sDefault();
    auto m2 = PhysicsMaterial.sDefault();
    assert(m1 is m2);
    assert(m1.GetDebugName() == "Default");
}
