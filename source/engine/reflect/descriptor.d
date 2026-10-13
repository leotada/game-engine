/// Compile-time reflection descriptors and runtime TypeRegistry.
module engine.reflect.descriptor;

import engine.core.pod : isPod;
import engine.core.strings : StringId, StringTable;
import engine.math.vec : Vec2, Vec3, Vec4;
import engine.math.quat : Quat;
import engine.graphics.types : Color4;
import engine.reflect.attrs;

@safe:

enum FieldKind : ubyte {
    unknown    = 0,
    f32        = 1,
    f64        = 2,
    i8         = 3,
    i16        = 4,
    i32        = 5,
    i64        = 6,
    u8         = 7,
    u16        = 8,
    u32        = 9,
    u64        = 10,
    bool_      = 11,
    vec2       = 12,
    vec3       = 13,
    vec4       = 14,
    quat       = 15,
    color      = 16,
    stringId   = 17,
    enum_      = 18,
    entityRef  = 19,
    assetRef   = 20,
    fixedArray = 21,
    struct_    = 22,
}

enum LifecycleMask : uint {
    none             = 0,
    onStart          = 1 << 0,
    onUpdate         = 1 << 1,
    onFixedUpdate    = 1 << 2,
    onLateUpdate     = 1 << 3,
    onCollisionEnter = 1 << 4,
    onCollisionExit  = 1 << 5,
    onDestroy        = 1 << 6,
    onValidate       = 1 << 7,
}

struct FieldAttrs {
    float rangeMin = float.nan;
    float rangeMax = float.nan;
    StringId tooltip;
    StringId header;
    StringId formerlyNamed;
    bool hidden = false;
    bool readOnly = false;
}

static assert(isPod!FieldAttrs);

struct FieldDescriptor {
    StringId name;
    uint offset = 0;
    uint size = 0;
    FieldKind kind = FieldKind.unknown;
    uint typeIndex = 0; // TypeRegistry index if struct/enum
    uint arrayLen = 1;
    FieldAttrs attrs;
}

static assert(isPod!FieldDescriptor);

struct TypeDescriptor {
    StringId qualifiedName;
    uint size = 0;
    uint alignment = 0;
    uint firstField = 0;
    uint fieldCount = 0;
    uint defaultOffset = 0; // offset in TypeRegistry.defaultStorage
    uint defaultLength = 0;
    uint lifecycleMask = 0;
}

static assert(isPod!TypeDescriptor);

alias ComponentTypeId = uint;
enum ComponentTypeId invalidComponentTypeId = ComponentTypeId.max;

/// Central registry holding all registered type and field descriptors.
struct TypeRegistry {
    TypeDescriptor[] types;
    FieldDescriptor[] fields;
    ubyte[] defaultStorage;

    ComponentTypeId find(scope const(char)[] qualifiedName, ref const StringTable strings) const nothrow @nogc {
        foreach (i, ref const t; types) {
            if (strings.get(t.qualifiedName) == qualifiedName)
                return cast(ComponentTypeId) i;
        }
        return invalidComponentTypeId;
    }

    ComponentTypeId findById(StringId qualifiedNameId) const nothrow @nogc {
        foreach (i, ref const t; types) {
            if (t.qualifiedName == qualifiedNameId)
                return cast(ComponentTypeId) i;
        }
        return invalidComponentTypeId;
    }

    ref const(TypeDescriptor) getType(ComponentTypeId id) const nothrow @nogc {
        return types[id];
    }

    const(FieldDescriptor)[] getFields(ComponentTypeId id) const nothrow @nogc {
        const t = types[id];
        if (t.firstField >= fields.length || t.firstField + t.fieldCount > fields.length)
            return null;
        return fields[t.firstField .. t.firstField + t.fieldCount];
    }

    const(ubyte)[] getDefaults(ComponentTypeId id) const nothrow @nogc {
        const t = types[id];
        if (t.defaultOffset >= defaultStorage.length || t.defaultOffset + t.defaultLength > defaultStorage.length)
            return null;
        return defaultStorage[t.defaultOffset .. t.defaultOffset + t.defaultLength];
    }

    ComponentTypeId register(T)(ref StringTable strings) @trusted {
        static assert(is(T == struct), "T must be a struct");
        static assert(isPod!T, "Component struct must be POD (no GC indirections)");

        immutable name = fullyQualifiedName!T;
        auto existing = find(name, strings);
        if (existing != invalidComponentTypeId)
            return existing;

        TypeDescriptor desc;
        desc.qualifiedName = strings.intern(name);
        desc.size = cast(uint) T.sizeof;
        desc.alignment = cast(uint) T.alignof;
        desc.lifecycleMask = detectLifecycle!T();

        // Register defaults
        T defVal = T.init;
        desc.defaultOffset = cast(uint) defaultStorage.length;
        desc.defaultLength = cast(uint) T.sizeof;
        auto p = cast(const(ubyte)*) &defVal;
        defaultStorage ~= p[0 .. T.sizeof];

        // Register fields
        desc.firstField = cast(uint) fields.length;
        static foreach (memberName; __traits(allMembers, T)) {
            static if (isFieldAccessible!(T, memberName)) {
                fields ~= describeField!(T, memberName)(strings, this);
                desc.fieldCount++;
            }
        }

        immutable typeId = cast(ComponentTypeId) types.length;
        types ~= desc;
        return typeId;
    }
}

// ---------------------------------------------------------------------------
// Compile-Time Introspection Helpers
// ---------------------------------------------------------------------------

private template fullyQualifiedName(T) {
    enum fullyQualifiedName = __traits(identifier, T);
}

private template isFieldAccessible(T, string member) {
    static if (__traits(compiles, {
        T val = void;
        auto x = __traits(getMember, val, member);
    })) {
        alias M = typeof(__traits(getMember, T.init, member));
        enum isFieldAccessible = !is(M == function) &&
                                 !is(M == void) &&
                                 !__traits(isStaticFunction, __traits(getMember, T, member)) &&
                                 (__traits(getMember, T.init, member).offsetof == __traits(getMember, T.init, member).offsetof);
    } else {
        enum isFieldAccessible = false;
    }
}

private uint detectLifecycle(T)() {
    uint mask = LifecycleMask.none;
    static if (__traits(hasMember, T, "onStart")) mask |= LifecycleMask.onStart;
    static if (__traits(hasMember, T, "onUpdate")) mask |= LifecycleMask.onUpdate;
    static if (__traits(hasMember, T, "onFixedUpdate")) mask |= LifecycleMask.onFixedUpdate;
    static if (__traits(hasMember, T, "onLateUpdate")) mask |= LifecycleMask.onLateUpdate;
    static if (__traits(hasMember, T, "onCollisionEnter")) mask |= LifecycleMask.onCollisionEnter;
    static if (__traits(hasMember, T, "onCollisionExit")) mask |= LifecycleMask.onCollisionExit;
    static if (__traits(hasMember, T, "onDestroy")) mask |= LifecycleMask.onDestroy;
    static if (__traits(hasMember, T, "onValidate")) mask |= LifecycleMask.onValidate;
    return mask;
}

private FieldDescriptor describeField(T, string memberName)(ref StringTable strings, ref TypeRegistry reg) {
    FieldDescriptor fd;
    fd.name = strings.intern(memberName);

    alias FieldType = typeof(__traits(getMember, T.init, memberName));
    fd.offset = cast(uint) __traits(getMember, T.init, memberName).offsetof;
    fd.size = cast(uint) FieldType.sizeof;
    fd.kind = deduceFieldKind!FieldType;

    // Inspect UDAs
    static foreach (attr; __traits(getAttributes, __traits(getMember, T, memberName))) {
        static if (is(typeof(attr) == range)) {
            fd.attrs.rangeMin = attr.min;
            fd.attrs.rangeMax = attr.max;
        } else static if (is(typeof(attr) == tooltip)) {
            fd.attrs.tooltip = strings.intern(attr.text);
        } else static if (is(typeof(attr) == header)) {
            fd.attrs.header = strings.intern(attr.text);
        } else static if (is(typeof(attr) == formerlyNamed)) {
            fd.attrs.formerlyNamed = strings.intern(attr.oldName);
        } else static if (is(attr == hide)) {
            fd.attrs.hidden = true;
        }
    }

    return fd;
}

private template deduceFieldKind(F) {
    static if (is(F == float)) enum deduceFieldKind = FieldKind.f32;
    else static if (is(F == double)) enum deduceFieldKind = FieldKind.f64;
    else static if (is(F == byte)) enum deduceFieldKind = FieldKind.i8;
    else static if (is(F == short)) enum deduceFieldKind = FieldKind.i16;
    else static if (is(F == int)) enum deduceFieldKind = FieldKind.i32;
    else static if (is(F == long)) enum deduceFieldKind = FieldKind.i64;
    else static if (is(F == ubyte)) enum deduceFieldKind = FieldKind.u8;
    else static if (is(F == ushort)) enum deduceFieldKind = FieldKind.u16;
    else static if (is(F == uint)) enum deduceFieldKind = FieldKind.u32;
    else static if (is(F == ulong)) enum deduceFieldKind = FieldKind.u64;
    else static if (is(F == bool)) enum deduceFieldKind = FieldKind.bool_;
    else static if (is(F == Vec2)) enum deduceFieldKind = FieldKind.vec2;
    else static if (is(F == Vec3)) enum deduceFieldKind = FieldKind.vec3;
    else static if (is(F == Vec4)) enum deduceFieldKind = FieldKind.vec4;
    else static if (is(F == Quat)) enum deduceFieldKind = FieldKind.quat;
    else static if (is(F == Color4)) enum deduceFieldKind = FieldKind.color;
    else static if (is(F == StringId)) enum deduceFieldKind = FieldKind.stringId;
    else static if (is(F == enum)) enum deduceFieldKind = FieldKind.enum_;
    else static if (is(F : E[N], E, size_t N)) {
        static if (is(E == float) && N == 4) enum deduceFieldKind = FieldKind.color;
        else static if (is(E == float) && N == 3) enum deduceFieldKind = FieldKind.vec3;
        else enum deduceFieldKind = FieldKind.fixedArray;
    }
    else static if (is(F == struct)) enum deduceFieldKind = FieldKind.struct_;
    else enum deduceFieldKind = FieldKind.unknown;
}

@safe unittest {
    static struct Player {
        @range(0, 100) @tooltip("Hit points") float health = 100;
        @header("Movement") Vec3 velocity;
        bool alive = true;
        @hide int internalTag = 42;

        void onStart() {}
        void onUpdate(float dt) {}
    }

    StringTable strings;
    TypeRegistry reg;
    immutable typeId = reg.register!Player(strings);

    assert(typeId == 0);
    auto t = reg.getType(typeId);
    assert(strings.get(t.qualifiedName) == "Player");
    assert((t.lifecycleMask & LifecycleMask.onStart) != 0);
    assert((t.lifecycleMask & LifecycleMask.onUpdate) != 0);

    auto fields = reg.getFields(typeId);
    assert(fields.length == 4);
    assert(strings.get(fields[0].name) == "health");
    assert(fields[0].kind == FieldKind.f32);
    assert(fields[0].attrs.rangeMin == 0 && fields[0].attrs.rangeMax == 100);

    assert(strings.get(fields[3].name) == "internalTag");
    assert(fields[3].attrs.hidden == true);
}
