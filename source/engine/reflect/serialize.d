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

/// Serializes component binary data to a JSON object using its registered TypeDescriptor.
JSONValue serializeComponent(
    ref const TypeRegistry reg,
    ComponentTypeId typeId,
    const(ubyte)[] data,
    ref const StringTable strings
) @trusted {
    JSONValue root = JSONValue(string[string].init);
    auto fields = reg.getFields(typeId);

    foreach (ref const f; fields) {
        if (f.offset + f.size > data.length) continue;
        string fname = cast(string) strings.get(f.name);
        const(ubyte)* ptr = data.ptr + f.offset;

        final switch (f.kind) {
            case FieldKind.unknown:
                break;
            case FieldKind.f32:
                root[fname] = JSONValue(cast(double) *cast(const(float)*) ptr);
                break;
            case FieldKind.f64:
                root[fname] = JSONValue(*cast(const(double)*) ptr);
                break;
            case FieldKind.i8:
                root[fname] = JSONValue(cast(long) *cast(const(byte)*) ptr);
                break;
            case FieldKind.i16:
                root[fname] = JSONValue(cast(long) *cast(const(short)*) ptr);
                break;
            case FieldKind.i32:
                root[fname] = JSONValue(cast(long) *cast(const(int)*) ptr);
                break;
            case FieldKind.i64:
                root[fname] = JSONValue(*cast(const(long)*) ptr);
                break;
            case FieldKind.u8:
                root[fname] = JSONValue(cast(long) *cast(const(ubyte)*) ptr);
                break;
            case FieldKind.u16:
                root[fname] = JSONValue(cast(long) *cast(const(ushort)*) ptr);
                break;
            case FieldKind.u32:
                root[fname] = JSONValue(cast(long) *cast(const(uint)*) ptr);
                break;
            case FieldKind.u64:
                root[fname] = JSONValue(cast(long) *cast(const(ulong)*) ptr);
                break;
            case FieldKind.bool_:
                root[fname] = JSONValue(*cast(const(bool)*) ptr);
                break;
            case FieldKind.vec2:
                auto v = cast(const(float)*) ptr;
                root[fname] = JSONValue([JSONValue(v[0]), JSONValue(v[1])]);
                break;
            case FieldKind.vec3:
                auto v = cast(const(float)*) ptr;
                root[fname] = JSONValue([JSONValue(v[0]), JSONValue(v[1]), JSONValue(v[2])]);
                break;
            case FieldKind.vec4:
                auto v = cast(const(float)*) ptr;
                root[fname] = JSONValue([JSONValue(v[0]), JSONValue(v[1]), JSONValue(v[2]), JSONValue(v[3])]);
                break;
            case FieldKind.quat:
                auto q = cast(const(Quat)*) ptr;
                root[fname] = JSONValue([JSONValue(q.x), JSONValue(q.y), JSONValue(q.z), JSONValue(q.w)]);
                break;
            case FieldKind.color:
                auto c = cast(const(float)*) ptr;
                root[fname] = JSONValue([JSONValue(c[0]), JSONValue(c[1]), JSONValue(c[2]), JSONValue(c[3])]);
                break;
            case FieldKind.stringId:
                auto sid = *cast(const(StringId)*) ptr;
                root[fname] = JSONValue(cast(string) strings.get(sid));
                break;
            case FieldKind.enum_:
                root[fname] = JSONValue(cast(long) *cast(const(int)*) ptr);
                break;
            case FieldKind.entityRef:
                root[fname] = JSONValue(cast(long) *cast(const(uint)*) ptr);
                break;
            case FieldKind.assetRef:
                root[fname] = JSONValue(cast(long) *cast(const(uint)*) ptr);
                break;
            case FieldKind.fixedArray:
            case FieldKind.struct_:
                break;
        }
    }

    return root;
}

/// Deserializes JSON data into a component memory buffer, falling back to defaults for missing fields.
void deserializeComponent(
    ref const TypeRegistry reg,
    ComponentTypeId typeId,
    ref const(JSONValue) json,
    ubyte[] outData,
    ref StringTable strings
) @trusted {
    auto defs = reg.getDefaults(typeId);
    if (defs.length > 0 && outData.length >= defs.length)
        outData[0 .. defs.length] = defs[];

    if (json.type != JSONType.object) return;
    auto fields = reg.getFields(typeId);

    foreach (key, val; json.object) {
        const(FieldDescriptor)* targetField = null;
        foreach (ref const f; fields) {
            string fname = cast(string) strings.get(f.name);
            if (fname == key) {
                targetField = &f;
                break;
            }
            if (!f.attrs.formerlyNamed.isNull()) {
                string oldName = cast(string) strings.get(f.attrs.formerlyNamed);
                if (oldName == key) {
                    targetField = &f;
                    break;
                }
            }
        }

        if (targetField is null) continue;
        if (targetField.offset + targetField.size > outData.length) continue;
        ubyte* ptr = outData.ptr + targetField.offset;

        final switch (targetField.kind) {
            case FieldKind.unknown:
                break;
            case FieldKind.f32:
                if (val.type == JSONType.float_ || val.type == JSONType.integer)
                    *cast(float*) ptr = val.type == JSONType.float_ ? cast(float) val.floating : cast(float) val.integer;
                break;
            case FieldKind.f64:
                if (val.type == JSONType.float_ || val.type == JSONType.integer)
                    *cast(double*) ptr = val.type == JSONType.float_ ? val.floating : cast(double) val.integer;
                break;
            case FieldKind.i8:
                if (val.type == JSONType.integer) *cast(byte*) ptr = cast(byte) val.integer;
                break;
            case FieldKind.i16:
                if (val.type == JSONType.integer) *cast(short*) ptr = cast(short) val.integer;
                break;
            case FieldKind.i32:
                if (val.type == JSONType.integer) *cast(int*) ptr = cast(int) val.integer;
                break;
            case FieldKind.i64:
                if (val.type == JSONType.integer) *cast(long*) ptr = val.integer;
                break;
            case FieldKind.u8:
                if (val.type == JSONType.integer) *cast(ubyte*) ptr = cast(ubyte) val.integer;
                break;
            case FieldKind.u16:
                if (val.type == JSONType.integer) *cast(ushort*) ptr = cast(ushort) val.integer;
                break;
            case FieldKind.u32:
                if (val.type == JSONType.integer) *cast(uint*) ptr = cast(uint) val.integer;
                break;
            case FieldKind.u64:
                if (val.type == JSONType.integer) *cast(ulong*) ptr = cast(ulong) val.integer;
                break;
            case FieldKind.bool_:
                if (val.type == JSONType.true_) *cast(bool*) ptr = true;
                else if (val.type == JSONType.false_) *cast(bool*) ptr = false;
                break;
            case FieldKind.vec2:
                if (val.type == JSONType.array && val.array.length >= 2) {
                    auto v = cast(float*) ptr;
                    v[0] = cast(float)(val.array[0].type == JSONType.float_ ? val.array[0].floating : val.array[0].integer);
                    v[1] = cast(float)(val.array[1].type == JSONType.float_ ? val.array[1].floating : val.array[1].integer);
                }
                break;
            case FieldKind.vec3:
                if (val.type == JSONType.array && val.array.length >= 3) {
                    auto v = cast(float*) ptr;
                    v[0] = cast(float)(val.array[0].type == JSONType.float_ ? val.array[0].floating : val.array[0].integer);
                    v[1] = cast(float)(val.array[1].type == JSONType.float_ ? val.array[1].floating : val.array[1].integer);
                    v[2] = cast(float)(val.array[2].type == JSONType.float_ ? val.array[2].floating : val.array[2].integer);
                }
                break;
            case FieldKind.vec4:
            case FieldKind.color:
                if (val.type == JSONType.array && val.array.length >= 4) {
                    auto v = cast(float*) ptr;
                    v[0] = cast(float)(val.array[0].type == JSONType.float_ ? val.array[0].floating : val.array[0].integer);
                    v[1] = cast(float)(val.array[1].type == JSONType.float_ ? val.array[1].floating : val.array[1].integer);
                    v[2] = cast(float)(val.array[2].type == JSONType.float_ ? val.array[2].floating : val.array[2].integer);
                    v[3] = cast(float)(val.array[3].type == JSONType.float_ ? val.array[3].floating : val.array[3].integer);
                }
                break;
            case FieldKind.quat:
                if (val.type == JSONType.array && val.array.length >= 4) {
                    auto q = cast(Quat*) ptr;
                    q.x = cast(float)(val.array[0].type == JSONType.float_ ? val.array[0].floating : val.array[0].integer);
                    q.y = cast(float)(val.array[1].type == JSONType.float_ ? val.array[1].floating : val.array[1].integer);
                    q.z = cast(float)(val.array[2].type == JSONType.float_ ? val.array[2].floating : val.array[2].integer);
                    q.w = cast(float)(val.array[3].type == JSONType.float_ ? val.array[3].floating : val.array[3].integer);
                }
                break;
            case FieldKind.stringId:
                if (val.type == JSONType.string) {
                    *cast(StringId*) ptr = strings.intern(val.str);
                }
                break;
            case FieldKind.enum_:
            case FieldKind.entityRef:
            case FieldKind.assetRef:
                if (val.type == JSONType.integer) *cast(uint*) ptr = cast(uint) val.integer;
                break;
            case FieldKind.fixedArray:
            case FieldKind.struct_:
                break;
        }
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
