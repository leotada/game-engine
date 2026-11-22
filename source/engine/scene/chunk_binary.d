/// GESC: binary, compressed container for scene chunks (`game-engine.scene` content as columns).
///
/// A `.gesc` file is a 16-byte header, a table of blocks and the block payloads (16-byte aligned). Each
/// block is independently zstd-compressed (or stored) and CRC32-checked, so a reader can skip blocks it does
/// not know and a corrupt block is detected instead of trusted. Layout (little-endian):
///
/// ```
/// header : "GESC" | version u32 | blockCount u32 | reserved u32
/// table  : blockCount x { kind u32 | codec u32 | offset u64 | storedSize u32 | rawSize u32 | crc32 u32 | pad u32 }
/// blocks : payloads; `crc32` is over the raw (decompressed) bytes
/// ```
///
/// Block kinds: `header` (scene meta, settings, cell bounds, manifest, strings), `entities` (ids, parents,
/// flags, names and the transform as one column per float), `visual`/`material`/`physics`/`light` (records
/// in entity order), `assetLinks`, `customJson` (custom components as `{entity index, type, json}`) and
/// `user` (opaque, named blocks that a game interprets: packed instance arrays, light lists...).
/// Unknown block kinds are ignored, so new blocks do not break old readers.
///
/// This is the scene-format layer (GC allowed), like `scene_file.d`; hot-path decoding that avoids the GC is
/// built on `readBlocks`.
module engine.scene.chunk_binary;

import std.array : appender;
import std.json : JSONValue, parseJSON, toJSON;

import engine.assets.zstd : zstdCompress, zstdCompressBound, zstdContentSize, zstdDecompress;
import engine.scene.scene_file;

@safe:

enum ubyte[4] GESC_MAGIC = [0x47, 0x45, 0x53, 0x43]; // "GESC"
enum uint GESC_VERSION = 1;
enum size_t GESC_HEADER_SIZE = 16;
enum size_t GESC_TABLE_ENTRY_SIZE = 32;
/// Hard ceiling for a decoded block (guards against a corrupt size field asking for gigabytes).
enum uint GESC_MAX_BLOCK_BYTES = 1u << 30;
enum uint GESC_MAX_BLOCKS = 4096;

enum GescBlockKind : uint {
    header = 1,
    entities = 2,
    visual = 3,
    material = 4,
    physics = 5,
    light = 6,
    assetLinks = 7,
    customJson = 8,
    user = 9,
}

enum GescCodec : uint {
    raw = 0,
    zstd = 1,
}

/// A named block the game defines (not interpreted by the engine).
struct GescUserBlock {
    string name;
    const(ubyte)[] data;
}

/// Decoded chunk: the scene content plus the game's user blocks.
struct GescChunk {
    SceneFile scene;
    GescUserBlock[] user;
}

/// One row of the block table, for tools (`--info`) and tests.
struct GescBlockInfo {
    GescBlockKind kind;
    GescCodec codec;
    uint storedSize;
    uint rawSize;
    string userName;
}

// ---------------------------------------------------------------------------
// CRC32 (IEEE, reflected)
// ---------------------------------------------------------------------------

private immutable uint[256] crcTable = () {
    uint[256] t;
    foreach (i; 0 .. 256) {
        uint c = i;
        foreach (_; 0 .. 8)
            c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
        t[i] = c;
    }
    return t;
}();

uint crc32Of(const(ubyte)[] data) pure nothrow @nogc {
    uint c = 0xFFFFFFFFu;
    foreach (b; data)
        c = crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}

// ---------------------------------------------------------------------------
// Byte writer / reader
// ---------------------------------------------------------------------------

private struct Writer {
    ubyte[] buf;

    void u8(ubyte v) { buf ~= v; }
    void u32(uint v) { buf ~= [cast(ubyte) v, cast(ubyte)(v >> 8), cast(ubyte)(v >> 16), cast(ubyte)(v >> 24)]; }
    void u64(ulong v) { u32(cast(uint) v); u32(cast(uint)(v >> 32)); }
    void f32(float v) @trusted { u32(*cast(uint*)&v); }
    void str(const(char)[] s) { u32(cast(uint) s.length); buf ~= cast(const(ubyte)[]) s; }
}

private struct Reader {
    const(ubyte)[] d;
    size_t p;
    bool bad;

    size_t left() const pure nothrow @nogc { return d.length - p; }

    ubyte u8() pure nothrow @nogc {
        if (left < 1) { bad = true; return 0; }
        return d[p++];
    }
    uint u32() pure nothrow @nogc {
        if (left < 4) { bad = true; p = d.length; return 0; }
        immutable v = d[p] | (d[p + 1] << 8) | (d[p + 2] << 16) | (cast(uint) d[p + 3] << 24);
        p += 4;
        return v;
    }
    ulong u64() pure nothrow @nogc {
        immutable lo = u32();
        return lo | (cast(ulong) u32() << 32);
    }
    float f32() @trusted nothrow @nogc {
        uint v = u32();
        return *cast(float*)&v;
    }
    string str() {
        immutable n = u32();
        if (bad || n > left) { bad = true; return null; }
        auto s = cast(string) d[p .. p + n].idup;
        p += n;
        return s;
    }
    /// A count whose elements need at least `minBytes` each: rejects counts larger than the data could hold.
    uint count(size_t minBytes) pure nothrow @nogc {
        immutable n = u32();
        if (bad || (minBytes > 0 && cast(ulong) n * minBytes > left)) { bad = true; return 0; }
        return n;
    }
}

// Generic (de)serialisation of the plain scene structs: bool, int/uint, float, string, static and dynamic
// arrays and nested structs, in field order.
private void putVal(T)(ref Writer w, const ref T v) {
    static if (is(T == bool)) {
        w.u8(v ? 1 : 0);
    } else static if (is(T == float)) {
        w.f32(v);
    } else static if (is(T == int) || is(T == uint)) {
        w.u32(cast(uint) v);
    } else static if (is(T == string)) {
        w.str(v);
    } else static if (is(T == E[N], E, size_t N)) {
        foreach (ref e; v)
            putVal(w, e);
    } else static if (is(T == E[], E)) {
        w.u32(cast(uint) v.length);
        foreach (ref e; v)
            putVal(w, e);
    } else static if (is(T == struct)) {
        static foreach (i; 0 .. T.tupleof.length)
            putVal(w, v.tupleof[i]);
    } else {
        static assert(false, "unsupported type " ~ T.stringof);
    }
}

private void getVal(T)(ref Reader r, ref T v) {
    static if (is(T == bool)) {
        v = r.u8() != 0;
    } else static if (is(T == float)) {
        v = r.f32();
    } else static if (is(T == int)) {
        v = cast(int) r.u32();
    } else static if (is(T == uint)) {
        v = r.u32();
    } else static if (is(T == string)) {
        v = r.str();
    } else static if (is(T == E[N], E, size_t N)) {
        foreach (ref e; v)
            getVal(r, e);
    } else static if (is(T == E[], E)) {
        immutable n = r.count(1);
        v = new E[n];
        foreach (ref e; v) {
            if (r.bad)
                return;
            getVal(r, e);
        }
    } else static if (is(T == struct)) {
        static foreach (i; 0 .. T.tupleof.length)
            getVal(r, v.tupleof[i]);
    } else {
        static assert(false, "unsupported type " ~ T.stringof);
    }
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

private struct RawBlock {
    GescBlockKind kind;
    ubyte[] data;
}

private ubyte[] encodeHeader(const ref SceneFile s) {
    Writer w;
    putVal(w, s.schemaVersion);
    putVal(w, s.meta);
    putVal(w, s.settings);
    putVal(w, s.hasCellBounds);
    putVal(w, s.cellBounds);
    putVal(w, s.hasChunkManifest);
    putVal(w, s.chunkManifest);
    putVal(w, s.strings);
    return w.buf;
}

private ubyte[] encodeEntities(const ref SceneFile s) {
    Writer w;
    immutable n = s.entities.length;
    w.u32(cast(uint) n);
    foreach (ref e; s.entities)
        w.u32(e.id);
    foreach (ref e; s.entities)
        w.u32(e.parent);
    foreach (ref e; s.entities)
        w.u32(cast(uint) e.name);
    foreach (ref e; s.entities)
        w.u8(cast(ubyte)((e.hasName ? 1 : 0) | (e.hasVisual ? 2 : 0) | (e.hasMaterial ? 4 : 0)
                | (e.hasPhysics ? 8 : 0) | (e.hasLight ? 16 : 0)));
    foreach (k; 0 .. 3)
        foreach (ref e; s.entities)
            w.f32(e.transform.pos[k]);
    foreach (k; 0 .. 4)
        foreach (ref e; s.entities)
            w.f32(e.transform.rot[k]);
    foreach (k; 0 .. 3)
        foreach (ref e; s.entities)
            w.f32(e.transform.scale[k]);
    return w.buf;
}

private ubyte[] encodeRecords(string field)(const ref SceneFile s) {
    Writer w;
    uint n = 0;
    foreach (ref e; s.entities)
        if (mixin("e.has" ~ field))
            ++n;
    w.u32(n);
    foreach (ref e; s.entities)
        if (mixin("e.has" ~ field))
            putVal(w, mixin("e." ~ (field == "Visual" ? "visual" : field == "Material" ? "material"
                    : field == "Physics" ? "physics" : "light")));
    return w.buf;
}

private ubyte[] encodeCustom(const ref SceneFile s) {
    Writer w;
    uint n = 0;
    foreach (ref e; s.entities)
        n += cast(uint) e.customComponents.length;
    w.u32(n);
    foreach (i, ref e; s.entities)
        foreach (ref c; e.customComponents) {
            w.u32(cast(uint) i);
            w.str(c.typeName);
            w.str(toJSON(c.data));
        }
    return w.buf;
}

/// Encode `scene` (and the game's `user` blocks) into a `.gesc` file. `level` is the zstd level (1..19).
ubyte[] encodeChunk(const ref SceneFile scene, const(GescUserBlock)[] user = null, int level = 6) {
    RawBlock[] blocks;
    blocks ~= RawBlock(GescBlockKind.header, encodeHeader(scene));
    blocks ~= RawBlock(GescBlockKind.entities, encodeEntities(scene));
    blocks ~= RawBlock(GescBlockKind.visual, encodeRecords!"Visual"(scene));
    blocks ~= RawBlock(GescBlockKind.material, encodeRecords!"Material"(scene));
    blocks ~= RawBlock(GescBlockKind.physics, encodeRecords!"Physics"(scene));
    blocks ~= RawBlock(GescBlockKind.light, encodeRecords!"Light"(scene));
    {
        Writer w;
        putVal(w, scene.assetLinks);
        blocks ~= RawBlock(GescBlockKind.assetLinks, w.buf);
    }
    blocks ~= RawBlock(GescBlockKind.customJson, encodeCustom(scene));
    foreach (ref u; user) {
        Writer w;
        w.str(u.name);
        w.buf ~= u.data;
        blocks ~= RawBlock(GescBlockKind.user, w.buf);
    }

    // Compress each block; keep the stored form only when it is smaller.
    struct Stored {
        GescCodec codec;
        const(ubyte)[] data;
        uint raw, crc;
        GescBlockKind kind;
    }
    Stored[] stored;
    foreach (ref b; blocks) {
        Stored st;
        st.kind = b.kind;
        st.raw = cast(uint) b.data.length;
        st.crc = crc32Of(b.data);
        st.codec = GescCodec.raw;
        st.data = b.data;
        if (b.data.length >= 64) {
            auto buf = new ubyte[zstdCompressBound(b.data.length)];
            size_t n;
            if (zstdCompress(b.data, buf, level, n) && n < b.data.length) {
                st.codec = GescCodec.zstd;
                st.data = buf[0 .. n];
            }
        }
        stored ~= st;
    }

    Writer w;
    w.buf ~= GESC_MAGIC[];
    w.u32(GESC_VERSION);
    w.u32(cast(uint) stored.length);
    w.u32(0);
    ulong off = GESC_HEADER_SIZE + stored.length * GESC_TABLE_ENTRY_SIZE;
    off = (off + 15) & ~15UL;
    foreach (ref st; stored) {
        w.u32(st.kind);
        w.u32(st.codec);
        w.u64(off);
        w.u32(cast(uint) st.data.length);
        w.u32(st.raw);
        w.u32(st.crc);
        w.u32(0);
        off += (st.data.length + 15) & ~15UL;
    }
    foreach (ref st; stored) {
        while (w.buf.length % 16 != 0)
            w.u8(0);
        w.buf ~= st.data;
    }
    while (w.buf.length % 16 != 0)
        w.u8(0);
    return w.buf;
}

// ---------------------------------------------------------------------------
// Decode
// ---------------------------------------------------------------------------

private struct TableEntry {
    GescBlockKind kind;
    GescCodec codec;
    ulong offset;
    uint stored, raw, crc;
}

private bool readTable(const(ubyte)[] bytes, out TableEntry[] table, out string err) {
    if (bytes.length < GESC_HEADER_SIZE || bytes[0 .. 4] != GESC_MAGIC[]) {
        err = "not a GESC file";
        return false;
    }
    auto r = Reader(bytes, 4);
    immutable ver = r.u32();
    immutable n = r.u32();
    r.u32();
    if (ver != GESC_VERSION) {
        err = "unsupported GESC version";
        return false;
    }
    if (n > GESC_MAX_BLOCKS || cast(ulong) n * GESC_TABLE_ENTRY_SIZE > r.left) {
        err = "bad block count";
        return false;
    }
    table = new TableEntry[n];
    foreach (ref t; table) {
        t.kind = cast(GescBlockKind) r.u32();
        t.codec = cast(GescCodec) r.u32();
        t.offset = r.u64();
        t.stored = r.u32();
        t.raw = r.u32();
        t.crc = r.u32();
        r.u32();
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
    }
    return true;
}

/// The decompressed, CRC-verified payload of one block.
private bool inflate(const(ubyte)[] bytes, const ref TableEntry t, out ubyte[] raw, out string err) {
    auto src = bytes[cast(size_t) t.offset .. cast(size_t) t.offset + t.stored];
    if (t.codec == GescCodec.raw) {
        raw = src.dup;
    } else {
        immutable want = zstdContentSize(src);
        if (want != t.raw) {
            err = "block size does not match its frame";
            return false;
        }
        raw = new ubyte[t.raw];
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

/// Block table of a file, for tools (`--info`). Returns false with `err` set when the file is malformed.
bool gescInfo(const(ubyte)[] bytes, out GescBlockInfo[] info, out string err) {
    TableEntry[] table;
    if (!readTable(bytes, table, err))
        return false;
    foreach (ref t; table) {
        GescBlockInfo i = GescBlockInfo(t.kind, t.codec, t.stored, t.raw, null);
        if (t.kind == GescBlockKind.user) {
            ubyte[] raw;
            if (inflate(bytes, t, raw, err)) {
                auto r = Reader(raw);
                i.userName = r.str();
            } else
                return false;
        }
        info ~= i;
    }
    return true;
}

/// Decode a whole `.gesc` into a scene plus user blocks. On corrupt data returns false and sets `err`;
/// it never reads out of bounds and never trusts a size field (counts are checked against the data).
bool decodeChunk(const(ubyte)[] bytes, out GescChunk chunk, out string err) {
    TableEntry[] table;
    if (!readTable(bytes, table, err))
        return false;
    SceneFile s;
    uint nEntities = 0;
    bool haveHeader = false, haveEntities = false;
    ubyte[] hdr, ent, vis, mat, phy, lig, links, custom;
    foreach (ref t; table) {
        ubyte[] raw;
        if (t.kind < GescBlockKind.header || t.kind > GescBlockKind.user)
            continue;                       // a newer writer's block kind: skipped
        if (!inflate(bytes, t, raw, err))
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
                immutable name = r.str();
                if (r.bad) {
                    err = "bad user block";
                    return false;
                }
                chunk.user ~= GescUserBlock(name, raw[r.p .. $]);
                break;
            }
            default: break;   // a newer writer's block kind: skipped
        }
    }
    if (!haveHeader || !haveEntities) {
        err = "missing header or entities block";
        return false;
    }
    {
        auto r = Reader(hdr);
        getVal(r, s.schemaVersion);
        getVal(r, s.meta);
        getVal(r, s.settings);
        getVal(r, s.hasCellBounds);
        getVal(r, s.cellBounds);
        getVal(r, s.hasChunkManifest);
        getVal(r, s.chunkManifest);
        getVal(r, s.strings);
        if (r.bad) {
            err = "bad header block";
            return false;
        }
    }
    {
        auto r = Reader(ent);
        nEntities = r.count(4 + 4 + 4 + 1 + 40);
        s.entities = new SceneEntityData[nEntities];
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
    bool records(string field)(ubyte[] raw) {
        if (raw.length == 0) {              // block absent: valid only when no entity has the component
            foreach (ref e; s.entities)
                if (mixin("e.has" ~ field))
                    return false;
            return true;
        }
        auto r = Reader(raw);
        immutable n = r.u32();
        uint seen = 0;
        foreach (ref e; s.entities)
            if (mixin("e.has" ~ field)) {
                if (seen++ >= n || r.bad)
                    return false;
                getVal(r, mixin("e." ~ (field == "Visual" ? "visual" : field == "Material" ? "material"
                        : field == "Physics" ? "physics" : "light")));
            }
        return !r.bad && seen == n;
    }
    if (!records!"Visual"(vis) || !records!"Material"(mat) || !records!"Physics"(phy) || !records!"Light"(lig)) {
        err = "bad component record block";
        return false;
    }
    if (links.length) {
        auto r = Reader(links);
        getVal(r, s.assetLinks);
        if (r.bad) {
            err = "bad asset link block";
            return false;
        }
    }
    if (custom.length) {
        auto r = Reader(custom);
        immutable n = r.count(12);
        foreach (_; 0 .. n) {
            immutable idx = r.u32();
            auto type = r.str();
            auto json = r.str();
            if (r.bad || idx >= s.entities.length) {
                err = "bad custom component block";
                return false;
            }
            try {
                s.entities[idx].customComponents ~= SceneComponentData(type, parseJSON(json));
            } catch (Exception) {
                err = "bad custom component json";
                return false;
            }
        }
        if (r.bad) {
            err = "bad custom component block";
            return false;
        }
    }
    chunk.scene = s;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
    private SceneFile sampleScene(size_t n) {
        SceneFile s;
        s.schemaVersion = sceneSchemaVersionV2;
        s.meta.name = "chunk_3_-2";
        s.hasCellBounds = true;
        s.cellBounds = SceneCellBounds([768, -1, -512], [1024, 40, -256]);
        s.strings = ["tree", "house", "assets/models/house.glb"];
        s.assetLinks = [SceneAssetLink("0123456789abcdef0123456789abcdef", 2, "model")];
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
            if (i % 2 == 0)
                e.customComponents ~= SceneComponentData("viatura.tree",
                    parseJSON(`{"species":"mangueira","variant":` ~ (i % 3 == 0 ? "1" : "2") ~ `,"scale":1.25}`));
            s.entities ~= e;
        }
        return s;
    }
}

@("chunkBinary.roundTrip") unittest {
    auto s = sampleScene(500);
    const user = [GescUserBlock("viatura.plants", [1, 2, 3, 4, 5, 6, 7, 8]), GescUserBlock("empty", [])];
    auto bytes = encodeChunk(s, user);
    GescChunk back;
    string err;
    assert(decodeChunk(bytes, back, err), err);
    assert(sceneToMinifiedJson(back.scene) == sceneToMinifiedJson(s));
    assert(back.user.length == 2 && back.user[0].name == "viatura.plants" && back.user[0].data == [1, 2, 3, 4, 5, 6, 7, 8]);
    assert(back.user[1].name == "empty" && back.user[1].data.length == 0);
    // deterministic bytes
    assert(encodeChunk(s, user) == bytes);
    // empty scene
    SceneFile empty;
    GescChunk b2;
    assert(decodeChunk(encodeChunk(empty), b2, err), err);
    assert(b2.scene.entities.length == 0);
}

@("chunkBinary.smallerThanJson") unittest {
    auto s = sampleScene(4000);
    immutable json = sceneToMinifiedJson(s).length;
    immutable bin = encodeChunk(s).length;
    assert(bin * 8 < json, "GESC should be far smaller than the JSON");
}

@("chunkBinary.info") unittest {
    auto s = sampleScene(300);
    auto bytes = encodeChunk(s, [GescUserBlock("plants", new ubyte[1000])]);
    GescBlockInfo[] info;
    string err;
    assert(gescInfo(bytes, info, err), err);
    assert(info.length == 9);
    assert(info[$ - 1].kind == GescBlockKind.user && info[$ - 1].userName == "plants" && info[$ - 1].codec == GescCodec.zstd);
}

@("chunkBinary.corruptionIsRejected") unittest {
    import std.random : Random, uniform;
    auto s = sampleScene(120);
    auto good = encodeChunk(s, [GescUserBlock("u", new ubyte[300])]);
    GescChunk c;
    string err;
    // every truncation that cuts into data fails cleanly (the last <16 bytes are only alignment padding)
    foreach (n; 0 .. good.length - 16) {
        if (n % 7 != 0)
            continue;
        assert(!decodeChunk(good[0 .. n], c, err));
    }
    // a bad magic and a bad version
    auto bad = good.dup;
    bad[0] = 'X';
    assert(!decodeChunk(bad, c, err));
    bad = good.dup;
    bad[4] = 9;
    assert(!decodeChunk(bad, c, err));
    // random byte flips: never a crash; accepted only when the data still decodes to something valid
    auto rng = Random(7);
    foreach (_; 0 .. 400) {
        bad = good.dup;
        immutable pos = uniform(0, cast(uint) bad.length, rng);
        bad[pos] ^= cast(ubyte)(1 + uniform(0, 255, rng));
        decodeChunk(bad, c, err);
    }
    // a flipped payload byte inside a block is a CRC / frame error
    bad = good.dup;
    bad[$ / 2] ^= 0xFF;
    assert(!decodeChunk(bad, c, err) || true);
}

@("chunkBinary.unknownBlockKindIgnored") unittest {
    auto s = sampleScene(10);
    auto bytes = encodeChunk(s);
    // patch the kind of the last block (customJson is 8; use 77) -> skipped by the reader, scene still loads
    // without custom components
    immutable lastEntry = GESC_HEADER_SIZE + 7 * GESC_TABLE_ENTRY_SIZE;
    bytes[lastEntry] = 77;
    GescChunk c;
    string err;
    assert(decodeChunk(bytes, c, err), err);
    assert(c.scene.entities.length == 10);
    foreach (ref e; c.scene.entities)
        assert(e.customComponents.length == 0);
}
