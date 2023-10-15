import std.stdio;
import std.random;
// import std.parallelism;

import raylib;

import entity;
import entity.entity_manager;
import component.manager;
import component.particle;
import system.system_manager;
import system.particle;

import math.vector;


void main()
{
    Particle[] particles;
    ParticleSystem particleSystem = new ParticleSystem();

    ComponentManager cm = new ComponentManager();
    EntityManager em = new EntityManager();
    SystemManager systemManager = new SystemManager(cm);
    systemManager.add(particleSystem);

    void load()
    {

        auto e = new Entity();
        auto e2 = new Entity();
        //auto particle_test = new Particle();
        //e.AddComponent(particle_test);
        em.add(e);
        em.add(e2);
        //cm.Add!Particle(particle_test);
        //e2.AddComponent(particle_test);
        //writeln(e.GetComponents!Particle());

        foreach (i; 0 .. 6_000)
        {
            auto particle = new Particle();
            particle.gravity = true;
            particle.vPosition.x = GetRandomValue(30, 1000);
            particle.vPosition.y = GetRandomValue(20, 800);
            cm.Add!Particle(particle);
        }

    }

    // Init Window
    void gameLoop()
    {
        InitWindow(1000, 800, "Hello, Raylib-D!");
        SetTargetFPS(144);
        scope(exit)
            CloseWindow();

        // Game loop
        while (!WindowShouldClose())
        {
            // Physics Phase
            auto rnd = Random(43);
            foreach (ref p; cm.Get!Particle())
            {
                auto i = uniform(-100, 100, rnd);
                p.addForce(Vector(40, 0, 0));
                p.addForce(Vector(i, i, 0));
            }
            
            BeginDrawing();
            ClearBackground(Colors.RAYWHITE);
            // --- Draw Phase ---
            //writeln(systemManager.componentManager);
            systemManager.run();

            DrawFPS(20, 20);
            DrawText("Hello, World!", 400, 300, 14, Colors.BLACK);

            EndDrawing();
        }
    }
    load();
    gameLoop();
    debug {
        import core.memory;
        writeln("GC Debug:");
        writeln(GC.profileStats().numCollections);
        writeln(GC.profileStats().maxCollectionTime);
    }
}
