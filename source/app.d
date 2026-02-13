import std.stdio;
import std.random;
import core.memory;
import core.time;
import std.datetime.stopwatch;

import raylib;

import ecs;
import component;
import system;
import math.vector;

alias GameRegistry = Registry!(Position, Particle, Circle, Timeout);

void main()
{
    GameRegistry reg;
    CircleRenderer circleRenderer;

    void start()
    {
        InitWindow(1000, 800, "Hello, Raylib-D!");
        SetTargetFPS(144);
    }

    void load()
    {
        auto rng = Random(unpredictableSeed);

        foreach (i; 0 .. 600)
        {
            auto e = reg.create();

            reg.store!Position.add(e, Position(
                    uniform(30.0f, 1000.0f, rng),
                    uniform(20.0f, 800.0f, rng)
            ));

            Particle p;
            p.gravity = true;
            reg.store!Particle.add(e, p);

            reg.store!Circle.add(e, Circle(5, Colors.GRAY));

            reg.store!Timeout.add(e, Timeout(2.0));
        }
    }

    void gameLoop()
    {
        float time_raw = 0;
        StopWatch sw = StopWatch();
        float max_frametime = 0;

        while (!WindowShouldClose())
        {
            sw.start();
            double dt = GetFrameTime();

            // --- Gameplay Phase ---
            particleSystem(reg, dt);
            auto expired = timeoutSystem(reg, dt);

            // Destroy expired entities
            foreach (id; expired)
            {
                reg.destroy(id);
            }

            // --- Draw Phase ---
            BeginDrawing();
            ClearBackground(Colors.RAYWHITE);

            circleRenderer.run(reg, dt);

            DrawFPS(20, 20);
            DrawText("Hello, World!", 400, 300, 14, Colors.BLACK);

            EndDrawing();

            sw.stop();
            time_raw = sw.peek.total!"msecs";
            sw.reset();
            max_frametime = max_frametime > time_raw ? max_frametime : time_raw;
        }

        writeln("Max game loop time:", max_frametime);
    }

    void shutdown()
    {
        CloseWindow();

        debug
        {
            writeln("GC Debug:");
            writeln(GC.profileStats().numCollections);
            writeln(GC.profileStats().maxCollectionTime);
            writeln(GC.profileStats().maxPauseTime);
        }
    }

    start();
    load();
    gameLoop();
    shutdown();
}
