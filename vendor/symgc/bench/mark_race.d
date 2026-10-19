// Stress test for a collector that marks while the program runs.
//
// The hazard: a thread takes a pointer out of the graph (into a local), the collector scans the place it came from
// and the place it is going to, and the thread stores the pointer into an object the collector already scanned.
// A mark that misses it frees a live object. Here every node carries its identity twice, so a node that was freed
// (and poisoned or reused) is noticed the next time a thread looks at it.
//
//   dmd ... mark_race.d <symgc sources> && SYMGC_CONCURRENT_MARK=1 ./mark_race [seconds] --DRT-gcopt=gc:sdcq
//
// Prints "MARK RACE OK <moves>" when no node was damaged.
import core.atomic : atomicOp, atomicLoad, atomicStore;
import core.thread : Thread;
import core.stdc.stdio : printf;
import core.stdc.stdlib : atoi;
import core.time : MonoTime, seconds;

enum Nodes = 4000;
enum Threads = 4;

shared size_t violations, moves;
shared bool stop;

struct Node
{
    ulong id;
    Node* a;
    Node* b;
    ulong check;       // id ^ Magic
    ubyte[40] pad;
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
    return n.id == expected && n.check == (expected ^ Magic);
}

__gshared Node*[] roots;   // the graph hangs off these, in the GC heap

void worker(uint seed)
{
    ulong x = 88172645463325252UL ^ seed;
    ulong next() { x ^= x << 13; x ^= x >> 7; x ^= x << 17; return x; }

    size_t myMoves;
    ulong sink;
    while (!atomicLoad(stop))
    {
        auto i = next() % Nodes;
        auto j = next() % Nodes;

        // Take a subtree out of the graph into a local...
        auto from = roots[i];
        auto held = (next() & 1) ? from.a : from.b;
        if (held is null)
            continue;
        auto heldId = held.id;
        if (!intact(held, heldId))
        {
            atomicOp!"+="(violations, 1);
            continue;
        }

        if (next() & 1) from.a = null; else from.b = null;

        // ...let the collector run while it only lives on our stack...
        foreach (_; 0 .. next() % 64)
        {
            auto g = new Node;      // garbage, drives the collections
            sink += cast(size_t) g;
        }

        // ...and store it into another object (which may have been scanned already).
        auto to = roots[j];
        if (next() & 1) to.a = held; else to.b = held;

        // The node we held must still be what it was, and so must what hangs off it.
        if (!intact(held, heldId))
            atomicOp!"+="(violations, 1);
        foreach (child; [held.a, held.b])
            if (child !is null && !intact(child, child.id))
                atomicOp!"+="(violations, 1);

        // Sometimes grow the graph: a new node that points to an old one.
        if ((next() & 7) == 0)
        {
            auto n = make(heldId + 1_000_000);
            n.a = held;
            roots[i].a = n;
        }

        myMoves++;
    }
    atomicOp!"+="(moves, myMoves);
    if (sink == 1) printf("");
}

int main(string[] args)
{
    uint secs = 10;

    // The digits of the first numeric argument.
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

    // Everything still reachable must be intact.
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

    printf("moves=%zu violations=%zu final_check=%zu/%zu bad\n", atomicLoad(moves), atomicLoad(violations), bad, checked);
    if (atomicLoad(violations) == 0 && bad == 0)
        printf("MARK RACE OK %zu\n", atomicLoad(moves));
    return atomicLoad(violations) == 0 && bad == 0 ? 0 : 1;
}

import core.time : dur;
