/**
 * Interned string table for engine storage.
 *
 * `StringId` is a 4-byte POD value that replaces `string` in any data
 * structure that lives in engine memory (components, mesh metadata,
 * dialog keys, asset paths, etc.).  The actual character data lives in
 * one big `char[]` buffer inside `StringTable`, which the GC sees as a
 * single root — not one root per string.
 *
 * Game scripts build `string` values freely; they call `intern()` when
 * handing one to the engine.
 *
 * See docs/gc-safe-architecture-plan.md §2.3.
 */
module engine.core.strings;

import engine.core.pod : isPod;

@safe:

/// A compact, POD identifier for an interned string.
/// `id == 0` is the null/empty string.
struct StringId
{
    uint id = 0;

    bool isNull() const @nogc nothrow pure @safe { return id == 0; }

    bool opEquals()(const StringId rhs) const @nogc nothrow pure @safe
    {
        return id == rhs.id;
    }

    size_t toHash() const @nogc nothrow pure @safe { return id; }
}

static assert(isPod!StringId);

/**
 * Append-only string interner.
 *
 * All character data is packed into a single contiguous `char[]` buffer.
 * Offsets are stored in a parallel `uint[]`.  A `string`-keyed AA handles
 * deduplication (this AA lives on the GC heap — that's fine, it's a
 * gameplay-side root, not scanned per-vertex).
 *
 * Capacity grows automatically via the GC allocator; the important
 * property is that the *contents* of the storage buffer are plain chars,
 * so the GC marks the buffer in O(1) regardless of how many strings are
 * interned.
 */
struct StringTable
{
    private char[]  storage;       // packed character data
    private uint[]  offsets;       // offsets[id] .. offsets[id+1]
    private uint[string] index;    // dedup: string → id

    /// Intern a string value.  Returns the same `StringId` for equal inputs.
    StringId intern(scope const(char)[] s) @trusted
    {
        if (s.length == 0) return StringId(0);

        // D allows using scope const(char)[] as AA key via idup internally.
        string key = (() @trusted => cast(string) s)();
        if (auto p = key in index)
            return StringId(*p);

        // First entry: offsets[0] = 0 (start of first string).
        if (offsets.length == 0)
            offsets ~= 0;

        immutable id = cast(uint) offsets.length; // 1-based
        storage ~= s;
        offsets ~= cast(uint) storage.length;

        // Keep an idup for the AA key so the original scope slice can die.
        string owned = s.idup;
        index[owned] = id;
        return StringId(id);
    }

    /// Retrieve the character data for a `StringId`.
    /// Returns an empty slice for `StringId(0)`.
    const(char)[] get(StringId sid) const @trusted
    {
        if (sid.id == 0 || sid.id >= offsets.length) return null;
        immutable lo = offsets[sid.id - 1];
        immutable hi = offsets[sid.id];
        return storage[lo .. hi];
    }

    /// Number of unique strings interned (not counting the null entry).
    size_t count() const @nogc nothrow pure @safe
    {
        return offsets.length > 0 ? offsets.length - 1 : 0;
    }
}

///
@safe unittest
{
    StringTable t;
    auto a = t.intern("hello");
    auto b = t.intern("world");
    auto c = t.intern("hello");  // dedup
    assert(a == c);
    assert(a != b);
    assert(t.get(a) == "hello");
    assert(t.get(b) == "world");
    assert(t.count == 2);
    assert(StringId.init.isNull);
    assert(t.get(StringId.init) is null);
}
