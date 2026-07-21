/// ED-5a/5b physics inspector panel, hull bake → `*.asset.json`, collider gizmos.
module engine.editor.physics_panel;

import bindings.box3d : b3CreateHullD, b3DestroyHullD, b3HullData, b3Vec3;

import engine.assets.asset_file : AssetFile, loadAssetFile, saveAssetFile;
import engine.assets.gltf : GltfMesh, parseGltfMesh;
import engine.core.log : err, info, warn;
import engine.core.strings : StringId;
import engine.devtools.gizmos : GizmoRenderer;
import engine.editor.components :
    PhysicsBody, PhysicsMotion, PhysicsShapeKind, Visual, VisualKind,
    isMeshDynamicForbidden, refuseMeshDynamic, worldMatrix;
import engine.editor.physics_sim :
    PhysicsAssetGeometry, PhysicsAssetResolver, PhysicsSimSession,
    trySetPhysicsShapeMotion;
import engine.editor.picking : entityWorldAabb;
import engine.editor.ui :
    UiContext, button, checkbox, combo, label, separator, sliderFloat;
import engine.ecs.store : EntityId;
import engine.graphics.types : Color4;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.physics.world : PhysicsWorld;
import engine.scene.graph : Transform;

@safe:

/// Collider gizmo colors (ED-5b).
enum Color4 colorColliderAabb = Color4(1.0f, 0.9f, 0.15f, 1.0f);   /// yellow
enum Color4 colorColliderHull = Color4(0.15f, 0.95f, 0.95f, 1.0f);  /// cyan
enum Color4 colorColliderMesh = Color4(0.95f, 0.2f, 0.85f, 1.0f);   /// magenta

/// Scratch state for physics inspector combos + status line.
struct PhysicsPanelState {
    bool motionOpen = false;
    bool shapeOpen = false;
    char[96] status = void;
    size_t statusLen = 0;

    void setStatus(scope const(char)[] msg) nothrow @nogc {
        immutable n = msg.length < status.length ? msg.length : status.length;
        foreach (i; 0 .. n)
            status[i] = msg[i];
        statusLen = n;
    }

    void clearStatus() nothrow @nogc { statusLen = 0; }
}

/// Draw Physics section for a selected entity. Mutates `PhysicsBody` live.
/// Returns true if any property changed this frame.
bool drawPhysicsPanel(W)(
    ref UiContext ui,
    ref W world,
    EntityId id,
    ref PhysicsPanelState state
) {
    bool changed = false;

    if (id == EntityId.max || !world.alive(id))
        return changed;

    separator(ui);
    label(ui, "Physics");

    PhysicsBody pb = world.has!PhysicsBody(id)
        ? world.get!PhysicsBody(id)
        : PhysicsBody.init;

    bool enabled = pb.enabled != 0;
    if (checkbox(ui, "Enable", enabled)) {
        pb.enabled = enabled ? 1 : 0;
        if (enabled)
            syncHalfExtentsFromVisual(world, id, pb);
        world.set(id, pb);
        changed = true;
    }

    if (pb.enabled == 0 && !world.has!PhysicsBody(id))
        return changed;

    if (!world.has!PhysicsBody(id))
        world.set(id, pb);

    int motion = cast(int) pb.motion;
    if (motion < 0) motion = 0;
    if (motion > 2) motion = 2;
    scope const(char[])[] motions = ["static", "dynamic", "kinematic"];
    if (combo(ui, "Motion", motions, motion, state.motionOpen)) {
        if (!trySetPhysicsShapeMotion(pb, pb.shape, cast(uint) motion)) {
            state.setStatus("mesh+dynamic refused");
            pb.motion = cast(uint) motion;
            refuseMeshDynamic(pb);
        } else {
            state.clearStatus();
        }
        world.set(id, pb);
        changed = true;
    }

    int shape = cast(int) pb.shape;
    if (shape < 0) shape = 0;
    if (shape > 2) shape = 2;
    scope const(char[])[] shapes = ["primitive", "convexHull", "triangleMesh"];
    if (combo(ui, "Shape", shapes, shape, state.shapeOpen)) {
        if (!trySetPhysicsShapeMotion(pb, cast(uint) shape, pb.motion)) {
            state.setStatus("mesh+dynamic refused");
            pb.shape = cast(uint) shape;
            refuseMeshDynamic(pb);
        } else {
            state.clearStatus();
        }
        world.set(id, pb);
        changed = true;
    }

    if (isMeshDynamicForbidden(pb)) {
        label(ui, "! mesh requires static");
        refuseMeshDynamic(pb);
        world.set(id, pb);
    }

    bool dimsChanged = false;
    if (sliderFloat(ui, "Half X", pb.halfExtents.x, 0.01f, 20)) dimsChanged = true;
    if (sliderFloat(ui, "Half Y", pb.halfExtents.y, 0.01f, 20)) dimsChanged = true;
    if (sliderFloat(ui, "Half Z", pb.halfExtents.z, 0.01f, 20)) dimsChanged = true;
    if (sliderFloat(ui, "Mass", pb.mass, 0.01f, 100)) dimsChanged = true;
    if (sliderFloat(ui, "Friction", pb.friction, 0, 2)) dimsChanged = true;
    if (sliderFloat(ui, "Restitution", pb.restitution, 0, 1)) dimsChanged = true;
    if (sliderFloat(ui, "Lin damp", pb.linearDamping, 0, 5)) dimsChanged = true;
    if (sliderFloat(ui, "Ang damp", pb.angularDamping, 0, 5)) dimsChanged = true;

    float maxHull = cast(float) pb.maxHullVertices;
    if (sliderFloat(ui, "Max hull verts", maxHull, 4, 256)) {
        pb.maxHullVertices = cast(uint) maxHull;
        dimsChanged = true;
    }

    bool showCol = pb.showCollider != 0;
    if (checkbox(ui, "Show collider", showCol)) {
        pb.showCollider = showCol ? 1 : 0;
        dimsChanged = true;
    }

    if (dimsChanged) {
        world.set(id, pb);
        changed = true;
    }

    if (pb.shape == PhysicsShapeKind.convexHull) {
        if (button(ui, "Bake hull to asset")) {
            if (pb.assetPath.isNull) {
                state.setStatus("set asset path first");
            } else {
                auto path = world.strings.get(pb.assetPath).idup;
                Visual vis = world.has!Visual(id) ? world.get!Visual(id) : Visual.init;
                if (bakeHullForEntity(path, pb, vis)) {
                    state.setStatus("hull baked OK");
                    info("Baked convex hull → ", path);
                } else {
                    state.setStatus("bake failed");
                }
            }
            changed = true;
        }
    }

    if (state.statusLen > 0)
        label(ui, state.status[0 .. state.statusLen]);

    return changed;
}

/// Simulate / Stop controls. Pair with `sim.handleEscape` + `sim.tick` in the frame loop.
bool drawPhysicsSimControls(W)(
    ref UiContext ui,
    ref W world,
    ref PhysicsSimSession sim,
    ref PhysicsWorld physics,
    PhysicsAssetResolver resolveAsset = null
) {
    bool changed = false;
    label(ui, "Physics Sim");
    if (sim.active) {
        label(ui, "SIM — Esc restores");
        if (button(ui, "Stop Simulate")) {
            sim.stopSimulate(world);
            changed = true;
        }
    } else if (button(ui, "Simulate")) {
        sim.beginSimulate(world, physics, resolveAsset);
        changed = true;
    }
    return changed;
}

/// Wireframe colliders: AABB yellow, hull cyan, mesh magenta.
void drawPhysicsColliderGizmos(W)(
    ref W world,
    ref GizmoRenderer gizmos,
    PhysicsAssetResolver resolveAsset = null
) {
    foreach (id; world.query!(Transform, PhysicsBody)()) {
        if (!world.alive(id))
            continue;
        immutable pb = world.get!PhysicsBody(id);
        if (pb.enabled == 0 || pb.showCollider == 0)
            continue;

        immutable box = entityWorldAabb(world, id);
        gizmos.box(box.center(), box.extents(), colorColliderAabb);

        immutable worldM = worldMatrix(world, id);

        if (pb.shape == PhysicsShapeKind.primitive) {
            drawOrientedBox(gizmos, worldM, pb.halfExtents, colorColliderAabb);
            continue;
        }

        PhysicsAssetGeometry geo;
        if (!pb.assetPath.isNull && resolveAsset !is null)
            resolveAsset(pb.assetPath, geo);

        if (pb.shape == PhysicsShapeKind.convexHull) {
            if (geo.hullPoints.length >= 2)
                drawHullWireframe(gizmos, worldM, geo.hullPoints, colorColliderHull);
            else
                drawOrientedBox(gizmos, worldM, pb.halfExtents, colorColliderHull);
        } else if (pb.shape == PhysicsShapeKind.triangleMesh) {
            if (geo.meshVertices.length >= 3 && geo.meshIndices.length >= 3)
                drawMeshWireframe(gizmos, worldM, geo.meshVertices, geo.meshIndices, colorColliderMesh);
            else
                drawOrientedBox(gizmos, worldM, pb.halfExtents, colorColliderMesh);
        }
    }
}

// ---------------------------------------------------------------------------
// Hull bake (ED-5b)
// ---------------------------------------------------------------------------

/// Bake convex hull from mesh points into `assetPath` (`*.asset.json`).
/// Validates with `b3CreateHull` before writing. Returns false on failure.
bool bakeConvexHullToAsset(
    string assetPath,
    scope const(Vec3)[] meshPoints,
    uint maxVertexCount = 64
) {
    if (meshPoints.length < 3 || maxVertexCount < 3) {
        warn("bakeConvexHullToAsset: need >= 3 points");
        return false;
    }

    if (!validateHullCook(meshPoints, maxVertexCount)) {
        err("bakeConvexHullToAsset: b3CreateHull failed");
        return false;
    }

    AssetFile asset;
    try {
        asset = loadAssetFile(assetPath);
    } catch (Exception e) {
        err("bakeConvexHullToAsset: load failed: ", e.msg);
        return false;
    }

    asset.collision.hasConvexHull = true;
    asset.collision.convexHull.maxVertexCount = maxVertexCount;
    asset.collision.convexHull.points.length = meshPoints.length;
    foreach (i, p; meshPoints)
        asset.collision.convexHull.points[i] = [p.x, p.y, p.z];

    try {
        saveAssetFile(assetPath, asset);
    } catch (Exception e) {
        err("bakeConvexHullToAsset: save failed: ", e.msg);
        return false;
    }
    return true;
}

/// Resolve mesh points for an entity and bake into its asset file.
bool bakeHullForEntity(string assetPath, ref const PhysicsBody pb, Visual visual) {
    auto points = collectBakePoints(assetPath, visual, pb.halfExtents);
    if (points.length < 3)
        return false;
    immutable maxV = pb.maxHullVertices > 0 ? pb.maxHullVertices : 64;
    return bakeConvexHullToAsset(assetPath, points, maxV);
}

/// Load hull + triangle mesh CPU data from a `*.asset.json` path.
bool loadPhysicsAssetGeometry(string assetPath, ref PhysicsAssetGeometry outGeo) {
    outGeo = PhysicsAssetGeometry.init;
    AssetFile asset;
    try {
        asset = loadAssetFile(assetPath);
    } catch (Exception e) {
        warn("loadPhysicsAssetGeometry: ", e.msg);
        return false;
    }

    outGeo.maxHullVertices = asset.collision.hasConvexHull
        ? asset.collision.convexHull.maxVertexCount
        : 64;

    if (asset.collision.hasConvexHull && asset.hullPoints().length > 0) {
        auto hp = asset.hullPoints();
        outGeo.hullPoints.length = hp.length;
        foreach (i, p; hp)
            outGeo.hullPoints[i] = Vec3(p[0], p[1], p[2]);
    }

    string meshPath = asset.collisionMeshPath();
    if (meshPath.length == 0)
        meshPath = asset.renderGltfPath();
    if (meshPath.length == 0)
        return outGeo.hullPoints.length > 0;

    try {
        auto mesh = parseGltfMesh(meshPath);
        outGeo.meshVertices.length = mesh.vertices.length;
        foreach (i, v; mesh.vertices)
            outGeo.meshVertices[i] = Vec3(v.pos[0], v.pos[1], v.pos[2]);
        outGeo.meshIndices.length = mesh.indices.length;
        foreach (i, idx; mesh.indices)
            outGeo.meshIndices[i] = cast(int) idx;
    } catch (Exception e) {
        warn("loadPhysicsAssetGeometry mesh: ", e.msg);
        return outGeo.hullPoints.length > 0;
    }
    return true;
}

/// Build a `PhysicsAssetResolver` that loads geometry via `loadPhysicsAssetGeometry`
/// using paths from `world.strings`.
PhysicsAssetResolver makeAssetResolver(W)(ref W world) {
    return (StringId pathId, ref PhysicsAssetGeometry geo) {
        if (pathId.isNull)
            return false;
        auto path = world.strings.get(pathId).idup;
        return loadPhysicsAssetGeometry(path, geo);
    };
}

/// Unique object-space positions from a glTF (for hull bake).
Vec3[] uniquePositionsFromGltf(string gltfPath) {
    auto mesh = parseGltfMesh(gltfPath);
    return uniquePositionsFromVerts(mesh);
}

/// 8 corners of an AABB centered at origin (primitive hull fallback).
Vec3[] primitiveHullPoints(Vec3 halfExtents) {
    immutable hx = halfExtents.x;
    immutable hy = halfExtents.y;
    immutable hz = halfExtents.z;
    return [
        Vec3(-hx, -hy, -hz), Vec3( hx, -hy, -hz),
        Vec3( hx,  hy, -hz), Vec3(-hx,  hy, -hz),
        Vec3(-hx, -hy,  hz), Vec3( hx, -hy,  hz),
        Vec3( hx,  hy,  hz), Vec3(-hx,  hy,  hz),
    ];
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

private void syncHalfExtentsFromVisual(W)(ref W world, EntityId id, ref PhysicsBody pb) {
    if (!world.has!Visual(id))
        return;
    immutable v = world.get!Visual(id);
    if (v.localHalfExtents.x > 0 || v.localHalfExtents.y > 0 || v.localHalfExtents.z > 0)
        pb.halfExtents = v.localHalfExtents;
}

private Vec3[] collectBakePoints(string assetPath, Visual visual, Vec3 halfExtents) {
    AssetFile asset;
    try {
        asset = loadAssetFile(assetPath);
    } catch (Exception e) {
        cast(void) visual;
        return uniqueDedup(primitiveHullPoints(halfExtents));
    }

    string meshPath = asset.collisionMeshPath();
    if (meshPath.length == 0)
        meshPath = asset.renderGltfPath();

    if (meshPath.length > 0) {
        try {
            return uniquePositionsFromGltf(meshPath);
        } catch (Exception e) {
            warn("collectBakePoints: ", e.msg);
        }
    }

    cast(void) visual;
    return uniqueDedup(primitiveHullPoints(halfExtents));
}

private Vec3[] uniquePositionsFromVerts(ref const GltfMesh mesh) {
    Vec3[] pts;
    pts.length = mesh.vertices.length;
    foreach (i, v; mesh.vertices)
        pts[i] = Vec3(v.pos[0], v.pos[1], v.pos[2]);
    return uniqueDedup(pts);
}

private Vec3[] uniqueDedup(Vec3[] pts) {
    enum float eps = 1e-5f;
    Vec3[] out_;
    foreach (p; pts) {
        bool found = false;
        foreach (q; out_) {
            immutable dx = p.x - q.x;
            immutable dy = p.y - q.y;
            immutable dz = p.z - q.z;
            if (dx * dx + dy * dy + dz * dz < eps * eps) {
                found = true;
                break;
            }
        }
        if (!found)
            out_ ~= p;
    }
    return out_;
}

private bool validateHullCook(scope const(Vec3)[] points, uint maxVertexCount) nothrow @nogc @trusted {
    if (points.length < 3)
        return false;
    immutable count = cast(int) points.length;
    immutable maxV = cast(int)(maxVertexCount < points.length ? maxVertexCount : points.length);
    b3HullData* hull = b3CreateHullD(cast(const(b3Vec3)*) points.ptr, count, maxV);
    if (hull is null)
        return false;
    b3DestroyHullD(hull);
    return true;
}

private void drawOrientedBox(ref GizmoRenderer gizmos, Mat4 world, Vec3 half, Color4 c) nothrow @nogc {
    Vec3[8] corners;
    size_t i = 0;
    foreach (ix; 0 .. 2)
    foreach (iy; 0 .. 2)
    foreach (iz; 0 .. 2) {
        immutable lx = ix ? half.x : -half.x;
        immutable ly = iy ? half.y : -half.y;
        immutable lz = iz ? half.z : -half.z;
        corners[i++] = transformPoint(world, Vec3(lx, ly, lz));
    }
    immutable int[2][12] edges = [
        [0, 1], [1, 3], [3, 2], [2, 0],
        [4, 5], [5, 7], [7, 6], [6, 4],
        [0, 4], [1, 5], [2, 6], [3, 7],
    ];
    foreach (e; edges)
        gizmos.line(corners[e[0]], corners[e[1]], c);
}

private void drawHullWireframe(
    ref GizmoRenderer gizmos,
    Mat4 world,
    scope const(Vec3)[] points,
    Color4 c
) nothrow @nogc {
    if (points.length < 2)
        return;
    Vec3 centroid = Vec3(0, 0, 0);
    foreach (p; points)
        centroid = centroid + p;
    immutable inv = 1.0f / cast(float) points.length;
    centroid = Vec3(centroid.x * inv, centroid.y * inv, centroid.z * inv);
    immutable cWorld = transformPoint(world, centroid);
    foreach (p; points) {
        immutable wp = transformPoint(world, p);
        gizmos.line(cWorld, wp, c);
    }
    foreach (i; 0 .. points.length) {
        immutable a = transformPoint(world, points[i]);
        immutable b = transformPoint(world, points[(i + 1) % points.length]);
        gizmos.line(a, b, c);
    }
}

private void drawMeshWireframe(
    ref GizmoRenderer gizmos,
    Mat4 world,
    scope const(Vec3)[] verts,
    scope const(int)[] indices,
    Color4 c
) nothrow @nogc {
    immutable triCount = indices.length / 3;
    enum size_t maxTris = 512;
    immutable n = triCount < maxTris ? triCount : maxTris;
    foreach (t; 0 .. n) {
        immutable i0 = indices[t * 3 + 0];
        immutable i1 = indices[t * 3 + 1];
        immutable i2 = indices[t * 3 + 2];
        if (i0 < 0 || i1 < 0 || i2 < 0)
            continue;
        if (i0 >= cast(int) verts.length || i1 >= cast(int) verts.length || i2 >= cast(int) verts.length)
            continue;
        immutable a = transformPoint(world, verts[i0]);
        immutable b = transformPoint(world, verts[i1]);
        immutable d = transformPoint(world, verts[i2]);
        gizmos.line(a, b, c);
        gizmos.line(b, d, c);
        gizmos.line(d, a, c);
    }
}

private Vec3 transformPoint(Mat4 m, Vec3 p) pure nothrow @nogc {
    return Vec3(
        m.m[0] * p.x + m.m[4] * p.y + m.m[8]  * p.z + m.m[12],
        m.m[1] * p.x + m.m[5] * p.y + m.m[9]  * p.z + m.m[13],
        m.m[2] * p.x + m.m[6] * p.y + m.m[10] * p.z + m.m[14],
    );
}

@safe unittest {
    auto pts = primitiveHullPoints(Vec3(0.5f, 0.5f, 0.5f));
    assert(pts.length == 8);

    PhysicsBody pb;
    assert(!trySetPhysicsShapeMotion(pb, PhysicsShapeKind.triangleMesh, PhysicsMotion.dynamic_));
    assert(trySetPhysicsShapeMotion(pb, PhysicsShapeKind.triangleMesh, PhysicsMotion.static_));
    assert(pb.shape == PhysicsShapeKind.triangleMesh);
    assert(pb.motion == PhysicsMotion.static_);
}
