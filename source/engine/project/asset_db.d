/// AssetDatabase: 128-bit GUID mapping, .meta sidecar persistence, and asset tracking.
module engine.project.asset_db;

import std.file : exists, readText, write, rename, remove, dirEntries, SpanMode, isFile;
import std.path : buildPath, extension, baseName, dirName;
import std.json : JSONValue, parseJSON, JSONType;
import engine.project.asset_ref : AssetGuid;
import engine.core.log : info, warn, err;

@safe:

struct AssetMeta {
    AssetGuid guid;
    string importer = "binary";
    JSONValue settings;
}

struct AssetDatabase {
    AssetGuid[string] pathToGuid;
    string[string] guidToPath; // hex string -> path
    AssetMeta[string] guidToMeta;

    void scanAssets(string rootDir = "assets") @trusted {
        pathToGuid.clear();
        guidToPath.clear();
        guidToMeta.clear();

        if (!exists(rootDir)) return;

        try {
            foreach (entry; dirEntries(rootDir, SpanMode.depth)) {
                if (!entry.isFile) continue;
                string path = entry.name;
                if (path.length >= 5 && path[$ - 5 .. $] == ".meta") continue;

                registerOrImportAsset(path);
            }
        } catch (Exception e) {
            err("AssetDatabase: scan failed: %s", e.msg);
        }

        info("AssetDatabase: scanned %d assets", cast(int) pathToGuid.length);
    }

    AssetGuid getGuid(string path) const {
        if (auto p = path in pathToGuid) return *p;
        return AssetGuid.init;
    }

    string getPath(AssetGuid guid) const {
        string hex = guid.toString();
        if (auto p = hex in guidToPath) return *p;
        return null;
    }

    bool moveAsset(string oldPath, string newPath) @trusted {
        if (!exists(oldPath)) return false;
        string metaOld = oldPath ~ ".meta";
        string metaNew = newPath ~ ".meta";

        try {
            rename(oldPath, newPath);
            if (exists(metaOld)) {
                rename(metaOld, metaNew);
            }
        } catch (Exception e) {
            err("AssetDatabase: failed to move asset from %s to %s: %s", oldPath, newPath, e.msg);
            return false;
        }

        if (auto g = oldPath in pathToGuid) {
            auto guid = *g;
            pathToGuid.remove(oldPath);
            pathToGuid[newPath] = guid;
            guidToPath[guid.toString()] = newPath;
        }

        info("AssetDatabase: moved asset from %s to %s", oldPath, newPath);
        return true;
    }

    bool deleteAsset(string path) @trusted {
        if (!exists(path)) return false;
        string metaPath = path ~ ".meta";

        try {
            remove(path);
            if (exists(metaPath)) remove(metaPath);
        } catch (Exception e) {
            err("AssetDatabase: failed to delete asset %s: %s", path, e.msg);
            return false;
        }

        if (auto g = path in pathToGuid) {
            auto guid = *g;
            pathToGuid.remove(path);
            guidToPath.remove(guid.toString());
            guidToMeta.remove(guid.toString());
        }

        info("AssetDatabase: deleted asset %s", path);
        return true;
    }

    private void registerOrImportAsset(string assetPath) @trusted {
        string metaPath = assetPath ~ ".meta";
        AssetMeta meta;

        if (exists(metaPath)) {
            // Load existing .meta
            try {
                string text = readText(metaPath);
                JSONValue root = parseJSON(text);
                if ("guid" in root && root["guid"].type == JSONType.string) {
                    meta.guid = AssetGuid.fromString(root["guid"].str);
                }
                if ("importer" in root && root["importer"].type == JSONType.string) {
                    meta.importer = root["importer"].str;
                }
                if ("settings" in root) {
                    meta.settings = root["settings"];
                }
            } catch (Exception e) {
                warn("AssetDatabase: corrupt meta for %s, regenerating", assetPath);
                meta.guid = AssetGuid.generate();
                meta.importer = detectImporter(assetPath);
                writeMeta(metaPath, meta);
            }
        } else {
            // Create new .meta sidecar
            meta.guid = AssetGuid.generate();
            meta.importer = detectImporter(assetPath);
            meta.settings = JSONValue(string[string].init);
            writeMeta(metaPath, meta);
        }

        pathToGuid[assetPath] = meta.guid;
        string hex = meta.guid.toString();
        guidToPath[hex] = assetPath;
        guidToMeta[hex] = meta;
    }

    private static void writeMeta(string metaPath, const ref AssetMeta meta) @trusted {
        JSONValue root = JSONValue(string[string].init);
        root["guid"] = JSONValue(meta.guid.toString());
        root["importer"] = JSONValue(meta.importer);
        root["settings"] = meta.settings.type != JSONType.null_ ? meta.settings : JSONValue(string[string].init);
        try {
            write(metaPath, root.toPrettyString());
        } catch (Exception e) {
            err("AssetDatabase: failed to write meta %s: %s", metaPath, e.msg);
        }
    }

    static string detectImporter(string path) pure nothrow {
        if (path.length >= 11 && path[$ - 11 .. $] == ".scene.json") return "scene";
        if (path.length >= 12 && path[$ - 12 .. $] == ".prefab.json") return "prefab";
        if (path.length >= 14 && path[$ - 14 .. $] == ".material.json") return "material";

        string ext = extension(path);
        switch (ext) {
            case ".gltf":
            case ".glb":
                return "gltf";
            case ".png":
            case ".jpg":
            case ".jpeg":
            case ".bmp":
            case ".tga":
                return "image";
            case ".wav":
            case ".ogg":
            case ".mp3":
                return "audio";
            case ".d":
                return "script";
            default:
                return "binary";
        }
    }
}

unittest {
    import std.file : mkdirRecurse, rmdirRecurse, write, exists;
    import std.path : buildPath;

    string testDir = "build/test_assets";
    if (exists(testDir)) rmdirRecurse(testDir);
    mkdirRecurse(testDir);
    scope(exit) {
        if (exists(testDir)) rmdirRecurse(testDir);
    }

    string file1 = buildPath(testDir, "test.png");
    write(file1, "fake png content");

    AssetDatabase db;
    db.scanAssets(testDir);

    auto guid1 = db.getGuid(file1);
    assert(!guid1.isNull());
    assert(db.getPath(guid1) == file1);
    assert(exists(file1 ~ ".meta"));

    // Test moving asset
    string file2 = buildPath(testDir, "moved.png");
    assert(db.moveAsset(file1, file2));
    assert(!exists(file1));
    assert(exists(file2));
    assert(exists(file2 ~ ".meta"));
    assert(db.getGuid(file2) == guid1);
    assert(db.getPath(guid1) == file2);

    // Test deleting asset
    assert(db.deleteAsset(file2));
    assert(!exists(file2));
    assert(!exists(file2 ~ ".meta"));
    assert(db.getGuid(file2).isNull());
}
