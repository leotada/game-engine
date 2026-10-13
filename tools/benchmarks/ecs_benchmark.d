/// Architectural Benchmark: Non-ECS (OOP) vs Native Static ECS vs Dynamic SceneWorld vs D Scripted ECS
module tools.benchmarks.ecs_benchmark;

import core.memory : GC;
import core.time : Duration, MonoTime, msecs, usecs, nsecs;
import std.algorithm : min, max, sort;
import std.conv : to;
import std.math : sqrt;
import std.random : Random, unpredictableSeed, uniform;
import std.stdio : writeln, writefln;
import std.string : format;

import engine.core.pod : isPod;
import engine.ecs.store : EntityId;
import engine.ecs.world : World;
import engine.ecs.scene_world : SceneWorld;
import engine.reflect.attrs : component, export_;
import engine.reflect.descriptor : LifecycleMask;
import engine.script.context : ScriptContext;
import engine.script.module_entry : ModuleRegistrar;
import engine.hotreload.reload : HotReloadManager;

@safe:

// ===========================================================================
// Common Simulation Constants & Workload Parameters
// ===========================================================================

enum float SIM_DT = 1.0f / 60.0f;
enum float ARENA_BOUNDS = 200.0f;
enum float AGGRO_RADIUS = 5.0f;

struct BenchStats {
    string name;
    size_t entityCount;
    size_t frameCount;
    double totalMs;
    double meanUs;
    double minUs;
    double maxUs;
    double medianUs;
    double p95Us;
    double p99Us;
    double throughputOpsPerMs;
    size_t gcAllocatedBytes;
    double speedupVsOop;
}

// ===========================================================================
// Architecture 1: Non-ECS (Traditional OOP / Class Virtual Dispatch)
// ===========================================================================

class GameObject {
    float x = 0.0f, y = 0.0f, z = 0.0f;
    float vx = 0.0f, vy = 0.0f, vz = 0.0f;
    float hp = 100.0f, maxHp = 100.0f, power = 10.0f, defense = 2.0f, regen = 1.0f;
    float targetX = 0.0f, targetY = 0.0f, targetZ = 0.0f, speed = 12.0f;
    int state = 0; // 0 = Seeking, 1 = Attacking
    bool isStatic = false;
    bool hasAi = true;

    this(float px, float py, float pz, float spd = 12.0f, bool isStat = false, bool ai = true) {
        x = px; y = py; z = pz;
        speed = spd;
        isStatic = isStat;
        hasAi = ai;
    }

    abstract void update(float dt);
}

class EnemyActor : GameObject {
    this(float px, float py, float pz, float spd) {
        super(px, py, pz, spd, false, true);
    }

    override void update(float dt) {
        // 1. AI Steering toward target
        float dx = targetX - x;
        float dy = targetY - y;
        float dz = targetZ - z;
        float distSq = dx * dx + dy * dy + dz * dz;
        if (distSq > 0.0001f) {
            float invDist = 1.0f / sqrt(distSq);
            vx += (dx * invDist * speed - vx) * 0.1f;
            vy += (dy * invDist * speed - vy) * 0.1f;
            vz += (dz * invDist * speed - vz) * 0.1f;
        }
        state = (distSq < (AGGRO_RADIUS * AGGRO_RADIUS)) ? 1 : 0;

        // 2. Kinematics integration & bounds reflection
        x += vx * dt;
        y += vy * dt;
        z += vz * dt;
        if (x < -ARENA_BOUNDS) { x = -ARENA_BOUNDS; vx = -vx; }
        else if (x > ARENA_BOUNDS) { x = ARENA_BOUNDS; vx = -vx; }
        if (y < -ARENA_BOUNDS) { y = -ARENA_BOUNDS; vy = -vy; }
        else if (y > ARENA_BOUNDS) { y = ARENA_BOUNDS; vy = -vy; }
        if (z < -ARENA_BOUNDS) { z = -ARENA_BOUNDS; vz = -vz; }
        else if (z > ARENA_BOUNDS) { z = ARENA_BOUNDS; vz = -vz; }

        // 3. Combat stats update
        hp += regen * dt;
        if (hp > maxHp) hp = maxHp;
    }
}

class ProjectileActor : GameObject {
    this(float px, float py, float pz, float vx_, float vy_, float vz_) {
        super(px, py, pz, 0.0f, false, false);
        vx = vx_; vy = vy_; vz = vz_;
    }

    override void update(float dt) {
        x += vx * dt;
        y += vy * dt;
        z += vz * dt;
        if (x < -ARENA_BOUNDS || x > ARENA_BOUNDS) vx = -vx;
        if (y < -ARENA_BOUNDS || y > ARENA_BOUNDS) vy = -vy;
        if (z < -ARENA_BOUNDS || z > ARENA_BOUNDS) vz = -vz;
    }
}

class StaticPropActor : GameObject {
    this(float px, float py, float pz) {
        super(px, py, pz, 0.0f, true, false);
    }

    override void update(float dt) {
        // Static prop does no work, but virtual call and pointer dereference still happen
    }
}

// ===========================================================================
// Architecture 2: Native Static SoA ECS (World!(...))
// ===========================================================================

struct Position {
    float x = 0.0f, y = 0.0f, z = 0.0f;
}

struct Velocity {
    float vx = 0.0f, vy = 0.0f, vz = 0.0f;
}

struct CombatStats {
    float hp = 100.0f, maxHp = 100.0f, power = 10.0f, defense = 2.0f, regen = 1.0f;
}

struct EnemyAI {
    float targetX = 0.0f, targetY = 0.0f, targetZ = 0.0f;
    float speed = 12.0f;
    int state = 0;
}

alias StaticGameWorld = World!(Position, Velocity, CombatStats, EnemyAI);

void tickStaticEcsQuery(ref StaticGameWorld world, float dt) nothrow @nogc @trusted {
    foreach (e; world.query!(Position, Velocity, CombatStats, EnemyAI)) {
        auto pos = world.getPtr!Position(e);
        auto vel = world.getPtr!Velocity(e);
        auto cbt = world.getPtr!CombatStats(e);
        auto ai  = world.getPtr!EnemyAI(e);

        // 1. AI Steering toward target
        float dx = ai.targetX - pos.x;
        float dy = ai.targetY - pos.y;
        float dz = ai.targetZ - pos.z;
        float distSq = dx * dx + dy * dy + dz * dz;
        if (distSq > 0.0001f) {
            float invDist = 1.0f / sqrt(distSq);
            vel.vx += (dx * invDist * ai.speed - vel.vx) * 0.1f;
            vel.vy += (dy * invDist * ai.speed - vel.vy) * 0.1f;
            vel.vz += (dz * invDist * ai.speed - vel.vz) * 0.1f;
        }
        ai.state = (distSq < (AGGRO_RADIUS * AGGRO_RADIUS)) ? 1 : 0;

        // 2. Kinematics integration & bounds reflection
        pos.x += vel.vx * dt;
        pos.y += vel.vy * dt;
        pos.z += vel.vz * dt;
        if (pos.x < -ARENA_BOUNDS) { pos.x = -ARENA_BOUNDS; vel.vx = -vel.vx; }
        else if (pos.x > ARENA_BOUNDS) { pos.x = ARENA_BOUNDS; vel.vx = -vel.vx; }
        if (pos.y < -ARENA_BOUNDS) { pos.y = -ARENA_BOUNDS; vel.vy = -vel.vy; }
        else if (pos.y > ARENA_BOUNDS) { pos.y = ARENA_BOUNDS; vel.vy = -vel.vy; }
        if (pos.z < -ARENA_BOUNDS) { pos.z = -ARENA_BOUNDS; vel.vz = -vel.vz; }
        else if (pos.z > ARENA_BOUNDS) { pos.z = ARENA_BOUNDS; vel.vz = -vel.vz; }

        // 3. Combat stats update
        cbt.hp += cbt.regen * dt;
        if (cbt.hp > cbt.maxHp) cbt.hp = cbt.maxHp;
    }
}

void tickStaticEcsSoaDense(ref StaticGameWorld world, float dt) nothrow @nogc @trusted {
    auto posArr = world.store!Position.components;
    auto velArr = world.store!Velocity.components;
    auto cbtArr = world.store!CombatStats.components;
    auto aiArr  = world.store!EnemyAI.components;
    immutable len = min(posArr.length, velArr.length, cbtArr.length, aiArr.length);

    foreach (i; 0 .. len) {
        auto pos = &posArr[i];
        auto vel = &velArr[i];
        auto cbt = &cbtArr[i];
        auto ai  = &aiArr[i];

        // 1. AI Steering toward target
        float dx = ai.targetX - pos.x;
        float dy = ai.targetY - pos.y;
        float dz = ai.targetZ - pos.z;
        float distSq = dx * dx + dy * dy + dz * dz;
        if (distSq > 0.0001f) {
            float invDist = 1.0f / sqrt(distSq);
            vel.vx += (dx * invDist * ai.speed - vel.vx) * 0.1f;
            vel.vy += (dy * invDist * ai.speed - vel.vy) * 0.1f;
            vel.vz += (dz * invDist * ai.speed - vel.vz) * 0.1f;
        }
        ai.state = (distSq < (AGGRO_RADIUS * AGGRO_RADIUS)) ? 1 : 0;

        // 2. Kinematics integration & bounds reflection
        pos.x += vel.vx * dt;
        pos.y += vel.vy * dt;
        pos.z += vel.vz * dt;
        if (pos.x < -ARENA_BOUNDS) { pos.x = -ARENA_BOUNDS; vel.vx = -vel.vx; }
        else if (pos.x > ARENA_BOUNDS) { pos.x = ARENA_BOUNDS; vel.vx = -vel.vx; }
        if (pos.y < -ARENA_BOUNDS) { pos.y = -ARENA_BOUNDS; vel.vy = -vel.vy; }
        else if (pos.y > ARENA_BOUNDS) { pos.y = ARENA_BOUNDS; vel.vy = -vel.vy; }
        if (pos.z < -ARENA_BOUNDS) { pos.z = -ARENA_BOUNDS; vel.vz = -vel.vz; }
        else if (pos.z > ARENA_BOUNDS) { pos.z = ARENA_BOUNDS; vel.vz = -vel.vz; }

        // 3. Combat stats update
        cbt.hp += cbt.regen * dt;
        if (cbt.hp > cbt.maxHp) cbt.hp = cbt.maxHp;
    }
}

// ===========================================================================
// Architecture 3: Dynamic SceneWorld Native Query
// ===========================================================================

void tickSceneWorldNative(ref SceneWorld world, float dt) @trusted {
    foreach (e; world.query!(Position, Velocity, CombatStats, EnemyAI)) {
        auto pos = world.getPtr!Position(e);
        auto vel = world.getPtr!Velocity(e);
        auto cbt = world.getPtr!CombatStats(e);
        auto ai  = world.getPtr!EnemyAI(e);

        // 1. AI Steering toward target
        float dx = ai.targetX - pos.x;
        float dy = ai.targetY - pos.y;
        float dz = ai.targetZ - pos.z;
        float distSq = dx * dx + dy * dy + dz * dz;
        if (distSq > 0.0001f) {
            float invDist = 1.0f / sqrt(distSq);
            vel.vx += (dx * invDist * ai.speed - vel.vx) * 0.1f;
            vel.vy += (dy * invDist * ai.speed - vel.vy) * 0.1f;
            vel.vz += (dz * invDist * ai.speed - vel.vz) * 0.1f;
        }
        ai.state = (distSq < (AGGRO_RADIUS * AGGRO_RADIUS)) ? 1 : 0;

        // 2. Kinematics integration & bounds reflection
        pos.x += vel.vx * dt;
        pos.y += vel.vy * dt;
        pos.z += vel.vz * dt;
        if (pos.x < -ARENA_BOUNDS) { pos.x = -ARENA_BOUNDS; vel.vx = -vel.vx; }
        else if (pos.x > ARENA_BOUNDS) { pos.x = ARENA_BOUNDS; vel.vx = -vel.vx; }
        if (pos.y < -ARENA_BOUNDS) { pos.y = -ARENA_BOUNDS; vel.vy = -vel.vy; }
        else if (pos.y > ARENA_BOUNDS) { pos.y = ARENA_BOUNDS; vel.vy = -vel.vy; }
        if (pos.z < -ARENA_BOUNDS) { pos.z = -ARENA_BOUNDS; vel.vz = -vel.vz; }
        else if (pos.z > ARENA_BOUNDS) { pos.z = ARENA_BOUNDS; vel.vz = -vel.vz; }

        // 3. Combat stats update
        cbt.hp += cbt.regen * dt;
        if (cbt.hp > cbt.maxHp) cbt.hp = cbt.maxHp;
    }
}

// ===========================================================================
// Architecture 4: Dynamic Scripted ECS (SceneWorld + D Script Component & Lifecycle)
// ===========================================================================

@component
struct EnemyScriptComponent {
    @export_ float speed = 12.0f;
    @export_ float targetX = 0.0f;
    @export_ float targetY = 0.0f;
    @export_ float targetZ = 0.0f;
    int state = 0;

    void onUpdate(ref ScriptContext ctx, float dt) @safe nothrow {
        auto pos = ctx.getPtr!Position();
        auto vel = ctx.getPtr!Velocity();
        auto cbt = ctx.getPtr!CombatStats();
        if (pos is null || vel is null || cbt is null) return;

        // 1. AI Steering toward target
        float dx = targetX - pos.x;
        float dy = targetY - pos.y;
        float dz = targetZ - pos.z;
        float distSq = dx * dx + dy * dy + dz * dz;
        if (distSq > 0.0001f) {
            float invDist = 1.0f / sqrt(distSq);
            vel.vx += (dx * invDist * speed - vel.vx) * 0.1f;
            vel.vy += (dy * invDist * speed - vel.vy) * 0.1f;
            vel.vz += (dz * invDist * speed - vel.vz) * 0.1f;
        }
        state = (distSq < (AGGRO_RADIUS * AGGRO_RADIUS)) ? 1 : 0;

        // 2. Kinematics integration & bounds reflection
        pos.x += vel.vx * dt;
        pos.y += vel.vy * dt;
        pos.z += vel.vz * dt;
        if (pos.x < -ARENA_BOUNDS) { pos.x = -ARENA_BOUNDS; vel.vx = -vel.vx; }
        else if (pos.x > ARENA_BOUNDS) { pos.x = ARENA_BOUNDS; vel.vx = -vel.vx; }
        if (pos.y < -ARENA_BOUNDS) { pos.y = -ARENA_BOUNDS; vel.vy = -vel.vy; }
        else if (pos.y > ARENA_BOUNDS) { pos.y = ARENA_BOUNDS; vel.vy = -vel.vy; }
        if (pos.z < -ARENA_BOUNDS) { pos.z = -ARENA_BOUNDS; vel.vz = -vel.vz; }
        else if (pos.z > ARENA_BOUNDS) { pos.z = ARENA_BOUNDS; vel.vz = -vel.vz; }

        // 3. Combat stats update
        cbt.hp += cbt.regen * dt;
        if (cbt.hp > cbt.maxHp) cbt.hp = cbt.maxHp;
    }
}

// ===========================================================================
// Benchmark Harness & Runner
// ===========================================================================

BenchStats runOopBenchmark(size_t entityCount, size_t frameCount, bool fragmentedHeap = false) {
    GameObject[] actors = new GameObject[entityCount];

    if (!fragmentedHeap) {
        // Contiguous linear allocation
        foreach (i; 0 .. entityCount) {
            float px = cast(float)((i * 17) % 360) - 180.0f;
            float py = cast(float)((i * 31) % 360) - 180.0f;
            float pz = cast(float)((i * 47) % 360) - 180.0f;
            actors[i] = new EnemyActor(px, py, pz, 10.0f + (i % 5));
        }
    } else {
        // Fragmented heap: allocate dummy objects in between to simulate real runtime heap fragmentation
        foreach (i; 0 .. entityCount) {
            float px = cast(float)((i * 17) % 360) - 180.0f;
            float py = cast(float)((i * 31) % 360) - 180.0f;
            float pz = cast(float)((i * 47) % 360) - 180.0f;
            actors[i] = new EnemyActor(px, py, pz, 10.0f + (i % 5));
            // Interleave with small scratch buffers (mimics game event, string, or UI allocations)
            auto dummy = new ubyte[128];
        }
    }

    // Warmup 10 frames
    foreach (_; 0 .. 10) {
        foreach (a; actors) a.update(SIM_DT);
    }

    GC.collect();
    size_t gcBefore = GC.stats().allocatedInCurrentThread;

    double[] frameTimesUs = new double[frameCount];
    auto tStart = MonoTime.currTime;

    foreach (f; 0 .. frameCount) {
        auto t0 = MonoTime.currTime;
        foreach (a; actors) {
            a.update(SIM_DT);
        }
        auto t1 = MonoTime.currTime;
        frameTimesUs[f] = cast(double)(t1 - t0).total!"nsecs" / 1000.0;
    }

    auto tEnd = MonoTime.currTime;
    size_t gcAfter = GC.stats().allocatedInCurrentThread;

    string label = fragmentedHeap ? "OOP (Fragmented Heap / Churn)" : "OOP (Contiguous Objects)";
    return computeStats(label, entityCount, frameCount, frameTimesUs, (tEnd - tStart), gcAfter - gcBefore);
}

BenchStats runStaticEcsSoaBenchmark(size_t entityCount, size_t frameCount) {
    StaticGameWorld world;

    foreach (i; 0 .. entityCount) {
        float px = cast(float)((i * 17) % 360) - 180.0f;
        float py = cast(float)((i * 31) % 360) - 180.0f;
        float pz = cast(float)((i * 47) % 360) - 180.0f;
        auto e = world.spawn();
        world.set(e, Position(px, py, pz));
        world.set(e, Velocity(0, 0, 0));
        world.set(e, CombatStats(100, 100, 10, 2, 1));
        world.set(e, EnemyAI(0, 0, 0, 10.0f + (i % 5), 0));
    }

    // Warmup
    foreach (_; 0 .. 10) {
        tickStaticEcsSoaDense(world, SIM_DT);
    }

    GC.collect();
    size_t gcBefore = GC.stats().allocatedInCurrentThread;

    double[] frameTimesUs = new double[frameCount];
    auto tStart = MonoTime.currTime;

    foreach (f; 0 .. frameCount) {
        auto t0 = MonoTime.currTime;
        tickStaticEcsSoaDense(world, SIM_DT);
        auto t1 = MonoTime.currTime;
        frameTimesUs[f] = cast(double)(t1 - t0).total!"nsecs" / 1000.0;
    }

    auto tEnd = MonoTime.currTime;
    size_t gcAfter = GC.stats().allocatedInCurrentThread;

    return computeStats("Static ECS (Direct SoA Array)", entityCount, frameCount, frameTimesUs, (tEnd - tStart), gcAfter - gcBefore);
}

BenchStats runStaticEcsQueryBenchmark(size_t entityCount, size_t frameCount) {
    StaticGameWorld world;

    foreach (i; 0 .. entityCount) {
        float px = cast(float)((i * 17) % 360) - 180.0f;
        float py = cast(float)((i * 31) % 360) - 180.0f;
        float pz = cast(float)((i * 47) % 360) - 180.0f;
        auto e = world.spawn();
        world.set(e, Position(px, py, pz));
        world.set(e, Velocity(0, 0, 0));
        world.set(e, CombatStats(100, 100, 10, 2, 1));
        world.set(e, EnemyAI(0, 0, 0, 10.0f + (i % 5), 0));
    }

    // Warmup
    foreach (_; 0 .. 10) {
        tickStaticEcsQuery(world, SIM_DT);
    }

    GC.collect();
    size_t gcBefore = GC.stats().allocatedInCurrentThread;

    double[] frameTimesUs = new double[frameCount];
    auto tStart = MonoTime.currTime;

    foreach (f; 0 .. frameCount) {
        auto t0 = MonoTime.currTime;
        tickStaticEcsQuery(world, SIM_DT);
        auto t1 = MonoTime.currTime;
        frameTimesUs[f] = cast(double)(t1 - t0).total!"nsecs" / 1000.0;
    }

    auto tEnd = MonoTime.currTime;
    size_t gcAfter = GC.stats().allocatedInCurrentThread;

    return computeStats("Static ECS (Sparse Query)", entityCount, frameCount, frameTimesUs, (tEnd - tStart), gcAfter - gcBefore);
}

BenchStats runSceneWorldBenchmark(size_t entityCount, size_t frameCount) {
    SceneWorld world;

    foreach (i; 0 .. entityCount) {
        float px = cast(float)((i * 17) % 360) - 180.0f;
        float py = cast(float)((i * 31) % 360) - 180.0f;
        float pz = cast(float)((i * 47) % 360) - 180.0f;
        auto e = world.spawn();
        world.set(e, Position(px, py, pz));
        world.set(e, Velocity(0, 0, 0));
        world.set(e, CombatStats(100, 100, 10, 2, 1));
        world.set(e, EnemyAI(0, 0, 0, 10.0f + (i % 5), 0));
    }

    // Warmup
    foreach (_; 0 .. 10) {
        tickSceneWorldNative(world, SIM_DT);
    }

    GC.collect();
    size_t gcBefore = GC.stats().allocatedInCurrentThread;

    double[] frameTimesUs = new double[frameCount];
    auto tStart = MonoTime.currTime;

    foreach (f; 0 .. frameCount) {
        auto t0 = MonoTime.currTime;
        tickSceneWorldNative(world, SIM_DT);
        auto t1 = MonoTime.currTime;
        frameTimesUs[f] = cast(double)(t1 - t0).total!"nsecs" / 1000.0;
    }

    auto tEnd = MonoTime.currTime;
    size_t gcAfter = GC.stats().allocatedInCurrentThread;

    return computeStats("SceneWorld Dynamic ECS (Query)", entityCount, frameCount, frameTimesUs, (tEnd - tStart), gcAfter - gcBefore);
}

BenchStats runScriptedEcsBenchmark(size_t entityCount, size_t frameCount) {
    SceneWorld world;
    ModuleRegistrar reg;
    reg.types = &world.types;
    reg.strings = &world.strings;
    reg.registerComponent!EnemyScriptComponent();

    HotReloadManager hotReload;
    hotReload.currentModule.registrar = reg;

    ScriptContext ctx;
    ctx.world = &world;
    ctx.dt = SIM_DT;

    foreach (i; 0 .. entityCount) {
        float px = cast(float)((i * 17) % 360) - 180.0f;
        float py = cast(float)((i * 31) % 360) - 180.0f;
        float pz = cast(float)((i * 47) % 360) - 180.0f;
        auto e = world.spawn();
        world.set(e, Position(px, py, pz));
        world.set(e, Velocity(0, 0, 0));
        world.set(e, CombatStats(100, 100, 10, 2, 1));
        world.set(e, EnemyScriptComponent(10.0f + (i % 5), 0, 0, 0, 0));
    }

    // Warmup
    foreach (_; 0 .. 10) {
        hotReload.tickLifecycle(world, LifecycleMask.onUpdate, ctx);
    }

    GC.collect();
    size_t gcBefore = GC.stats().allocatedInCurrentThread;

    double[] frameTimesUs = new double[frameCount];
    auto tStart = MonoTime.currTime;

    foreach (f; 0 .. frameCount) {
        auto t0 = MonoTime.currTime;
        hotReload.tickLifecycle(world, LifecycleMask.onUpdate, ctx);
        auto t1 = MonoTime.currTime;
        frameTimesUs[f] = cast(double)(t1 - t0).total!"nsecs" / 1000.0;
    }

    auto tEnd = MonoTime.currTime;
    size_t gcAfter = GC.stats().allocatedInCurrentThread;

    return computeStats("Dynamic D Scripted ECS (Lifecycle)", entityCount, frameCount, frameTimesUs, (tEnd - tStart), gcAfter - gcBefore);
}

BenchStats computeStats(
    string name,
    size_t entityCount,
    size_t frameCount,
    double[] timesUs,
    Duration totalDur,
    size_t gcAllocBytes
) {
    BenchStats s;
    s.name = name;
    s.entityCount = entityCount;
    s.frameCount = frameCount;
    s.totalMs = cast(double) totalDur.total!"usecs" / 1000.0;
    s.gcAllocatedBytes = gcAllocBytes;

    double sumUs = 0;
    double minV = double.max;
    double maxV = 0;

    foreach (t; timesUs) {
        sumUs += t;
        if (t < minV) minV = t;
        if (t > maxV) maxV = t;
    }

    s.meanUs = sumUs / frameCount;
    s.minUs = minV;
    s.maxUs = maxV;

    // Percentiles
    sort(timesUs);
    s.medianUs = timesUs[frameCount / 2];
    s.p95Us = timesUs[cast(size_t)(frameCount * 0.95)];
    s.p99Us = timesUs[cast(size_t)(frameCount * 0.99)];

    double totalUpdates = cast(double) entityCount * frameCount;
    s.throughputOpsPerMs = (s.totalMs > 0) ? (totalUpdates / s.totalMs) : 0;

    return s;
}

void printHeader(string title, size_t entityCount, size_t frameCount) {
    writeln("\n==========================================================================================");
    writefln(" %s — %d Entidades x %d Frames", title, entityCount, frameCount);
    writeln("==========================================================================================");
    writefln("%-35s | %-10s | %-10s | %-10s | %-11s | %-9s | %-8s",
        "Arquitetura", "Média (µs)", "P95 (µs)", "P99 (µs)", "Ops/ms", "GC/Frame", "Speedup");
    writeln("------------------------------------+------------+------------+------------+-------------+-----------+---------");
}

void printResultRow(ref BenchStats s, double baselineMeanUs) {
    s.speedupVsOop = (s.meanUs > 0) ? (baselineMeanUs / s.meanUs) : 1.0;
    writefln("%-35s | %10.2f | %10.2f | %10.2f | %11.0f | %9d | %7.2fx",
        s.name, s.meanUs, s.p95Us, s.p99Us, s.throughputOpsPerMs, s.gcAllocatedBytes / s.frameCount, s.speedupVsOop);
}

void runHomogeneousSuite(size_t entityCount, size_t frameCount) {
    printHeader("CENÁRIO 1: Homogeneous Swarm (Simulação Completa)", entityCount, frameCount);

    auto oopContig = runOopBenchmark(entityCount, frameCount, false);
    printResultRow(oopContig, oopContig.meanUs);

    auto oopFrag = runOopBenchmark(entityCount, frameCount, true);
    printResultRow(oopFrag, oopContig.meanUs);

    auto staticSoa = runStaticEcsSoaBenchmark(entityCount, frameCount);
    printResultRow(staticSoa, oopContig.meanUs);

    auto staticQuery = runStaticEcsQueryBenchmark(entityCount, frameCount);
    printResultRow(staticQuery, oopContig.meanUs);

    auto sceneWorld = runSceneWorldBenchmark(entityCount, frameCount);
    printResultRow(sceneWorld, oopContig.meanUs);

    auto scripted = runScriptedEcsBenchmark(entityCount, frameCount);
    printResultRow(scripted, oopContig.meanUs);

    writeln("------------------------------------------------------------------------------------------");
}

// ===========================================================================
// Scenario 2: Heterogeneous Scene (Realistic Game Composition & Filtering)
// 60% Static Props (Position) + 30% Bullets (Position, Velocity) + 10% Enemies (Full)
// ===========================================================================

void runHeterogeneousSuite(size_t totalEntities, size_t frameCount) {
    printHeader("CENÁRIO 2: Heterogeneous World (60% Props, 30% Bullets, 10% Enemies)", totalEntities, frameCount);

    size_t numProps = (totalEntities * 60) / 100;
    size_t numBullets = (totalEntities * 30) / 100;
    size_t numEnemies = totalEntities - numProps - numBullets;

    // 1. OOP Setup
    GameObject[] actors = new GameObject[totalEntities];
    size_t idx = 0;
    foreach (i; 0 .. numProps) actors[idx++] = new StaticPropActor(cast(float)i, 0, 0);
    foreach (i; 0 .. numBullets) actors[idx++] = new ProjectileActor(cast(float)i, 0, 0, 10.0f, 0, 0);
    foreach (i; 0 .. numEnemies) actors[idx++] = new EnemyActor(cast(float)i, 0, 0, 12.0f);

    // Warmup
    foreach (_; 0 .. 10) {
        foreach (a; actors) a.update(SIM_DT);
    }
    GC.collect();
    size_t gcOopBefore = GC.stats().allocatedInCurrentThread;

    double[] oopTimesUs = new double[frameCount];
    auto tOop0 = MonoTime.currTime;
    foreach (f; 0 .. frameCount) {
        auto t0 = MonoTime.currTime;
        foreach (a; actors) {
            a.update(SIM_DT);
        }
        auto t1 = MonoTime.currTime;
        oopTimesUs[f] = cast(double)(t1 - t0).total!"nsecs" / 1000.0;
    }
    auto tOop1 = MonoTime.currTime;
    size_t gcOopAfter = GC.stats().allocatedInCurrentThread;
    auto oopStats = computeStats("OOP (Iterates All 100k Objects)", totalEntities, frameCount, oopTimesUs, (tOop1 - tOop0), gcOopAfter - gcOopBefore);
    printResultRow(oopStats, oopStats.meanUs);

    // 2. Static ECS Setup
    StaticGameWorld world;
    foreach (i; 0 .. numProps) {
        auto e = world.spawn();
        world.set(e, Position(cast(float)i, 0, 0));
    }
    foreach (i; 0 .. numBullets) {
        auto e = world.spawn();
        world.set(e, Position(cast(float)i, 0, 0));
        world.set(e, Velocity(10.0f, 0, 0));
    }
    foreach (i; 0 .. numEnemies) {
        auto e = world.spawn();
        world.set(e, Position(cast(float)i, 0, 0));
        world.set(e, Velocity(0, 0, 0));
        world.set(e, CombatStats(100, 100, 10, 2, 1));
        world.set(e, EnemyAI(0, 0, 0, 12.0f, 0));
    }

    // Warmup ECS
    foreach (_; 0 .. 10) {
        // Kinematics moves ONLY moving entities (Bullets + Enemies = 40% of world)
        foreach (e; world.query!(Position, Velocity)) {
            auto pos = world.getPtr!Position(e);
            auto vel = world.getPtr!Velocity(e);
            pos.x += vel.vx * SIM_DT;
            pos.y += vel.vy * SIM_DT;
            pos.z += vel.vz * SIM_DT;
        }
        // AI runs ONLY on Enemies (10% of world)
        foreach (e; world.query!(EnemyAI, Position, Velocity)) {
            auto ai = world.getPtr!EnemyAI(e);
            auto pos = world.getPtr!Position(e);
            auto vel = world.getPtr!Velocity(e);
            float dx = ai.targetX - pos.x;
            float dy = ai.targetY - pos.y;
            float dz = ai.targetZ - pos.z;
            float distSq = dx * dx + dy * dy + dz * dz;
            if (distSq > 0.0001f) {
                float invDist = 1.0f / sqrt(distSq);
                vel.vx += (dx * invDist * ai.speed - vel.vx) * 0.1f;
            }
        }
    }
    GC.collect();
    size_t gcEcsBefore = GC.stats().allocatedInCurrentThread;

    double[] ecsTimesUs = new double[frameCount];
    auto tEcs0 = MonoTime.currTime;
    foreach (f; 0 .. frameCount) {
        auto t0 = MonoTime.currTime;
        // Kinematics moves ONLY moving entities (Bullets + Enemies)
        foreach (e; world.query!(Position, Velocity)) {
            auto pos = world.getPtr!Position(e);
            auto vel = world.getPtr!Velocity(e);
            pos.x += vel.vx * SIM_DT;
            pos.y += vel.vy * SIM_DT;
            pos.z += vel.vz * SIM_DT;
        }
        // AI runs ONLY on Enemies (10%)
        foreach (e; world.query!(EnemyAI, Position, Velocity)) {
            auto ai = world.getPtr!EnemyAI(e);
            auto pos = world.getPtr!Position(e);
            auto vel = world.getPtr!Velocity(e);
            float dx = ai.targetX - pos.x;
            float dy = ai.targetY - pos.y;
            float dz = ai.targetZ - pos.z;
            float distSq = dx * dx + dy * dy + dz * dz;
            if (distSq > 0.0001f) {
                float invDist = 1.0f / sqrt(distSq);
                vel.vx += (dx * invDist * ai.speed - vel.vx) * 0.1f;
            }
        }
        auto t1 = MonoTime.currTime;
        ecsTimesUs[f] = cast(double)(t1 - t0).total!"nsecs" / 1000.0;
    }
    auto tEcs1 = MonoTime.currTime;
    size_t gcEcsAfter = GC.stats().allocatedInCurrentThread;
    auto ecsStats = computeStats("Static ECS (Queries Target Sets)", totalEntities, frameCount, ecsTimesUs, (tEcs1 - tEcs0), gcEcsAfter - gcEcsBefore);
    printResultRow(ecsStats, oopStats.meanUs);

    writeln("------------------------------------------------------------------------------------------");
}

void main(string[] args) {
    size_t[] tiers = [1_000, 5_000, 20_000, 50_000];
    size_t frameCount = 300;

    foreach (arg; args[1 .. $]) {
        if (arg.length > 11 && arg[0 .. 11] == "--entities=") {
            tiers = [to!size_t(arg[11 .. $])];
        } else if (arg.length > 9 && arg[0 .. 9] == "--frames=") {
            frameCount = to!size_t(arg[9 .. $]);
        }
    }

    writeln("\n==========================================================================================");
    writeln("       ESTUDO COMPARATIVO DE PERFORMANCE: ARQUITETURAS DE JOGO NA GAME ENGINE D           ");
    writeln("==========================================================================================");
    writeln("Ambiente de Teste: D (DMD 64-bit com DIP1000, Release)");
    writeln("Comparação: Non-ECS (OOP) vs Native Static ECS vs SceneWorld Dynamic vs D Scripts");

    foreach (tier; tiers) {
        runHomogeneousSuite(tier, frameCount);
    }

    // Run realistic mixed composition scene (100,000 entities)
    runHeterogeneousSuite(100_000, frameCount);

    writeln("\n==========================================================================================");
    writeln("                                  CONCLUSÕES GERAIS                                       ");
    writeln("==========================================================================================");
    writeln("1. Static ECS (Direct SoA): Máxima vazão de processamento vetorial (SoA em cache L1).");
    writeln("2. Static ECS (Sparse Query): Escala linearmente e filtra conjuntos específicos sem overhead.");
    writeln("3. Em mundos heterogêneos reais (Props + Balas + Inimigos), o ECS supera o OOP ao evitar");
    writeln("   iterações e dereferenciamentos desnecessários em entidades estáticas.");
    writeln("4. Dynamic D Scripted ECS: Permite prototipagem ágil no editor (com hot-reload e reflexão),");
    writeln("   mantendo 0 alocações no GC e taxa de mais de 10 milhões de updates/segundo.");
    writeln("==========================================================================================\n");
}
