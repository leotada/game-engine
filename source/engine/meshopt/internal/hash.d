// Ported from meshoptimizer v1.3 (src/indexgenerator.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Open-addressing table: power-of-two buckets and quadratic probing (`hashLookup`).
module engine.meshopt.internal.hash;

@safe:

/// Smallest power of two strictly above `count + count/4`, or 1 when that sum is 0.
size_t hashBuckets(size_t count) pure nothrow @nogc {
    size_t buckets = 1;
    while (buckets < count + count / 4)
        buckets *= 2;
    return buckets;
}

/**
 * Quadratic-probe lookup. `table.length` is the bucket count and must be a
 * power of two. Empty slots compare equal to `empty` with `==`; occupied
 * slots use `hasher.equal`. Returns the index of the empty or matching slot.
 *
 * `Hasher` provides `size_t hash(T)` and `bool equal(T, T)`.
 */
size_t hashLookup(T, Hasher)(T[] table, scope ref Hasher hasher, T key, T empty) nothrow @nogc
if (is(typeof(hasher.hash(key)) : size_t) && is(typeof(hasher.equal(key, key)) : bool)) {
    assert(table.length > 0);
    assert((table.length & (table.length - 1)) == 0);

    size_t hashmod = table.length - 1;
    size_t bucket = hasher.hash(key) & hashmod;

    foreach (probe; 0 .. hashmod + 1) {
        if (table[bucket] == empty)
            return bucket;
        if (hasher.equal(table[bucket], key))
            return bucket;
        // hash collision, quadratic probing
        bucket = (bucket + probe + 1) & hashmod;
    }

    assert(0); // table is full
    return 0;
}

@safe nothrow @nogc unittest {
    assert(hashBuckets(0) == 1);
    assert(hashBuckets(1) == 1);
    assert(hashBuckets(4) == 8);
    assert(hashBuckets(8) == 16);

    static struct IdHash {
        size_t hash(uint k) const pure nothrow @nogc {
            return k * 0x9e37_79b1;
        }

        bool equal(uint a, uint b) const pure nothrow @nogc {
            return a == b;
        }
    }

    IdHash hasher;
    uint[8] table = uint.max;
    uint[4] keys = [1, 2, 3, 4];
    foreach (k; keys) {
        size_t slot = hashLookup(table[], hasher, k, uint.max);
        assert(table[slot] == uint.max);
        table[slot] = k;
    }
    foreach (k; keys) {
        size_t slot = hashLookup(table[], hasher, k, uint.max);
        assert(table[slot] == k);
    }

    // Every key hashes to 0 so probing has to walk the table.
    static struct ZeroHash {
        size_t hash(uint) const pure nothrow @nogc {
            return 0;
        }

        bool equal(uint a, uint b) const pure nothrow @nogc {
            return a == b;
        }
    }

    ZeroHash zero;
    uint[4] forced = [uint.max, uint.max, uint.max, uint.max];
    uint[3] collide = [7, 8, 9];
    foreach (k; collide) {
        size_t slot = hashLookup(forced[], zero, k, uint.max);
        forced[slot] = k;
    }
    // probe 0, then +1, then +2: keys land at 0, 1, and 3.
    assert(forced[0] == 7 && forced[1] == 8 && forced[3] == 9);
    assert(forced[2] == uint.max);
    assert(hashLookup(forced[], zero, 8u, uint.max) == 1);
    assert(hashLookup(forced[], zero, 9u, uint.max) == 3);
}
