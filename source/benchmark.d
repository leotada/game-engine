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

import ecs;
import component;
import system;
import math.vector;

// ─────────────────────────────────────────────────────────────────────────────
// Benchmark Configuration
// ─────────────────────────────────────────────────────────────────────────────
immutable int WINDOW_WIDTH = 1200;
immutable int WINDOW_HEIGHT = 900;
immutable int SPAWN_POINTS = 7;
immutable int PARTICLES_PER_SPAWN = 5;
immutable float MIN_TIMEOUT = 0.5;
immutable float MAX_TIMEOUT = 3.0;
immutable float MIN_RADIUS = 3.0;
immutable float MAX_RADIUS = 12.0;
immutable float BENCHMARK_DURATION = 20.0;

// ─────────────────────────────────────────────────────────────────────────────
// Statistics Tracking
// ─────────────────────────────────────────────────────────────────────────────
struct BenchmarkStats
{
    ulong totalEntitiesCreated = 0;
    ulong peakActiveEntities = 0;
    ulong peakMemoryUsed = 0;
    ulong totalCollisions = 0;
    ulong frameCollisions = 0;
    float maxFrameTime = 0;
    float totalFrameTime = 0;
    ulong frameCount = 0;
    StopWatch runtimeWatch;
}

// ─────────────────────────────────────────────────────────────────────────────
// Color Utilities
// ─────────────────────────────────────────────────────────────────────────────
Colors hsvToColors(float h, float s, float v)
{
    int idx = cast(int)(h / 30) % 12;
    Colors[] palette = [
        Colors.RED, Colors.ORANGE, Colors.YELLOW, Colors.LIME,
        Colors.GREEN, Colors.SKYBLUE, Colors.BLUE, Colors.VIOLET,
        Colors.PURPLE, Colors.PINK, Colors.MAGENTA, Colors.MAROON
    ];
    return palette[idx];
}

// ─────────────────────────────────────────────────────────────────────────────
// Type alias for our game world
// ─────────────────────────────────────────────────────────────────────────────
alias GameRegistry = Registry!(Position, Particle, Circle, Timeout);

// ─────────────────────────────────────────────────────────────────────────────
// Main Benchmark
// ─────────────────────────────────────────────────────────────────────────────
void main()
{
    BenchmarkStats stats;
    GameRegistry reg;
    CircleRenderer circleRenderer;

    auto rng = Random(unpredictableSeed);
    float hueOffset = 0;

    void start()
    {
        InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Game Engine Benchmark - Metaprogramming ECS");
        SetTargetFPS(1440);
        stats.runtimeWatch.start();
    }

    // Spawn particles from a fountain at given position with a base direction
    void spawnParticles(float spawnX, float spawnY, float dirX, float dirY, float hue)
    {
        foreach (i; 0 .. PARTICLES_PER_SPAWN)
        {
            auto e = reg.create();

            // Position with slight random offset
            reg.store!Position.add(e, Position(
                    spawnX + uniform(-15.0f, 15.0f, rng),
                    spawnY + uniform(-15.0f, 15.0f, rng)
            ));

            // Particle with velocity aimed in the given direction + spread
            Particle particle;
            particle.gravity = true;
            float speed = uniform(200.0f, 400.0f, rng);
            float spread = uniform(-0.4f, 0.4f, rng); // radial spread
            float baseAngle = std.math.atan2(dirY, dirX);
            float angle = baseAngle + spread;
            particle.velocity.x = cos(angle) * speed;
            particle.velocity.y = sin(angle) * speed;
            reg.store!Particle.add(e, particle);

            // Circle with varying sizes and colors
            float particleHue = hue + uniform(-30.0f, 30.0f, rng);
            reg.store!Circle.add(e, Circle(
                    uniform(MIN_RADIUS, MAX_RADIUS, rng),
                    hsvToColors(particleHue, 0.9, 1.0)
            ));

            // Random timeout
            reg.store!Timeout.add(e, Timeout(
                    uniform(MIN_TIMEOUT, MAX_TIMEOUT, rng)
            ));

            stats.totalEntitiesCreated++;
        }
    }

    void gameLoop()
    {
        StopWatch sw = StopWatch();

        while (!WindowShouldClose() && stats.runtimeWatch.peek.total!"msecs" / 1000.0 < BENCHMARK_DURATION)
        {
            sw.start();
            double dt = GetFrameTime();

            // ─────────────────────────────────────────────────────────────────
            // Spawn Phase
            // ─────────────────────────────────────────────────────────────────
            hueOffset += 2.0f;

            // Center of screen (target for inward-aimed spawners)
            float cx = WINDOW_WIDTH / 2.0f;
            float cy = WINDOW_HEIGHT / 2.0f;

            foreach (i; 0 .. SPAWN_POINTS)
            {
                // Distribute spawn points around the screen perimeter
                float t = cast(float) i / SPAWN_POINTS;
                float angle = t * 2.0f * std.math.PI;

                // Elliptical placement along screen edges
                float spawnX = cx + cos(angle) * (WINDOW_WIDTH / 2.0f - 30);
                float spawnY = cy + sin(angle) * (WINDOW_HEIGHT / 2.0f - 30);

                // Direction: aim toward center with some offset
                float dirX = cx - spawnX;
                float dirY = cy - spawnY;
                float dirLen = std.math.sqrt(dirX * dirX + dirY * dirY);
                if (dirLen > 0)
                {
                    dirX /= dirLen;
                    dirY /= dirLen;
                }

                float hue = hueOffset + (360.0f * i / SPAWN_POINTS);

                spawnParticles(spawnX, spawnY, dirX, dirY, hue);
            }

            // ─────────────────────────────────────────────────────────────────
            // Gameplay Phase — direct template calls, no virtual dispatch
            // ─────────────────────────────────────────────────────────────────
            particleSystem(reg, dt);
            stats.frameCollisions = collisionSystem(reg, dt);
            stats.totalCollisions += stats.frameCollisions;
            auto expired = timeoutSystem(reg, dt);

            // Destroy expired entities
            foreach (id; expired)
            {
                reg.destroy(id);
            }

            // Count active entities (use Particle store as reference)
            ulong activeCount = reg.store!Particle.length;
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

            circleRenderer.run(reg, dt);

            // ─────────────────────────────────────────────────────────────────
            // Stats Overlay
            // ─────────────────────────────────────────────────────────────────
            auto profileStats = GC.profileStats();

            int overlayX = 15;
            int overlayY = 15;
            int lineHeight = 22;

            DrawRectangle(10, 10, 280, 245, Color(0, 0, 0, 180));

            DrawText("FPS:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d", GetFPS())), overlayX + 100, overlayY, 18, Colors.LIME);
            overlayY += lineHeight;

            DrawText("Entities:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d", activeCount)), overlayX + 100, overlayY, 18, Colors
                    .YELLOW);
            overlayY += lineHeight;

            DrawText("Created:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d", stats.totalEntitiesCreated)), overlayX + 100, overlayY, 18, Colors
                    .ORANGE);
            overlayY += lineHeight;

            DrawText("GC Runs:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d", profileStats.numCollections)), overlayX + 100, overlayY, 18, Colors
                    .SKYBLUE);
            overlayY += lineHeight;

            DrawText("Memory:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%.2f MB", gcStats.usedSize / 1024.0 / 1024.0)), overlayX + 100, overlayY, 18, Colors
                    .PINK);
            overlayY += lineHeight;

            DrawText("Peak Mem:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%.2f MB", stats.peakMemoryUsed / 1024.0 / 1024.0)), overlayX + 100, overlayY, 18, Colors
                    .MAGENTA);
            overlayY += lineHeight;

            DrawText("Max Pause:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%.2f ms", profileStats.maxPauseTime.total!"usecs" / 1000.0)), overlayX + 100, overlayY, 18, Colors
                    .RED);
            overlayY += lineHeight;

            DrawText("Collisions:", overlayX, overlayY, 18, Colors.WHITE);
            DrawText(toStringz(format("%d / %d", stats.frameCollisions, stats.totalCollisions)), overlayX + 100, overlayY, 18, Colors
                    .LIME);
            overlayY += lineHeight;

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
        writefln("  Total Collisions:       %d", stats.totalCollisions);
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
