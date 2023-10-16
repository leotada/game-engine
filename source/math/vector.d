module math.vector;

import std.math.algebraic : sqrt;
import std.math.exponential: pow;


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

    float magnitude() const
    {
        return sqrt(pow(x, 2) + pow(y, 2) + pow(z, 2));
    }

}
