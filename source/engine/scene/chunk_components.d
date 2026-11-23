/// Binary component blocks for GESC chunks (format version 2).
///
/// Custom components normally travel as JSON (`customJson` block): one `parseJSON` per component on load. For
/// component types the writer's process has registered, `encodeChunkWithComponents` instead cooks them into
/// two kinds of blocks:
///
/// ```
/// types      : u32 typeCount, then per type
///                str name | u32 sizeof | u32 alignof | u32 fieldCount | per field
///                  { str name | str formerlyNamed | u8 FieldKind | u32 offset | u32 size | u32 arrayLen }
/// component  : str typeName | u32 count | u32 stringCount, stringCount x str   (block-local string table)
///              | u32 entityIndex[count] | zero padding to a 16-byte boundary (relative to the block)
///              | count x sizeof raw component structs
/// ```
///
/// Mapping is by type *name* through `TypeRegistry.find` (a `ComponentTypeId` is an index into one process's
/// registry and is not stable across processes). When the reader's struct has the same layout as the writer's the
/// dense bytes are copied with one memcpy; when it differs (field added, removed, renamed with `@formerlyNamed`,
/// or a numeric field changed type) each field is copied by name and missing fields keep the reader's defaults.
/// `StringId` fields are rewritten through the block-local string table and `@entityRef` fields from chunk-local
/// entity ids to live `EntityId`s. Types the writer could not cook, and chunks written before version 2, keep
/// using the JSON block, which also remains the editable source of truth (`*.scene.json`).
///
/// Decoding (`decodeChunk`) and applying (`applyGescComponents`) are separate steps: the first needs only buffers,
/// the second needs the destination world.
module engine.scene.chunk_components;

import std.json : JSONValue;

import engine.core.strings : StringId, StringTable;
import engine.ecs.scene_world : SceneWorld;
import engine.ecs.store : EntityId;
import engine.editor.scene_load : SceneLoadOptions, SceneLoadResult, loadSceneAdditive;
import engine.math.vec : Vec3;
import engine.reflect.descriptor;
import engine.reflect.serialize : deserializeComponent, serializeComponent;
import engine.scene.chunk_binary;
import engine.scene.scene_file;

@safe:

enum uint GESC_MAX_TYPE_SIZE = 1u << 20;
enum uint GESC_MAX_TYPE_FIELDS = 4096;

/// One field of a stored component type.
struct GescFieldSchema {
    string name;
    string formerlyNamed;
    FieldKind kind;
    uint offset, size, arrayLen = 1;
}

/// A stored component type, as written in the `types` block.
struct GescTypeSchema {
    string name;
    uint size, alignment;
    GescFieldSchema[] fields;
}

/// Outcome of `applyGescComponents`.
struct GescApplyResult {
    /// Component blocks applied (types registered in the world).
    uint blocksApplied;
    /// Component instances inserted.
    uint componentsApplied;
    /// Names of stored types the world does not register (their components are skipped).
    string[] unresolvedTypes;
    /// Number of component instances skipped for that reason.
    uint unresolvedComponents;
}

// ---------------------------------------------------------------------------
// Schema (de)serialisation
// ---------------------------------------------------------------------------

/// Schema of a registered type, for the `types` block.
GescTypeSchema schemaOf(ref const TypeRegistry reg, ComponentTypeId tid, ref const StringTable strings) {
    GescTypeSchema t;
    const d = reg.getType(tid);
    t.name = strings.get(d.qualifiedName).idup;
    t.size = d.size;
    t.alignment = d.alignment;
    foreach (ref const f; reg.getFields(tid)) {
        GescFieldSchema g;
        g.name = strings.get(f.name).idup;
        if (!f.attrs.formerlyNamed.isNull)
            g.formerlyNamed = strings.get(f.attrs.formerlyNamed).idup;
        g.kind = f.kind;
        g.offset = f.offset;
        g.size = f.size;
        g.arrayLen = f.arrayLen;
        t.fields ~= g;
    }
    return t;
}

ubyte[] encodeTypesBlock(const(GescTypeSchema)[] types) {
    Writer w;
    w.u32(cast(uint) types.length);
    foreach (ref t; types) {
        w.str(t.name);
        w.u32(t.size);
        w.u32(t.alignment);
        w.u32(cast(uint) t.fields.length);
        foreach (ref f; t.fields) {
            w.str(f.name);
            w.str(f.formerlyNamed);
            w.u8(cast(ubyte) f.kind);
            w.u32(f.offset);
            w.u32(f.size);
            w.u32(f.arrayLen);
        }
    }
    return w.buf;
}

/// Parse a `types` block. Every size and count is validated against the data; returns false with `err` set.
bool parseTypesBlock(const(ubyte)[] payload, out GescTypeSchema[] types, out string err) {
    auto r = Reader(payload);
    immutable n = r.count(16);
    foreach (_; 0 .. n) {
        GescTypeSchema t;
        t.name = r.str();
        t.size = r.u32();
        t.alignment = r.u32();
        immutable nf = r.count(21);
        if (r.bad || t.size > GESC_MAX_TYPE_SIZE || nf > GESC_MAX_TYPE_FIELDS) {
            err = "bad types block";
            return false;
        }
        foreach (__; 0 .. nf) {
            GescFieldSchema f;
            f.name = r.str();
            f.formerlyNamed = r.str();
            f.kind = cast(FieldKind) r.u8();
            f.offset = r.u32();
            f.size = r.u32();
            f.arrayLen = r.u32();
            if (r.bad || f.kind > FieldKind.struct_ || cast(ulong) f.offset + f.size > t.size) {
                err = "bad types block";
                return false;
            }
            t.fields ~= f;
        }
        types ~= t;
    }
    if (r.bad) {
        err = "bad types block";
        return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Component block (de)serialisation
// ---------------------------------------------------------------------------

/// A parsed `component` block: slices into the payload, no copy of the records.
struct GescComponentBlock {
    string typeName;
    uint count;
    string[] strings;           /// block-local string table (local id i+1 is `strings[i]`)
    const(ubyte)[] entityIndex; /// `count` little-endian u32
    const(ubyte)[] data;        /// `count` records of the stored type's size

    uint indexAt(size_t i) const pure nothrow @nogc {
        immutable p = i * 4;
        return entityIndex[p] | (entityIndex[p + 1] << 8) | (entityIndex[p + 2] << 16) | (cast(uint) entityIndex[p + 3] << 24);
    }
}

/// Parse a `component` payload. `itemSize` is the stored size from the `types` block, used to validate the data.
bool parseComponentBlock(const(ubyte)[] payload, uint itemSize, out GescComponentBlock b, out string err) {
    auto r = Reader(payload);
    b.typeName = r.str();
    b.count = r.u32();
    immutable ns = r.count(4);
    foreach (_; 0 .. ns)
        b.strings ~= r.str();
    if (r.bad || cast(ulong) b.count * 4 > r.left) {
        err = "bad component block";
        return false;
    }
    b.entityIndex = payload[r.p .. r.p + b.count * 4];
    r.p += b.count * 4;
    r.p = (r.p + 15) & ~cast(size_t) 15;
    if (r.p > payload.length || cast(ulong) b.count * itemSize != payload.length - r.p) {
        err = "bad component block size";
        return false;
    }
    b.data = payload[r.p .. $];
    return true;
}

// ---------------------------------------------------------------------------
// Encode
// ---------------------------------------------------------------------------

private struct TypeAcc {
    ComponentTypeId tid;
    uint[] index;
    ubyte[] data;
    string[] locals;
    uint[string] localIds;
}

private T ld(T)(const(ubyte)[] p) @trusted {
    T v;
    (cast(ubyte*) &v)[0 .. T.sizeof] = p[0 .. T.sizeof];
    return v;
}

private void st(T)(ubyte[] p, T v) @trusted {
    p[0 .. T.sizeof] = (cast(const(ubyte)*) &v)[0 .. T.sizeof];
}

/// Encode `scene` like `encodeChunk`, cooking every custom component whose type `reg` registers into binary
/// `types` / `component` blocks (the others stay in the `customJson` block). `strings` is the table `reg` was
/// registered with; it is only appended to. The result is a version-2 file when at least one component was cooked,
/// otherwise identical to `encodeChunk`'s output. `entityRef` values are chunk-local entity ids, as in the JSON.
ubyte[] encodeChunkWithComponents(const ref SceneFile scene, ref TypeRegistry reg, ref StringTable strings,
        const(GescUserBlock)[] user = null, int level = 6) @trusted {
    SceneFile s2 = cast() scene;                 // shallow copy; only slices we replace below are written
    s2.entities = s2.entities.dup;
    TypeAcc[] accs;
    int[ComponentTypeId] accOf;
    foreach (i, ref e; s2.entities) {
        SceneComponentData[] keep;
        foreach (ref c; e.customComponents) {
            immutable tid = reg.find(c.typeName, strings);
            if (tid == invalidComponentTypeId) {
                keep ~= c;
                continue;
            }
            auto pa = tid in accOf;
            if (pa is null) {
                accOf[tid] = cast(int) accs.length;
                accs ~= TypeAcc(tid);
                pa = tid in accOf;
            }
            auto acc = &accs[*pa];
            immutable sz = reg.getType(tid).size;
            auto rec = new ubyte[sz];
            try {
                deserializeComponent(reg, tid, c.data, rec, strings);
            } catch (Exception) {
                keep ~= c;                    // JSON that does not fit the registered type stays JSON
                continue;
            }
            foreach (ref const f; reg.getFields(tid)) {
                if (f.kind != FieldKind.stringId)
                    continue;
                immutable sid = ld!StringId(rec[f.offset .. $]);
                uint local = 0;
                if (!sid.isNull) {
                    string str = strings.get(sid).idup;
                    if (auto p = str in acc.localIds)
                        local = *p;
                    else {
                        acc.locals ~= str;
                        local = cast(uint) acc.locals.length;
                        acc.localIds[str] = local;
                    }
                }
                st!uint(rec[f.offset .. $], local);
            }
            acc.index ~= cast(uint) i;
            acc.data ~= rec;
        }
        e.customComponents = keep;
    }
    if (accs.length == 0)
        return encodeChunk(scene, user, level);

    GescTypeSchema[] schemas;
    foreach (ref a; accs)
        schemas ~= schemaOf(reg, a.tid, strings);
    GescExtraBlock[] extra;
    extra ~= GescExtraBlock(GescBlockKind.types, encodeTypesBlock(schemas));
    foreach (ref a; accs) {
        Writer w;
        w.str(strings.get(reg.getType(a.tid).qualifiedName));
        w.u32(cast(uint) a.index.length);
        w.u32(cast(uint) a.locals.length);
        foreach (ref l; a.locals)
            w.str(l);
        foreach (ix; a.index)
            w.u32(ix);
        while (w.buf.length % 16 != 0)
            w.u8(0);
        w.buf ~= a.data;
        extra ~= GescExtraBlock(GescBlockKind.component, w.buf);
    }
    return encodeChunk(s2, user, level, extra);
}

// ---------------------------------------------------------------------------
// Field conversion
// ---------------------------------------------------------------------------

private enum OpKind : ubyte { copy, convert, stringId, entity }

private struct Op {
    OpKind kind;
    FieldKind srcKind, dstKind;
    uint srcOff, dstOff, size;
}

private bool isNumeric(FieldKind k) pure nothrow @nogc {
    return k >= FieldKind.f32 && k <= FieldKind.bool_;
}

private bool isFloating(FieldKind k) pure nothrow @nogc {
    return k == FieldKind.f32 || k == FieldKind.f64;
}

private long readInt(FieldKind k, const(ubyte)[] p) {
    switch (k) {
        case FieldKind.i8: return ld!byte(p);
        case FieldKind.i16: return ld!short(p);
        case FieldKind.i32: return ld!int(p);
        case FieldKind.i64: return ld!long(p);
        case FieldKind.u8: return ld!ubyte(p);
        case FieldKind.u16: return ld!ushort(p);
        case FieldKind.u32: return ld!uint(p);
        case FieldKind.u64: return cast(long) ld!ulong(p);
        case FieldKind.bool_: return ld!ubyte(p) != 0;
        default: return 0;
    }
}

private double readFloat(FieldKind k, const(ubyte)[] p) {
    return k == FieldKind.f32 ? ld!float(p) : ld!double(p);
}

private void convertScalar(FieldKind sk, const(ubyte)[] src, FieldKind dk, ubyte[] dst) {
    immutable sf = isFloating(sk);
    immutable long l = sf ? 0 : readInt(sk, src);
    immutable double d = sf ? readFloat(sk, src) : 0;
    if (isFloating(dk)) {
        immutable v = sf ? d : cast(double) l;
        if (dk == FieldKind.f32)
            st!float(dst, cast(float) v);
        else
            st!double(dst, v);
        return;
    }
    long v = l;
    if (sf)
        v = (d != d) ? 0 : (d >= 9.2e18 ? long.max : (d <= -9.2e18 ? long.min : cast(long) d));
    switch (dk) {
        case FieldKind.i8: st!byte(dst, cast(byte) v); break;
        case FieldKind.i16: st!short(dst, cast(short) v); break;
        case FieldKind.i32: st!int(dst, cast(int) v); break;
        case FieldKind.i64: st!long(dst, v); break;
        case FieldKind.u8: st!ubyte(dst, cast(ubyte) v); break;
        case FieldKind.u16: st!ushort(dst, cast(ushort) v); break;
        case FieldKind.u32: st!uint(dst, cast(uint) v); break;
        case FieldKind.u64: st!ulong(dst, cast(ulong) v); break;
        case FieldKind.bool_: st!ubyte(dst, v != 0 ? 1 : 0); break;
        default: break;
    }
}

/// True when the stored layout is byte-for-byte the reader's: same size and the same fields at the same offsets.
private bool sameLayout(ref const GescTypeSchema src, ref const TypeRegistry reg, ComponentTypeId tid,
        ref const StringTable strings) {
    const d = reg.getType(tid);
    auto fs = reg.getFields(tid);
    if (src.size != d.size || src.fields.length != fs.length)
        return false;
    foreach (i, ref const f; fs) {
        // A pointer, not a `ref` local: D only allows `ref` on parameters and foreach variables (LDC enforces it).
        const g = &src.fields[i];
        if (g.name != strings.get(f.name) || g.kind != f.kind || g.offset != f.offset || g.size != f.size
                || g.arrayLen != f.arrayLen)
            return false;
    }
    return true;
}

/// The per-field operations that turn a stored record into the reader's record (or, when `identical`, only the
/// fix-ups that a memcpy of the record needs: string-id and entity-id rewrites).
private Op[] buildOps(ref const GescTypeSchema src, ref const TypeRegistry reg, ComponentTypeId tid,
        ref const StringTable strings, bool identical) {
    Op[] ops;
    foreach (ref const df; reg.getFields(tid)) {
        if (df.kind == FieldKind.unknown)
            continue;
        const(char)[] dname = strings.get(df.name);
        const(char)[] dformer = df.attrs.formerlyNamed.isNull ? null : strings.get(df.attrs.formerlyNamed);
        const(GescFieldSchema)* sf;
        foreach (ref const g; src.fields) {
            if (g.name == dname || (dformer.length && g.name == dformer) || (g.formerlyNamed.length && g.formerlyNamed == dname)) {
                sf = &g;
                // an exact name match wins over a rename match
                if (g.name == dname)
                    break;
            }
        }
        if (sf is null)
            continue;
        Op op;
        op.srcKind = sf.kind;
        op.dstKind = df.kind;
        op.srcOff = sf.offset;
        op.dstOff = df.offset;
        op.size = df.size;
        if (df.kind == FieldKind.stringId && sf.kind == FieldKind.stringId && sf.size == 4 && df.size == 4)
            op.kind = OpKind.stringId;
        else if (df.kind == FieldKind.entityRef && sf.kind == FieldKind.entityRef && sf.size == 4 && df.size == 4)
            op.kind = OpKind.entity;
        else if (sf.kind == df.kind && sf.size == df.size && sf.arrayLen == df.arrayLen)
            op.kind = OpKind.copy;
        else if (isNumeric(sf.kind) && isNumeric(df.kind) && sf.arrayLen == 1 && df.arrayLen == 1)
            op.kind = OpKind.convert;
        else
            continue;
        if (identical && op.kind != OpKind.stringId && op.kind != OpKind.entity)
            continue;
        ops ~= op;
    }
    return ops;
}

/// Convert all records of `b` (stored as `src`) to the layout of `tid` in `reg`, interning strings into
/// `strings`. When `fileIds` is non-null, entity-ref fields are remapped through it (file id 0, or an id that is
/// not in the map, becomes `EntityId.max`); when null they are left as stored.
ubyte[] convertRecords(ref const GescTypeSchema src, ref const GescComponentBlock b, ref const TypeRegistry reg,
        ComponentTypeId tid, ref StringTable strings, scope const(EntityId[uint])* fileIds) {
    immutable dsz = reg.getType(tid).size;
    immutable identical = sameLayout(src, reg, tid, strings);
    auto ops = buildOps(src, reg, tid, strings, identical);
    auto outBuf = new ubyte[b.count * dsz];
    StringId[] sidMap = new StringId[b.strings.length + 1];
    foreach (i, ref s; b.strings)
        sidMap[i + 1] = strings.intern(s);
    if (identical) {
        outBuf[] = b.data[];
    } else {
        auto defs = reg.getDefaults(tid);
        if (defs.length == dsz)
            foreach (i; 0 .. b.count)
                outBuf[i * dsz .. (i + 1) * dsz] = defs[];
    }
    immutable ssz = src.size;
    foreach (i; 0 .. b.count) {
        auto drec = outBuf[i * dsz .. (i + 1) * dsz];
        auto srec = b.data[i * ssz .. (i + 1) * ssz];
        foreach (ref op; ops) {
            auto dst = drec[op.dstOff .. op.dstOff + op.size];
            auto sp = srec[op.srcOff .. op.srcOff + op.size];
            final switch (op.kind) {
                case OpKind.copy:
                    dst[] = sp[];
                    break;
                case OpKind.convert:
                    convertScalar(op.srcKind, sp, op.dstKind, dst);
                    break;
                case OpKind.stringId: {
                    immutable local = ld!uint(sp);
                    st!StringId(dst, local < sidMap.length ? sidMap[local] : StringId.init);
                    break;
                }
                case OpKind.entity: {
                    immutable v = ld!uint(sp);
                    uint live = EntityId.max;
                    if (fileIds is null)
                        live = v;
                    else if (v != 0)
                        if (auto p = v in *fileIds)
                            live = *p;
                    st!uint(dst, live);
                    break;
                }
            }
        }
    }
    return outBuf;
}

// ---------------------------------------------------------------------------
// Apply
// ---------------------------------------------------------------------------

/// Insert the binary components of `chunk` into `world`. `entityByIndex[i]` is the live entity spawned for the
/// chunk's `i`-th entity, `fileIdToEntity` maps chunk-local entity ids to live ones (for `@entityRef` fields).
/// Types the world has not registered are reported in `res`, not failed. Returns false with `err` set when a
/// block is malformed (nothing from that block is applied; earlier blocks may already be). A chunk without
/// binary blocks (version 1, or all-JSON) is a no-op that returns true.
bool applyGescComponents(ref SceneWorld world, const ref GescChunk chunk, scope const(EntityId)[] entityByIndex,
        const(EntityId[uint]) fileIdToEntity, out GescApplyResult res, out string err) {
    if (chunk.componentBlocks.length == 0)
        return true;
    GescTypeSchema[] schemas;
    if (!parseTypesBlock(chunk.typesBlock, schemas, err))
        return false;
    foreach (payload; chunk.componentBlocks) {
        // The type name is the first string of the payload; look the schema up by it.
        auto nameReader = Reader(payload);
        immutable name = nameReader.str();
        if (nameReader.bad) {
            err = "bad component block";
            return false;
        }
        const(GescTypeSchema)* src;
        foreach (ref t; schemas)
            if (t.name == name)
                src = &t;
        if (src is null) {
            err = "component block without a type schema: " ~ name;
            return false;
        }
        GescComponentBlock b;
        if (!parseComponentBlock(payload, src.size, b, err))
            return false;
        immutable tid = world.types.find(name, world.strings);
        if (tid == invalidComponentTypeId) {
            res.unresolvedTypes ~= name;
            res.unresolvedComponents += b.count;
            continue;
        }
        auto ids = new EntityId[b.count];
        foreach (i; 0 .. b.count) {
            immutable ix = b.indexAt(i);
            if (ix >= entityByIndex.length) {
                err = "component entity index out of range";
                return false;
            }
            ids[i] = entityByIndex[ix];
        }
        auto bytes = convertRecords(*src, b, world.types, tid, world.strings, &fileIdToEntity);
        world.rawAddBatch(tid, ids, bytes);
        ++res.blocksApplied;
        res.componentsApplied += b.count;
    }
    return true;
}

/// Apply a decoded chunk to `world`: spawn its entities (batched), then insert its binary components and let the
/// JSON fallback components (`customJson`) resolve through the registry as before. This is the "apply" half of
/// loading a chunk; the "decode" half is `decodeChunk` / `parseChunkBytes`, which needs only buffers.
/// Throws when the chunk is malformed (a binary block that does not match its schema).
SceneLoadResult applyChunk(ref SceneWorld world, ref GescChunk chunk, Vec3 rootOffset, SceneLoadOptions opts,
        out GescApplyResult comps) {
    import std.exception : enforce;
    auto res = loadSceneAdditive(world, chunk.scene, rootOffset, opts);
    string err;
    enforce(applyGescComponents(world, chunk, res.spawnedEntities, res.fileIdToEntity, comps, err), "GESC: " ~ err);
    return res;
}

/// For tools and the editor: turn the binary component blocks of `chunk` back into `customComponents` JSON on
/// its scene entities, using the schemas stored in the file itself (no registry needed). Entity-ref fields stay
/// chunk-local ids. Fields that are structs or fixed arrays are not representable in JSON and are omitted.
bool gescMaterializeJson(ref GescChunk chunk, out string err) {
    if (chunk.componentBlocks.length == 0)
        return true;
    GescTypeSchema[] schemas;
    if (!parseTypesBlock(chunk.typesBlock, schemas, err))
        return false;
    StringTable strings;
    TypeRegistry reg;
    foreach (ref t; schemas) {
        reg.registerRuntime(t.name, t.size, t.alignment, t.fields, strings);
    }
    foreach (payload; chunk.componentBlocks) {
        auto nameReader = Reader(payload);
        immutable name = nameReader.str();
        const(GescTypeSchema)* src;
        foreach (ref t; schemas)
            if (t.name == name)
                src = &t;
        if (nameReader.bad || src is null) {
            err = "bad component block";
            return false;
        }
        GescComponentBlock b;
        if (!parseComponentBlock(payload, src.size, b, err))
            return false;
        immutable tid = reg.find(name, strings);
        auto bytes = convertRecords(*src, b, reg, tid, strings, null);
        foreach (i; 0 .. b.count) {
            immutable ix = b.indexAt(i);
            if (ix >= chunk.scene.entities.length) {
                err = "component entity index out of range";
                return false;
            }
            chunk.scene.entities[ix].customComponents ~= SceneComponentData(name,
                serializeComponent(reg, tid, bytes[i * src.size .. (i + 1) * src.size], strings));
        }
    }
    chunk.typesBlock = null;
    chunk.componentBlocks = null;
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) {
    import std.conv : to;
    import std.json : parseJSON, toJSON;
    import engine.math.vec : Vec3;
    import engine.reflect.attrs : entityRef, formerlyNamed;

    private SceneFile componentScene(size_t n) {
        SceneFile s;
        s.schemaVersion = sceneSchemaVersionV2;
        s.meta.name = "chunk_0_0";
        foreach (i; 0 .. n) {
            SceneEntityData e;
            e.id = cast(uint)(100 + i);
            e.parent = sceneNoParent;
            e.transform.rot = [0, 0, 0, 1];
            e.transform.scale = [1, 1, 1];
            if (i % 2 == 0)
                e.customComponents ~= SceneComponentData("Door", parseJSON(
                    `{"angle":` ~ (i % 4 == 0 ? "0.25" : "1.5") ~ `,"kind":` ~ (i % 3 == 0 ? "7" : "2")
                    ~ `,"label":"door_` ~ (i % 3 == 0 ? "a" : "b") ~ `","target":` ~ (i + 101).to!string ~ `,"pos":[1,2,3]}`));
            if (i % 5 == 0)
                e.customComponents ~= SceneComponentData("Unknown.Thing", parseJSON(`{"x":1}`));
            s.entities ~= e;
        }
        return s;
    }

    private EntityId[] spawnFor(ref SceneWorld w, ref const SceneFile s, out EntityId[uint] fileIds) {
        auto ids = w.spawnBatch(s.entities.length);
        foreach (i, ref e; s.entities)
            fileIds[e.id] = ids[i];
        return ids;
    }
}

@("chunkComponents.roundTripSameLayout") unittest {
    static struct Door {
        float angle = 0.5f;
        uint kind = 1;
        StringId label;
        @entityRef uint target = EntityId.max;
        Vec3 pos;
    }
    auto scene = componentScene(39);
    SceneWorld writer;
    writer.ensureRegistered!Door();
    auto bytes = encodeChunkWithComponents(scene, writer.types, writer.strings);
    assert(bytes[4] == 2, "binary components stamp version 2");

    GescChunk c;
    string err;
    assert(decodeChunk(bytes, c, err), err);
    // Door went to binary blocks; the unregistered type stayed in the JSON block
    assert(c.componentBlocks.length == 1);
    foreach (ref e; c.scene.entities)
        foreach (ref cc; e.customComponents)
            assert(cc.typeName == "Unknown.Thing");

    // The reading world has a different string table state, so StringIds differ from the writer's.
    SceneWorld w;
    w.strings.intern("padding_1");
    w.strings.intern("padding_2");
    w.ensureRegistered!Door();
    EntityId[uint] fileIds;
    // shift live ids so file ids != live ids
    foreach (_; 0 .. 7)
        w.spawn();
    auto ids = spawnFor(w, c.scene, fileIds);
    GescApplyResult res;
    assert(applyGescComponents(w, c, ids, fileIds, res, err), err);
    assert(res.blocksApplied == 1 && res.componentsApplied == 20 && res.unresolvedTypes.length == 0);
    foreach (i, ref e; scene.entities) {
        if (i % 2 != 0) {
            assert(!w.has!Door(ids[i]));
            continue;
        }
        auto d = w.get!Door(ids[i]);
        assert(d.angle == (i % 4 == 0 ? 0.25f : 1.5f));
        assert(d.kind == (i % 3 == 0 ? 7 : 2));
        assert(w.strings.get(d.label) == (i % 3 == 0 ? "door_a" : "door_b"));
        if (i + 1 < ids.length)
            assert(d.target == ids[i + 1], "entity ref remapped to the live entity");
        else
            assert(d.target == EntityId.max, "a file id that is not in the chunk becomes EntityId.max");
        assert(d.pos == Vec3(1, 2, 3));
    }
    // decode -> JSON again for tooling: values equal the source JSON
    assert(gescMaterializeJson(c, err), err);
    foreach (i, ref e; scene.entities) {
        if (i % 2 != 0)
            continue;
        bool seen;
        foreach (ref cc; c.scene.entities[i].customComponents)
            if (cc.typeName == "Door") {
                seen = true;
                assert(cc.data["kind"].integer == (i % 3 == 0 ? 7 : 2));
                assert(cc.data["label"].str == (i % 3 == 0 ? "door_a" : "door_b"));
                assert(cc.data["target"].integer == i + 101);
            }
        assert(seen);
    }
    // deterministic
    assert(encodeChunkWithComponents(scene, writer.types, writer.strings) == bytes);
}

@("chunkComponents.oldAndAllJsonChunksStillWork") unittest {
    static struct Other {
        float angle = 0.5f;
        uint kind = 1;
    }
    auto scene = componentScene(10);
    // plain encodeChunk: version 1, JSON components, no binary blocks
    auto v1 = encodeChunk(scene);
    assert(v1[4] == 1);
    GescChunk c;
    string err;
    assert(decodeChunk(v1, c, err), err);
    assert(c.componentBlocks.length == 0 && c.scene.entities[0].customComponents.length == 2);
    SceneWorld w;
    EntityId[uint] fileIds;
    auto ids = spawnFor(w, c.scene, fileIds);
    GescApplyResult res;
    assert(applyGescComponents(w, c, ids, fileIds, res, err) && res.blocksApplied == 0);
    // registry that knows no scene type: nothing cooked, same bytes as encodeChunk, still version 1
    SceneWorld empty;
    empty.ensureRegistered!Other();
    assert(encodeChunkWithComponents(scene, empty.types, empty.strings) == v1);
    assert(GESC_VERSION_BASE == 1 && GESC_VERSION == 2);
}

@("chunkComponents.differentLayout") unittest {
    // Writer's layout
    SceneWorld writer;
    {
        static struct Door {
            float angle = 0.5f;     // renamed in the reader
            uint kind = 1;          // changes type in the reader (uint -> float)
            uint removed = 9;       // absent in the reader
            StringId label;
        }
        writer.ensureRegistered!Door();
    }
    SceneFile scene;
    scene.schemaVersion = sceneSchemaVersionV2;
    foreach (i; 0 .. 6) {
        SceneEntityData e;
        e.id = cast(uint)(i + 1);
        e.parent = sceneNoParent;
        e.customComponents ~= SceneComponentData("Door", parseJSON(
            `{"angle":` ~ (i * 0.5).to!string ~ `,"kind":` ~ i.to!string ~ `,"removed":77,"label":"L` ~ i.to!string ~ `"}`));
        scene.entities ~= e;
    }
    auto bytes = encodeChunkWithComponents(scene, writer.types, writer.strings);
    GescChunk c;
    string err;
    assert(decodeChunk(bytes, c, err), err);

    static struct Door {                     // same name, different layout
        uint pad = 123;                      // added field keeps its default
        @formerlyNamed("angle") float openAngle = 9;
        float kind = -1;                     // numeric conversion uint -> float
        StringId label;
        float added = 4.5f;
    }
    SceneWorld w;
    w.strings.intern("shift");
    w.ensureRegistered!Door();
    EntityId[uint] fileIds;
    auto ids = spawnFor(w, c.scene, fileIds);
    GescApplyResult res;
    assert(applyGescComponents(w, c, ids, fileIds, res, err), err);
    assert(res.componentsApplied == 6);
    foreach (i; 0 .. 6) {
        auto d = w.get!Door(ids[i]);
        assert(d.pad == 123 && d.added == 4.5f);
        assert(d.openAngle == i * 0.5f);
        assert(d.kind == i);
        assert(w.strings.get(d.label) == "L" ~ i.to!string);
    }
}

@("chunkComponents.unknownTypeAndTruncation") unittest {
    static struct Door {
        float angle = 0.5f;
        uint kind = 1;
        StringId label;
        @entityRef uint target = EntityId.max;
        Vec3 pos;
    }
    SceneWorld writer;
    writer.ensureRegistered!Door();
    auto scene = componentScene(12);
    auto bytes = encodeChunkWithComponents(scene, writer.types, writer.strings);
    GescChunk c;
    string err;
    assert(decodeChunk(bytes, c, err), err);

    // reader world without Door: reported, entities untouched, no failure
    SceneWorld w;
    EntityId[uint] fileIds;
    auto ids = spawnFor(w, c.scene, fileIds);
    GescApplyResult res;
    assert(applyGescComponents(w, c, ids, fileIds, res, err), err);
    assert(res.unresolvedTypes == ["Door"] && res.unresolvedComponents == 6 && res.blocksApplied == 0);

    // every truncation that cuts into data fails cleanly
    foreach (n; 0 .. bytes.length - 16) {
        if (n % 5 != 0)
            continue;
        GescChunk t;
        assert(!decodeChunk(bytes[0 .. n], t, err));
    }
    // random flips are caught by the block CRCs (or decode to something valid): never a crash
    import std.random : Random, uniform;
    auto rng = Random(11);
    foreach (_; 0 .. 300) {
        auto bad = bytes.dup;
        bad[uniform(0, cast(uint) bad.length, rng)] ^= cast(ubyte)(1 + uniform(0, 255, rng));
        GescChunk t;
        if (decodeChunk(bad, t, err)) {
            SceneWorld w2;
            w2.ensureRegistered!Door();
            EntityId[uint] f2;
            auto i2 = spawnFor(w2, t.scene, f2);
            GescApplyResult r2;
            applyGescComponents(w2, t, i2, f2, r2, err);
        }
    }

    // malformed payloads that pass the CRC (a buggy writer): rejected at apply, never trusted
    SceneWorld w3;
    w3.ensureRegistered!Door();
    EntityId[uint] f3;
    auto i3 = spawnFor(w3, c.scene, f3);
    GescChunk bad = c;
    auto p = bad.componentBlocks[0].dup;
    bad.componentBlocks = [p[0 .. $ - 1]];                                  // size mismatch
    assert(!applyGescComponents(w3, bad, i3, f3, res, err));
    auto short_ = i3[0 .. 2];                                               // entity index out of range
    assert(!applyGescComponents(w3, c, short_, f3, res, err));
    bad.componentBlocks = [p];
    bad.typesBlock = bad.typesBlock[0 .. $ / 2];                            // truncated schema
    assert(!applyGescComponents(w3, bad, i3, f3, res, err));
    bad.typesBlock = null;                                                  // component without schema
    assert(!applyGescComponents(w3, bad, i3, f3, res, err));
}

@("chunkComponents.infoListsComponentBlocks") unittest {
    static struct Door { float angle = 0.5f; uint kind = 1; }
    SceneWorld writer;
    writer.ensureRegistered!Door();
    auto sc = componentScene(8);
    auto bytes = encodeChunkWithComponents(sc, writer.types, writer.strings, [GescUserBlock("u", [1, 2, 3])]);
    GescBlockInfo[] info;
    string err;
    assert(gescInfo(bytes, info, err), err);
    bool sawTypes, sawComp;
    foreach (i; info) {
        sawTypes |= i.kind == GescBlockKind.types;
        if (i.kind == GescBlockKind.component) {
            sawComp = true;
            assert(i.userName == "Door");
        }
    }
    assert(sawTypes && sawComp && info[$ - 1].kind == GescBlockKind.user);
}

@("chunkComponents.applyChunkMixesBinaryAndJson") unittest {
    import engine.scene.graph : Transform;
    static struct Door {
        float angle = 0.5f;
        uint kind = 1;
    }
    static struct Lamp {
        float power = 1;
    }
    auto scene = componentScene(10);                 // "Door" and "Unknown.Thing"
    foreach (i, ref e; scene.entities)
        if (i % 3 == 0)
            e.customComponents ~= SceneComponentData("Lamp", parseJSON(`{"power":4}`));
    SceneWorld writer;
    writer.ensureRegistered!Door();                  // only Door is cooked; Lamp stays JSON
    auto bytes = encodeChunkWithComponents(scene, writer.types, writer.strings);
    GescChunk c;
    string err;
    assert(decodeChunk(bytes, c, err), err);

    SceneWorld w;
    w.ensureRegistered!Door();
    w.ensureRegistered!Lamp();
    SceneLoadOptions opts;
    opts.validate = false;
    opts.checkAssetFiles = false;
    GescApplyResult comps;
    auto res = applyChunk(w, c, Vec3(0, 0, 0), opts, comps);
    assert(res.spawnedEntities.length == 10 && comps.componentsApplied == 5);
    foreach (i, id; res.spawnedEntities) {
        assert(w.has!Transform(id));
        assert(w.has!Door(id) == (i % 2 == 0));
        assert(w.has!Lamp(id) == (i % 3 == 0));
    }
    assert(res.unresolvedComponents.length == 2);    // the two "Unknown.Thing" entities (i = 0, 5)
}

@("chunkComponents.malformedJsonStaysJson") unittest {
    static struct Door {
        float angle = 0.5f;
        Vec3 pos;
    }
    SceneWorld writer;
    writer.ensureRegistered!Door();
    SceneFile s;
    s.schemaVersion = sceneSchemaVersionV2;
    foreach (i; 0 .. 2) {
        SceneEntityData e;
        e.id = cast(uint)(i + 1);
        e.parent = sceneNoParent;
        e.customComponents ~= SceneComponentData("Door", parseJSON(i == 0 ? `{"angle":2,"pos":[1,2,3]}` : `{"pos":["a","b","c"]}`));
        s.entities ~= e;
    }
    GescChunk c;
    string err;
    assert(decodeChunk(encodeChunkWithComponents(s, writer.types, writer.strings), c, err), err);
    assert(c.componentBlocks.length == 1 && c.scene.entities[0].customComponents.length == 0);
    assert(c.scene.entities[1].customComponents.length == 1);
}
