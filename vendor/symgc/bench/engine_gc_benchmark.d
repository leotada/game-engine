/**
 * Paced engine GC benchmark (vendored from leotada/game-engine 88f28dfe).
 *
 * Upstream: source/demo/gc_benchmark.d on branch ccr-cc050179-pkqfvj.
 * Engine helpers live in bench/engine_core/ (same commit). Collector selection
 * is by which binary is linked — do not mix collectors in one binary.
 *
 * Frame times are work only. After each sample the harness sleeps to the
 * 60 Hz deadline (like vsync) so a concurrent collector has idle time.
 *
 *   --light / --openworld / --worst / --worst-safe
 *   default | scheduler | disabled  [frames]
 *
 * Prints a RESULT line for scripts, over16ms, and GC.frameStats deltas when
 * the runtime provides them (zeros on a stock GC without telemetry).
 */
module engine_gc_benchmark;

import core.memory : GC;
import core.thread : Thread;
import core.time   : Duration, MonoTime, msecs, usecs, nsecs, hnsecs;
import std.algorithm : sort, sum, max;
import std.array    : appender;
import std.format   : format;
import std.stdio    : writeln, writefln;
import std.conv     : to;

import engine_core.pod     : isPod;
import engine_core.handle  : Handle;
import engine_core.strings : StringId, StringTable;
import engine_core.arena   : FrameArena;
import engine_core.attrs   : noGcStorage;

@safe:

// Collector selection is by how the binary is linked (see engine_gc_build.sh),
// not by mixin UseSteadyGC — so the druntime binary never contains symgc.

// ---------------------------------------------------------------------------
// Approach C reference: frame-budgeted GC scheduler.
// ---------------------------------------------------------------------------

struct FrameGcScheduler
{
    Duration budgetPerFrame    = 2.msecs;
    Duration minInterval       = 250.msecs;          // collect at most 4x/sec
    size_t   minGrowthBytes    = 1 * 1024 * 1024;    // need 1 MB of garbage
    size_t   forceCollectBytes = 64 * 1024 * 1024;   // hard ceiling

    private MonoTime lastCollect;
    private size_t   lastUsed;

    void start() @trusted nothrow
    {
        GC.disable();
        lastCollect = MonoTime.currTime;
        lastUsed    = GC.stats.usedSize;
    }

    void stop() @trusted nothrow
    {
        GC.enable();
    }

    /// Call once per frame. `frameSlack` is the time remaining in this frame's
    /// budget (e.g. 16.6ms - measured frame work). Pass Duration.zero to skip.
    void tick(Duration frameSlack) @trusted nothrow
    {
        const stats = GC.stats;
        const grew  = stats.usedSize > lastUsed ? stats.usedSize - lastUsed : 0;
        const since = MonoTime.currTime - lastCollect;

        const haveSlack    = frameSlack >= budgetPerFrame;
        const enoughGrowth = grew >= minGrowthBytes;
        const intervalOk   = since >= minInterval;

        if ((haveSlack && enoughGrowth && intervalOk)
            || stats.usedSize >= forceCollectBytes)
        {
            GC.collect();
            lastCollect = MonoTime.currTime;
            lastUsed    = GC.stats.usedSize;
        }
    }

    void onSceneTransition() @trusted nothrow
    {
        GC.collect();
        GC.minimize();
        lastCollect = MonoTime.currTime;
        lastUsed    = GC.stats.usedSize;
    }
}

// ---------------------------------------------------------------------------
// Synthetic gameplay workloads.
// All allocations escape the function so the GC actually has to track them.
// ---------------------------------------------------------------------------

enum Scenario { light, openworld, worst, worst_safe }

__gshared string[]          retainedStrings;   // last N frames of strings
__gshared int[][]           retainedArrays;
__gshared string[]          dialogQueue;       // open-world: dialog/loot lines
__gshared int[][]           terrainChunks;     // open-world: streamed mesh
enum size_t LIVE_WINDOW  = 120;                // ~2s of retained state at 60Hz
enum size_t TERRAIN_RING = 64;                 // 64 active streamed chunks

// --- Scenario 1: light --------------------------------------------------

void simulateFrameLight(size_t frameIdx) @trusted
{
    // 1. UI / debug strings — 16 per frame.
    foreach (k; 0 .. 16)
    {
        auto label = format("frame %d ent=%d hp=%d ammo=%d state=%s",
                            frameIdx, k,
                            100 - cast(int)((frameIdx + k) % 100),
                            cast(int)((frameIdx * 7 + k) % 64),
                            (frameIdx + k) % 2 ? "alive" : "dying");
        if (k == 0 && retainedStrings.length)
            retainedStrings[frameIdx % LIVE_WINDOW] = label;
    }

    // 2. Per-frame scratch arrays — 8 of them, ~1 KB each.
    int[][] scratchSet = new int[][](8);
    foreach (j; 0 .. scratchSet.length)
    {
        scratchSet[j] = new int[](256);
        foreach (i; 0 .. scratchSet[j].length)
            scratchSet[j][i] = cast(int)(frameIdx + i + j);
    }

    // 3. Occasional larger allocation — every 30 frames, ~16 KB.
    int[] big;
    if (frameIdx % 30 == 0)
    {
        big = new int[](4096);
        foreach (i; 0 .. big.length)
            big[i] = cast(int)(frameIdx ^ i);
    }

    if (retainedStrings.length < LIVE_WINDOW)
    {
        retainedStrings.length = LIVE_WINDOW;
        retainedArrays.length  = LIVE_WINDOW;
    }
    retainedArrays[frameIdx % LIVE_WINDOW] = big.length ? big : scratchSet[0];
}

// --- Scenario 2: openworld (pointer-free arrays) ------------------------

/**
 * Open-world action game scenario.
 * Live working set ~30-60 MB, allocation rate ~1-2 MB/frame.
 * Heap data is mostly int[] / float[] (no internal pointers).
 */
void simulateFrameOpenWorld(size_t frameIdx) @trusted
{
    if (retainedStrings.length < LIVE_WINDOW)
    {
        retainedStrings.length = LIVE_WINDOW;
        retainedArrays.length  = LIVE_WINDOW;
    }
    if (terrainChunks.length < TERRAIN_RING)
        terrainChunks.length = TERRAIN_RING;

    enum NPC_COUNT = 512;
    int[][] aiDecisions = new int[][](NPC_COUNT);
    foreach (n; 0 .. NPC_COUNT)
    {
        const len = 4 + cast(size_t)((frameIdx ^ n) % 13);
        aiDecisions[n] = new int[](len);
        foreach (i; 0 .. len)
            aiDecisions[n][i] = cast(int)(frameIdx * 31 + n * 7 + i);
    }

    foreach (k; 0 .. 64)
    {
        auto label = format("npc=%d pos=(%d,%d,%d) hp=%d/%d behavior=%s target=%d",
                            cast(int)((frameIdx + k) % NPC_COUNT),
                            cast(int)((frameIdx + k * 17) % 4096),
                            cast(int)((frameIdx * 3 + k * 23) % 4096),
                            cast(int)((frameIdx + k * 5) % 256),
                            100 - cast(int)((frameIdx + k) % 100), 100,
                            (k % 4 == 0 ? "patrol"
                             : k % 4 == 1 ? "combat"
                             : k % 4 == 2 ? "flee" : "idle"),
                            cast(int)((frameIdx * 11 + k) % NPC_COUNT));
        if (k < 8)
            retainedStrings[(frameIdx + k) % LIVE_WINDOW] = label;
    }

    dialogQueue = new string[](256);
    foreach (k; 0 .. dialogQueue.length)
    {
        dialogQueue[k] = format("[%d] %s picked up %s x%d (rarity=%d)",
                                frameIdx,
                                k % 2 ? "player" : "npc",
                                k % 3 == 0 ? "gold"
                                    : k % 3 == 1 ? "potion" : "scroll",
                                1 + cast(int)((frameIdx + k) % 32),
                                cast(int)((frameIdx ^ k) % 5));
    }

    foreach (s; 0 .. 32)
    {
        const count = 100 + cast(size_t)((frameIdx + s * 13) % 400);
        auto particles = new float[](count * 4);
        foreach (i; 0 .. particles.length)
            particles[i] = cast(float)(frameIdx + s + i) * 0.001f;
    }

    if (frameIdx % 4 == 0)
    {
        auto chunk = new int[](64 * 1024); // 256 KB
        foreach (i; 0 .. chunk.length)
            chunk[i] = cast(int)(frameIdx ^ i);
        terrainChunks[(frameIdx / 4) % TERRAIN_RING] = chunk;
    }

    int[] eventLog;
    if (frameIdx % 120 == 0)
    {
        eventLog = new int[](256 * 1024);
        foreach (i; 0 .. eventLog.length)
            eventLog[i] = cast(int)(frameIdx + i);
    }

    retainedArrays[frameIdx % LIVE_WINDOW] =
        eventLog.length ? eventLog : aiDecisions[0];
}

// --- Scenario 3: worst (pointer-rich object graph) ----------------------

class NpcInventoryItem
{
    string           name;
    int              quantity;
    NpcInventoryItem next;          // intrusive linked list
}

class NpcState
{
    string           displayName;
    int[]            memory;
    NpcState         target;        // reference to another NPC
    NpcInventoryItem inventory;     // owned linked list
    string[]         dialogLines;
}

struct PointerVertex                // string + class ref => block scanned
{
    float    x, y, z, u, v;
    string   materialName;
    NpcState owner;
}

__gshared NpcState[]        npcRoster;
__gshared PointerVertex[][] worstTerrain;
enum size_t WORST_NPC_COUNT    = 4096;
enum size_t WORST_TERRAIN_RING = 256;   // 256 chunks * ~256KB ≈ 64 MB live

/**
 * Worst-case scenario for a conservative mark-sweep GC.
 *
 *   - 4096 NPC objects (class instances) with class-typed `target` refs,
 *     int[] memory, string[] dialog cache, and an intrusive linked list of
 *     up to 8 inventory items. Mark must traverse a real reference graph.
 *   - Terrain chunks of 4096 PointerVertex (each holding a string and a
 *     class reference). The GC must scan every byte of these blocks.
 *   - 1024 transient short strings per frame (hot allocator path).
 *
 * Live heap settles around 60-120 MB. Allocation rate ~3-5 MB/frame.
 */
void simulateFrameWorst(size_t frameIdx) @trusted
{
    if (retainedStrings.length < LIVE_WINDOW)
        retainedStrings.length = LIVE_WINDOW;
    if (npcRoster.length < WORST_NPC_COUNT)
    {
        npcRoster.length = WORST_NPC_COUNT;
        foreach (i; 0 .. WORST_NPC_COUNT)
            npcRoster[i] = new NpcState;
    }
    if (worstTerrain.length < WORST_TERRAIN_RING)
        worstTerrain.length = WORST_TERRAIN_RING;

    // 1. AI tick — every NPC mutates state and rewires its target.
    foreach (n; 0 .. WORST_NPC_COUNT)
    {
        auto npc = npcRoster[n];
        npc.displayName = format("npc_%d_t%d", n, frameIdx);
        npc.memory = new int[](16 + cast(size_t)((frameIdx ^ n) % 32));
        foreach (i; 0 .. npc.memory.length)
            npc.memory[i] = cast(int)(frameIdx + n + i);
        npc.target = npcRoster[(n * 2654435761U + cast(uint)frameIdx)
                               % WORST_NPC_COUNT];

        // Grow inventory linked list (capped to ~8 nodes).
        auto item = new NpcInventoryItem;
        item.name     = format("item_%d", (frameIdx + n) % 1024);
        item.quantity = cast(int)((frameIdx ^ n) % 99) + 1;
        item.next     = npc.inventory;
        npc.inventory = item;

        auto cur = npc.inventory;
        size_t depth = 0;
        while (cur !is null && depth < 8) { cur = cur.next; depth++; }
        if (cur !is null) cur.next = null;

        if (frameIdx % 16 == n % 16)
        {
            npc.dialogLines = new string[](4);
            foreach (k; 0 .. 4)
                npc.dialogLines[k] = format("npc=%d line=%d frame=%d",
                                            n, k, frameIdx);
        }
    }

    // 2. Terrain streaming — every 2 frames, ~256 KB pointer-bearing chunk.
    if (frameIdx % 2 == 0)
    {
        auto chunk = new PointerVertex[](4096);
        foreach (i; 0 .. chunk.length)
        {
            chunk[i].x = cast(float)i;
            chunk[i].y = cast(float)frameIdx;
            chunk[i].z = cast(float)(i ^ frameIdx);
            chunk[i].materialName =
                (i % 4 == 0) ? "stone"
              : (i % 4 == 1) ? "grass"
              : (i % 4 == 2) ? "sand"
              :                "water";
            chunk[i].owner = npcRoster[i % WORST_NPC_COUNT];
        }
        worstTerrain[(frameIdx / 2) % WORST_TERRAIN_RING] = chunk;
    }

    // 3. Per-frame transient garbage — 1024 short strings die immediately.
    foreach (k; 0 .. 1024)
    {
        auto s = format("event %d.%d type=%d",
                        frameIdx, k, cast(int)((frameIdx ^ k) % 7));
        if (k == 0)
            retainedStrings[frameIdx % LIVE_WINDOW] = s;
    }
}

// --- Scenario 4: worst_safe (same workload, POD + Handle + StringId) ----

/// Phantom types for Handle domains.
struct NpcDomain {}
struct InvDomain {}

/// POD NPC state — no class, no string, no GC indirections.
@noGcStorage
struct SafeNpcDef
{
    StringId          baseName;       // interned once ("npc_42"), stable
    Handle!NpcDomain  target;
    uint              memoryOffset;
    uint              memoryLen;
    Handle!InvDomain  inventoryHead;
    StringId[4]       dialogLines;
}
static assert(isPod!SafeNpcDef);

/// POD inventory node — linked via handles, not class refs.
@noGcStorage
struct SafeInvNode
{
    StringId         name;
    int              qty;
    Handle!InvDomain next;
}
static assert(isPod!SafeInvNode);

/// POD terrain vertex — materialId instead of string, ownerId instead of class.
@noGcStorage
struct SafeTerrainVertex
{
    float  x, y, z, u, v;
    ushort materialId;
    uint   ownerNpcId;
}
static assert(isPod!SafeTerrainVertex);

__gshared SafeNpcDef[]            safeNpcPool;
__gshared SafeInvNode[]           safeInvPool;
__gshared size_t                  safeInvCount;
__gshared int[]                   safeMemoryPool;     // shared AI memory
__gshared SafeTerrainVertex[][]   safeTerrain;
__gshared StringTable             safeStrings;
__gshared FrameArena              safeArena;

/**
 * GC-safe version of the worst scenario.
 *
 * Same logical workload (4096 NPCs, AI tick, inventory, terrain streaming,
 * transient strings), but using:
 *
 *   - `SafeNpcDef` (POD struct with Handle/StringId) instead of `NpcState` class
 *   - `SafeInvNode` pool + handles instead of intrusive linked list of classes
 *   - `SafeTerrainVertex` (ushort materialId, uint ownerId) instead of string + class
 *   - `StringTable.intern()` for names that need to persist
 *   - `FrameArena.fmt()` for transient per-frame strings (zero GC pressure)
 *
 * Live heap size is comparable (~60+ MB). Allocation rate is comparable.
 * But the GC sees only POD arrays → mark cost collapses to ~0.
 */
void simulateFrameWorstSafe(size_t frameIdx) @trusted
{
    if (retainedStrings.length < LIVE_WINDOW)
        retainedStrings.length = LIVE_WINDOW;

    // Lazy init
    if (safeNpcPool.length < WORST_NPC_COUNT)
    {
        safeNpcPool    = new SafeNpcDef[](WORST_NPC_COUNT);
        safeInvPool    = new SafeInvNode[](WORST_NPC_COUNT * 8);
        safeMemoryPool = new int[](WORST_NPC_COUNT * 48);
        safeStrings    = StringTable.init;
        safeArena      = FrameArena(4 * 1024 * 1024);  // 4 MB scratch

        // Intern stable base names once — a real game loads these from assets.
        foreach (n; 0 .. WORST_NPC_COUNT)
        {
            auto buf = format("npc_%d", n);
            safeNpcPool[n].baseName = safeStrings.intern(buf);
        }
    }
    if (safeTerrain.length < WORST_TERRAIN_RING)
        safeTerrain.length = WORST_TERRAIN_RING;

    safeArena.reset();
    safeInvCount = 0;

    // 1. AI tick — same 4096 NPCs, mutate state, rewire target, grow inventory.
    foreach (n; 0 .. WORST_NPC_COUNT)
    {
        // Per-frame display name goes to the arena (dies at frame end).
        // The stored baseName is stable → no new interning.
        auto _displayBuf = safeArena.fmt("npc_%d_t%d", n, frameIdx);

        // AI memory — index into shared int pool (no per-NPC allocation).
        immutable memLen = 16 + cast(uint)((frameIdx ^ n) % 32);
        immutable memOff = cast(uint)((n * 48) % safeMemoryPool.length);
        safeNpcPool[n].memoryOffset = memOff;
        safeNpcPool[n].memoryLen    = memLen;
        foreach (i; memOff .. memOff + memLen)
        {
            if (i < safeMemoryPool.length)
                safeMemoryPool[i] = cast(int)(frameIdx + n + (i - memOff));
        }

        // Target rewire — handle, not class ref.
        immutable targetIdx = (n * 2654435761U + cast(uint)frameIdx)
                              % WORST_NPC_COUNT;
        safeNpcPool[n].target = Handle!NpcDomain(cast(uint)(targetIdx + 1), 0);

        // Inventory — pool allocation via handles (capped at 8 per NPC).
        if (safeInvCount < safeInvPool.length)
        {
            auto slot = safeInvCount++;
            // Item names have bounded cardinality (1024 unique) — intern is fine.
            auto itemNameBuf = safeArena.fmt("item_%d", (frameIdx + n) % 1024);
            safeInvPool[slot].name = itemNameBuf !is null
                ? safeStrings.intern(itemNameBuf)
                : StringId.init;
            safeInvPool[slot].qty  = cast(int)((frameIdx ^ n) % 99) + 1;
            safeInvPool[slot].next = safeNpcPool[n].inventoryHead;
            safeNpcPool[n].inventoryHead = Handle!InvDomain(cast(uint)(slot + 1), 0);

            // Trim to 8 nodes (walk handles).
            Handle!InvDomain cur = safeNpcPool[n].inventoryHead;
            size_t depth = 0;
            while (!cur.isNull && depth < 8)
            {
                cur = safeInvPool[cur.index - 1].next;
                depth++;
            }
            if (!cur.isNull)
                safeInvPool[cur.index - 1].next = Handle!InvDomain.init;
        }

        // Dialog lines — arena-formatted, interned only on change (bounded set).
        if (frameIdx % 16 == n % 16)
        {
            foreach (k; 0 .. 4)
            {
                // Bounded cardinality: 4096 NPCs * 4 lines = ~16K unique.
                auto buf = safeArena.fmt("npc=%d line=%d", n, k);
                safeNpcPool[n].dialogLines[k] = buf !is null
                    ? safeStrings.intern(buf)
                    : StringId.init;
            }
        }
    }

    // 2. Terrain streaming — same cadence, POD vertex data.
    if (frameIdx % 2 == 0)
    {
        auto chunk = new SafeTerrainVertex[](4096);
        foreach (i; 0 .. chunk.length)
        {
            chunk[i].x = cast(float)i;
            chunk[i].y = cast(float)frameIdx;
            chunk[i].z = cast(float)(i ^ frameIdx);
            chunk[i].materialId = cast(ushort)(i % 4);
            chunk[i].ownerNpcId = cast(uint)(i % WORST_NPC_COUNT);
        }
        safeTerrain[(frameIdx / 2) % WORST_TERRAIN_RING] = chunk;
    }

    // 3. Per-frame transient strings — FrameArena, zero GC pressure.
    foreach (k; 0 .. 1024)
    {
        auto s = safeArena.fmt("event %d.%d type=%d",
                               frameIdx, k, cast(int)((frameIdx ^ k) % 7));
        if (k == 0 && s !is null)
            retainedStrings[frameIdx % LIVE_WINDOW] = s.idup;
    }
}

void simulateFrame(Scenario sc, size_t frameIdx) @trusted
{
    final switch (sc)
    {
        case Scenario.light:      simulateFrameLight(frameIdx);      break;
        case Scenario.openworld:  simulateFrameOpenWorld(frameIdx);  break;
        case Scenario.worst:      simulateFrameWorst(frameIdx);      break;
        case Scenario.worst_safe: simulateFrameWorstSafe(frameIdx);  break;
    }
}

// ---------------------------------------------------------------------------
// Statistics helpers.
// ---------------------------------------------------------------------------

struct PauseStats
{
    Duration mean, p50, p95, p99, max_;
    size_t   count;
}

PauseStats summarize(Duration[] samples) @trusted
{
    PauseStats s;
    s.count = samples.length;
    if (samples.length == 0) return s;

    auto sorted = samples.dup;
    sorted.sort!((a, b) => a < b);

    long totalHnsecs = 0;
    foreach (d; sorted) totalHnsecs += d.total!"hnsecs";
    s.mean = hnsecs(totalHnsecs / cast(long)sorted.length);

    s.p50  = sorted[sorted.length * 50 / 100];
    s.p95  = sorted[sorted.length * 95 / 100];
    s.p99  = sorted[sorted.length * 99 / 100];
    s.max_ = sorted[$ - 1];
    return s;
}

double toMs(Duration d) @safe pure nothrow @nogc
{
    return d.total!"hnsecs" / 10_000.0;
}

void printStats(string label, PauseStats s) @safe
{
    writefln("  %-12s n=%5d  mean=%7.3fms  p50=%7.3fms  p95=%7.3fms  "
             ~ "p99=%7.3fms  max=%7.3fms",
             label, s.count, toMs(s.mean), toMs(s.p50),
             toMs(s.p95), toMs(s.p99), toMs(s.max_));
}

// ---------------------------------------------------------------------------
// Benchmark drivers — one per mode.
// ---------------------------------------------------------------------------

enum Mode { default_, scheduler, disabled }

enum Duration FRAME_BUDGET = 16.msecs + 666.usecs;  // 60Hz target

struct FrameTelemetry
{
    Duration sumAlloc;
    Duration sumCollect;
    Duration sumPause;
    Duration maxAlloc;
    Duration maxCollect;
    Duration maxPause;
    Duration quietWork;      // work on frames with isCycleActive == false
    Duration quietTimers;    // alloc+collect+pause on those frames
    Duration cycleWork;
    Duration cycleTimers;
    size_t   quietFrames;
    size_t   cycleFrames;
    size_t   over16Quiet;
    size_t   over16Cycle;
    bool     telemetryLive;  // true if any timer delta was non-zero
}

struct RunResult
{
    Duration[]     frameTimes;
    FrameTelemetry telem;
    size_t         usedBefore;
    size_t         usedAfter;
    GC.ProfileStats profileBefore;
    GC.ProfileStats profileAfter;
}

void resetRetainedState() @trusted
{
    retainedStrings = null;
    retainedArrays  = null;
    dialogQueue     = null;
    terrainChunks   = null;
    npcRoster       = null;
    worstTerrain    = null;
    safeNpcPool     = null;
    safeInvPool     = null;
    safeInvCount    = 0;
    safeMemoryPool  = null;
    safeTerrain     = null;
    safeStrings     = StringTable.init;
    safeArena       = FrameArena.init;
}

void sleepToDeadline(MonoTime deadline) @trusted
{
    while (MonoTime.currTime < deadline)
        Thread.sleep(deadline - MonoTime.currTime);
}

RunResult runBenchmark(Mode mode, Scenario sc, size_t frames) @trusted
{
    resetRetainedState();
    GC.collect();
    GC.minimize();

    // Snapshot after the harness collect so in-frame profile deltas exclude it.
    const profileBefore = GC.profileStats();
    const usedBefore    = GC.stats.usedSize;

    FrameGcScheduler sched;

    final switch (mode)
    {
        case Mode.default_:  break;
        case Mode.scheduler: sched.start(); break;
        case Mode.disabled:  GC.disable();  break;
    }

    auto frameTimes = new Duration[](frames);
    FrameTelemetry telem;

    foreach (i; 0 .. frames)
    {
        const fs0 = GC.frameStats();
        const t0 = MonoTime.currTime;
        simulateFrame(sc, i);
        const work = MonoTime.currTime - t0;
        const fs1 = GC.frameStats();

        if (mode == Mode.scheduler)
        {
            const slack = work < FRAME_BUDGET
                ? FRAME_BUDGET - work
                : Duration.zero;
            sched.tick(slack);
        }

        // Sample is work only; then wait out the rest of the 60 Hz slot.
        frameTimes[i] = work;

        const dAlloc   = fs1.threadAllocTime   - fs0.threadAllocTime;
        const dCollect = fs1.threadCollectTime - fs0.threadCollectTime;
        const dPause   = fs1.threadPauseTime   - fs0.threadPauseTime;
        const timers   = dAlloc + dCollect + dPause;
        if (dAlloc > Duration.zero || dCollect > Duration.zero || dPause > Duration.zero)
            telem.telemetryLive = true;

        telem.sumAlloc   += dAlloc;
        telem.sumCollect += dCollect;
        telem.sumPause   += dPause;
        if (dAlloc > telem.maxAlloc)     telem.maxAlloc = dAlloc;
        if (dCollect > telem.maxCollect) telem.maxCollect = dCollect;
        if (dPause > telem.maxPause)     telem.maxPause = dPause;

        const active = fs1.isCycleActive;
        if (active)
        {
            telem.cycleFrames++;
            telem.cycleWork += work;
            telem.cycleTimers += timers;
            if (work > FRAME_BUDGET) telem.over16Cycle++;
        }
        else
        {
            telem.quietFrames++;
            telem.quietWork += work;
            telem.quietTimers += timers;
            if (work > FRAME_BUDGET) telem.over16Quiet++;
        }

        sleepToDeadline(t0 + FRAME_BUDGET);
    }

    final switch (mode)
    {
        case Mode.default_:  break;
        case Mode.scheduler: sched.stop(); break;
        case Mode.disabled:  GC.enable();  break;
    }

    RunResult r;
    r.frameTimes    = frameTimes;
    r.telem         = telem;
    r.usedBefore    = usedBefore;
    r.usedAfter     = GC.stats.usedSize;
    r.profileBefore = profileBefore;
    r.profileAfter  = GC.profileStats();
    return r;
}

void reportMode(string name, Mode mode, Scenario sc, size_t frames) @trusted
{
    writeln();
    writefln("=== %s (%s, %d frames) ===", name, sc, frames);

    const t0 = MonoTime.currTime;
    auto run = runBenchmark(mode, sc, frames);
    const wall = MonoTime.currTime - t0;

    auto frameStats = summarize(run.frameTimes);
    printStats("frame", frameStats);

    size_t over16;
    foreach (d; run.frameTimes)
        if (d > FRAME_BUDGET) over16++;

    const dCollections = run.profileAfter.numCollections - run.profileBefore.numCollections;
    const dPause       = run.profileAfter.totalPauseTime - run.profileBefore.totalPauseTime;
    const dMark        = run.profileAfter.totalCollectionTime - run.profileBefore.totalCollectionTime;
    const maxColl      = run.profileAfter.maxCollectionTime;
    const maxPause     = run.profileAfter.maxPauseTime;

    writefln("  over16ms=%d  (quiet_frames=%d cycle_frames=%d; over16 quiet=%d cycle=%d)",
             over16, run.telem.quietFrames, run.telem.cycleFrames,
             run.telem.over16Quiet, run.telem.over16Cycle);
    writefln("  GC: collections=%d  total_pause=%.3fms  total_mark=%.3fms  "
             ~ "max_collection=%.3fms  max_pause=%.3fms  (startup collect excluded)",
             dCollections, toMs(dPause), toMs(dMark),
             toMs(maxColl), toMs(maxPause));
    writefln("  heap: used %d -> %d bytes (delta %+d)",
             run.usedBefore, run.usedAfter,
             cast(long)run.usedAfter - cast(long)run.usedBefore);
    writefln("  wall: %.3fms total, %.3fms/frame avg (includes pacing sleep)",
             toMs(wall), toMs(wall) / frames);

    auto telem = run.telem;
    if (!telem.telemetryLive)
    {
        writefln("  frameStats: unsupported (timers stayed zero)");
    }
    else
    {
        writefln("  frameStats: alloc=%.3fms (max %.3f) collect=%.3fms (max %.3f) "
                 ~ "pause=%.3fms (max %.3f)",
                 toMs(telem.sumAlloc), toMs(telem.maxAlloc),
                 toMs(telem.sumCollect), toMs(telem.maxCollect),
                 toMs(telem.sumPause), toMs(telem.maxPause));
        const quietN = telem.quietFrames ? telem.quietFrames : 1;
        const cycleN = telem.cycleFrames ? telem.cycleFrames : 1;
        writefln("  frames: quiet=%d mean_work=%.3fms residual=%.3fms; "
                 ~ "cycle=%d mean_work=%.3fms residual=%.3fms",
                 telem.quietFrames,
                 toMs(telem.quietWork) / quietN,
                 toMs(telem.quietWork - telem.quietTimers) / quietN,
                 telem.cycleFrames,
                 toMs(telem.cycleWork) / cycleN,
                 toMs(telem.cycleWork - telem.cycleTimers) / cycleN);
    }

    // Machine-readable line for engine_gc_compare.sh
    string gcLabel = "druntime";
    version (Symgc_druntime_hooks)
        gcLabel = "steadygc";
    writefln("RESULT scenario=%s gc=%s mean_ms=%.3f p50_ms=%.3f p99_ms=%.3f "
             ~ "worst_ms=%.3f over16ms=%d",
             sc, gcLabel, toMs(frameStats.mean), toMs(frameStats.p50),
             toMs(frameStats.p99), toMs(frameStats.max_), over16);
}

// ---------------------------------------------------------------------------

void main(string[] args) @trusted
{
    Mode     mode     = Mode.default_;
    Scenario scenario = Scenario.worst_safe;
    size_t   frames   = 600;

    string[] positional;
    foreach (a; args[1 .. $])
    {
        switch (a)
        {
            case "--openworld":  scenario = Scenario.openworld;  break;
            case "--worst":      scenario = Scenario.worst;      break;
            case "--worst-safe": scenario = Scenario.worst_safe; break;
            case "--light":      scenario = Scenario.light;      break;
            default:             positional ~= a;                break;
        }
    }

    if (positional.length > 0)
    {
        switch (positional[0])
        {
            case "default":   mode = Mode.default_;  break;
            case "scheduler": mode = Mode.scheduler; break;
            case "disabled":  mode = Mode.disabled;  break;
            case "all":       mode = cast(Mode)0xFF; break;  // sentinel
            default:
                writeln("usage: gc-benchmark [default|scheduler|disabled|all] "
                        ~ "[frames] [--light|--openworld|--worst|--worst-safe]");
                return;
        }
    }
    if (positional.length > 1)
        frames = positional[1].to!size_t;

    writeln("incremental-gc research benchmark");
    writefln("scenario = %s  frames per mode = %d  (target 60Hz, 16.666ms budget)",
             scenario, frames);
    writeln("(set DRT_GCOPT=\"fork:1 parallel:N precise:1 profile:1\" to "
            ~ "layer Approach B / enable profileStats)");

    if (cast(int)mode == 0xFF)
    {
        runBenchmark(Mode.default_, scenario, 60);  // warmup
        reportMode("default",   Mode.default_,  scenario, frames);
        reportMode("scheduler", Mode.scheduler, scenario, frames);
        reportMode("disabled",  Mode.disabled,  scenario, frames);
        return;
    }

    runBenchmark(mode, scenario, 60);  // warmup
    final switch (mode)
    {
        case Mode.default_:  reportMode("default",   mode, scenario, frames); break;
        case Mode.scheduler: reportMode("scheduler", mode, scenario, frames); break;
        case Mode.disabled:  reportMode("disabled",  mode, scenario, frames); break;
    }
}
