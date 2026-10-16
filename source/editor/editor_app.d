/// Unity/Godot-style visual editor application.
module editor.editor_app;

import core.memory : GC;
import std.file : exists, mkdirRecurse;
import std.math : PI, asin, atan2, tan;
import std.path : dirName;
import std.stdio : writefln;

import editor.panels;
import editor.play_mode : PlayMode;
import editor.shortcuts;
import engine.app : App;
import engine.core.log : info, warn, err, clearLogHistory;
import engine.devtools.gizmos : GizmoRenderer;
import engine.ecs.scene_world : SceneWorld;
import engine.ecs.store : EntityId;
import engine.editor.commands :
    CommandEntry, CommandKind, CommandStack, applySnapshotTo, captureEntity,
    deleteSelected, focusPoint, recordGizmoDrag, recordMaterial, recordTransform,
    spawnPrimitive;
import engine.editor.components :
    Camera3D, MaterialOverride, Name, PhysicsBody, PhysicsMotion, PhysicsShapeKind,
    Visual, VisualKind, defaultHalfExtents, worldPosition;
import engine.editor.demo_level : findCurrentCamera, sceneCameraToGpu, spawnDemoLevel;
import engine.editor.gizmo_tool : GizmoMode, GizmoSpace, GizmoTool;
import engine.editor.light_panel : SceneLightSettings;
import engine.editor.physics_sim;
import engine.editor.picking : drawSelectionHighlights, pickClosestAabb;
import engine.editor.scene_load : loadSceneIntoWorld, worldToSceneFile;
import engine.editor.selection : Selection, noSelection;
import engine.graphics.mesh : Mesh;
import engine.graphics.types : Color4;
import engine.hotreload.build_runner : Diagnostic;
import engine.hotreload.reload : HotReloadManager;
import engine.hotreload.shader_reload : ShaderHotReloader;
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.ray : screenToWorldRay;
import engine.math.vec : Vec3;
import engine.physics.world : PhysicsWorld;
import engine.platform.input : InputState, Key, MouseButton;
import engine.project.asset_db : AssetDatabase;
import engine.scene.camera : Camera;
import engine.scene.controllers : FlyCamera;
import engine.scene.graph : Transform;
import engine.scene.scene3d : Scene3D;
import engine.scene.scene_file : SceneFile, loadSceneFile, saveSceneFile, validateScene;
import engine.ui;

@safe:

enum PopupKind : uint {
    none = 0,
    arquivo = 1,
    editar = 2,
    gameObject = 3,
    janela = 4,
    ajuda = 5,
    criar = 6,
    componente = 7,
}

enum MenuAction : uint {
    newScene = 1,
    saveScene = 2,
    undo = 3,
    redo = 4,
    duplicate = 5,
    deleteSel = 6,
    cube = 7,
    sphere = 8,
    plane = 9,
    winHierarchy = 11,
    winScene = 12,
    winGame = 13,
    winInspector = 14,
    winProject = 15,
    winConsole = 16,
    camera = 22,
}

enum playTag = 0xAA01;
enum pauseTag = 0xAA02;
enum stopTag = 0xAA03;

struct EditorApp {
    enum ActiveView : ubyte {
        none = 0,
        viewport = 1,
        game = 2,
    }

    App app;
    Font font;
    UiTree ui;
    UiBatchRenderer uiRenderer;
    UiTheme theme;
    UiInputContext inputCtx;
    UiEventQueue queue;

    Scene3D scene;
    Mesh cubeMesh;
    Mesh sphereMesh;
    Mesh planeMesh;
    GizmoRenderer gizmos;
    bool gpuSceneReady = false;

    ulong framesPresented = 0;
    ulong framesSkipped = 0;

    UiNodeId activeViewportNode;
    ActiveView activeView = ActiveView.none;
    bool flyCamActive = false;
    bool vpValid = false;
    float vpX = 0, vpY = 0, vpW = 0, vpH = 0;
    uint pointerPressTag = 0;

    DockSpace dock;

    SceneWorld world;
    Selection selection;
    CommandStack commands;
    GizmoTool gizmoTool;
    FlyCamera flyCam;
    Camera camera;

    ConsolePanel consolePanel;
    HierarchyPanel hierarchyPanel;
    InspectorPanel inspectorPanel;
    SceneViewPanel sceneViewPanel;
    GameViewPanel gameViewPanel;
    SceneLightSettings lightSettings;
    PhysicsWorld physics;
    HotReloadManager hotReload;
    ShaderHotReloader shaderReloader;
    PlayMode playMode;
    AssetDatabase assetDb;
    ProjectPanel projectPanel;

    PopupKind popup = PopupKind.none;
    float popupX = 0;
    float popupY = 0;
    float popupAnchorTop = 0;

    char[64] nameBuf;
    uint nameLen = 0;
    EntityId nameBound = noSelection;
    bool nameDirty = false;
    EntityId hierarchyRename = noSelection;
    EntityId lastHierarchyClick = noSelection;
    float uiClock = 0;
    float lastHierarchyClickAt = -1;
    bool focusRenameField = false;

    bool draggingValue = false;
    uint dragSlot = 0;
    EntityId dragEntity;
    Transform dragBefore;
    Vec3 dragEuler;
    MaterialOverride dragMatBefore;
    bool dragHadMaterial = false;
    Camera3D dragCamBefore;

    string currentScenePath = "assets/scenes/untitled.scene.json";
    bool sceneDirty = false;
    bool isHeadless = false;

    void init(string scenePath = "", bool headless = false) {
        isHeadless = headless;
        hotReload.enabled = false;
        nameBound = noSelection;

        physics = PhysicsWorld.createDefault();
        if (!headless)
            assetDb.scanAssets("assets");

        if (exists("assets/fonts/default.ttf")) {
            import std.file : read;
            ubyte[] fontData = () @trusted { return cast(ubyte[]) read("assets/fonts/default.ttf"); }();
            font.loadFromMemory(fontData, 14.0f);
        }

        ui = UiTree.create();
        theme = UiTheme.init;

        if (!headless) {
            app = App.create("Game Engine Editor — Unity/Godot style", 1280, 768);
            uiRenderer.init(app.gpu.getDevice(), app.gpu.getQueue(), app.gpu.getFormat(), font);
            scene = Scene3D.create(app.gpu);
            cubeMesh = Mesh.cube(app.gpu);
            sphereMesh = Mesh.sphere(app.gpu);
            planeMesh = Mesh.plane(app.gpu);
            gizmos = GizmoRenderer.create(app.gpu);
            gpuSceneReady = true;
            shaderReloader.init("assets/shaders");
        }

        dock.initDefaultLayout(1280.0f, 768.0f);

        world = SceneWorld.init;
        world.ensureRegistered!Camera3D();
        camera = Camera.create(0.9f, 16.0f / 9.0f, 0.1f, 1000.0f);
        gizmoTool.space = GizmoSpace.world;
        gizmoTool.snapEnabled = false;
        gizmoTool.showGrid = true;

        if (scenePath.length > 0 && exists(scenePath)) {
            if (!openSceneFile(scenePath))
                spawnGroundAndCube();
        } else {
            if (scenePath.length > 0)
                warn("Falha ao carregar cena: arquivo não encontrado.");
            spawnGroundAndCube();
        }
    }

    void update(ref InputState input, float dt, float screenW, float screenH) {
        uiClock += dt;
        immutable bool typing = focusIsText();
        EditorAction action;
        static if (__traits(compiles, pollShortcuts(input, true)))
            action = pollShortcuts(input, typing);
        else {
            action = pollShortcuts(input);
            if (typing)
                action = allowWhileTyping(action);
        }
        runShortcut(action);

        pointerPressTag = 0;
        queue.clear();
        inputCtx.update(ui, queue, input, dt);

        foreach (ref const ev; queue.items) {
            if (!ui.isValid(ev.node))
                continue;
            immutable uint tag = ui.get(ev.node).customTag;
            if (ev.kind == UiEventKind.mouseDown) {
                pointerPressTag = tag;
                if (nameDirty && tag != nameFieldTag)
                    commitName();
                if (hierarchyRename != noSelection && tag != nameFieldTag)
                    hierarchyRename = noSelection;
                if ((tag & 0xFF00_0000) == dragTagBase)
                    beginValueDrag(tag & 0xFF);
            } else if (ev.kind == UiEventKind.textChange && tag == nameFieldTag) {
                onNameText(ev.text[0 .. ev.textLen]);
            } else if (ev.kind == UiEventKind.submit && tag == nameFieldTag) {
                commitName();
            } else if (ev.kind == UiEventKind.click) {
                handleClick(tag, ev.node);
            }
        }
        if (draggingValue)
            applyValueDrag(input);

        if (!isHeadless && activeView == ActiveView.viewport && playMode.isEditing())
            updateViewportPointer(input, dt);
        else
            flyCamActive = false;

        input.clearKeyEdges();
        input.clearPointerEdges();

        playMode.update(world, physics, input, dt, hotReload);
        if (hotReload.enabled && !isHeadless) {
            Diagnostic[] diags;
            hotReload.pollAndReload(world, world.types, world.strings, dt, diags);
        }
        if (!isHeadless) {
            shaderReloader.pollAndReload(&scene, null, &gizmos, &uiRenderer, &app.renderer, dt);
        }

        if (!isHeadless && activeView == ActiveView.viewport && !flyCamActive)
            camera.lookAt(flyCam.position, flyCam.position + flyCam.forward());

        rebuildUi(screenW, screenH, focusIsText());
        measureTextNodes(ui, ui.root, font);
        computeLayout(ui, ui.root, screenW, screenH);
        inputCtx.applyState(ui);
        if (focusRenameField && ui.isValid(hierarchyPanel.renameField)) {
            inputCtx.focusedNode = hierarchyPanel.renameField;
            ui.get(hierarchyPanel.renameField).focused = true;
            focusRenameField = false;
        }

        if (activeViewportNode.isValid() && ui.isValid(activeViewportNode)) {
            const vn = &ui.get(activeViewportNode);
            vpX = vn.layoutX;
            vpY = vn.layoutY;
            vpW = vn.layoutWidth;
            vpH = vn.layoutHeight;
            vpValid = vpW >= 8 && vpH >= 8;
            if (vpValid && vpH > 0)
                camera.aspect = vpW / vpH;
        } else {
            vpValid = false;
        }
        activeViewportNode = UiNodeId.init;
    }

    void render() {
        auto frame = app.beginFrame(Color4(0.025f, 0.03f, 0.04f, 1.0f));
        if (!frame.valid) {
            framesSkipped++;
            return;
        }

        if (gpuSceneReady && vpValid) {
            frame.setViewport(vpX, vpY, vpW, vpH, app.window.width, app.window.height);
            immutable bool gameTab = activeView == ActiveView.game;
            EntityId gameCam = noSelection;
            if (gameTab)
                gameCam = findCurrentCamera(world);

            if (!gameTab || gameCam != noSelection) {
                Camera viewCam;
                if (gameTab)
                    viewCam = sceneCameraToGpu(world, gameCam, vpW, vpH);
                else
                    viewCam = camera;

                scene.begin(viewCam);
                drawMeshes();
                scene.end(frame);

                if (!gameTab) {
                    gizmos.begin(viewCam.viewProjection());
                    if (playMode.isEditing())
                        gizmoTool.draw(world, selection.primary, gizmos);
                    else if (gizmoTool.showGrid)
                        gizmos.grid(gizmoTool.gridSize, gizmoTool.gridCells,
                            Color4(0.25f, 0.25f, 0.28f, 1.0f), 0);
                    drawCameraFrustums();
                    drawSelectionHighlights(world, selection, gizmos);
                    gizmos.render(frame);
                }
            }
        }

        // Read clicks off the Wayland socket before the swapchain wait.
        app.pumpEvents();
        if (app.input.hasPendingEdges())
            app.input.keepEdgesForNextFrame();

        app.resolvePost(frame);
        if (!frame.valid) {
            if (frame.acquireNeedsRecover())
                app.recoverSurface();
            framesSkipped++;
            return;
        }

        if (font.isDirty)
            uiRenderer.uploadFontAtlas(font);
        uiRenderer.begin();
        uiRenderer.renderTree(ui, ui.root, font);
        uiRenderer.flush(frame.pass, cast(float) app.window.width, cast(float) app.window.height);

        app.endFrame(frame);
        framesPresented++;
    }

    void run() {
        while (app.running) {
            app.pollEvents();
            app.handleResize();
            if (app.input.keyPressed(Key.escape)) {
                if (playMode.isPlaying() || playMode.isPaused())
                    stopPlay();
                else if (focusIsText() || hierarchyRename != noSelection || nameDirty)
                    cancelRename();
                else
                    break;
            }
            update(app.input, 1.0f / 60.0f, cast(float) app.window.width, cast(float) app.window.height);
            render();
        }
        cleanup();
    }

    void runHeadlessFrames(uint frameCount, bool assertNoGc) {
        info("Running editor headless benchmark...");
        checkDemoContract();

        InputState mockInput;
        mockInput.beginFrame();

        foreach (_; 0 .. 5)
            update(mockInput, 1.0f / 60.0f, 1280.0f, 768.0f);

        size_t gcBefore = 0;
        if (assertNoGc) {
            GC.collect();
            gcBefore = GC.stats().allocatedInCurrentThread;
        }

        foreach (f; 0 .. frameCount)
            update(mockInput, 1.0f / 60.0f, 1280.0f, 768.0f);

        if (assertNoGc) {
            size_t gcAfter = GC.stats().allocatedInCurrentThread;
            size_t delta = gcAfter - gcBefore;
            writefln("GC allocations over %u frames in EditorApp: %u bytes", frameCount, delta);
            assert(delta == 0, "GC allocations detected in Editor frame path!");
        }

        info("EditorApp headless benchmark completed successfully!");
    }

    void cleanup() {
        info("Frames presented: ", framesPresented, ", skipped (no swapchain image): ", framesSkipped);
        if (playMode.isPlaying() || playMode.isPaused())
            playMode.stop(world, physics, world.strings, lightSettings, hotReload);
        shaderReloader.shutdown();
        hotReload.shutdown(world);
        if (gpuSceneReady) {
            gizmos.destroy();
            planeMesh.destroy();
            sphereMesh.destroy();
            cubeMesh.destroy();
            scene.destroy();
            gpuSceneReady = false;
        }
        if (!isHeadless)
            uiRenderer.release();
    }

    private void checkDemoContract() {
        if (currentScenePath != "assets/scenes/untitled.scene.json")
            return;
        assert(world.entityCount() == 3);

        int dynamics = 0;
        int statics = 0;
        foreach (e; world.query!PhysicsBody()) {
            if (!world.alive(e))
                continue;
            auto pb = world.get!PhysicsBody(e);
            if (pb.enabled == 0)
                continue;
            if (pb.motion == PhysicsMotion.dynamic_)
                dynamics++;
            else if (pb.motion == PhysicsMotion.static_)
                statics++;
        }
        assert(dynamics == 1);
        assert(statics == 1);

        immutable cam = findCurrentCamera(world);
        assert(cam != noSelection);
        assert(world.get!Camera3D(cam).current == 1);
        auto gpu = sceneCameraToGpu(world, cam, 160.0f, 90.0f);
        assert(gpu.position.x == 0 && gpu.position.y == 1.6f && gpu.position.z == 8);
        assert(gpu.target.z < gpu.position.z);
        assert(gpu.target.x == gpu.position.x);
        assert(gpu.target.y == gpu.position.y);

        assert(playMode.physicsSim.beginSimulate(world, physics));
        foreach (_; 0 .. 20)
            playMode.physicsSim.tick(world, physics, 1.0f / 60.0f);
        bool fell = false;
        foreach (e; world.query!(Transform, PhysicsBody)()) {
            if (!world.alive(e))
                continue;
            auto pb = world.get!PhysicsBody(e);
            if (pb.motion == PhysicsMotion.dynamic_ && world.get!Transform(e).position.y < 2.0f)
                fell = true;
        }
        assert(fell);
        playMode.physicsSim.stopSimulate(world);
    }

    private void rebuildUi(float screenW, float screenH, bool nameFieldFocused) {
        syncNameBuffer(nameFieldFocused);
        ui.resetForRebuild();
        activeView = ActiveView.none;
        activeViewportNode = UiNodeId.init;

        auto root = ui.root;
        ui.get(root).style.direction = UiFlexDirection.column;
        ui.get(root).style.backgroundColor = Color4(0, 0, 0, 0);

        auto mb = menuBar(ui, root, theme);
        addMenuButton(mb, "Cena", PopupKind.arquivo);
        addMenuButton(mb, "Editar", PopupKind.editar);
        addMenuButton(mb, "Criar", PopupKind.criar);
        addMenuButton(mb, "Janela", PopupKind.janela);

        UiStyle tbStyle;
        tbStyle.direction = UiFlexDirection.row;
        tbStyle.widthMode = UiSizeMode.fill;
        tbStyle.height = 32.0f;
        tbStyle.heightMode = UiSizeMode.fixed;
        tbStyle.backgroundColor = theme.colors.bgSurface;
        tbStyle.alignItems = UiAlign.center;
        tbStyle.padding = [4.0f, 8.0f, 4.0f, 8.0f];
        tbStyle.gap = 8.0f;

        UiNodeId tb = ui.createNode(root, tbStyle);
        UiNodeId pBtn = button(ui, tb, "Play", theme);
        ui.get(pBtn).customTag = playTag;
        if (playMode.isPlaying())
            ui.get(pBtn).style.backgroundColor = theme.colors.accent;

        UiNodeId pauseBtn = button(ui, tb, "Pause", theme);
        ui.get(pauseBtn).customTag = pauseTag;

        UiNodeId stopBtn = button(ui, tb, "Stop", theme);
        ui.get(stopBtn).customTag = stopTag;

        char[96] sceneLabel;
        immutable uint sceneLabelLen = formatSceneLabel(sceneLabel);
        label(ui, tb, sceneLabel[0 .. sceneLabelLen], theme.colors.textDim, 12.0f);

        UiStyle dockAreaStyle;
        dockAreaStyle.direction = UiFlexDirection.column;
        dockAreaStyle.widthMode = UiSizeMode.fill;
        dockAreaStyle.heightMode = UiSizeMode.fill;
        dockAreaStyle.flexGrow = 1.0f;
        dockAreaStyle.backgroundColor = Color4(0, 0, 0, 0);

        UiNodeId dockArea = ui.createNode(root, dockAreaStyle);
        dock.computeLayout(0, 0, screenW, screenH - 56.0f);

        foreach (uint i; 1 .. dock.MAX_NODES) {
            if (dock.pool[i].inUse && dock.pool[i].kind == DockKind.leaf)
                renderDockLeaf(i, dockArea);
        }

        drawPopup(screenW, screenH);
    }

    private void renderDockLeaf(uint leafIdx, UiNodeId parentContainer) {
        const leaf = &dock.pool[leafIdx];
        if (leaf.tabCount == 0)
            return;

        const(char)[] leafTitle = leaf.getActiveTab();
        immutable bool seeThrough = tabIs(leafTitle, "Viewport", "Scene") || leafTitle == "Game";

        UiStyle leafStyle;
        leafStyle.position = UiPosition.absolute;
        leafStyle.left = leaf.x;
        leafStyle.top = leaf.y;
        leafStyle.width = leaf.width;
        leafStyle.height = leaf.height;
        leafStyle.widthMode = UiSizeMode.fixed;
        leafStyle.heightMode = UiSizeMode.fixed;
        leafStyle.direction = UiFlexDirection.column;
        leafStyle.clipChildren = true;
        leafStyle.backgroundColor = seeThrough ? Color4(0, 0, 0, 0) : theme.colors.bgBase;
        leafStyle.borderWidth = 1.0f;
        leafStyle.borderColor = theme.colors.border;

        UiNodeId leafNode = ui.createNode(parentContainer, leafStyle);

        auto tb = tabBar(ui, leafNode, theme);
        foreach (t; 0 .. leaf.tabCount) {
            bool isActive = (t == leaf.activeTab);
            UiNodeId tab = tabItem(ui, tb, leaf.getTab(t), isActive, true, theme);
            ui.get(tab).customTag = 0xA100_0000 | (leafIdx << 8) | t;
        }

        const(char)[] activeTitle = leaf.getActiveTab();
        UiStyle contentStyle;
        contentStyle.direction = UiFlexDirection.column;
        contentStyle.widthMode = UiSizeMode.fill;
        contentStyle.heightMode = UiSizeMode.fill;
        contentStyle.flexGrow = 1.0f;
        contentStyle.clipChildren = true;

        UiNodeId contentNode = ui.createNode(leafNode, contentStyle);

        if (tabIs(activeTitle, "Cena", "Hierarchy")) {
            hierarchyPanel.buildUi(world, selection, world.strings, ui, contentNode, theme,
                hierarchyRename, nameBuf[0 .. nameLen],
                (scope const(char)[] kind) @safe { spawnByName(kind); });
        } else if (tabIs(activeTitle, "Inspetor", "Inspector")) {
            immutable bool useEuler = draggingValue && dragEntity == selection.primary
                && dragSlot >= 3 && dragSlot <= 5;
            inspectorPanel.buildUi(world, selection, ui, contentNode, theme,
                nameBuf[0 .. nameLen], playMode.isEditing(), useEuler, dragEuler);
        } else if (tabIs(activeTitle, "Viewport", "Scene")) {
            sceneViewPanel.buildUi(ui, contentNode, theme, gizmoTool.mode, gizmoTool.showGrid, gizmoTool.snapEnabled);
            activeViewportNode = sceneViewPanel.vpNode;
            activeView = ActiveView.viewport;
        } else if (activeTitle == "Game") {
            char[80] camLabel;
            immutable camId = findCurrentCamera(world);
            immutable uint camLen = formatCameraLabel(camLabel, camId);
            gameViewPanel.buildUi(ui, contentNode, theme, playMode.isPlaying(),
                camLabel[0 .. camLen], camId == noSelection);
            activeViewportNode = gameViewPanel.vpNode;
            activeView = ActiveView.game;
        } else if (activeTitle == "Console") {
            consolePanel.buildUi(ui, contentNode, theme);
        } else if (tabIs(activeTitle, "Arquivos", "Project")) {
            projectPanel.buildUi(assetDb, ui, contentNode, theme);
        }
    }

    private void addMenuButton(UiNodeId bar, scope const(char)[] labelText, PopupKind kind) {
        auto id = menuBarItem(ui, bar, labelText, theme);
        ui.get(id).customTag = 0xD000_0000 | kind;
        if (popup == kind)
            ui.get(id).style.backgroundColor = theme.colors.bgActive;
    }

    private void togglePopup(PopupKind kind, UiNodeId node) {
        if (kind < PopupKind.arquivo || kind > PopupKind.componente)
            return;
        if (popup == kind) {
            popup = PopupKind.none;
            return;
        }
        if (!ui.isValid(node))
            return;
        const n = &ui.get(node);
        popup = kind;
        popupX = n.layoutX;
        popupAnchorTop = n.layoutY;
        popupY = n.layoutY + n.layoutHeight;
    }

    private uint popupItemCount() const {
        final switch (popup) {
            case PopupKind.none: return 0;
            case PopupKind.arquivo: return 2;
            case PopupKind.editar: return 4;
            case PopupKind.gameObject: return 0;
            case PopupKind.janela: return 6;
            case PopupKind.ajuda: return 0;
            case PopupKind.criar: return 4;
            case PopupKind.componente: return 0;
        }
    }

    private void drawPopup(float screenW, float screenH) {
        immutable uint nItems = popupItemCount();
        if (nItems == 0)
            return;

        immutable float menuW = 220.0f;
        immutable float menuH = nItems * 24.0f + 12.0f;
        float x = popupX;
        float y = popupY + 2.0f;
        if (y + menuH > screenH && popupAnchorTop > menuH)
            y = popupAnchorTop - menuH - 2.0f;
        if (x + menuW > screenW)
            x = screenW - menuW;
        if (x < 4)
            x = 4;
        if (y < 4)
            y = 4;

        auto menu = contextMenu(ui, ui.root, x, y, theme, menuW);
        ui.get(menu).customTag = 0xD200_0000;

        void item(scope const(char)[] labelText, scope const(char)[] shortcut, MenuAction action) {
            auto id = menuItem(ui, menu, labelText, shortcut, theme);
            ui.get(id).customTag = 0xD100_0000 | action;
        }

        final switch (popup) {
            case PopupKind.none:
            case PopupKind.gameObject:
            case PopupKind.ajuda:
            case PopupKind.componente:
                break;
            case PopupKind.arquivo:
                item("Nova cena", "Ctrl+N", MenuAction.newScene);
                item("Salvar cena", "Ctrl+S", MenuAction.saveScene);
                break;
            case PopupKind.editar:
                item("Desfazer", "Ctrl+Z", MenuAction.undo);
                item("Refazer", "Ctrl+Y", MenuAction.redo);
                item("Duplicar", "Ctrl+D", MenuAction.duplicate);
                item("Excluir", "Del", MenuAction.deleteSel);
                break;
            case PopupKind.criar:
                item("Cubo", "", MenuAction.cube);
                item("Esfera", "", MenuAction.sphere);
                item("Plano", "", MenuAction.plane);
                item("Câmera", "", MenuAction.camera);
                break;
            case PopupKind.janela:
                item("Cena", "", MenuAction.winHierarchy);
                item("Viewport", "", MenuAction.winScene);
                item("Game", "", MenuAction.winGame);
                item("Inspetor", "", MenuAction.winInspector);
                item("Arquivos", "", MenuAction.winProject);
                item("Console", "", MenuAction.winConsole);
                break;
        }
    }

    private void handleClick(uint tag, UiNodeId node) {
        immutable bool menuBar = (tag & 0xFF00_0000) == 0xD000_0000 && (tag & 0xFF) != 0;
        immutable bool action = (tag & 0xFF00_0000) == 0xD100_0000;
        immutable bool chrome = tag == 0xD200_0000;
        immutable bool drag = (tag & 0xFF00_0000) == dragTagBase;

        if (menuBar) {
            togglePopup(cast(PopupKind)(tag & 0xFF), node);
            return;
        }
        if (chrome)
            return;
        if (action) {
            runAction(tag & 0xFF);
            popup = PopupKind.none;
            return;
        }
        if (popup != PopupKind.none)
            popup = PopupKind.none;
        if (drag)
            return;

        if (tag == playTag) {
            startPlay();
        } else if (tag == pauseTag) {
            if (playMode.isPlaying())
                playMode.pause();
        } else if (tag == stopTag) {
            stopPlay();
        } else if (tag == 0xBB01) {
            assetDb.scanAssets("assets");
            projectPanel.dirty = true;
        } else if (tag == 0xBB20) {
            projectPanel.currentDir = "assets";
            projectPanel.dirty = true;
        } else if (tag == 0xBB22) {
            projectPanel.goUp();
        } else if ((tag & 0xFFFF_0000) == 0xB200_0000) {
            uint idx = tag & 0xFFFF;
            if (idx < projectPanel.cachedItems.length) {
                if (projectPanel.cachedItems[idx].isDir) {
                    projectPanel.currentDir = projectPanel.cachedItems[idx].fullPath;
                    projectPanel.dirty = true;
                } else {
                    projectPanel.selectedItem = projectPanel.cachedItems[idx].fullPath;
                    if (isScenePath(projectPanel.selectedItem))
                        openSceneFile(projectPanel.selectedItem);
                }
            }
        } else if ((tag & 0xFF00_0000) == 0xA100_0000) {
            uint leafIdx = (tag >> 8) & 0xFF;
            uint tabIdx = tag & 0xFF;
            if (leafIdx > 0 && leafIdx < dock.MAX_NODES && dock.pool[leafIdx].inUse
                && tabIdx < dock.pool[leafIdx].tabCount)
                dock.pool[leafIdx].activeTab = tabIdx;
        } else if (tag == gridToggleTag) {
            gizmoTool.showGrid = !gizmoTool.showGrid;
        } else if (tag == snapToggleTag) {
            gizmoTool.snapEnabled = !gizmoTool.snapEnabled;
        } else if (tag == gizmoMoveTag) {
            gizmoTool.mode = GizmoMode.translate;
        } else if (tag == gizmoRotateTag) {
            gizmoTool.mode = GizmoMode.rotate;
        } else if (tag == gizmoScaleTag) {
            gizmoTool.mode = GizmoMode.scale;
        } else if (tag == 0xC000_0030) {
            clearLogHistory();
        } else if (tag == physicsToggleTag) {
            toggleDynamicPhysics();
        } else if (tag == cameraCurrentTag) {
            toggleCurrentCamera();
        } else if (tag == meshCubeTag) {
            setMeshKind(VisualKind.cube);
        } else if (tag == meshSphereTag) {
            setMeshKind(VisualKind.sphere);
        } else if (tag == meshPlaneTag) {
            setMeshKind(VisualKind.plane);
        } else if ((tag & 0xFF00_0000) == 0xB000_0000) {
            EntityId id = tag & 0x0FFF_FFFF;
            if (world.alive(id)) {
                if (id == lastHierarchyClick && uiClock - lastHierarchyClickAt < 0.45f
                        && playMode.isEditing())
                    beginRename(id);
                else
                    selectEntity(id);
                lastHierarchyClick = id;
                lastHierarchyClickAt = uiClock;
            }
        }
    }

    private void runShortcut(EditorAction action) {
        switch (action) {
            case EditorAction.saveScene:
                saveCurrentScene();
                break;
            case EditorAction.openScene:
                showPanel("Arquivos");
                break;
            case EditorAction.newScene:
                newScene();
                break;
            case EditorAction.undo:
                if (nameDirty)
                    commitName();
                commands.undo(world, selection);
                nameBound = noSelection;
                break;
            case EditorAction.redo:
                if (nameDirty)
                    commitName();
                commands.redo(world, selection);
                nameBound = noSelection;
                break;
            case EditorAction.duplicate:
                duplicatePrimary();
                break;
            case EditorAction.deleteSelection:
                deleteSelectionUndo();
                break;
            case EditorAction.focusCamera:
                focusSelection();
                break;
            case EditorAction.renameEntity:
                if (!selection.empty() && world.alive(selection.primary))
                    beginRename(selection.primary);
                break;
            case EditorAction.togglePlay:
                if (playMode.isEditing())
                    startPlay();
                else
                    stopPlay();
                break;
            case EditorAction.pausePlay:
                if (playMode.isPlaying())
                    playMode.pause();
                break;
            case EditorAction.gizmoTranslate:
                gizmoTool.mode = GizmoMode.translate;
                break;
            case EditorAction.gizmoRotate:
                gizmoTool.mode = GizmoMode.rotate;
                break;
            case EditorAction.gizmoScale:
                gizmoTool.mode = GizmoMode.scale;
                break;
            case EditorAction.stepPlay:
            case EditorAction.none:
                break;
            default:
                break;
        }
    }

    private void runAction(uint action) {
        switch (action) {
            case MenuAction.newScene:
                newScene();
                break;
            case MenuAction.saveScene:
                saveCurrentScene();
                break;
            case MenuAction.undo:
                if (nameDirty)
                    commitName();
                if (!commands.undo(world, selection))
                    info("Nada para desfazer");
                nameBound = noSelection;
                break;
            case MenuAction.redo:
                if (nameDirty)
                    commitName();
                if (!commands.redo(world, selection))
                    info("Nada para refazer");
                nameBound = noSelection;
                break;
            case MenuAction.duplicate:
                duplicatePrimary();
                break;
            case MenuAction.deleteSel:
                deleteSelectionUndo();
                break;
            case MenuAction.cube:
                spawnVisual(VisualKind.cube);
                break;
            case MenuAction.sphere:
                spawnVisual(VisualKind.sphere);
                break;
            case MenuAction.plane:
                spawnVisual(VisualKind.plane);
                break;
            case MenuAction.camera:
                spawnCamera();
                break;
            case MenuAction.winHierarchy:
                showPanel("Cena");
                break;
            case MenuAction.winScene:
                showPanel("Viewport");
                break;
            case MenuAction.winGame:
                showPanel("Game");
                break;
            case MenuAction.winInspector:
                showPanel("Inspetor");
                break;
            case MenuAction.winProject:
                showPanel("Arquivos");
                break;
            case MenuAction.winConsole:
                showPanel("Console");
                break;
            default:
                break;
        }
    }

    private void newScene() {
        if (!playMode.isEditing())
            stopPlay();
        if (nameDirty)
            commitName();
        world.clearEntities();
        selection.clear();
        commands.clear();
        nameBound = noSelection;
        nameDirty = false;
        popup = PopupKind.none;
        spawnGroundAndCube();
    }

    private bool openSceneFile(string path) {
        world.ensureRegistered!Camera3D();
        SceneFile sf;
        try {
            sf = loadSceneFile(path);
        } catch (Exception ex) {
            warn("Falha ao carregar cena: %s", ex.msg);
            return false;
        }
        const validation = validateScene(sf, true);
        if (!validation.ok) {
            if (validation.errors.length > 0)
                warn("Falha ao carregar cena: %s", validation.errors[0].message);
            else
                warn("Falha ao carregar cena: validação");
            return false;
        }
        if (!playMode.isEditing())
            stopPlay();
        if (nameDirty)
            commitName();
        SceneFile backup;
        try {
            backup = worldToSceneFile(world, lightSettings);
        } catch (Exception ex) {
            warn("Falha ao carregar cena: %s", ex.msg);
            return false;
        }
        try {
            loadSceneIntoWorld(world, sf, lightSettings);
        } catch (Exception ex) {
            warn("Falha ao carregar cena: %s", ex.msg);
            restoreSceneBackup(backup);
            return false;
        }
        selection.clear();
        commands.clear();
        nameBound = noSelection;
        nameDirty = false;
        popup = PopupKind.none;
        currentScenePath = path;
        sceneDirty = false;
        resetCamera();
        info("Cena carregada no editor: %s", path);
        return true;
    }

    /// Puts `backup` back after a load that already cleared the world.
    /// Entity ids change; the selection is dropped. `sceneDirty` stays as it was.
    private void restoreSceneBackup(ref SceneFile backup) {
        try {
            loadSceneIntoWorld(world, backup, lightSettings);
        } catch (Exception ex) {
            err("Falha ao restaurar a cena: %s", ex.msg);
            return;
        }
        selection.clear();
        nameBound = noSelection;
        nameDirty = false;
    }

    private void saveCurrentScene() {
        try {
            auto dir = dirName(currentScenePath);
            if (dir.length > 0 && dir != "." && !exists(dir))
                mkdirRecurse(dir);
            auto sf = worldToSceneFile(world, lightSettings);
            saveSceneFile(currentScenePath, sf);
            sceneDirty = false;
            info("Cena salva com sucesso: %s", currentScenePath);
        } catch (Exception ex) {
            err("Erro ao salvar cena: %s", ex.msg);
        }
    }

    private void spawnGroundAndCube() {
        world.ensureRegistered!Camera3D();
        spawnDemoLevel(world, selection);
        commands.clear();
        nameBound = noSelection;
        nameDirty = false;
        currentScenePath = "assets/scenes/untitled.scene.json";
        sceneDirty = true;
        resetCamera();
    }

    private void spawnByName(scope const(char)[] kind) {
        if (kind == "Esfera")
            spawnVisual(VisualKind.sphere);
        else if (kind == "Plano")
            spawnVisual(VisualKind.plane);
        else if (kind == "Câmera" || kind == "Camera")
            spawnCamera();
        else
            spawnVisual(VisualKind.cube);
    }

    private void spawnVisual(VisualKind kind) {
        if (!playMode.isEditing())
            return;
        Transform t;
        t.position = Vec3(0, kind == VisualKind.plane ? 0 : 0.5f, 0);
        t.scale = Vec3(1, 1, 1);
        const(char)[] labelText = "Cubo";
        if (kind == VisualKind.sphere)
            labelText = "Esfera";
        else if (kind == VisualKind.plane)
            labelText = "Plano";
        spawnPrimitive(world, commands, selection, kind, t, world.strings.intern(labelText));
        nameBound = noSelection;
        sceneDirty = true;
    }

    private void spawnCamera() {
        if (!playMode.isEditing())
            return;
        world.ensureRegistered!Camera3D();
        Transform t;
        t.position = flyCam.position + flyCam.forward() * 4;
        immutable pitchDeg = flyCam.pitch * (180.0f / cast(float) PI);
        immutable yawDeg = -(flyCam.yaw + cast(float) PI * 0.5f) * (180.0f / cast(float) PI);
        t.rotation = Quat.fromEulerYXZ(Vec3(pitchDeg, yawDeg, 0));
        t.scale = Vec3(1, 1, 1);

        Visual vis;
        vis.kind = VisualKind.none;
        vis.localHalfExtents = Vec3(0.25f, 0.2f, 0.4f);

        Camera3D lens;
        lens.current = findCurrentCamera(world) == noSelection ? 1 : 0;
        lens.fovYDeg = 70;
        lens.nearPlane = 0.1f;
        lens.farPlane = 1000;

        auto id = world.spawn();
        world.set(id, t);
        world.set(id, vis);
        world.set(id, lens);
        world.set(id, Name(world.strings.intern("Câmera")));

        CommandEntry cmd;
        cmd.kind = CommandKind.spawn;
        cmd.entity = id;
        cmd.after = captureEntity(world, id);
        commands.push(cmd);
        selection.select(id);
        nameBound = noSelection;
        sceneDirty = true;
    }

    private void duplicatePrimary() {
        if (!playMode.isEditing())
            return;
        if (selection.empty() || !world.alive(selection.primary)) {
            warn("Nada selecionado para duplicar");
            return;
        }
        if (nameDirty)
            commitName();
        EntityId src = selection.primary;
        auto snap = captureEntity(world, src);
        snap.transform.position.x += 0.5f;
        snap.transform.position.z += 0.5f;
        if (snap.hasCamera)
            snap.camera.current = 0;
        auto id = world.spawn();
        applySnapshotTo(world, id, snap);

        CommandEntry cmd;
        cmd.kind = CommandKind.duplicate;
        cmd.entity = id;
        cmd.source = src;
        cmd.after = captureEntity(world, id);
        commands.push(cmd);
        selection.select(id);
        nameBound = noSelection;
        sceneDirty = true;
    }

    private void deleteSelectionUndo() {
        if (!playMode.isEditing())
            return;
        if (selection.empty()) {
            warn("Nada selecionado para excluir");
            return;
        }
        if (nameDirty)
            commitName();
        immutable n = deleteSelected(world, commands, selection);
        nameBound = noSelection;
        nameDirty = false;
        if (n > 0)
            sceneDirty = true;
    }

    private void resetCamera() {
        flyCam.position = Vec3(0, 5, 10);
        flyCam.pitch = -0.35f;
        flyCam.yaw = -cast(float) PI * 0.5f;
        camera.lookAt(flyCam.position, flyCam.position + flyCam.forward());
    }

    private void focusSelection() {
        if (selection.empty() || !world.alive(selection.primary))
            return;
        if (!world.has!Transform(selection.primary))
            return;
        immutable target = focusPoint(world, selection.primary);
        flyCam.position = target + Vec3(0, 2, 6);
        immutable toTarget = target - flyCam.position;
        immutable len = toTarget.length();
        if (len > 1e-4f) {
            immutable dir = toTarget / len;
            flyCam.pitch = cast(float) asin(dir.y);
            flyCam.yaw = cast(float) atan2(dir.z, dir.x);
        }
        camera.lookAt(flyCam.position, flyCam.position + flyCam.forward());
    }

    private void startPlay() {
        if (nameDirty)
            commitName();
        cancelGizmoDrag();
        if (playMode.isPaused()) {
            playMode.resume();
            return;
        }
        if (!playMode.isEditing())
            return;
        playMode.start(world, physics, world.strings, lightSettings, hotReload);
        if (playMode.isPlaying())
            showPanel("Game");
    }

    private void stopPlay() {
        if (playMode.isEditing())
            return;
        if (!playMode.hasSnapshot)
            warn("PlayMode: sem snapshot; a cena não foi restaurada");
        cancelGizmoDrag();
        playMode.stop(world, physics, world.strings, lightSettings, hotReload);
        selection.clear();
        nameBound = noSelection;
        nameDirty = false;
        draggingValue = false;
        showPanel("Viewport");
    }

    private void cancelGizmoDrag() {
        if (gizmoTool.dragging && gizmoTool.dragCount > 0) {
            bool changed = false;
            foreach (i; 0 .. gizmoTool.dragCount) {
                immutable id = gizmoTool.dragIds[i];
                if (!world.alive(id) || !world.has!Transform(id))
                    continue;
                if (transformChanged(gizmoTool.dragStarts[i], world.get!Transform(id)))
                    changed = true;
            }
            if (changed) {
                recordGizmoDrag(commands, world,
                    gizmoTool.dragIds[0 .. gizmoTool.dragCount],
                    gizmoTool.dragStarts[0 .. gizmoTool.dragCount]);
                sceneDirty = true;
            }
        }
        gizmoTool.dragging = false;
    }

    private void updateViewportPointer(ref InputState input, float dt) {
        immutable bool over = vpValid
            && input.mx >= vpX && input.mx <= vpX + vpW
            && input.my >= vpY && input.my <= vpY + vpH;

        if (input.mouseDown(MouseButton.right) && (over || flyCamActive)) {
            flyCamActive = true;
            flyCam.update(input, dt, camera);
            return;
        }
        flyCamActive = false;
        if (!vpValid)
            return;

        immutable float localX = input.mx - vpX;
        immutable float localY = input.my - vpY;
        immutable bool inside = localX >= 0 && localY >= 0 && localX <= vpW && localY <= vpH;
        if (!inside && !gizmoTool.dragging)
            return;

        gizmoTool.space = GizmoSpace.world;
        if (!selection.empty() && world.alive(selection.primary) && world.has!Transform(selection.primary)) {
            immutable origin = worldPosition(world, selection.primary);
            immutable dist = (flyCam.position - origin).length();
            gizmoTool.pickRadius = dist * 0.05f;
            if (gizmoTool.pickRadius < 0.22f)
                gizmoTool.pickRadius = 0.22f;
        }

        auto ray = screenToWorldRay(localX, localY, vpW, vpH, camera.viewProjection());
        immutable bool pressCanvas = input.mousePressed(MouseButton.left)
            && pointerPressTag == viewportCanvasTag
            && inside;
        gizmoTool.update(world, selection, ray, pressCanvas,
            input.mouseDown(MouseButton.left), input.mouseUp(MouseButton.left));
        if (gizmoTool.dragJustEnded) {
            recordGizmoDrag(commands, world,
                gizmoTool.dragIds[0 .. gizmoTool.dragCount],
                gizmoTool.dragStarts[0 .. gizmoTool.dragCount]);
            sceneDirty = true;
        }
        if (pressCanvas && !gizmoTool.wantCaptureMouse()) {
            auto hit = pickClosestAabb(world, ray);
            if (hit.hit)
                selectEntity(hit.entity);
            else
                clearSelection();
        }
    }

    private void drawMeshes() {
        foreach (EntityId e; world.query!(Transform, Visual)()) {
            if (!world.alive(e))
                continue;
            immutable v = world.get!Visual(e);
            if (v.kind == VisualKind.none)
                continue;
            immutable t = world.get!Transform(e);

            Color4 col = Color4(0.75f, 0.75f, 0.80f, 1.0f);
            if (world.has!MaterialOverride(e)) {
                auto m = world.get!MaterialOverride(e);
                col = Color4(m.baseColor[0], m.baseColor[1], m.baseColor[2], m.baseColor[3]);
            }

            auto model = Mat4.translation(t.position.x, t.position.y, t.position.z)
                * t.rotation.toMat4()
                * Mat4.scaling(t.scale.x, t.scale.y, t.scale.z);

            if (v.kind == VisualKind.sphere)
                scene.drawMatrix(sphereMesh, model, col);
            else if (v.kind == VisualKind.plane)
                scene.drawMatrix(planeMesh, model, col);
            else
                scene.drawMatrix(cubeMesh, model, col);
        }
    }

    private void drawCameraFrustums() {
        foreach (e; world.query!Camera3D()) {
            if (!world.alive(e) || !world.has!Transform(e))
                continue;
            auto lens = world.get!Camera3D(e);
            auto t = world.get!Transform(e);
            t.position = worldPosition(world, e);
            immutable col = lens.current != 0
                ? Color4(0.3f, 0.8f, 1.0f, 1.0f)
                : Color4(0.55f, 0.55f, 0.58f, 1.0f);
            drawOneFrustum(t, lens, col);
        }
    }

    private void drawOneFrustum(Transform t, Camera3D lens, Color4 color) {
        immutable fov = lens.fovYDeg * (cast(float) PI / 180.0f);
        float nearD = lens.nearPlane;
        float farD = lens.farPlane;
        if (nearD < 0.01f)
            nearD = 0.01f;
        if (farD < nearD + 0.05f)
            farD = nearD + 0.05f;
        immutable origin = t.position;
        immutable q = t.rotation;
        Vec3 n0 = frustumCorner(origin, q, nearD, fov, -1, -1);
        Vec3 n1 = frustumCorner(origin, q, nearD, fov, 1, -1);
        Vec3 n2 = frustumCorner(origin, q, nearD, fov, 1, 1);
        Vec3 n3 = frustumCorner(origin, q, nearD, fov, -1, 1);
        Vec3 f0 = frustumCorner(origin, q, farD, fov, -1, -1);
        Vec3 f1 = frustumCorner(origin, q, farD, fov, 1, -1);
        Vec3 f2 = frustumCorner(origin, q, farD, fov, 1, 1);
        Vec3 f3 = frustumCorner(origin, q, farD, fov, -1, 1);
        gizmos.line(n0, n1, color);
        gizmos.line(n1, n2, color);
        gizmos.line(n2, n3, color);
        gizmos.line(n3, n0, color);
        gizmos.line(f0, f1, color);
        gizmos.line(f1, f2, color);
        gizmos.line(f2, f3, color);
        gizmos.line(f3, f0, color);
        gizmos.line(n0, f0, color);
        gizmos.line(n1, f1, color);
        gizmos.line(n2, f2, color);
        gizmos.line(n3, f3, color);
        immutable look = q.rotate(Vec3(0, 0, -1));
        gizmos.line(origin, origin + look * 0.45f, color);
    }

    private void selectEntity(EntityId id) {
        if (!world.alive(id))
            return;
        if (nameDirty && nameBound != id)
            commitName();
        selection.select(id);
        if (nameBound != id) {
            nameDirty = false;
            nameBound = noSelection;
        }
    }

    private void clearSelection() {
        if (nameDirty)
            commitName();
        selection.clear();
        nameBound = noSelection;
    }

    private void syncNameBuffer(bool nameFieldFocused) {
        if (selection.empty() || !world.alive(selection.primary)) {
            if (nameDirty)
                commitName();
            nameBound = noSelection;
            nameLen = 0;
            return;
        }
        immutable bool keep = nameFieldFocused && playMode.isEditing() && nameBound == selection.primary;
        if (nameDirty && !keep)
            commitName();
        if (keep)
            return;
        loadNameFrom(selection.primary);
        nameBound = selection.primary;
        nameDirty = false;
    }

    private void loadNameFrom(EntityId id) {
        if (world.has!Name(id)) {
            auto src = world.strings.get(world.get!Name(id).id);
            if (src.length > 0) {
                copyName(src);
                return;
            }
        }
        copyName(fallbackLiteral(id));
    }

    private void copyName(scope const(char)[] src) {
        immutable uint n = src.length < nameBuf.length ? cast(uint) src.length : cast(uint) nameBuf.length;
        nameBuf[0 .. n] = src[0 .. n];
        nameLen = n;
    }

    private const(char)[] fallbackLiteral(EntityId id) {
        if (world.has!Camera3D(id))
            return "Câmera";
        if (!world.has!Visual(id))
            return "Entidade";
        final switch (world.get!Visual(id).kind) {
            case VisualKind.none: return "Câmera";
            case VisualKind.cube: return "Cubo";
            case VisualKind.sphere: return "Esfera";
            case VisualKind.plane: return "Plano";
            case VisualKind.mesh: return "Mesh";
        }
    }

    private void onNameText(scope const(char)[] text) {
        if (!playMode.isEditing())
            return;
        copyName(text);
        nameDirty = true;
        if (!selection.empty() && world.alive(selection.primary))
            nameBound = selection.primary;
    }

    private void commitName() {
        if (!nameDirty)
            return;
        if (nameBound == noSelection || !world.alive(nameBound)) {
            nameDirty = false;
            return;
        }
        const(char)[] text = nameBuf[0 .. nameLen];
        if (nameLen == 0) {
            text = fallbackLiteral(nameBound);
            copyName(text);
        }
        world.set(nameBound, Name(world.strings.intern(text)));
        nameDirty = false;
        hierarchyRename = noSelection;
        sceneDirty = true;
    }

    private void beginRename(EntityId id) {
        if (!playMode.isEditing() || !world.alive(id))
            return;
        selectEntity(id);
        loadNameFrom(id);
        nameBound = id;
        nameDirty = false;
        hierarchyRename = id;
        focusRenameField = true;
        showPanel("Cena");
    }

    private void cancelRename() {
        nameDirty = false;
        hierarchyRename = noSelection;
        focusRenameField = false;
        if (nameBound != noSelection && world.alive(nameBound))
            loadNameFrom(nameBound);
        else if (!selection.empty() && world.alive(selection.primary))
            loadNameFrom(selection.primary);
        inputCtx.focusedNode = UiNodeId.init;
    }

    private void beginValueDrag(uint slot) {
        if (!playMode.isEditing())
            return;
        if (selection.empty() || !world.alive(selection.primary))
            return;
        dragEntity = selection.primary;
        dragSlot = slot;
        if (slot <= 8) {
            if (!world.has!Transform(dragEntity))
                return;
            dragBefore = world.get!Transform(dragEntity);
            if (slot >= 3 && slot <= 5)
                dragEuler = dragBefore.rotation.toEulerYXZ();
            draggingValue = true;
        } else if (slot <= 11) {
            if (!world.has!MaterialOverride(dragEntity)) {
                world.set(dragEntity, MaterialOverride.init);
                dragHadMaterial = false;
                dragMatBefore = MaterialOverride.init;
                sceneDirty = true;
            } else {
                dragHadMaterial = true;
                dragMatBefore = world.get!MaterialOverride(dragEntity);
            }
            draggingValue = true;
        } else if (slot <= 14) {
            if (!world.has!Camera3D(dragEntity))
                return;
            dragCamBefore = world.get!Camera3D(dragEntity);
            draggingValue = true;
        }
    }

    private void applyValueDrag(ref InputState input) {
        if (!draggingValue || !playMode.isEditing() || !world.alive(dragEntity)) {
            draggingValue = false;
            return;
        }
        float d = input.mdx * (input.shiftDown() ? 0.002f : 0.02f);
        if (dragSlot >= 3 && dragSlot <= 5)
            d *= 0.5f;
        else if (dragSlot == 12)
            d *= 25.0f;
        else if (dragSlot == 14)
            d *= 50.0f;

        if (d != 0 && dragSlot <= 8 && world.has!Transform(dragEntity)) {
            auto t = world.get!Transform(dragEntity);
            if (dragSlot <= 2) {
                if (dragSlot == 0) t.position.x += d;
                else if (dragSlot == 1) t.position.y += d;
                else t.position.z += d;
            } else if (dragSlot <= 5) {
                if (dragSlot == 3) dragEuler.x += d;
                else if (dragSlot == 4) dragEuler.y += d;
                else dragEuler.z += d;
                t.rotation = Quat.fromEulerYXZ(dragEuler);
            } else {
                if (dragSlot == 6) t.scale.x += d;
                else if (dragSlot == 7) t.scale.y += d;
                else t.scale.z += d;
                if (t.scale.x < 0.01f) t.scale.x = 0.01f;
                if (t.scale.y < 0.01f) t.scale.y = 0.01f;
                if (t.scale.z < 0.01f) t.scale.z = 0.01f;
            }
            world.set(dragEntity, t);
        } else if (d != 0 && dragSlot >= 9 && dragSlot <= 11 && world.has!MaterialOverride(dragEntity)) {
            auto m = world.get!MaterialOverride(dragEntity);
            if (dragSlot == 9) m.baseColor[0] += d;
            else if (dragSlot == 10) m.baseColor[1] += d;
            else m.baseColor[2] += d;
            foreach (i; 0 .. 3) {
                if (m.baseColor[i] < 0) m.baseColor[i] = 0;
                if (m.baseColor[i] > 1) m.baseColor[i] = 1;
            }
            m.baseColor[3] = 1;
            world.set(dragEntity, m);
        } else if (d != 0 && dragSlot >= 12 && dragSlot <= 14 && world.has!Camera3D(dragEntity)) {
            auto c = world.get!Camera3D(dragEntity);
            if (dragSlot == 12) {
                c.fovYDeg += d;
                if (c.fovYDeg < 10) c.fovYDeg = 10;
                if (c.fovYDeg > 120) c.fovYDeg = 120;
            } else if (dragSlot == 13) {
                c.nearPlane += d;
                if (c.nearPlane < 0.01f) c.nearPlane = 0.01f;
                if (c.nearPlane > c.farPlane - 0.1f) c.nearPlane = c.farPlane - 0.1f;
            } else {
                c.farPlane += d;
                if (c.farPlane < c.nearPlane + 0.1f) c.farPlane = c.nearPlane + 0.1f;
            }
            world.set(dragEntity, c);
        }

        if (!input.mouseDown(MouseButton.left)) {
            if (dragSlot <= 8 && world.has!Transform(dragEntity)) {
                auto after = world.get!Transform(dragEntity);
                if (transformChanged(dragBefore, after)) {
                    recordTransform(commands, dragEntity, dragBefore, after);
                    sceneDirty = true;
                }
            } else if (dragSlot <= 11 && world.has!MaterialOverride(dragEntity)) {
                auto after = world.get!MaterialOverride(dragEntity);
                if (!dragHadMaterial || materialChanged(dragMatBefore, after)) {
                    if (materialChanged(dragMatBefore, after))
                        recordMaterial(commands, dragEntity, dragMatBefore, after);
                    sceneDirty = true;
                }
            } else if (dragSlot <= 14 && world.has!Camera3D(dragEntity)) {
                auto after = world.get!Camera3D(dragEntity);
                if (after.fovYDeg != dragCamBefore.fovYDeg
                    || after.nearPlane != dragCamBefore.nearPlane
                    || after.farPlane != dragCamBefore.farPlane)
                    sceneDirty = true;
            }
            draggingValue = false;
        }
    }

    private void setMeshKind(VisualKind kind) {
        if (!playMode.isEditing())
            return;
        if (selection.empty() || !world.alive(selection.primary))
            return;
        auto e = selection.primary;
        if (world.has!Camera3D(e) || !world.has!Visual(e))
            return;
        auto vis = world.get!Visual(e);
        if (vis.kind == VisualKind.none)
            return;
        vis.kind = kind;
        vis.localHalfExtents = defaultHalfExtents(kind);
        world.set(e, vis);
        if (world.has!PhysicsBody(e)) {
            auto pb = world.get!PhysicsBody(e);
            pb.halfExtents = vis.localHalfExtents;
            world.set(e, pb);
        }
        sceneDirty = true;
    }

    private void toggleDynamicPhysics() {
        if (!playMode.isEditing())
            return;
        if (selection.empty() || !world.alive(selection.primary))
            return;
        auto e = selection.primary;
        if (world.has!Camera3D(e))
            return;
        bool on = false;
        if (world.has!PhysicsBody(e)) {
            auto pb = world.get!PhysicsBody(e);
            on = pb.enabled != 0 && pb.motion == PhysicsMotion.dynamic_;
        }
        if (on) {
            world.remove!PhysicsBody(e);
        } else {
            PhysicsBody pb;
            pb.enabled = 1;
            pb.motion = PhysicsMotion.dynamic_;
            pb.shape = PhysicsShapeKind.primitive;
            pb.mass = 1;
            if (world.has!Visual(e))
                pb.halfExtents = world.get!Visual(e).localHalfExtents;
            else
                pb.halfExtents = defaultHalfExtents(VisualKind.cube);
            world.set(e, pb);
        }
        sceneDirty = true;
    }

    private void toggleCurrentCamera() {
        if (!playMode.isEditing())
            return;
        if (selection.empty() || !world.alive(selection.primary))
            return;
        auto e = selection.primary;
        if (!world.has!Camera3D(e))
            return;
        if (world.get!Camera3D(e).current != 0) {
            world.get!Camera3D(e).current = 0;
        } else {
            foreach (other; world.query!Camera3D()) {
                if (!world.alive(other) || !world.has!Camera3D(other))
                    continue;
                world.get!Camera3D(other).current = other == e ? 1 : 0;
            }
        }
        sceneDirty = true;
    }

    private bool focusIsText() {
        if (!inputCtx.focusedNode.isValid() || !ui.isValid(inputCtx.focusedNode))
            return false;
        return ui.get(inputCtx.focusedNode).style.cursor == UiCursor.text;
    }

    private bool activateExact(scope const(char)[] title) {
        foreach (uint i; 1 .. dock.MAX_NODES) {
            if (!dock.pool[i].inUse || dock.pool[i].kind != DockKind.leaf)
                continue;
            foreach (uint t; 0 .. dock.pool[i].tabCount) {
                if (dock.pool[i].getTab(t) == title) {
                    dock.pool[i].activeTab = t;
                    return true;
                }
            }
        }
        return false;
    }

    private void showPanel(scope const(char)[] title) {
        if (activateExact(title))
            return;
        if (title == "Cena")
            activateExact("Hierarchy");
        else if (title == "Hierarchy")
            activateExact("Cena");
        else if (title == "Viewport")
            activateExact("Scene");
        else if (title == "Scene")
            activateExact("Viewport");
        else if (title == "Inspetor")
            activateExact("Inspector");
        else if (title == "Inspector")
            activateExact("Inspetor");
        else if (title == "Arquivos")
            activateExact("Project");
        else if (title == "Project")
            activateExact("Arquivos");
    }

    private uint formatSceneLabel(ref char[96] buf) {
        const(char)[] path = currentScenePath;
        size_t start = 0;
        foreach (i, c; path) {
            if (c == '/' || c == '\\')
                start = i + 1;
        }
        uint n = 0;
        foreach (c; path[start .. $]) {
            if (n >= buf.length)
                break;
            buf[n++] = c;
        }
        if (sceneDirty && n + 2 <= buf.length) {
            buf[n++] = ' ';
            buf[n++] = '*';
        }
        return n;
    }

    private uint formatCameraLabel(ref char[80] buf, EntityId id) {
        if (id == noSelection || !world.alive(id)) {
            enum m = "Nenhuma câmera";
            immutable uint n = m.length < buf.length ? cast(uint) m.length : cast(uint) buf.length;
            buf[0 .. n] = m[0 .. n];
            return n;
        }
        enum prefix = "Câmera: ";
        uint n = prefix.length < buf.length ? cast(uint) prefix.length : cast(uint) buf.length;
        buf[0 .. n] = prefix[0 .. n];
        if (world.has!Name(id)) {
            auto src = world.strings.get(world.get!Name(id).id);
            foreach (c; src) {
                if (n >= buf.length)
                    break;
                buf[n++] = c;
            }
        }
        return n;
    }
}

private EditorAction allowWhileTyping(EditorAction action) {
    switch (action) {
        case EditorAction.saveScene:
        case EditorAction.openScene:
        case EditorAction.newScene:
        case EditorAction.undo:
        case EditorAction.redo:
        case EditorAction.togglePlay:
            return action;
        default:
            return EditorAction.none;
    }
}

private bool tabIs(scope const(char)[] title, scope const(char)[] a, scope const(char)[] b) {
    return title == a || title == b;
}

private bool isScenePath(scope const(char)[] path) {
    enum suf = ".scene.json";
    if (path.length < suf.length)
        return false;
    return path[$ - suf.length .. $] == suf;
}

private bool transformChanged(Transform a, Transform b) {
    if (a.position != b.position || a.scale != b.scale)
        return true;
    return a.rotation.x != b.rotation.x || a.rotation.y != b.rotation.y
        || a.rotation.z != b.rotation.z || a.rotation.w != b.rotation.w;
}

private bool materialChanged(MaterialOverride a, MaterialOverride b) {
    foreach (i; 0 .. 4) {
        if (a.baseColor[i] != b.baseColor[i])
            return true;
    }
    return a.metallic != b.metallic || a.roughness != b.roughness;
}

private Vec3 frustumCorner(Vec3 origin, Quat q, float dist, float fovRad, float sx, float sy) {
    enum aspect = 16.0f / 9.0f;
    immutable h = cast(float) tan(fovRad * 0.5f) * dist;
    immutable w = h * aspect;
    return origin + q.rotate(Vec3(sx * w, sy * h, -dist));
}
