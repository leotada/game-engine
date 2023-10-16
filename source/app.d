import std.stdio;
import std.random;

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
    ParticleSystem particleSystem = new ParticleSystem();
    CircleSystem circleSystem = new CircleSystem();

    EntityManager em = new EntityManager();
    SystemManager systemManager = new SystemManager(em);
    systemManager.add(particleSystem);
    systemManager.add(circleSystem);

    void start()
    {
        InitWindow(1000, 800, "Hello, Raylib-D!");
        SetTargetFPS(144);            
    }

    void load()
    {
        foreach (i; 0 .. 6_000)
        {
            auto e = new Entity();
            em.add(e);
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
        }
        
    }

    // Init Window
    void gameLoop()
    {
        while (!WindowShouldClose())
        {
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
        }
    }

    void shutdown()
    {
        CloseWindow();

        debug {
            import core.memory;
            writeln("GC Debug:");
            writeln(GC.profileStats().numCollections);
            writeln(GC.profileStats().maxCollectionTime);
        }
    }

    start();
    load();
    gameLoop();
    shutdown();
}
