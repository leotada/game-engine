/// Project Manager window: recent projects launcher and new project scaffolding.
module editor.project_manager;

import std.file : exists, mkdirRecurse, write;
import std.path : buildPath;
import engine.project.project : ProjectConfig, saveProject, RecentProjectsManager;
import engine.scene.scene_file : SceneFile, saveSceneFile;
import engine.ui;
import engine.core.log : info, warn;

@safe:

struct ProjectManager {
    RecentProjectsManager recent;
    string selectedPath;

    void init() {
        recent.load();
    }

    void buildUi(ref UiTree ui, UiNodeId parent, ref const UiTheme theme) @trusted {
        UiStyle mainStyle;
        mainStyle.direction = UiFlexDirection.column;
        mainStyle.widthMode = UiSizeMode.fill;
        mainStyle.heightMode = UiSizeMode.fill;
        mainStyle.padding = [16.0f, 16.0f, 16.0f, 16.0f];
        mainStyle.gap = 12.0f;
        mainStyle.backgroundColor = theme.colors.bgBase;

        UiNodeId rootNode = ui.createNode(parent, mainStyle);

        label(ui, rootNode, "Game Engine — Gerenciador de Projetos", theme.colors.text);

        // Action buttons
        UiStyle btnRow;
        btnRow.direction = UiFlexDirection.row;
        btnRow.gap = 8.0f;
        UiNodeId row = ui.createNode(rootNode, btnRow);

        UiNodeId newBtn = button(ui, row, "+ Novo Projeto", theme);
        ui.get(newBtn).customTag = 0xCC01;

        UiNodeId openBtn = button(ui, row, "Abrir Pasta...", theme);
        ui.get(openBtn).customTag = 0xCC02;

        // Recent projects list
        label(ui, rootNode, "Projetos Recentes:", theme.colors.textDim);

        UiNodeId list = scrollView(ui, rootNode, theme);

        foreach (p; recent.recentPaths) {
            UiStyle itemStyle;
            itemStyle.direction = UiFlexDirection.row;
            itemStyle.widthMode = UiSizeMode.fill;
            itemStyle.height = 32.0f;
            itemStyle.heightMode = UiSizeMode.fixed;
            itemStyle.padding = [6.0f, 10.0f, 6.0f, 10.0f];
            itemStyle.backgroundColor = (selectedPath == p) ? theme.colors.bgActive : theme.colors.bgSurface;
            itemStyle.cornerRadius = theme.cornerRadius;

            UiNodeId item = ui.createNode(list, itemStyle);
            label(ui, item, p, theme.colors.text);
        }
    }

    /// Scaffolds a new project directory structure with default project.json, dub.json, and scene.
    static bool createNewProject(string targetDir, string projectName) @trusted {
        try {
            if (!exists(targetDir)) mkdirRecurse(targetDir);

            auto assetsDir = buildPath(targetDir, "assets");
            auto scenesDir = buildPath(assetsDir, "scenes");
            auto scriptsDir = buildPath(targetDir, "scripts");
            mkdirRecurse(scenesDir);
            mkdirRecurse(scriptsDir);

            // 1. project.json
            ProjectConfig cfg;
            cfg.name = projectName;
            cfg.startScene = "assets/scenes/main.scene.json";
            saveProject(buildPath(targetDir, "project.json"), cfg);

            // 2. assets/scenes/main.scene.json
            SceneFile sf;
            sf.meta.name = projectName ~ " - Main Scene";
            saveSceneFile(buildPath(scenesDir, "main.scene.json"), sf);

            // 3. scripts/player.d
            string scriptCode =
                "module scripts.player;\n\n" ~
                "import engine.script;\n\n" ~
                "@component static struct PlayerController {\n" ~
                "    @export_ float moveSpeed = 5.0f;\n\n" ~
                "    void onStart(scope ref ScriptContext ctx) {\n" ~
                "    }\n\n" ~
                "    void onUpdate(scope ref ScriptContext ctx, float dt) {\n" ~
                "    }\n" ~
                "}\n";
            write(buildPath(scriptsDir, "player.d"), scriptCode);

            // 4. .gitignore
            write(buildPath(targetDir, ".gitignore"), ".engine/\n*.so\n*.o\n*.a\n");

            info("Scaffolded new project at %s", targetDir);
            return true;
        } catch (Exception e) {
            warn("Failed to scaffold project at %s: %s", targetDir, e.msg);
            return false;
        }
    }
}
