# Why This Game Engine Is Fast — Explained for Programmers from Other Languages

This engine uses the same architectural principles as Rust's **Bevy Engine** — but implemented in D. If you've written Python, Java, C#, or even Rust, this document explains **why our architecture is fast** and how D's compile-time metaprogramming achieves Bevy-class performance without a borrow checker.

---

## The Problem: 600 Particles at 60 FPS

Imagine a game with 600 particles on screen. Every frame (ideally 60 times per second), the engine must:

1. **Update physics** for each particle (gravity, velocity, position)
2. **Check timeouts** for each particle (should it disappear?)
3. **Draw** each particle on screen

That's ~1,800 operations per frame, 108,000 per second. Every nanosecond counts.

---

## How Python Would Do It (The Slow Way)

```python
class Component:
    pass

class Particle(Component):
    def __init__(self):
        self.velocity_x = 0.0
        self.velocity_y = 0.0
        self.mass = 1.0
        self.gravity = False

class Circle(Component):
    def __init__(self):
        self.radius = 5.0
        self.color = "gray"

class Entity:
    def __init__(self):
        self.components = {}    # {"Particle": <Particle>, "Circle": <Circle>}
        self.position_x = 0.0
        self.position_y = 0.0

class ParticleSystem:
    def run(self, entities):
        for entity in entities:
            particle = entity.components.get("Particle")  # dictionary lookup
            if particle:
                self.update_physics(entity, particle)
```

This is clean, readable code. But it has **3 hidden performance killers**.

---

## Killer #1: Objects Are Scattered in Memory

### The Python Way (Bad for Speed)

When you create objects in Python (or classes in many languages), each object gets its own chunk of memory, placed **wherever the allocator finds space**:

```
Memory layout:
[Particle_0] ... [Circle_3] ... [Particle_1] ... [Entity_5] ... [Particle_2]
     ↑                              ↑                               ↑
   addr 1000                      addr 5400                       addr 8200
```

Each particle lives at a random address. When the CPU needs to process particles one by one, it has to **jump around in memory** like flipping between random pages of a book.

### Why This Is Slow: The CPU Cache

Your CPU has a small, ultra-fast memory called the **cache** (think of it as the CPU's "clipboard"). When the CPU reads data from address 1000, it automatically copies a chunk of **nearby memory** (typically 64 bytes) into the cache — because programs *usually* need nearby data next.

But if Particle_0 is at address 1000 and Particle_1 is at address 5400, that "nearby" prediction is **completely wrong**. The CPU must go to slow main memory for every single particle. This is called a **cache miss**, and it costs ~100 nanoseconds vs ~1 nanosecond for a cache hit. That's **100x slower**.

### Our Way (Fast)

We store all particles in a **contiguous array** — one right after the other:

```
Memory layout:
[Particle_0][Particle_1][Particle_2][Particle_3][Particle_4]...
     ↑           ↑           ↑
   addr 1000   addr 1032   addr 1064    ← all sequential!
```

Now when the CPU loads Particle_0 into cache, Particle_1 and Particle_2 come along **for free**. Processing 600 particles becomes a straight sprint through memory instead of a scavenger hunt.

**In our code:** `ComponentStore(T)` in `engine/ecs/store.d` stores all components of the same type in a `T[] dense` array — a contiguous block. This is the same sparse-set pattern used by Bevy's ECS in Rust.

---

## Killer #2: Dictionary Lookups Are Expensive

### The Python Way

```python
particle = entity.components["Particle"]  # hash "Particle", probe table, follow pointer
```

A Python dictionary lookup involves:
1. **Hash** the key string `"Particle"` → compute a number
2. **Probe** the hash table to find the slot
3. **Follow a pointer** to the actual object
4. **Compare** keys to handle collisions

This is O(1) on average, but with a big constant — each step touches different memory, causing more cache misses.

### Our Way: Sparse Set (True O(1))

We use a **sparse array** — literally just indexing into an array:

```
sparse[entity_id] → index into dense array

// To get Particle for entity 42:
uint idx = sparse[42];          // ONE array read
Particle* p = &dense[idx];     // ONE array read, direct pointer
```

Two array reads. No hashing. No pointer chasing. No string comparisons. The CPU can even **predict** these reads ahead of time (prefetching).

**In our code:** `ComponentStore(T)` in `engine/ecs/store.d` has `sparse[]` (entity ID → dense index) and `dense[]` (contiguous components). Bevy uses the exact same data structure.

---

## Killer #3: Virtual Dispatch (The Invisible Cost)

### What Python Does Every Call

In Python, *every method call* is "virtual" — the interpreter looks up the method at runtime:

```python
system.run(entities)
# Python: "What class is `system`? Does it have `run`? Let me check the MRO..."
```

In compiled languages like C++ or D, using `interface` or base classes creates a similar problem called **virtual dispatch**:

```
// Old code (D, but same concept as C++):
interface ISystem {
    void run(EntityManager em, double dt);
}

class ParticleSystem : ISystem {
    void run(EntityManager em, double dt) { ... }
}

// When called:
system.run(em, dt);
//   1. Read the vtable pointer from the object → cache miss
//   2. Read the function pointer from the vtable → cache miss
//   3. Jump to that address → branch misprediction penalty
```

The CPU has a **branch predictor** that guesses where the next instruction is. With virtual dispatch, it **can't predict** which function will be called, because it depends on the runtime type. This causes a **pipeline stall** — the CPU has to throw away speculative work and start over, costing ~10-20 cycles each time.

### Our Way: Templates (Compile-Time Dispatch)

In D, a **template** is like a code generator that runs at compile time:

```d
// In our engine, World!(Components...) generates stores at compile time.
// Systems are plain functions — no interface, no vtable:

void physicsSystem(W)(ref W world, double dt) {
    // The compiler knows the exact type of W and generates direct calls
    foreach (id; 0 .. world.entityCount()) {
        if (auto vel = world.getPtr!Velocity(id)) {
            auto pos = &world.get!Position(id);
            pos.x += vel.x * dt;
            pos.y += vel.y * dt;
        }
    }
}
```

The `(W)` part means: "generate a **specialized version** of this function for the exact type of World I'm using." The compiler sees *exactly* which stores to access and generates **direct function calls** — no vtable, no pointer indirection, no branch misprediction.

This is how D matches Bevy's performance: Bevy uses Rust's monomorphization (generics compiled to concrete types), and D uses template instantiation — the same compile-time specialization strategy.

Think of it like this:
- **Virtual dispatch** = calling a phone number that forwards to another number (you don't know where it goes)
- **Templates** = the compiler **hardcodes** the destination at build time (zero overhead)

---

## Summary: Three Optimizations, One Pattern

| Problem | Python/OOP Way | Our Way | Speedup |
|:---|:---|:---|:---|
| Memory layout | Objects scattered on heap | Contiguous arrays (`T[]`) | ~10-100x fewer cache misses |
| Component lookup | Dictionary (hash + pointer) | Sparse set (two array reads) | ~5-10x faster |
| System dispatch | Virtual calls (vtable) | Templates (compile-time) | Eliminates ~10-20 cycle penalty per call |

The unifying principle is **Data-Oriented Design**: instead of organizing code around *objects* (Entity has Components), organize it around *data* (all Positions in one array, all Particles in another). The CPU loves predictable, sequential memory access.

---

## Visual: Before vs After

```
BEFORE (Object-Oriented):
┌─────────────────────────────────────────────────────────┐
│  Entity_0 ─→ dict ─→ Particle_0 (addr 1000)            │
│                  ─→ Circle_0   (addr 5400)              │
│  Entity_1 ─→ dict ─→ Particle_1 (addr 8200)  ← RANDOM  │
│                  ─→ Circle_1   (addr 2100)              │
│  ...scattered across memory, vtable for every call...   │
└─────────────────────────────────────────────────────────┘

AFTER (Data-Oriented):
┌─────────────────────────────────────────────────────────┐
│  Particles: [P0][P1][P2][P3][P4]... ← CONTIGUOUS       │
│  Circles:   [C0][C1][C2][C3][C4]... ← CONTIGUOUS       │
│  Positions: [X0][X1][X2][X3][X4]... ← CONTIGUOUS       │
│  Entity = just a number (uint): 0, 1, 2, 3, 4...       │
│  Systems = direct function calls, no vtable             │
└─────────────────────────────────────────────────────────┘
```

---

## Analogy

Imagine you manage a warehouse with 600 packages.

- **OOP approach**: Each package is in a random spot. To process all packages, you walk back and forth across the warehouse for each one. Each package has a note saying "to process this, go to the office and ask which procedure to use" (virtual dispatch).

- **DOD approach**: All packages are lined up in a single row. You walk straight down the line processing each one. The procedure is printed directly on each package (templates = hardcoded instructions).

Same work, dramatically less wasted motion.

---

## How We Compare to Bevy (Rust)

Bevy is the gold standard for ECS game engines. Here's how our D engine achieves the same architectural advantages:

| Feature | Bevy (Rust) | This Engine (D) |
|:---|:---|:---|
| ECS storage | Sparse-set `Table` + `SparseSet` | `ComponentStore(T)` sparse-set |
| Component registration | `#[derive(Component)]` macro | `World!(Position, Velocity, ...)` variadic template |
| System dispatch | Trait-based scheduling, monomorphized | Template functions, compile-time resolved |
| Memory safety | Borrow checker (compile-time) | `@safe` by default + DIP1000 scopes |
| GPU abstraction | `wgpu` (Rust crate) | `wgpu-native` (same engine, C API) |
| Zero-cost abstractions | Rust generics → monomorphization | D templates → compile-time instantiation |
| Entities | `Entity` newtype (u64) | `EntityId` alias (uint) |
| Hot path GC | N/A (no GC) | No GC in hot paths — structs in contiguous arrays |

### Where D Has an Edge

- **Faster compile times** — DMD compiles in seconds vs minutes for Rust
- **`mixin` and `static foreach`** — more powerful compile-time code generation than Rust macros
- **C interop without FFI boilerplate** — `extern(C)` is a single attribute, not `unsafe extern "C"` blocks
- **Optional GC** — useful for tooling/editor code while keeping hot paths GC-free

### Where Bevy Has an Edge

- **Larger ecosystem** — more plugins, community, documentation
- **Lifetime guarantees** — borrow checker prevents data races at compile time
- **Parallel system scheduling** — Bevy auto-parallelizes systems based on component access

Our goal: match Bevy's runtime performance and architectural quality, while leveraging D's ergonomics and compile-time power for faster iteration.
