// Jolt — Physics/Collision/BroadPhaseLayer.h port (minimal runtime seam).
//
// The simple rigid-body MVP starts with a single broadphase layer by default,
// but keeps the mapping interface explicit so the brute-force broadphase can
// later be swapped for a spatial structure without changing BodyManager.
module engine.jph.physics.collision.broad_phase_layer;

import engine.jph.core.types : uint8;
import engine.jph.physics.collision.object_layer : ObjectLayer;

@safe:

alias BroadPhaseLayer = uint8;

abstract class BroadPhaseLayerInterface {
    abstract BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer inLayer) const nothrow @nogc;

    uint GetNumBroadPhaseLayers() const nothrow @nogc {
        return 1;
    }

    static BroadPhaseLayerInterface sDefault() @trusted nothrow {
        if (gDefaultBroadPhaseLayerInterface is null)
            gDefaultBroadPhaseLayerInterface = new DefaultBroadPhaseLayerInterface();
        return gDefaultBroadPhaseLayerInterface;
    }
}

private final class DefaultBroadPhaseLayerInterface : BroadPhaseLayerInterface {
    override BroadPhaseLayer GetBroadPhaseLayer(ObjectLayer inLayer) const nothrow @nogc {
        cast(void) inLayer;
        return 0;
    }
}

private __gshared BroadPhaseLayerInterface gDefaultBroadPhaseLayerInterface;