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
    uint typeIndex = 0; // `TypeRegistry.nestedTypes` index + 1 for a struct (or an array of structs); 0 = none
    uint arrayLen = 1;
    FieldKind elemKind = FieldKind.unknown; // element kind of a fixedArray
    uint elemSize = 0;                      // element size of a fixedArray, in bytes
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
    bool stale = false; // unregistered (script unload): hidden from `find`, replaced by the next `register`
}

static assert(isPod!TypeDescriptor);

alias ComponentTypeId = uint;
enum ComponentTypeId invalidComponentTypeId = ComponentTypeId.max;

/// Central registry holding all registered type and field descriptors.
struct TypeRegistry {
    TypeDescriptor[] types;
    FieldDescriptor[] fields;
    // Structs used as field types. Kept apart from `types`: they are not components and have no store.
    TypeDescriptor[] nestedTypes;
    FieldDescriptor[] nestedFields;
    ubyte[] defaultStorage;

    ComponentTypeId find(scope const(char)[] qualifiedName, ref const StringTable strings) const nothrow @nogc {
        foreach (i, ref const t; types) {
            if (!t.stale && strings.get(t.qualifiedName) == qualifiedName)
                return cast(ComponentTypeId) i;
        }
        return invalidComponentTypeId;
    }

    ComponentTypeId findById(StringId qualifiedNameId) const nothrow @nogc {
        foreach (i, ref const t; types) {
            if (!t.stale && t.qualifiedName == qualifiedNameId)
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

    /// Fields of a nested struct type (`FieldDescriptor.typeIndex`).
    const(FieldDescriptor)[] getNestedFields(uint typeIndex) const nothrow @nogc {
        if (typeIndex == 0 || typeIndex > nestedTypes.length)
            return null;
        const t = nestedTypes[typeIndex - 1];
        return nestedFields[t.firstField .. t.firstField + t.fieldCount];
    }

    /// True when a nested struct or fixed array of `id` holds a `StringId` or an `@entityRef`: values that mean
    /// something only in one world, so a raw byte copy of the component is not portable.
    bool hasNestedReferences(ComponentTypeId id) const nothrow @nogc {
        foreach (ref const f; getFields(id))
            if (nestedReference(f))
                return true;
        return false;
    }

    private bool nestedReference(ref const FieldDescriptor f) const nothrow @nogc {
        if (f.kind == FieldKind.fixedArray && (f.elemKind == FieldKind.stringId || f.elemKind == FieldKind.entityRef))
            return true;
        if (f.kind != FieldKind.struct_ && f.kind != FieldKind.fixedArray)
            return false;
        foreach (ref const n; getNestedFields(f.typeIndex)) {
            if (n.kind == FieldKind.stringId || n.kind == FieldKind.entityRef || nestedReference(n))
                return true;
        }
        return false;
    }

    /// Forget the layout of a type whose code was unloaded. Its id stays reserved: the next `register` of the same
    /// name refills it with the new layout.
    void markStale(ComponentTypeId id) nothrow @nogc {
        if (id < types.length)
            types[id].stale = true;
    }

    const(ubyte)[] getDefaults(ComponentTypeId id) const nothrow @nogc {
        const t = types[id];
        if (t.defaultOffset >= defaultStorage.length || t.defaultOffset + t.defaultLength > defaultStorage.length)
            return null;
        return defaultStorage[t.defaultOffset .. t.defaultOffset + t.defaultLength];
    }

    /// Register a type that has no D struct in this process, from a schema (name, size, fields). Used to read
    /// self-describing data (GESC `types` block) and by tools; defaults are zero bytes unless `defaults` is given.
    /// Returns the existing id when `name` is already registered.
    /// `FieldT` is any struct with `name`, `formerlyNamed` (strings), `kind` (`FieldKind`), `offset`, `size` and
    /// `arrayLen` members (for example `GescFieldSchema`); it is a template parameter so this registry module
    /// holds no GC-owning field type.
    ComponentTypeId registerRuntime(FieldT)(scope const(char)[] name, uint size, uint alignment,
            scope const(FieldT)[] runtimeFields, ref StringTable strings,
            scope const(ubyte)[] defaults = null) @trusted {
        auto existing = find(name, strings);
        if (existing != invalidComponentTypeId)
            return existing;
        TypeDescriptor desc;
        desc.qualifiedName = strings.intern(name);
        desc.size = size;
        desc.alignment = alignment;
        desc.defaultOffset = cast(uint) defaultStorage.length;
        desc.defaultLength = size;
        immutable base = defaultStorage.length;
        defaultStorage.length = base + size;
        defaultStorage[base .. base + size] = 0;
        if (defaults.length == size)
            defaultStorage[base .. base + size] = defaults[];
        desc.firstField = cast(uint) fields.length;
        foreach (ref const f; runtimeFields) {
            FieldDescriptor fd;
            fd.name = strings.intern(f.name);
            fd.offset = f.offset;
            fd.size = f.size;
            fd.kind = f.kind;
            fd.arrayLen = f.arrayLen;
            if (f.formerlyNamed.length)
                fd.attrs.formerlyNamed = strings.intern(f.formerlyNamed);
            fields ~= fd;
            desc.fieldCount++;
        }
        immutable typeId = cast(ComponentTypeId) types.length;
        types ~= desc;
        return typeId;
    }

    ComponentTypeId register(T)(ref StringTable strings) @trusted {
        static assert(is(T == struct), "T must be a struct");
        static assert(isPod!T, "Component struct must be POD (no GC indirections)");

        immutable name = fullyQualifiedName!T;
        ComponentTypeId slot = invalidComponentTypeId;
        foreach (i, ref const t; types) {
            if (strings.get(t.qualifiedName) == name) {
                slot = cast(ComponentTypeId) i;
                break;
            }
        }
        if (slot != invalidComponentTypeId && !types[slot].stale) {
            // Types are keyed by bare identifier: two different structs with the same name would share one store.
            if (types[slot].size != T.sizeof)
                throw new Exception("component type name collision: '" ~ name
                    ~ "' is already registered with a different size");
            return slot;
        }

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

        if (slot != invalidComponentTypeId) {
            types[slot] = desc;
            return slot;
        }
        immutable typeId = cast(ComponentTypeId) types.length;
        types ~= desc;
        return typeId;
    }

    /// Describe struct `S` used as a field type; returns its `typeIndex`.
    private uint registerNested(S)(ref StringTable strings) @trusted {
        import std.traits : stdFullyQualifiedName = fullyQualifiedName;

        // Describe the fields first: they may register their own nested types.
        FieldDescriptor[] described;
        static foreach (memberName; __traits(allMembers, S)) {
            static if (isFieldAccessible!(S, memberName))
                described ~= describeField!(S, memberName)(strings, this);
        }
        // A struct of the same name may have changed after a script reload: compare the layout, not only the name.
        immutable sid = strings.intern(stdFullyQualifiedName!S);
        foreach (i, ref const t; nestedTypes)
            if (t.qualifiedName == sid && t.size == S.sizeof
                    && sameFields(nestedFields[t.firstField .. t.firstField + t.fieldCount], described))
                return cast(uint) i + 1;

        TypeDescriptor desc;
        desc.qualifiedName = sid;
        desc.size = cast(uint) S.sizeof;
        desc.alignment = cast(uint) S.alignof;
        desc.firstField = cast(uint) nestedFields.length;
        desc.fieldCount = cast(uint) described.length;
        nestedFields ~= described;
        nestedTypes ~= desc;
        return cast(uint) nestedTypes.length;
    }

    private static bool sameFields(scope const(FieldDescriptor)[] a, scope const(FieldDescriptor)[] b) pure nothrow @nogc {
        if (a.length != b.length)
            return false;
        foreach (i, ref const x; a) {
            const y = &b[i];
            if (x.name != y.name || x.offset != y.offset || x.size != y.size || x.kind != y.kind
                    || x.typeIndex != y.typeIndex || x.elemKind != y.elemKind || x.elemSize != y.elemSize)
                return false;
        }
        return true;
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
    static if (deduceFieldKind!FieldType == FieldKind.struct_) {
        fd.typeIndex = reg.registerNested!FieldType(strings);
    } else static if (deduceFieldKind!FieldType == FieldKind.fixedArray) {
        static if (is(FieldType : E[N], E, size_t N)) {
            fd.elemKind = deduceFieldKind!E;
            fd.elemSize = cast(uint) E.sizeof;
            static if (deduceFieldKind!E == FieldKind.struct_)
                fd.typeIndex = reg.registerNested!E(strings);
        }
    }

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
        } else static if (is(attr == entityRef)) {
            static assert(is(FieldType == uint), "@entityRef requires a uint field");
            fd.kind = FieldKind.entityRef;
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
