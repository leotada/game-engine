/// Reflection-guided serialization of component POD data to/from JSON.
module engine.reflect.serialize;

import std.json;
import engine.core.strings : StringId, StringTable;
import engine.math.vec : Vec2, Vec3, Vec4;
import engine.math.quat : Quat;
import engine.graphics.types : Color4;
import engine.reflect.attrs;
import engine.reflect.descriptor;

@safe:

/// Maps an entity id stored in an `@entityRef` field while (de)serializing.
alias EntityIdMap = uint delegate(uint id) @safe;

/// Serializes component binary data to a JSON object using its registered TypeDescriptor.
/// `mapEntity` translates `@entityRef` values (scene files store file-local ids); null writes them as they are.
JSONValue serializeComponent(
    ref const TypeRegistry reg,
    ComponentTypeId typeId,
    const(ubyte)[] data,
    ref const StringTable strings,
    scope EntityIdMap mapEntity = null
) {
    return serializeFields(reg, reg.getFields(typeId), data, strings, mapEntity);
}

private JSONValue serializeFields(
    ref const TypeRegistry reg,
    scope const(FieldDescriptor)[] fields,
    const(ubyte)[] data,
    ref const StringTable strings,
    scope EntityIdMap mapEntity
) @trusted {
    JSONValue root = JSONValue(string[string].init);
    foreach (ref const f; fields) {
        if (cast(size_t) f.offset + f.size > data.length) continue;
        JSONValue v;
        if (serializeValue(reg, f, f.kind, data[f.offset .. f.offset + f.size], strings, mapEntity, v))
            root[strings.get(f.name).idup] = v;
    }
    return root;
}

/// Serializes one value of `kind` (the field itself, or one element of a fixed array). Returns false when the kind
/// has no JSON form (unknown, or a struct without a nested description, as in runtime-registered types).
private bool serializeValue(
    ref const TypeRegistry reg,
    ref const FieldDescriptor f,
    FieldKind kind,
    const(ubyte)[] bytes,
    ref const StringTable strings,
    scope EntityIdMap mapEntity,
    out JSONValue result
) @trusted {
    const(ubyte)* ptr = bytes.ptr;

    static JSONValue floats(const(ubyte)* p, size_t n) {
        auto v = cast(const(float)*) p;
        JSONValue[] arr;
        foreach (i; 0 .. n) arr ~= JSONValue(v[i]);
        return JSONValue(arr);
    }

    final switch (kind) {
        case FieldKind.unknown: return false;
        case FieldKind.f32: result = JSONValue(cast(double) *cast(const(float)*) ptr); return true;
        case FieldKind.f64: result = JSONValue(*cast(const(double)*) ptr); return true;
        case FieldKind.i8: result = JSONValue(cast(long) *cast(const(byte)*) ptr); return true;
        case FieldKind.i16: result = JSONValue(cast(long) *cast(const(short)*) ptr); return true;
        case FieldKind.i32: result = JSONValue(cast(long) *cast(const(int)*) ptr); return true;
        case FieldKind.i64: result = JSONValue(*cast(const(long)*) ptr); return true;
        case FieldKind.u8: result = JSONValue(cast(long) *ptr); return true;
        case FieldKind.u16: result = JSONValue(cast(long) *cast(const(ushort)*) ptr); return true;
        case FieldKind.u32: result = JSONValue(cast(long) *cast(const(uint)*) ptr); return true;
        case FieldKind.u64: result = JSONValue(cast(long) *cast(const(ulong)*) ptr); return true;
        case FieldKind.bool_: result = JSONValue(*cast(const(bool)*) ptr); return true;
        case FieldKind.vec2: result = floats(ptr, 2); return true;
        case FieldKind.vec3: result = floats(ptr, 3); return true;
        case FieldKind.vec4: result = floats(ptr, 4); return true;
        case FieldKind.color: result = floats(ptr, 4); return true;
        case FieldKind.quat:
            auto q = cast(const(Quat)*) ptr;
            result = JSONValue([JSONValue(q.x), JSONValue(q.y), JSONValue(q.z), JSONValue(q.w)]);
            return true;
        case FieldKind.stringId:
            result = JSONValue(strings.get(*cast(const(StringId)*) ptr).idup);
            return true;
        case FieldKind.enum_:
            // The base type decides the size; 1 and 2 byte enums are read unsigned.
            switch (bytes.length) {
                case 1: result = JSONValue(cast(long) *ptr); return true;
                case 2: result = JSONValue(cast(long) *cast(const(ushort)*) ptr); return true;
                case 4: result = JSONValue(cast(long) *cast(const(int)*) ptr); return true;
                case 8: result = JSONValue(*cast(const(long)*) ptr); return true;
                default: return false;
            }
        case FieldKind.entityRef:
            immutable id = *cast(const(uint)*) ptr;
            result = JSONValue(cast(long)(mapEntity is null ? id : mapEntity(id)));
            return true;
        case FieldKind.assetRef: result = JSONValue(cast(long) *cast(const(uint)*) ptr); return true;
        case FieldKind.fixedArray:
            if (f.elemSize == 0) return false;
            JSONValue[] arr;
            for (size_t o = 0; o + f.elemSize <= bytes.length; o += f.elemSize) {
                JSONValue e;
                if (!serializeValue(reg, f, f.elemKind, bytes[o .. o + f.elemSize], strings, mapEntity, e))
                    return false;
                arr ~= e;
            }
            result = JSONValue(arr);
            return true;
        case FieldKind.struct_:
            if (f.typeIndex == 0) return false;
            result = serializeFields(reg, reg.getNestedFields(f.typeIndex), bytes, strings, mapEntity);
            return true;
    }
}

/// Deserializes JSON data into a component memory buffer, falling back to defaults for missing fields.
/// `mapEntity` translates `@entityRef` values (file-local to live ids); null stores them as they are.
void deserializeComponent(
    ref const TypeRegistry reg,
    ComponentTypeId typeId,
    ref const(JSONValue) json,
    ubyte[] outData,
    ref StringTable strings,
    scope EntityIdMap mapEntity = null
) {
    auto defs = reg.getDefaults(typeId);
    if (defs.length > 0 && outData.length >= defs.length)
        outData[0 .. defs.length] = defs[];
    deserializeFields(reg, reg.getFields(typeId), json, outData, strings, mapEntity);
}

private void deserializeFields(
    ref const TypeRegistry reg,
    scope const(FieldDescriptor)[] fields,
    ref const(JSONValue) json,
    ubyte[] outData,
    ref StringTable strings,
    scope EntityIdMap mapEntity
) @trusted {
    if (json.type != JSONType.object) return;

    foreach (key, ref const val; json.object) {
        const(FieldDescriptor)* targetField = null;
        foreach (ref const f; fields) {
            if (strings.get(f.name) == key) {
                targetField = &f;
                break;
            }
            if (!f.attrs.formerlyNamed.isNull() && strings.get(f.attrs.formerlyNamed) == key) {
                targetField = &f;
                break;
            }
        }

        if (targetField is null) continue;
        immutable size_t start = targetField.offset;
        if (start + targetField.size > outData.length) continue;
        deserializeValue(reg, *targetField, targetField.kind, val, outData[start .. start + targetField.size],
            strings, mapEntity);
    }
}

private bool isNumber(ref const(JSONValue) v) @safe {
    return v.type == JSONType.float_ || v.type == JSONType.integer || v.type == JSONType.uinteger;
}

/// Malformed vector data is an error (chunk writers keep such components as JSON).
private void enforceNumber(ref const(JSONValue) v) @safe {
    if (!isNumber(v))
        throw new JSONException("expected a number in a vector field");
}

private double toDouble(ref const(JSONValue) v) @trusted {
    if (v.type == JSONType.float_) return v.floating;
    return v.type == JSONType.uinteger ? cast(double) v.uinteger : cast(double) v.integer;
}

/// True (and the value) for a JSON integer, including the unsigned range above `long.max`.
private bool toInteger(ref const(JSONValue) v, out long result) @trusted {
    if (v.type == JSONType.integer) { result = v.integer; return true; }
    if (v.type == JSONType.uinteger) { result = cast(long) v.uinteger; return true; }
    return false;
}

private void deserializeValue(
    ref const TypeRegistry reg,
    ref const FieldDescriptor f,
    FieldKind kind,
    ref const(JSONValue) val,
    ubyte[] dst,
    ref StringTable strings,
    scope EntityIdMap mapEntity
) @trusted {
    ubyte* ptr = dst.ptr;
    long n;

    static void floats(ref const(JSONValue) v, ubyte* p, size_t count) {
        if (v.type != JSONType.array || v.array.length < count) return;
        foreach (i; 0 .. count)
            enforceNumber(v.array[i]);
        foreach (i; 0 .. count)
            (cast(float*) p)[i] = cast(float) toDouble(v.array[i]);
    }

    final switch (kind) {
        case FieldKind.unknown: break;
        case FieldKind.f32: if (isNumber(val)) *cast(float*) ptr = cast(float) toDouble(val); break;
        case FieldKind.f64: if (isNumber(val)) *cast(double*) ptr = toDouble(val); break;
        case FieldKind.i8:
        case FieldKind.u8: if (toInteger(val, n)) *ptr = cast(ubyte) n; break;
        case FieldKind.i16:
        case FieldKind.u16: if (toInteger(val, n)) *cast(ushort*) ptr = cast(ushort) n; break;
        case FieldKind.i32:
        case FieldKind.u32: if (toInteger(val, n)) *cast(uint*) ptr = cast(uint) n; break;
        case FieldKind.i64:
        case FieldKind.u64: if (toInteger(val, n)) *cast(long*) ptr = n; break;
        case FieldKind.bool_:
            if (val.type == JSONType.true_) *cast(bool*) ptr = true;
            else if (val.type == JSONType.false_) *cast(bool*) ptr = false;
            break;
        case FieldKind.vec2: floats(val, ptr, 2); break;
        case FieldKind.vec3: floats(val, ptr, 3); break;
        case FieldKind.vec4:
        case FieldKind.color: floats(val, ptr, 4); break;
        case FieldKind.quat:
            if (val.type == JSONType.array && val.array.length >= 4) {
                foreach (i; 0 .. 4)
                    enforceNumber(val.array[i]);
                auto q = cast(Quat*) ptr;
                q.x = cast(float) toDouble(val.array[0]);
                q.y = cast(float) toDouble(val.array[1]);
                q.z = cast(float) toDouble(val.array[2]);
                q.w = cast(float) toDouble(val.array[3]);
            }
            break;
        case FieldKind.stringId:
            if (val.type == JSONType.string)
                *cast(StringId*) ptr = strings.intern(val.str);
            break;
        case FieldKind.enum_:
            if (!toInteger(val, n)) break;
            switch (dst.length) {
                case 1: *ptr = cast(ubyte) n; break;
                case 2: *cast(ushort*) ptr = cast(ushort) n; break;
                case 4: *cast(uint*) ptr = cast(uint) n; break;
                case 8: *cast(long*) ptr = n; break;
                default: break;
            }
            break;
        case FieldKind.entityRef:
            if (toInteger(val, n))
                *cast(uint*) ptr = mapEntity is null ? cast(uint) n : mapEntity(cast(uint) n);
            break;
        case FieldKind.assetRef:
            if (toInteger(val, n)) *cast(uint*) ptr = cast(uint) n;
            break;
        case FieldKind.fixedArray:
            if (val.type != JSONType.array || f.elemSize == 0) break;
            size_t o = 0;
            foreach (ref const e; val.array) {
                if (o + f.elemSize > dst.length) break;
                deserializeValue(reg, f, f.elemKind, e, dst[o .. o + f.elemSize], strings, mapEntity);
                o += f.elemSize;
            }
            break;
        case FieldKind.struct_:
            deserializeFields(reg, reg.getNestedFields(f.typeIndex), val, dst, strings, mapEntity);
            break;
    }
}

@trusted unittest {
    static struct Config {
        float speed = 10.0f;
        Vec3 direction = Vec3(0, 1, 0);
        bool enabled = true;
        @formerlyNamed("oldTag") StringId tag;
    }

    StringTable strings;
    TypeRegistry reg;
    immutable typeId = reg.register!Config(strings);

    Config cfg;
    cfg.speed = 42.5f;
    cfg.direction = Vec3(1, 2, 3);
    cfg.enabled = false;
    cfg.tag = strings.intern("hero");

    ubyte[] asBytes(T)(ref T val) @trusted {
        auto p = cast(ubyte*) &val;
        return p[0 .. T.sizeof];
    }

    auto json = serializeComponent(reg, typeId, asBytes(cfg), strings);
    assert(json["speed"].floating == 42.5);
    assert(json["enabled"].type == JSONType.false_);
    assert(json["direction"].array[0].floating == 1.0);
    assert(json["tag"].str == "hero");

    // Test deserialize with migration of formerlyNamed
    string jsonText = `{"speed": 99.0, "oldTag": "migrated", "direction": [4.0, 5.0, 6.0]}`;
    auto parsed = parseJSON(jsonText);

    Config restored;
    deserializeComponent(reg, typeId, parsed, asBytes(restored), strings);
    assert(restored.speed == 99.0f);
    assert(restored.direction == Vec3(4, 5, 6));
    assert(restored.enabled == true); // kept default!
    assert(strings.get(restored.tag) == "migrated"); // successfully migrated from oldTag!
}

version (unittest) {
    private enum SmallKind : ubyte { a, b, c }
    private enum WideKind : ulong { x = 1, y = 0x1_0000_0001 }
    private struct SerInner { float a = 1; StringId tag; SmallKind[3] kinds; }
    private struct SerOuter {
        SmallKind kind = SmallKind.a;
        ubyte n1 = 11, n2 = 22, n3 = 33;
        WideKind wide = WideKind.x;
        SerInner inner;
        int[4] arr = [1, 2, 3, 4];
        SerInner[2] pair;
        ulong big = 0;
        @entityRef uint target = uint.max;
        @entityRef uint lastRef = 7;
    }
}

@("serialize: enum sizes, nested structs, fixed arrays and entity refs round-trip")
@trusted unittest {
    StringTable strings;
    TypeRegistry reg;
    immutable tid = reg.register!SerOuter(strings);
    static ubyte[] raw(T)(ref T v) { return (cast(ubyte*) &v)[0 .. T.sizeof]; }

    SerOuter o;
    o.kind = SmallKind.c;
    o.wide = WideKind.y;
    o.inner.a = 9;
    o.inner.tag = strings.intern("tag");
    o.inner.kinds = [SmallKind.b, SmallKind.c, SmallKind.a];
    o.arr = [9, 8, -7, 6];
    o.pair[1].a = 5;
    o.big = ulong.max;
    o.target = 41;

    auto json = serializeComponent(reg, tid, raw(o), strings);
    assert(json["kind"].integer == 2);
    auto text = parseJSON(json.toString());
    SerOuter back;
    deserializeComponent(reg, tid, text, raw(back), strings);
    assert(back.kind == SmallKind.c && back.n1 == 11 && back.n2 == 22 && back.n3 == 33);
    assert(back.wide == WideKind.y && back.inner == o.inner && back.arr == o.arr && back.pair == o.pair);
    assert(back.big == ulong.max && back.target == 41);

    // A partial object must not touch the neighbours of the enum.
    auto partial = parseJSON(`{"kind": 1, "arr": [100], "inner": {"a": 3}}`);
    SerOuter p;
    deserializeComponent(reg, tid, partial, raw(p), strings);
    assert(p.kind == SmallKind.b && p.n1 == 11 && p.n2 == 22 && p.n3 == 33);
    assert(p.arr == [100, 2, 3, 4] && p.inner.a == 3 && p.inner.kinds == SerInner.init.kinds);

    auto mapped = serializeComponent(reg, tid, raw(o), strings, (uint id) => id == 41 ? 2 : 0);
    assert(mapped["target"].integer == 2 && mapped["lastRef"].integer == 0);
    SerOuter live;
    deserializeComponent(reg, tid, mapped, raw(live), strings, (uint id) => id == 2 ? 900 : uint.max);
    assert(live.target == 900 && live.lastRef == uint.max);
}

@("registry: a stale type is hidden and re-registered with the new layout; name collisions are rejected")
@safe unittest {
    struct V1 { static struct Health { int hp = 100; } }
    struct V2 { static struct Health { int hp = 100; int shield = 7; float[3] extra = [1, 2, 3]; } }
    StringTable strings;
    TypeRegistry reg;
    immutable a = reg.register!(V1.Health)(strings);
    bool threw;
    try reg.register!(V2.Health)(strings);
    catch (Exception) threw = true;
    assert(threw);

    reg.markStale(a);
    assert(reg.find("Health", strings) == invalidComponentTypeId);
    immutable b = reg.register!(V2.Health)(strings);
    assert(b == a && reg.getType(b).size == V2.Health.sizeof);
    assert(reg.getFields(b).length == 3 && reg.getDefaults(b).length == V2.Health.sizeof);
    assert(reg.find("Health", strings) == b);
}
