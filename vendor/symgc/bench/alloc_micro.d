/**
 * Allocation-path microbenchmarks for the small-heap investigation.
 *
 *   A: class with one int + one class ref, retain a sliding window (inventory-like)
 *   B: new int[](32) appendable NO_SCAN churn
 *   C: large scanned struct array (PointerVertex-like)
 *
 * Build with engine_gc_build pattern (two binaries). Prints ns/op.
 */
module alloc_micro;

import core.memory : GC;
import core.time   : MonoTime;
import std.stdio   : writefln, writeln;
import std.conv    : to;

class Node
{
    int  value;
    Node next;
}

struct PtrVert
{
    float  x, y, z, u, v;
    string material;
    Node   owner;
}

void benchA(size_t iters) @trusted
{
    enum W = 4096;
    Node[] win = new Node[](W);
    foreach (i; 0 .. W)
        win[i] = new Node;
    const t0 = MonoTime.currTime;
    foreach (i; 0 .. iters)
    {
        auto n = new Node;
        n.value = cast(int)i;
        n.next = win[i % W];
        win[i % W] = n;
    }
    const dt = MonoTime.currTime - t0;
    writefln("A_class_list iters=%s ns_per_op=%.1f", iters,
             dt.total!"nsecs" / cast(double)iters);
}

void benchB(size_t iters) @trusted
{
    int[] sink;
    const t0 = MonoTime.currTime;
    foreach (i; 0 .. iters)
    {
        auto a = new int[](32);
        a[0] = cast(int)i;
        if ((i & 63) == 0)
            sink = a;
    }
    const dt = MonoTime.currTime - t0;
    writefln("B_int32_array iters=%s ns_per_op=%.1f sink_len=%s", iters,
             dt.total!"nsecs" / cast(double)iters, sink.length);
}

void benchC(size_t iters) @trusted
{
    PtrVert[] sink;
    auto owner = new Node;
    const t0 = MonoTime.currTime;
    foreach (i; 0 .. iters)
    {
        auto chunk = new PtrVert[](4096);
        chunk[0].owner = owner;
        chunk[0].material = "stone";
        if ((i & 15) == 0)
            sink = chunk;
    }
    const dt = MonoTime.currTime - t0;
    writefln("C_ptr_vertex iters=%s ns_per_op=%.1f", iters,
             dt.total!"nsecs" / cast(double)iters);
}

void main(string[] args) @trusted
{
    size_t iters = 2_000_000;
    if (args.length > 1)
        iters = args[1].to!size_t;
    GC.collect();
    benchA(iters / 4);   // class alloc is heavier; fewer iters
    GC.collect();
    benchB(iters);
    GC.collect();
    benchC(iters / 50);  // large arrays
}
