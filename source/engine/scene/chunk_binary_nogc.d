/// GESC decoding without the GC: the "decode" half of chunk loading, built to run on the streamer's
/// GC-excluded worker thread (`engine.scene.streamer`).
///
/// `readChunkNoGc` validates the container, verifies every block CRC, inflates the zstd blocks and decodes
/// the columns (entities, visual, material, physics, light, asset links, header) into a `GescChunkNoGc`.
/// Everything lives in `malloc` memory owned by that struct (a chain of blocks released together by `release`
/// or the destructor); strings are non-owning views into the inflated blocks, so a decode costs a handful of
/// allocations per chunk and nothing from the GC heap. The struct is move-only (`@disable this(this)`).
///
/// The "apply" half, `applyChunkNoGc`, runs on the main thread: it hands the decoded rows to the existing
/// `applyChunk` as a zero-copy `GescChunk` view, so instancing into the `SceneWorld` is the only work left
/// there. The GC decoder (`decodeChunk`) is untouched and produces an equivalent result; `toGescChunk`
/// converts between the two for tools and tests.
///
/// What stays on the GC side: `customJson` blocks (custom components as JSON text) are validated structurally
/// by the worker but parsed on the main thread at apply time, since `std.json` needs the GC; `*.scene.json`
/// chunks have no GC-free path at all and keep being parsed on the main thread.
module engine.scene.chunk_binary_nogc;

import core.atomic : atomicFetchAdd, atomicFetchSub, atomicLoad, MemoryOrder;
import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, memset;
import std.json : JSONValue, parseJSON;

import engine.assets.zstd : zstdContentSize, zstdDecompress;
import engine.editor.scene_load : SceneLoadOptions, SceneLoadResult, loadSceneAdditive;
import engine.ecs.scene_world : SceneWorld;
import engine.math.vec : Vec3;
import engine.scene.chunk_binary;
import engine.scene.chunk_components : GescApplyResult, applyChunk;
import engine.scene.scene_file;

@safe:

// ---------------------------------------------------------------------------
// Allocation accounting (leak checks in tests and the streamer)
// ---------------------------------------------------------------------------

private shared size_t g_liveAllocs;
private shared size_t g_liveBytes;

/// Number of live `malloc` blocks owned by `GescChunkNoGc` objects (and the heap-allocated objects themselves).
size_t gescNoGcLiveAllocations() nothrow @nogc @trusted {
    return atomicLoad!(MemoryOrder.acq)(g_liveAllocs);
}

/// Bytes held by those blocks.
size_t gescNoGcLiveBytes() nothrow @nogc @trusted {
    return atomicLoad!(MemoryOrder.acq)(g_liveBytes);
}

private struct Node {
    Node* next;
    size_t size;        /// payload bytes
}
static assert(Node.sizeof == 16, "payload must stay 16-byte aligned");

// ---------------------------------------------------------------------------
// The decoded chunk
// ---------------------------------------------------------------------------

/// A chunk decoded without the GC. Slices and string views inside point into the blocks owned by this struct and
/// are valid until `release()` (or destruction). Never store them beyond the chunk's lifetime and never append
/// to them: they are not GC memory.
struct GescChunkNoGc {
    /// Header fields plus `entities` rows; `entities[i].customComponents` is always empty (see `customBlock`).
    SceneFile scene;
    GescUserBlock[] user;
    const(ubyte)[] typesBlock;
    const(ubyte)[][] componentBlocks;
    /// Raw, structurally validated `customJson` payload when it holds entries, else empty.
    const(ubyte)[] customBlock;

    private Node* head_;
    private size_t bytes_;

    @disable this(this);

    ~this() nothrow @nogc @trusted {
        release();
    }

    /// Free every block and reset to the empty state. Safe to call twice.
    void release() nothrow @nogc @trusted {
        auto n = head_;
        size_t blocks = 0;
        while (n !is null) {
            auto next = n.next;
            free(n);
            n = next;
            ++blocks;
        }
        if (blocks) {
            atomicFetchSub!(MemoryOrder.rel)(g_liveAllocs, blocks);
            atomicFetchSub!(MemoryOrder.rel)(g_liveBytes, bytes_);
        }
        head_ = null;
        bytes_ = 0;
        scene = SceneFile.init;
        user = null;
        typesBlock = null;
        componentBlocks = null;
        customBlock = null;
    }

    /// Bytes currently owned.
    size_t memoryBytes() const pure nothrow @nogc {
        return bytes_;
    }

    private void* allocRaw(size_t bytes) nothrow @nogc @trusted {
        if (bytes == 0 || bytes > (size_t.max >> 2))
            return null;
        auto n = cast(Node*) malloc(Node.sizeof + bytes);
        if (n is null)
            return null;
        n.next = head_;
        n.size = bytes;
        head_ = n;
        bytes_ += bytes;
        atomicFetchAdd!(MemoryOrder.rel)(g_liveAllocs, 1);
        atomicFetchAdd!(MemoryOrder.rel)(g_liveBytes, bytes);
        return cast(void*)(n + 1);
    }

    private ubyte[] allocBytes(size_t n) nothrow @nogc @trusted {
        auto p = cast(ubyte*) allocRaw(n);
        return p is null ? null : p[0 .. n];
    }

    /// `n` elements initialised to `T.init`; null when `n == 0` or the allocation fails.
    private T[] allocArray(T)(size_t n) nothrow @nogc @trusted {
        if (n == 0 || n > (size_t.max >> 2) / T.sizeof)
            return null;
        auto p = cast(T*) allocRaw(n * T.sizeof);
        if (p is null)
            return null;
        static if (__traits(isZeroInit, T)) {
            memset(p, 0, n * T.sizeof);
        } else {
            static immutable T init_ = T.init;
            foreach (i; 0 .. n)
                memcpy(p + i, &init_, T.sizeof);
        }
        return p[0 .. n];
    }
}

/// Heap-allocate an empty `GescChunkNoGc` (for owners that must copy handles around, like the streamer's job
/// records). Pair with `gescChunkNoGcFree`. Null on allocation failure.
GescChunkNoGc* gescChunkNoGcNew() nothrow @nogc @trusted {
    auto p = cast(GescChunkNoGc*) malloc(GescChunkNoGc.sizeof);
    if (p is null)
        return null;
    static immutable GescChunkNoGc init_ = GescChunkNoGc.init;
    memcpy(p, &init_, GescChunkNoGc.sizeof);
    atomicFetchAdd!(MemoryOrder.rel)(g_liveAllocs, 1);
    return p;
}

/// Release the chunk's blocks and free the object made by `gescChunkNoGcNew`. Accepts null.
void gescChunkNoGcFree(GescChunkNoGc* p) nothrow @nogc @trusted {
    if (p is null)
        return;
    p.release();
    free(p);
    atomicFetchSub!(MemoryOrder.rel)(g_liveAllocs, 1);
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

/// A length-prefixed string as a view into the reader's buffer (no copy).
private string viewStr(ref Reader r) nothrow @nogc @trusted {
    immutable n = r.u32();
    if (r.bad || n > r.left) {
        r.bad = true;
        return null;
    }
    auto s = cast(string) r.d[r.p .. r.p + n];
    r.p += n;
    return s;
}

/// `getVal` of `engine.scene.chunk_binary` without the GC: strings are views, arrays come from `a`.
private void getValView(T)(ref Reader r, ref T v, ref GescChunkNoGc a) nothrow @nogc @trusted {
    static if (is(T == bool)) {
        v = r.u8() != 0;
    } else static if (is(T == float)) {
        v = r.f32();
    } else static if (is(T == int)) {
        v = cast(int) r.u32();
    } else static if (is(T == uint)) {
        v = r.u32();
    } else static if (is(T == string)) {
        v = viewStr(r);
    } else static if (is(T == E[N], E, size_t N)) {
        foreach (ref e; v)
            getValView(r, e, a);
    } else static if (is(T == E[], E)) {
        immutable n = r.count(1);
        if (n == 0) {
            v = null;
            return;
        }
        auto arr = a.allocArray!E(n);
        if (arr is null) {
            r.bad = true;
            return;
        }
        v = arr;
        foreach (ref e; v) {
            if (r.bad)
                return;
            getValView(r, e, a);
        }
    } else static if (is(T == struct)) {
        static foreach (i; 0 .. T.tupleof.length)
            getValView(r, v.tupleof[i], a);
    } else {
        static assert(false, "unsupported type " ~ T.stringof);
    }
}

private struct Entry {
    GescBlockKind kind;
    GescCodec codec;
    ulong offset;
    uint stored, raw, crc;
}

private bool entryAt(const(ubyte)[] bytes, size_t i, out Entry t, out string err) nothrow @nogc {
    auto r = Reader(bytes, GESC_HEADER_SIZE + i * GESC_TABLE_ENTRY_SIZE);
    t.kind = cast(GescBlockKind) r.u32();
    t.codec = cast(GescCodec) r.u32();
    t.offset = r.u64();
    t.stored = r.u32();
    t.raw = r.u32();
    t.crc = r.u32();
    if (t.offset > bytes.length || t.stored > bytes.length - t.offset || t.raw > GESC_MAX_BLOCK_BYTES) {
        err = "block outside the file";
        return false;
    }
    if (t.codec != GescCodec.raw && t.codec != GescCodec.zstd) {
        err = "unknown codec";
        return false;
    }
    if (t.codec == GescCodec.raw && t.stored != t.raw) {
        err = "raw block size mismatch";
        return false;
    }
    return true;
}

private bool inflateNoGc(const(ubyte)[] bytes, const ref Entry t, ref GescChunkNoGc a, out ubyte[] raw,
        out string err) nothrow @nogc @trusted {
    auto src = bytes[cast(size_t) t.offset .. cast(size_t) t.offset + t.stored];
    if (t.raw != 0) {
        raw = a.allocBytes(t.raw);
        if (raw is null) {
            err = "out of memory";
            return false;
        }
    }
    if (t.codec == GescCodec.raw) {
        if (t.raw != 0)
            memcpy(raw.ptr, src.ptr, t.raw);
    } else {
        if (zstdContentSize(src) != t.raw) {
            err = "block size does not match its frame";
            return false;
        }
        size_t n;
        if (!zstdDecompress(src, raw, n) || n != t.raw) {
            err = "block decompression failed";
            return false;
        }
    }
    if (crc32Of(raw) != t.crc) {
        err = "block CRC mismatch";
        return false;
    }
    return true;
}

/// Decode the per-entity records of one component kind (visual / material / physics / light), in entity order.
private bool readRecords(string field)(const(ubyte)[] raw, SceneEntityData[] ents, ref GescChunkNoGc a)
        nothrow @nogc @trusted {
    enum member = field == "Visual" ? "visual" : field == "Material" ? "material"
        : field == "Physics" ? "physics" : "light";
    if (raw.length == 0) {              // block absent: valid only when no entity has the component
        foreach (ref e; ents)
            if (mixin("e.has" ~ field))
                return false;
        return true;
    }
    auto r = Reader(raw);
    immutable n = r.u32();
    uint seen = 0;
    foreach (ref e; ents)
        if (mixin("e.has" ~ field)) {
            if (seen++ >= n || r.bad)
                return false;
            getValView(r, mixin("e." ~ member), a);
        }
    return !r.bad && seen == n;
}

/// Decode a whole `.gesc` without touching the GC heap. Same acceptance rules and error strings as
/// `decodeChunk`, with one difference: custom-component JSON text is only checked structurally here (a
/// syntax error surfaces when `applyChunkNoGc` parses it). `chunk` is reset first; on failure it is left empty.
bool readChunkNoGc(const(ubyte)[] bytes, ref GescChunkNoGc chunk, out string err) nothrow @nogc @trusted {
    chunk.release();
    if (!readChunkInto(bytes, chunk, err)) {
        chunk.release();
        return false;
    }
    return true;
}

private bool readChunkInto(const(ubyte)[] bytes, ref GescChunkNoGc chunk, out string err) nothrow @nogc @trusted {
    if (bytes.length < GESC_HEADER_SIZE || bytes[0 .. 4] != GESC_MAGIC[]) {
        err = "not a GESC file";
        return false;
    }
    auto hr = Reader(bytes, 4);
    immutable ver = hr.u32();
    immutable n = hr.u32();
    hr.u32();
    if (ver < GESC_VERSION_BASE || ver > GESC_VERSION) {
        err = "unsupported GESC version";
        return false;
    }
    if (n > GESC_MAX_BLOCKS || cast(ulong) n * GESC_TABLE_ENTRY_SIZE > hr.left) {
        err = "bad block count";
        return false;
    }
    size_t nUser = 0, nComp = 0;
    foreach (i; 0 .. n) {
        Entry t;
        if (!entryAt(bytes, i, t, err))
            return false;
        if (t.kind == GescBlockKind.user)
            ++nUser;
        else if (t.kind == GescBlockKind.component)
            ++nComp;
    }
    GescUserBlock[] users;
    const(ubyte)[][] comps;
    if (nUser) {
        users = chunk.allocArray!GescUserBlock(nUser);
        if (users is null) {
            err = "out of memory";
            return false;
        }
    }
    if (nComp) {
        comps = chunk.allocArray!(const(ubyte)[])(nComp);
        if (comps is null) {
            err = "out of memory";
            return false;
        }
    }
    size_t iUser = 0, iComp = 0;
    bool haveHeader = false, haveEntities = false;
    ubyte[] hdr, ent, vis, mat, phy, lig, links, custom;
    foreach (i; 0 .. n) {
        Entry t;
        entryAt(bytes, i, t, err);
        if (t.kind < GescBlockKind.header || t.kind > GescBlockKind.component)
            continue;                       // a newer writer's block kind: skipped
        ubyte[] raw;
        if (!inflateNoGc(bytes, t, chunk, raw, err))
            return false;
        switch (t.kind) {
            case GescBlockKind.header: hdr = raw; haveHeader = true; break;
            case GescBlockKind.entities: ent = raw; haveEntities = true; break;
            case GescBlockKind.visual: vis = raw; break;
            case GescBlockKind.material: mat = raw; break;
            case GescBlockKind.physics: phy = raw; break;
            case GescBlockKind.light: lig = raw; break;
            case GescBlockKind.assetLinks: links = raw; break;
            case GescBlockKind.customJson: custom = raw; break;
            case GescBlockKind.user: {
                auto r = Reader(raw);
                immutable name = viewStr(r);
                if (r.bad) {
                    err = "bad user block";
                    return false;
                }
                users[iUser++] = GescUserBlock(name, raw[r.p .. $]);
                break;
            }
            case GescBlockKind.types: chunk.typesBlock = raw; break;
            case GescBlockKind.component: comps[iComp++] = raw; break;
            default: break;
        }
    }
    chunk.user = users;
    chunk.componentBlocks = comps;
    if (!haveHeader || !haveEntities) {
        err = "missing header or entities block";
        return false;
    }
    SceneFile s;
    {
        auto r = Reader(hdr);
        getValView(r, s.schemaVersion, chunk);
        getValView(r, s.meta, chunk);
        getValView(r, s.settings, chunk);
        getValView(r, s.hasCellBounds, chunk);
        getValView(r, s.cellBounds, chunk);
        getValView(r, s.hasChunkManifest, chunk);
        getValView(r, s.chunkManifest, chunk);
        getValView(r, s.strings, chunk);
        if (r.bad) {
            err = "bad header block";
            return false;
        }
    }
    {
        auto r = Reader(ent);
        immutable nEntities = r.count(4 + 4 + 4 + 1 + 40);
        s.entities = chunk.allocArray!SceneEntityData(nEntities);
        if (nEntities && s.entities is null) {
            err = "out of memory";
            return false;
        }
        foreach (ref e; s.entities)
            e.id = r.u32();
        foreach (ref e; s.entities)
            e.parent = r.u32();
        foreach (ref e; s.entities)
            e.name = cast(int) r.u32();
        foreach (ref e; s.entities) {
            immutable f = r.u8();
            e.hasName = (f & 1) != 0;
            e.hasVisual = (f & 2) != 0;
            e.hasMaterial = (f & 4) != 0;
            e.hasPhysics = (f & 8) != 0;
            e.hasLight = (f & 16) != 0;
        }
        foreach (k; 0 .. 3)
            foreach (ref e; s.entities)
                e.transform.pos[k] = r.f32();
        foreach (k; 0 .. 4)
            foreach (ref e; s.entities)
                e.transform.rot[k] = r.f32();
        foreach (k; 0 .. 3)
            foreach (ref e; s.entities)
                e.transform.scale[k] = r.f32();
        if (r.bad) {
            err = "bad entities block";
            return false;
        }
    }
    if (!readRecords!"Visual"(vis, s.entities, chunk) || !readRecords!"Material"(mat, s.entities, chunk)
            || !readRecords!"Physics"(phy, s.entities, chunk) || !readRecords!"Light"(lig, s.entities, chunk)) {
        err = "bad component record block";
        return false;
    }
    if (links.length) {
        auto r = Reader(links);
        getValView(r, s.assetLinks, chunk);
        if (r.bad) {
            err = "bad asset link block";
            return false;
        }
    }
    if (custom.length) {
        auto r = Reader(custom);
        immutable cn = r.count(12);
        foreach (_; 0 .. cn) {
            immutable idx = r.u32();
            viewStr(r);
            viewStr(r);
            if (r.bad || idx >= s.entities.length) {
                err = "bad custom component block";
                return false;
            }
        }
        if (r.bad) {
            err = "bad custom component block";
            return false;
        }
        if (cn > 0)
            chunk.customBlock = custom;
    }
    chunk.scene = s;
    return true;
}

// ---------------------------------------------------------------------------
// Bridge to the GC world
// ---------------------------------------------------------------------------

/// Parse the (already structurally validated) `customJson` payload into `entities[i].customComponents`.
/// `entities` must be GC memory. Returns false with `err` on malformed JSON.
private bool attachCustomJson(SceneEntityData[] entities, const(ubyte)[] block, out string err) {
    auto r = Reader(block);
    immutable n = r.count(12);
    foreach (_; 0 .. n) {
        immutable idx = r.u32();
        auto type = r.str();
        auto json = r.str();
        if (r.bad || idx >= entities.length) {
            err = "bad custom component block";
            return false;
        }
        try {
            entities[idx].customComponents ~= SceneComponentData(type, parseJSON(json));
        } catch (Exception) {
            err = "bad custom component json";
            return false;
        }
    }
    return !r.bad;
}

private T deepCopy(T)(ref T src) {
    static if (is(T == string)) {
        return src.idup;
    } else static if (is(T == JSONValue)) {
        return src;
    } else static if (is(T == E[N], E, size_t N)) {
        T r;
        foreach (i, ref e; src)
            r[i] = deepCopy(e);
        return r;
    } else static if (is(T == E[], E)) {
        auto r = new E[src.length];
        foreach (i, ref e; src)
            r[i] = deepCopy(e);
        return r;
    } else static if (is(T == struct)) {
        T r;
        static foreach (i; 0 .. T.tupleof.length)
            r.tupleof[i] = deepCopy(src.tupleof[i]);
        return r;
    } else {
        return src;
    }
}

/// Deep, GC-owned copy of `c` (strings duplicated, custom JSON parsed), equivalent to what `decodeChunk` yields
/// for the same bytes. For tools and tests; the streamer applies chunks through `applyChunkNoGc` instead.
bool toGescChunk(ref GescChunkNoGc c, out GescChunk g, out string err) {
    g.scene = deepCopy(c.scene);
    foreach (ref u; c.user)
        g.user ~= GescUserBlock(u.name.idup, u.data.dup);
    g.typesBlock = c.typesBlock.dup;
    foreach (b; c.componentBlocks)
        g.componentBlocks ~= b.dup;
    if (c.customBlock.length)
        return attachCustomJson(g.scene.entities, c.customBlock, err);
    return true;
}

/// Instance a decoded chunk into `world` (the main-thread half of loading). Zero-copy: the rows and strings
/// of `chunk` are lent to `applyChunk` for the duration of the call. When the chunk has custom-component JSON
/// the entity rows are first copied to the GC heap so the parsed components can be attached.
/// Throws on a malformed chunk, like `applyChunk`.
SceneLoadResult applyChunkNoGc(ref SceneWorld world, ref GescChunkNoGc chunk, Vec3 rootOffset,
        SceneLoadOptions opts, out GescApplyResult comps) {
    import std.exception : enforce;
    GescChunk view;
    view.scene = chunk.scene;
    view.user = chunk.user;
    view.typesBlock = chunk.typesBlock;
    view.componentBlocks = chunk.componentBlocks;
    if (chunk.customBlock.length) {
        view.scene.entities = chunk.scene.entities.dup;
        string err;
        enforce(attachCustomJson(view.scene.entities, chunk.customBlock, err), "GESC: " ~ err);
    }
    return applyChunk(world, view, rootOffset, opts, comps);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
    import std.conv : to;
    import engine.ecs.store : EntityId;
    import engine.core.strings : StringId;
    import engine.reflect.attrs : entityRef;
    import engine.scene.chunk_components : applyGescComponents, encodeChunkWithComponents;

    private SceneFile nogcSample(size_t n, bool custom = true) {
        SceneFile s;
        s.schemaVersion = sceneSchemaVersionV2;
        s.meta.name = "chunk_3_-2";
        s.hasCellBounds = true;
        s.cellBounds = SceneCellBounds([768, -1, -512], [1024, 40, -256]);
        s.strings = ["tree", "house", "assets/models/house.glb"];
        s.assetLinks = [SceneAssetLink("0123456789abcdef0123456789abcdef", 2, "model")];
        s.hasChunkManifest = true;
        s.chunkManifest.chunks = [SceneChunkDescriptor(1, 2, SceneCellBounds([0, 0, 0], [1, 1, 1]), "a.gesc", "a.nav")];
        s.settings.hasFog = true;
        foreach (i; 0 .. n) {
            SceneEntityData e;
            e.id = cast(uint)(i + 1);
            e.parent = i > 3 && i % 7 == 0 ? cast(uint) i : sceneNoParent;
            e.hasName = true;
            e.name = cast(int)(i % 2);
            e.transform.pos = [cast(float) i * 1.5f, cast(float)(i % 13), -cast(float) i * 0.25f];
            e.transform.rot = [0, 0.7071f, 0, 0.7071f];
            e.transform.scale = [1, 1 + (i % 3) * 0.1f, 1];
            if (i % 5 == 0) {
                e.hasVisual = true;
                e.visual.hasAsset = true;
                e.visual.asset = 2;
                e.visual.hasAssetGuid = true;
                e.visual.assetGuid = "0123456789abcdef0123456789abcdef";
                e.visual.hasKind = true;
                e.visual.kind = "mesh";
            }
            if (i % 9 == 0) {
                e.hasMaterial = true;
                e.material.baseColor = [0.2f, 0.4f, 0.6f];
                e.material.flags = 3;
            }
            if (i % 4 == 0) {
                e.hasPhysics = true;
                e.physics.motion = "static";
                e.physics.shape = "primitive";
            }
            if (i % 11 == 0) {
                e.hasLight = true;
                e.light.type = "point";
                e.light.range = 30;
            }
            if (custom && i % 2 == 0)
                e.customComponents ~= SceneComponentData("viatura.tree",
                    parseJSON(`{"species":"mangueira","variant":` ~ (i % 3 == 0 ? "1" : "2") ~ `,"scale":1.25}`));
            s.entities ~= e;
        }
        return s;
    }

    private struct NgDoor {
        float angle = 0.5f;
        uint kind = 1;
        StringId label;
        @entityRef uint target = EntityId.max;
        Vec3 pos;
    }

    /// Sample files: columns only, columns + user blocks, and v2 with binary component blocks.
    private ubyte[][string] nogcFiles() {
        ubyte[][string] f;
        auto s1 = nogcSample(300, false), s2 = nogcSample(300), s3 = nogcSample(80), s4 = SceneFile.init;
        f["columns"] = encodeChunk(s1);
        f["columnsJson"] = encodeChunk(s2);
        f["empty"] = encodeChunk(s4);
        f["user"] = encodeChunk(s3, [GescUserBlock("viatura.plants", [1, 2, 3, 4, 5, 6, 7, 8]),
                GescUserBlock("empty", []), GescUserBlock("big", new ubyte[5000])]);
        SceneWorld writer;
        writer.ensureRegistered!NgDoor();
        auto scene = nogcSample(60, false);
        foreach (i, ref e; scene.entities)
            if (i % 2 == 0)
                e.customComponents ~= SceneComponentData("NgDoor", parseJSON(
                    `{"angle":0.25,"kind":` ~ (i % 3 == 0 ? "7" : "2") ~ `,"label":"door_a","target":` ~ (i + 2).to!string
                    ~ `,"pos":[1,2,3]}`));
        f["binary"] = encodeChunkWithComponents(scene, writer.types, writer.strings,
                [GescUserBlock("viatura.plants", [9, 9, 9])]);
        return f;
    }

    private void assertSameChunk(ref const GescChunk a, ref const GescChunk b, string what) {
        assert(a.scene == b.scene, what ~ ": scene differs");
        assert(a.user.length == b.user.length, what ~ ": user count");
        foreach (i; 0 .. a.user.length)
            assert(a.user[i].name == b.user[i].name && a.user[i].data == b.user[i].data, what ~ ": user block");
        assert(a.typesBlock == b.typesBlock, what ~ ": types block");
        assert(a.componentBlocks == b.componentBlocks, what ~ ": component blocks");
    }
}

@("chunkNoGc.equivalentToGcDecoder") unittest {
    foreach (name, bytes; nogcFiles()) {
        GescChunk gc;
        string err;
        assert(decodeChunk(bytes, gc, err), name ~ ": " ~ err);
        GescChunkNoGc ng;
        assert(readChunkNoGc(bytes, ng, err), name ~ ": " ~ err);
        GescChunk back;
        assert(toGescChunk(ng, back, err), err);
        assertSameChunk(gc, back, name);
        // the zero-copy rows are the GC decoder's rows (custom JSON aside)
        assert(ng.scene.entities.length == gc.scene.entities.length);
        assert(ng.scene.strings == gc.scene.strings);
    }
    // the binary sample really carries v2 blocks, and the user sample real user blocks
    auto files = nogcFiles();
    GescChunkNoGc ng;
    string err;
    assert(readChunkNoGc(files["binary"], ng, err), err);
    assert(ng.componentBlocks.length == 1 && ng.typesBlock.length > 0 && ng.user.length == 1);
    assert(readChunkNoGc(files["user"], ng, err), err);
    assert(ng.user.length == 3 && ng.user[0].name == "viatura.plants" && ng.user[2].data.length == 5000);
}

@("chunkNoGc.applyMatchesGcApply") unittest {
    import engine.editor.components : Visual;
    import engine.scene.graph : Transform;
    auto files = nogcFiles();
    foreach (name; ["columnsJson", "binary"]) {
        auto bytes = files[name];
        SceneWorld w1, w2;
        foreach (w; [&w1, &w2]) {
            w.ensureRegistered!Transform();
            w.ensureRegistered!Visual();
            w.ensureRegistered!NgDoor();
        }
        GescChunk gc;
        string err;
        assert(decodeChunk(bytes, gc, err), err);
        GescApplyResult c1, c2;
        SceneLoadOptions opts;
        opts.validate = false;
        opts.checkAssetFiles = false;
        auto r1 = applyChunk(w1, gc, Vec3(0, 0, 0), opts, c1);
        GescChunkNoGc ng;
        assert(readChunkNoGc(bytes, ng, err), err);
        auto r2 = applyChunkNoGc(w2, ng, Vec3(0, 0, 0), opts, c2);
        assert(w1.entityCount() == w2.entityCount() && r1.spawnedEntities.length == r2.spawnedEntities.length, name);
        assert(c1.blocksApplied == c2.blocksApplied && c1.componentsApplied == c2.componentsApplied, name);
        assert(c1.unresolvedTypes == c2.unresolvedTypes, name);
        assert(r1.unresolvedComponents.length == r2.unresolvedComponents.length, name);
        foreach (i, id; r1.spawnedEntities) {
            assert(w1.get!Transform(id) == w2.get!Transform(r2.spawnedEntities[i]), name ~ ": transform");
            assert(w1.has!Visual(id) == w2.has!Visual(r2.spawnedEntities[i]), name ~ ": visual");
        }
        if (name == "binary")
            assert(c2.componentsApplied > 0);
    }
}

@("chunkNoGc.noGcAllocationDuringDecode") unittest {
    import core.memory : GC;
    auto files = nogcFiles();
    GescChunkNoGc ng;
    string err;
    foreach (name, bytes; files)          // warm up (zstd tables, etc.)
        assert(readChunkNoGc(bytes, ng, err), err);
    ng.release();
    immutable liveBefore0 = gescNoGcLiveAllocations();
    immutable before = GC.stats().usedSize;
    foreach (_; 0 .. 8)
        foreach (name, bytes; files) {
            assert(readChunkNoGc(bytes, ng, err));
            assert(ng.scene.entities.length > 0 || name == "empty");
        }
    assert(GC.stats().usedSize == before, "readChunkNoGc touched the GC heap");
    ng.release();
    assert(gescNoGcLiveAllocations() == liveBefore0, "release frees every block");
}

@("chunkNoGc.corruptionAndTruncation") unittest {
    import core.memory : GC;
    import std.random : Random, uniform;
    auto files = nogcFiles();
    immutable liveBefore = gescNoGcLiveAllocations();
    immutable bytesBefore = gescNoGcLiveBytes();
    GescChunkNoGc ng;
    GescChunk gc;
    string err, gerr;
    immutable gcBefore = GC.stats().usedSize;
    foreach (name, good; files) {
        foreach (n; 0 .. good.length - 16) {
            if (n % 5 != 0)
                continue;
            assert(!readChunkNoGc(good[0 .. n], ng, err), name ~ ": truncation accepted");
            assert(ng.scene.entities.length == 0 && ng.memoryBytes == 0, "a failed read leaves the chunk empty");
        }
        auto bad = good.dup;
        bad[0] = 'X';
        assert(!readChunkNoGc(bad, ng, err) && err == "not a GESC file");
        bad = good.dup;
        bad[4] = 9;
        assert(!readChunkNoGc(bad, ng, err) && err == "unsupported GESC version");
        // random flips: never a crash, never a leak, and the two decoders agree on accept / reject
        auto rng = Random(11);
        foreach (_; 0 .. 400) {
            bad = good.dup;
            bad[uniform(0, cast(uint) bad.length, rng)] ^= cast(ubyte)(1 + uniform(0, 255, rng));
            immutable okNg = readChunkNoGc(bad, ng, err);
            immutable okGc = decodeChunk(bad, gc, gerr);
            if (okNg && !okGc)
                assert(gerr == "bad custom component json", name ~ ": nogc accepted what the GC decoder refused: " ~ gerr);
            if (!okNg && !okGc)
                assert(err == gerr, name ~ ": " ~ err ~ " vs " ~ gerr);
        }
    }
    ng.release();
    assert(gescNoGcLiveAllocations() == liveBefore && gescNoGcLiveBytes() == bytesBefore, "corrupt reads leak nothing");
    // an all-zero or tiny buffer
    assert(!readChunkNoGc(null, ng, err) && !readChunkNoGc(new ubyte[64], ng, err));
}

@("chunkNoGc.ownershipAndHeapHandle") unittest {
    immutable liveBefore = gescNoGcLiveAllocations();
    auto files = nogcFiles();
    auto p = gescChunkNoGcNew();
    assert(p !is null && gescNoGcLiveAllocations() == liveBefore + 1);
    string err;
    assert(readChunkNoGc(files["binary"], *p, err), err);
    assert(gescNoGcLiveAllocations() > liveBefore + 1 && p.memoryBytes > 0);
    // re-reading into the same object releases the previous contents first
    immutable blocks = gescNoGcLiveAllocations();
    assert(readChunkNoGc(files["binary"], *p, err), err);
    assert(gescNoGcLiveAllocations() == blocks);
    gescChunkNoGcFree(p);
    assert(gescNoGcLiveAllocations() == liveBefore);
    gescChunkNoGcFree(null);
    {
        GescChunkNoGc scoped;
        assert(readChunkNoGc(files["user"], scoped, err), err);
    }
    assert(gescNoGcLiveAllocations() == liveBefore, "the destructor releases the blocks");
}

/// Benchmark, enabled by `GESC_BENCH_DIR=<dir with .gesc chunks>`: main-thread cost per chunk before (GC decode +
/// apply) and after (apply only; the decode moved to the worker), plus the worker-side decode time.
@("chunkNoGc.benchmarkDirectory") unittest {
    import core.time : MonoTime;
    import std.file : dirEntries, read, SpanMode;
    import std.process : environment;
    import std.stdio : writefln;
    import engine.editor.components : Visual;
    import engine.scene.graph : Transform;
    immutable dir = environment.get("GESC_BENCH_DIR", "");
    if (dir.length == 0)
        return;
    ubyte[][] files;
    foreach (e; dirEntries(dir, "*.gesc", SpanMode.shallow))
        files ~= () @trusted { return cast(ubyte[]) read(e.name); }();
    SceneLoadOptions opts;
    opts.validate = false;
    opts.checkAssetFiles = false;
    long oldMain, newWorker, newMain, customParse, loadOnly;
    size_t withCustom;
    size_t ents;
    enum reps = 5;
    foreach (rep; 0 .. reps)
        foreach (bytes; files) {
            SceneWorld w1, w2;
            foreach (w; [&w1, &w2]) {
                w.ensureRegistered!Transform();
                w.ensureRegistered!Visual();
            }
            GescApplyResult c;
            auto t0 = MonoTime.currTime();
            auto gc = parseChunkBytes(bytes);
            auto r1 = applyChunk(w1, gc, Vec3(0, 0, 0), opts, c);
            oldMain += (MonoTime.currTime() - t0).total!"usecs";
            GescChunkNoGc ng;
            string err;
            t0 = MonoTime.currTime();
            assert(readChunkNoGc(bytes, ng, err), err);
            newWorker += (MonoTime.currTime() - t0).total!"usecs";
            t0 = MonoTime.currTime();
            auto r2 = applyChunkNoGc(w2, ng, Vec3(0, 0, 0), opts, c);
            newMain += (MonoTime.currTime() - t0).total!"usecs";
            assert(r1.spawnedEntities.length == r2.spawnedEntities.length);
            if (ng.customBlock.length) {
                ++withCustom;
                t0 = MonoTime.currTime();
                auto dup = ng.scene.entities.dup;
                attachCustomJson(dup, ng.customBlock, err);
                customParse += (MonoTime.currTime() - t0).total!"usecs";
            }
            {
                SceneWorld w3;
                w3.ensureRegistered!Transform();
                w3.ensureRegistered!Visual();
                t0 = MonoTime.currTime();
                auto sf = ng.scene;
                loadSceneAdditive(w3, sf, Vec3(0, 0, 0), opts);
                loadOnly += (MonoTime.currTime() - t0).total!"usecs";
            }
            if (rep == 0)
                ents += r1.spawnedEntities.length;
        }
    immutable n = files.length * reps;
    writefln("GESC bench: %s chunks, %s entities; per chunk: main before %.1f us (decode+apply), "
            ~ "main after %.1f us (apply), worker decode %.1f us; "
            ~ "%s/%s chunks have custom JSON (parse %.1f us/chunk avg), loadSceneAdditive alone %.1f us", files.length, ents,
            cast(double) oldMain / n, cast(double) newMain / n, cast(double) newWorker / n, withCustom, n,
            cast(double) customParse / n, cast(double) loadOnly / n);
}
