// Ported from meshoptimizer v1.3 (src/spatialorder.cpp, src/clusterizer.cpp, src/overdrawoptimizer.cpp, src/simplifier.cpp, src/partition.cpp, src/meshletutils.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Upstream sort orders. Do not replace these with `std.algorithm.sort`.
module engine.meshopt.internal.sort;

import engine.core.pod : isPod;
import engine.meshopt.internal.bits : floatBits;

@safe:

/// Map a float's bits onto an unsigned order (negatives first). From `clusterizer.cpp`.
uint radixFloat(uint v) pure nothrow @nogc {
    uint mask = (cast(int) v >> 31) | 0x8000_0000;
    return v ^ mask;
}

/**
 * 10-bit counting sort from `spatialorder.cpp` `radixSort10`.
 * `keys` is indexed by `source[i]`, not by `i`.
 */
void radixSort10(uint[] destination, const(uint)[] source, const(ushort)[] keys) pure nothrow @nogc {
    size_t count = source.length;
    assert(destination.length >= count);
    uint[1024] hist;
    foreach (i; 0 .. count) {
        assert(source[i] < keys.length);
        hist[keys[source[i]]]++;
    }
    uint sum = 0;
    foreach (i; 0 .. 1024) {
        uint h = hist[i];
        hist[i] = sum;
        sum += h;
    }
    assert(sum == count);
    foreach (i; 0 .. count) {
        uint id = keys[source[i]];
        destination[hist[id]++] = source[i];
    }
}

/// Stable counting sort. `order[i]` is the input index, ordered by `keys`.
void countingSortOrder(uint[] order, const(uint)[] keys, uint bins) pure nothrow @nogc {
    size_t count = keys.length;
    assert(order.length >= count);
    assert(bins > 0 && bins <= 4096);
    uint[4096] histogram = void;
    histogram[0 .. bins] = 0;
    foreach (i; 0 .. count) {
        assert(keys[i] < bins);
        histogram[keys[i]]++;
    }
    size_t sum = 0;
    foreach (i; 0 .. bins) {
        size_t c = histogram[i];
        histogram[i] = cast(uint) sum;
        sum += c;
    }
    assert(sum == count);
    foreach (i; 0 .. count)
        order[histogram[keys[i]]++] = cast(uint) i;
}

/**
 * Counting sort of collapse indices by the top bits of a non-negative error.
 * From `simplifier.cpp` `sortEdgeCollapses` (12 bits, exponent range clamped).
 */
void sortEdgeCollapses(uint[] sortOrder, const(uint)[] errorBits) pure nothrow @nogc {
    enum uint sortBits = 12;
    enum uint sortBins = 2048 + 512;
    size_t count = errorBits.length;
    assert(sortOrder.length >= count);
    uint[sortBins] histogram;
    foreach (i; 0 .. count) {
        uint key = (errorBits[i] << 1) >> (32 - sortBits);
        if (key >= sortBins)
            key = sortBins - 1;
        histogram[key]++;
    }
    size_t sum = 0;
    foreach (i; 0 .. sortBins) {
        size_t c = histogram[i];
        histogram[i] = cast(uint) sum;
        sum += c;
    }
    assert(sum == count);
    foreach (i; 0 .. count) {
        uint key = (errorBits[i] << 1) >> (32 - sortBits);
        if (key >= sortBins)
            key = sortBins - 1;
        sortOrder[histogram[key]++] = cast(uint) i;
    }
}

/**
 * Three-pass 10-bit radix sort of float keys from `clusterizer.cpp`.
 * `destination` receives the order of indices. `scratch` must be the same length.
 */
void radixSortFloat(uint[] destination, uint[] scratch, const(float)[] keys) pure nothrow @nogc {
    size_t count = keys.length;
    assert(destination.length >= count);
    assert(scratch.length >= count);
    uint[1024][3] hist;
    foreach (i; 0 .. count) {
        uint id = radixFloat(floatBits(keys[i]));
        hist[0][(id >> 2) & 1023]++;
        hist[1][(id >> 12) & 1023]++;
        hist[2][(id >> 22) & 1023]++;
    }
    foreach (pass; 0 .. 3) {
        uint sum = 0;
        foreach (b; 0 .. 1024) {
            uint h = hist[pass][b];
            hist[pass][b] = sum;
            sum += h;
        }
        assert(sum == count);
    }
    foreach (i; 0 .. count)
        destination[i] = cast(uint) i;

    bool inDest = true;
    foreach (pass; 0 .. 3) {
        int bitoff = pass * 10 + 2;
        uint[] src = inDest ? destination[0 .. count] : scratch[0 .. count];
        uint[] dst = inDest ? scratch[0 .. count] : destination[0 .. count];
        foreach (i; 0 .. count) {
            uint id = (radixFloat(floatBits(keys[src[i]])) >> bitoff) & 1023;
            dst[hist[pass][id]++] = src[i];
        }
        inDest = !inDest;
    }
    if (!inDest)
        destination[0 .. count] = scratch[0 .. count];
}

/// Min-heap node from `partition.cpp`. `order` is the heap key (smaller first).
struct GroupOrder {
    uint id;
    int order;
}

static assert(isPod!GroupOrder);

/**
 * Push `item` at `heap[size]`. Caller increments its own counter, matching
 * `heapPush(order, pending++, item)`.
 */
void heapPush(GroupOrder[] heap, size_t size, GroupOrder item) pure nothrow @nogc {
    assert(size < heap.length);
    heap[size++] = item;
    size_t i = size - 1;
    while (i > 0 && heap[i].order < heap[(i - 1) / 2].order) {
        size_t p = (i - 1) / 2;
        GroupOrder temp = heap[i];
        heap[i] = heap[p];
        heap[p] = temp;
        i = p;
    }
}

/**
 * Pop the minimum. `size` is the length before the pop, matching
 * `heapPop(order, pending--)`.
 */
GroupOrder heapPop(GroupOrder[] heap, size_t size) pure nothrow @nogc {
    assert(size > 0 && size <= heap.length);
    GroupOrder top = heap[0];
    heap[0] = heap[--size];
    size_t i = 0;
    while (i * 2 + 1 < size) {
        size_t j = i * 2 + 1;
        if (j + 1 < size && heap[j + 1].order < heap[j].order)
            j++;
        if (heap[j].order >= heap[i].order)
            break;
        GroupOrder temp = heap[i];
        heap[i] = heap[j];
        heap[j] = temp;
        i = j;
    }
    return top;
}

/**
 * Move `data[end]` to `data[begin]`, shifting the open range up by one.
 * This is the meshlet optimizer's `memmove` (an insertion, not a swap).
 */
void rotateRight(T)(T[] data, size_t begin, size_t end) pure nothrow @nogc {
    assert(begin <= end && end < data.length);
    if (begin == end)
        return;
    T saved = data[end];
    foreach_reverse (k; begin .. end)
        data[k + 1] = data[k];
    data[begin] = saved;
}

@safe pure nothrow @nogc unittest {
    assert(radixFloat(floatBits(1.0f)) > radixFloat(floatBits(-1.0f)));
    assert(radixFloat(floatBits(-2.0f)) < radixFloat(floatBits(-1.0f)));

    ushort[5] keys = [3, 1, 3, 0, 1];
    uint[5] source = [0, 1, 2, 3, 4];
    uint[5] dest;
    radixSort10(dest[], source[], keys[]);
    // stable: key 0 -> 3, key 1 -> 1 then 4, key 3 -> 0 then 2
    assert(dest == [3, 1, 4, 0, 2]);

    uint[4] ckeys = [1, 0, 1, 0];
    uint[4] order;
    countingSortOrder(order[], ckeys[], 2);
    assert(order == [1, 3, 0, 2]);

    uint[4] errors = [0x3f80_0000, 0x4000_0000, 0x3f00_0000, 0];
    uint[4] eorder;
    sortEdgeCollapses(eorder[], errors[]);
    assert(eorder[0] == 3);

    float[4] fkeys = [1.0f, -2.0f, 0.0f, -0.5f];
    uint[4] forder;
    uint[4] scratch;
    radixSortFloat(forder[], scratch[], fkeys[]);
    foreach (i; 1 .. 4) {
        uint a = radixFloat(floatBits(fkeys[forder[i - 1]]));
        uint b = radixFloat(floatBits(fkeys[forder[i]]));
        assert(a <= b);
    }

    GroupOrder[4] heap;
    size_t n = 0;
    heapPush(heap[], n++, GroupOrder(1, 5));
    heapPush(heap[], n++, GroupOrder(2, 1));
    heapPush(heap[], n++, GroupOrder(3, 3));
    assert(heapPop(heap[], n--).id == 2);
    assert(heapPop(heap[], n--).id == 3);
    assert(heapPop(heap[], n--).id == 1);

    int[5] seq = [0, 1, 2, 3, 4];
    rotateRight(seq[], 1, 3);
    assert(seq == [0, 3, 1, 2, 4]);
}
