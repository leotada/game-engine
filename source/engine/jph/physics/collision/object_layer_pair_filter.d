// Jolt — Physics/Collision/ObjectLayerPairFilter.h port (minimal runtime seam).
module engine.jph.physics.collision.object_layer_pair_filter;

import engine.jph.physics.collision.object_layer : ObjectLayer;

@safe:

class ObjectLayerPairFilter {
    bool ShouldCollide(ObjectLayer inLayer1, ObjectLayer inLayer2) const nothrow @nogc {
        cast(void) inLayer1;
        cast(void) inLayer2;
        return true;
    }

    static ObjectLayerPairFilter sDefault() @trusted nothrow {
        if (gDefaultObjectLayerPairFilter is null)
            gDefaultObjectLayerPairFilter = new ObjectLayerPairFilter();
        return gDefaultObjectLayerPairFilter;
    }
}

private __gshared ObjectLayerPairFilter gDefaultObjectLayerPairFilter;