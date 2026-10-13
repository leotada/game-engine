/// Interactive UI gallery demo demonstrating the retained UI system.
module demo.ui_gallery;

import core.memory : GC;
import std.file : exists, read;
import std.stdio : writeln, writefln;

import bindings.sdl3;
import bindings.wgpu;
import engine.app : App;
import engine.core.log : info;
import engine.graphics.types : Color4;
import engine.platform.input : InputState, Key, MouseButton;
import engine.ui;

@safe:

struct UiGalleryDemo {
    App app;
    Font font;
    UiTree tree;
    UiBatchRenderer renderer;
    UiTheme theme;
    UiInputContext inputCtx;
    UiEventQueue queue;

    bool isHeadless = false;

    // Interactive state
    float sliderVal = 45.0f;
    float dragVal = 1.25f;
    bool checkboxVal = true;
    uint clickCounter = 0;

    // Node handles
    UiNodeId btnClick;
    UiNodeId sldNode;
    UiNodeId dragNode;
    UiNodeId chkNode;
    UiNodeId txtNode;
    UiNodeId statusLbl;

    void init(bool headless = false) {
        isHeadless = headless;

        // Load TTF Font
        if (exists("assets/fonts/default.ttf")) {
            ubyte[] fontData = () @trusted { return cast(ubyte[]) read("assets/fonts/default.ttf"); }();
            font.loadFromMemory(fontData, 16.0f);
        } else {
            writeln("Aviso: assets/fonts/default.ttf não encontrado!");
        }

        // Initialize UI systems
        tree = UiTree.create();
        theme = UiTheme.init;

        if (!headless) {
            app = App.create("UI Gallery — Retained UI & TTF Fonts", 1024, 720);
            renderer.init(app.gpu.getDevice(), app.gpu.getQueue(), app.gpu.getFormat(), font);
        }

        buildUi();
    }

    void buildUi() {
        auto root = tree.root;
        tree.get(root).style.direction = UiFlexDirection.column;
        tree.get(root).style.padding = [12.0f, 16.0f, 12.0f, 16.0f];
        tree.get(root).style.gap = 12.0f;
        tree.get(root).style.backgroundColor = theme.colors.bgBase;

        // Top Header
        auto header = tree.createNode(root);
        tree.get(header).style.direction = UiFlexDirection.row;
        tree.get(header).style.alignItems = UiAlign.center;
        tree.get(header).style.justifyContent = UiJustify.spaceBetween;
        tree.get(header).style.height = 36.0f;
        tree.get(header).style.heightMode = UiSizeMode.fixed;
        tree.get(header).style.padding = [4.0f, 8.0f, 4.0f, 8.0f];
        tree.get(header).style.backgroundColor = theme.colors.bgSurface;
        tree.get(header).style.cornerRadius = theme.cornerRadius;

        label(tree, header, "UI Retida — Galeria de Componentes (pt-BR: Ação, Configuração)", theme.colors.text, 14.0f);

        // Toolbar controls
        auto toolbar = tree.createNode(header);
        tree.get(toolbar).style.direction = UiFlexDirection.row;
        tree.get(toolbar).style.gap = 6.0f;
        iconButton(tree, toolbar, ">", theme, 28.0f);
        iconButton(tree, toolbar, "||", theme, 28.0f);
        iconButton(tree, toolbar, "[]", theme, 28.0f);

        // Main body: 2 columns
        auto bodyRow = tree.createNode(root);
        tree.get(bodyRow).style.direction = UiFlexDirection.row;
        tree.get(bodyRow).style.flexGrow = 1.0f;
        tree.get(bodyRow).style.gap = 12.0f;

        // Left Column (Controls)
        auto leftCol = tree.createNode(bodyRow);
        tree.get(leftCol).style.direction = UiFlexDirection.column;
        tree.get(leftCol).style.width = 340.0f;
        tree.get(leftCol).style.widthMode = UiSizeMode.fixed;
        tree.get(leftCol).style.gap = 10.0f;
        tree.get(leftCol).style.padding = [12.0f, 12.0f, 12.0f, 12.0f];
        tree.get(leftCol).style.backgroundColor = theme.colors.bgSurface;
        tree.get(leftCol).style.cornerRadius = theme.cornerRadius;

        label(tree, leftCol, "Controles Básicos", theme.colors.accent, 14.0f);

        btnClick = button(tree, leftCol, "Clique aqui (+1)", theme);
        sldNode = slider(tree, leftCol, sliderVal, 0.0f, 100.0f, theme, 300.0f);
        dragNode = dragValue(tree, leftCol, "Velocidade", dragVal, theme, 300.0f);
        chkNode = checkbox(tree, leftCol, "Habilitar Efeitos Visuais", checkboxVal, theme);
        txtNode = textField(tree, leftCol, "Texto editável...", theme, 300.0f);

        // Right Column (Preview / Inspector)
        auto rightCol = tree.createNode(bodyRow);
        tree.get(rightCol).style.direction = UiFlexDirection.column;
        tree.get(rightCol).style.flexGrow = 1.0f;
        tree.get(rightCol).style.gap = 10.0f;
        tree.get(rightCol).style.padding = [12.0f, 12.0f, 12.0f, 12.0f];
        tree.get(rightCol).style.backgroundColor = theme.colors.bgSurface;
        tree.get(rightCol).style.cornerRadius = theme.cornerRadius;

        label(tree, rightCol, "Estado & Eventos", theme.colors.accent, 14.0f);
        statusLbl = label(tree, rightCol, "Nenhum clique registrado ainda.", theme.colors.textDim);
    }

    void update(in InputState input, float dt, float screenW, float screenH) {
        queue.clear();
        inputCtx.update(tree, queue, input, dt);

        // Process UI events
        foreach (ref const ev; queue.items) {
            if (ev.isClick(btnClick)) {
                clickCounter++;
                char[64] buf;
                import core.stdc.stdio : snprintf;
                () @trusted {
                    snprintf(buf.ptr, buf.length, "Total de cliques: %u", clickCounter);
                }();
                import core.stdc.string : strlen;
                size_t len = () @trusted { return strlen(buf.ptr); }();
                tree.get(statusLbl).setText(buf[0 .. len]);
            }
        }

        // Compute layout
        computeLayout(tree, tree.root, screenW, screenH);
    }

    void render() {
        auto frame = app.beginFrame(theme.colors.bgBase);
        if (!frame.valid) return;

        app.resolvePost(frame);

        renderer.begin();
        renderer.renderTree(tree, tree.root, font);
        renderer.flush(frame.pass, cast(float)app.window.width, cast(float)app.window.height);

        app.endFrame(frame);
    }

    void run() {
        while (app.running) {
            app.pollEvents();
            if (app.input.keyPressed(Key.escape)) {
                break;
            }
            update(app.input, 1.0f / 60.0f, cast(float)app.window.width, cast(float)app.window.height);
            render();
        }
        cleanup();
    }

    void runHeadlessFrames(uint frameCount, bool assertNoGc) {
        info("Running headless frame benchmark...");
        InputState mockInput;
        mockInput.beginFrame();

        // Warmup 5 frames to settle one-time initial layout/buffers
        foreach (_; 0 .. 5) {
            update(mockInput, 1.0f / 60.0f, 1024.0f, 720.0f);
        }

        size_t gcBefore = 0;
        if (assertNoGc) {
            GC.collect();
            gcBefore = GC.stats().allocatedInCurrentThread;
        }

        foreach (f; 0 .. frameCount) {
            update(mockInput, 1.0f / 60.0f, 1024.0f, 720.0f);
        }

        if (assertNoGc) {
            size_t gcAfter = GC.stats().allocatedInCurrentThread;
            size_t delta = gcAfter - gcBefore;
            writefln("GC allocations over %u frames: %u bytes", frameCount, delta);
            assert(delta == 0, "GC allocations detected in UI frame path!");
        }

        info("Headless benchmark completed successfully!");
    }

    void cleanup() {
        if (!isHeadless) {
            renderer.release();
        }
    }
}

void main(string[] args) {
    bool headless = false;
    uint headlessFrames = 0;
    bool assertNoGc = false;

    foreach (arg; args[1 .. $]) {
        if (arg == "--assert-no-gc") {
            assertNoGc = true;
        } else if (arg.length > 18 && arg[0 .. 18] == "--headless-frames=") {
            headless = true;
            import std.conv : to;
            headlessFrames = to!uint(arg[18 .. $]);
        }
    }

    UiGalleryDemo demo;
    demo.init(headless);

    if (headlessFrames > 0) {
        demo.runHeadlessFrames(headlessFrames, assertNoGc);
    } else {
        demo.run();
    }
}
