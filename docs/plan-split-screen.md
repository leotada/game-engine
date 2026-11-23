# Plan: Split-Screen Local Co-op

> **Status:** pending · Priority: medium · See [roadmap.md](roadmap.md)

## Objective

Render **2–4 independent cameras into sub-rectangles of the main window** in the same frame, so several players can share one screen (local co-op / versus). Pair the rendering work with the minimum input layer local multiplayer needs: **gamepads, per-player input, and assigning players to slots**.

Goals:

- One frame, one HDR target, one post-processing chain, N camera views (`MAX_VIEWS = 4`).
- World-space data (instances, lights, shadow maps, IBL) is uploaded **once per frame** and shared by all views. Only the view/projection uniforms differ per view.
- The existing single-camera API keeps working unchanged. Split-screen is opt-in.
- No GC allocation in the frame path. All per-view state is fixed-size and `isPod`.
- The same layout math drives the standalone player, the demos, and the editor's Game view preview.

## Current State

Repository paths and the facts this plan depends on:

- [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d): `Renderer.beginFrame` opens **one** render pass on the full-window HDR target (`rgba16float`) plus `depth24Plus`, and clears both. `resolvePost` closes it, runs post into the swapchain, then reopens a load-only present pass for UI.
  - `FrameContext.setViewport(x, y, w, h, targetW, targetH)` already exists. It sets viewport and scissor on the current pass. The editor uses it to fit the 3D scene into a docked panel (`source/editor/editor_app.d:311`).
  - `FrameContext.setBindGroup` always passes `0, null` dynamic offsets.
- [`source/engine/scene/scene3d.d`](../source/engine/scene/scene3d.d) and [`scene3d_textured.d`](../source/engine/scene/scene3d_textured.d): `begin(camera)` writes the camera matrix into **a single uniform buffer** with `wgpuQueueWriteBuffer`. `end(frame)` uploads every batch's instance buffer the same way, then records the draws.
  - `Scene3DTextured`'s `FrameUniforms` (1088 bytes) holds `viewProj` and `cameraPos` **next to** all light data. Binding 0 of `@group(0)` is created in `rebuildFrameBindGroup` (around line 472) without `hasDynamicOffset`.
- [`source/engine/devtools/gizmos.d`](../source/engine/devtools/gizmos.d): `begin(viewProj)` does the same thing with a single 64-byte uniform buffer.
- [`source/engine/gpu/post.d`](../source/engine/gpu/post.d): `PostProcessor.execute` runs bloom, tonemap, and FXAA over the **whole** HDR target. It has no idea viewports exist.
- [`source/engine/gpu/shadow.d`](../source/engine/gpu/shadow.d): `directionalLightVP(direction, sceneCenter, sceneRadius)` is fit to the scene, **not to the camera**. Point and spot shadows depend on the light only. So every shadow map is view-independent and can be shared by all views.
- [`source/engine/scene/camera.d`](../source/engine/scene/camera.d): `Camera` is a plain POD lens with an `aspect` field. Nothing updates `aspect` automatically.
- [`source/engine/editor/components.d`](../source/engine/editor/components.d): the `Camera3D` ECS component has `current`, `fovYDeg`, `nearPlane`, and `farPlane`. `findCurrentCamera` and `sceneCameraToGpu` live in [`engine/editor/demo_level.d`](../source/engine/editor/demo_level.d), even though they are not editor-specific.
- [`source/engine/platform/input.d`](../source/engine/platform/input.d): `InputState` covers keyboard, mouse, and text only. [`source/bindings/sdl3.d`](../source/bindings/sdl3.d) has **no gamepad or joystick bindings**: no `SDL_INIT_GAMEPAD`, no gamepad events, no `SDL_Gamepad*` functions.
- [`tools/player/player_main.d`](../tools/player/player_main.d): the standalone player currently ticks physics and only clears the screen. It does not render the scene yet.
- [`source/engine/audio/engine.d`](../source/engine/audio/engine.d): no spatial audio and no listener concept.
- No frustum culling exists in the scene renderers. Every queued instance is drawn.

### Why this is not "call `setViewport` N times"

The naive loop looks right, but it renders every view from the **last** camera:

```d
foreach (i; 0 .. n) {
    frame.setViewport(rect[i]...);
    scene.begin(cam[i]);   // wgpuQueueWriteBuffer(uniformBuf, cam[i])
    drawMeshes();
    scene.end(frame);      // wgpuQueueWriteBuffer(instanceBuf, ...) + draws
}
```

`wgpuQueueWriteBuffer` runs on the queue timeline **before** the command buffer that holds the draws is submitted in `endFrame`. All N writes to the same buffer land first, the last one wins, and then all N sets of draws execute against it. The instance buffers have the same problem. This is the main technical constraint of this plan. Per-view data must live at **different buffer offsets** that are all written before submit and selected per draw. That means dynamic uniform offsets.

## Out of Scope

- Separate OS windows per player, or multiple monitors.
- Per-view post-processing settings (different exposure or bloom per player). See the optional SS-9.
- Per-view frustum culling. No culling exists today. SS-2 keeps the API ready for it (see "Future: per-view culling").
- Spatial audio and multiple listeners. The audio engine has no listener yet. Revisit when spatial audio lands.
- Online multiplayer. See [plan-networking.md](plan-networking.md). Split-screen and networking will compose later as N local players on one client.
- A generic action-mapping/rebinding system. This plan defines a small fixed virtual-gamepad model and nothing more.
- Dynamic split (Voronoi or merging split-screen, as in some co-op games). It is a possible follow-up on top of the same `ViewSet`.

## Dependencies

- None blocking for the rendering phases (SS-0 to SS-3).
- SS-6 (player integration) needs the standalone player to render the scene. That is not done today. Either land minimal scene rendering in `tools/player/player_main.d` first, or include it in SS-6.
- SS-8 (editor preview) reuses the existing Game view canvas (`editor/panels/game_view.d`).

## Design

### 1. View rectangles and layouts (`engine.gpu.viewport`)

New module `source/engine/gpu/viewport.d`. It is pure, `@nogc`, and unit-testable without a GPU.

```d
module engine.gpu.viewport;

@safe:

enum uint MAX_VIEWS = 4;

/// Integer pixel rectangle inside a render target (top-left origin).
struct ViewRect {
    uint x, y, w, h;
    bool valid() const pure nothrow @nogc { return w > 0 && h > 0; }
    float aspect() const pure nothrow @nogc { return h > 0 ? cast(float) w / h : 1.0f; }
    bool contains(float px, float py) const pure nothrow @nogc;
}

enum TwoPlayerSplit   : ubyte { sideBySide, stacked }
enum ThreePlayerSplit : ubyte { topWide, bottomWide, quadWithBlank }

struct SplitConfig {
    TwoPlayerSplit   two   = TwoPlayerSplit.sideBySide;
    ThreePlayerSplit three = ThreePlayerSplit.topWide;
    uint gutterPx = 2;              // separator thickness, in pixels
}

/// Fixed-capacity set of view rects for one frame. POD.
struct ViewSet {
    ViewRect[MAX_VIEWS] rects;
    uint count;
    ViewRect blank;                 // unused quadrant for quadWithBlank (may be invalid)
}

/// Split `outer` into `count` (1..MAX_VIEWS) player rects.
ViewSet computeSplitLayout(ViewRect outer, uint count, in SplitConfig cfg) pure nothrow @nogc;

/// Index of the view under a pixel, or -1 (mouse routing, editor picking).
int viewAt(in ViewSet views, float px, float py) pure nothrow @nogc;
```

Layout rules:

| Players | Layout | Notes |
|---:|:---|:---|
| 1 | full `outer` | Same output as today's single-view path |
| 2 | `sideBySide` (default) or `stacked` | A 16:9 window gives 8:9 views side by side or 32:9 strips stacked |
| 3 | `topWide` (P1 spans the top), `bottomWide`, or `quadWithBlank` | `quadWithBlank` gives every player the same aspect. The 4th quadrant is free for a minimap or logo |
| 4 | 2×2 grid | |

Pixel math requirements:

- The layout takes an **outer rect, not the window size**. The editor can then split its Game view canvas with the same function (SS-8).
- Work in integer pixels. Distribute remainders so views plus gutters cover `outer` exactly, with no 1-px seams or overlaps. Odd widths give the extra pixel to the last column or row.
- If `outer` is too small to hold the gutters plus 1 px per view (minimized window, collapsed panel), return `count = 0`. Callers skip 3D rendering, which already happens for `vpValid == false` in the editor.
- Gutters are part of the layout, not of rendering: rects never include gutter pixels.

### 2. Frame-level helpers (`FrameContext`)

Small additions to `engine/gpu/renderer.d`:

```d
/// Viewport + scissor from a ViewRect (integer, already clamped by layout).
void setViewport(in ViewRect r) nothrow @nogc @trusted;

/// Scissor only. Used in the present pass to clip a player's HUD to its view.
void setScissor(in ViewRect r) nothrow @nogc @trusted;
void resetScissor(uint targetW, uint targetH) nothrow @nogc @trusted;

/// Bind group with dynamic offsets (per-view uniform slot).
void setBindGroup(uint group, WGPUBindGroup bg, scope const(uint)[] dynamicOffsets) nothrow @nogc @trusted;
```

The existing float overload of `setViewport` stays as it is, because the editor uses it. All views draw into the **same** HDR render pass. Views never overlap, so the single clear at `beginFrame` is enough and no per-view clear pass is needed.

### 3. Multi-view scene renderers (the core change)

Split each renderer's frame into a **view-independent** part, done once, and a **per-view** part, done N times.

```d
scene.beginFrame();                       // reset batches (no camera)
drawMeshes(scene);                        // world-space instances, queued once
foreach (i; 0 .. views.count)
    scene.setView(i, cams[i]);            // CPU-side only
scene.upload();                           // ONE writeBuffer per instance batch,
                                          // ONE writeBuffer for all view slots
foreach (i; 0 .. views.count) {
    frame.setViewport(views.rects[i]);
    scene.renderView(frame, i);           // setBindGroup(0, frameBG, [i * stride]) + draws
}
```

Backward compatibility (no existing caller changes):

```d
void begin(ref const Camera c) { beginFrame(); setView(0, c); }
void end(ref FrameContext f)   { upload(); renderView(f, 0); }
```

#### Uniform layout with dynamic offsets

- Uniform buffers become `MAX_VIEWS` slots of `stride = alignUp(size, UNIFORM_OFFSET_ALIGN)` bytes.
- `UNIFORM_OFFSET_ALIGN = 256`. That is the WebGPU default for `minUniformBufferOffsetAlignment`, and the engine does not request custom limits (`requiredLimits` is null in `GpuContext`). Keep it a named constant. If the context ever queries adapter limits, read the real value from there.
- `Scene3D`: 64-byte VP, stride 256, buffer 1 KiB.
- `Scene3DTextured`: `FrameUniforms` is 1088 bytes, stride 1280, buffer 5 KiB. **v1 keeps `FrameUniforms` intact.** The CPU copies the light block into every active slot and patches `viewProj`/`cameraPos` per slot. That costs about 4 KiB of `writeBuffer` per frame, which is negligible. The WGSL shader, the bind group layout shape, and the light code are all unchanged.
  - A follow-up could move `viewProj`/`cameraPos` into their own small `@group(0)` binding, so lights are uploaded once. That changes WGSL and every frame-bind-group entry, so it is not worth doing in v1.
- Bind group layout changes:
  - `@group(0)` binding 0 gets `buffer.hasDynamicOffset = WGPU_TRUE`.
  - The bind group entry `size` must be the **slot size** (`FRAME_UNIFORMS_SIZE` / 64), not the whole buffer.
  - Sites to update:
    - `createColoredPipeline3D` and `reloadColoredPipeline3D`
    - `createTexturedPipeline3D` and `reloadTexturedPipeline3D` in `pipeline.d`
    - `createUniformBindGroup` (add a `slotSize` parameter) in `buffer.d`
    - the frame bind group rebuild in `scene3d_textured.d`
- Hot reload: the reload functions rebuild pipelines against the existing bind group layouts. Add a unit/integration check that a reloaded pipeline still accepts a dynamic-offset bind group, or wgpu validation fails at the first draw after a shader edit.
- `renderView` must pass the dynamic offset on **every** `setBindGroup(0, …)` call. Single-view callers use offset 0.

#### Instance data

Instances are world-space (model matrix + tint) and do not depend on the view. They are uploaded once in `upload()`, and every view draws the same `instanceBuf` range. This removes the "last write wins" bug for instance buffers too, without duplicating any instance memory.

> The existing `b.instances ~= …` appends in `Scene3D`/`Scene3DTextured` predate this plan and allocate on the GC heap. This plan must not add more of them. Moving the batches to preallocated `Pod!InstanceData[]` belongs in a separate GC-hygiene task.

#### Gizmos

`Gizmos` follows the same pattern: `beginFrame()` queues world-space lines, `setView(i, viewProj)`, `upload()`, `renderView(frame, i)`. `begin(viewProj)` plus `render(frame)` stay as the single-view compatibility wrappers.

#### Shadows and IBL

Shadow maps are fit to the scene, not the camera. Render them **once per frame**, before `beginFrame`, exactly as today. All views sample the same shadow and IBL bind groups. No change is needed. Document this invariant in `shadow.d`. If cascaded or camera-fit shadows are added later, they become per-view, and the cost is N× shadow passes.

### 4. Post-processing across views

v1 keeps **one** post chain over the full HDR target. It is the cheapest option and needs no post changes. Two artifacts follow from it:

- **Bloom bleed across the seam.** The blur mips sample neighboring views near the border.
- **FXAA at the seam.** It sees the hard edge between views.

Mitigation in v1: draw gutters and borders **after** post, in the present pass, as solid quads. They cover the few pixels where bleed is visible and stay crisp because they are never tonemapped or bloomed. Put a `drawGutters(frame, views, color)` helper in `engine/gpu/viewport.d`, or reuse `UiRenderer` solid rects.

If bleed is still visible with 2-px gutters at the default bloom settings, SS-9 adds per-view clamping (see that phase).

Rejected for v1: one offscreen HDR target and post chain **per view**. It allows per-view exposure and dynamic resolution, but it costs N× bloom mip chains, N× post passes, a composite pass, and N× resize logic.

### 5. HUD and UI per view

- Text and UI pipelines map pixel coordinates to NDC with a full-window `screenSize` uniform. They must **not** get a per-view `setViewport`, because that would break the mapping. Per-player HUD instead:
  - offsets its positions by `views.rects[i].x/y`
  - uses `frame.setScissor(views.rects[i])` to clip to the view, and `resetScissor` afterward
- The debug overlay (`devtools/overlay.d`) stays full-window.
- Add `ViewRect`-relative anchoring helpers (`anchorTopLeft`, `anchorBottomCenter`, …) so game code never computes offsets by hand.

### 6. Camera aspect and FOV policy

- `SplitScreen.update` sets `cam.aspect = rect.aspect()` on every layout change, including resize, player join or leave, and config change.
- FOV policy per camera: `FovAxis.vertical` (default, today's behavior) or `FovAxis.horizontal`.
  - With `sideBySide`, views are tall, and vertical FOV makes the horizontal view very narrow.
  - `horizontal` keeps horizontal FOV constant: `fovY = 2 * atan(tan(fovX / 2) / aspect)`.
  - Implement it as a pure helper `fovYForAspect(fovDeg, axis, aspect)` in `engine.scene.camera`.

### 7. High-level API (`engine.scene.split_screen`)

```d
struct SplitScreen {
    SplitConfig config;
    ViewSet     views;
    Camera[MAX_VIEWS] cameras;
    uint        playerCount = 1;
    Color4      gutterColor = Color4(0, 0, 0, 1);

    /// Recompute rects + camera aspects. Cheap; call each frame or on change.
    void update(uint targetW, uint targetH) nothrow @nogc;
    void updateIn(ViewRect outer) nothrow @nogc;       // editor panel variant

    /// Render the same queued scene into every active view.
    void render(ref FrameContext frame, ref Scene3DTextured scene) nothrow @nogc;
    void renderGizmos(ref FrameContext frame, ref Gizmos g) nothrow @nogc;

    /// Present-pass helpers (after app.resolvePost).
    void drawGutters(ref FrameContext frame) nothrow @nogc;
}
```

Typical game loop:

```d
app.pollEvents();
players.update(app.input, gamepads);                    // SS-5
split.playerCount = players.activeCount;
split.update(app.window.width, app.window.height);
foreach (i; 0 .. split.playerCount)
    split.cameras[i] = followCamera(world, players.entity(i), split.views.rects[i].aspect);

shadow.render(...);                                     // once
auto frame = app.beginFrame(clear);
scene.beginFrame();
drawWorld(scene, world);                                // once
split.render(frame, scene);                             // N views
app.resolvePost(frame);
split.drawGutters(frame);
foreach (i; 0 .. split.playerCount) drawHud(frame, split.views.rects[i], i);
app.endFrame(frame);
```

### 8. Input for local multiplayer

#### Gamepad bindings (`bindings/sdl3.d`)

Add these, matching `SDL3/SDL_init.h`, `SDL_events.h`, and `SDL_gamepad.h` **exactly**. The same rule that applies to WGPU enums applies here: a wrong event id or struct layout fails silently.

- `SDL_INIT_GAMEPAD` (`0x00002000`, which implies `SDL_INIT_JOYSTICK`), added to the `SDL_Init` flags in `Window.create`
- Event ids:
  - `SDL_EVENT_GAMEPAD_AXIS_MOTION` (`0x650`)
  - `..._BUTTON_DOWN` / `..._BUTTON_UP` (`0x651` / `0x652`)
  - `..._ADDED` / `..._REMOVED` / `..._REMAPPED` (`0x653`–`0x655`)
- Event structs `SDL_GamepadDeviceEvent`, `SDL_GamepadButtonEvent`, and `SDL_GamepadAxisEvent`, added to the `SDL_Event` union. The union keeps its 128-byte padding.
- `alias SDL_Gamepad = void*` (opaque) and `alias SDL_JoystickID = uint`
- Functions:
  - `SDL_OpenGamepad`, `SDL_CloseGamepad`, `SDL_GetGamepadID`, `SDL_GetGamepadName`
  - `SDL_GetGamepadButton`, `SDL_GetGamepadAxis`
  - `SDL_RumbleGamepad`, `SDL_SetGamepadPlayerIndex`
- Enums `SDL_GamepadButton` and `SDL_GamepadAxis`

Verify every value above against the SDL3 version the engine links before merging.

#### `engine.platform.gamepad`

```d
enum uint MAX_GAMEPADS = 8;

enum PadButton : ubyte { south, east, west, north, back, guide, start,
                         leftStick, rightStick, leftShoulder, rightShoulder,
                         dpadUp, dpadDown, dpadLeft, dpadRight }

struct GamepadState {              // POD, fixed size
    SDL_JoystickID id;             // 0 = empty slot
    bool connected;
    bool[PadButton.max + 1] down, pressed, released;
    float leftX, leftY, rightX, rightY, leftTrigger, rightTrigger;  // normalized
}

struct Gamepads {
    GamepadState[MAX_GAMEPADS] pads;
    float deadzone = 0.15f;        // radial deadzone on sticks
    void beginFrame() nothrow @nogc;                         // clear edges
    void processEvent(ref const SDL_Event ev) nothrow @nogc; // hot-plug + state
    void rumble(uint pad, float low, float high, uint ms) nothrow @nogc;
}
```

- `App` owns a `Gamepads` instance and forwards events in `pumpEvents`, next to `input.processEvent`. It honors the same `keepEdgesForNextFrame` rule as keyboard edges, so a button pressed during the swapchain wait is not lost.
- Hot-plug: on `ADDED`, open the device and fill the first empty slot. On `REMOVED`, close it and mark the slot disconnected. **Do not shift other slots.**
- Axes: map SDL's `short` range to `[-1, 1]` and apply a radial deadzone to each stick pair, not per axis.

#### `engine.platform.players`: the virtual gamepad model

Every player reads the same virtual gamepad, whatever device backs it:

```d
enum InputDevice : ubyte { none, gamepad, keyboardLeft, keyboardRight, keyboardMouse }

struct PlayerInput {               // POD, one per player slot
    InputDevice device;
    ubyte padIndex;                // when device == gamepad
    Vec2 move, look;               // [-1, 1]
    bool[PadButton.max + 1] down, pressed;
}

struct PlayerSlots {
    PlayerInput[MAX_VIEWS] players;
    uint activeCount;

    /// Rebuild every PlayerInput from raw keyboard/mouse/gamepad state.
    void update(ref const InputState kb, ref const Gamepads pads) nothrow @nogc;

    /// Join: first unassigned device that pressed `start` (pad) or
    /// Enter/Space (keyboard scheme) takes the next free slot.
    bool pollJoin(ref const InputState kb, ref const Gamepads pads) nothrow @nogc;
    void leave(uint slot) nothrow @nogc;
}
```

- Keyboard schemes:
  - `keyboardLeft`: WASD + Q/E/Space/LShift
  - `keyboardRight`: arrows + RCtrl/RShift/Enter

  Two players can then share one keyboard. Add the missing `Key` entries to `engine.platform.input`, such as `rctrl`, `return_`, and keypad keys.
- `keyboardMouse`: mouse delta drives `look`. At most one player can hold this scheme.
- Disconnect: if a player's pad is removed, set `PlayerInput.device = none` and expose `PlayerSlots.waitingForReconnect(slot)`. The game decides whether to pause. The next pad to press `start` reclaims the slot.
- Call `SDL_SetGamepadPlayerIndex(slot)` so controllers with player LEDs show the right number.

### 9. ECS and scene integration

- Add `@export_ ubyte playerSlot = 0;` to `Camera3D`:
  - `0` is the shared/single-player camera, chosen by `current` as today.
  - `1..4` renders into player N's view.

  Old `*.scene.json` files have no such field, so they load with the default `0`. Add a serialization round-trip test with and without the field.
- Move `sceneCameraToGpu` and `findCurrentCamera` from `engine/editor/demo_level.d` into `engine/scene/` (for example, `engine/scene/scene_camera.d`). The standalone player needs them, and the player must not import editor modules. Leave the old names as re-exports so the editor keeps compiling.
- Add `findCameraForSlot(world, slot)`. If no camera claims a slot, it falls back to the `current` camera, so a scene without per-player cameras still renders N identical views instead of black views.
- Gameplay usually spawns per-player follow cameras at runtime. The component only matters for authored scenes and for the editor preview.

### 10. Editor preview

- Game view toolbar: a "Players: 1 / 2 / 3 / 4" selector plus a layout selector (2-player and 3-player variants).
- The editor computes `computeSplitLayout(canvasRect, n, cfg)` from the Game view canvas rect (`vpX/vpY/vpW/vpH`) and renders each view with the camera from `findCameraForSlot`.
- Gizmos are not drawn in the Game view (as today), so the editor needs no per-view gizmos.
- Picking or clicks in the Game view use `viewAt` to tell which player's view the pointer is over.

## Performance Budget

| Cost | Single view | N views (this design) |
|:---|:---|:---|
| Shadow passes | 1× | 1× (shared) |
| Instance uploads (`writeBuffer`) | 1× per batch | 1× per batch (shared) |
| Frame uniform uploads | 1 slot | 1 write covering N slots |
| Draw calls / vertex work | D | N × D (no culling yet) |
| Fragment work | W×H | ≈ W×H total, minus gutters |
| Post-processing | 1 chain | 1 chain |
| GC allocations in frame path | 0 new | 0 new |

Acceptance numbers come from a `split-screen` variant of the benchmark scene at 1920×1080. Record them in this document when SS-7 lands:

- 4 views must stay within **1.5× the single-view frame time** on the reference machine. The extra cost should be almost all vertex and draw-call work.
- `dub run --config=player -- --headless-frames=600 --assert-no-gc` must still pass with `SplitScreen` and `PlayerSlots` active.

### Future: per-view culling

Once frustum culling exists, `renderView(frame, i)` takes a per-view visible list. The shared instance buffer stays as it is, and each view issues draws over index ranges it selects (or uses `firstInstance` remapping). Keep `renderView`'s signature free of assumptions that every instance is drawn.

## Phases

### SS-0 — Layout math (`engine.gpu.viewport`)

- [ ] `ViewRect`, `SplitConfig`, `ViewSet`, `MAX_VIEWS`
- [ ] `computeSplitLayout` for 1–4 players, all 2- and 3-player variants, gutters, odd sizes
- [ ] `viewAt` hit test
- [ ] Unit tests:
  - views plus gutters cover `outer` exactly
  - no overlaps
  - deterministic remainder distribution
  - tiny/zero outer gives `count == 0`
  - `outer` with a non-zero origin (editor panel case)

**DoD:** `dub test --config=library` passes the layout tests. The module is `@safe pure nothrow @nogc`.

### SS-1 — `FrameContext` helpers

- [ ] `setViewport(in ViewRect)`, `setScissor`, `resetScissor`
- [ ] `setBindGroup` overload with dynamic offsets
- [ ] `alignUp` helper plus the `UNIFORM_OFFSET_ALIGN = 256` constant (`engine.gpu.buffer`)

**DoD:** The editor still renders into its panel through the old `setViewport` overload. The new overloads compile and are used by SS-2.

### SS-2 — Multi-view renderers

- [ ] Dynamic-offset uniform slots in `Scene3D`, `Scene3DTextured`, and `Gizmos` (`MAX_VIEWS` slots, 256-aligned stride)
- [ ] `hasDynamicOffset` in the create **and** reload paths of the colored, textured, and gizmo pipelines. The bind group entry size is the slot size
- [ ] `beginFrame` / `setView` / `upload` / `renderView` API, plus the `begin`/`end` compatibility wrappers
- [ ] Instance buffers uploaded once per frame and shared across views
- [ ] Comment in `shadow.d` stating the "shadow maps are view-independent" invariant

**DoD:**
- A 2-view test scene shows **two different cameras** (proves the "last write wins" bug is gone).
- No wgpu validation errors.
- Existing demos (`pbr`, `golf`, `showcase`, `benchmark`) and the editor render the same as before.
- Shader hot reload of the textured pipeline still works during a 2-view frame.

### SS-3 — `SplitScreen` high-level API

- [ ] `engine/scene/split_screen.d` with `update`, `updateIn`, `render`, `renderGizmos`, and `drawGutters`
- [ ] Aspect updates on resize, join or leave, and config change; `fovYForAspect` + `FovAxis`
- [ ] HUD anchoring helpers relative to `ViewRect`
- [ ] Re-export from `engine/scene/package.d`

**DoD:** A 1-player `SplitScreen` gives pixel-identical output to the plain single-view path. 2, 3, and 4 players render with crisp gutters. Window resize keeps correct aspects with no stretching.

### SS-4 — Gamepad support

- [ ] SDL3 gamepad bindings (init flag, events, structs, functions, enums), verified against the SDL3 headers
- [ ] `engine.platform.gamepad`: `Gamepads` with hot-plug, deadzone, edges, rumble
- [ ] `App` owns `Gamepads`, and `pumpEvents` forwards events with the same edge-retention rule as `InputState`

**DoD:** Plugging and unplugging two controllers while the app runs logs the slot assignments. The stick and button state is readable. Unit tests cover the deadzone and axis normalization math.

### SS-5 — Player slots and virtual gamepad

- [ ] `engine.platform.players`: `PlayerInput`, `PlayerSlots`, keyboard schemes (left/right/mouse)
- [ ] Join (`start` / Enter), leave, disconnect and reconnect, `SDL_SetGamepadPlayerIndex`
- [ ] Missing `Key` entries for the right-hand keyboard scheme

**DoD:**
- Unit tests for join order, slot reuse after leave, and reconnect to the same slot, using synthetic events.
- Two players on one keyboard plus two gamepads can join at the same time.

### SS-6 — ECS, scene, and standalone player integration

- [ ] `Camera3D.playerSlot`, plus a scene file round-trip test (old files load with the default)
- [ ] Move `sceneCameraToGpu` / `findCurrentCamera` to `engine/scene/`, add `findCameraForSlot`, and keep the editor working
- [ ] Standalone player renders the scene through `SplitScreen`. A player count comes from a CLI flag (`--players=N`) or from join events. Depends on the player rendering the scene at all (see Dependencies)

**DoD:** A scene authored with two `Camera3D` (slots 1 and 2) opens in the player as a 2-way split. `--headless-frames=600 --assert-no-gc` still passes.

### SS-7 — Demo and documentation

- [ ] `source/demo/split_screen.d` plus a dub config `split-screen`:
  - small arena, 1–4 players, gamepads and both keyboard schemes
  - per-player follow cameras and HUD
  - `Tab` cycles the 2- and 3-player layouts
- [ ] Measure the performance budget above and record the numbers here
- [ ] "Split-screen local co-op" section in [game-development-guide.md](game-development-guide.md)
- [ ] Update [graphics.md](graphics.md): the multi-view renderer contract (`beginFrame` / `upload` / `renderView`) and dynamic offsets
- [ ] Mark this plan done in [roadmap.md](roadmap.md) and [README.md](README.md)

**DoD:** `dub run --config=split-screen` plays with 4 local players. The budget numbers are recorded.

### SS-8 — Editor Game view preview

- [ ] Players and layout selectors in the Game view toolbar
- [ ] Game view canvas split through `updateIn(canvasRect)`, each view using `findCameraForSlot`
- [ ] `viewAt` used for pointer routing in the Game view

**DoD:** In edit and play mode, the Game view shows the same split the standalone player will show for the same scene.

### SS-9 — (Optional) Post seam isolation

Run this phase only if the gutters do not hide bleed at default settings.

- [ ] Pass the active view rects (≤ 4 × `vec4<u32>`) to the bloom threshold and downsample shaders, and clamp sample UVs to the rect of the pixel's own view
- [ ] Optionally, per-view exposure: tonemap picks `exposure[viewIndex]` from the same rect table

**DoD:** A bright emitter at a view border produces no visible glow in the neighbor view with `gutterPx = 0`.

## Testing Strategy

| Layer | How |
|:---|:---|
| Layout math | Unit tests (SS-0): coverage and no-overlap properties over many window sizes, including odd sizes and 1-px edge cases |
| Uniform slots | Unit tests for `alignUp`/stride. Runtime: wgpu validation errors are fatal in debug builds |
| Multi-view correctness | 2-view scene with intentionally different cameras (SS-2 DoD). Manual screenshot check |
| Regression | Existing demos and editor through the compatibility wrappers |
| Input | Synthetic `SDL_Event` sequences fed to `Gamepads.processEvent` and `PlayerSlots` |
| Serialization | `Camera3D` round-trip with and without `playerSlot` |
| GC | `--assert-no-gc` headless runs of the player with split-screen active |

## Risks

| Risk | Mitigation |
|:---|:---|
| Dynamic offset not 256-aligned, or bind group entry size wrong, causing wgpu validation errors | One shared `alignUp` + `UNIFORM_OFFSET_ALIGN`, plus a static assert on the stride |
| Pipeline hot reload recreates a layout without `hasDynamicOffset` | Update the create and reload paths in the same commit. Test hot reload during a multi-view frame |
| SDL3 struct or enum mismatch (silent corruption) | Cross-check against the SDL3 headers of the linked version, the same rule as `webgpu.h` |
| Bloom and FXAA bleed between views | Gutters drawn after post (v1); SS-9 if needed |
| Vertex cost scales N× without culling | Accepted in v1. The `renderView` signature leaves room for per-view visible lists |
| Wayland: no gamepad focus issues are expected, but SDL needs `SDL_INIT_GAMEPAD` before devices enumerate | Init flag added in `Window.create`, with an `ADDED` event test on startup |
