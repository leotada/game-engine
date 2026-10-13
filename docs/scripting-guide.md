# D Language Game Scripting Guide

This guide details the scripting API, component model, reflection attributes, lifecycle execution, and hot-reload rules for developing games in the engine using the **D programming language**.

---

## 1. Principles & Safety

1. **Safety First:** All gameplay scripts should begin with `@safe:`.
2. **Component Structs are POD:** Components must be plain old data (`isPod!T`).
   - No GC heap references (`string`, dynamic arrays, class references, or delegates).
   - Use `StringId` for interned strings and `Handle!T` / `AssetRef!T` for resource handles.
   - Component state is stored contiguously in engine memory (`SceneWorld`), allowing cache-efficient iteration and instantaneous serialization.
3. **Gameplay Logic is Free:** Inside lifecycle methods and systems, game code can freely allocate temporary objects, use formatting, and query entities.

---

## 2. Defining a Script Component

To create a component, annotate a `struct` with `@component`:

```d
module scripts.rotator;

import engine.script;

@component
static struct Rotator {
    @export_ @range(0.0f, 360.0f) @tooltip("Rotation speed in degrees per second")
    float speed = 90.0f;

    @export_
    Vec3 axis = Vec3(0, 1, 0);

    @hide
    float accumulatedAngle = 0.0f; // Serialized but hidden from the Inspector

    void onStart(scope ref ScriptContext ctx) {
        // Called when Play Mode starts or entity spawns
    }

    void onUpdate(scope ref ScriptContext ctx, float dt) {
        if (ctx.has!Transform()) {
            auto t = &ctx.get!Transform();
            t.position = t.position + axis * (speed * dt * 0.01f);
        }
    }

    void onDestroy(scope ref ScriptContext ctx) {
        // Cleanup when entity is destroyed or Play Mode stops
    }
}
```

---

## 3. Inspector Reflection UDAs

The reflection engine inspects struct members at compile-time to automatically generate editor UI and serialization:

| UDA | Target | Description |
|:---|:---|:---|
| `@component` | `struct` | Registers the struct as an ECS component type. |
| `@export_` / `@exported` | Field | Exposes the field to the Inspector panel and scene serialization. |
| `@hide` | Field | Hides the field from the Inspector, while keeping it serialized. |
| `@range(min, max)` | Numeric field | Renders a draggable slider in the Inspector. |
| `@tooltip("...")` | Field | Displays documentation tooltip when hovering over the field. |
| `@header("...")` | Field | Renders a visual divider and header text above the field. |
| `@formerlyNamed("old")` | Field | Automatically migrates data from an older field name upon scene load. |
| `@runInEditor` | Struct | Executes lifecycle methods (`onUpdate`, etc.) inside the editor outside of Play Mode. |

---

## 4. Script Lifecycle Methods

Component methods are detected via compile-time introspection. The engine builds direct, zero-overhead function pointers without virtual dispatch:

- `void onStart(scope ref ScriptContext ctx)`: Invoked once when entering Play Mode or when an entity spawns during gameplay.
- `void onUpdate(scope ref ScriptContext ctx, float dt)` (or without `dt`): Invoked every visual frame during the gameplay tick.
- `void onFixedUpdate(scope ref ScriptContext ctx, float dt)`: Invoked during fixed physics simulation steps.
- `void onLateUpdate(scope ref ScriptContext ctx, float dt)`: Invoked after all standard update systems have executed (e.g. for camera tracking).
- `void onDestroy(scope ref ScriptContext ctx)`: Invoked when the entity is destroyed or Play Mode is stopped.
- `void onValidate(scope ref ScriptContext ctx)`: Invoked in the editor whenever a property is changed in the Inspector.

---

## 5. `ScriptContext` API

Every lifecycle callback receives a `ScriptContext`:

```d
struct ScriptContext {
    EntityId entity;                  // Current entity ID
    SceneWorld* world;                // Pointer to active ECS world
    const(InputState)* input;         // Keyboard & mouse input state
    float dt;                         // Frame delta time in seconds
    double totalTime;                 // Elapsed gameplay time in seconds

    ref C get(C)();                   // Access component on this entity
    C* getPtr(C)();                   // Optional pointer to component
    bool has(C)();                    // Check if component exists
    void set(C)(C comp);              // Add or replace component
    void remove(C)();                 // Remove component
    EntityId spawn();                 // Spawn a new entity
    void destroy(EntityId target);    // Destroy an entity
}
```

### Checking Input

```d
void onUpdate(scope ref ScriptContext ctx, float dt) {
    if (ctx.input !is null) {
        if (ctx.input.keyDown(Key.w)) {
            // Move forward
        }
    }
}
```

---

## 6. Bevy-Style Free Systems

In addition to component methods, free functions can be marked as systems:

```d
@system(Stage.update, 0)
void moveEnemies(ref SceneWorld world, float dt) {
    foreach (e; world.query!(Transform, EnemyTag)()) {
        auto t = &world.get!Transform(e);
        t.position.z -= dt * 2.0f;
    }
}
```

Stages: `Stage.preUpdate`, `Stage.fixedUpdate`, `Stage.update`, `Stage.lateUpdate`.

---

## 7. Hot-Reload Architecture & Rules

The engine reloads compiled script shared libraries (`libgame.so`) on the fly:

1. **Watch & Debounce:** `FileWatcher` detects script file modifications and waits for a 300ms debounce period.
2. **Child Compilation:** `BuildRunner` runs the DMD compilation in a background subprocess.
3. **State Snapshot:** All script component POD bytes are serialized to JSON in memory.
4. **Unload & Release:** Old module is shutdown and druntime unloads the shared library via `Runtime.unloadLibrary`.
5. **Load & Validate:** New library instance (`libgame_inst_N.so`) is loaded with `Runtime.loadLibrary` and the ABI version (`ENGINE_SCRIPT_ABI`) is verified.
6. **Schema Migration & Restore:** Component state is deserialized back into `SceneWorld`, applying defaults for new fields and mapping renamed fields via `@formerlyNamed`.

### Safe Scripting Rules
- **State in Components Only:** Persistent state must live in component structs. Module-level global variables in `.so` are discarded upon reload.
- **No Dangling Delegates:** Never store function pointers or delegates across the engine boundary; use `ScriptContext` and registered components.
