import raylib;

/* @safe: */

immutable float GRAVITYACCELERATION = -9.8;
immutable float PHYSICS_SCALE = 8;


struct Vector
{
    float x;
    float y;
    float z;

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


class Particle
{
public:
    float fMass;
    Vector vPosition;
    Vector vVelocity;
    float fSpeed;
    Vector vForces;
    float fRadius;
    Vector vGravity;

    this()
    {
        fMass = 1.0;
        vPosition.x = 0.0;
        vPosition.y = 0.0;
        vPosition.z = 0.0;
        vVelocity.x = 0.0;
        vVelocity.y = 0.0;
        vVelocity.z = 0.0;
        fSpeed = 0.0;
        vForces.x = 0.0;
        vForces.y = 0.0;
        vForces.z = 0.0;
        fRadius = 10;
        vGravity.x = 0;
        vGravity.y = fMass * GRAVITYACCELERATION * PHYSICS_SCALE;
        vGravity.z = 0;
    }

    // Aggregates forces acting on the particle
    void CalcLoads()
    {
        // Reset forces
        vForces.x = 0;
        vForces.y = 0;

        // Aggregate forces
        vForces -= vGravity;
    }

    // Integrates one time step
    void UpdateBodyEuler(double dt)
    {
        Vector a;
        Vector dv;
        Vector ds;

        // Integrate equation of motion
        a = vForces / fMass;

        dv = a * dt;
        vVelocity += dv;

        ds = vVelocity * dt;
        vPosition += ds;

        // Misc. calculations
        fSpeed = vVelocity.Magnitude();
    }

    // Draws the particle
    void Draw()
    {
        DrawCircle(cast(int) vPosition.x, cast(int) vPosition.y, fRadius, Colors.BROWN);
    }

}

@system:
void main()
{
    Particle[] particles;
    foreach (i; 0 .. 1_000) {
        auto particle = new Particle();
        particle.vPosition.x = GetRandomValue(30, 1000);
        particle.vPosition.y = GetRandomValue(20, 800);
        particles ~= particle;
    }

    // Init Window
    InitWindow(1000, 800, "Hello, Raylib-D!");
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

        foreach (ref e; particles) {
            e.CalcLoads();
            e.UpdateBodyEuler(GetFrameTime());
            e.Draw();
        }
    }
}
