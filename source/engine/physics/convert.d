module engine.physics.convert;

import bindings.box3d;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;

@safe:

struct PhysicsTransform {
    Vec3 position;
    Quat rotation;
}

b3Vec3 toB3Vec3(const Vec3 v) pure nothrow @nogc {
    return b3Vec3(v.x, v.y, v.z);
}

b3Pos toB3Pos(const Vec3 v) pure nothrow @nogc {
    return b3Pos(v.x, v.y, v.z);
}

b3Quat toB3Quat(const Quat q) pure nothrow @nogc {
    return b3Quat(b3Vec3(q.x, q.y, q.z), q.w);
}

Vec3 toEngineVec3(const b3Vec3 v) pure nothrow @nogc {
    return Vec3(v.x, v.y, v.z);
}

Quat toEngineQuat(const b3Quat q) pure nothrow @nogc {
    return Quat(q.v.x, q.v.y, q.v.z, q.s);
}

PhysicsTransform readBodyTransform(const b3BodyId bodyId) nothrow @nogc @trusted {
    immutable p = b3Body_GetPositionD(bodyId);
    immutable q = b3Body_GetRotationD(bodyId);
    return PhysicsTransform(toEngineVec3(p), toEngineQuat(q));
}

void writeBodyTransform(const b3BodyId bodyId, const Vec3 position, const Quat rotation) nothrow @nogc @trusted {
    immutable p = toB3Pos(position);
    immutable q = toB3Quat(rotation);
    b3Body_SetTransformD(bodyId, p, q);
}
