// A benchmark for runs of pointer stores to one object: a scene of linked
// entities, each with eight pointer fields, whose links are rewritten every
// frame (the way a game re-parents nodes, rebuilds neighbour lists or resets a
// pooled object), with a little allocation churn so that the collector runs
// beside it. The stores `e.a = x; e.b = y; ...` are what the barrier
// clustering of `-preview=gcbarrier` shares one barrier for.
//
//   entity_init SECONDS LIVE_MIB [RELINKS_PER_FRAME=200000] [CHURN_PER_FRAME=20000] [FPS=60, 0 = unpaced]
//
// LIVE_MIB is the size of the scene (do not go past 2048 for this machine).
// Prints the frame times, and the time per relink in a phase with the
// collector idle (GC.disable), which is the cost of the stores alone.
import core.memory : GC;
import core.stdc.stdio : printf;
import std.conv : to;
import core.thread : Thread;
import core.time : dur, Duration, MonoTime;
import std.algorithm : sort;

final class Entity
{
    Entity parent, firstChild, nextSibling, prevSibling;
    Entity target, owner, left, right;
    ulong id;
}

struct Rng
{
    ulong s;
    ulong next() { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s; }
}

Entity[] scene;
Rng rng = Rng(0x9e3779b97f4a7c15UL);

// Each in a function of its own, so the stores are not mixed with the loop.
pragma(inline, false) void relink(Entity e, Entity p, Entity c, Entity n, Entity pr,
                                  Entity t, Entity o, Entity l, Entity r)
{
    e.parent = p;
    e.firstChild = c;
    e.nextSibling = n;
    e.prevSibling = pr;
    e.target = t;
    e.owner = o;
    e.left = l;
    e.right = r;
}

// Entities are updated in order, a window that slides through the scene each
// frame, and link to entities close to them (a scene graph, a neighbour list):
// like a game, the writes are local, not spread over the whole heap.
size_t cursor;
enum Reach = 64;

pragma(inline, false) Entity near(size_t i)
{
    return scene[(i + rng.next() % Reach) % scene.length];
}

pragma(inline, false) void relinkBatch(size_t count)
{
    const m = scene.length;
    foreach (_; 0 .. count)
    {
        const i = cursor++ % m;
        relink(scene[i], near(i), near(i), near(i), near(i), near(i), near(i), near(i), near(i));
    }
}

pragma(inline, false) void churn(size_t count)
{
    const m = scene.length;
    foreach (_; 0 .. count)
    {
        const i = (cursor + rng.next() % 50_000) % m;       // near the window
        auto e = new Entity;
        e.id = rng.next();
        relink(e, near(i), near(i), near(i), near(i), near(i), near(i), near(i), near(i));
        scene[i] = e;                   // the old one becomes garbage
    }
}

int main(string[] args)
{
    const secs = args.length > 1 ? args[1].to!int : 20;
    const liveMiB = args.length > 2 ? args[2].to!int : 1024;
    const relinks = args.length > 3 ? args[3].to!int : 200_000;
    const churnN = args.length > 4 ? args[4].to!int : 20_000;
    const fps = args.length > 5 ? args[5].to!int : 60;      // 0: as fast as it goes
    // (not computed inside the loop: with fps == 0 and -O, a build of dmd divided by zero there
    // before testing fps > 0, which looks like a division hoisted out of its condition)
    const frameUs = fps > 0 ? 1_000_000 / fps : 0;

    const entityBytes = Entity.classinfo.initializer.length;
    const n = cast(size_t) liveMiB * 1024 * 1024 / (entityBytes + 16);   // + the slot's rounding
    scene = new Entity[n];
    foreach (ref e; scene)
        e = new Entity;
    foreach (i, e; scene)
        e.id = i;
    printf("scene: %zu entities of %zu bytes (about %d MiB)\n", n, entityBytes, liveMiB);

    // Building the scene allocated 1 GiB at full speed, which no collector
    // keeps up with; settle before measuring the steady state.
    GC.collect();

    // 1. the cost of the stores alone: the collector is off
    GC.disable();
    relinkBatch(200_000);                               // warm up
    enum Reps = 20;
    double[Reps] per;
    foreach (r; 0 .. Reps)
    {
        auto t0 = MonoTime.currTime;
        relinkBatch(500_000);
        per[r] = cast(double) (MonoTime.currTime - t0).total!"nsecs" / 500_000;
    }
    per[].sort();
    printf("relink of 8 fields, collector off: median %.1f ns per entity (%.2f ns per store), best %.1f\n",
           per[Reps / 2], per[Reps / 2] / 8, per[0]);
    GC.enable();

    // 2. frames with the collector running beside the program
    enum MaxFrames = 20 * 60 * 10;
    auto times = new long[MaxFrames];
    size_t frames;
    const t00 = MonoTime.currTime;
    while ((MonoTime.currTime - t00).total!"seconds" < secs && frames < MaxFrames)
    {
        const f0 = MonoTime.currTime;
        relinkBatch(relinks);
        churn(churnN);
        times[frames++] = (MonoTime.currTime - f0).total!"usecs";
        version (EntityInitTrace)
        {
            // what the program allocates, to compare with the heap's growth in the collector's trace
            import core.stdc.stdio : fprintf, stderr;
            if (frames % 100 == 0)
                fprintf(stderr, "prog t=%.2f s frames=%zu allocated=%zu MiB\n",
                        (MonoTime.currTime - t00).total!"msecs" / 1000.0, frames,
                        frames * churnN * entityBytes / (1024 * 1024));
        }
        if (times[frames - 1] > 16_000)
            printf("slow frame %zu at %.1f s: %ld us\n", frames, (f0 - t00).total!"msecs" / 1000.0, times[frames - 1]);

        // A game waits for the next frame; a loop that does not runs the program
        // several times faster than any game would, writes the heap that much
        // faster, and no collector can keep up with it.
        if (fps > 0)
        {
            const left = (f0 + dur!"usecs"(frameUs)) - MonoTime.currTime;
            if (left > Duration.zero)
                Thread.sleep(left);
        }
    }
    auto ts = times[0 .. frames];
    ts.sort();
    size_t over(long us) { size_t c; foreach (t; ts) if (t > us) c++; return c; }
    printf("frame_p50_us=%ld p99=%ld p999=%ld max=%ld over1ms=%zu over5ms=%zu over16ms=%zu frames=%zu\n",
           ts[frames / 2], ts[frames * 99 / 100], ts[frames * 999 / 1000], ts[frames - 1],
           over(1000), over(5000), over(16000), frames);
    return 0;
}
