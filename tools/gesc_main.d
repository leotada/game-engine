/// `game-engine-gesc`: convert, inspect, verify and split scene chunks (GESC, see `engine.scene.chunk_binary`).
///
///   game-engine-gesc encode <in.scene.json> <out.gesc> [--level=6]
///   game-engine-gesc decode <in.gesc> <out.scene.json>
///   game-engine-gesc info   <file.gesc>
///   game-engine-gesc verify <file.gesc> [more.gesc ...]
///   game-engine-gesc split  <in.scene.json> <outDir> [--cell-size=256] [--level=6] [--json]
///   game-engine-gesc bench  <in.scene.json>
module gesc_main;

import std.algorithm : sort;
import std.conv : to;
import std.datetime.stopwatch : StopWatch;
import std.file : mkdirRecurse, read, readText, write;
import std.format : format;
import std.math : floor;
import std.path : buildPath;
import std.stdio : stderr, writefln, writeln;
import std.string : startsWith;

import engine.scene.chunk_binary;
import engine.scene.scene_file;

int main(string[] args) {
    int level = 6;
    float cellSize = 256.0f;
    bool asJson = false;
    string[] pos;
    foreach (a; args[1 .. $]) {
        if (a.startsWith("--level="))
            level = a[8 .. $].to!int;
        else if (a.startsWith("--cell-size="))
            cellSize = a[12 .. $].to!float;
        else if (a == "--json")
            asJson = true;
        else
            pos ~= a;
    }
    if (pos.length == 0) {
        stderr.writeln("usage: game-engine-gesc encode|decode|info|verify|split|bench ... (see tools/gesc_main.d)");
        return 2;
    }
    try {
        switch (pos[0]) {
            case "encode":
                auto s = loadSceneFile(pos[1]);
                write(pos[2], encodeChunk(s, null, level));
                writefln("%s -> %s", pos[1], pos[2]);
                return 0;
            case "decode":
                GescChunk c;
                string err;
                if (!decodeChunk(cast(const(ubyte)[]) read(pos[1]), c, err)) {
                    stderr.writefln("%s: %s", pos[1], err);
                    return 1;
                }
                saveSceneFile(pos[2], c.scene);
                return 0;
            case "info":
                return info(pos[1]);
            case "verify":
                int bad = 0;
                foreach (p; pos[1 .. $]) {
                    GescChunk c;
                    string err;
                    if (!decodeChunk(cast(const(ubyte)[]) read(p), c, err)) {
                        stderr.writefln("FAIL %s: %s", p, err);
                        ++bad;
                    } else
                        writefln("ok   %s (%s entities)", p, c.scene.entities.length);
                }
                return bad ? 1 : 0;
            case "split":
                return split(pos[1], pos[2], cellSize, level, asJson);
            case "bench":
                return bench(pos[1], level);
            default:
                stderr.writefln("unknown command '%s'", pos[0]);
                return 2;
        }
    } catch (Exception e) {
        stderr.writeln("error: ", e.msg);
        return 1;
    }
}

int info(string path) {
    const bytes = cast(const(ubyte)[]) read(path);
    GescBlockInfo[] bi;
    string err;
    if (!gescInfo(bytes, bi, err)) {
        stderr.writefln("%s: %s", path, err);
        return 1;
    }
    writefln("%s: %s bytes, %s blocks", path, bytes.length, bi.length);
    foreach (b; bi)
        writefln("  %-10s %-4s stored %9s raw %9s %s", b.kind, b.codec, b.storedSize, b.rawSize, b.userName);
    return 0;
}

/// Split a scene into one chunk per `cellSize` cell (by the XZ origin of each root entity; children follow
/// their parent) plus a root v2 scene with the chunk manifest. Entity ids are renumbered per chunk.
int split(string inPath, string outDir, float cellSize, int level, bool asJson) {
    auto src = loadSceneFile(inPath);
    mkdirRecurse(outDir);
    uint[uint] indexOf;                         // file id -> entity index
    foreach (i, ref e; src.entities)
        indexOf[e.id] = cast(uint) i;
    long[2][] cellOf = new long[2][src.entities.length];
    bool[] done = new bool[src.entities.length];
    long[2] resolve(uint i) {
        if (done[i])
            return cellOf[i];
        auto e = &src.entities[i];
        if (e.parent != sceneNoParent && e.parent in indexOf)
            cellOf[i] = resolve(indexOf[e.parent]);
        else
            cellOf[i] = [cast(long) floor(e.transform.pos[0] / cellSize), cast(long) floor(e.transform.pos[2] / cellSize)];
        done[i] = true;
        return cellOf[i];
    }
    uint[][long[2]] groups;
    foreach (i; 0 .. src.entities.length)
        groups[resolve(cast(uint) i)] ~= cast(uint) i;

    ChunkManifest manifest;
    manifest.cellSize = cellSize;
    manifest.loadRadius = 1.5f * cellSize;
    manifest.unloadRadius = 2.0f * cellSize;
    auto keys = groups.keys;
    keys.sort!((a, b) => a[0] != b[0] ? a[0] < b[0] : a[1] < b[1]);
    ulong totalBytes = 0;
    foreach (k; keys) {
        SceneFile c;
        c.schemaVersion = sceneSchemaVersionV2;
        c.meta.name = format("chunk_%s_%s", k[0], k[1]);
        c.hasCellBounds = true;
        // Per-chunk string table: only the strings this chunk's entities and links refer to.
        int[int] strMap;
        int intern(int old) {
            if (old < 0 || old >= cast(int) src.strings.length)
                return sceneNoString;
            if (auto p = old in strMap)
                return *p;
            strMap[old] = cast(int) c.strings.length;
            c.strings ~= src.strings[old];
            return strMap[old];
        }
        foreach (l; src.assetLinks) {
            l.path = intern(l.path);
            c.assetLinks ~= l;
        }
        float lo = float.max, hi = -float.max;
        uint[uint] remap;
        foreach (i; groups[k]) {
            SceneEntityData e = src.entities[i];
            if (e.hasName)
                e.name = intern(e.name);
            if (e.hasVisual && e.visual.hasAsset)
                e.visual.asset = intern(e.visual.asset);
            remap[e.id] = cast(uint) remap.length + 1;
            c.entities ~= e;
        }
        foreach (ref e; c.entities) {
            auto old = e.id;
            e.id = remap[old];
            if (e.parent != sceneNoParent)
                e.parent = remap.get(e.parent, sceneNoParent);
            lo = lo < e.transform.pos[1] ? lo : e.transform.pos[1];
            hi = hi > e.transform.pos[1] ? hi : e.transform.pos[1];
        }
        c.cellBounds = SceneCellBounds([k[0] * cellSize, lo - 1, k[1] * cellSize], [(k[0] + 1) * cellSize, hi + 1, (k[1] + 1) * cellSize]);
        immutable ext = asJson ? "scene.json" : "gesc";
        immutable path = buildPath(outDir, format("chunk_%s_%s.%s", k[0], k[1], ext));
        if (asJson)
            saveSceneFile(path, c);
        else {
            auto bytes = encodeChunk(c, null, level);
            write(path, bytes);
            totalBytes += bytes.length;
        }
        SceneChunkDescriptor d;
        d.coordX = cast(int) k[0];
        d.coordZ = cast(int) k[1];
        d.bounds = c.cellBounds;
        d.scenePath = path;
        manifest.chunks ~= d;
    }
    SceneFile root;
    root.schemaVersion = sceneSchemaVersionV2;
    root.meta = src.meta;
    root.settings = src.settings;
    root.hasChunkManifest = true;
    root.chunkManifest = manifest;
    saveSceneFile(buildPath(outDir, "world.scene.json"), root);
    writefln("%s entities -> %s chunks (%s bytes total)", src.entities.length, keys.length, totalBytes);
    return 0;
}

int bench(string inPath, int level) {
    immutable text = readText(inPath);
    StopWatch sw;
    sw.start();
    auto s = parseSceneJson(text);
    immutable tJson = sw.peek.total!"msecs";
    sw.reset();
    auto bin = encodeChunk(s, null, level);
    immutable tEnc = sw.peek.total!"msecs";
    sw.reset();
    GescChunk c;
    string err;
    immutable ok = decodeChunk(bin, c, err);
    immutable tDec = sw.peek.total!"msecs";
    writefln("JSON  %9s bytes  parse  %5s ms", text.length, tJson);
    writefln("GESC  %9s bytes  encode %5s ms  decode %5s ms  (%s)", bin.length, tEnc, tDec, ok ? "ok" : err);
    return ok ? 0 : 1;
}
