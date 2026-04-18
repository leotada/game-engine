# GC-Safe Architecture Plan

> **Goal.** Allow high-level D code with the GC in game scripts while making
> the worst-case GC pauses (the ones measured in
> [docs/incremental-gc-research.md](incremental-gc-research.md) §7.5,
> ~9 ms/collection on a pointer-rich heap) **unrepresentable in code that
> compiles**. The engine stays pause-free by construction, not by discipline.

This document is the implementation plan that follows from the GC research
report. Read that report first for the empirical motivation.

---

## 1. The mental model — two heaps, one language

```
┌─────────────────────────────────────────────────────────────┐
│  GAME SCRIPT LAYER  (gameplay code, GC-allowed)              │
│  - local string formatting, closures, dynamic arrays         │
│  - allowed to allocate freely between system calls           │
│  - never holds a long-lived pointer into engine data         │
└──────────────────────┬──────────────────────────────────────┘
                       │  handles (uint IDs / StringId) only
                       ▼
┌─────────────────────────────────────────────────────────────┐
│  ENGINE STORAGE LAYER  (POD only, effectively GC.NO_SCAN)    │
│  - ECS components, mesh buffers, particle pools, scene graph │
│  - every allocation goes through a typed pool that checks    │
│    !hasIndirections at compile time                          │
│  - GC sees these arrays but never scans into them            │
└─────────────────────────────────────────────────────────────┘
```

The contract:

> **Anything that survives more than one frame lives in the lower layer and
> has no GC-traced indirections.**

Scripts can `format()` a debug string, build a `string[]` of nearby NPC
names, write a closure for a tween, etc. — but the moment that data needs
to persist or be read back by the engine, it crosses the boundary as IDs
plus pointer-free buffers. The GC can run, freely, between frames; it will
have nothing to trace into except a handful of root buffers.

This is the same model Unity uses (C++ engine / C# gameplay), but
implemented within a single language using D's `@safe` / `@nogc` /
`hasIndirections` machinery instead of an FFI boundary.

### Why this works (recap from §7.5 of the research)

- **Pointer-free arrays cost ~0 ms to mark** even when the heap is large
  (`openworld` scenario: 30–50 MB live, 0.07 ms per collection).
- **Pointer-rich graphs cost 5–9 ms to mark** at the same heap size
  (`worst` scenario: 4096 class instances + class-bearing vertex buffers).
- The gap is two orders of magnitude. It is not a tuning gap; it is a
  data-structure gap. The fix is structural.

---

## 2. Five enforcement primitives

These are small, mechanical, and convert "easy to write, slow at runtime"
into a compile error.

### 2.1 `Pod!T` — the universal allowed-in-engine check

```d
// source/engine/core/pod.d
module engine.core.pod;
import std.traits : hasIndirections;

@safe:

/// Compile-time gate: `T` may live in engine-owned, GC-untraced storage.
enum isPod(T) = !hasIndirections!T;

/// Wrapper that fails compilation with an explanatory message if `T` is
/// not POD. Use in any container declaration that lives in engine memory.
template Pod(T)
{
    static assert(isPod!T,
        "Type `" ~ T.stringof ~ "` contains GC-traced indirections "
        ~ "(class, string, slice, delegate, or pointer to GC memory). "
        ~ "Engine storage must be POD. Replace references with "
        ~ "EntityId / Handle!T, and strings with StringId or fixed buffers.");
    alias Pod = T;
}
```

Usage in storage containers:

```d
struct ParticlePool(T) { Pod!T[] data; ... }
struct ComponentStore(T) { Pod!T[] dense; ... }   // make implicit rule explicit
struct VertexBuffer(V) { Pod!V[] verts; ... }
```

A new contributor who writes `struct Particle { string label; }` gets a
clear compile error pointing at the rule, not a runtime pause spike six
months later.

### 2.2 `Handle(T)` — the only legal cross-references

Generalize the existing `EntityId` so the same pattern works for any
engine-owned resource (NPC definitions, materials, sounds, animation
clips, …).

```d
// source/engine/core/handle.d
module engine.core.handle;
@safe:

struct Handle(T)
{
    uint index;
    uint generation;       // detects stale handles after free

    bool isNull() const @nogc nothrow pure @safe => index == 0;
}
```

Anywhere game code wants to "point at" something owned by the engine, it
stores a `Handle!NpcDef`, never `NpcDef*` or a class reference. Handles
are 8 bytes of POD, so they freely pass through engine storage at zero
GC cost. The generation field catches use-after-free.

The benchmark's worst-case `NpcState.target = anotherNpc` becomes:

```d
struct NpcState { Handle!NpcDef target; uint memoryOffset, memoryLen; ... }
```

### 2.3 `StringId` + a string interner — kill `string` in storage

```d
// source/engine/core/strings.d
module engine.core.strings;
@safe:

struct StringId { uint id; bool isNull() const @nogc nothrow pure => id == 0; }

struct StringTable
{
    private char[] storage;          // single big char buffer
    private uint[] offsets;          // one offset per id (offsets[id..id+1])
    private uint[string] index;      // dedup table (gameplay-side, GC ok)

    StringId intern(scope const(char)[] s) @trusted { ... }
    const(char)[] get(StringId id) const @trusted { ... }
}
```

Material names, dialog keys, asset paths — anything *stored* — becomes a
`StringId`. The interner's backing buffer is one big `char[]` (no
per-element indirections), so the GC sees one root, not 4096. Game scripts
still build `string`s freely; they just call `engine.strings.intern("stone")`
when they want to hand one to the engine.

### 2.4 `FrameArena` — a scratch allocator for hot-path scripts

```d
// source/engine/core/arena.d
module engine.core.arena;
import engine.core.pod : isPod;
@safe:

struct FrameArena
{
    private ubyte[] buffer;
    private size_t  cursor;

    this(size_t capacity) @trusted { buffer = new ubyte[](capacity); }

    T[] alloc(T)(size_t n) @trusted if (isPod!T) { ... }
    char[] sprintf(Args...)(string fmt, Args args) @trusted { ... }
    void reset() @nogc nothrow { cursor = 0; }
}
```

The engine resets it once per frame in `endFrame()`. Game scripts that
need formatted strings, temp arrays, AI decision lists, etc. use the
arena instead of `new` / `format`:

```d
void aiTick(ref FrameArena tmp, NpcId npc) {
    auto candidates = tmp.alloc!Target(64);          // dies at end of frame
    auto label = tmp.sprintf("npc=%d hp=%d", npc.id, hp);
    debugOverlay.draw(label);                        // copies if it persists
}
```

This addresses the **allocator** cost (which dominated mean frame time even
with the GC disabled in the benchmark) without forbidding `string` in
script-level code. Scripts can still use `new` for genuinely persistent
gameplay state — they just shouldn't for per-frame chatter.

### 2.5 `@noGcStorage` UDA + a lint pass

Documentation marker plus a tool that walks `source/engine/**.d` and
fails CI on violations:

```d
// source/engine/core/attrs.d
module engine.core.attrs;
@safe:

/// Marks a struct as engine-owned storage. Lint fails CI if the struct
/// contains GC-traced indirections.
struct noGcStorage {}
```

```d
@noGcStorage
struct Particle { float x, y, vx, vy; ushort kind; }
```

A small `dub run --config=lint` (≈ 100 lines of D using
`std.compiler` + module reflection or `dscanner`) iterates every type
tagged `@noGcStorage`, every container that uses `Pod!T`, and every
field of every component registered with `World!(...)`. For each, it
asserts `isPod`. This catches things that slip past per-call `Pod!T`
gates (e.g. a field added to an existing struct without thinking).

---

## 3. Refactored worst-case (proof the rules work)

The benchmark's `worst` scenario (~9 ms per collection on a 70 MB heap),
rewritten against the rules:

```d
// All engine-owned, NO_SCAN by virtue of !hasIndirections
@noGcStorage
struct NpcDef
{
    StringId             displayName;
    Handle!NpcDef        target;            // 8 bytes, not a class ref
    uint                 memoryOffset, memoryLen;   // index into shared int[]
    Handle!InventoryNode inventoryHead;
    StringId[4]          dialogLines;       // fixed size, ids not strings
}

@noGcStorage
struct InventoryNode { StringId name; int qty; Handle!InventoryNode next; }

@noGcStorage
struct TerrainVertex
{
    float  x, y, z, u, v;
    ushort materialId;
    uint   ownerNpcId;
}

// Gameplay system (GC allowed):
void aiSystem(ref World w, ref FrameArena tmp, float dt) {
    foreach (npc; w.query!NpcDef) {
        // Free to use string, format, etc. — dies in `tmp` or in the GC
        auto debugLine = tmp.sprintf("npc %d targeting %d",
                                     npc.id, npc.target.index);
        // To persist:
        npc.displayName = w.strings.intern(debugLine);
    }
}
```

Predicted mark cost: collapses from ~9 ms to ~0.07 ms (the openworld
number) because the GC walks one root per pool instead of 4096 reference
chains. Step 5 of the rollout (§5) verifies this empirically.

---

## 4. Files to add, by location

| Add                           | Path                                  | Notes                                  |
|-------------------------------|---------------------------------------|----------------------------------------|
| `Pod!T` / `isPod`             | source/engine/core/pod.d              | new module                             |
| `Handle(T)`                   | source/engine/core/handle.d           | generalize current `EntityId` pattern  |
| `StringId` + `StringTable`    | source/engine/core/strings.d          | new module, lives on `World`           |
| `FrameArena`                  | source/engine/core/arena.d            | reset in `engine.app` per-frame        |
| `@noGcStorage` UDA            | source/engine/core/attrs.d            | one-line UDA                           |
| Lint pass                     | tools/lint.d (+ `dub.json` config)    | walks engine/, fails CI on violations  |
| Updated guidance              | AGENTS.md                             | document the layered model + rules     |
| Re-export                     | source/engine/core/package.d          | `public import` of the five new modules|

Each module is small (<200 LOC), individually unit-testable, and converts
one class of "easy to write, slow at runtime" code into a compile error.

---

## 5. Rollout plan (incremental, low-risk)

Each step is independently shippable. Stop at any step if the empirical
numbers say "this is enough."

### Step 1 — Land `Pod!T` and apply it to existing storage

- Add `engine.core.pod`.
- Wrap the dense arrays in `ComponentStore`, `Mesh`, `TexMesh`,
  `ParticlePool`, vertex/index buffers, and `SceneGraph` transform array
  with `Pod!T`.
- Zero behavior change. Just turns implicit assumptions into explicit
  static asserts. Protects against future regressions.
- Acceptance: all 7 dub configs still build; `dub test` still passes.

### Step 2 — Add `StringId` + `StringTable`, migrate engine-side string fields

- Add `engine.core.strings` with a `StringTable` instance owned by `World`
  (or a global engine context).
- Audit `engine/devtools/overlay.d`, `engine/audio/engine.d`,
  `engine/assets/*` for `string` fields stored beyond a single function
  call. Replace with `StringId`.
- Public API: anywhere the engine currently *takes* a `string`, accept
  `scope const(char)[]` and intern internally.
- Acceptance: no `string` survives across a frame inside `engine/`. Run
  the gc-benchmark `worst` scenario; max pause should already drop
  noticeably (predicted: 9 ms → 4–6 ms, since terrain vertices and
  dialog cache strings are gone).

### Step 3 — Add `FrameArena`, expose it through the system signature

- Add `engine.core.arena`.
- Allocate a per-frame arena (suggested: 4 MB) in `engine.app`. Reset in
  `endFrame()`.
- Pass it as a parameter to gameplay systems alongside `World`:
  `void aiSystem(ref World w, ref FrameArena tmp, float dt)`.
- Mandatory for engine devtools/overlay (eliminates the per-frame
  `format()` allocations there). Optional for game code.
- Acceptance: `engine/devtools/overlay.d` no longer allocates per-frame
  `string` for the FPS counter; mean frame time on the `light` scenario
  drops by the cost of those `format()` calls.

### Step 4 — Add the lint pass, gate CI on it

- `tools/lint.d` walks `source/engine/**.d`, finds every `@noGcStorage`
  struct and every `Pod!T` instantiation, asserts `isPod` recursively.
- Add `dub run --config=lint` to the build pipeline before `dub build
  --config=demo`.
- Acceptance: a deliberately broken PR (e.g. add `string label` to a
  component) fails CI with a readable error pointing at the offending
  field.

### Step 5 — Refactor the gc-benchmark `worst` scenario

- Mirror §3 above: replace `class NpcState` with `struct NpcDef`,
  `string materialName` with `StringId materialId`, the inventory linked
  list with `Handle!InventoryNode`, and `string` allocations with
  `FrameArena.sprintf`.
- Re-run the benchmark.
- **Acceptance:** max pause drops from ~9 ms to <2 ms (within noise of
  the openworld scenario). This is the empirical proof that the rules
  work and "fixing the GC" is the wrong question.

### Step 6 (deferred) — `Handle(T)` generalization across game code

Only needed once game code starts wanting cross-entity references beyond
the current ECS `EntityId`. Until then, `EntityId` is sufficient and
adding `Handle!T` to the public API risks API churn for no benefit.

---

## 6. What stays *out* of scope

The research report (§5–§7) ruled these out, and the rules in this
document don't change that calculus:

- **Approach A (incremental tri-color + write barriers in DMD).** Multi-
  month DMD fork, every assignment to a GC pointer pays a barrier even in
  `@nogc` code, breaks ABI compat with stock DMD/LDC. The architecture
  in this plan removes the workload that would justify it.
- **Approach C (frame-budgeted GC scheduler, `FrameGcScheduler`).** The
  benchmark proved it triples total pause under sustained pressure
  (§7.5 worst-case: 525 ms vs 195 ms / 1200 frames). Drop it from the
  engine plan. Keep `GC.disable()` / `GC.collect()` only for explicit
  scene transitions and loading screens, where slack is real and the
  heap is genuinely cold afterward.
- **`fork:1 parallel:N` as a default.** The benchmark showed it was
  within noise of stock GC on the worst case. Leave it as a per-game
  knob (`DRT_GCOPT`), not an engine-wide default.
- **`precise:1` as a non-default.** Always run with it. Add it to the
  engine launcher's default `DRT_GCOPT`. (This is a one-line change and
  does not deserve its own step.)

---

## 7. Cross-references

- [docs/incremental-gc-research.md](incremental-gc-research.md) — the
  research and benchmark numbers that motivate this plan.
- [source/demo/gc_benchmark.d](../source/demo/gc_benchmark.d) — the
  benchmark used in §5 step 5 to validate the rules empirically.
- [AGENTS.md](../AGENTS.md) — the engine-wide rules; this plan extends
  the existing `!hasIndirections!T` policy from "ECS components" to
  "any engine-owned storage."

---

## 8. TL;DR

D's GC is not broken. The 9 ms worst-case pause is a **data-structure
problem**: GC pointers were allowed to leak into multi-MB hot buffers.
The plan is five small primitives (`Pod!T`, `Handle!T`, `StringId`,
`FrameArena`, `@noGcStorage` + lint) that make the bad pattern a build
error. Game scripts keep their high-level D experience with the GC;
the engine stays pause-free by construction. No DMD fork, no custom GC,
no Approach-A heroics.
