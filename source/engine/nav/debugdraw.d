/// Filled-triangle gizmo debug draw helper for `NavMesh`.
module engine.nav.debugdraw;

import engine.devtools.gizmos : GizmoRenderer;
import engine.graphics.types : Color4;
import engine.math.vec : Vec3;
import engine.nav.mesh : NavMesh;
import bindings.recast : navExtractDebugTriangles;

@safe:

/// Draw walkable `NavMesh` polygons as semi-transparent filled triangles plus wireframe edges.
void drawNavMesh(ref GizmoRenderer gizmos, ref const NavMesh mesh,
                 float fillAlpha = 0.35f, float yOffset = 0.03f) @trusted nothrow @nogc {
    if (!mesh.isValid()) return;
    enum int MAX_TRIS = 4096;
    float[MAX_TRIS * 9] verts = void;
    ubyte[MAX_TRIS] areas = void;

    immutable int triCount = navExtractDebugTriangles(mesh.handle, verts.ptr, areas.ptr, MAX_TRIS);
    if (triCount <= 0) return;

    immutable fillCol = Color4(0.15f, 0.72f, 0.95f, fillAlpha);
    immutable edgeCol = Color4(0.10f, 0.90f, 1.00f, 0.85f);

    foreach (i; 0 .. triCount) {
        immutable base = i * 9;
        immutable a = Vec3(verts[base + 0], verts[base + 1] + yOffset, verts[base + 2]);
        immutable b = Vec3(verts[base + 3], verts[base + 4] + yOffset, verts[base + 5]);
        immutable c = Vec3(verts[base + 6], verts[base + 7] + yOffset, verts[base + 8]);

        gizmos.triangle(a, b, c, fillCol);
        gizmos.line(a, b, edgeCol);
        gizmos.line(b, c, edgeCol);
        gizmos.line(c, a, edgeCol);
    }
}
