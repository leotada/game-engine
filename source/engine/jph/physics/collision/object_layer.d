// Jolt — Physics/Collision/ObjectLayer.h port.
//
// Object layers are gameplay-facing collision categories. Broadphase layers
// and pair filters will build on this in later phases.
module engine.jph.physics.collision.object_layer;

import engine.jph.core.types : uint16;

@safe:

alias ObjectLayer = uint16;