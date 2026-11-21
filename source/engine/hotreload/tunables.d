/**
 * HR-2 — live gameplay tunables loaded from JSON files.
 *
 * A tunable file is a plain JSON object; nested objects flatten into dotted
 * keys:
 *
 * ---
 * { "vehicle": { "suspension": { "stiffness": 42000, "damping": 3100 },
 *                "breakImpulse": 900.5, "lights": true,
 *                "comOffset": [0, -0.4, 0.1] } }
 * ---
 *
 * gives `vehicle.suspension.stiffness`, `vehicle.suspension.damping`,
 * `vehicle.breakImpulse` (numbers), `vehicle.lights` (bool) and
 * `vehicle.comOffset` (a 1–4 component vector).
 *
 * Keys are interned once into the registry's own `StringTable`; values live
 * in a POD array indexed by `StringId.id`, so reads by `StringId` are
 * `@nogc nothrow` and safe to use every frame. A reload that fails to parse
 * keeps every previous value and logs the error.
 *
 * Reloads arrive through `AssetHotReloader` (any watched `*.tune.json` or a
 * file registered with `addFile`). `applyTo` / `applyToComponents` copy
 * `prefix.field` values into a struct or into every live component of a type,
 * so a reload updates live entities without restarting.
 */
module engine.hotreload.tunables;

import std.json : JSONValue, JSONType, parseJSON;
import engine.core.arena : FrameArena;
import engine.core.log : err, info, warn;
import engine.core.pod : Pod, isPod;
import engine.core.strings : StringId, StringTable;
import engine.math.vec : Vec3;

@safe:

/// Kind of value stored for a tunable key.
enum TunableType : ubyte {
    missing,
    number,
    boolean,
    vector,
}

/// One stored tunable (POD).
struct TunableValue {
    TunableType type;
    /// Component count for `vector` (1–4); 1 for `number` / `boolean`.
    ubyte count;
    /// Index + 1 into the registry's file list (0 = set from code).
    ushort file;
    float[4] v = [0, 0, 0, 0];
}

static assert(isPod!TunableValue);

/// Tunable files are recognised by this suffix (e.g. `vehicle.tune.json`).
enum tunableFileSuffix = ".tune.json";

/// True when `path` names a tunables file by convention.
bool isTunablePath(scope const(char)[] path) pure nothrow @nogc {
    return path.length >= tunableFileSuffix.length
        && path[$ - tunableFileSuffix.length .. $] == tunableFileSuffix;
}

struct TunableRegistry {
    private StringTable _keys;
    private Pod!TunableValue[] _values; // indexed by StringId.id
    private string[] _files;
    private uint[] _fileVersions;
    private uint _generation;

    /// Called after every successful file (re)load with the file path.
    void delegate(string path) @safe[] onReloaded;

    /// Incremented by every successful load; cheap "did anything change" check.
    uint generation() const nothrow @nogc { return _generation; }

    /// Files registered via `addFile` / `loadFile`.
    const(string)[] files() const nothrow @nogc { return _files; }

    /// Number of distinct keys ever loaded or set.
    size_t keyCount() const nothrow @nogc {
        size_t n;
        foreach (ref v; _values) if (v.type != TunableType.missing) n++;
        return n;
    }

    /// Intern `name` once (load time) and keep the `StringId` for `@nogc` reads.
    StringId key(scope const(char)[] name) { return _keys.intern(name); }

    /// `StringId` of an existing key, or the null id.
    StringId findKey(scope const(char)[] name) const { return _keys.lookup(name); }

    /// Key text for `id`.
    const(char)[] keyName(StringId id) const nothrow @nogc { return _keys.get(id); }

    /// Register `path` and load it now. Returns false (and keeps nothing) on error.
    bool addFile(string path) {
        fileIndex(path, true);
        return loadFile(path);
    }

    /// Register and load every `*.tune.json` below `root`. Returns files loaded.
    uint addFilesUnder(string root) @trusted {
        import std.file : dirEntries, exists, isDir, SpanMode;
        if (!exists(root) || !isDir(root)) return 0;
        uint loaded;
        try {
            foreach (entry; dirEntries(root, "*" ~ tunableFileSuffix, SpanMode.depth))
                if (!entry.isDir && addFile(entry.name)) loaded++;
        } catch (Exception e) {
            warn("Tunables: scan of ", root, " failed: ", e.msg);
        }
        return loaded;
    }

    /// True when `path` is a registered tunables file.
    bool watches(scope const(char)[] path) const nothrow @nogc {
        foreach (f; _files) if (f == path) return true;
        return false;
    }

    /// Reload count of `path` (0 when unknown or never loaded).
    uint fileVersion(scope const(char)[] path) const nothrow @nogc {
        foreach (i, f; _files) if (f == path) return _fileVersions[i];
        return 0;
    }

    /**
     * Read and apply `path`. On a read/parse error the previous values stay
     * untouched. Registers the file if it is new.
     */
    bool loadFile(string path) @trusted {
        import std.file : readText;
        string text;
        try {
            text = readText(path);
        } catch (Exception e) {
            err("Tunables: cannot read ", path, ": ", e.msg);
            return false;
        }
        return loadText(path, text);
    }

    /// Apply tunables from JSON `text` attributed to `path`.
    bool loadText(string path, string text) @trusted {
        JSONValue root;
        try {
            root = parseJSON(text);
        } catch (Exception e) {
            err("Tunables: parse error in ", path, " (keeping previous values): ", e.msg);
            return false;
        }
        if (root.type != JSONType.object) {
            err("Tunables: ", path, " must contain a JSON object (keeping previous values)");
            return false;
        }

        // Flatten into a staging list first so a bad value never half-applies.
        static struct Staged { string key; TunableValue value; }
        Staged[] staged;
        string firstError;
        void walk(ref const JSONValue node, string prefix) @trusted {
            foreach (string k, ref const JSONValue child; node.object) {
                immutable name = prefix.length ? prefix ~ "." ~ k : k;
                TunableValue tv;
                if (child.type == JSONType.object) {
                    walk(child, name);
                    continue;
                }
                if (toTunable(child, tv)) {
                    staged ~= Staged(name, tv);
                } else if (firstError.length == 0) {
                    firstError = name;
                }
            }
        }
        walk(root, "");
        if (firstError.length)
            warn("Tunables: ", path, ": unsupported value for '", firstError,
                 "' (numbers, booleans and 1-4 number arrays only); skipped");

        immutable fi = fileIndex(path, true);
        foreach (ref s; staged) {
            s.value.file = cast(ushort)(fi + 1);
            store(_keys.intern(s.key), s.value);
        }
        _fileVersions[fi]++;
        _generation++;
        info("Tunables: loaded ", path, " (", staged.length, " values)");
        foreach (cb; onReloaded) cb(_files[fi]);
        return true;
    }

    /// Set a number from code (e.g. defaults before any file loads).
    void setNumber(scope const(char)[] name, float value) {
        TunableValue tv;
        tv.type = TunableType.number;
        tv.count = 1;
        tv.v[0] = value;
        store(_keys.intern(name), tv);
    }

    /// Raw stored value (type `missing` when absent).
    TunableValue value(StringId id) const nothrow @nogc @trusted {
        if (id.isNull || id.id >= _values.length) return TunableValue.init;
        return _values[id.id];
    }

    bool has(StringId id) const nothrow @nogc { return value(id).type != TunableType.missing; }

    float getFloat(StringId id, float fallback = 0) const nothrow @nogc {
        immutable tv = value(id);
        if (tv.type == TunableType.number || tv.type == TunableType.vector) return tv.v[0];
        if (tv.type == TunableType.boolean) return tv.v[0] != 0 ? 1 : 0;
        return fallback;
    }

    int getInt(StringId id, int fallback = 0) const nothrow @nogc {
        immutable tv = value(id);
        if (tv.type == TunableType.missing) return fallback;
        immutable f = tv.v[0];
        return cast(int)(f >= 0 ? f + 0.5f : f - 0.5f);
    }

    bool getBool(StringId id, bool fallback = false) const nothrow @nogc {
        immutable tv = value(id);
        if (tv.type == TunableType.missing) return fallback;
        return tv.v[0] != 0;
    }

    Vec3 getVec3(StringId id, Vec3 fallback = Vec3(0, 0, 0)) const nothrow @nogc {
        immutable tv = value(id);
        if (tv.type == TunableType.missing) return fallback;
        if (tv.type != TunableType.vector) return Vec3(tv.v[0], tv.v[0], tv.v[0]);
        return Vec3(tv.v[0], tv.count > 1 ? tv.v[1] : 0, tv.count > 2 ? tv.v[2] : 0);
    }

    /// Convenience lookups by name (load time / tools; not `@nogc`).
    float getFloat(scope const(char)[] name, float fallback = 0) const {
        return getFloat(findKey(name), fallback);
    }
    /// ditto
    int getInt(scope const(char)[] name, int fallback = 0) const { return getInt(findKey(name), fallback); }
    /// ditto
    bool getBool(scope const(char)[] name, bool fallback = false) const {
        return getBool(findKey(name), fallback);
    }
    /// ditto
    Vec3 getVec3(scope const(char)[] name, Vec3 fallback = Vec3(0, 0, 0)) const {
        return getVec3(findKey(name), fallback);
    }

    /// Debug label `key=value` in the frame arena (no GC allocation).
    const(char)[] describe(StringId id, ref FrameArena arena) const @trusted {
        immutable tv = value(id);
        auto name = _keys.get(id);
        final switch (tv.type) {
            case TunableType.missing: return arena.fmt("%s=<missing>", name);
            case TunableType.number: return arena.fmt("%s=%g", name, tv.v[0]);
            case TunableType.boolean: return arena.fmt("%s=%s", name, tv.v[0] != 0 ? "true" : "false");
            case TunableType.vector: return arena.fmt("%s=%s", name, tv.v[0 .. tv.count]);
        }
    }

    /**
     * Copy every `prefix.field` tunable into the matching field of `target`.
     * Supported fields: integral, floating-point, `bool`, `Vec3` and
     * `float[N]` (N ≤ 4). Absent keys leave the field unchanged. Returns the
     * number of fields written.
     */
    uint applyTo(T)(ref T target, scope const(char)[] prefix) const if (is(T == struct)) {
        uint written;
        static foreach (i, field; T.tupleof) {{
            alias F = typeof(field);
            enum fname = __traits(identifier, T.tupleof[i]);
            static if (isTunableField!F) {
                immutable id = findKey(prefix.length ? prefix ~ "." ~ fname : fname);
                if (has(id)) {
                    assignField(target.tupleof[i], id);
                    written++;
                }
            }
        }}
        return written;
    }

    /**
     * Apply `prefix.field` tunables to component `C` of every live entity in
     * `world` (any `World!(...)` or `SceneWorld`). Returns entities updated.
     */
    uint applyToComponents(C, W)(ref W world, scope const(char)[] prefix) const {
        uint updated;
        foreach (e; world.query!C()) {
            if (!world.alive(e)) continue;
            if (applyTo(world.get!C(e), prefix) > 0) updated++;
        }
        return updated;
    }

    private void assignField(F)(ref F field, StringId id) const {
        static if (is(F == bool)) field = getBool(id);
        else static if (is(F == Vec3)) field = getVec3(id);
        else static if (is(F == float[N], size_t N)) {
            immutable tv = value(id);
            foreach (k; 0 .. N) field[k] = k < tv.count ? tv.v[k] : (tv.type == TunableType.vector ? 0 : tv.v[0]);
        } else static if (__traits(isFloating, F)) field = cast(F) getFloat(id);
        else static if (__traits(isIntegral, F)) field = cast(F) getInt(id);
    }

    private void store(StringId id, TunableValue tv) @trusted {
        if (id.id >= _values.length) _values.length = id.id + 1;
        _values[id.id] = tv;
    }

    private size_t fileIndex(string rawPath, bool create) {
        import std.path : buildNormalizedPath;
        // Normalized so watcher paths (`assets/x/../y`, `./assets/y`) match.
        immutable path = buildNormalizedPath(rawPath);
        foreach (i, f; _files) if (f == path) return i;
        if (!create) return size_t.max;
        _files ~= path;
        _fileVersions ~= 0;
        return _files.length - 1;
    }
}

private template isTunableField(F) {
    static if (is(F == float[N], size_t N)) enum isTunableField = N <= 4;
    else enum isTunableField = is(F == bool) || is(F == Vec3)
        || __traits(isFloating, F) || __traits(isIntegral, F);
}

private bool toTunable(ref const JSONValue v, out TunableValue tv) @trusted {
    switch (v.type) {
        case JSONType.integer:
        case JSONType.uinteger:
        case JSONType.float_:
            tv.type = TunableType.number;
            tv.count = 1;
            tv.v[0] = jsonNumber(v);
            return true;
        case JSONType.true_:
        case JSONType.false_:
            tv.type = TunableType.boolean;
            tv.count = 1;
            tv.v[0] = v.type == JSONType.true_ ? 1 : 0;
            return true;
        case JSONType.array:
            auto arr = v.array;
            if (arr.length == 0 || arr.length > 4) return false;
            foreach (k, ref item; arr) {
                if (item.type != JSONType.integer && item.type != JSONType.uinteger
                    && item.type != JSONType.float_) return false;
                tv.v[k] = jsonNumber(item);
            }
            tv.type = TunableType.vector;
            tv.count = cast(ubyte) arr.length;
            return true;
        default:
            return false;
    }
}

private float jsonNumber(ref const JSONValue v) @trusted {
    if (v.type == JSONType.integer) return cast(float) v.integer;
    if (v.type == JSONType.uinteger) return cast(float) v.uinteger;
    return cast(float) v.floating;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

@("tunables.flattenAndTypedReads") unittest {
    TunableRegistry reg;
    assert(reg.loadText("mem/vehicle.tune.json", `{
        "vehicle": { "suspension": { "stiffness": 42000, "damping": 3100.5 },
                     "lights": true, "gears": 6, "comOffset": [0, -0.4, 0.1] },
        "name": "ignored-string" }`));
    immutable stiff = reg.key("vehicle.suspension.stiffness");
    assert(reg.getFloat(stiff) == 42000);
    assert(reg.getFloat("vehicle.suspension.damping") == 3100.5f);
    assert(reg.getBool("vehicle.lights"));
    assert(reg.getInt("vehicle.gears") == 6);
    assert(reg.getVec3("vehicle.comOffset") == Vec3(0, -0.4f, 0.1f));
    assert(reg.getFloat("missing.key", 7) == 7);
    assert(reg.keyCount == 5);
    assert(reg.generation == 1);
    assert(reg.fileVersion("mem/vehicle.tune.json") == 1);
}

@("tunables.parseErrorKeepsPreviousValues") unittest {
    TunableRegistry reg;
    assert(reg.loadText("t.tune.json", `{"hp": 100}`));
    assert(!reg.loadText("t.tune.json", `{"hp": 50,,`));
    assert(reg.getFloat("hp") == 100);
    assert(!reg.loadText("t.tune.json", `[1, 2]`));
    assert(reg.getFloat("hp") == 100);
    assert(reg.generation == 1);
    assert(reg.loadText("t.tune.json", `{"hp": 50}`));
    assert(reg.getFloat("hp") == 50);
    assert(reg.fileVersion("t.tune.json") == 2);
}

@("tunables.nogcReadsByStringId") unittest {
    TunableRegistry reg;
    reg.setNumber("spawn.interval", 2.5f);
    immutable id = reg.key("spawn.interval");
    float got;
    () nothrow @nogc { got = reg.getFloat(id); }();
    assert(got == 2.5f);
}

@("tunables.applyToStructAndLiveComponents") unittest {
    import engine.ecs.world : World;
    import engine.reflect.attrs : component;

    @component static struct Suspension {
        float stiffness = 1;
        float damping = 1;
        int gear = 1;
        bool abs;
        Vec3 comOffset;
        float[2] travel = [0, 0];
        ubyte untouched = 9;
    }

    TunableRegistry reg;
    assert(reg.loadText("v.tune.json", `{"car": {"stiffness": 4, "damping": 0.5, "gear": 3,
        "abs": true, "comOffset": [1, 2, 3], "travel": [0.2, 0.3]}}`));

    Suspension s;
    assert(reg.applyTo(s, "car") == 6);
    assert(s.stiffness == 4 && s.damping == 0.5f && s.gear == 3 && s.abs);
    assert(s.comOffset == Vec3(1, 2, 3) && s.travel == [0.2f, 0.3f] && s.untouched == 9);

    World!(Suspension) world;
    auto a = world.spawn();
    auto b = world.spawn();
    world.set(a, Suspension.init);
    world.set(b, Suspension.init);
    world.destroy(b);
    assert(reg.applyToComponents!Suspension(world, "car") == 1);
    assert(world.get!Suspension(a).stiffness == 4);

    // A live edit (reload) updates the component on the next apply.
    assert(reg.loadText("v.tune.json", `{"car": {"stiffness": 8}}`));
    reg.applyToComponents!Suspension(world, "car");
    assert(world.get!Suspension(a).stiffness == 8);
    assert(world.get!Suspension(a).damping == 0.5f); // previous value kept
}

@("tunables.fileReloadCallbackAndArenaLabel") @trusted unittest {
    import std.file : mkdirRecurse, rmdirRecurse, write;
    immutable dir = "build/test_tunables";
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    immutable path = dir ~ "/gameplay.tune.json";
    write(path, `{"enemy": {"hp": 30}}`);

    TunableRegistry reg;
    string seen;
    reg.onReloaded ~= (string p) { seen = p; };
    assert(reg.addFilesUnder(dir) == 1);
    assert(reg.files == [path]);
    assert(reg.addFile("./" ~ path)); // same file, other spelling
    assert(reg.files.length == 1);
    assert(reg.watches(path) && isTunablePath(path));
    assert(seen == path);
    write(path, `{"enemy": {"hp": 45}}`);
    assert(reg.loadFile(path));
    assert(reg.getInt("enemy.hp") == 45);

    auto arena = FrameArena(256);
    assert(reg.describe(reg.key("enemy.hp"), arena) == "enemy.hp=45");
    assert(!reg.loadFile(dir ~ "/missing.tune.json"));
}
