// How many cards does the barrier mark, compared to the memory the program
// wrote? A barrier that marks cards that were not written makes a concurrent
// collector rescan memory for nothing, and in a program that writes pointers
// all the time the rescans never catch up with the writes.
//
// Each case clears the cards, performs stores that touch a known footprint, and
// counts the marked cards. "exact" is the footprint in cards; "max" is the
// number the barrier is allowed to mark (the footprint plus a little for the
// objects around it).
//
// Build like mark_race.d (DMD with -preview=gcbarrier and the instrumented
// libraries, or LDC with -gc-card-marking), run with --DRT-gcopt=gc:sdcq.
import core.memory : GC;
import core.stdc.stdio : printf;

extern(C) extern __gshared size_t __sd_gc_card_lo;
extern(C) extern __gshared size_t __sd_gc_card_n;
extern(C) extern __gshared ubyte* __sd_gc_card_base;

enum CardShift = 9;

size_t marked(const(void)* start, size_t bytes)
{
    const first = (cast(size_t) start - __sd_gc_card_lo) >> CardShift;
    const last = (cast(size_t) start + bytes - 1 - __sd_gc_card_lo) >> CardShift;
    size_t n;
    foreach (c; first .. last + 1)
        n += __sd_gc_card_base[c];
    return n;
}

void clear(const(void)* start, size_t bytes)
{
    const first = (cast(size_t) start - __sd_gc_card_lo) >> CardShift;
    const last = (cast(size_t) start + bytes - 1 - __sd_gc_card_lo) >> CardShift;
    foreach (c; first .. last + 1)
        __sd_gc_card_base[c] = 0;
}

int failures;

void report(const(char)* what, size_t got, size_t exact, size_t max)
{
    const ok = got >= exact && got <= max;
    printf("%s %-44s marked %7zu  (footprint %zu, at most %zu)\n", (ok ? "ok  " : "FAIL").ptr, what, got, exact, max);
    if (!ok) failures++;
}

final class Obj { Obj next; Obj other; ubyte[40] pad; }
struct Rec { void* a; void* b; long c; }

// the stores, each in a function of its own
pragma(inline, false) void fillArray(void*[] a, void* p) { foreach (i; 0 .. a.length) a[i] = p; }
pragma(inline, false) void fillFields(Obj[] os, Obj p) { foreach (o; os) o.next = p; }
pragma(inline, false) void fillFieldsEvery(Obj[] os, Obj p, size_t step) { for (size_t i = 0; i < os.length; i += step) os[i].next = p; }
pragma(inline, false) void fillStructs(Rec[] rs, void* p) { foreach (ref r; rs) r.a = p; }
pragma(inline, false) void copyPtrs(void*[] d, void*[] s) { d[] = s[]; }
final class Quad { Obj a, b, c, d; }
pragma(inline, false) void fillQuads(Quad[] qs, Obj p) { foreach (q; qs) { q.a = p; q.b = p; q.c = p; q.d = p; } }
pragma(inline, false) void sameCard(Obj o, Obj p) { foreach (i; 0 .. 100_000) o.next = p; }

int main()
{
    GC.disable();

    enum N = 100_000;
    const bytesArray = N * (void*).sizeof;

    // 1. a pointer array, every element
    auto arr = new void*[N];
    auto probe = new Obj;
    clear(arr.ptr, bytesArray);
    fillArray(arr, cast(void*) probe);
    report("array of 100k pointers, every element", marked(arr.ptr, bytesArray), bytesArray / 512, bytesArray / 512 + 2);

    // 2. one field of each of 100k objects (each object is 64 bytes: 8 per card)
    auto objs = new Obj[N];
    foreach (ref o; objs) o = new Obj;
    const objBytes = Obj.classinfo.initializer.length;
    // objects are allocated one after the other, so they are contiguous
    auto lo = cast(void*) objs[0];
    auto hi = cast(void*) objs[N - 1] + objBytes;
    const span = cast(size_t) (hi - lo);
    clear(lo, span);
    fillFields(objs, probe);
    // the footprint is the distinct cards that hold a `next` field (the
    // allocator's size class decides how far apart the objects are)
    size_t distinct, lastCard = size_t.max;
    foreach (o; objs)
    {
        const c = (cast(size_t) cast(void*) o + Obj.next.offsetof - __sd_gc_card_lo) >> CardShift;
        if (c != lastCard) { distinct++; lastCard = c; }
    }
    report("field of 100k objects, every object", marked(lo, span), distinct, distinct);

    // 3. one object in 64: very few cards
    clear(lo, span);
    fillFieldsEvery(objs, probe, 64);
    // 100k / 64 = 1562 objects, each in a card of its own or sharing one with up
    // to 7 neighbours that are not written, so between 1562 / 8 cards and 1562.
    report("field of every 64th object", marked(lo, span), N / 64 / 8, N / 64 + 4);

    // 4. a struct array, one field
    auto recs = new Rec[N];
    const recBytes = N * Rec.sizeof;
    clear(recs.ptr, recBytes);
    fillStructs(recs, cast(void*) probe);
    report("field a of 100k 24-byte structs", marked(recs.ptr, recBytes), recBytes / 512, recBytes / 512 + 2);

    // 5. a pointer copy
    auto dst = new void*[N];
    clear(dst.ptr, bytesArray);
    copyPtrs(dst, arr);
    report("copy of 100k pointers", marked(dst.ptr, bytesArray), bytesArray / 512, bytesArray / 512 + 2);

    // 6. the same field, 100k times: one card
    auto one = new Obj;
    clear(cast(void*) one, objBytes);
    sameCard(one, probe);
    report("the same field 100k times", marked(cast(void*) one, objBytes), 1, 2);

    // 7. cards outside what was written must stay clear: the arrays above are
    // clean beyond their ends, so check a quiet array that nothing wrote to
    auto quiet = new void*[N];
    clear(quiet.ptr, bytesArray);
    fillArray(arr, cast(void*) probe);       // writes elsewhere
    report("a neighbour nobody wrote to", marked(quiet.ptr, bytesArray), 0, 0);

    // 8. four stores in a row to one object share a barrier (two cards: the
    // lowest and the highest address): the cards must be exactly those of the fields
    auto quads = new Quad[N];
    foreach (ref q; quads) q = new Quad;
    auto qlo = cast(void*) quads[0];
    const qspan = cast(size_t) (cast(void*) quads[N - 1] + Quad.classinfo.initializer.length) - cast(size_t) qlo;
    clear(qlo, qspan);
    fillQuads(quads, probe);
    const qmarked = marked(qlo, qspan);     // before the bookkeeping below allocates
    size_t qdistinct;
    bool[size_t] seen;
    foreach (q; quads)
        foreach (off; [Quad.a.offsetof, Quad.b.offsetof, Quad.c.offsetof, Quad.d.offsetof])
        {
            const c = (cast(size_t) cast(void*) q + off - __sd_gc_card_lo) >> CardShift;
            if (c !in seen) { seen[c] = true; qdistinct++; }
        }
    report("four fields in a row of 100k objects", qmarked, qdistinct, qdistinct);

    if (failures == 0)
        printf("CARD PRECISION OK\n");
    else
        printf("CARD PRECISION: %d failures\n", failures);
    return failures == 0 ? 0 : 1;
}
