/// Interactive TRS gizmo over `GizmoRenderer` — translate/rotate/scale,
/// local/world space, snap + ground grid. Multi-select moves (ED-8).
module engine.editor.gizmo_tool;

import engine.devtools.gizmos : GizmoRenderer;
import engine.editor.components : worldPosition;
import engine.editor.selection : Selection, noSelection;
import engine.ecs.store : EntityId;
import engine.graphics.types : Color4;
import engine.math.quat : Quat;
import engine.math.ray : Ray;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;
import std.math : abs, cos, sin, round, PI;

@safe:

enum GizmoMode : uint {
    translate = 0,
    rotate    = 1,
    scale     = 2,
}

enum GizmoSpace : uint {
    world = 0,
    local = 1,
}

enum GizmoAxis : uint {
    none = 0,
    x    = 1,
    y    = 2,
    z    = 3,
}

/// Snap a scalar to the nearest multiple of `step` (no-op if step ≤ 0).
float snapValue(float v, float step) nothrow @nogc {
    if (step <= 0) return v;
    return round(v / step) * step;
}

Vec3 snapVec(Vec3 v, float step) nothrow @nogc {
    return Vec3(snapValue(v.x, step), snapValue(v.y, step), snapValue(v.z, step));
}

/// Closest distance between ray and infinite axis through `origin` along `axisDir`.
/// Writes ray parameter `tRay` and signed axis parameter `tSeg` from origin.
float closestRayAxis(Ray ray, Vec3 origin, Vec3 axisDir, ref float tRay, ref float tSeg) {
    immutable d1 = ray.direction;
    immutable d2 = axisDir.normalized();
    immutable w = ray.origin - origin;

    immutable a = d1.dot(d1);
    immutable b = d1.dot(d2);
    immutable c = d2.dot(d2);
    immutable d = d1.dot(w);
    immutable e = d2.dot(w);
    immutable denom = a * c - b * b;

    if (abs(denom) < 1e-8f) {
        tRay = 0;
        tSeg = e;
        immutable pAxis = origin + d2 * tSeg;
        return (ray.origin - pAxis).length();
    }

    tRay = (b * e - c * d) / denom;
    tSeg = (a * e - b * d) / denom;
    immutable pRay = ray.origin + d1 * tRay;
    immutable pAxis = origin + d2 * tSeg;
    return (pRay - pAxis).length();
}

Vec3 snapAlongAxis(Vec3 delta, Vec3 axis, float step) {
    if (step <= 0) return delta;
    immutable a = axis.normalized();
    immutable mag = snapValue(delta.dot(a), step);
    return a * mag;
}

/// Interactive transform gizmo state.
struct GizmoTool {
    GizmoMode mode = GizmoMode.translate;
    GizmoSpace space = GizmoSpace.world;

    bool snapEnabled = true;
    float translateSnap = 0.25f;
    float rotateSnapDeg = 15.0f;
    float scaleSnap = 0.1f;

    bool showGrid = true;
    float gridSize = 20.0f;
    int gridCells = 20;
    float axisLength = 1.25f;
    float pickRadius = 0.15f;

    bool dragging = false;
    /// True for one frame after a drag that mutated transforms (wire undo).
    bool dragJustEnded = false;
    bool dragMutated = false;
    GizmoAxis activeAxis = GizmoAxis.none;
    EntityId dragEntity = EntityId.max;
    Transform dragStartLocal;
    Vec3 dragAxisWorld = Vec3(1, 0, 0);
    float dragT0 = 0;

    /// Multi-select drag baselines (ED-8).
    enum maxDrag = Selection.capacity;
    EntityId[maxDrag] dragIds;
    Transform[maxDrag] dragStarts;
    int dragCount = 0;

    /// True while the gizmo owns the mouse (suppress scene picking).
    bool wantCaptureMouse() const nothrow @nogc {
        return dragging;
    }

    /// Draw grid + TRS handles for `entity`. Call after `gizmos.begin`.
    void draw(W)(ref W world, EntityId entity, ref GizmoRenderer gizmos) {
        if (showGrid) {
            gizmos.grid(gridSize, gridCells, Color4(0.25f, 0.25f, 0.28f, 1.0f), 0);
        }
        if (entity == EntityId.max || !world.alive(entity) || !world.has!Transform(entity))
            return;

        immutable origin = worldPosition(world, entity);
        Vec3 ax, ay, az;
        axisDirections(world, entity, ax, ay, az);

        final switch (mode) {
            case GizmoMode.translate:
            case GizmoMode.scale:
                drawAxis(gizmos, origin, ax, Color4(1, 0.2f, 0.2f, 1), activeAxis == GizmoAxis.x);
                drawAxis(gizmos, origin, ay, Color4(0.2f, 1, 0.2f, 1), activeAxis == GizmoAxis.y);
                drawAxis(gizmos, origin, az, Color4(0.25f, 0.45f, 1, 1), activeAxis == GizmoAxis.z);
                break;
            case GizmoMode.rotate:
                drawRotationRing(gizmos, origin, ax, Color4(1, 0.2f, 0.2f, 1), activeAxis == GizmoAxis.x);
                drawRotationRing(gizmos, origin, ay, Color4(0.2f, 1, 0.2f, 1), activeAxis == GizmoAxis.y);
                drawRotationRing(gizmos, origin, az, Color4(0.25f, 0.45f, 1, 1), activeAxis == GizmoAxis.z);
                break;
        }
    }

    /// Handle mouse vs gizmo for the selection primary (+ multi-move).
    /// Returns true if any transform changed this frame.
    bool update(W)(
        ref W world,
        ref Selection sel,
        Ray mouseRay,
        bool mousePressed,
        bool mouseDown,
        bool mouseReleased
    ) {
        dragJustEnded = false;
        bool changed = false;
        immutable entity = sel.primary;

        if (entity == noSelection || !world.alive(entity) || !world.has!Transform(entity)) {
            if (dragging && (mouseReleased || !mouseDown)) {
                dragging = false;
                activeAxis = GizmoAxis.none;
            }
            return false;
        }

        immutable origin = worldPosition(world, entity);
        Vec3 ax, ay, az;
        axisDirections(world, entity, ax, ay, az);

        if (!dragging) {
            activeAxis = GizmoAxis.none;
            float bestDist = pickRadius;
            tryPickAxis(mouseRay, origin, ax, GizmoAxis.x, bestDist);
            tryPickAxis(mouseRay, origin, ay, GizmoAxis.y, bestDist);
            tryPickAxis(mouseRay, origin, az, GizmoAxis.z, bestDist);

            if (mousePressed && activeAxis != GizmoAxis.none) {
                dragging = true;
                dragMutated = false;
                dragEntity = entity;
                dragStartLocal = world.get!Transform(entity);
                dragAxisWorld = axisFor(activeAxis, ax, ay, az);
                float tSeg = 0, tRay = 0;
                closestRayAxis(mouseRay, origin, dragAxisWorld, tRay, tSeg);
                dragT0 = tSeg;
                captureDragStarts(world, sel);
            }
        }

        if (dragging && mouseDown && dragEntity == entity) {
            float tSeg = 0, tRay = 0;
            closestRayAxis(mouseRay, origin, dragAxisWorld, tRay, tSeg);
            immutable delta = tSeg - dragT0;
            changed = applyDragDelta(world, delta);
            if (changed) dragMutated = true;
        }

        if (dragging && (mouseReleased || !mouseDown)) {
            if (dragMutated)
                dragJustEnded = true;
            dragging = false;
            dragMutated = false;
            if (!mouseDown)
                activeAxis = GizmoAxis.none;
        }
        return changed;
    }

    /// Convenience single-entity update (tests / simple callers).
    bool update(W)(
        ref W world,
        EntityId entity,
        Ray mouseRay,
        bool mousePressed,
        bool mouseDown,
        bool mouseReleased
    ) {
        Selection sel;
        if (entity != noSelection) sel.select(entity);
        return update(world, sel, mouseRay, mousePressed, mouseDown, mouseReleased);
    }

private:
    void captureDragStarts(W)(ref W world, ref Selection sel) nothrow @nogc {
        dragCount = 0;
        foreach (i; 0 .. sel.count) {
            if (dragCount >= maxDrag) break;
            immutable id = sel.ids[i];
            if (!world.alive(id) || !world.has!Transform(id)) continue;
            dragIds[dragCount] = id;
            dragStarts[dragCount] = world.get!Transform(id);
            dragCount++;
        }
        if (dragCount == 0 && world.has!Transform(sel.primary)) {
            dragIds[0] = sel.primary;
            dragStarts[0] = world.get!Transform(sel.primary);
            dragCount = 1;
        }
    }

    bool applyDragDelta(W)(ref W world, float delta) {
        bool changed = false;
        foreach (i; 0 .. dragCount) {
            immutable id = dragIds[i];
            if (!world.alive(id) || !world.has!Transform(id)) continue;
            auto t = dragStarts[i];
            final switch (mode) {
                case GizmoMode.translate: {
                    Vec3 deltaWorld = dragAxisWorld * delta;
                    if (snapEnabled)
                        deltaWorld = snapAlongAxis(deltaWorld, dragAxisWorld, translateSnap);
                    t.position = dragStarts[i].position + deltaWorld;
                    if (snapEnabled && space == GizmoSpace.world)
                        t.position = snapVec(t.position, translateSnap);
                    break;
                }
                case GizmoMode.scale: {
                    float s = 1.0f + delta;
                    if (snapEnabled)
                        s = snapValue(s, scaleSnap);
                    if (s < 0.01f) s = 0.01f;
                    Vec3 scale = dragStarts[i].scale;
                    if (activeAxis == GizmoAxis.x) scale.x = dragStarts[i].scale.x * s;
                    else if (activeAxis == GizmoAxis.y) scale.y = dragStarts[i].scale.y * s;
                    else if (activeAxis == GizmoAxis.z) scale.z = dragStarts[i].scale.z * s;
                    t.scale = scale;
                    break;
                }
                case GizmoMode.rotate: {
                    float deg = delta * (180.0f / PI) * 40.0f;
                    if (snapEnabled)
                        deg = snapValue(deg, rotateSnapDeg);
                    immutable rad = deg * (PI / 180.0f);
                    immutable qDelta = Quat.fromAxisAngle(dragAxisWorld, rad);
                    if (space == GizmoSpace.world)
                        t.rotation = (qDelta * dragStarts[i].rotation).normalized();
                    else
                        t.rotation = (dragStarts[i].rotation * qDelta).normalized();
                    break;
                }
            }
            world.set(id, t);
            changed = true;
        }
        return changed;
    }

    void axisDirections(W)(ref W world, EntityId entity, ref Vec3 ax, ref Vec3 ay, ref Vec3 az) {
        if (space == GizmoSpace.world || !world.has!Transform(entity)) {
            ax = Vec3(1, 0, 0);
            ay = Vec3(0, 1, 0);
            az = Vec3(0, 0, 1);
            return;
        }
        immutable q = world.get!Transform(entity).rotation;
        ax = q.rotate(Vec3(1, 0, 0));
        ay = q.rotate(Vec3(0, 1, 0));
        az = q.rotate(Vec3(0, 0, 1));
    }

    void tryPickAxis(Ray ray, Vec3 origin, Vec3 axisDir, GizmoAxis axis, ref float bestDist) {
        float tRay = 0, tSeg = 0;
        immutable d = closestRayAxis(ray, origin, axisDir, tRay, tSeg);
        if (tSeg < 0 || tSeg > axisLength) return;
        if (d < bestDist) {
            bestDist = d;
            activeAxis = axis;
        }
    }

    static Vec3 axisFor(GizmoAxis a, Vec3 ax, Vec3 ay, Vec3 az) {
        final switch (a) {
            case GizmoAxis.none: return Vec3(0, 0, 0);
            case GizmoAxis.x: return ax;
            case GizmoAxis.y: return ay;
            case GizmoAxis.z: return az;
        }
    }

    void drawAxis(ref GizmoRenderer gizmos, Vec3 origin, Vec3 dir, Color4 c, bool hot) {
        immutable col = hot ? Color4(1, 1, 0.2f, 1) : c;
        immutable len = hot ? axisLength * 1.1f : axisLength;
        gizmos.line(origin, origin + dir * len, col);
    }

    void drawRotationRing(ref GizmoRenderer gizmos, Vec3 origin, Vec3 axis, Color4 c, bool hot) {
        immutable col = hot ? Color4(1, 1, 0.2f, 1) : c;
        Vec3 u = abs(axis.y) < 0.9f ? axis.cross(Vec3(0, 1, 0)).normalized()
                                    : axis.cross(Vec3(1, 0, 0)).normalized();
        Vec3 v = axis.cross(u).normalized();
        immutable r = axisLength;
        enum segs = 24;
        Vec3 prev = origin + u * r;
        foreach (i; 1 .. segs + 1) {
            immutable ang = (2.0f * PI * cast(float) i) / cast(float) segs;
            immutable p = origin + u * (r * cos(ang)) + v * (r * sin(ang));
            gizmos.line(prev, p, col);
            prev = p;
        }
    }
}

@safe unittest {
    assert(snapValue(1.1f, 0.5f) == 1.0f);
    assert(snapValue(1.3f, 0.5f) == 1.5f);
    assert(snapValue(0.4f, 0) == 0.4f);
}

@safe unittest {
    Ray ray = Ray(Vec3(0, 1, 0), Vec3(0, -1, 0));
    float tRay = 0, tSeg = 0;
    immutable d = closestRayAxis(ray, Vec3(0, 0, 0), Vec3(1, 0, 0), tRay, tSeg);
    assert(d < 0.01f);
    assert(abs(tSeg) < 0.01f);
}
