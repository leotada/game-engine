/// Vector types — Vec2, Vec3, Vec4.
/// Designed for game math: physics, transforms, shaders.
module engine.math.vec;

import core.math : sqrt;

@safe:

struct Vec2 {
    float x = 0, y = 0;

    Vec2 opBinary(string op)(Vec2 rhs) const pure nothrow @nogc if (op == "+" || op == "-") {
        mixin("return Vec2(x " ~ op ~ " rhs.x, y " ~ op ~ " rhs.y);");
    }

    Vec2 opBinary(string op)(float s) const pure nothrow @nogc if (op == "*" || op == "/") {
        mixin("return Vec2(x " ~ op ~ " s, y " ~ op ~ " s);");
    }

    ref Vec2 opOpAssign(string op)(Vec2 rhs) pure nothrow @nogc if (op == "+" || op == "-") {
        mixin("x " ~ op ~ "= rhs.x; y " ~ op ~ "= rhs.y;");
        return this;
    }

    Vec2 opUnary(string op : "-")() const pure nothrow @nogc { return Vec2(-x, -y); }
    bool opEquals(Vec2 rhs) const pure nothrow @nogc { return x == rhs.x && y == rhs.y; }

    float dot(Vec2 b) const pure nothrow @nogc { return x * b.x + y * b.y; }
    float lengthSquared() const pure nothrow @nogc { return x * x + y * y; }
    float length() const pure nothrow @nogc { return sqrt(lengthSquared()); }

    Vec2 normalized() const pure nothrow @nogc {
        immutable len = length();
        return len > 0 ? Vec2(x / len, y / len) : Vec2(0, 0);
    }
}

struct Vec3 {
    float x = 0, y = 0, z = 0;

    Vec3 opBinary(string op)(Vec3 rhs) const pure nothrow @nogc if (op == "+" || op == "-") {
        mixin("return Vec3(x " ~ op ~ " rhs.x, y " ~ op ~ " rhs.y, z " ~ op ~ " rhs.z);");
    }

    Vec3 opBinary(string op)(float s) const pure nothrow @nogc if (op == "*" || op == "/") {
        mixin("return Vec3(x " ~ op ~ " s, y " ~ op ~ " s, z " ~ op ~ " s);");
    }

    ref Vec3 opOpAssign(string op)(Vec3 rhs) pure nothrow @nogc if (op == "+" || op == "-") {
        mixin("x " ~ op ~ "= rhs.x; y " ~ op ~ "= rhs.y; z " ~ op ~ "= rhs.z;");
        return this;
    }

    Vec3 opUnary(string op : "-")() const pure nothrow @nogc { return Vec3(-x, -y, -z); }
    bool opEquals(Vec3 rhs) const pure nothrow @nogc { return x == rhs.x && y == rhs.y && z == rhs.z; }

    float dot(Vec3 b) const pure nothrow @nogc { return x * b.x + y * b.y + z * b.z; }

    Vec3 cross(Vec3 b) const pure nothrow @nogc {
        return Vec3(
            y * b.z - z * b.y,
            z * b.x - x * b.z,
            x * b.y - y * b.x,
        );
    }

    float lengthSquared() const pure nothrow @nogc { return x * x + y * y + z * z; }
    float length() const pure nothrow @nogc { return sqrt(lengthSquared()); }

    Vec3 normalized() const pure nothrow @nogc {
        immutable len = length();
        return len > 0 ? Vec3(x / len, y / len, z / len) : Vec3(0, 0, 0);
    }

    float distanceTo(Vec3 b) const pure nothrow @nogc { return (this - b).length(); }
}

struct Vec4 {
    float x = 0, y = 0, z = 0, w = 0;

    Vec4 opBinary(string op)(Vec4 rhs) const pure nothrow @nogc if (op == "+" || op == "-") {
        mixin("return Vec4(x " ~ op ~ " rhs.x, y " ~ op ~ " rhs.y, z " ~ op ~ " rhs.z, w " ~ op ~ " rhs.w);");
    }

    Vec4 opBinary(string op)(float s) const pure nothrow @nogc if (op == "*" || op == "/") {
        mixin("return Vec4(x " ~ op ~ " s, y " ~ op ~ " s, z " ~ op ~ " s, w " ~ op ~ " s);");
    }

    Vec4 opUnary(string op : "-")() const pure nothrow @nogc { return Vec4(-x, -y, -z, -w); }
    bool opEquals(Vec4 rhs) const pure nothrow @nogc {
        return x == rhs.x && y == rhs.y && z == rhs.z && w == rhs.w;
    }

    float dot(Vec4 b) const pure nothrow @nogc { return x * b.x + y * b.y + z * b.z + w * b.w; }
    float lengthSquared() const pure nothrow @nogc { return dot(this); }
    float length() const pure nothrow @nogc { return sqrt(lengthSquared()); }

    Vec3 xyz() const pure nothrow @nogc { return Vec3(x, y, z); }
}
