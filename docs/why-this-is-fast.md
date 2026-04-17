# Why This Game Engine Is Fast

This engine follows the same core performance principles that make modern ECS-driven engines fast: contiguous data layout, O(1) component lookup, and compile-time specialization. In this codebase, those ideas are implemented in D with templates, `@safe` defaults, and a strict hot-path policy that keeps the frame loop free from GC overhead.

---

## The Core Workload

Consider a scene with 600 particles. Every frame, the engine needs to:

1. Update motion and physics
2. Check lifetime or visibility state
3. Submit render data

That is not a large problem algorithmically. The real constraint is how often this work repeats and how predictably the CPU can access the underlying data.

The engine is fast because it optimizes the memory and dispatch patterns that dominate frame time.

---

## 1. Contiguous Component Storage

The first major win is memory layout.

Components of the same type are stored together in contiguous arrays rather than being spread across unrelated heap allocations. This means iteration has strong cache locality: when the CPU loads one component, nearby components often arrive in the same cache line.

```
Particles: [P0][P1][P2][P3][P4]...
Positions: [X0][X1][X2][X3][X4]...
Velocities:[V0][V1][V2][V3][V4]...
```

That layout matters more than the number of operations in a loop. Sequential reads are cheap. Random reads are not.

In this codebase, `ComponentStore(T)` in `engine/ecs/store.d` keeps component data in dense arrays. This is the same data-oriented principle used by Bevy and other high-performance ECS implementations.

---

## 2. Sparse-Set Lookup

Entity-to-component access is handled with a sparse-set layout:

```
sparse[entityId] -> dense index
dense[index] -> component data
```

That keeps lookup effectively O(1) with a very small constant cost. There is no dynamic type discovery in the hot path, no string-based lookup, and no unnecessary pointer chasing.

For a component fetch, the engine typically does two predictable array reads:

```d
uint idx = sparse[entityId];
auto component = &dense[idx];
```

This is fast not only because it is O(1), but because it is CPU-friendly. The memory access pattern is simple, stable, and easy to prefetch.

---

## 3. Compile-Time World and System Specialization

The engine avoids runtime polymorphism in core ECS execution.

`World!(Components...)` generates the required component stores at compile time, and systems are plain or templated functions instead of interface-driven objects. That gives the compiler full visibility into the concrete types involved.

```d
void physicsSystem(W)(ref W world, float dt) {
    foreach (id; 0 .. world.entityCount()) {
        if (auto vel = world.getPtr!Velocity(id)) {
            auto pos = &world.get!Position(id);
            pos.x += vel.x * dt;
            pos.y += vel.y * dt;
        }
    }
}
```

Because the compiler knows the exact world type and exact component access path, it can emit direct code without vtable dispatch. The result is the same zero-cost specialization strategy that Rust engines get through monomorphization.

---

## 4. Strict Hot-Path Discipline

This repository separates engine-core execution from gameplay-level flexibility.

- Code inside `engine/` that participates in the frame loop is expected to be `@nogc`.
- Components are POD structs with no GC-tracked indirections.
- GPU and platform bindings use narrow `@trusted` interop boundaries.

That split matters because it keeps the high-frequency execution path predictable while still allowing ergonomic higher-level code where appropriate.

The important point is not merely that D has a GC. It is that this engine is structured so the frame path does not depend on it.

---

## Summary

The engine gets its speed from a small set of architectural decisions:

| Concern | Strategy in this engine | Effect |
|:---|:---|:---|
| Memory layout | Dense per-component arrays | Fewer cache misses during iteration |
| Component lookup | Sparse-set indexing | O(1) access with low constant cost |
| System execution | Template-based specialization | No virtual dispatch in hot paths |
| Runtime behavior | `@nogc` frame path and POD components | Predictable per-frame cost |

These choices all reinforce the same principle: organize the engine around data movement and predictable execution, not around object graphs.

---

## Relation to Bevy

Bevy is a useful comparison because the high-level ideas are the same even though the language is different.

| Feature | Bevy (Rust) | This engine (D) |
|:---|:---|:---|
| ECS storage | Sparse-set / table-based ECS | `ComponentStore(T)` sparse-set |
| Entity model | Integer-backed entity handle | `EntityId` alias (`uint`) |
| System specialization | Generic monomorphization | Template instantiation |
| Safety model | Borrow checker | `@safe` by default + DIP1000 |
| GPU backend | `wgpu` | `wgpu-native` via manual bindings |

The goal is the same: achieve modern data-oriented engine performance with abstractions that compile away.