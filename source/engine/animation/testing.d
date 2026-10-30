/// Test helpers for `engine.animation`. Compiled only into unittest builds.
module engine.animation.testing;

version (unittest):

import std.file : read;
import std.math : abs;

enum fixtureDir = "assets/animation/test/";

/// Loads a vendored `.ozz` fixture. Tests run from the repository root.
const(ubyte)[] loadFixture(string name) @trusted {
    return cast(const(ubyte)[]) read(fixtureDir ~ name);
}

/// Absolute/relative float comparison used by numeric tests.
bool near(float a, float b, float tol = 1e-5f) @safe pure nothrow @nogc {
    return abs(a - b) <= tol * (1.0f + abs(b));
}
