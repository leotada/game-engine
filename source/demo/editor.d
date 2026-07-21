/// Level editor — `dub run --config=editor`.
///
/// Wires EditorWorld, hierarchy/inspector, picking, TRS gizmos, CommandStack,
/// lights + shadows, physics Simulate/Esc, and Ctrl+S/O/N scene I/O.
///
/// Controls:
///   LMB            — pick / gizmo drag (Shift+LMB multi-select)
///   RMB hold       — fly camera look (WASD / Space / LCtrl / LShift)
///   1 / 2 / 3      — gizmo translate / rotate / scale
///   Ctrl+Z / Y     — undo / redo
///   Ctrl+S / O / N — save / open / new scene (path field in Hierarchy)
///   Ctrl+D         — duplicate
///   X              — delete selection
///   F              — focus camera on selection
///   Esc            — stop physics sim (or quit if idle)
module demo.editor;

import std.exception : collectException;
import std.file : exists;

import engine.app;
import engine.core.log;
import engine.devtools.gizmos : GizmoRenderer;
import engine.editor;
import engine.gpu.buffer;
import engine.gpu.shadow;
import engine.gpu.text : TextRenderer, FpsCounter;
import engine.graphics.material : Material, MaterialParams;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.texture : Texture, Sampler, TextureFilter, TextureWrap;
import engine.graphics.types : Color4, InstanceData;
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.ray : Ray, screenToWorldRay;
import engine.math.vec : Vec3;
import engine.physics.world : PhysicsWorld;
import engine.platform.input : InputState, Key, MouseButton;
import engine.scene.camera : Camera;
import engine.scene.controllers : FlyCamera;
import engine.scene.graph : Transform;
import engine.scene.light :
    Light, LightSet, LightType, MAX_POINT_SHADOW_CASTERS, MAX_SPOT_SHADOW_CASTERS,
    POINT_SHADOW_RESOLUTION, SPOT_SHADOW_RESOLUTION;
import engine.scene.scene3d_textured : Scene3DTextured;

@safe:

private enum W = 1280;
private enum H = 720;
private enum defaultScenePath = "assets/scenes/arena_01.scene.json";
private enum maxShadowCasters = 64;

void main() {
    auto app = App.create("Engine Level Editor", W, H);

    auto scene = Scene3DTextured.create(app.gpu);
    scope(exit) scene.destroy();

    auto cubeMesh = TexMesh.cube(app.gpu);
    scope(exit) cubeMesh.destroy();
    auto sphereMesh = TexMesh.sphere(app.gpu, 24, 16);
    scope(exit) sphereMesh.destroy();
    auto quadMesh = TexMesh.quad(app.gpu);
    scope(exit) quadMesh.destroy();

    auto sampler = Sampler.create(app.gpu, TextureFilter.linear, TextureWrap.repeat);
    scope(exit) sampler.destroy();
    auto groundTex = Texture.checker(app.gpu, 128, [50, 50, 60, 255], [30, 30, 40, 255]);
    scope(exit) groundTex.destroy();
    auto whiteTex = Texture.solid(app.gpu, 220, 220, 230, 255);
    scope(exit) whiteTex.destroy();

    auto layout = scene.materialLayout();
    auto groundMat = Material.create(app.gpu, layout, sampler, groundTex);
    scope(exit) groundMat.destroy();
    auto defaultMat = Material.create(app.gpu, layout, sampler, whiteTex);
    scope(exit) defaultMat.destroy();
    // Pool so each override entity gets its own Material (batching keys on pointer).
    enum overridePoolSize = 32;
    Material[overridePoolSize] overridePool;
    foreach (ref m; overridePool)
        m = Material.create(app.gpu, layout, sampler, whiteTex);
    scope(exit) foreach (ref m; overridePool) m.destroy();
    uint overridePoolCursor = 0;

    auto shadowPipe = createShadowPipeline(app.gpu.getDevice());
    scope(exit) shadowPipe.release();
    auto lightBuf = createUniformBuffer(app.gpu.getDevice(), 64);
    scope(exit) destroyBuffer(lightBuf);
    auto lightBg = createUniformBindGroup(app.gpu.getDevice(), shadowPipe.bindGroupLayout, lightBuf, 64);
    scope(exit) releaseBindGroup(lightBg);
    auto shadowInstanceBuf = createDynamicVertexBuffer(
        app.gpu.getDevice(), maxShadowCasters * InstanceData.sizeof);
    scope(exit) destroyBuffer(shadowInstanceBuf);

    auto dirShadow = ShadowMap.create(app.gpu, 2048);
    scope(exit) dirShadow.destroy();
    PointShadowMap[MAX_POINT_SHADOW_CASTERS] pointShadows;
    foreach (ref ps; pointShadows)
        ps = PointShadowMap.create(app.gpu, POINT_SHADOW_RESOLUTION, 0.1f, 25.0f);
    scope(exit) foreach (ref ps; pointShadows) ps.destroy();
    SpotShadowMap[MAX_SPOT_SHADOW_CASTERS] spotShadows;
    foreach (ref ss; spotShadows)
        ss = SpotShadowMap.create(app.gpu, SPOT_SHADOW_RESOLUTION);
    scope(exit) foreach (ref ss; spotShadows) ss.destroy();

    auto gizmos = GizmoRenderer.create(app.gpu);
    scope(exit) gizmos.destroy();
    auto text = TextRenderer.create(app.gpu, W, H);
    scope(exit) text.destroy();

    EditorWorld world;
    Selection sel;
    GizmoTool gizmo;
    CommandStack cmds;
    HierarchyState hier;
    InspectorState insp;
    LightPanelState lights;
    PhysicsSimSession sim;
    auto physics = PhysicsWorld.createDefault();
    float[3] gravity = [0, -9.81f, 0];

    char[192] pathBuf = void;
    size_t pathLen = 0;
    setPathBuffer(pathBuf, pathLen, defaultScenePath);

    // Bootstrap: load default scene or spawn a starter level.
    if (exists(defaultScenePath)) {
        auto err = collectException(loadScene(world, defaultScenePath, lights.scene, gravity));
        if (err !is null) {
            warn("Failed to load ", defaultScenePath, ": ", err.msg);
            seedDefaultScene(world, cmds, sel, lights);
        } else {
            info("Loaded ", defaultScenePath);
        }
    } else {
        seedDefaultScene(world, cmds, sel, lights);
    }
    cmds.clear(); // don't undo bootstrap
    sel.clear();
    physics.setGravity(Vec3(gravity[0], gravity[1], gravity[2]));

    auto camera = Camera.create(0.9f, W, H);
    camera.lookAt(Vec3(8, 6, 10), Vec3(0, 1, 0));
    auto fly = FlyCamera.create(Vec3(8, 6, 10));

    // Absolute mouse for UI / picking; RMB enables relative look.
    app.window.setRelativeMouseMode(false);
    scope(exit) app.window.setRelativeMouseMode(false);

    UiContext ui;
    auto fps = FpsCounter.create();
    string statusMsg = "Ready";
    float statusTimer = 0;

    info("Level editor — RMB fly, LMB pick, Ctrl+S/O/N save/open/new, Esc stops sim.");

    while (app.running()) {
        app.pollEvents();
        immutable dt = fps.tick();
        if (statusTimer > 0) statusTimer -= dt;

        immutable lmbDown = app.input.mouseDown(MouseButton.left);
        immutable lmbPressed = app.input.mousePressed(MouseButton.left);
        immutable lmbReleased = app.input.mouseUp(MouseButton.left);
        immutable rmbDown = app.input.mouseDown(MouseButton.right);
        immutable shift = app.input.keyDown(Key.lshift);
        immutable ctrl = app.input.keyDown(Key.lctrl);

        // Camera: RMB enables relative look; absolute mouse otherwise for UI/pick.
        app.window.setRelativeMouseMode(rmbDown);
        if (rmbDown) {
            fly.update(app.input, dt, camera);
        } else {
            updateFlyMoveOnly(fly, app.input, dt, camera);
        }

        sel.validateWorld(world);

        // --- Shortcuts (before UI so Esc can stop sim) ---
        if (app.input.keyPressed(Key.escape)) {
            if (sim.handleEscape(world, true)) {
                setStatus(statusMsg, statusTimer, "Sim stopped");
            } else {
                break;
            }
        }

        if (ctrl && app.input.keyPressed(Key.z)) {
            if (cmds.undo(world, sel)) setStatus(statusMsg, statusTimer, "Undo");
        }
        if (ctrl && app.input.keyPressed(Key.y)) {
            if (cmds.redo(world, sel)) setStatus(statusMsg, statusTimer, "Redo");
        }
        if (ctrl && app.input.keyPressed(Key.s)) {
            if (trySave(world, pathBuf[0 .. pathLen], lights.scene, gravity))
                setStatus(statusMsg, statusTimer, "Saved");
            else
                setStatus(statusMsg, statusTimer, "Save failed");
        }
        if (ctrl && app.input.keyPressed(Key.o)) {
            if (tryLoad(world, pathBuf[0 .. pathLen], lights.scene, gravity, sel, cmds, physics))
                setStatus(statusMsg, statusTimer, "Loaded");
            else
                setStatus(statusMsg, statusTimer, "Load failed");
        }
        if (ctrl && app.input.keyPressed(Key.n)) {
            if (sim.active) sim.stopSimulate(world);
            newScene(world, lights.scene, gravity);
            seedDefaultScene(world, cmds, sel, lights);
            cmds.clear();
            sel.clear();
            physics.setGravity(Vec3(gravity[0], gravity[1], gravity[2]));
            setStatus(statusMsg, statusTimer, "New scene");
        }
        if (ctrl && app.input.keyPressed(Key.d) && !sel.empty)
            duplicateSelected(world, cmds, sel);
        if ((app.input.keyPressed(Key.x)) && !sel.empty && !ctrl)
            deleteSelected(world, cmds, sel);

        if (app.input.keyPressed(Key.digit1)) gizmo.mode = GizmoMode.translate;
        if (app.input.keyPressed(Key.digit2)) gizmo.mode = GizmoMode.rotate;
        if (app.input.keyPressed(Key.digit3)) gizmo.mode = GizmoMode.scale;

        if (app.input.keyPressed(Key.f) && !sel.empty) {
            immutable p = focusPoint(world, sel.primary);
            fly.position = p + Vec3(4, 3, 6);
            camera.lookAt(fly.position, p);
        }

        auto cols = editorColumns(cast(float) W, cast(float) H);
        immutable mx = app.input.mx();
        immutable my = app.input.my();
        immutable overPanel = cols.hierarchy.contains(mx, my) || cols.inspector.contains(mx, my);

        // Viewport ray uses full window coords (panels still get absolute mouse).
        auto ray = screenToWorldRay(mx, my, cast(float) W, cast(float) H, camera.viewProjection());

        // Gizmo + pick only when not over side panels and not flying.
        if (!overPanel && !rmbDown && !sim.active) {
            gizmo.update(world, sel, ray, lmbPressed, lmbDown, lmbReleased);
            if (gizmo.dragJustEnded) {
                recordGizmoDrag(
                    cmds, world,
                    gizmo.dragIds[0 .. gizmo.dragCount],
                    gizmo.dragStarts[0 .. gizmo.dragCount]);
            }
            if (!gizmo.wantCaptureMouse && lmbPressed) {
                auto hit = pickClosestAabb(world, ray);
                if (hit.hit) {
                    if (shift) sel.toggle(hit.entity);
                    else sel.select(hit.entity);
                } else if (!shift) {
                    sel.clear();
                }
            }
        }

        // Physics tick
        auto resolver = makeAssetResolver(world);
        sim.tick(world, physics, dt);

        // Pack lights + submit shadow maps
        auto packed = packLightsFromWorld(world, lights.scene);
        submitEditorShadows(app, packed, dirShadow, pointShadows, spotShadows,
            shadowPipe, lightBg, lightBuf, shadowInstanceBuf,
            cubeMesh, sphereMesh, world);

        PointShadowMap*[MAX_POINT_SHADOW_CASTERS] pointMaps;
        SpotShadowMap*[MAX_SPOT_SHADOW_CASTERS] spotMaps;
        {
            uint pi = 0;
            foreach (i; 0 .. packed.pointCount) {
                if (!packed.points[i].castShadows) continue;
                if (pi >= MAX_POINT_SHADOW_CASTERS) break;
                pointMaps[pi] = &pointShadows[pi];
                pi++;
            }
            uint si = 0;
            foreach (i; 0 .. packed.spotCount) {
                if (!packed.spots[i].castShadows) continue;
                if (si >= MAX_SPOT_SHADOW_CASTERS) break;
                spotMaps[si] = &spotShadows[si];
                si++;
            }
        }
        scene.setLights(packed, &dirShadow, pointMaps, spotMaps);

        auto frame = app.beginFrame(Color4(0.04f, 0.045f, 0.06f, 1));
        if (!frame.valid) continue;

        scene.begin(camera);
        overridePoolCursor = 0;
        drawWorldMeshes(app, scene, world, cubeMesh, sphereMesh, quadMesh,
            groundMat, defaultMat, overridePool[], overridePoolCursor);
        scene.end(frame);

        gizmos.begin(camera.viewProjection());
        gizmo.draw(world, sel.primary, gizmos);
        drawAllLightGizmos(world, gizmos, lights.scene);
        drawSelectionHighlights(world, sel, gizmos);
        drawPhysicsColliderGizmos(world, gizmos, resolver);
        gizmos.render(frame);

        app.resolvePost(frame);

        // UI overlay
        text.beginFrame();
        ui.beginFrame(mx, my, lmbDown, lmbPressed, lmbReleased, cast(float) W, cast(float) H);
        ui.bindRenderer(text, frame);

        auto focusReq = drawHierarchy(ui, cols.hierarchy, world, sel, cmds, hier, lights);
        // Scene path + I/O under hierarchy stack
        {
            label(ui, "Scene path");
            char typed = asciiFromInput(app.input, ctrl);
            bool back = app.input.keyPressed(Key.backspace);
            textField(ui, "Path", pathBuf[], pathLen, typed, back);
            if (button(ui, "Save")) {
                if (trySave(world, pathBuf[0 .. pathLen], lights.scene, gravity))
                    setStatus(statusMsg, statusTimer, "Saved");
                else
                    setStatus(statusMsg, statusTimer, "Save failed");
            }
            if (button(ui, "Load")) {
                if (tryLoad(world, pathBuf[0 .. pathLen], lights.scene, gravity, sel, cmds, physics))
                    setStatus(statusMsg, statusTimer, "Loaded");
                else
                    setStatus(statusMsg, statusTimer, "Load failed");
            }
            if (button(ui, "New")) {
                if (sim.active) sim.stopSimulate(world);
                newScene(world, lights.scene, gravity);
                seedDefaultScene(world, cmds, sel, lights);
                cmds.clear();
                sel.clear();
                setStatus(statusMsg, statusTimer, "New scene");
            }
            drawPhysicsSimControls(ui, world, sim, physics, resolver);
        }

        drawInspector(ui, cols.inspector, world, sel, cmds, insp, gizmo, lights);
        ui.endFrame();

        if (focusReq != noSelection) {
            immutable p = focusPoint(world, focusReq);
            fly.position = p + Vec3(4, 3, 6);
            camera.lookAt(fly.position, p);
        }

        // Status line in viewport
        {
            import std.format : format;
            auto hud = format("FPS %.0f | %s | sel=%d | %s",
                fps.fps,
                gizmoModeName(gizmo.mode),
                sel.count,
                statusTimer > 0 ? statusMsg : (sim.active ? "SIMULATING" : "edit"));
            text.drawText(frame, hud, cols.viewport.x + 8, 8, 1);
            text.drawText(frame, "RMB fly | LMB pick | Shift multi | 1/2/3 gizmo | Ctrl+Z/Y undo | Ctrl+S/O/N",
                cols.viewport.x + 8, 24, 1);
        }

        app.endFrame(frame);
    }

    if (sim.active) sim.stopSimulate(world);
    app.destroy();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private void setStatus(ref string msg, ref float timer, string text) {
    msg = text;
    timer = 2.0f;
}

private void setPathBuffer(ref char[192] buf, ref size_t len, string path) {
    len = path.length < buf.length ? path.length : buf.length;
    foreach (i; 0 .. len) buf[i] = path[i];
}

private string gizmoModeName(GizmoMode m) {
    final switch (m) {
        case GizmoMode.translate: return "Move";
        case GizmoMode.rotate:    return "Rotate";
        case GizmoMode.scale:     return "Scale";
    }
}

/// Map a single key press to printable ASCII for the path text field.
private char asciiFromInput(ref const InputState input, bool ctrl) {
    if (ctrl) return 0;
    if (input.keyPressed(Key.slash)) return '/';
    if (input.keyPressed(Key.period)) return '.';
    if (input.keyPressed(Key.minus)) return input.keyDown(Key.lshift) ? '_' : '-';
    if (input.keyPressed(Key.a)) return 'a';
    if (input.keyPressed(Key.b)) return 'b';
    if (input.keyPressed(Key.c)) return 'c';
    if (input.keyPressed(Key.d)) return 'd';
    if (input.keyPressed(Key.e)) return 'e';
    if (input.keyPressed(Key.f)) return 'f';
    if (input.keyPressed(Key.g)) return 'g';
    if (input.keyPressed(Key.n)) return 'n';
    if (input.keyPressed(Key.o)) return 'o';
    if (input.keyPressed(Key.q)) return 'q';
    if (input.keyPressed(Key.r)) return 'r';
    if (input.keyPressed(Key.s)) return 's';
    if (input.keyPressed(Key.w)) return 'w';
    if (input.keyPressed(Key.x)) return 'x';
    if (input.keyPressed(Key.y)) return 'y';
    if (input.keyPressed(Key.z)) return 'z';
    if (input.keyPressed(Key.digit0)) return '0';
    if (input.keyPressed(Key.digit1)) return '1';
    if (input.keyPressed(Key.digit2)) return '2';
    if (input.keyPressed(Key.digit3)) return '3';
    if (input.keyPressed(Key.digit4)) return '4';
    if (input.keyPressed(Key.digit5)) return '5';
    if (input.keyPressed(Key.digit6)) return '6';
    if (input.keyPressed(Key.digit7)) return '7';
    if (input.keyPressed(Key.digit8)) return '8';
    if (input.keyPressed(Key.digit9)) return '9';
    return 0;
}

/// WASD translate without mouse look (absolute cursor for UI).
private void updateFlyMoveOnly(
    ref FlyCamera fly,
    ref const InputState input,
    float dt,
    ref Camera camera
) {
    immutable float mul = input.keyDown(Key.lshift) ? fly.sprintMultiplier : 1.0f;
    immutable speed = fly.moveSpeed * mul * dt;
    immutable f = fly.forward();
    immutable r = fly.right();
    Vec3 m = Vec3(0, 0, 0);
    if (input.keyDown(Key.w)) m = m + f;
    if (input.keyDown(Key.s)) m = m - f;
    if (input.keyDown(Key.d)) m = m + r;
    if (input.keyDown(Key.a)) m = m - r;
    if (input.keyDown(Key.space)) m.y += 1;
    if (input.keyDown(Key.lctrl)) m.y -= 1;
    if (m.lengthSquared() > 1e-8f)
        fly.position = fly.position + m.normalized() * speed;
    camera.lookAt(fly.position, fly.position + fly.forward());
}

private bool trySave(
    ref EditorWorld world,
    scope const(char)[] path,
    ref const SceneLightSettings lights,
    float[3] gravity
) {
    if (path.length == 0) return false;
    auto e = collectException(saveScene(world, path.idup, lights, gravity, "arena_01"));
    if (e !is null) {
        err("saveScene: ", e.msg);
        return false;
    }
    return true;
}

private bool tryLoad(
    ref EditorWorld world,
    scope const(char)[] path,
    ref SceneLightSettings lights,
    ref float[3] gravity,
    ref Selection sel,
    ref CommandStack cmds,
    ref PhysicsWorld physics
) {
    if (path.length == 0) return false;
    immutable p = path.idup;
    auto e = collectException(loadScene(world, p, lights, gravity));
    if (e !is null) {
        err("loadScene: ", e.msg);
        return false;
    }
    sel.clear();
    cmds.clear();
    physics.setGravity(Vec3(gravity[0], gravity[1], gravity[2]));
    return true;
}

private void seedDefaultScene(
    ref EditorWorld world,
    ref CommandStack cmds,
    ref Selection sel,
    ref LightPanelState lights
) {
    // Ground plane
    {
        Transform t;
        t.position = Vec3(0, 0, 0);
        t.scale = Vec3(20, 1, 20);
        auto id = spawnPrimitive(world, cmds, sel, VisualKind.plane, t,
            defaultNameFor(world.strings, VisualKind.plane));
        PhysicsBody pb;
        pb.enabled = 1;
        pb.motion = PhysicsMotion.static_;
        pb.shape = PhysicsShapeKind.primitive;
        pb.halfExtents = Vec3(10, 0.01f, 10);
        world.set(id, pb);
    }
    // Three cubes for multi-select demo
    foreach (i; 0 .. 3) {
        Transform t;
        t.position = Vec3(-2.0f + i * 2.0f, 0.5f, 0);
        auto id = spawnPrimitive(world, cmds, sel, VisualKind.cube, t,
            defaultNameFor(world.strings, VisualKind.cube));
        auto mat = world.get!MaterialOverride(id);
        mat.baseColor = [0.7f + i * 0.1f, 0.4f, 0.3f, 1];
        mat.roughness = 0.4f + i * 0.15f;
        world.set(id, mat);
    }
    // Dynamic sphere for Simulate
    {
        Transform t;
        t.position = Vec3(0, 4, 2);
        auto id = spawnPrimitive(world, cmds, sel, VisualKind.sphere, t,
            defaultNameFor(world.strings, VisualKind.sphere));
        PhysicsBody pb;
        pb.enabled = 1;
        pb.motion = PhysicsMotion.dynamic_;
        pb.shape = PhysicsShapeKind.primitive;
        pb.halfExtents = Vec3(0.5f, 0.5f, 0.5f);
        pb.mass = 1;
        pb.restitution = 0.3f;
        world.set(id, pb);
    }
    // Sun
    {
        Transform t;
        t.position = Vec3(0, 8, 0);
        t.rotation = Quat.fromEulerYXZ(Vec3(-50, 35, 0));
        Light L;
        L.type = LightType.directional;
        L.color = [1.0f, 0.98f, 0.92f];
        L.intensity = 2.5f;
        L.castShadows = 1;
        L.range = 14;
        spawnLightEntity(world, cmds, sel, L, t, defaultLightName(world.strings));
    }
    // Point lamp
    {
        Transform t;
        t.position = Vec3(-3, 3, 2);
        Light L;
        L.type = LightType.point;
        L.color = [0.4f, 0.7f, 1.0f];
        L.intensity = 18;
        L.range = 14;
        L.castShadows = 1;
        spawnLightEntity(world, cmds, sel, L, t, world.strings.intern("Lamp"));
    }
    lights.scene.dirShadowCenter = Vec3(0, 1, 0);
    lights.scene.dirShadowRadius = 14;
}

private void drawWorldMeshes(
    ref App app,
    ref Scene3DTextured scene,
    ref EditorWorld world,
    ref TexMesh cubeMesh,
    ref TexMesh sphereMesh,
    ref TexMesh quadMesh,
    ref Material groundMat,
    ref Material defaultMat,
    scope Material[] overridePool,
    ref uint overridePoolCursor
) {
    foreach (id; world.query!(Transform, Visual)()) {
        if (!world.alive(id)) continue;
        immutable vis = world.get!Visual(id);
        immutable model = worldMatrix(world, id);

        Material* mat = &defaultMat;
        Color4 tint = Color4.white;
        if (world.has!MaterialOverride(id)) {
            immutable mo = world.get!MaterialOverride(id);
            if (mo.active) {
                tint = Color4(mo.baseColor[0], mo.baseColor[1], mo.baseColor[2], mo.baseColor[3]);
                if (overridePoolCursor < overridePool.length) {
                    MaterialParams p;
                    p.baseColorFactor = mo.baseColor;
                    p.metallic = mo.metallic;
                    p.roughness = mo.roughness < 0.04f ? 0.04f : mo.roughness;
                    overridePool[overridePoolCursor].updateParams(app.gpu, p);
                    mat = &overridePool[overridePoolCursor];
                    overridePoolCursor++;
                }
            }
        }

        final switch (vis.kind) {
            case VisualKind.none:
                break;
            case VisualKind.cube:
                scene.drawMatrix(cubeMesh, *mat, model, tint);
                break;
            case VisualKind.sphere:
                scene.drawMatrix(sphereMesh, *mat, model, tint);
                break;
            case VisualKind.plane:
                scene.drawMatrix(quadMesh, groundMat, model, Color4(0.8f, 0.8f, 0.85f, 1));
                break;
            case VisualKind.mesh:
                scene.drawMatrix(cubeMesh, *mat, model, tint);
                break;
        }
    }
}

private void submitEditorShadows(
    ref App app,
    ref const LightSet packed,
    ref ShadowMap dirShadow,
    ref PointShadowMap[MAX_POINT_SHADOW_CASTERS] pointShadows,
    ref SpotShadowMap[MAX_SPOT_SHADOW_CASTERS] spotShadows,
    ref ShadowPipeline pipe,
    void* lightBg,
    void* lightBuf,
    void* instanceBuf,
    ref TexMesh cubeMesh,
    ref TexMesh sphereMesh,
    ref EditorWorld world
) {
    import bindings.wgpu : WGPUBindGroup, WGPUBuffer;

    auto bg = cast(WGPUBindGroup) lightBg;
    auto lb = cast(WGPUBuffer) lightBuf;
    auto ib = cast(WGPUBuffer) instanceBuf;

    InstanceData[maxShadowCasters] casters;
    uint count = 0;
    foreach (id; world.query!(Transform, Visual)()) {
        if (!world.alive(id) || count >= maxShadowCasters) continue;
        immutable vis = world.get!Visual(id);
        if (vis.kind == VisualKind.none || vis.kind == VisualKind.plane) continue;
        casters[count++] = InstanceData(worldMatrix(world, id).m, Color4.white.toArray());
    }
    if (count == 0) return;
    updateBuffer(app.gpu.getQueue(), ib, casters[0 .. count]);

    if (packed.dirEnabled && packed.dir.castShadows) {
        submitShadowPass(app.gpu, dirShadow, pipe, bg, lb, packed.dir.viewProj,
            cubeMesh, ib, count);
    }

    uint pSlot = 0;
    foreach (i; 0 .. packed.pointCount) {
        if (!packed.points[i].castShadows) continue;
        if (pSlot >= MAX_POINT_SHADOW_CASTERS) break;
        immutable pos = packed.points[i].position;
        immutable faceVPs = pointLightFaceVPs(pos, pointShadows[pSlot].nearPlane,
            pointShadows[pSlot].farPlane);
        foreach (face; 0 .. 6) {
            submitPointShadowFace(app.gpu, pointShadows[pSlot], face, pipe, bg, lb,
                faceVPs[face], cubeMesh, ib, count);
        }
        pSlot++;
    }

    uint sSlot = 0;
    foreach (i; 0 .. packed.spotCount) {
        if (!packed.spots[i].castShadows) continue;
        if (sSlot >= MAX_SPOT_SHADOW_CASTERS) break;
        submitSpotShadowPass(app.gpu, spotShadows[sSlot], pipe, bg, lb,
            packed.spots[i].viewProj, cubeMesh, ib, count);
        sSlot++;
    }
}
