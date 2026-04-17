# AI Agent Instructions — Game Engine (D)

This is a commercial-grade 3D game engine written in **D**, targeting Bevy Engine (Rust) quality. Read this before making any changes.

## Project Identity

- **Language**: D (dlang.org)
- **Build**: DUB (`dub.json`) — no Meson, no CMake
- **Compiler**: DMD for development, LDC2 for release builds
- **GPU**: WGPU-native via `extern(C)` bindings (not bindbc-wgpu)
- **Window/Input**: SDL3 via `extern(C)` bindings (not bindbc-sdl)
- **Platform**: Linux Wayland (primary), X11 (secondary)
- **ECS**: Sparse-set SoA with compile-time variadic templates

## Critical Rules

### Safety

- **Every module starts with `@safe:`** at the top level. This is non-negotiable.
- C interop functions are wrapped in `@trusted` with **minimal scope** — the `@trusted` block should contain only the unsafe call, not surrounding logic.
- **DIP1000** is enabled (`-preview=dip1000`). Respect scope/return semantics for pointers.
- Never use `@system` unless absolutely unavoidable. Explain why in a comment if you do.

### Bindings

- Bindings are **manual `extern(C) nothrow @nogc`** declarations in `source/bindings/`.
- **Do NOT** add dub dependencies for bindbc-sdl, bindbc-wgpu, or similar. We control our own bindings.
- When adding new WGPU/SDL3 functions, match the C header signatures exactly. Use `const(T)*` for C's `const T*` — never `T const*` (not valid D syntax).
- Opaque handles are `alias WGPUFoo = void*`.

### Architecture

- **Components are POD structs** — no classes, no inheritance, no GC pointers (`!hasIndirections!T` enforced at compile time).
- **Entities are `uint` IDs** (`EntityId` alias). No entity objects on the heap.
- **Systems are template functions or plain functions** — no interfaces, no virtual dispatch. GC is allowed in gameplay systems (see GC Policy).
- `World!(Components...)` generates one `ComponentStore(T)` per component type at compile time.
- **RAII** for GPU resources — use `Handle(T, releaseFn)` from `engine/core/resource.d` or scope guards.

### Code Style

- Module declarations match directory structure: `module engine.gpu.context;` for `source/engine/gpu/context.d`.
- Imports use the fully qualified module path: `import engine.core.log;`, not relative imports.
- Package modules (`package.d`) re-export submodules with `public import`.
- Prefer `immutable` for local variables that don't change. Use `const` for function parameters.
- No classes in engine code. Structs only. `@disable this(this)` for move-only types.
- Logging via `engine.core.log` — `info()`, `warn()`, `err()`, `fatal()`. Fatal calls `abort()`.

### Performance Principles

- **Cache locality first** — contiguous arrays (`T[]`), sparse-set iteration over dense storage.
- **No allocations in hot paths** — pre-allocate, reuse buffers, avoid `new` in frame loops.
- **Compile-time dispatch** — templates over interfaces. The compiler should know exact types.
- **No hash maps for component lookup** — sparse-set gives O(1) with two array reads.
- **Struct-based DOD** keeps the GC out of hot paths — it only sees a handful of root objects.

### GC Policy — Two Layers

The engine uses a two-layer model for GC: strict in the engine core, permissive for gameplay.

| Layer | GC | `@nogc` | Who writes it |
|:---|:---|:---|:---|
| **Engine core** (`engine/`) | Forbidden in frame path | Required on all frame-loop functions | Engine developers |
| **Gameplay / public API** (systems, game logic) | Allowed by default | Opt-in for performance-critical systems | Game developers |

**The boundary is the frame loop.** Everything inside `engine/` called from `pollEvents()` through `endFrame()` must be `@nogc`. Gameplay systems that consume `World.query()` ranges are free to use the GC.

**Component data is always strict:**
- Components must pass `!hasIndirections!T` — no slices, strings, delegates, or pointers to GC memory.
- This ensures the GC never scans the dense arrays in `ComponentStore`, even with thousands of entities.
- Dynamic arrays (`T[]`) used for internal ECS storage are GC roots, but their *contents* (POD structs) are never scanned.

**Gameplay system logic is free:**
- Systems are regular functions — they may allocate, use `string`, `format`, dynamic arrays, closures.
- For performance-critical systems, developers can opt into `@nogc` and use pre-allocated buffers.
- This mirrors Unity's model (C++ engine / C# gameplay) but within a single language.

## Directory Structure

```
source/
├── bindings/           # extern(C) declarations for C libraries
│   ├── sdl3.d          # SDL3 (window, events, input, Wayland properties, audio)
│   ├── wgpu.d          # WGPU-native (GPU API based on webgpu.h)
│   └── package.d       # Re-exports
├── engine/             # Core engine modules
│   ├── app.d           # Application framework (window + GPU + input loop)
│   ├── package.d       # Top-level re-export: `import engine;`
│   ├── assets/         # Disk-to-engine loaders
│   │   ├── bmp.d       # Uncompressed 24/32-bpp BMP decoder → Texture
│   │   └── gltf.d      # Minimal glTF 2.0 mesh loader (JSON + .bin) → TexMesh
│   ├── audio/          # SDL3-backed audio (AudioEngine, AudioClip)
│   │   └── engine.d
│   ├── core/           # Logging, RAII handles
│   ├── devtools/       # In-engine developer tooling
│   │   ├── gizmos.d    # Immediate-mode 3D line primitives (lineList, overlay depth)
│   │   └── overlay.d   # Structured FPS + label overlay atop TextRenderer
│   ├── ecs/            # Sparse-set ComponentStore, World template
│   ├── gpu/            # WGPU context, renderer, pipelines, buffers, shaders, text, shadow
│   │   ├── buffer.d    # Vertex, index, uniform, dynamic buffer helpers
│   │   ├── context.d   # WGPU lifecycle (instance→adapter→device→surface)
│   │   ├── pipeline.d  # Pipeline3D (instanced 3D, colored, textured) and PipelineText
│   │   ├── renderer.d  # Frame management (beginFrame/endFrame, depth buffer)
│   │   ├── shader.d    # WGSL shader module creation
│   │   ├── shaders.d   # Embedded WGSL sources (cube3D, colored3D, textured3D, text2D, shadowDepth)
│   │   ├── shadow.d    # ShadowMap + depth-only pipeline + directional light VP helper
│   │   └── text.d      # Bitmap font atlas (8×8 CP437), TextRenderer, FpsCounter
│   ├── graphics/       # High-level mesh, texture, material types
│   │   ├── mesh.d      # Mesh (position+normal)
│   │   ├── texmesh.d   # TexMesh (position+normal+uv), textured cube/quad primitives
│   │   ├── texture.d   # GPU Texture, Sampler, TGA loader, procedural checker/solid
│   │   ├── material.d  # Bind-group wrapper (uniform + sampler + albedo)
│   │   ├── primitives.d# Untextured primitive meshes
│   │   └── types.d     # Vert, TexVert, InstanceData, Color4
│   ├── math/           # Vec2/3/4, Mat4 (perspective, ortho, lookAt, transforms)
│   └── platform/       # SDL3 window wrapper, input state
│   └── scene/          # Camera, controllers, graph, batched 3D renderers
│       ├── camera.d
│       ├── controllers.d     # OrbitCamera, FlyCamera, FirstPersonCamera
│       ├── graph.d           # SceneGraph (Transform hierarchy, parent→child)
│       ├── scene3d.d         # Batched instanced renderer (colored)
│       └── scene3d_textured.d# Batched instanced renderer (textured + materials)
└── demo/               # Executable demos
    ├── main.d          # Clear-screen demo
    ├── benchmark.d     # 3D benchmark (1000 cubes, instanced, FPS overlay)
    ├── game.d          # Crystal Collector gameplay demo
    └── showcase.d      # Solar system (scene graph + textured materials)
```

## Build Commands

```bash
dub build --config=demo              # Debug build (clear-screen demo)
dub build --config=benchmark         # Debug build (3D benchmark)
dub build --config=demo --build=release  # Release build
dub run --config=demo                # Build and run demo
dub run --config=benchmark           # Build and run benchmark
dub build --config=library           # Build as static library
```

## Adding New Components

1. Define a POD struct (no classes, no pointers to GC memory):
   ```d
   struct Velocity { float x = 0, y = 0, z = 0; }
   ```
2. Add to your World type:
   ```d
   alias GameWorld = World!(Position, Velocity, Sprite);
   ```
3. Use in systems:
   ```d
   void moveSystem(W)(ref W world, float dt) {
       // iterate entities with both Position and Velocity
   }
   ```

## Adding New GPU Resources

1. Add the WGPU function declaration to `source/bindings/wgpu.d` matching the C99 signature.
2. Wrap in a `@trusted` helper in the appropriate `engine/gpu/` module.
3. Use `Handle(T, releaseFn)` or `scope(exit)` for cleanup.

## Adding New SDL3 Functions

1. Add the function signature to `source/bindings/sdl3.d` with `extern(C) nothrow @nogc`.
2. Use `@trusted` wrappers in `engine/platform/` modules.

## Common Mistakes to Avoid

- **Using `T const*` in bindings** — D syntax is `const(T)*`. The C-style postfix `const` doesn't compile.
- **Forgetting `@trusted` on callbacks** — `extern(C)` callbacks passed to WGPU/SDL3 need `@trusted` if they do pointer casts.
- **Returning scope variables** — DIP1000 forbids returning pointers to stack-allocated data. Use `return ref` or allocate on the caller's side.
- **Using classes for components** — breaks cache locality and involves GC. Components must be structs.
- **Adding bindbc dependencies** — we maintain our own bindings. Don't add third-party binding packages to dub.json.
- **Wrong WGPU enum values** — enum values in `bindings/wgpu.d` **must** match the official `webgpu.h` header exactly. Always cross-reference `https://github.com/webgpu-native/webgpu-headers/blob/main/webgpu.h` when adding or modifying enums. Mismatched values cause silent data corruption (e.g., wrong `WGPUVertexFormat` makes geometry invisible with no errors).
- **Forgetting `BindingNotUsed = 0`** — since webgpu.h v29, many enums (e.g., `WGPUBufferBindingType`, `WGPUSamplerBindingType`, `WGPUTextureSampleType`, `WGPUStorageTextureAccess`) have `BindingNotUsed = 0` before `Undefined = 1`. Default init values for sub-structs in `WGPUBindGroupLayoutEntry` must use `BindingNotUsed` (0), not `Undefined` (1).
