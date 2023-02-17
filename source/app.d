import std.random;

import raylib;

// @safe:

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

struct Particle
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

class ParticleSystem
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


void main()
{
    Particle[] particles;
    foreach (i; 0 .. 10_000) {
        auto particle = Particle();
        particle.gravity = true;
        particle.vPosition.x = GetRandomValue(30, 1000);
        particle.vPosition.y = GetRandomValue(20, 800);
        particles ~= particle;
    }
    auto particleSystem = new ParticleSystem();

    // Init Window
    InitWindow(1000, 800, "Hello, Raylib-D!");
    SetTargetFPS(100);
    scope(exit)
        CloseWindow();

    // Game loop
    while (!WindowShouldClose())
    {
        BeginDrawing();
        ClearBackground(Colors.RAYWHITE);
        scope(exit)
            EndDrawing();

        // --- Draw Phase ---

        DrawFPS(20, 20);
        DrawText("Hello, World!", 400, 300, 14, Colors.BLACK);

        auto rnd = Random(43);

        foreach (ref p; particles) {
            auto i = uniform(-100, 100, rnd);
            p.AddForce(Vector(40, 0, 0));
            p.AddForce(Vector(i, i, 0));
            particleSystem.CalcLoads(p);
            particleSystem.UpdateBodyEuler(GetFrameTime(), p);
            particleSystem.Draw(p);
        }
    }
}
