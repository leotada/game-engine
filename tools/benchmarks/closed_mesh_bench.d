// Time of `isClosedMesh` against the sort-based test it replaced, on dense
// subdivided spheres (a seam column and pole fans, like a deformable car body).
//   dub run --config=closed-mesh-bench --compiler=ldc2 --build=release
module closed_mesh_bench;

import core.sys.posix.time : CLOCK_MONOTONIC, clock_gettime, timespec;
import std.stdio;

import engine.graphics.closed_mesh : isClosedMesh, isClosedMeshReference;
import engine.graphics.types : TexVert;

private double now() nothrow @nogc @trusted {
    timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

private void sphere(uint seg, uint ring, out TexVert[] verts, out uint[] idx) {
    import std.math : cos, PI, sin;
    foreach (y; 0 .. ring + 1) foreach (x; 0 .. seg + 1) {
        immutable float phi = cast(float) PI * y / ring, th = 2 * cast(float) PI * x / seg;
        immutable float nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th);
        verts ~= TexVert([nx, ny, nz], [nx, ny, nz], [cast(float) x / seg, cast(float) y / ring]);
    }
    foreach (y; 0 .. ring) foreach (x; 0 .. seg) {
        immutable uint a = y * (seg + 1) + x, b = a + seg + 1;
        idx ~= [a, a + 1, b, a + 1, b + 1, b];
    }
}

/// Best of `runs` timings in milliseconds.
private double bestMs(int runs, bool delegate() test, bool expect) {
    double best = double.max;
    foreach (_; 0 .. runs) {
        immutable t0 = now();
        immutable got = test();
        immutable dt = (now() - t0) * 1e3;
        if (got != expect) {
            stderr.writeln("result mismatch");
            import core.stdc.stdlib : exit;
            exit(1);
        }
        if (dt < best) best = dt;
    }
    return best;
}

void main() {
    writeln("| triangles | vertices | sort-based (ms) | linear (ms) | speedup |");
    writeln("|---:|---:|---:|---:|---:|");
    foreach (seg; [64u, 128, 256, 512]) {
        TexVert[] verts;
        uint[] idx;
        sphere(seg, seg / 2, verts, idx);
        immutable want = isClosedMeshReference(verts, idx);
        immutable oldMs = bestMs(5, () => isClosedMeshReference(verts, idx), want);
        immutable newMs = bestMs(20, () => isClosedMesh(verts, idx), want);
        writefln("| %d | %d | %.2f | %.3f | %.1fx |", idx.length / 3, verts.length, oldMs, newMs, oldMs / newMs);
    }
}
