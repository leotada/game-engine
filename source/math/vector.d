module math.vector;

import std.math.algebraic : sqrt;
import std.math.exponential : pow;

struct Vector
{
    float x = 0;
    float y = 0;
    float z = 0;

    // this + Vector
    Vector opBinary(string op : "+")(Vector rhs) const
    {
        Vector vec;
        vec.x = this.x + rhs.x;
        vec.y = this.y + rhs.y;
        vec.z = this.z + rhs.z;
        return vec;
    }

    // this - Vector
    Vector opBinary(string op : "-")(Vector rhs) const
    {
        Vector vec;
        vec.x = this.x - rhs.x;
        vec.y = this.y - rhs.y;
        vec.z = this.z - rhs.z;
        return vec;
    }

    // this * rhs
    Vector opBinary(string op : "*", T)(T rhs) const
    {
        Vector vec;
        vec.x = this.x * rhs;
        vec.y = this.y * rhs;
        vec.z = this.z * rhs;
        return vec;
    }

    // this / rhs
    Vector opBinary(string op : "/", T)(T rhs) const
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

    float magnitude() const
    {
        return sqrt(pow(x, 2) + pow(y, 2) + pow(z, 2));
    }

    // Squared magnitude (faster when you just need to compare distances)
    float magnitudeSquared() const
    {
        return pow(x, 2) + pow(y, 2) + pow(z, 2);
    }

    // Returns unit vector (same direction, magnitude = 1)
    Vector normalize() const
    {
        float mag = magnitude();
        if (mag == 0)
            return Vector(0, 0, 0);
        return Vector(x / mag, y / mag, z / mag);
    }

    // Dot product
    float dot(Vector other) const
    {
        return x * other.x + y * other.y + z * other.z;
    }

    // Cross product (3D only)
    Vector cross(Vector other) const
    {
        return Vector(
            y * other.z - z * other.y,
            z * other.x - x * other.z,
            x * other.y - y * other.x
        );
    }

    // Distance to another vector
    float distanceTo(Vector other) const
    {
        return (this - other).magnitude();
    }
}

unittest
{
    // Test magnitude
    auto v1 = Vector(3, 4, 0);
    assert(v1.magnitude() == 5);

    // Test normalize
    auto v2 = Vector(10, 0, 0);
    auto norm = v2.normalize();
    assert(norm.x == 1 && norm.y == 0 && norm.z == 0);

    // Test dot product
    auto v3 = Vector(1, 0, 0);
    auto v4 = Vector(0, 1, 0);
    assert(v3.dot(v4) == 0); // Perpendicular vectors

    // Test cross product
    auto cross = v3.cross(v4);
    assert(cross.z == 1); // i x j = k

    // Test distanceTo
    auto v5 = Vector(0, 0, 0);
    auto v6 = Vector(3, 4, 0);
    assert(v5.distanceTo(v6) == 5);
}
