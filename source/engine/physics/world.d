module engine.physics.world;

import bindings.box3d;
import bindings.box3d.ids : b3IsNonNull;
import core.stdc.stdlib : free, realloc;
import engine.math.vec : Vec3;
import engine.physics.convert : toB3Vec3;

@safe:

struct PhysicsWorld {
    @disable this(this);

    private b3WorldId _world;
    private b3MeshData** _ownedMeshes;
    private size_t _ownedMeshCount;
    private size_t _ownedMeshCap;
    private b3HeightFieldData** _ownedHeightFields;
    private size_t _ownedHeightFieldCount;
    private size_t _ownedHeightFieldCap;

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
        // Destroy world first so shapes release references before cooked geometry is freed.
        if (b3IsNonNull(_world)) {
            b3DestroyWorldD(_world);
            _world = b3WorldId.init;
        }
        if (_ownedMeshes !is null) {
            foreach (i; 0 .. _ownedMeshCount) {
                if (_ownedMeshes[i] !is null)
                    b3DestroyMeshD(_ownedMeshes[i]);
            }
            free(_ownedMeshes);
            _ownedMeshes = null;
            _ownedMeshCount = 0;
            _ownedMeshCap = 0;
        }
        if (_ownedHeightFields !is null) {
            foreach (i; 0 .. _ownedHeightFieldCount) {
                if (_ownedHeightFields[i] !is null)
                    b3DestroyHeightFieldD(_ownedHeightFields[i]);
            }
            free(_ownedHeightFields);
            _ownedHeightFields = null;
            _ownedHeightFieldCount = 0;
            _ownedHeightFieldCap = 0;
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

    /// Minimum approach speed (m/s) that generates hit events. Game code sets this.
    void setHitEventThreshold(float value) nothrow @nogc @trusted {
        b3World_SetHitEventThresholdD(_world, value);
    }

    /// Number of awake dynamic/kinematic bodies currently simulated.
    int awakeBodyCount() const nothrow @nogc @trusted {
        if (!valid())
            return 0;
        return b3World_GetAwakeBodyCountD(_world);
    }

    /// Transfer ownership of convenience cooked mesh data to this world.
    package bool adoptCookedMesh(b3MeshData* mesh) nothrow @nogc @trusted {
        return appendOwnedPtr(_ownedMeshes, _ownedMeshCount, _ownedMeshCap, mesh);
    }

    /// Transfer ownership of convenience cooked heightfield data to this world.
    package bool adoptCookedHeightField(b3HeightFieldData* hf) nothrow @nogc @trusted {
        return appendOwnedPtr(_ownedHeightFields, _ownedHeightFieldCount, _ownedHeightFieldCap, hf);
    }
}

private bool appendOwnedPtr(T)(ref T** items, ref size_t count, ref size_t cap, T* item) nothrow @nogc @trusted {
    if (item is null)
        return false;
    if (count == cap) {
        immutable nextCap = cap == 0 ? 16 : cap * 2;
        auto nextBuf = cast(T**) realloc(items, nextCap * (T*).sizeof);
        if (nextBuf is null)
            return false;
        items = nextBuf;
        cap = nextCap;
    }
    items[count++] = item;
    return true;
}
