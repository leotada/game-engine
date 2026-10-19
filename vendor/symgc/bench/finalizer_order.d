// A destructor that reads another dead object (the D spec says it must not, but it works with a collector that
// releases nothing before all finalizers ran, and programs rely on it). Other threads allocate heavily while the
// collector sweeps, so a slot released early is reused and overwritten, or poisoned with -version=Symgc_verify.
//
// Prints "FINALIZER ORDER OK" if no destructor found its partner damaged.
import core.atomic : atomicOp, atomicLoad, atomicStore;
import core.memory : GC;
import core.thread : Thread;
import core.stdc.stdio : printf;

shared size_t violations, finalized;
shared bool stop;

class B
{
    ulong marker;
    ubyte[200] pad;       // another size class than A, so another slab
    this(ulong m) { marker = m; }
}

class A
{
    B partner;
    ulong expected;
    ubyte[40] pad;
    this(B b, ulong e) { partner = b; expected = e; }
    ~this()
    {
        // Reads memory of an object that may be dead too.
        if (partner.marker != expected)
            atomicOp!"+="(violations, 1);
        atomicOp!"+="(finalized, 1);
    }
}

void churn()
{
    // Garbage of the size of B, to take the slots released by a sweep.
    ulong sink;
    while (!atomicLoad(stop))
    {
        auto b = new B(sink++);
        sink += b.marker & 1;
    }
}

int main()
{
    Thread[] ts;
    foreach (i; 0 .. 4) { auto t = new Thread(&churn); t.start(); ts ~= t; }

    enum Pairs = 400_000;
    foreach (i; 0 .. Pairs)
    {
        auto b = new B(0x1234_5678_0000_0000UL + i);
        auto a = new A(b, 0x1234_5678_0000_0000UL + i);
        // keep a few alive, drop the rest
        if (i % 1000 == 0) GC.addRoot(cast(void*) a);
    }

    atomicStore(stop, true);
    foreach (t; ts) t.join();
    GC.collect();

    printf("finalized=%zu violations=%zu\n", atomicLoad(finalized), atomicLoad(violations));
    if (atomicLoad(violations) == 0 && atomicLoad(finalized) > 0)
        printf("FINALIZER ORDER OK\n");
    return atomicLoad(violations) == 0 ? 0 : 1;
}
