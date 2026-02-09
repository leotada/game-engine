import std.stdio;
import std.random;
import std.math;
import std.format;
import std.conv;
import std.string : toStringz;
import core.memory;
import core.time;
import std.datetime.stopwatch;

import raylib;

import entity;
import entity.manager;
import component.particle;
import component.graphic.circle;
import component.timeout;
import system.manager;
import system.particle;
import system.graphic.circle;
import system.timeout;
import math.vector;
import pool;

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark Configuration
// ─────────────────────────────────────────────────────────────────────────────
immutable int WINDOW_WIDTH = 1200;
immutable int WINDOW_HEIGHT = 900;
immutable int SPAWN_POINTS = 7; // Number of particle fountains
immutable int PARTICLES_PER_SPAWN = 5; // Particles per fountain per frame
immutable float MIN_TIMEOUT = 0.5;
immutable float MAX_TIMEOUT = 3.0;
immutable float MIN_RADIUS = 3.0;
immutable float MAX_RADIUS = 12.0;
immutable float BENCHMARK_DURATION = 20.0; // Auto-exit after 20 seconds

// ─────────────────────────────────────────────────────────────────────────────
// Statistics Tracking
// ─────────────────────────────────────────────────────────────────────────────
struct BenchmarkStats
{
    ulong totalEntitiesCreated = 0;
    ulong peakActiveEntities = 0;
    ulong peakMemoryUsed = 0;
    float maxFrameTime = 0;
    float totalFrameTime = 0;
    ulong frameCount = 0;
    StopWatch runtimeWatch;
}

// ─────────────────────────────────────────────────────────────────────────────
// Color Utilities
// ─────────────────────────────────────────────────────────────────────────────
Color hsvToRgb(float h, float s, float v)
{
    h = h % 360.0f;
    float c = v * s;
    float x = c * (1 - abs((h / 60.0f) % 2 - 1));
    float m = v - c;

    float r, g, b;
    if (h < 60)
    {
        r = c;
        g = x;
        b = 0;
    }
    else if (h < 120)
    {
        r = x;
        g = c;
        b = 0;
    }
    else if (h < 180)
    {
        r = 0;
        g = c;
        b = x;
    }
    else if (h < 240)
    {
        r = 0;
        g = x;
        b = c;
    }
    else if (h < 300)
    {
        r = x;
        g = 0;
        b = c;
    }
    else
    {
        r = c;
        g = 0;
        b = x;
    }

    return Color(
        cast(ubyte)((r + m) * 255),
        cast(ubyte)((g + m) * 255),
        cast(ubyte)((b + m) * 255),
        255
    );
}

Colors hsvToColors(float h, float s, float v)
{
    // Raylib-d uses Colors enum, we need to work around this
    // For the benchmark, we'll cycle through a predefined palette
    int idx = cast(int)(h / 30) % 12;
    Colors[] palette = [
        Colors.RED, Colors.ORANGE, Colors.YELLOW, Colors.LIME,
        Colors.GREEN, Colors.SKYBLUE, Colors.BLUE, Colors.VIOLET,
        Colors.PURPLE, Colors.PINK, Colors.MAGENTA, Colors.MAROON
    ];
    return palette[idx];
}

// ─────────────────────────────────────────────────────────────────────────────
// Main Benchmark
// ─────────────────────────────────────────────────────────────────────────────
void main()
{
    BenchmarkStats stats;
    scope ParticleSystem particleSystem = new ParticleSystem();
    scope CircleSystem circleSystem = new CircleSystem();
    scope TimeoutSystem timeoutSystem = new TimeoutSystem();

    scope EntityManager em = new EntityManager();
    scope SystemManager systemManager = new SystemManager(em);

    // Component pools for reduced GC pressure
    auto particlePool = new ObjectPool!Particle();
    auto circlePool = new ObjectPool!Circle();
    auto timeoutPool = new ObjectPool!Timeout();

    systemManager.add(particleSystem);
    systemManager.add(circleSystem);
    systemManager.add(timeoutSystem);

    auto rng = Random(unpredictableSeed);
    float hueOffset = 0;

    void start()
    {
        InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Game Engine Benchmark - CPU/GC Stress Test");
        SetTargetFPS(144);
        stats.runtimeWatch.start();
    }

    // Spawn particles from a fountain at given position
    void spawnParticles(float spawnX, float spawnY, float hue)
    {
        foreach (i; 0 .. PARTICLES_PER_SPAWN)
        {
            auto e = em.createEntity();

            // Acquire components from pools
            auto particle = particlePool.acquire();
            particle.gravity = true;

            // Initial position with slight random offset
            e.position.x = spawnX + uniform(-20.0f, 20.0f, rng);
            e.position.y = spawnY;

            // Initial upward velocity with random spread
            particle.velocity.x = uniform(-150.0f, 150.0f, rng);
            particle.velocity.y = uniform(-400.0f, -200.0f, rng);

            e.addComponent!Particle(particle);

            // Varying circle sizes and colors
            auto circle = circlePool.acquire();
            circle.radius = uniform(MIN_RADIUS, MAX_RADIUS, rng);
            float particleHue = hue + uniform(-30.0f, 30.0f, rng);
            circle.color = hsvToColors(particleHue, 0.9, 1.0);
            e.addComponent!Circle(circle);

            // Random timeout for GC stress
            auto timeout = timeoutPool.acquire();
            timeout.duration = uniform(MIN_TIMEOUT, MAX_TIMEOUT, rng);
            e.addComponent!Timeout(timeout);

            em.add(e);
            stats.totalEntitiesCreated++;
        }
    }

    // Cleanup inactive entities and return components to pools
    void cleanupInactiveEntities()
    {
        foreach (ref Entity entity; em.getByComponent!Timeout())
        {
            if (entity is null || entity.active)
                continue;

            // Release components back to pools
            auto particle = entity.getComponent!Particle();
            if (particle !is null)
                particlePool.release(particle);

            auto circle = entity.getComponent!Circle();
            if (circle !is null)
                circlePool.release(circle);

            auto timeout = entity.getComponent!Timeout();
            if (timeout !is null)
                timeoutPool.release(timeout);

            // Remove entity from manager (returns entity to pool)
            em.remove(entity);
        }
    }

    void gameLoop()
    {
        StopWatch sw = StopWatch();

        while (!WindowShouldClose() && stats.runtimeWatch.peek.total!"msecs" / 1000.0 < BENCHMARK_DURATION)
        {
            sw.start();

            // ─────────────────────────────────────────────────────────────────
            // Spawn Phase - Create particles from multiple fountain positions
            // ─────────────────────────────────────────────────────────────────
            hueOffset += 2.0f; // Color cycling

            foreach (i; 0 .. SPAWN_POINTS)
            {
                // Semi-circle arrangement at bottom of screen
                float angle = std.math.PI * (cast(float) i / (SPAWN_POINTS - 1));
                float spawnX = WINDOW_WIDTH / 2 + cos(angle) * 300;
                float spawnY = WINDOW_HEIGHT - 50;
                float hue = hueOffset + (360.0f * i / SPAWN_POINTS);

                spawnParticles(spawnX, spawnY, hue);
            }

            // ─────────────────────────────────────────────────────────────────
            // Gameplay Phase
            // ─────────────────────────────────────────────────────────────────
            systemManager.run();

            // Release expired entities back to pools
            cleanupInactiveEntities();

            // Count active entities
            ulong activeCount = 0;
            foreach (entity; em.getByComponent!Particle())
            {
                if (entity !is null && entity.active)
                    activeCount++;
            }
            if (activeCount > stats.peakActiveEntities)
                stats.peakActiveEntities = activeCount;

            // Track memory usage
            auto gcStats = GC.stats();
            if (gcStats.usedSize > stats.peakMemoryUsed)
                stats.peakMemoryUsed = gcStats.usedSize;

            // ─────────────────────────────────────────────────────────────────
            // Draw Phase
            // ─────────────────────────────────────────────────────────────────
            BeginDrawing();
            ClearBackground(Color(15, 15, 25, 255));

            // Draw particles
            systemManager.runGraphics();

            // ─────────────────────────────────────────────────────────────────
            // Stats Overlay
            // ─────────────────────────────────────────────────────────────────
            auto profileStats = GC.profileStats();

            int overlayX = 15;
            int overlayY = 15;
            int lineHeight = 22;

            // Semi-transparent background for stats
            DrawRectangle(10, 10, 280, 200, Color(0, 0, 0, 180));

            // FPS
            DrawText("FPS:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d", GetFPS())), overlayX + 100, overlayY, 18, Colors.LIME);
            overlayY += lineHeight;

            // Active Entities
            DrawText("Entities:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d", activeCount)), overlayX + 100, overlayY, 18, Colors
                    .YELLOW);
            overlayY += lineHeight;

            // Total Created
            DrawText("Created:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d", stats.totalEntitiesCreated)), overlayX + 100, overlayY, 18, Colors
                    .ORANGE);
            overlayY += lineHeight;

            // GC Collections
            DrawText("GC Runs:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d", profileStats.numCollections)), overlayX + 100, overlayY, 18, Colors
                    .SKYBLUE);
            overlayY += lineHeight;

            // Memory Used
            DrawText("Memory:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%.2f MB", gcStats.usedSize / 1024.0 / 1024.0)), overlayX + 100, overlayY, 18, Colors
                    .PINK);
            overlayY += lineHeight;

            // Peak Memory
            DrawText("Peak Mem:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%.2f MB", stats.peakMemoryUsed / 1024.0 / 1024.0)), overlayX + 100, overlayY, 18, Colors
                    .MAGENTA);
            overlayY += lineHeight;

            // Max Pause Time
            DrawText("Max Pause:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%.2f ms", profileStats.maxPauseTime.total!"usecs" / 1000.0)), overlayX + 100, overlayY, 18, Colors
                    .RED);
            overlayY += lineHeight;

            // Title at bottom
            DrawText("Press ESC to exit and view report",
                WINDOW_WIDTH / 2 - 180, WINDOW_HEIGHT - 30, 18, Colors.GRAY);

            EndDrawing();

            // ─────────────────────────────────────────────────────────────────
            // Frame Timing
            // ─────────────────────────────────────────────────────────────────
            sw.stop();
            float frameTime = sw.peek.total!"usecs" / 1000.0f;
            sw.reset();

            if (frameTime > stats.maxFrameTime)
                stats.maxFrameTime = frameTime;
            stats.totalFrameTime += frameTime;
            stats.frameCount++;
        }
    }

    void shutdown()
    {
        stats.runtimeWatch.stop();
        CloseWindow();

        // ─────────────────────────────────────────────────────────────────────
        // Console Report
        // ─────────────────────────────────────────────────────────────────────
        auto profileStats = GC.profileStats();
        auto gcStats = GC.stats();
        float runtimeSecs = stats.runtimeWatch.peek.total!"msecs" / 1000.0f;
        float avgFrameTime = stats.frameCount > 0 ?
            stats.totalFrameTime / stats.frameCount : 0;

        writeln();
        writeln("═══════════════════════════════════════════════════════════════");
        writeln("                    BENCHMARK REPORT");
        writeln("═══════════════════════════════════════════════════════════════");
        writefln("  Runtime:               %.2f s", runtimeSecs);
        writefln("  Total Frames:          %d", stats.frameCount);
        writefln("  Total Entities Created: %d", stats.totalEntitiesCreated);
        writefln("  Peak Active Entities:   %d", stats.peakActiveEntities);
        writeln("───────────────────────────────────────────────────────────────");
        writeln("  GC Statistics:");
        writefln("    Collections:         %d", profileStats.numCollections);
        writefln("    Max Collection Time: %.2f ms",
            profileStats.maxCollectionTime.total!"usecs" / 1000.0);
        writefln("    Max Pause Time:      %.2f ms",
            profileStats.maxPauseTime.total!"usecs" / 1000.0);
        writeln("───────────────────────────────────────────────────────────────");
        writeln("  Memory Statistics:");
        writefln("    Peak Memory Used:    %.2f MB", stats.peakMemoryUsed / 1024.0 / 1024.0);
        writefln("    Final Memory Used:   %.2f MB", gcStats.usedSize / 1024.0 / 1024.0);
        writeln("───────────────────────────────────────────────────────────────");
        writeln("  Frame Statistics:");
        writefln("    Max Frame Time:      %.2f ms", stats.maxFrameTime);
        writefln("    Avg Frame Time:      %.2f ms", avgFrameTime);
        writefln("    Avg FPS:             %.1f", stats.frameCount > 0 ?
                1000.0 / avgFrameTime : 0);
        writeln("═══════════════════════════════════════════════════════════════");
        writeln();
    }

    start();
    gameLoop();
    shutdown();
}
