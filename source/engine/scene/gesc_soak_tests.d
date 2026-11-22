/**
 * Soak and robustness tests for GESC (`.gesc`) world chunks.
 *
 * Mirrors `streamer.soak100Cycles9Km2` (JSON chunks) for the binary format and for the mounted asset pak:
 * the same world is generated as JSON, plain GESC (v1) and GESC with binary component blocks (v2), streamed through
 * repeated load/unload cycles, and the resulting world state is compared across formats and across byte sources
 * (disk versus pak). A corruption test checks that damaged chunks fail alone and the streamer keeps going.
 *
 * Default size: 6 x 6 cells of 256 m (2.4 km²), 20 cycles. Set `GESC_SOAK_FULL=1` for the full 12 x 12 (9.4 km²)
 * grid and 100 cycles.
 */
module engine.scene.gesc_soak_tests;

@safe:

version (unittest):

import std.file : exists, mkdirRecurse, read, rmdirRecurse, write;
import std.format : format;
import std.json : parseJSON;

import engine.assets.pak : buildAssetPak, mountAssetPak, PakInput, unmountAssetPak;
import engine.ecs.scene_world : SceneWorld;
import engine.editor.components : Visual;
import engine.math.vec : Vec3;
import engine.scene.chunk_binary : encodeChunk;
import engine.scene.chunk_components : encodeChunkWithComponents;
import engine.scene.graph : Transform;
import engine.scene.scene_file :
    ChunkManifest, SceneCellBounds, SceneChunkDescriptor, SceneComponentData, SceneEntityData, SceneFile,
    loadSceneFile, saveSceneFile;
import engine.scene.streamer : WorldStreamer;

/// Test component cooked into binary blocks by the `binary` chunk flavour.
private struct SoakTag {
    uint tag;
    float weight = 0.5f;
}

private enum Flavour { json, gesc, gescBinary }

private bool fullSoak() @trusted {
    import std.process : environment;
    return environment.get("GESC_SOAK_FULL", "") == "1";
}

private SceneFile makeChunk(int cx, int cz) {
    SceneFile cf;
    cf.schemaVersion = 2;
    cf.meta.name = format("chunk_%d_%d", cx, cz);
    foreach (k; 0 .. 4) {
        SceneEntityData e;
        e.id = cast(uint)(k + 1);
        e.transform.pos = [cx * 256.0f + k * 10.0f, 0.0f, cz * 256.0f];
        e.hasVisual = true;
        e.visual.hasKind = true;
        e.visual.kind = "cube";
        if (k % 2 == 0)
            e.customComponents ~= SceneComponentData("SoakTag", parseJSON(
                format(`{"tag":%d,"weight":0.5}`, cx * 1000 + cz * 10 + k)));
        cf.entities ~= e;
    }
    return cf;
}

private string chunkExt(Flavour f) { return f == Flavour.json ? "scene.json" : "gesc"; }

/// Encode one chunk in the requested flavour. `gescBinary` chunks with an odd `cx + cz` fall back to plain GESC so
/// the grid mixes version 1 and version 2 files.
private ubyte[] encodeFlavour(Flavour f, int cx, int cz) {
    auto cf = makeChunk(cx, cz);
    if (f == Flavour.gescBinary && (cx + cz) % 2 == 0) {
        SceneWorld writer;
        writer.ensureRegistered!SoakTag();
        return encodeChunkWithComponents(cf, writer.types, writer.strings);
    }
    return encodeChunk(cf);
}

private struct World {
    ChunkManifest manifest;
    PakInput[] pakInputs;
    int cells;
}

/// Write an `n x n` grid of chunks into `dir` (and collect pak inputs under `virtual_<flavour>/`).
private World buildWorld(string dir, Flavour f, int n, string pakPrefix) {
    mkdirRecurse(dir);
    World w;
    w.cells = n;
    w.manifest.cellSize = 256.0f;
    w.manifest.loadRadius = 300.0f;
    w.manifest.unloadRadius = 420.0f;
    foreach (cz; 0 .. n)
        foreach (cx; 0 .. n) {
            immutable path = format("%s/chunk_%d_%d.%s", dir, cx, cz, chunkExt(f));
            if (f == Flavour.json) {
                auto cf = makeChunk(cx, cz);
                saveSceneFile(path, cf);
            } else
                write(path, encodeFlavour(f, cx, cz));
            SceneChunkDescriptor desc;
            desc.coordX = cx;
            desc.coordZ = cz;
            desc.bounds = SceneCellBounds([cx * 256.0f, -10.0f, cz * 256.0f],
                [(cx + 1) * 256.0f, 200.0f, (cz + 1) * 256.0f]);
            desc.scenePath = path;
            w.manifest.chunks ~= desc;
            w.pakInputs ~= PakInput(format("%s/chunk_%d_%d.%s", pakPrefix, cx, cz, chunkExt(f)),
                cast(const(ubyte)[]) read(path));
        }
    return w;
}

/// Order-independent summary of the live world; equal worlds give equal digests.
private struct Digest {
    size_t entities;
    long sumX, sumZ;
    ulong tagCount, tagSum;

    bool opEquals(const Digest o) const {
        return entities == o.entities && sumX == o.sumX && sumZ == o.sumZ && tagCount == o.tagCount
            && tagSum == o.tagSum;
    }
}

private Digest digest(ref SceneWorld world) {
    Digest d;
    foreach (i; 0 .. world.capacity()) {
        immutable id = cast(uint) i;
        if (!world.alive(id))
            continue;
        ++d.entities;
        auto t = world.get!Transform(id);
        d.sumX += cast(long) t.position.x;
        d.sumZ += cast(long) t.position.z;
        if (world.has!SoakTag(id)) {
            ++d.tagCount;
            d.tagSum += world.get!SoakTag(id).tag;
        }
    }
    return d;
}

private void prepare(ref SceneWorld world) {
    world.ensureRegistered!Transform();
    world.ensureRegistered!Visual();
    world.ensureRegistered!SoakTag();
}

private struct SoakResult {
    Digest atA, atB;      // world state at the last visit of each corner
    uint totalLoads, totalUnloads;
    size_t peakCapacity, finalCapacity, finalEntities;
    uint finalActive;
}

private Vec3 cornerA() { return Vec3(128.0f, 0.0f, 128.0f); }
private Vec3 cornerB(int n) { return Vec3((n - 1) * 256.0f + 128.0f, 0.0f, (n - 1) * 256.0f + 128.0f); }

/// Alternate between two map corners for `cycles` load/unload cycles. `midHook` runs once, after cycle `hookAt`.
private SoakResult soak(ref ChunkManifest m, int n, int cycles, scope void delegate() @safe midHook = null,
        int hookAt = -1) {
    SceneWorld world;
    prepare(world);
    WorldStreamer streamer;
    streamer.initFromManifest(m);
    assert(streamer.cells.length == cast(size_t) n * n);

    SoakResult r;
    foreach (cycle; 0 .. cycles) {
        immutable atA = cycle % 2 == 0;
        streamer.update(world, atA ? cornerA() : cornerB(n), 50.0f);
        if (world.capacity() > r.peakCapacity)
            r.peakCapacity = world.capacity();
        if (atA) r.atA = digest(world); else r.atB = digest(world);
        if (cycle == hookAt && midHook !is null)
            midHook();
    }
    streamer.update(world, Vec3(-5000.0f, 0.0f, -5000.0f), 50.0f);
    immutable st = streamer.stats();
    r.totalLoads = st.totalLoads;
    r.totalUnloads = st.totalUnloads;
    r.finalActive = st.activeCount;
    r.finalCapacity = world.capacity();
    r.finalEntities = world.entityCount();
    assert(st.activeGltfCount == 0);
    return r;
}

private void checkClean(ref const SoakResult r, int cycles) {
    assert(r.finalActive == 0, "every chunk unloaded");
    assert(r.finalEntities == 0, "no entity leaked");
    assert(r.totalLoads >= cast(uint) cycles);
    assert(r.totalUnloads == r.totalLoads);
    assert(r.finalCapacity <= 64, "EntityId recycling keeps capacity bounded");
    assert(r.peakCapacity <= 64);
}

/// Byte offset of block `i`'s stored data (little-endian u64 at table entry + 8). Flipping a byte there is always
/// covered by the block CRC, unlike header, table and alignment padding bytes.
private size_t blockPayloadOffset(const(ubyte)[] bytes, size_t i) {
    immutable at = 16 + i * 32 + 8;
    ulong off;
    foreach (k; 0 .. 8)
        off |= cast(ulong) bytes[at + k] << (8 * k);
    return cast(size_t) off;
}

private enum soakRoot = "build/test_gesc_soak";

private void cleanup(string dir) @trusted {
    if (exists(dir))
        rmdirRecurse(dir);
}

@("gescSoak.matchesJsonSoak") unittest {
    immutable n = fullSoak() ? 12 : 6;
    immutable cycles = fullSoak() ? 100 : 20;
    scope (exit) cleanup(soakRoot);

    auto json = buildWorld(soakRoot ~ "/json", Flavour.json, n, "v/json");
    auto gesc = buildWorld(soakRoot ~ "/gesc", Flavour.gesc, n, "v/gesc");
    auto bin = buildWorld(soakRoot ~ "/bin", Flavour.gescBinary, n, "v/bin");

    immutable rj = soak(json.manifest, n, cycles);
    checkClean(rj, cycles);
    assert(rj.atA.entities > 0 && rj.atB.entities > 0 && rj.atA.tagCount > 0);

    foreach (i; 0 .. 2) {
        auto manifest = i == 0 ? gesc.manifest : bin.manifest;
        immutable r = soak(manifest, n, cycles);
        checkClean(r, cycles);
        assert(r.totalLoads == rj.totalLoads, "same load schedule");
        assert(r.atA == rj.atA && r.atB == rj.atB, "world state equals the JSON soak");
    }
}

@("gescSoak.pakMatchesDisk") unittest {
    immutable n = fullSoak() ? 12 : 6;
    immutable cycles = fullSoak() ? 100 : 20;
    scope (exit) {
        unmountAssetPak();
        cleanup(soakRoot ~ "_pak");
    }

    foreach (f; [Flavour.gesc, Flavour.gescBinary]) {
        immutable dir = format("%s_pak/%s", soakRoot, f == Flavour.gesc ? "gesc" : "bin");
        auto disk = buildWorld(dir, f, n, "virtual_pak");
        immutable rd = soak(disk.manifest, n, cycles);
        checkClean(rd, cycles);

        // Same chunks, but addressed by virtual paths that exist only inside the mounted pak.
        ChunkManifest pm = disk.manifest;
        pm.chunks = disk.manifest.chunks.dup;
        foreach (i, ref c; pm.chunks)
            c.scenePath = disk.pakInputs[i].path;
        foreach (ref c; pm.chunks)
            assert(!exists(c.scenePath), "virtual path must not resolve on disk");
        assert(mountAssetPak(buildAssetPak(disk.pakInputs, 0xC0FFEE), 0xC0FFEE, false));
        immutable rp = soak(pm, n, cycles);
        checkClean(rp, cycles);
        assert(rp.atA == rd.atA && rp.atB == rd.atB && rp.totalLoads == rd.totalLoads,
            "pak soak equals disk soak");

        // Chunks missing from the pak (no disk fallback) simply fail to load; the world stays empty and sane.
        assert(mountAssetPak(buildAssetPak(disk.pakInputs[0 .. 1], 0xC0FFEE), 0xC0FFEE, false));
        immutable rm = soak(pm, n, cycles);
        assert(rm.finalEntities == 0 && rm.finalActive == 0 && rm.finalCapacity <= 64);
        unmountAssetPak();
    }
}

@("gescSoak.manifestRoundTripThroughRootScene") unittest {
    immutable n = 3;
    scope (exit) cleanup(soakRoot ~ "_root");
    auto w = buildWorld(soakRoot ~ "_root/chunks", Flavour.gescBinary, n, "v");

    // Root scene with a chunk manifest whose scenePath entries point at `.gesc` files, saved and reloaded.
    SceneFile root;
    root.schemaVersion = 2;
    root.meta.name = "root";
    root.hasChunkManifest = true;
    root.chunkManifest = w.manifest;
    immutable rootPath = soakRoot ~ "_root/root.scene.json";
    saveSceneFile(rootPath, root);
    auto loaded = loadSceneFile(rootPath);
    assert(loaded.hasChunkManifest && loaded.chunkManifest.chunks.length == 9);
    foreach (ref c; loaded.chunkManifest.chunks) {
        assert(c.scenePath.length > 5 && c.scenePath[$ - 5 .. $] == ".gesc");
        assert(exists(c.scenePath));
    }

    immutable direct = soak(w.manifest, n, 6);
    immutable viaRoot = soak(loaded.chunkManifest, n, 6);
    checkClean(viaRoot, 6);
    assert(viaRoot.atA == direct.atA && viaRoot.atB == direct.atB);
    assert(viaRoot.atA.entities > 0);
}

@("gescSoak.corruptChunksFailAlone") unittest {
    immutable n = 4;
    immutable cycles = 12;
    scope (exit) cleanup(soakRoot ~ "_bad");

    foreach (mode; 0 .. 4) {
        auto w = buildWorld(format("%s_bad/m%d", soakRoot, mode), Flavour.gescBinary, n, "v");
        immutable clean = soak(w.manifest, n, cycles);
        assert(clean.atA.entities > 0 && clean.atB.entities > 0);

        // After a few cycles, damage every chunk of the 2 x 2 block around corner A on disk.
        void damage() @safe {
            foreach (ref c; w.manifest.chunks) {
                if (c.coordX > 1 || c.coordZ > 1)
                    continue;
                auto bytes = (() @trusted => cast(ubyte[]) read(c.scenePath))();
                final switch (mode) {
                    case 0: bytes = bytes[0 .. bytes.length / 2]; break;             // truncated mid-file
                    case 1: bytes[blockPayloadOffset(bytes, 1)] ^= 0xFF; break;                 // payload bit flip (CRC)
                    case 2: bytes[0 .. 4] = [0, 0, 0, 0]; break;                     // bad magic
                    case 3: bytes = bytes[0 .. 10]; break;                           // truncated inside the header
                }
                write(c.scenePath, bytes);
            }
        }
        immutable bad = soak(w.manifest, n, cycles, &damage, 4);

        assert(bad.finalActive == 0 && bad.finalEntities == 0, "no leak after corrupt chunks");
        assert(bad.totalUnloads == bad.totalLoads);
        assert(bad.finalCapacity <= 64 && bad.peakCapacity <= 64);
        assert(bad.atB == clean.atB, "corner B (undamaged chunks) is unaffected");
        assert(bad.atA.entities == 0, format("mode %d: damaged chunks spawn nothing, got %d (clean %d)", mode, bad.atA.entities, clean.atA.entities));
    }
}
