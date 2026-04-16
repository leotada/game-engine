/// Shared GPU data types for 3D instanced rendering.
module engine.graphics.types;

@safe:

/// Per-vertex data: position + normal. Matches WGSL shader layout.
/// Buffer 0, stride = 24 bytes.
struct Vert {
    float[3] pos;
    float[3] normal;
}

/// Per-instance data: model matrix + RGBA color.
/// Buffer 1, stride = 80 bytes. Matches colored3dShaderSource layout.
struct InstanceData {
    float[16] model;
    float[4]  color;
}

/// RGBA color as 4 floats, for use in high-level draw calls.
struct Color4 {
    float r = 1, g = 1, b = 1, a = 1;

    float[4] toArray() const pure nothrow @nogc {
        return [r, g, b, a];
    }

    static Color4 white()  pure nothrow @nogc { return Color4(1, 1, 1, 1); }
    static Color4 red()    pure nothrow @nogc { return Color4(1, 0, 0, 1); }
    static Color4 green()  pure nothrow @nogc { return Color4(0, 1, 0, 1); }
    static Color4 blue()   pure nothrow @nogc { return Color4(0, 0, 1, 1); }
    static Color4 yellow() pure nothrow @nogc { return Color4(1, 1, 0, 1); }
}
