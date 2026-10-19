/**
 * Phobos-free GC workloads, so one binary built with the repo's dmd and druntime can be run
 * under any collector linked in: --DRT-gcopt=gc:conservative, gc:sdc (symgc, with the banner
 * suppressed by gc:sdcq), and later gc:immix.
 *
 *   gcb alloc <threads> <allocs-per-thread>
 *   gcb frag <steps> <slots> [max-size]      (max-size 2032 keeps objects out of large-object space)
 *   gcb trav <nodes> <traversals>            (user-space cache misses via perf_event_open)
 *   gcb tree <depth>
 *   gcb latency <live-MiB> <requests>
 *   gcb mixed <threads> <seconds>            (threads allocating, one holding a big live set)
 *
 * Prints one "RESULT key=value ..." line.
 */
import core.memory;
import core.stdc.stdio;
import core.stdc.stdlib : atoi, atol, qsort;
import core.thread;
import core.time;

version (SymGC) import symgc.gcobj;

extern (C) __gshared string[] rt_options = []; // gc chosen on the command line

size_t statusKiB(const(char)* key)
{
    auto f = fopen("/proc/self/status", "r");
    if (!f) return 0;
    char[256] line;
    size_t v;
    size_t n = 0;
    while (fgets(line.ptr, 256, f))
    {
        // match "<key>: <n> kB"
        size_t k;
        while (key[k] && line[k] == key[k]) ++k;
        if (!key[k] && sscanf(line.ptr + k, ": %zu kB", &v) == 1) { n = v; break; }
    }
    fclose(f);
    return n;
}

void result(const(char)* name, double secs, double ops, const(char)* extra = "")
{
    auto ps = GC.profileStats();
    printf("RESULT workload=%s seconds=%.4f mops=%.3f rss_kib=%zu peak_kib=%zu gcs=%zu gc_ms=%.1f maxpause_ms=%.2f %s\n",
        name, secs, ops / secs / 1e6, statusKiB("VmRSS"), statusKiB("VmHWM"),
        cast(size_t) ps.numCollections, ps.totalCollectionTime.total!"usecs" / 1000.0,
        ps.maxPauseTime.total!"usecs" / 1000.0, extra);
}

double now() { return MonoTime.currTime.ticks / cast(double) MonoTime.ticksPerSecond; }

ulong nextRng(ref ulong r) { r = r * 6364136223846793005UL + 1442695040888963407UL; return r >> 33; }

// ----------------------------------------------------------------------------- alloc

final class Node { Node next; size_t payload; }
__gshared size_t allocN = 1_000_000;
void* gcSinkShared;

void allocWorker()
{
    enum window = 64;
    Node[window] ring;
    void* sink;
    foreach (i; 0 .. allocN)
    {
        auto n = new Node;
        n.payload = i;
        n.next = (i & 1) ? ring[(i + 1) % window] : null;
        ring[i % window] = n;
        if ((i & 15) == 0)
        {
            auto a = new ubyte[](16 + (i & 0x3F0));
            a[0] = cast(ubyte) i;
            sink = a.ptr;
        }
    }
    if (sink is null && ring[0] is null) printf("x");
    foreach (s; 0 .. window)
        if (ring[s] is null || ring[s].payload % window != s) { printf("FAILED ring\n"); }
}

void runAlloc(int threads)
{
    immutable t0 = now();
    Thread[] ts;
    foreach (i; 0 .. threads)
    {
        auto t = new Thread(&allocWorker);
        t.start();
        ts ~= t;
    }
    foreach (t; ts) t.join();
    result("alloc", now() - t0, cast(double) allocN * threads * 1.0625);
}

// ----------------------------------------------------------------------------- frag

size_t pickSize(ref ulong rng)
{
    immutable r = nextRng(rng);
    switch (r % 10)
    {
        case 0: .. case 5: return 16 + (r >> 4) % 240;
        case 6: .. case 8: return 256 + (r >> 4) % 3840;
        default:           return 4096 + (r >> 4) % 61440;
    }
}

void runFrag(size_t steps, size_t slotCount, size_t maxSize)
{
    auto slots = new ubyte[][](slotCount);
    ulong rng = 42;
    size_t[1024] samples;
    size_t ns;
    immutable every = steps / 512 + 1;
    immutable t0 = now();
    foreach (step; 0 .. steps)
    {
        immutable i = nextRng(rng) % slotCount;
        auto n = pickSize(rng);
        if (n > maxSize) n = 16 + n % (maxSize - 16);
        slots[i] = new ubyte[](n);
        slots[i][0] = 1;
        if (step % every == 0 && ns < 1024) samples[ns++] = statusKiB("VmRSS");
    }
    immutable secs = now() - t0;
    size_t sum, cnt;
    foreach (i; ns / 2 .. ns) { sum += samples[i]; ++cnt; }
    char[96] extra;
    snprintf(extra.ptr, 96, "steady_rss_kib=%zu", cnt ? sum / cnt : 0);
    foreach (s; slots) if (s.length && s[0] != 1) printf("FAILED slot\n");
    result("frag", secs, steps, extra.ptr);
}

// ----------------------------------------------------------------------------- trav

final class Small { Small left, right; size_t v; }
final class Medium { Medium left, right; size_t v; ubyte[96] pad; }
final class Large { Large left, right; size_t v; ubyte[400] pad; }
final class ListNode { ListNode next; size_t v; ubyte[24] pad; }
void* travSink;

Small buildSmall(size_t n)
{
    if (!n) return null;
    auto s = new Small;
    s.v = n;
    travSink = cast(void*) new Medium;
    if (n % 4 == 0) travSink = cast(void*) new Large;
    s.left = buildSmall(n / 2);
    s.right = buildSmall(n - n / 2 - 1);
    return s;
}
size_t sumT(Small s) { return s is null ? 0 : s.v + sumT(s.left) + sumT(s.right); }
size_t sumL(ListNode n) { size_t t; for (; n; n = n.next) t += n.v; return t; }

import perfcount;

void runTrav(size_t nodes, size_t traversals)
{
    auto tree = buildSmall(nodes);
    ListNode head;
    foreach (i; 0 .. nodes)
    {
        auto n = new ListNode;
        n.v = i;
        n.next = head;
        head = n;
        if (i % 3 == 0) travSink = (new ubyte[](200 + i % 600)).ptr;
    }
    GC.collect();
    immutable e1 = sumT(tree), e2 = sumL(head);
    auto cm = PerfCounter.open(PERF_COUNT_HW_CACHE_MISSES);
    size_t total;
    immutable t0 = now();
    cm.start();
    foreach (_; 0 .. traversals) total += sumT(tree) + sumL(head);
    immutable misses = cm.stop();
    immutable secs = now() - t0;
    if (total != traversals * (e1 + e2)) printf("FAILED trav\n");
    char[128] extra;
    snprintf(extra.ptr, 128, "traversal_ms=%.3f misses_per_traversal=%.0f", secs * 1000 / traversals, cast(double) misses / traversals);
    result("trav", secs, cast(double) traversals * nodes * 2, extra.ptr);
}

// ----------------------------------------------------------------------------- tree

final class TreeNode { TreeNode left, right; int item; }
TreeNode bottomUp(int item, int depth)
{
    auto n = new TreeNode;
    n.item = item;
    if (depth > 0) { n.left = bottomUp(2 * item - 1, depth - 1); n.right = bottomUp(2 * item, depth - 1); }
    return n;
}
long check(TreeNode n) { return n.left is null ? n.item : n.item + check(n.left) - check(n.right); }

void runTree(int n)
{
    enum minDepth = 4;
    immutable maxDepth = minDepth + 2 > n ? minDepth + 2 : n;
    immutable t0 = now();
    long total = check(bottomUp(0, maxDepth + 1));
    auto longLived = bottomUp(0, maxDepth);
    size_t nodes;
    for (int depth = minDepth; depth <= maxDepth; depth += 2)
    {
        immutable iterations = 1 << (maxDepth - depth + minDepth);
        foreach (i; 1 .. iterations + 1)
        {
            total += check(bottomUp(i, depth)) + check(bottomUp(-i, depth));
        }
        nodes += cast(size_t) iterations * 2 * ((2UL << depth) - 1);
    }
    total += check(longLived);
    printf("tree checksum %lld\n", total);
    result("tree", now() - t0, nodes);
}

// ----------------------------------------------------------------------------- latency

extern (C) int cmpLong(const(void)* a, const(void)* b) nothrow @nogc
{
    immutable x = *cast(const(long)*) a, y = *cast(const(long)*) b;
    return x < y ? -1 : x > y;
}

final class Entry { Entry next; ubyte[] data; }
void* latSink;

void runLatency(size_t liveMiB, size_t requests)
{
    enum entrySize = 512;
    immutable count = liveMiB * 1024 * 1024 / entrySize;
    auto live = new Entry[](count);
    foreach (i, ref e; live)
    {
        e = new Entry;
        e.data = new ubyte[](entrySize - 64);
        if (i) e.next = live[i - 1];
    }
    auto samples = new long[](requests);
    ulong seed = 12345;
    immutable t0 = now();
    foreach (r; 0 .. requests)
    {
        immutable a = MonoTime.currTime;
        foreach (k; 0 .. 8)
        {
            auto tmp = new ubyte[](128 + k * 64);
            tmp[0] = cast(ubyte) r;
            latSink = tmp.ptr;
        }
        auto e = new Entry;
        e.data = new ubyte[](entrySize - 64);
        live[nextRng(seed) % count] = e;
        samples[r] = (MonoTime.currTime - a).total!"usecs";
    }
    immutable secs = now() - t0;
    qsort(samples.ptr, requests, long.sizeof, &cmpLong);
    char[160] extra;
    snprintf(extra.ptr, 160, "p50_us=%lld p99_us=%lld p999_us=%lld max_us=%lld", samples[requests / 2],
        samples[requests * 99 / 100], samples[requests * 999 / 1000], samples[$ - 1]);
    result("latency", secs, requests, extra.ptr);
}

// ----------------------------------------------------------------------------- main

int main(string[] args)
{
    if (args.length < 2) { fprintf(stderr, "usage: gcb <alloc|frag|trav|tree|latency> ...\n"); return 2; }
    // D strings from argv are slices, not guaranteed NUL-terminated: parse by length.
    size_t arg(size_t i, size_t d)
    {
        if (args.length <= i) return d;
        size_t v;
        foreach (c; args[i]) v = v * 10 + (c - '0');
        return v;
    }
    switch (args[1])
    {
        case "alloc": allocN = arg(3, 1_000_000); runAlloc(cast(int) arg(2, 4)); break;
        case "frag": runFrag(arg(2, 10_000_000), arg(3, 100_000), arg(4, 65535)); break;
        case "trav": runTrav(arg(2, 1_000_000), arg(3, 10)); break;
        case "tree": runTree(cast(int) arg(2, 16)); break;
        case "latency": runLatency(arg(2, 256), arg(3, 200_000)); break;
        case "frames": runFrames(arg(2, 512), arg(3, 1200), arg(4, 5000)); break;
        default: fprintf(stderr, "unknown workload\n"); return 2;
    }
    return 0;
}

// ----------------------------------------------------------------------------- frames
// A game-shaped loop: a large live world, and every frame does a fixed amount of allocation
// work (temporaries, a few retained objects). Reports the distribution of the per-frame work
// time and how many frames the collector pushed over 1, 2 and 5 ms.

final class Ent { Ent link; ubyte[] data; size_t id; }
__gshared Ent[] world;
void* frameSink;

// With -version=GcbLockStats (and a symgc built with -version=Symgc_phase_trace): per slow frame, how many
// times this thread took a lock the slow way and for how long.
version (GcbLockStats) extern(C) void symgc_lockstats(ulong* count, ulong* time);

void runFrames(size_t liveMiB, size_t frames, size_t allocsPerFrame)
{
    enum entrySize = 512;
    immutable count = liveMiB * 1024 * 1024 / entrySize;
    world = new Ent[](count);
    foreach (i, ref e; world)
    {
        e = new Ent;
        e.data = new ubyte[](entrySize - 64);
        e.id = i;
        if (i) e.link = world[i - 1];
    }
    auto ft = new long[](frames);
    ulong seed = 99;
    immutable t0 = now();
    foreach (f; 0 .. frames)
    {
        version (GcbLockStats) { ulong lc0, lt0; symgc_lockstats(&lc0, &lt0); }
        immutable a = MonoTime.currTime;
        foreach (k; 0 .. allocsPerFrame)
        {
            auto tmp = new ubyte[](32 + (k & 7) * 32);
            tmp[0] = cast(ubyte) k;
            frameSink = tmp.ptr;
            if ((k & 63) == 0)
            {
                auto e = new Ent;
                e.data = new ubyte[](entrySize - 64);
                world[nextRng(seed) % count] = e;
            }
        }
        ft[f] = (MonoTime.currTime - a).total!"usecs";
        version (GcbLockStats)
        {
            ulong lc1, lt1;
            symgc_lockstats(&lc1, &lt1);
            if (ft[f] > 1100)
                fprintf(stderr, "frame %zu %lld us: slow lock entries %llu, waited %.0f us\n", f, ft[f], lc1 - lc0, (lt1 - lt0) / 10.0);
        }
        // pace to 60 fps so the collector has idle time, as in a real game
        immutable target = cast(long) 16_666;
        long spent = ft[f];
        while (spent < target && spent >= 0)
        {
            Thread.sleep(dur!"usecs"(target - spent < 500 ? target - spent : 500));
            spent = (MonoTime.currTime - a).total!"usecs";
        }
    }
    immutable secs = now() - t0;
    import core.stdc.stdlib : getenv;
    if (getenv("FRAMES_DUMP"))   // list the frames over 2 ms: index and duration, to correlate with GC activity
        foreach (i, v; ft)
            if (v > 2000) fprintf(stderr, "slowframe %zu %lld us\n", i, v);
    size_t o1, o2, o5, o16;
    long worst, over;
    foreach (v; ft)
    {
        if (v > 1000) { ++o1; over += v; }
        if (v > 2000) ++o2;
        if (v > 5000) ++o5;
        if (v > 16666) ++o16;
        if (v > worst) worst = v;
    }
    auto sorted = ft.dup;
    qsort(sorted.ptr, frames, long.sizeof, &cmpLong);
    char[224] extra;
    snprintf(extra.ptr, 224, "frame_p50_us=%lld frame_p99_us=%lld frame_p999_us=%lld frame_max_us=%lld over1ms=%zu over2ms=%zu over5ms=%zu over16ms=%zu frames=%zu",
        sorted[frames / 2], sorted[frames * 99 / 100], sorted[frames * 999 / 1000], worst, o1, o2, o5, o16, frames);
    result("frames", secs, frames, extra.ptr);
}
