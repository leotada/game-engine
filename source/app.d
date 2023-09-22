import std.stdio;
import std.random;
// import std.parallelism;

import raylib;


immutable float GRAVITYACCELERATION = -9.8;
immutable float PHYSICS_SCALE = 8;


struct Vector
{
    float x = 0;
    float y = 0;
    float z = 0;

    // this + Vector
    Vector opBinary(string op : "+")(Vector rhs)
    {
        Vector vec;
        vec.x = this.x + rhs.x;
        vec.y = this.y + rhs.y;
        vec.z = this.z + rhs.z;
        return vec;
    }

    // this - Vector
    Vector opBinary(string op : "-")(Vector rhs)
    {
        Vector vec;
        vec.x = this.x - rhs.x;
        vec.y = this.y - rhs.y;
        vec.z = this.z - rhs.z;
        return vec;
    }

    // this * rhs
    Vector opBinary(string op : "*", T)(T rhs)
    {
        Vector vec;
        vec.x = this.x * rhs;
        vec.y = this.y * rhs;
        vec.z = this.z * rhs;
        return vec;
    }

    // this / rhs
    Vector opBinary(string op : "/", T)(T rhs)
    {
        Vector vec;
        vec.x = this.x / rhs;
        vec.y = this.y / rhs;
        vec.z = this.z / rhs;
        return vec;
    }

    // this += Vector
    auto ref opOpAssign(string op : "+")(Vector rhs)
    {
        this.x += rhs.x;
        this.y += rhs.y;
        this.z += rhs.z;
        return this;
    }

    // this -= Vector
    auto ref opOpAssign(string op : "-")(Vector rhs)
    {
        this.x -= rhs.x;
        this.y -= rhs.y;
        this.z -= rhs.z;
        return this;
    }

    const float Magnitude()
    {
        import std.math.algebraic : sqrt;
        import std.math.exponential: pow;
        return sqrt(pow(x, 2) + pow(y, 2) + pow(z, 2));
    }

}

class Component
{
    bool active = true;
    bool owned = false;
}

class DrawableComponent : Component
{

}

class Circle : DrawableComponent
{

}

class Particle : Component
{
    float fMass = 1.0;
    Vector vPosition;
    Vector vVelocity;
    float fSpeed = 0.0;
    private Vector vForces;
    Vector[] forces;
    float fRadius = 5;
    bool gravity;

    void AddForce(Vector force)
    {
        this.forces ~= force;
    }
}

class System
{

}

class ParticleSystem : System
{
    // Aggregates forces acting on the particle
    void CalcLoads(ref Particle particle)
    {
        // Reset forces
        particle.vForces.x = 0;
        particle.vForces.y = 0;

        // Aggregate forces
        foreach (force; particle.forces)
        {
            particle.vForces += force;
        }
        particle.forces = [];

        // Apply gravity force
        if (particle.gravity)
            particle.vForces.y -= particle.fMass * GRAVITYACCELERATION * PHYSICS_SCALE;
    }

    // Integrates one time step
    void UpdateBodyEuler(double dt, ref Particle particle)
    {
        Vector a;
        Vector dv;
        Vector ds;

        // Integrate equation of motion
        a = particle.vForces / particle.fMass;

        dv = a * dt;
        particle.vVelocity += dv;

        ds = particle.vVelocity * dt;
        particle.vPosition += ds;

        // Misc. calculations
        particle.fSpeed = particle.vVelocity.Magnitude();
    }

    // Draws the particle
    void Draw(ref Particle particle)
    {
        DrawCircle(cast(int) particle.vPosition.x, cast(int) particle.vPosition.y, particle.fRadius, Colors.BROWN);
    }

}

class RenderSystem
{

}

class ComponentArray(T)
{
    private T[] components;

    void Add(T)(T component) @safe
    {
        components ~= component;
    }

    T Get(uint index) @safe
    {
        return components[index];
    }

    ~this() @safe
    {
        this.components = null;
    }
}

class ComponentManager
{
    private Component[][string] componentArray;

    void Add(T)(T component)
    {
        string className = T.mangleof;
        componentArray[className] ~= component;
    }

    T[] Get(T)()
    {
        string className = T.mangleof;
        if (className in componentArray)
            return cast(T[]) componentArray[className];
        else
            return null;
    }

    T Get(T)(uint id) @safe
    {
        string className = T.mangleof;
        if (className in componentArray)
            return componentArray[className][id];
        else
            return null;
    }

    ~this()
    {
        this.componentArray = null;
    }
}



class EntityManager
{
    Entity[] entities;
    private ComponentManager componentManager;

    this(ComponentManager componentManager)
    {
        componentManager = componentManager;
    }

    void Add(Entity entity) @safe
    {
        entities ~= entity;
    }

    private void RegisterComponent(T)(T component)
    {
        writeln(componentManager);
        componentManager.Add!T(component);
    }

    ~this()
    {
        this.entities = null;
    }
}

class Entity
{
    uint id;
    bool active = true;
    Component[][string] components;
    private EntityManager entityManager;

    this(EntityManager entityManager)
    {
        entityManager = entityManager;
    }

    void AddComponent(T)(T component)
    {
        if (component.owned)
            return;
        string className = T.mangleof;
        components[className] ~= component;
        component.owned = true;
    }

    Component[] GetComponents(T)() @safe
    {
        string className = T.mangleof;
        if (className in this.components)
            return this.components[className];
        else
            return null;
    }

    ~this()
    {
        this.components = null;
    }
}

void processPhysics() @safe
{

}

class SystemManager
{
    private System[] systems;

    void Add(T)(T system)
    {
        systems ~= system;
    }

    void Run() @safe
    {
        /* foreach (system; systems)
        {
            system.run();
        } */
    }

    ~this()
    {
        this.systems = null;
    }
}


void main()
{
    Particle[] particles;
    auto particleSystem = new ParticleSystem();

    auto sm = new SystemManager();
    auto cm = new ComponentManager();
    auto em = new EntityManager(cm);

    void load()
    {

        //auto e = new Entity();
        //auto e2 = new Entity(em);
        //auto particle_test = new Particle();
        //e.AddComponent(particle_test);
        //em.Add(e);
        //cm.Add!Particle(particle_test);
        writeln("teste");
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
    load();

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
            BeginDrawing();
            ClearBackground(Colors.RAYWHITE);

            // --- Draw Phase ---
            auto rnd = Random(43);

            foreach (ref p; cm.Get!Particle())
            {
                auto i = uniform(-100, 100, rnd);
                p.AddForce(Vector(40, 0, 0));
                p.AddForce(Vector(i, i, 0));
                particleSystem.CalcLoads(p);
                particleSystem.UpdateBodyEuler(GetFrameTime(), p);
                particleSystem.Draw(p);
            }

            DrawFPS(20, 20);
            DrawText("Hello, World!", 400, 300, 14, Colors.BLACK);

            EndDrawing();
        }
    }

    gameLoop();
}
