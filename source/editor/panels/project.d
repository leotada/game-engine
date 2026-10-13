/// Project & Asset Browser panel: folder tree, file grid/list, asset search, and template creation.
module editor.panels.project;

import std.file : exists, isDir, isFile, dirEntries, SpanMode, write, mkdirRecurse;
import std.path : buildPath, baseName, dirName, extension;
import engine.project.asset_db : AssetDatabase;
import engine.ui;
import engine.core.log : info, warn;

@safe:

/// Index of the character just past the `assets` path segment, if any.
private bool assetsRootEnd(scope const(char)[] path, out size_t end) pure nothrow {
    size_t i = 0;
    while (i < path.length) {
        immutable size_t segStart = i;
        while (i < path.length && path[i] != '/')
            i++;
        if (i - segStart == 6 && path[segStart .. i] == "assets") {
            end = i;
            return true;
        }
        if (i < path.length && path[i] == '/')
            i++;
    }
    return false;
}

private bool isUnderAssets(scope const(char)[] path) pure nothrow {
    size_t end;
    return assetsRootEnd(path, end);
}

private bool isAssetsRootPath(scope const(char)[] path) pure nothrow {
    size_t end;
    if (!assetsRootEnd(path, end))
        return false;
    if (path.length == end)
        return true;
    return path.length == end + 1 && path[end] == '/';
}

/// `..` after the assets segment would leave the assets tree.
private bool escapesAssets(scope const(char)[] path, size_t rootEnd) pure nothrow {
    size_t i = rootEnd;
    if (i < path.length && path[i] == '/')
        i++;
    while (i < path.length) {
        immutable size_t segStart = i;
        while (i < path.length && path[i] != '/')
            i++;
        if (i - segStart == 2 && path[segStart .. i] == "..")
            return true;
        if (i < path.length && path[i] == '/')
            i++;
    }
    return false;
}

struct ProjectFileItem {
    string name;
    string fullPath;
    bool isDir;
}

struct ProjectPanel {
    string currentDir = "assets";
    string searchQuery = "";
    string selectedItem = "";
    ProjectFileItem[] cachedItems;
    bool dirty = true;

    void refresh() @trusted {
        cachedItems.length = 0;
        if (exists(currentDir) && isDir(currentDir)) {
            try {
                foreach (entry; dirEntries(currentDir, SpanMode.shallow)) {
                    string fname = baseName(entry.name);
                    if (fname.length >= 5 && fname[$ - 5 .. $] == ".meta") continue;
                    cachedItems ~= ProjectFileItem(fname, entry.name, entry.isDir);
                }
            } catch (Exception) {}
        }
        dirty = false;
    }

    void buildUi(
        ref AssetDatabase assetDb,
        ref UiTree ui,
        UiNodeId parent,
        ref const UiTheme theme,
        void delegate(string action, string path) @safe onAction = null
    ) @trusted {
        if (!isUnderAssets(currentDir)) {
            currentDir = "assets";
            dirty = true;
        }
        if (dirty) refresh();

        // Toolbar: assets path only. No script or material creation.
        UiStyle barStyle;
        barStyle.direction = UiFlexDirection.row;
        barStyle.widthMode = UiSizeMode.fill;
        barStyle.height = 28.0f;
        barStyle.heightMode = UiSizeMode.fixed;
        barStyle.backgroundColor = theme.colors.bgSurface;
        barStyle.alignItems = UiAlign.center;
        barStyle.padding = [2.0f, 6.0f, 2.0f, 6.0f];
        barStyle.gap = 6.0f;

        UiNodeId bar = ui.createNode(parent, barStyle);

        label(ui, bar, currentDir, theme.colors.textDim);

        UiNodeId assetsBtn = button(ui, bar, "Assets", theme);
        ui.get(assetsBtn).customTag = 0xBB20;
        ui.get(assetsBtn).style.backgroundColor = theme.colors.accent;

        if (isUnderAssets(currentDir) && !isAssetsRootPath(currentDir)) {
            UiNodeId upBtn = button(ui, bar, "Voltar", theme);
            ui.get(upBtn).customTag = 0xBB22;
        }

        UiNodeId refBtn = button(ui, bar, "Refresh", theme);
        ui.get(refBtn).customTag = 0xBB01;

        // Content split: left folders, right files
        UiStyle splitStyle;
        splitStyle.direction = UiFlexDirection.row;
        splitStyle.widthMode = UiSizeMode.fill;
        splitStyle.flexGrow = 1.0f;

        UiNodeId split = ui.createNode(parent, splitStyle);

        // Right pane: Files in currentDir
        UiNodeId fileList = scrollView(ui, split, theme);

        foreach (idx, ref item; cachedItems) {
            UiStyle rowStyle;
            rowStyle.direction = UiFlexDirection.row;
            rowStyle.widthMode = UiSizeMode.fill;
            rowStyle.height = 22.0f;
            rowStyle.heightMode = UiSizeMode.fixed;
            rowStyle.padding = [2.0f, 6.0f, 2.0f, 6.0f];
            rowStyle.alignItems = UiAlign.center;
            rowStyle.cursor = UiCursor.pointer;
            rowStyle.backgroundColor = (selectedItem == item.fullPath) ? theme.colors.bgActive : theme.colors.bgBase;

            UiNodeId row = ui.createNode(fileList, rowStyle);
            // Index tag. The editor opens a row when its path ends in .scene.json.
            ui.get(row).customTag = 0xB200_0000 | cast(uint) idx;

            char[96] nameBuf;
            size_t n = 0;
            if (item.isDir && n < nameBuf.length) nameBuf[n++] = '/';
            foreach (c; item.name) {
                if (n >= nameBuf.length) break;
                nameBuf[n++] = c;
            }
            label(ui, row, nameBuf[0 .. n], theme.colors.text);
        }
    }

    /// Next free path `dir/stem.ext`, then `dir/stem1.ext`, and so on.
    private string uniqueFile(string dir, string stem, string ext) @trusted {
        import core.stdc.stdio : snprintf;
        if (!exists(dir)) mkdirRecurse(dir);
        foreach (i; 0 .. 1000) {
            string name = stem;
            if (i > 0) {
                char[8] num = void;
                int wrote = snprintf(num.ptr, num.length, "%d", i);
                if (wrote <= 0 || wrote >= num.length) continue;
                name = stem ~ num[0 .. wrote].idup;
            }
            string path = buildPath(dir, name ~ ext);
            if (!exists(path)) return path;
        }
        return "";
    }

    /// Creates a new D script component template in `scripts/` and shows that folder.
    string createScriptTemplate() @trusted {
        try {
            string path = uniqueFile("scripts", "NewScript", ".d");
            if (path.length == 0) {
                warn("Não foi possível criar o script");
                return "";
            }
            string scriptName = baseName(path, ".d");
            string code =
                "module scripts." ~ scriptName ~ ";\n\n" ~
                "import engine.script;\n\n" ~
                "@component struct " ~ scriptName ~ " {\n" ~
                "    @export_ float speed = 10.0f;\n\n" ~
                "    void onStart(scope ref ScriptContext ctx) {\n" ~
                "    }\n\n" ~
                "    void onUpdate(scope ref ScriptContext ctx, float dt) {\n" ~
                "    }\n" ~
                "}\n";

            write(path, code);
            currentDir = "scripts";
            selectedItem = path;
            dirty = true;
            info("Script criado: ", path);
            return path;
        } catch (Exception e) {
            warn("Falha ao criar script: ", e.msg);
            return "";
        }
    }

    /// Creates `assets/materials/NewMaterial.material.json` and shows that folder.
    string createMaterialTemplate() @trusted {
        try {
            string path = uniqueFile("assets/materials", "NewMaterial", ".material.json");
            if (path.length == 0) {
                warn("Não foi possível criar o material");
                return "";
            }
            string json =
                "{\n" ~
                "  \"baseColor\": [1, 1, 1, 1],\n" ~
                "  \"metallic\": 0,\n" ~
                "  \"roughness\": 0.5,\n" ~
                "  \"flags\": 0\n" ~
                "}\n";
            write(path, json);
            currentDir = "assets/materials";
            selectedItem = path;
            dirty = true;
            info("Material criado: ", path);
            return path;
        } catch (Exception e) {
            warn("Falha ao criar material: ", e.msg);
            return "";
        }
    }

    void goUp() {
        size_t rootEnd;
        if (!assetsRootEnd(currentDir, rootEnd) || escapesAssets(currentDir, rootEnd)) {
            currentDir = "assets";
            dirty = true;
            return;
        }
        if (isAssetsRootPath(currentDir))
            return;

        string parent = dirName(currentDir);
        size_t parentRoot;
        if (parent.length == 0 || parent == "."
            || !assetsRootEnd(parent, parentRoot)
            || escapesAssets(parent, parentRoot)) {
            currentDir = currentDir[0 .. rootEnd];
        } else {
            currentDir = parent;
        }
        dirty = true;
    }
}

unittest {
    ProjectPanel panel;

    panel.currentDir = "assets";
    panel.goUp();
    assert(panel.currentDir == "assets");

    panel.currentDir = "assets/models";
    panel.goUp();
    assert(panel.currentDir == "assets");

    panel.currentDir = "assets/models/nested";
    panel.goUp();
    assert(panel.currentDir == "assets/models");
    panel.goUp();
    assert(panel.currentDir == "assets");

    panel.currentDir = "/tmp/proj/assets/scenes";
    panel.goUp();
    assert(panel.currentDir == "/tmp/proj/assets");
    panel.goUp();
    assert(panel.currentDir == "/tmp/proj/assets");

    panel.currentDir = "assets/../secrets";
    panel.goUp();
    assert(panel.currentDir == "assets");

    panel.currentDir = "scripts";
    panel.goUp();
    assert(panel.currentDir == "assets");
}
