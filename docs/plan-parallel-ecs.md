# Plan: Parallel ECS Scheduler

> **Status:** pending · Priority: low · See [roadmap.md](roadmap.md)

## Objective

Execute independent ECS systems in parallel (stages + execution waves), with explicit declarations of component read/write access — preventing data races while respecting `@safe` and the engine's `@nogc` hot path.

**The serial API remains supported indefinitely.** The scheduler is completely opt-in; existing game logic does not need to migrate.

## Current State

Repository paths:

- [`ecs/world.d`](../source/engine/ecs/world.d) + [`store.d`](../source/engine/ecs/store.d) — sparse-set SoA stores; no system scheduler
- Systems are plain functions called manually in the user's game loop
- Box3D physics can utilize internal `workerCount` independently **outside** the ECS ([`physics/world.d`](../source/engine/physics/world.d))

## Out of Scope

- Auto-parallelization of GPU command encoding
- Replacing the existing SoA component storage layout
- Parallelizing Box3D narrowphase in D (handled by Box3D backend)
- Full Bevy-style stage graphs in the first release — only the baseline below

## Dependencies

- None. The threading and GC policy (below) must be documented before merging.

## Threading & GC Policy

- Worker thread systems running in the `@nogc` frame path must never allocate on the GC heap.
- Systems that allocate on the GC must only run on the main thread (or within a designated serial stage).
- Never share GC slices across worker threads without explicit synchronization.
- `FrameArena`: one allocator per worker thread or restricted to the main thread (v1 default = main thread only).

## Phases

### ECS-P1 — Access Descriptor Model

- [ ] `Reads!T` / `Writes!T` compile-time templates + debug conflict validation
- [ ] Conflicting writes on the same component type are assigned to separate serial waves

**DoD:** Unit test catches and fails if two writers of the same component `T` are placed in the same execution wave.

### ECS-P2 — Minimal Staging Schedule

- [ ] Three fixed stages: `PreUpdate`, `Update`, `PostUpdate`
- [ ] Topological sorting of systems within a stage
- [ ] Parallel execution waves for non-conflicting systems

**DoD:** Serial schedule execution (1 thread) matches the documented topological order deterministically.

### ECS-P3 — Parallel Worker Runtime

- [ ] Minimal thread pool wrapper
- [ ] Synchronization barriers between execution waves
- [ ] Explicit opt-in: `Schedule.runParallel` vs `Schedule.runSerial`

**DoD:** Two disjoint read-only systems execute concurrently on separate OS threads (verified via thread ID assertion in debug builds).

### ECS-P4 — Engine Integration & Benchmarks

- [ ] Optional schedule hook inside `App` / game loop
- [ ] Scalability benchmark: N independent systems × 10k+ entities vs serial baseline
- [ ] Migration documentation for manual loops

**DoD:** Existing demos running manual system loops continue functioning without changes.

## Acceptance Criteria

1. Concurrent writers to the same component type are provably never scheduled simultaneously.
2. Independent readers execute concurrently across worker threads.
3. Building without the scheduler retains the existing zero-overhead serial execution.
4. Zero performance or behavioral regressions across all existing demos.

## References

- `source/engine/ecs/world.d`, `store.d`
- [why-this-is-fast.md](why-this-is-fast.md)
- [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)
