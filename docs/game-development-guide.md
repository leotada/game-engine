# Game Development Guide

This guide explains how to build a 3D game using the engine's high-level API. The engine follows a Godot-inspired 3-layer model:

| Layer | Purpose | Modules |
|:------|:--------|:--------|
| **Scene** | Game-level: camera, batched renderer | `engine.scene.*` |
| **Graphics** | Resources: meshes, colors, primitives | `engine.graphics.*` |
| **GPU** | Low-level WGPU wrappers (power users) | `engine.gpu.*` |

Most games only need `engine.app`, `engine.scene`, `engine.graphics`, and `engine.math`.

---

## Quick Start — Minimal 3D Game

```d
module mygame;

import engine.app;
import engine.gpu.text;
import engine.math.vec;
import engine.graphics.types : Color4;
import engine.graphics.mesh : Mesh;
import engine.scene.camera : Camera;
import engine.scene.scene3d : Scene3D;
import engine.platform.input : Key;

void main() {
    auto app = App.create("My Game", 1280, 720);

    auto scene   = Scene3D.create(app.gpu);
    scope(exit) scene.destroy();
    auto cube    = Mesh.cube(app.gpu);
    scope(exit) cube.destroy();
    auto camera  = Camera.create(0.9, 1280, 720);
    auto textRenderer = TextRenderer.create(app.gpu, 1280, 720);
    scope(exit) textRenderer.destroy();
    auto fps = FpsCounter.create();

    while (app.running()) {
        app.pollEvents();
        fps.tick();
        if (app.input.keyPressed(Key.escape)) break;

        camera.lookAt(Vec3(0, 5, 10), Vec3(0, 0, 0));
        scene.begin(camera);
        scene.draw(cube, Vec3(0, 0, 0), Vec3(1, 1, 1), Color4.white());
        
        auto frame = app.beginFrame(Color4(0.1, 0.1, 0.15));
        if (!frame.valid) continue;
        scene.end(frame);

        textRenderer.beginFrame();
        textRenderer.drawText(frame, fps.text(), 10, 10, 2);
        app.endFrame(frame);
    }
}
```

---

## Step-by-Step Setup

### 1. Create the Application

`App` ties together the window, GPU context, renderer, and input system.

```d
auto app = App.create("Window Title", 1280, 720);
```

This creates an SDL3 window, initializes WGPU (instance → adapter → device → surface), and sets up input tracking. The app owns all these resources and cleans up on destruction.

### 2. Create a Scene3D

`Scene3D` manages the 3D render pipeline, uniform buffers, bind groups, and per-mesh instance batches internally. You never touch pipelines or GPU buffers directly.

```d
auto scene = Scene3D.create(app.gpu);
scope(exit) scene.destroy();
```

**Important:** Create `Scene3D` before creating meshes. One `Scene3D` per game is typical.

### 3. Create Meshes

`Mesh` owns GPU vertex and index buffers for a 3D shape. Built-in primitives are available as static factories:

```d
auto cube    = Mesh.cube(app.gpu);
auto pyramid = Mesh.pyramid(app.gpu);
auto diamond = Mesh.diamond(app.gpu);
scope(exit) cube.destroy();
scope(exit) pyramid.destroy();
scope(exit) diamond.destroy();
```

For custom geometry, use `Mesh.fromData`:

```d
import engine.graphics.types : Vert;

auto myMesh = Mesh.fromData(app.gpu, myVertices[], myIndices[]);
scope(exit) myMesh.destroy();
```

Each `Vert` has `float[3] pos` and `float[3] normal`.

### 4. Create a Camera

`Camera` holds perspective projection parameters and view position.

```d
// From aspect ratio
auto camera = Camera.create(0.9, 16.0 / 9.0);

// From pixel dimensions (convenience)
auto camera = Camera.create(0.9, 1280, 720);

// With custom near/far planes
auto camera = Camera.create(0.9, 1280, 720, 0.1, 200.0);
```

Update the camera each frame:

```d
camera.lookAt(eyePosition, targetPosition);
```

### 5. Create a TextRenderer (Optional)

`TextRenderer` provides bitmap font text rendering (8×8 pixel CP437 font, 96 ASCII glyphs).

```d
auto textRenderer = TextRenderer.create(app.gpu, 1280, 720);
scope(exit) textRenderer.destroy();
```

### 6. FpsCounter (Optional)

```d
auto fps = FpsCounter.create();
// In game loop:
immutable dt = fps.tick();  // returns delta time in seconds
fps.text();                 // returns "FPS: 60" style string
```

---

## The Game Loop

The game loop follows this order every frame:

```
pollEvents → game logic → camera update → scene.begin → scene.draw* → beginFrame → scene.end → text → endFrame
```

### Frame Structure

```d
while (app.running()) {
    // 1. Poll input events
    app.pollEvents();
    immutable dt = fps.tick();
    if (app.input.keyPressed(Key.escape)) break;

    // 2. Game logic (physics, AI, collision, etc.)
    updateGameState(dt);

    // 3. Update camera
    camera.lookAt(eyePos, targetPos);

    // 4. Queue draw calls (CPU-side batching)
    scene.begin(camera);
    scene.draw(cube, position, scale, color);
    scene.draw(cube, otherPos, otherScale, otherColor, rotationY);
    scene.drawMatrix(pyramid, modelMatrix, color);

    // 5. Begin GPU frame (acquire surface, clear)
    auto frame = app.beginFrame(Color4(0.05, 0.06, 0.12));
    if (!frame.valid) continue;

    // 6. Submit 3D scene to GPU
    scene.end(frame);

    // 7. Draw HUD text (on top of 3D scene)
    textRenderer.beginFrame();
    textRenderer.drawText(frame, "Score: 10", 10, 10, 2);

    // 8. Present
    app.endFrame(frame);
}
```

**Why this order?** Scene draw calls are CPU-side batching — they collect instance data into arrays. Only `scene.end(frame)` actually uploads to the GPU and issues draw commands. This lets you call `scene.draw` freely without worrying about GPU state.

---

## API Reference

### Color4

RGBA color with float components. Used everywhere in the high-level API.

```d
// Manual construction
Color4(0.2, 0.35, 0.2)       // RGB, alpha defaults to 1.0
Color4(0.2, 0.35, 0.2, 0.5)  // RGBA

// Named colors
Color4.white()
Color4.red()
Color4.green()
Color4.blue()
Color4.yellow()
Color4.black()
```

### Vec3 / Mat4

```d
// Vectors
auto pos = Vec3(1.0, 2.0, 3.0);
auto dir = pos.normalized();
auto len = pos.length();
auto sum = pos + Vec3(1, 0, 0);
auto scaled = pos * 2.0;

// Matrices
auto model = Mat4.translation(x, y, z)
           * Mat4.rotationY(angle)
           * Mat4.scaling(sx, sy, sz);

auto view = Mat4.lookAt(eye, target, up);
auto proj = Mat4.perspective(fovY, aspect, near, far);
```

### Scene3D

```d
auto scene = Scene3D.create(app.gpu);

// Per frame:
scene.begin(camera);                              // reset batches, upload VP matrix
scene.draw(mesh, position, scale, color);          // queue instance (uniform scale)
scene.draw(mesh, pos, scale, color, rotationY);    // with Y-axis rotation
scene.drawMatrix(mesh, modelMatrix, color);        // full transform control
scene.end(frame);                                  // upload + draw all batches

scene.destroy();
```

`Scene3D` supports up to **16 different meshes** and **256 instances per mesh** per frame. Instances of the same mesh are automatically batched into a single instanced draw call.

### Camera

```d
auto camera = Camera.create(fovY, width, height);
camera.lookAt(eyePosition, targetPosition);

// Access/modify fields directly:
camera.fovY   = 1.2;
camera.near   = 0.5;
camera.far    = 200.0;
camera.up     = Vec3(0, 1, 0);
```

### Mesh

```d
// Built-in primitives
auto cube    = Mesh.cube(app.gpu);       // 24 vertices, 36 indices
auto pyramid = Mesh.pyramid(app.gpu);    // 16 vertices, 18 indices
auto diamond = Mesh.diamond(app.gpu);    // 24 vertices, 24 indices

// Custom geometry
auto mesh = Mesh.fromData(app.gpu, vertices[], indices[]);

mesh.destroy();  // releases GPU buffers
```

Meshes are move-only (no copying). Use `ref` when passing to functions.

### TextRenderer

```d
auto text = TextRenderer.create(app.gpu, screenWidth, screenHeight);

// Per frame:
text.beginFrame();
text.drawText(frame, "Hello World", x, y, scale);  // scale: 1=8px, 2=16px, 3=24px

text.destroy();
```

### Input

```d
// Pressed this frame (rising edge)
if (app.input.keyPressed(Key.space)) { ... }

// Held down (continuous)
if (app.input.keyDown(Key.w)) { ... }

// Available keys: Key.w, Key.a, Key.s, Key.d, Key.space, Key.escape,
//                 Key.left, Key.right, Key.up, Key.down, etc.
```

### App

```d
auto app = App.create("Title", width, height);

app.running()      // true until window close or app.close()
app.close()        // request exit
app.pollEvents()   // process SDL3 events, update input state

// Frame management
auto frame = app.beginFrame(Color4(r, g, b));  // clear + begin render pass
app.endFrame(frame);                            // submit + present

// Access subsystems
app.gpu     // GpuContext — pass to Mesh/Scene3D/TextRenderer factories
app.input   // InputState — keyboard/mouse state
```

---

## Architecture Layers

### When to Use Each Layer

| I want to... | Use |
|:---|:---|
| Draw 3D objects with colors | `Scene3D` + `Mesh` + `Camera` |
| Render HUD text | `TextRenderer` |
| Create custom mesh shapes | `Mesh.fromData` + `Vert` |
| Custom shader/pipeline | `engine.gpu.pipeline`, `engine.gpu.shader` |
| Direct GPU buffer management | `engine.gpu.buffer` |
| Raw WGPU calls | `bindings.wgpu` |

### Data Flow

```
Camera ─────────────────────┐
                            ▼
Mesh.cube() ───► Scene3D.draw() ───► scene.begin(camera)
Mesh.pyramid()                       scene.draw(mesh, pos, scale, color)
Mesh.diamond()                       scene.draw(mesh, pos, scale, color)
                                     ...
                                     ▼
                              app.beginFrame(clearColor)
                                     ▼
                              scene.end(frame)  ← uploads + draws all batches
                                     ▼
                              textRenderer.drawText(frame, ...)
                                     ▼
                              app.endFrame(frame) ← submit + present
```

---

## Building

```bash
# Build the game
dub build --config=game

# Run the game
dub run --config=game

# Build with optimizations
dub build --config=game --build=release

# Build the benchmark (low-level API demo)
dub build --config=benchmark
```

### Requirements

- **D compiler**: DMD or LDC2
- **SDL3**: `libSDL3.so` (system package or built from source)
- **WGPU-native**: `libwgpu_native.a` in `libs/`
- **OS**: Linux with Wayland

### Installing WGPU-native

```bash
curl -sL https://github.com/gfx-rs/wgpu-native/releases/latest/download/wgpu-linux-x86_64-release.zip \
  -o /tmp/wgpu.zip
unzip -o /tmp/wgpu.zip -d /tmp/wgpu
cp /tmp/wgpu/lib/libwgpu_native.a libs/
```

---

## Tips

- **`scope(exit)`** — Always pair resource creation with `scope(exit) resource.destroy()` to ensure cleanup.
- **`@safe`** — Mark your game module `@safe:` at the top. The engine API is fully `@safe`.
- **Delta time** — Use `fps.tick()` return value for frame-independent movement: `pos = pos + velocity * dt`.
- **GC is allowed** — Game code can freely use dynamic arrays, `format`, closures. The engine core is `@nogc` internally so GC pauses stay minimal.
- **Multiple meshes** — `Scene3D` batches instances of the same mesh automatically. Drawing 100 cubes at different positions costs one draw call.
