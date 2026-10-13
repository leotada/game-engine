/// Game engine project configuration and recent projects tracking.
module engine.project.project;

import std.file : exists, readText, write, mkdirRecurse;
import std.path : buildPath, dirName, expandTilde;
import std.json : JSONValue, parseJSON, JSONType;
import engine.core.log : info, warn, err;

@safe:

struct ProjectConfig {
    string name = "MyGame";
    string engineVersion = "0.1.0";
    string startScene = "assets/scenes/arena_01.scene.json";
    string compiler = "dmd";
}

void saveProject(string projectJsonPath, const ref ProjectConfig cfg) @trusted {
    JSONValue root = JSONValue(string[string].init);
    root["format"] = JSONValue("game-engine.project");
    root["version"] = JSONValue(1);
    root["name"] = JSONValue(cfg.name);
    root["engineVersion"] = JSONValue(cfg.engineVersion);
    root["startScene"] = JSONValue(cfg.startScene);
    root["compiler"] = JSONValue(cfg.compiler);

    auto dir = dirName(projectJsonPath);
    if (!exists(dir)) mkdirRecurse(dir);
    write(projectJsonPath, root.toPrettyString());
    info("Project configuration saved: %s", projectJsonPath);
}

bool loadProject(string projectJsonPath, ref ProjectConfig cfg) @trusted {
    if (!exists(projectJsonPath)) return false;

    try {
        string text = readText(projectJsonPath);
        JSONValue root = parseJSON(text);

        if ("name" in root && root["name"].type == JSONType.string)
            cfg.name = root["name"].str;
        if ("engineVersion" in root && root["engineVersion"].type == JSONType.string)
            cfg.engineVersion = root["engineVersion"].str;
        if ("startScene" in root && root["startScene"].type == JSONType.string)
            cfg.startScene = root["startScene"].str;
        if ("compiler" in root && root["compiler"].type == JSONType.string)
            cfg.compiler = root["compiler"].str;

        info("Loaded project: %s (startScene: %s)", cfg.name, cfg.startScene);
        return true;
    } catch (Exception e) {
        err("Failed to parse project.json: %s", e.msg);
        return false;
    }
}

struct RecentProjectsManager {
    string[] recentPaths;

    private static string configFilePath() @trusted {
        return expandTilde("~/.config/game-engine/projects.json");
    }

    void load() @trusted {
        recentPaths.length = 0;
        string path = configFilePath();
        if (!exists(path)) return;

        try {
            string text = readText(path);
            JSONValue root = parseJSON(text);
            if ("recent" in root && root["recent"].type == JSONType.array) {
                foreach (item; root["recent"].array) {
                    if (item.type == JSONType.string)
                        recentPaths ~= item.str;
                }
            }
        } catch (Exception) {}
    }

    void save() @trusted {
        string path = configFilePath();
        try {
            auto dir = dirName(path);
            if (!exists(dir)) mkdirRecurse(dir);

            JSONValue root = JSONValue(string[string].init);
            JSONValue[] arr;
            foreach (p; recentPaths) arr ~= JSONValue(p);
            root["recent"] = JSONValue(arr);
            write(path, root.toPrettyString());
        } catch (Exception) {}
    }

    void addRecent(string projectPath) {
        // Remove duplicate if exists
        string[] next;
        next ~= projectPath;
        foreach (p; recentPaths) {
            if (p != projectPath) next ~= p;
        }
        if (next.length > 10) next = next[0 .. 10];
        recentPaths = next;
        save();
    }

    void removeRecent(string projectPath) {
        string[] next;
        foreach (p; recentPaths) {
            if (p != projectPath) next ~= p;
        }
        recentPaths = next;
        save();
    }
}
