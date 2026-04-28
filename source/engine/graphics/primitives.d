/// Built-in primitive mesh data — vertex and index arrays for common 3D shapes.
/// Pure data module: no GPU calls, no dependencies beyond types.
module engine.graphics.primitives;

import engine.graphics.types : Vert;

@safe:

// ---------------------------------------------------------------------------
// Cube — 24 vertices, 36 indices (6 faces, 4 verts each, unique normals)
// ---------------------------------------------------------------------------
immutable Vert[24] cubeVertices = [
    // Front (+Z)
    Vert([-0.5,-0.5, 0.5], [ 0, 0, 1]), Vert([ 0.5,-0.5, 0.5], [ 0, 0, 1]),
    Vert([ 0.5, 0.5, 0.5], [ 0, 0, 1]), Vert([-0.5, 0.5, 0.5], [ 0, 0, 1]),
    // Back (-Z)
    Vert([ 0.5,-0.5,-0.5], [ 0, 0,-1]), Vert([-0.5,-0.5,-0.5], [ 0, 0,-1]),
    Vert([-0.5, 0.5,-0.5], [ 0, 0,-1]), Vert([ 0.5, 0.5,-0.5], [ 0, 0,-1]),
    // Right (+X)
    Vert([ 0.5,-0.5, 0.5], [ 1, 0, 0]), Vert([ 0.5,-0.5,-0.5], [ 1, 0, 0]),
    Vert([ 0.5, 0.5,-0.5], [ 1, 0, 0]), Vert([ 0.5, 0.5, 0.5], [ 1, 0, 0]),
    // Left (-X)
    Vert([-0.5,-0.5,-0.5], [-1, 0, 0]), Vert([-0.5,-0.5, 0.5], [-1, 0, 0]),
    Vert([-0.5, 0.5, 0.5], [-1, 0, 0]), Vert([-0.5, 0.5,-0.5], [-1, 0, 0]),
    // Top (+Y)
    Vert([-0.5, 0.5, 0.5], [ 0, 1, 0]), Vert([ 0.5, 0.5, 0.5], [ 0, 1, 0]),
    Vert([ 0.5, 0.5,-0.5], [ 0, 1, 0]), Vert([-0.5, 0.5,-0.5], [ 0, 1, 0]),
    // Bottom (-Y)
    Vert([-0.5,-0.5,-0.5], [ 0,-1, 0]), Vert([ 0.5,-0.5,-0.5], [ 0,-1, 0]),
    Vert([ 0.5,-0.5, 0.5], [ 0,-1, 0]), Vert([-0.5,-0.5, 0.5], [ 0,-1, 0]),
];

immutable ushort[36] cubeIndices = [
     0, 1, 2,  2, 3, 0,
     4, 5, 6,  6, 7, 4,
     8, 9,10, 10,11, 8,
    12,13,14, 14,15,12,
    16,17,18, 18,19,16,
    20,21,22, 22,23,20,
];

// ---------------------------------------------------------------------------
// Pyramid — 16 vertices, 18 indices (4 triangular faces + square base)
// Apex at y=+0.8, base at y=0, base radius ~0.5
// ---------------------------------------------------------------------------
immutable Vert[16] pyramidVertices = [
    // Front face — normal ≈ (0, 0.53, 0.848)
    Vert([-0.5, 0,  0.5], [ 0, 0.53, 0.848]),
    Vert([ 0.5, 0,  0.5], [ 0, 0.53, 0.848]),
    Vert([ 0, 0.8,    0], [ 0, 0.53, 0.848]),
    // Right face — normal ≈ (0.848, 0.53, 0)
    Vert([ 0.5, 0,  0.5], [ 0.848, 0.53, 0]),
    Vert([ 0.5, 0, -0.5], [ 0.848, 0.53, 0]),
    Vert([ 0, 0.8,    0], [ 0.848, 0.53, 0]),
    // Back face — normal ≈ (0, 0.53, -0.848)
    Vert([ 0.5, 0, -0.5], [ 0, 0.53,-0.848]),
    Vert([-0.5, 0, -0.5], [ 0, 0.53,-0.848]),
    Vert([ 0, 0.8,    0], [ 0, 0.53,-0.848]),
    // Left face — normal ≈ (-0.848, 0.53, 0)
    Vert([-0.5, 0, -0.5], [-0.848, 0.53, 0]),
    Vert([-0.5, 0,  0.5], [-0.848, 0.53, 0]),
    Vert([ 0, 0.8,    0], [-0.848, 0.53, 0]),
    // Base (two triangles, normal down)
    Vert([-0.5, 0, -0.5], [ 0,-1, 0]),
    Vert([ 0.5, 0, -0.5], [ 0,-1, 0]),
    Vert([ 0.5, 0,  0.5], [ 0,-1, 0]),
    Vert([-0.5, 0,  0.5], [ 0,-1, 0]),
];

immutable ushort[18] pyramidIndices = [
    0,  1,  2,   // front
    3,  4,  5,   // right
    6,  7,  8,   // back
    9, 10, 11,   // left
   12, 13, 14,   // base tri 1
   14, 15, 12,   // base tri 2
];

// ---------------------------------------------------------------------------
// Diamond (octahedron) — 24 vertices, 24 indices (8 triangular faces)
// Top at y=+0.7, bottom at y=-0.7, equator at y=0 with radius 0.4
// ---------------------------------------------------------------------------
immutable Vert[24] diamondVertices = () {
    enum float R = 0.4;
    enum float H = 0.7;
    enum float[3] e0 = [ R, 0,  0];
    enum float[3] e1 = [ 0, 0,  R];
    enum float[3] e2 = [-R, 0,  0];
    enum float[3] e3 = [ 0, 0, -R];
    enum float[3] top = [0,  H, 0];
    enum float[3] bot = [0, -H, 0];

    enum float[3] n0 = [ 0.655, 0.375, 0.655];
    enum float[3] n1 = [-0.655, 0.375, 0.655];
    enum float[3] n2 = [-0.655, 0.375,-0.655];
    enum float[3] n3 = [ 0.655, 0.375,-0.655];
    enum float[3] n4 = [ 0.655,-0.375, 0.655];
    enum float[3] n5 = [-0.655,-0.375, 0.655];
    enum float[3] n6 = [-0.655,-0.375,-0.655];
    enum float[3] n7 = [ 0.655,-0.375,-0.655];

    return [
        // Top 4 faces
        Vert(top, n0), Vert(e1, n0), Vert(e0, n0),
        Vert(top, n1), Vert(e2, n1), Vert(e1, n1),
        Vert(top, n2), Vert(e3, n2), Vert(e2, n2),
        Vert(top, n3), Vert(e0, n3), Vert(e3, n3),
        // Bottom 4 faces
        Vert(bot, n4), Vert(e0, n4), Vert(e1, n4),
        Vert(bot, n5), Vert(e1, n5), Vert(e2, n5),
        Vert(bot, n6), Vert(e2, n6), Vert(e3, n6),
        Vert(bot, n7), Vert(e3, n7), Vert(e0, n7),
    ];
}();

immutable ushort[24] diamondIndices = [
     0, 1, 2,   3, 4, 5,   6, 7, 8,   9,10,11,
    12,13,14,  15,16,17,  18,19,20,  21,22,23,
];

// ---------------------------------------------------------------------------
// Sphere — Generated at compile-time (16 rings, 32 segments)
// ---------------------------------------------------------------------------
private struct CTFESphereData {
    Vert[] vertices;
    ushort[] indices;
}

private CTFESphereData generateSphere(int rings = 16, int segments = 32) {
    import std.math : sin, cos, PI;
    Vert[] verts;
    ushort[] inds;
    verts.reserve((rings+1)*(segments+1));
    inds.reserve(rings*segments*6);
    
    foreach(i; 0..rings+1) {
        float phi = PI * cast(float)i / cast(float)rings;
        float sinPhi = sin(phi);
        float cosPhi = cos(phi);
        foreach(j; 0..segments+1) {
            float theta = 2.0f * PI * cast(float)j / cast(float)segments;
            float sinTheta = sin(theta);
            float cosTheta = cos(theta);
            
            float x = cosTheta * sinPhi;
            float y = cosPhi;
            float z = sinTheta * sinPhi;
            
            // Radius 0.5 to match the cube bounds (diameter 1.0)
            verts ~= Vert([x * 0.5f, y * 0.5f, z * 0.5f], [x, y, z]);
        }
    }
    
    foreach(i; 0..rings) {
        foreach(j; 0..segments) {
            ushort first = cast(ushort)(i * (segments + 1) + j);
            ushort second = cast(ushort)(first + segments + 1);
            
            inds ~= first;
            inds ~= second;
            inds ~= cast(ushort)(first + 1);
            
            inds ~= second;
            inds ~= cast(ushort)(second + 1);
            inds ~= cast(ushort)(first + 1);
        }
    }
    
    return CTFESphereData(verts, inds);
}

private enum CTFESphereData sphereData = generateSphere();
immutable Vert[] sphereVertices = sphereData.vertices;
immutable ushort[] sphereIndices = sphereData.indices;
