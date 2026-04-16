# Game Engine

A commercial-grade 3D game engine built in **D**, designed to match the architectural quality of Rust's Bevy Engine — proving that D is a viable language for high-performance, production game engines.

**WGPU + SDL3 | ECS with SoA Sparse Sets | `@safe` by Default | DIP1000**

## Why D?

D sits at the intersection of C++ performance and high-level ergonomics. This engine exploits what makes D uniquely powerful for games:

- **Compile-time metaprogramming** — variadic templates generate zero-overhead ECS stores, no runtime reflection
- **`@safe` by default** — memory safety without a borrow checker, with `@trusted` escape hatches for C interop
- **DIP1000 scope semantics** — stack-allocated references with compile-time lifetime tracking
- **No mandatory GC in hot paths** — struct-based DOD keeps the GC idle during frame execution. Engine core enforces `@nogc` on the entire frame loop while gameplay systems are free to use the GC for convenience
- **Direct C interop** — `extern(C)` bindings to SDL3 and WGPU-native with zero wrapper overhead

## Architecture

```
source/
├── bindings/              # C API bindings (extern(C), @nogc, nothrow)
│   ├── sdl3.d             # SDL3 — window, events, input, Wayland
│   └── wgpu.d             # WGPU-native — GPU resources, render pipeline
├── engine/
│   ├── app.d              # Application framework (window + GPU + input loop)
│   ├── core/
│   │   ├── log.d          # Logging (trace/info/warn/err/fatal)
│   │   └── resource.d     # RAII Handle(T) — move-only GPU resource wrapper
│   ├── ecs/
│   │   ├── store.d        # ComponentStore(T) — sparse-set SoA, O(1) ops
│   │   └── world.d        # World!(Components...) — compile-time registry
│   ├── gpu/
│   │   ├── buffer.d       # Vertex, index, uniform, dynamic buffer creation
│   │   ├── context.d      # WGPU lifecycle (instance→adapter→device→surface)
│   │   ├── pipeline.d     # Render pipeline builders (Pipeline3D, PipelineText)
│   │   ├── renderer.d     # Frame management (beginFrame/endFrame, depth buffer)
│   │   ├── shader.d       # WGSL shader module creation
│   │   ├── shaders.d      # Embedded WGSL shader sources (cube3D, text2D)
│   │   └── text.d         # Bitmap font atlas, TextRenderer, FpsCounter
│   ├── graphics/          # Mid-level graphics resources
│   │   ├── types.d        # Vert, InstanceData, Color4
│   │   ├── primitives.d   # Built-in vertex/index data (cube, pyramid, diamond)
│   │   └── mesh.d         # GPU mesh handle with static factories
│   ├── scene/             # Game-level scene management
│   │   ├── camera.d       # Perspective camera (create, lookAt, viewProjection)
│   │   └── scene3d.d      # Batched instanced 3D renderer (begin/draw/end)
│   ├── math/
│   │   ├── vec.d          # Vec2, Vec3, Vec4
│   │   └── mat.d          # Mat4 (perspective, lookAt, transforms)
│   └── platform/
│       ├── window.d       # SDL3 window + Wayland handle extraction
│       └── input.d        # Per-frame keyboard/mouse state tracking
└── demo/
    ├── main.d             # Minimal clear-screen demo
    ├── game.d             # Crystal Collector 3D — high-level API demo
    └── benchmark.d        # 3D benchmark — 1000 spinning cubes + FPS overlay
```

### Design Principles

| Principle | Implementation |
|:---|:---|
| **Bevy-like ECS** | Sparse-set stores with compile-time `World!(Components...)` — no vtables, no runtime type lookup |
| **`@safe` by default** | Every module is `@safe:` at top level. C interop wrapped in `@trusted` with minimal surface |
| **Data-Oriented Design** | Components are POD structs in contiguous `T[]` arrays. Entities are `uint` IDs |
| **Zero-overhead abstractions** | Template systems resolved at compile time. RAII handles for GPU resources |
| **GC discipline** | GC forbidden in engine frame loop (`@nogc`). Allowed in gameplay systems. Components enforce `!hasIndirections` — no GC pointers in data |
| **Native Wayland** | SDL3 extracts `wl_display`/`wl_surface` for WGPU surface creation. No X11 dependency |

### ECS — Bevy-Class Performance in D

The ECS is the heart of the engine, inspired by Bevy's sparse-set architecture:

- **`ComponentStore(T)`** — O(1) add/remove/lookup via sparse-set, swap-and-pop removal, dense iteration over contiguous arrays
- **`World!(Components...)`** — variadic template generates one store per component at compile time. Zero runtime overhead for type dispatch
- **Entities** — plain `uint` IDs, no heap allocation, O(1) alive check

```d
// Define a world with your component types
alias GameWorld = World!(Position, Velocity, Sprite, Health);

auto world = GameWorld();
auto player = world.spawn();
world.set(player, Position(0, 0, 0));
world.set(player, Velocity(1, 0, 0));
```

### GPU Stack

| Layer | Technology | Purpose |
|:---|:---|:---|
| Window | SDL3 | Cross-platform window, events, Wayland-native |
| GPU API | WGPU-native | Vulkan/Metal/DX12 via WebGPU abstraction |
| Bindings | `extern(C)` | Direct C99 API — no bindbc, no wrapper overhead |
| Resources | `Handle(T)` | RAII move-only wrappers, deterministic release |

### GC Policy — Engine vs Gameplay

The engine uses a **two-layer GC model**, similar to Unity (C++ engine / C# gameplay) but within a single language:

| Layer | GC | Who |
|:---|:---|:---|
| **Engine core** (`engine/`) | Forbidden — `@nogc` on all frame-loop functions | Engine developers |
| **Gameplay** (systems, game logic) | Allowed by default — opt into `@nogc` for perf-critical systems | Game developers |

**Component data is always strict** — `ComponentStore` enforces `!hasIndirections!T` at compile time, so the GC never scans dense arrays even with thousands of entities. **System logic is free** — gameplay code may allocate, use `string`, `format`, dynamic arrays, and closures. Developers who need maximum performance can mark individual systems `@nogc` and use pre-allocated buffers.

```d
// Gameplay system — GC is allowed, write naturally
void damageSystem(W)(ref W world) {
    int[] toKill;  // GC-allocated dynamic array
    foreach (id; world.query!(Health, DamageReceived)()) {
        auto hp = world.get!Health(id);
        hp.current -= world.get!DamageReceived(id).amount;
        world.set(id, hp);
        if (hp.current <= 0) toKill ~= id;
    }
    foreach (id; toKill) world.destroy(id);
}

// Same system, optimized — opt into @nogc when needed
void damageSystem(W)(ref W world) @nogc nothrow {
    EntityId[128] killBuf = void;
    size_t killCount = 0;
    foreach (id; world.query!(Health, DamageReceived)()) {
        auto hp = world.get!Health(id);
        hp.current -= world.get!DamageReceived(id).amount;
        world.set(id, hp);
        if (hp.current <= 0 && killCount < killBuf.length)
            killBuf[killCount++] = id;
    }
    foreach (id; killBuf[0 .. killCount]) world.destroy(id);
}
```

## Requirements

- **D compiler**: DMD or LDC2
- **SDL3**: `libSDL3.so` (system package or built from source)
- **WGPU-native**: `libwgpu_native.a` in `libs/` (see below)
- **OS**: Linux with Wayland (primary target)

## Building

```bash
# Build the demo (clear-screen)
dub build --config=demo

# Build the 3D benchmark (1000 spinning cubes + FPS)
dub build --config=benchmark

# Build with optimizations (LDC2 recommended for production)
dub build --config=demo --build=release

# Run
dub run --config=demo
dub run --config=benchmark

# Build as library (for embedding in other projects)
dub build --config=library
```

### Installing WGPU-native

```bash
curl -sL https://github.com/gfx-rs/wgpu-native/releases/latest/download/wgpu-linux-x86_64-release.zip \
  -o /tmp/wgpu.zip
unzip -o /tmp/wgpu.zip -d /tmp/wgpu
cp /tmp/wgpu/lib/libwgpu_native.a libs/
```

## Demos

### Clear-Screen Demo

The minimal proof that the full stack works (SDL3 window → Wayland surface → WGPU instance → adapter → device → render pass → present):

```d
import engine;

void main() {
    auto app = App.create("Game Engine Demo", 1280, 720);
    scope(exit) app.destroy();

    while (app.running) {
        app.pollEvents();
        if (app.input.keyPressed(Key.escape)) app.close();

        auto frame = app.beginFrame(Color(0.05, 0.05, 0.12, 1.0));
        app.endFrame(frame);
    }
}
```

### 3D Benchmark

1000 spinning cubes rendered with instanced drawing, directional N·L lighting, depth buffer, and a real-time FPS overlay using a bitmap font atlas. Runs at **~1800 FPS** on Linux/Vulkan (uncapped, mailbox present mode).

Features demonstrated:
- **Instanced rendering** — per-instance model matrices via vertex attributes (4×vec4)
- **Depth buffer** — depth24Plus with clear-to-1.0
- **WGSL shaders** — vertex transforms + directional lighting in fragment stage
- **Bitmap text** — embedded 8×8 CP437 font atlas (R8Unorm), alpha-blended overlay
- **Uniform buffers** — view-projection matrix uploaded per frame

```bash
dub run --config=benchmark
```

## Roadmap

- [x] Phase 1 — Core stack (SDL3 + WGPU + ECS + math + clear screen)
- [x] Phase 2 — Mesh rendering (vertex/index buffers, WGSL shaders, render pipeline)
- [x] Phase 3 — Instanced rendering, depth buffer, directional lighting
- [x] Phase 4 — Bitmap text rendering, FPS overlay
- [x] Phase 5 — 3D Benchmark (1000 cubes, ~1800 FPS)
- [x] Phase 6 — Materials and textures (RGBA8 textures, samplers, TGA loader, textured pipeline)
- [x] Phase 7 — Scene graph and transforms (parent-indexed hierarchy, one-pass world matrices)
- [ ] Phase 8 — 3D camera system (orbit, fly, first-person)
- [ ] Phase 9 — Shadows (shadow mapping)
- [ ] Phase 10 — Asset pipeline (glTF, image loading)
- [ ] Phase 11 — Audio (SDL3 audio subsystem)
- [ ] Phase 12 — Editor tooling

## Documentation

- [docs/graphics.md](docs/graphics.md) — GPU architecture and rendering pipeline
- [docs/why-this-is-fast.md](docs/why-this-is-fast.md) — Data-Oriented Design explained for programmers from other languages

## License

Proprietary — Copyright © 2022–2026, Leonardo Tada
