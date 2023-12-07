module system.manager;

import core.time;

import system;
import system.graphic;
import entity.manager;

import raylib;


class SystemManager
{
    private ISystem[] systems;
    private IGraphic[] graphicSystems;
    private EntityManager entityManager;

    this(ref EntityManager entityManager)
    {
        this.entityManager = entityManager;
    }

    void add(ISystem system)
    {
        systems ~= system;
    }

    void add(IGraphic system)
    {
        graphicSystems ~= system;
    }

    void run()
    {
        foreach (ref system; systems)
        {
            auto before = MonoTime.currTime;
            system.run(entityManager, GetFrameTime());
            auto timeElapsed = MonoTime.currTime - before;
            debug { import std.stdio : writeln; try { writeln(system, " ", timeElapsed); } catch (Exception) {} }
        }
    }

    void runGraphics()
    {
        foreach (ref system; graphicSystems)
        {
            auto before = MonoTime.currTime;
            system.run(entityManager, GetFrameTime());
            auto timeElapsed = MonoTime.currTime - before;
            debug { import std.stdio : writeln; try { writeln(system, " ", timeElapsed); } catch (Exception) {} }
        }
    }
}
