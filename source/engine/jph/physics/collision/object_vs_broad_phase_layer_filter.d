// Jolt — Physics/Collision/ObjectVsBroadPhaseLayerFilter.h port (minimal runtime seam).
module engine.jph.physics.collision.object_vs_broad_phase_layer_filter;

import engine.jph.physics.collision.broad_phase_layer : BroadPhaseLayer;
import engine.jph.physics.collision.object_layer : ObjectLayer;

@safe:

class ObjectVsBroadPhaseLayerFilter {
    bool ShouldCollide(ObjectLayer inLayer1, BroadPhaseLayer inLayer2) const nothrow @nogc {
        cast(void) inLayer1;
        cast(void) inLayer2;
        return true;
    }

    static ObjectVsBroadPhaseLayerFilter sDefault() @trusted nothrow {
        if (gDefaultObjectVsBroadPhaseLayerFilter is null)
            gDefaultObjectVsBroadPhaseLayerFilter = new ObjectVsBroadPhaseLayerFilter();
        return gDefaultObjectVsBroadPhaseLayerFilter;
    }
}

private __gshared ObjectVsBroadPhaseLayerFilter gDefaultObjectVsBroadPhaseLayerFilter;