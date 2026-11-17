/// Procedural CPU 3D primitive mesh builders and mesh merging utilities.
/// Produces `MeshData` (`TexVert[]` + `uint[]`) ready for CPU noise/deformation
/// and upload via `TexMesh.fromData`.
module engine.graphics.shapes;

import std.math : atan2, cos, sin, sqrt, PI;

import engine.gpu.context : GpuContext;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.types : TexVert;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;

@safe:

/// CPU-side indexed mesh buffer with transform & merge operations.
struct MeshData {
    TexVert[] vertices;
    uint[] indices;

    /// Upload to GPU as a `TexMesh` (automatically narrows indices to u16 when <= 65535).
    TexMesh toTexMesh(ref GpuContext gpu) const {
        return TexMesh.fromData(gpu, vertices, indices);
    }

    /// Transform all vertices and normals in place.
    /// Normals use the cofactor (inverse-transpose) of the upper 3x3 so
    /// non-uniform scaling stays accurate; negative determinants flip winding.
    void transform(Mat4 m) pure nothrow {
        if (vertices.length == 0) return;

        // Upper-left 3x3 columns: c0=(m[0],m[1],m[2]), c1=(m[4],m[5],m[6]), c2=(m[8],m[9],m[10]).
        immutable float a00 = m.m[0], a01 = m.m[4], a02 = m.m[8];
        immutable float a10 = m.m[1], a11 = m.m[5], a12 = m.m[9];
        immutable float a20 = m.m[2], a21 = m.m[6], a22 = m.m[10];

        // Cofactor matrix (adjugate transpose = det * inv^T).
        immutable float n00 = a11 * a22 - a12 * a21;
        immutable float n01 = a12 * a20 - a10 * a22;
        immutable float n02 = a10 * a21 - a11 * a20;
        immutable float n10 = a02 * a21 - a01 * a22;
        immutable float n11 = a00 * a22 - a02 * a20;
        immutable float n12 = a01 * a20 - a00 * a21;
        immutable float n20 = a01 * a12 - a02 * a11;
        immutable float n21 = a02 * a10 - a00 * a12;
        immutable float n22 = a00 * a11 - a01 * a10;

        immutable float det = a00 * n00 + a01 * n01 + a02 * n02;
        immutable float sign = det < 0.0f ? -1.0f : 1.0f;

        foreach (ref v; vertices) {
            immutable px = v.pos[0], py = v.pos[1], pz = v.pos[2];
            v.pos[0] = a00 * px + a01 * py + a02 * pz + m.m[12];
            v.pos[1] = a10 * px + a11 * py + a12 * pz + m.m[13];
            v.pos[2] = a20 * px + a21 * py + a22 * pz + m.m[14];

            immutable nx = v.normal[0], ny = v.normal[1], nz = v.normal[2];
            auto nn = Vec3(
                (n00 * nx + n01 * ny + n02 * nz) * sign,
                (n10 * nx + n11 * ny + n12 * nz) * sign,
                (n20 * nx + n21 * ny + n22 * nz) * sign,
            ).normalized();
            v.normal = [nn.x, nn.y, nn.z];
        }

        if (det < 0.0f) {
            for (size_t i = 0; i + 2 < indices.length; i += 3) {
                immutable tmp = indices[i + 1];
                indices[i + 1] = indices[i + 2];
                indices[i + 2] = tmp;
            }
        }
    }

    /// Append `other` transformed by `xform` into this mesh.
    void merge(in MeshData other, Mat4 xform = Mat4.identity()) pure {
        if (other.vertices.length == 0 || other.indices.length == 0) return;
        MeshData copy;
        copy.vertices = other.vertices.dup;
        copy.indices = other.indices.dup;
        copy.transform(xform);

        immutable uint base = cast(uint) vertices.length;
        vertices ~= copy.vertices;
        indices.reserve(indices.length + copy.indices.length);
        foreach (idx; copy.indices) {
            indices ~= base + idx;
        }
    }
}

/// Axis-aligned box centered at the origin with dimensions `(width, height, depth)`.
MeshData box(float width = 1.0f, float height = 1.0f, float depth = 1.0f) pure {
    import engine.graphics.texmesh : texCubeIndices, texCubeVertices;
    MeshData d;
    d.vertices = new TexVert[texCubeVertices.length];
    foreach (i, v; texCubeVertices) {
        d.vertices[i] = TexVert(
            [v.pos[0] * width, v.pos[1] * height, v.pos[2] * depth],
            v.normal,
            v.uv);
    }
    d.indices = new uint[texCubeIndices.length];
    foreach (i, idx; texCubeIndices) {
        d.indices[i] = idx;
    }
    return d;
}

/// Unit XZ quad centered at the origin with normal +Y.
MeshData quad(float width = 1.0f, float depth = 1.0f) pure {
    import engine.graphics.texmesh : texQuadIndices, texQuadVertices;
    MeshData d;
    d.vertices = new TexVert[texQuadVertices.length];
    foreach (i, v; texQuadVertices) {
        d.vertices[i] = TexVert(
            [v.pos[0] * width, v.pos[1], v.pos[2] * depth],
            v.normal,
            v.uv);
    }
    d.indices = new uint[texQuadIndices.length];
    foreach (i, idx; texQuadIndices) {
        d.indices[i] = idx;
    }
    return d;
}

/// UV sphere centered at the origin.
MeshData uvSphere(float radius = 0.5f, uint segments = 32, uint rings = 16) pure {
    assert(segments >= 3 && rings >= 2);
    MeshData d;
    d.vertices = new TexVert[(rings + 1) * (segments + 1)];
    d.indices = new uint[rings * segments * 6];

    size_t vi = 0;
    foreach (y; 0 .. rings + 1) {
        immutable v = cast(float) y / cast(float) rings;
        immutable phi = v * PI;
        immutable sy = cast(float) cos(phi);
        immutable sr = cast(float) sin(phi);
        foreach (x; 0 .. segments + 1) {
            immutable u = cast(float) x / cast(float) segments;
            immutable theta = u * 2.0f * PI;
            immutable nx = sr * cast(float) cos(theta);
            immutable nz = sr * cast(float) sin(theta);
            d.vertices[vi++] = TexVert(
                [nx * radius, sy * radius, nz * radius],
                [nx, sy, nz],
                [u, 1.0f - v]);
        }
    }

    size_t ii = 0;
    foreach (y; 0 .. rings) {
        foreach (x; 0 .. segments) {
            immutable uint a = y * (segments + 1) + x;
            immutable uint b = a + segments + 1;
            d.indices[ii++] = a;
            d.indices[ii++] = a + 1;
            d.indices[ii++] = b;
            d.indices[ii++] = a + 1;
            d.indices[ii++] = b + 1;
            d.indices[ii++] = b;
        }
    }
    return d;
}

/// Geodesic icosphere centered at the origin (avoids polar pinching).
MeshData icosphere(float radius = 0.5f, uint subdivisions = 2) pure {
    immutable float t = (1.0f + sqrt(5.0f)) * 0.5f;
    Vec3[] positions = [
        Vec3(-1,  t,  0).normalized(), Vec3( 1,  t,  0).normalized(),
        Vec3(-1, -t,  0).normalized(), Vec3( 1, -t,  0).normalized(),
        Vec3( 0, -1,  t).normalized(), Vec3( 0,  1,  t).normalized(),
        Vec3( 0, -1, -t).normalized(), Vec3( 0,  1, -t).normalized(),
        Vec3( t,  0, -1).normalized(), Vec3( t,  0,  1).normalized(),
        Vec3(-t,  0, -1).normalized(), Vec3(-t,  0,  1).normalized(),
    ];
    uint[] tris = [
        0, 11, 5,   0, 5, 1,    0, 1, 7,    0, 7, 10,   0, 10, 11,
        1, 5, 9,    5, 11, 4,   11, 10, 2,  10, 7, 6,   7, 1, 8,
        3, 9, 4,    3, 4, 2,    3, 2, 6,    3, 6, 8,    3, 8, 9,
        4, 9, 5,    2, 4, 11,   6, 2, 10,   8, 6, 7,    9, 8, 1,
    ];

    uint[ulong] midpointCache;
    uint midpoint(uint a, uint b) {
        immutable uint lo = a < b ? a : b;
        immutable uint hi = a < b ? b : a;
        immutable ulong key = (cast(ulong) lo << 32) | hi;
        if (auto p = key in midpointCache) return *p;
        immutable Vec3 mid = (positions[a] + positions[b]).normalized();
        immutable uint idx = cast(uint) positions.length;
        positions ~= mid;
        midpointCache[key] = idx;
        return idx;
    }

    foreach (_; 0 .. subdivisions) {
        midpointCache.clear();
        uint[] nextTris;
        nextTris.reserve(tris.length * 4);
        for (size_t i = 0; i < tris.length; i += 3) {
            immutable a = tris[i], b = tris[i + 1], c = tris[i + 2];
            immutable ab = midpoint(a, b);
            immutable bc = midpoint(b, c);
            immutable ca = midpoint(c, a);
            nextTris ~= [a, ab, ca,  b, bc, ab,  c, ca, bc,  ab, bc, ca];
        }
        tris = nextTris;
    }

    MeshData d;
    d.vertices = new TexVert[positions.length];
    foreach (i, p; positions) {
        immutable u = 0.5f + atan2(p.z, p.x) / (2.0f * PI);
        immutable v = 0.5f - (p.y < -1.0f ? -1.0f : (p.y > 1.0f ? 1.0f : p.y)) * 0.5f;
        d.vertices[i] = TexVert(
            [p.x * radius, p.y * radius, p.z * radius],
            [p.x, p.y, p.z],
            [u, v]);
    }
    d.indices = tris;
    return d;
}

/// Tapered cylinder / frustum / cone along Y centered at the origin.
/// `radiusTop == 0` yields a cone pointing +Y; `radiusTop != radiusBottom` yields a frustum.
MeshData cylinder(float radiusTop = 0.5f, float radiusBottom = 0.5f,
                  float height = 1.0f, uint segments = 24, bool capped = true) pure {
    assert(segments >= 3);
    MeshData d;
    immutable float halfH = height * 0.5f;
    immutable float dr = radiusBottom - radiusTop;
    immutable float slopeLen = sqrt(height * height + dr * dr);
    immutable float ny = slopeLen > 1e-6f ? (dr / slopeLen) : 0.0f;
    immutable float nrScale = slopeLen > 1e-6f ? (height / slopeLen) : 1.0f;

    // Side ring vertices: top (y = +halfH) and bottom (y = -halfH).
    immutable uint sideBase = 0;
    foreach (s; 0 .. segments + 1) {
        immutable float u = cast(float) s / cast(float) segments;
        immutable float theta = u * 2.0f * PI;
        immutable float cx = cast(float) cos(theta);
        immutable float sz = cast(float) sin(theta);
        // Flip theta sign so +X -> -Z -> -X -> +Z puts CCW outward winding cleanly.
        immutable float x = cx;
        immutable float z = -sz;
        immutable auto n = Vec3(x * nrScale, ny, z * nrScale).normalized();
        d.vertices ~= TexVert([x * radiusTop,     halfH, z * radiusTop],     [n.x, n.y, n.z], [u, 0.0f]);
        d.vertices ~= TexVert([x * radiusBottom, -halfH, z * radiusBottom],  [n.x, n.y, n.z], [u, 1.0f]);
    }

    foreach (s; 0 .. segments) {
        immutable uint t0 = sideBase + s * 2;
        immutable uint b0 = t0 + 1;
        immutable uint t1 = t0 + 2;
        immutable uint b1 = t0 + 3;
        if (radiusTop > 0.0f) {
            d.indices ~= [t0, b0, b1];
        }
        if (radiusBottom > 0.0f) {
            d.indices ~= [t0, b1, t1];
        }
    }

    if (capped) {
        if (radiusTop > 0.0f) {
            immutable uint center = cast(uint) d.vertices.length;
            d.vertices ~= TexVert([0.0f, halfH, 0.0f], [0.0f, 1.0f, 0.0f], [0.5f, 0.5f]);
            immutable uint ringStart = cast(uint) d.vertices.length;
            foreach (s; 0 .. segments + 1) {
                immutable float theta = (cast(float) s / cast(float) segments) * 2.0f * PI;
                immutable float x = cast(float) cos(theta);
                immutable float z = -cast(float) sin(theta);
                d.vertices ~= TexVert([x * radiusTop, halfH, z * radiusTop],
                                      [0.0f, 1.0f, 0.0f], [0.5f + x * 0.5f, 0.5f + z * 0.5f]);
            }
            foreach (s; 0 .. segments) {
                d.indices ~= [center, ringStart + s, ringStart + s + 1];
            }
        }
        if (radiusBottom > 0.0f) {
            immutable uint center = cast(uint) d.vertices.length;
            d.vertices ~= TexVert([0.0f, -halfH, 0.0f], [0.0f, -1.0f, 0.0f], [0.5f, 0.5f]);
            immutable uint ringStart = cast(uint) d.vertices.length;
            foreach (s; 0 .. segments + 1) {
                immutable float theta = (cast(float) s / cast(float) segments) * 2.0f * PI;
                immutable float x = cast(float) cos(theta);
                immutable float z = -cast(float) sin(theta);
                d.vertices ~= TexVert([x * radiusBottom, -halfH, z * radiusBottom],
                                      [0.0f, -1.0f, 0.0f], [0.5f + x * 0.5f, 0.5f + z * 0.5f]);
            }
            foreach (s; 0 .. segments) {
                d.indices ~= [center, ringStart + s + 1, ringStart + s];
            }
        }
    }
    return d;
}

/// Cone along Y centered at the origin, apex at +height/2.
MeshData cone(float radius = 0.5f, float height = 1.0f, uint segments = 24, bool capped = true) pure {
    return cylinder(0.0f, radius, height, segments, capped);
}

/// Frustum (truncated cone) along Y centered at the origin.
MeshData frustum(float radiusTop, float radiusBottom, float height = 1.0f,
                 uint segments = 24, bool capped = true) pure {
    return cylinder(radiusTop, radiusBottom, height, segments, capped);
}

/// Capsule along Y centered at the origin (`cylinderHeight` is the straight middle section;
/// total height is `cylinderHeight + 2 * radius`).
MeshData capsule(float radius = 0.5f, float cylinderHeight = 1.0f,
                 uint segments = 24, uint rings = 8) pure {
    assert(segments >= 3 && rings >= 2);
    MeshData d;
    immutable float halfCyl = cylinderHeight * 0.5f;
    immutable uint totalRings = rings * 2 + 1; // top hemisphere (rings+1) + bottom hemisphere (rings+1) sharing seam ring pair

    // Top hemisphere (phi: 0 .. PI/2), offset +halfCyl
    foreach (r; 0 .. rings + 1) {
        immutable float frac = cast(float) r / cast(float) rings;
        immutable float phi = frac * (PI * 0.5f);
        immutable float sy = cast(float) cos(phi);
        immutable float sr = cast(float) sin(phi);
        immutable float v = 1.0f - (0.5f * frac * 0.5f);
        foreach (s; 0 .. segments + 1) {
            immutable float u = cast(float) s / cast(float) segments;
            immutable float theta = u * 2.0f * PI;
            immutable float nx = sr * cast(float) cos(theta);
            immutable float nz = sr * cast(float) sin(theta);
            d.vertices ~= TexVert(
                [nx * radius, sy * radius + halfCyl, nz * radius],
                [nx, sy, nz],
                [u, v]);
        }
    }

    // Bottom hemisphere (phi: PI/2 .. PI), offset -halfCyl
    foreach (r; 0 .. rings + 1) {
        immutable float frac = cast(float) r / cast(float) rings;
        immutable float phi = (PI * 0.5f) + frac * (PI * 0.5f);
        immutable float sy = cast(float) cos(phi);
        immutable float sr = cast(float) sin(phi);
        immutable float v = 0.5f - (0.5f * frac * 0.5f);
        foreach (s; 0 .. segments + 1) {
            immutable float u = cast(float) s / cast(float) segments;
            immutable float theta = u * 2.0f * PI;
            immutable float nx = sr * cast(float) cos(theta);
            immutable float nz = sr * cast(float) sin(theta);
            d.vertices ~= TexVert(
                [nx * radius, sy * radius - halfCyl, nz * radius],
                [nx, sy, nz],
                [u, v]);
        }
    }

    immutable uint rowCount = totalRings;
    foreach (y; 0 .. rowCount) {
        foreach (x; 0 .. segments) {
            immutable uint a = y * (segments + 1) + x;
            immutable uint b = a + segments + 1;
            d.indices ~= [a, a + 1, b,  a + 1, b + 1, b];
        }
    }
    return d;
}

/// Flat-shaded N-sided regular prism along Y centered at the origin.
MeshData prism(uint sides = 6, float radius = 0.5f, float height = 1.0f) pure {
    assert(sides >= 3);
    MeshData d;
    immutable float halfH = height * 0.5f;

    foreach (i; 0 .. sides) {
        immutable float a0 = (cast(float) i / cast(float) sides) * 2.0f * PI;
        immutable float a1 = (cast(float)(i + 1) / cast(float) sides) * 2.0f * PI;
        immutable float x0 = cast(float) cos(a0) * radius;
        immutable float z0 = -cast(float) sin(a0) * radius;
        immutable float x1 = cast(float) cos(a1) * radius;
        immutable float z1 = -cast(float) sin(a1) * radius;

        immutable Vec3 p0 = Vec3(x0,  halfH, z0);
        immutable Vec3 p1 = Vec3(x0, -halfH, z0);
        immutable Vec3 p2 = Vec3(x1, -halfH, z1);
        immutable Vec3 p3 = Vec3(x1,  halfH, z1);
        immutable Vec3 n = (p1 - p0).cross(p2 - p0).normalized();

        immutable uint base = cast(uint) d.vertices.length;
        d.vertices ~= TexVert([p0.x, p0.y, p0.z], [n.x, n.y, n.z], [0, 0]);
        d.vertices ~= TexVert([p1.x, p1.y, p1.z], [n.x, n.y, n.z], [0, 1]);
        d.vertices ~= TexVert([p2.x, p2.y, p2.z], [n.x, n.y, n.z], [1, 1]);
        d.vertices ~= TexVert([p3.x, p3.y, p3.z], [n.x, n.y, n.z], [1, 0]);
        d.indices ~= [base, base + 1, base + 2,  base, base + 2, base + 3];
    }

    // Top cap (+Y)
    immutable uint topCenter = cast(uint) d.vertices.length;
    d.vertices ~= TexVert([0, halfH, 0], [0, 1, 0], [0.5f, 0.5f]);
    foreach (i; 0 .. sides) {
        immutable float a = (cast(float) i / cast(float) sides) * 2.0f * PI;
        immutable float cx = cast(float) cos(a);
        immutable float cz = -cast(float) sin(a);
        d.vertices ~= TexVert([cx * radius, halfH, cz * radius], [0, 1, 0], [0.5f + cx * 0.5f, 0.5f + cz * 0.5f]);
    }
    foreach (i; 0 .. sides) {
        immutable uint next = (i + 1) % sides;
        d.indices ~= [topCenter, topCenter + 1 + i, topCenter + 1 + next];
    }

    // Bottom cap (-Y)
    immutable uint botCenter = cast(uint) d.vertices.length;
    d.vertices ~= TexVert([0, -halfH, 0], [0, -1, 0], [0.5f, 0.5f]);
    foreach (i; 0 .. sides) {
        immutable float a = (cast(float) i / cast(float) sides) * 2.0f * PI;
        immutable float cx = cast(float) cos(a);
        immutable float cz = -cast(float) sin(a);
        d.vertices ~= TexVert([cx * radius, -halfH, cz * radius], [0, -1, 0], [0.5f + cx * 0.5f, 0.5f + cz * 0.5f]);
    }
    foreach (i; 0 .. sides) {
        immutable uint next = (i + 1) % sides;
        d.indices ~= [botCenter, botCenter + 1 + next, botCenter + 1 + i];
    }
    return d;
}

/// Torus centered at the origin lying in the XZ plane (hole along Y).
MeshData torus(float majorRadius = 0.5f, float minorRadius = 0.15f,
               uint majorSegments = 32, uint minorSegments = 16) pure {
    assert(majorSegments >= 3 && minorSegments >= 3);
    MeshData d;
    d.vertices = new TexVert[(majorSegments + 1) * (minorSegments + 1)];
    d.indices = new uint[majorSegments * minorSegments * 6];

    size_t vi = 0;
    foreach (i; 0 .. majorSegments + 1) {
        immutable float u = cast(float) i / cast(float) majorSegments;
        immutable float phi = u * 2.0f * PI;
        immutable float cp = cast(float) cos(phi);
        immutable float sp = -cast(float) sin(phi);
        foreach (j; 0 .. minorSegments + 1) {
            immutable float v = cast(float) j / cast(float) minorSegments;
            immutable float theta = v * 2.0f * PI;
            immutable float ct = cast(float) cos(theta);
            immutable float st = cast(float) sin(theta);

            immutable float nx = cp * ct;
            immutable float ny = st;
            immutable float nz = sp * ct;
            immutable float r = majorRadius + minorRadius * ct;
            d.vertices[vi++] = TexVert(
                [r * cp, minorRadius * st, r * sp],
                [nx, ny, nz],
                [u, v]);
        }
    }

    size_t ii = 0;
    foreach (i; 0 .. majorSegments) {
        foreach (j; 0 .. minorSegments) {
            immutable uint a = i * (minorSegments + 1) + j;
            immutable uint b = a + minorSegments + 1;
            d.indices[ii++] = a;
            d.indices[ii++] = b;
            d.indices[ii++] = a + 1;
            d.indices[ii++] = a + 1;
            d.indices[ii++] = b;
            d.indices[ii++] = b + 1;
        }
    }
    return d;
}

@safe unittest {
    import std.math : abs;
    import engine.math.quat : Quat;

    static void assertOutwardWinding(ref const MeshData m) {
        assert(m.vertices.length > 0 && m.indices.length > 0);
        assert(m.indices.length % 3 == 0);
        foreach (ref v; m.vertices) {
            immutable len = Vec3(v.normal[0], v.normal[1], v.normal[2]).length();
            assert(abs(len - 1.0f) < 1e-3f);
        }
        for (size_t i = 0; i < m.indices.length; i += 3) {
            immutable i0 = m.indices[i], i1 = m.indices[i + 1], i2 = m.indices[i + 2];
            assert(i0 < m.vertices.length && i1 < m.vertices.length && i2 < m.vertices.length);
            immutable p0 = Vec3(m.vertices[i0].pos[0], m.vertices[i0].pos[1], m.vertices[i0].pos[2]);
            immutable p1 = Vec3(m.vertices[i1].pos[0], m.vertices[i1].pos[1], m.vertices[i1].pos[2]);
            immutable p2 = Vec3(m.vertices[i2].pos[0], m.vertices[i2].pos[1], m.vertices[i2].pos[2]);
            immutable faceN = (p1 - p0).cross(p2 - p0);
            if (faceN.lengthSquared() < 1e-12f) continue; // polar cap degenerate
            immutable avgN = Vec3(m.vertices[i0].normal[0], m.vertices[i0].normal[1], m.vertices[i0].normal[2])
                           + Vec3(m.vertices[i1].normal[0], m.vertices[i1].normal[1], m.vertices[i1].normal[2])
                           + Vec3(m.vertices[i2].normal[0], m.vertices[i2].normal[1], m.vertices[i2].normal[2]);
            assert(faceN.dot(avgN) > 0.0f, "Inverted triangle winding detected");
        }
    }

    auto b = box(2, 3, 4);
    assertOutwardWinding(b);
    auto s = uvSphere(0.5f, 16, 8);
    assertOutwardWinding(s);
    auto ico = icosphere(0.5f, 2);
    assertOutwardWinding(ico);
    auto cyl = cylinder(0.5f, 0.5f, 2.0f, 16);
    assertOutwardWinding(cyl);
    auto cn = cone(0.5f, 1.5f, 16);
    assertOutwardWinding(cn);
    auto fr = frustum(0.25f, 0.6f, 1.2f, 16);
    assertOutwardWinding(fr);
    auto cap = capsule(0.4f, 1.0f, 16, 6);
    assertOutwardWinding(cap);
    auto pr = prism(6, 0.5f, 1.0f);
    assertOutwardWinding(pr);
    auto tor = torus(0.5f, 0.15f, 16, 8);
    assertOutwardWinding(tor);

    // Merge + non-uniform TRS keeps outward normals & winding.
    MeshData combined = box(1, 1, 1);
    immutable size_t baseVerts = combined.vertices.length;
    combined.merge(cone(0.5f, 1.0f, 12), Mat4.trs(Vec3(0, 1, 0), Quat.identity(), Vec3(1, 2, 0.5f)));
    assert(combined.vertices.length > baseVerts);
    assertOutwardWinding(combined);
}
