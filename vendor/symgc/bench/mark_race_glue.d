// Stress test for a collector that marks while the program runs, aimed at the
// stores the code generator makes by itself.
//
// mark_race.d moves nodes with plain assignments of fields. A barrier that
// rewrites assignments in the frontend would pass it. This one stores the node
// through forms in which the compiler writes the pointer without an assignment
// expression existing:
//
//   0  an array literal           h.arr = [n, o]      (the elements are stored by
//                                                      the code generator into the
//                                                      memory the runtime allocated)
//   1  a heap struct              h.pp = new Pair(n, o)
//   2  a struct literal           h.ps = Pair(n, o)
//   3  a closure                  h.dg = () => n      (the frame holds n)
//   4  an append                  h.list ~= n         (druntime)
//   5  an associative array       h.map[id] = n       (druntime)
//   6  an atomic store            atomicStore(h.sp, n)  (assembly or an intrinsic)
//   7  a compare-and-swap         cas(&h.cp, null, n)
//
// After the store the only way to the node is through the holder, a collection
// runs, and the node is read back from the holder and checked. A barrier that
// misses one of these forms lets the collector free the node, and the check
// finds it reused or poisoned.
//
//   build with the card barrier, run with --DRT-gcopt=gc:sdcq [seconds]
//   prints "MARK RACE GLUE OK <moves>" when no node was damaged.
import core.atomic : atomicOp, atomicLoad, atomicStore, cas;
import core.thread : Thread;
import core.stdc.stdio : printf;
import core.time : MonoTime, seconds, dur;

enum Nodes = 4000;
enum Threads = 4;
enum Forms = 9;

shared size_t violations, moves;
shared size_t[Forms] perForm;
shared bool stop;

version (GlueUnmarked)
{
    // The values are created in mark_race_glue_ext.d, built without the barrier.
    import mark_race_glue_ext;
}
else
{
    struct Node
    {
        ulong id;
        Node* a;
        Node* b;
        ulong check;       // id ^ Magic
        ubyte[40] pad;
    }

    struct Pair
    {
        Node* x;
        Node* y;
    }
}

enum ulong Magic = 0x9e3779b97f4a7c15UL;

Node* make(ulong id)
{
    auto n = new Node;
    n.id = id;
    n.check = id ^ Magic;
    return n;
}

bool intact(Node* n, ulong expected)
{
    return n !is null && n.id == expected && n.check == (expected ^ Magic);
}

/// One per thread: the places the node is stored into. Old objects, scanned by
/// the collector many times, like the objects of a long-running program.
final class Holder
{
    Node*[] arr;
    Pair* pp;
    Pair ps;
    Node* delegate() dg;
    Node*[] list;
    Node*[ulong] map;
    shared(Node)* sp;           // form 6
    shared(Node)* cp;           // form 7
    Node* t1, t2, t3;           // form 8: three stores in a row to one object share a barrier
}

__gshared Node*[] roots;

// Each form in its own function, so that nothing of the node stays in the
// caller's frame.
version (GlueUnmarked)
{
    // The assignment into the holder has the barrier; the creation of the value does not.
    pragma(inline, false) void put0(Holder h, Node* n, Node* o) { h.arr = mk0(n, o); }
    pragma(inline, false) void put1(Holder h, Node* n, Node* o) { h.pp = mk1(n, o); }
    pragma(inline, false) void put3(Holder h, Node* n) { h.dg = mk3(n); }
}
else
{
    pragma(inline, false) void put0(Holder h, Node* n, Node* o) { h.arr = [n, o, o, o, o, o, o, o, o, o, o, o, o, o, o, o]; }
    pragma(inline, false) void put1(Holder h, Node* n, Node* o) { h.pp = new Pair(n, o); }
    pragma(inline, false) void put3(Holder h, Node* n) { h.dg = () => n; }
}
pragma(inline, false) void put2(Holder h, Node* n, Node* o) { h.ps = Pair(n, o); }
pragma(inline, false) void put4(Holder h, Node* n) { h.list = null; h.list ~= n; }
pragma(inline, false) void put5(Holder h, Node* n) { h.map = null; h.map[n.id] = n; }
// Atomic operations store through assembly or intrinsics: invisible to a barrier
// that looks at the stores the compiler makes. core.atomic reports them itself.
pragma(inline, false) void put6(Holder h, Node* n) { atomicStore(h.sp, cast(shared(Node)*) n); }
pragma(inline, false) void put7(Holder h, Node* n) { h.cp = null; cas(&h.cp, cast(shared(Node)*) null, cast(shared(Node)*) n); }

pragma(inline, false) void put8(Holder h, Node* n) { h.t1 = n; h.t2 = n; h.t3 = n; }

pragma(inline, false) Node* get(Holder h, uint form, ulong id)
{
    switch (form)
    {
        case 0: return h.arr.length ? h.arr[0] : null;
        case 1: return h.pp ? h.pp.x : null;
        case 2: return h.ps.x;
        case 3: return h.dg ? h.dg() : null;
        case 4: return h.list.length ? h.list[0] : null;
        case 5: auto p = id in h.map; return p ? *p : null;
        case 6: return cast(Node*) atomicLoad(h.sp);
        case 7: return cast(Node*) atomicLoad(h.cp);
        default: return h.t2;       // form 8 (t1 and t3 hold it too, but only one need survive)
    }
}

/// Take a node out of the graph and store it into the holder, by `form`.
/// Returns its id, or 0 if there was nothing to take.
pragma(inline, false) ulong takeAndPut(Holder h, size_t i, bool slotA, uint form, size_t k)
{
    auto from = roots[i];
    auto held = slotA ? from.a : from.b;
    if (held is null)
        return 0;

    auto id = held.id;
    if (!intact(held, id))
    {
        atomicOp!"+="(violations, 1);
        return 0;
    }

    if (slotA) from.a = null; else from.b = null;

    auto other = roots[k].a;
    switch (form)
    {
        case 0: put0(h, held, other); break;
        case 1: put1(h, held, other); break;
        case 2: put2(h, held, other); break;
        case 3: put3(h, held); break;
        case 4: put4(h, held); break;
        case 5: put5(h, held); break;
        case 6: put6(h, held); break;
        case 7: put7(h, held); break;
        default: put8(h, held); break;
    }

    return id;
}

pragma(inline, false) void burn(ulong n)
{
    ulong sink;
    foreach (_; 0 .. n)
    {
        auto g = new Node;      // garbage of the node's size: drives the collections and reuses freed slots
        sink += cast(size_t) g;
    }
    if (sink == 1) printf("");
}

void worker(uint seed)
{
    ulong x = 88172645463325252UL ^ seed;
    ulong next() { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x; }

    auto h = new Holder;
    size_t myMoves;
    size_t[Forms] mine;

    while (!atomicLoad(stop))
    {
        auto i = next() % Nodes;
        auto slotA = (next() & 1) != 0;
        auto form = cast(uint) (next() % Forms);

        auto id = takeAndPut(h, i, slotA, form, next() % Nodes);
        if (id == 0)
            continue;

        // The node is reachable only through the holder now.
        burn(next() % 256);

        auto back = get(h, form, id);
        if (!intact(back, id))
        {
            atomicOp!"+="(violations, 1);
            continue;
        }

        // Put it back so that the graph does not run dry.
        if (slotA) roots[i].a = back; else roots[i].b = back;

        // Grow the graph: a new node that points to it. The nodes of `roots`
        // are alive whatever the collector does; these are alive only if the
        // collector finds them through the graph, which is what is tested.
        if ((next() & 3) == 0)
        {
            auto n = make(id + 1_000_000);
            n.a = back;
            roots[i].a = n;
        }

        myMoves++;
        mine[form]++;
    }

    atomicOp!"+="(moves, myMoves);
    foreach (f; 0 .. Forms)
        atomicOp!"+="(perForm[f], mine[f]);
}

int main(string[] args)
{
    uint secs = 10;

    foreach (a; args[1 .. $])
    {
        if (a.length && a[0] >= '0' && a[0] <= '9')
        {
            secs = 0;
            foreach (c; a) secs = secs * 10 + (c - '0');
            break;
        }
    }

    roots = new Node*[](Nodes);
    foreach (i, ref r; roots)
        r = make(i);
    foreach (i, r; roots)
    {
        r.a = roots[(i * 7 + 1) % Nodes];
        r.b = roots[(i * 13 + 5) % Nodes];
    }

    Thread[] ts;
    foreach (i; 0 .. Threads)
    {
        auto seed = cast(uint) (i + 1);
        auto t = new Thread({ worker(seed); });
        t.start();
        ts ~= t;
    }

    auto end = MonoTime.currTime + seconds(secs);
    while (MonoTime.currTime < end)
        Thread.sleep(dur!"msecs"(50));

    atomicStore(stop, true);
    foreach (t; ts) t.join();

    size_t checked, bad;
    foreach (r; roots)
    {
        foreach (n; [r, r.a, r.b])
        {
            if (n is null) continue;
            checked++;
            if (!intact(n, n.id)) bad++;
        }
    }

    printf("moves=%zu violations=%zu final_check=%zu/%zu bad  per form:", atomicLoad(moves), atomicLoad(violations), bad, checked);
    foreach (f; 0 .. Forms)
        printf(" %zu", atomicLoad(perForm[f]));
    printf("\n");

    const ok = atomicLoad(violations) == 0 && bad == 0;
    if (ok)
        printf("MARK RACE GLUE OK %zu\n", atomicLoad(moves));
    return ok ? 0 : 1;
}
