/// Script execution context passed to component lifecycle methods and systems.
module engine.script.context;

import engine.ecs.store : EntityId;
import engine.ecs.scene_world : SceneWorld;
import engine.platform.input : InputState;
import engine.platform.gamepad : Gamepads;

@safe:

struct ScriptContext {
    EntityId entity = EntityId.max;
    SceneWorld* world = null;
    const(InputState)* input = null;
    Gamepads* gamepads = null;
    float dt = 0.0f;
    double totalTime = 0.0;
    /// Set by the engine while a component method runs: destroying `entity` itself is then deferred until the method
    /// returns, because the method still writes through the component's memory.
    bool deferSelfDestroy = false;
    /// The running method destroyed its own entity.
    bool selfDestroyRequested = false;

    ref C get(C)() @trusted {
        assert(world !is null, "ScriptContext: world is null");
        return world.get!C(entity);
    }

    C* getPtr(C)() @trusted {
        if (world is null) return null;
        return world.getPtr!C(entity);
    }

    bool has(C)() @trusted {
        if (world is null) return false;
        return world.has!C(entity);
    }

    void set(C)(C comp) @trusted {
        assert(world !is null, "ScriptContext: world is null");
        world.set!C(entity, comp);
    }

    void remove(C)() @trusted {
        assert(world !is null, "ScriptContext: world is null");
        world.remove!C(entity);
    }

    EntityId spawn() @trusted {
        assert(world !is null, "ScriptContext: world is null");
        return world.spawn();
    }

    void destroy(EntityId target) @trusted {
        assert(world !is null, "ScriptContext: world is null");
        if (deferSelfDestroy && target == entity) {
            selfDestroyRequested = true;
            return;
        }
        world.destroy(target);
    }
}
