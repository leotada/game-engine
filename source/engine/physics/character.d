module engine.physics.character;

import bindings.box3d;
import core.stdc.float_ : FLT_MAX;
import engine.math.vec : Vec3;
import engine.physics.convert : toB3Pos, toB3Vec3, toEngineVec3;
import engine.physics.queries : defaultPhysicsQueryFilter;
import engine.physics.world : PhysicsWorld;

@safe:

/// Kinematic capsule mover driven by application code (not a rigid body).
/// `position` is the capsule center in world space.
struct CharacterController {
    Vec3 position;
    Vec3 velocity;
    float height = 1.8f;
    float radius = 0.35f;
    float gravity = 15.0f;
    float maxSpeed = 6.0f;
    float acceleration = 30.0f;
    float friction = 4.0f;
    float stopSpeed = 1.0f;
    float minSpeed = 0.01f;
    float jumpSpeed = 5.0f;
    float maxSlopeY = 0.7f;
    bool onGround;
    bool clipVelocity = true;

    enum int planeCapacity = 16;

    this(Vec3 position, float height = 1.8f, float radius = 0.35f) pure nothrow @nogc {
        this.position = position;
        this.height = height;
        this.radius = radius;
    }

    b3Capsule localCapsule() const pure nothrow @nogc {
        immutable half = height * 0.5f;
        immutable inner = half > radius ? (half - radius) : 0.0f;
        b3Capsule capsule;
        capsule.center1 = b3Vec3(0.0f, -inner, 0.0f);
        capsule.center2 = b3Vec3(0.0f, inner, 0.0f);
        capsule.radius = radius;
        return capsule;
    }

    /// Apply wish direction (XZ), optional jump, gravity, then resolve against the world.
    void move(ref PhysicsWorld world, Vec3 wishDir, float dt, bool jump = false) nothrow @nogc @trusted {
        if (dt <= 0.0f)
            return;

        applyGroundFriction(dt);

        immutable wish = flatten(wishDir);
        immutable wishLenSq = wish.x * wish.x + wish.y * wish.y + wish.z * wish.z;
        if (wishLenSq > 1e-12f) {
            import core.stdc.math : sqrtf;
            immutable wishLen = sqrtf(wishLenSq);
            immutable dir = Vec3(wish.x / wishLen, wish.y / wishLen, wish.z / wishLen);
            immutable desiredSpeed = maxSpeed;
            immutable currentSpeed = velocity.x * dir.x + velocity.z * dir.z;
            immutable addSpeed = desiredSpeed - currentSpeed;
            if (addSpeed > 0.0f) {
                float accelSpeed = acceleration * maxSpeed * dt;
                if (accelSpeed > addSpeed)
                    accelSpeed = addSpeed;
                velocity.x += dir.x * accelSpeed;
                velocity.z += dir.z * accelSpeed;
            }
        }

        if (onGround)
            velocity.y = 0.0f;

        if (jump && onGround) {
            velocity.y = jumpSpeed;
            onGround = false;
        }

        velocity.y -= gravity * dt;

        immutable start = position;
        immutable target = position + velocity * dt;
        solveMove(world, target);

        if (!clipVelocity && dt > 0.0f)
            velocity = (position - start) * (1.0f / dt);

        updateGroundState(world);
    }

    /// Direct kinematic displacement with collision resolution (no wish accel).
    void moveDelta(ref PhysicsWorld world, Vec3 desiredDelta) nothrow @nogc @trusted {
        immutable target = position + desiredDelta;
        solveMove(world, target);
        updateGroundState(world);
    }

private:
    void applyGroundFriction(float dt) nothrow @nogc {
        immutable speed = horizontalSpeed(velocity);
        if (speed < minSpeed) {
            velocity.x = 0.0f;
            velocity.z = 0.0f;
            return;
        }
        immutable control = speed < stopSpeed ? stopSpeed : speed;
        immutable drop = control * friction * dt;
        immutable newSpeed = speed - drop;
        if (newSpeed <= 0.0f) {
            velocity.x = 0.0f;
            velocity.z = 0.0f;
            return;
        }
        immutable scale = newSpeed / speed;
        velocity.x *= scale;
        velocity.z *= scale;
    }

    void solveMove(ref PhysicsWorld world, Vec3 target) nothrow @nogc @trusted {
        auto filter = defaultPhysicsQueryFilter();
        b3Capsule mover = localCapsule();
        b3CollisionPlane[planeCapacity] planes;
        PlaneGatherCtx gather;
        gather.planes = planes.ptr;
        gather.capacity = planeCapacity;

        enum int maxIterations = 5;
        enum float tolerance = 0.01f;

        foreach (_; 0 .. maxIterations) {
            gather.count = 0;
            b3World_CollideMoverD(world.handle, toB3Pos(position), &mover, filter,
                &planeResultThunk, &gather);

            immutable targetDelta = toB3Vec3(target - position);
            b3PlaneSolverResult result = b3SolvePlanesD(targetDelta, planes.ptr, gather.count);
            b3Vec3 delta = result.delta;

            immutable fraction = b3World_CastMoverD(world.handle, toB3Pos(position), &mover, delta,
                filter, null, null);
            delta.x *= fraction;
            delta.y *= fraction;
            delta.z *= fraction;

            position = position + toEngineVec3(delta);

            immutable lenSq = delta.x * delta.x + delta.y * delta.y + delta.z * delta.z;
            if (lenSq < tolerance * tolerance)
                break;
        }

        if (clipVelocity && gather.count > 0)
            velocity = toEngineVec3(b3ClipVectorD(toB3Vec3(velocity), planes.ptr, gather.count));

        onGround = false;
        foreach (i; 0 .. gather.count) {
            if (planes[i].plane.normal.y >= maxSlopeY) {
                onGround = true;
                break;
            }
        }
    }

    void updateGroundState(ref PhysicsWorld world) nothrow @nogc @trusted {
        // Short downward ray from bottom sphere to detect support.
        immutable capsule = localCapsule();
        immutable feet = position + Vec3(0.0f, capsule.center1.y, 0.0f);
        import engine.physics.queries : castRayClosest;
        immutable hit = castRayClosest(world, feet, Vec3(0.0f, -1.0f, 0.0f), radius * 1.5f);
        if (hit.hit && hit.normal.y >= maxSlopeY)
            onGround = true;
    }
}

private struct PlaneGatherCtx {
    b3CollisionPlane* planes;
    int capacity;
    int count;
}

private extern(C) bool planeResultThunk(b3ShapeId shapeId, const(b3PlaneResult)* results, int planeCount, void* context)
    nothrow @nogc @trusted {
    auto ctx = cast(PlaneGatherCtx*) context;
    if (ctx is null || results is null)
        return false;

    foreach (i; 0 .. planeCount) {
        if (ctx.count >= ctx.capacity)
            return false;
        ctx.planes[ctx.count] = b3CollisionPlane(results[i].plane, FLT_MAX, 0.0f, true);
        ctx.count += 1;
    }
    // silence unused
    cast(void) shapeId;
    return true;
}

private Vec3 flatten(Vec3 v) pure nothrow @nogc {
    return Vec3(v.x, 0.0f, v.z);
}

private float horizontalSpeed(Vec3 v) nothrow @nogc {
    import core.stdc.math : sqrtf;
    return sqrtf(v.x * v.x + v.z * v.z);
}
