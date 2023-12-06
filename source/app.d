import std.stdio;
import std.random;
import core.memory;
import core.time;
import std.datetime.stopwatch;

import raylib;

import entity;
import entity.manager;
import component.particle;
import component.graphic.circle;
import system.manager;
import system.particle;
import system.graphic.circle;
import math.vector;


void main()
{
    Particle[] particles;
    scope ParticleSystem particleSystem = new ParticleSystem();
    scope CircleSystem circleSystem = new CircleSystem();

    scope EntityManager em = new EntityManager();
    scope SystemManager systemManager = new SystemManager(em);
    systemManager.add(particleSystem);
    systemManager.add(circleSystem);

    void start()
    {
        InitWindow(1000, 800, "Hello, Raylib-D!");
        SetTargetFPS(144);
    }

    void load()
    {
        foreach (i; 0 .. 6000)
        {
            auto e = new Entity();
            auto particle = new Particle();
            particle.gravity = true;
            e.position.x = GetRandomValue(30, 1000);
            e.position.y = GetRandomValue(20, 800);
            particle.position.x = e.position.x;
            particle.position.y = e.position.y;
            e.addComponent!Particle(particle);
            auto circle = new Circle();
            circle.radius = 5;
            e.addComponent!Circle(circle);
            em.add(e);  // add in the final only
        }

    }

    // Init Window
    void gameLoop()
    {
		float time = 0;
        float time_raw = 0;
        StopWatch sw = StopWatch();
        float max_frametime = 0;
        while (!WindowShouldClose())
        {
            sw.start();

            // --- Gameplay Phase ---
            systemManager.run();
            // --- Gameplay end ---

            BeginDrawing();
            ClearBackground(Colors.RAYWHITE);
            // --- Draw Phase ---
            systemManager.runGraphics();

            DrawFPS(20, 20);
            DrawText("Hello, World!", 400, 300, 14, Colors.BLACK);

            EndDrawing();

			time += GetFrameTime();
			// manual GC collection
			if (time > 1)
			{
				// GC.collect();
				// GC.minimize();
				time = 0;
			}

            sw.stop();
            time_raw = sw.peek.total!"msecs" / 1000.0f;
            max_frametime = max_frametime > time_raw ? max_frametime : time_raw;
        }

        {
            writeln("Max game loop time:", max_frametime);
        }
    }

    void shutdown()
    {
        CloseWindow();

        debug {
            writeln("GC Debug:");
            writeln(GC.profileStats().numCollections);
            writeln(GC.profileStats().maxCollectionTime);
            writeln(GC.profileStats().maxPauseTime);
        }
    }

    start();
    load();
    GC.disable();
    gameLoop();
    GC.enable();
    shutdown();
}
