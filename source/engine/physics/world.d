module engine.physics.world;

import bindings.box3d;
import bindings.box3d.ids : b3IsNonNull;
import engine.math.vec : Vec3;
import engine.physics.convert : toB3Vec3;

@safe:

struct PhysicsWorld {
    @disable this(this);

    private b3WorldId _world;

    this(Vec3 gravity,
         bool enableSleep = true,
         bool enableContinuous = true,
         uint workerCount = 1) nothrow @nogc @trusted {
        b3WorldDef def = b3DefaultWorldDefD();
        def.gravity = toB3Vec3(gravity);
        def.enableSleep = enableSleep;
        def.enableContinuous = enableContinuous;
        def.workerCount = workerCount;
        _world = b3CreateWorldD(&def);
    }

    static PhysicsWorld createDefault() nothrow @nogc {
        return PhysicsWorld(Vec3(0.0f, -9.81f, 0.0f));
    }

    ~this() nothrow @nogc @trusted {
        if (b3IsNonNull(_world)) {
            b3DestroyWorldD(_world);
            _world = b3WorldId.init;
        }
    }

    b3WorldId handle() const nothrow @nogc {
        return _world;
    }

    bool valid() const nothrow @nogc @trusted {
        return b3IsNonNull(_world) && b3World_IsValidD(_world);
    }

    void step(float dt, int subStepCount = 4) nothrow @nogc @trusted {
        b3World_StepD(_world, dt, subStepCount);
    }

    void setGravity(Vec3 gravity) nothrow @nogc @trusted {
        b3World_SetGravityD(_world, toB3Vec3(gravity));
    }

    Vec3 gravity() const nothrow @nogc @trusted {
        immutable g = b3World_GetGravityD(_world);
        return Vec3(g.x, g.y, g.z);
    }

    void enableSleep(bool enabled) nothrow @nogc @trusted {
        b3World_EnableSleepingD(_world, enabled);
    }

    void enableContinuous(bool enabled) nothrow @nogc @trusted {
        b3World_EnableContinuousD(_world, enabled);
    }
}
