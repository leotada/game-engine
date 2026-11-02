/// Procedural meshes for the meshopt test corpus. Not a port.
/// `pirate.obj` lives in `assets/models/meshopt/` (CC-BY-SA 3.0).
module engine.meshopt.corpus;

@safe:

struct ProcMesh {
    float[] positions;
    float[] uvs;
    uint[] indices;
}

ProcMesh makeGrid(uint nx, uint nz) {
    assert(nx >= 1 && nz >= 1);
    ProcMesh m;
    uint cols = nx + 1;
    uint rows = nz + 1;
    m.positions.length = cols * rows * 3;
    m.uvs.length = cols * rows * 2;
    foreach (z; 0 .. rows) {
        foreach (x; 0 .. cols) {
            size_t i = z * cols + x;
            m.positions[i * 3 + 0] = cast(float) x;
            m.positions[i * 3 + 1] = 0;
            m.positions[i * 3 + 2] = cast(float) z;
            m.uvs[i * 2 + 0] = cast(float) x / nx;
            m.uvs[i * 2 + 1] = cast(float) z / nz;
        }
    }
    m.indices.length = nx * nz * 6;
    size_t t = 0;
    foreach (z; 0 .. nz) {
        foreach (x; 0 .. nx) {
            uint a = z * cols + x;
            uint b = a + 1;
            uint c = a + cols;
            uint d = c + 1;
            m.indices[t .. t + 6] = [a, c, b, b, c, d];
            t += 6;
        }
    }
    return m;
}

ProcMesh makeSphere(uint slices, uint stacks) {
    assert(slices >= 3 && stacks >= 2);
    ProcMesh m;
    uint cols = slices + 1;
    uint rows = stacks + 1;
    m.positions.length = cols * rows * 3;
    m.uvs.length = cols * rows * 2;
    foreach (iy; 0 .. rows) {
        float v = cast(float) iy / stacks;
        float phi = v * 3.14159265f;
        foreach (ix; 0 .. cols) {
            float u = cast(float) ix / slices;
            float theta = u * 6.2831853f;
            size_t i = iy * cols + ix;
            float sp = sinF(phi);
            m.positions[i * 3 + 0] = sp * cosF(theta);
            m.positions[i * 3 + 1] = cosF(phi);
            m.positions[i * 3 + 2] = sp * sinF(theta);
            m.uvs[i * 2 + 0] = u;
            m.uvs[i * 2 + 1] = v;
        }
    }
    m.indices.length = slices * stacks * 6;
    size_t t = 0;
    foreach (iy; 0 .. stacks) {
        foreach (ix; 0 .. slices) {
            uint a = iy * cols + ix;
            uint b = a + 1;
            uint c = a + cols;
            uint d = c + 1;
            m.indices[t .. t + 6] = [a, c, b, b, c, d];
            t += 6;
        }
    }
    return m;
}

ProcMesh makeTorus(uint majorSeg, uint minorSeg, float ring, float tube) {
    assert(majorSeg >= 3 && minorSeg >= 3);
    ProcMesh m;
    uint cols = majorSeg + 1;
    uint rows = minorSeg + 1;
    m.positions.length = cols * rows * 3;
    m.uvs.length = cols * rows * 2;
    foreach (iy; 0 .. rows) {
        float v = cast(float) iy / minorSeg;
        float phi = v * 6.2831853f;
        foreach (ix; 0 .. cols) {
            float u = cast(float) ix / majorSeg;
            float theta = u * 6.2831853f;
            size_t i = iy * cols + ix;
            float r = ring + tube * cosF(phi);
            m.positions[i * 3 + 0] = r * cosF(theta);
            m.positions[i * 3 + 1] = tube * sinF(phi);
            m.positions[i * 3 + 2] = r * sinF(theta);
            m.uvs[i * 2 + 0] = u;
            m.uvs[i * 2 + 1] = v;
        }
    }
    m.indices.length = majorSeg * minorSeg * 6;
    size_t t = 0;
    foreach (iy; 0 .. minorSeg) {
        foreach (ix; 0 .. majorSeg) {
            uint a = iy * cols + ix;
            uint b = a + 1;
            uint c = a + cols;
            uint d = c + 1;
            m.indices[t .. t + 6] = [a, c, b, b, c, d];
            t += 6;
        }
    }
    return m;
}

/// Two quads that share positions along x = 1 but carry different U values.
ProcMesh makeSeam() {
    ProcMesh m;
    // 0,1,2,3 left quad. 4,5,6,7 right quad. 1 coincides with 4, 3 with 6.
    m.positions = [
        0, 0, 0,  1, 0, 0,  0, 1, 0,  1, 1, 0,
        1, 0, 0,  2, 0, 0,  1, 1, 0,  2, 1, 0,
    ];
    m.uvs = [
        0, 0,  1, 0,  0, 1,  1, 1,
        0, 0,  1, 0,  0, 1,  1, 1,
    ];
    m.indices = [
        0, 2, 1,  1, 2, 3,
        4, 6, 5,  5, 6, 7,
    ];
    return m;
}

/// Three triangles on one edge, plus a degenerate. Non-manifold soup.
ProcMesh makeSoup() {
    ProcMesh m;
    m.positions = [
        0, 0, 0,
        1, 0, 0,
        0, 1, 0,
        0, 0, 1,
        1, 1, 1,
        2, 0, 0,
        2, 1, 0,
    ];
    m.indices = [
        0, 1, 2,
        0, 1, 3,
        0, 1, 4,
        5, 5, 6,
    ];
    return m;
}

private float sinF(float x) nothrow @nogc @trusted {
    import core.stdc.math : sinf;
    return sinf(x);
}

private float cosF(float x) nothrow @nogc @trusted {
    import core.stdc.math : cosf;
    return cosf(x);
}

@safe unittest {
    ProcMesh g = makeGrid(2, 3);
    assert(g.positions.length == 3 * 4 * 3);
    assert(g.indices.length == 2 * 3 * 6);

    ProcMesh sphere = makeSphere(8, 4);
    assert(sphere.indices.length == 8 * 4 * 6);
    assert(sphere.uvs.length == sphere.positions.length / 3 * 2);

    ProcMesh torus = makeTorus(8, 4, 2, 0.4f);
    assert(torus.indices.length == 8 * 4 * 6);

    ProcMesh seam = makeSeam();
    // Vertex 1 and vertex 4 share a position and differ in U.
    assert(seam.positions[1 * 3 .. 1 * 3 + 3] == seam.positions[4 * 3 .. 4 * 3 + 3]);
    assert(seam.uvs[1 * 2] != seam.uvs[4 * 2]);

    ProcMesh soup = makeSoup();
    uint[3] edgeUsers = 0;
    foreach (t; 0 .. soup.indices.length / 3) {
        uint a = soup.indices[t * 3];
        uint b = soup.indices[t * 3 + 1];
        uint c = soup.indices[t * 3 + 2];
        if ((a == 0 && b == 1) || (a == 1 && b == 0))
            edgeUsers[0]++;
        if (a == b || b == c || a == c)
            edgeUsers[1]++;
    }
    assert(edgeUsers[0] == 3);
    assert(edgeUsers[1] >= 1);

    import std.file : exists, readText;
    assert(exists("assets/models/meshopt/pirate.obj"));
    string head = readText("assets/models/meshopt/pirate.obj")[0 .. 180];
    assert(head.length > 0);
    bool sawAuthor;
    bool sawLicense;
    foreach (line; head.splitLinesSafe()) {
        if (indexOfSafe(line, "Clint Bellanger"))
            sawAuthor = true;
        if (indexOfSafe(line, "CC-BY-SA"))
            sawLicense = true;
    }
    assert(sawAuthor && sawLicense);
}

private bool indexOfSafe(string s, string needle) pure {
    if (needle.length > s.length)
        return false;
    foreach (i; 0 .. s.length - needle.length + 1) {
        if (s[i .. i + needle.length] == needle)
            return true;
    }
    return false;
}

private string[] splitLinesSafe(string s) pure {
    string[] lines;
    size_t start;
    foreach (i, char c; s) {
        if (c == '\n') {
            size_t end = i > start && s[i - 1] == '\r' ? i - 1 : i;
            lines ~= s[start .. end];
            start = i + 1;
        }
    }
    if (start < s.length)
        lines ~= s[start .. $];
    return lines;
}
