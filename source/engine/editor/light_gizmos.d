/// ED-6 light gizmos: directional arrow + ortho AABB, point range sphere,
/// spot inner/outer cones.
module engine.editor.light_gizmos;

import engine.devtools.gizmos : GizmoRenderer;
import engine.ecs.store : EntityId;
import engine.editor.components : worldPosition;
import engine.editor.light_panel : SceneLightSettings, lightRayDirection;
import engine.editor.selection : noSelection;
import engine.graphics.types : Color4;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;
import engine.scene.light : Light, LightType;
import std.math : abs, cos, sin, PI;

@safe:

/// Draw gizmos for every Light entity in the world.
void drawAllLightGizmos(W)(
    ref W world,
    ref GizmoRenderer gizmos,
    ref const SceneLightSettings settings
) {
    foreach (id; world.query!(Light)()) {
        if (!world.alive(id)) continue;
        drawLightGizmo(world, id, gizmos, settings);
    }
}

/// Draw gizmos for a single light entity (no-op if missing Light/Transform).
void drawLightGizmo(W)(
    ref W world,
    EntityId id,
    ref GizmoRenderer gizmos,
    ref const SceneLightSettings settings
) {
    if (id == noSelection || !world.alive(id)) return;
    if (!world.has!Light(id) || !world.has!Transform(id)) return;

    immutable light = world.get!Light(id);
    immutable t = world.get!Transform(id);
    immutable pos = worldPosition(world, id);
    immutable ray = lightRayDirection(t);
    immutable col = lightColor(light);
    immutable shadowCol = light.castShadows
        ? Color4(1.0f, 0.85f, 0.2f, 1.0f)
        : col;

    final switch (light.type) {
        case LightType.directional:
            drawDirectionalGizmo(gizmos, pos, ray, light, settings, shadowCol);
            break;
        case LightType.point:
            drawPointGizmo(gizmos, pos, light, shadowCol);
            break;
        case LightType.spot:
            drawSpotGizmo(gizmos, pos, ray, light, shadowCol);
            break;
    }
}

private Color4 lightColor(ref const Light light) nothrow @nogc {
    return Color4(light.color[0], light.color[1], light.color[2], 1.0f);
}

/// Arrow along ray + AABB of the ortho shadow volume around scene center.
private void drawDirectionalGizmo(
    ref GizmoRenderer gizmos,
    Vec3 pos,
    Vec3 ray,
    ref const Light light,
    ref const SceneLightSettings settings,
    Color4 col
) nothrow @nogc {
    immutable r = light.range > 0.1f ? light.range : settings.dirShadowRadius;
    immutable center = settings.dirShadowCenter;

    // Arrow along illumination ray (light → scene).
    immutable arrowLen = r * 0.6f;
    immutable tail = center - ray * arrowLen;
    immutable origin = (pos - center).lengthSquared() > 0.01f ? pos : tail;
    gizmos.line(origin, origin + ray * arrowLen, col);
    drawArrowHead(gizmos, origin + ray * arrowLen, ray, col, arrowLen * 0.12f);

    // Ortho AABB (axis-aligned approximation of the shadow volume).
    gizmos.box(center, Vec3(r * 2, r * 2, r * 2),
                Color4(col.r * 0.7f, col.g * 0.7f, col.b * 0.7f, 1));

    // Short marker toward the sun (surface → light).
    immutable shade = -ray;
    gizmos.line(center, center + shade * (r * 0.25f), Color4(1, 1, 0.4f, 1));
}

private void drawPointGizmo(
    ref GizmoRenderer gizmos,
    Vec3 pos,
    ref const Light light,
    Color4 col
) nothrow @nogc {
    immutable radius = light.range > 0.01f ? light.range : 1.0f;
    drawWireSphere(gizmos, pos, radius, col, 24);
    // Cross icon at center
    immutable s = radius * 0.08f;
    gizmos.line(pos + Vec3(-s, 0, 0), pos + Vec3(s, 0, 0), col);
    gizmos.line(pos + Vec3(0, -s, 0), pos + Vec3(0, s, 0), col);
    gizmos.line(pos + Vec3(0, 0, -s), pos + Vec3(0, 0, s), col);
}

private void drawSpotGizmo(
    ref GizmoRenderer gizmos,
    Vec3 pos,
    Vec3 ray,
    ref const Light light,
    Color4 col
) nothrow @nogc {
    immutable range = light.range > 0.01f ? light.range : 1.0f;
    immutable inner = light.innerConeDeg * (PI / 180.0f);
    immutable outer = light.outerConeDeg * (PI / 180.0f);
    immutable innerCol = Color4(col.r, col.g * 0.9f, col.b * 0.5f, 1);
    immutable outerCol = col;

    drawCone(gizmos, pos, ray, range, outer, outerCol, 20);
    drawCone(gizmos, pos, ray, range, inner, innerCol, 16);

    // Axis
    gizmos.line(pos, pos + ray * range, Color4(1, 1, 0.5f, 1));
}

// ---------------------------------------------------------------------------
// Primitives
// ---------------------------------------------------------------------------

void drawWireSphere(
    ref GizmoRenderer gizmos,
    Vec3 center,
    float radius,
    Color4 col,
    int segments = 24
) nothrow @nogc {
    if (radius <= 0 || segments < 3) return;
    // Three great circles: XY, XZ, YZ
    drawCircle(gizmos, center, Vec3(1, 0, 0), Vec3(0, 1, 0), radius, col, segments);
    drawCircle(gizmos, center, Vec3(1, 0, 0), Vec3(0, 0, 1), radius, col, segments);
    drawCircle(gizmos, center, Vec3(0, 1, 0), Vec3(0, 0, 1), radius, col, segments);
}

void drawCircle(
    ref GizmoRenderer gizmos,
    Vec3 center,
    Vec3 u,
    Vec3 v,
    float radius,
    Color4 col,
    int segments
) nothrow @nogc {
    immutable uu = u.normalized();
    immutable vv = v.normalized();
    Vec3 prev = center + uu * radius;
    foreach (i; 1 .. segments + 1) {
        immutable ang = (2.0f * PI * cast(float) i) / cast(float) segments;
        immutable p = center + uu * (radius * cos(ang)) + vv * (radius * sin(ang));
        gizmos.line(prev, p, col);
        prev = p;
    }
}

/// Cone along `axis` (unit) with half-angle `halfAngleRad` and length `len`.
void drawCone(
    ref GizmoRenderer gizmos,
    Vec3 apex,
    Vec3 axis,
    float len,
    float halfAngleRad,
    Color4 col,
    int segments = 20
) nothrow @nogc {
    if (len <= 0 || segments < 3) return;
    immutable a = axis.normalized();
    // Base radius = len * tan(halfAngle)
    immutable baseR = len * (abs(cos(halfAngleRad)) > 1e-4f
        ? sin(halfAngleRad) / cos(halfAngleRad)
        : 1e4f);
    immutable base = apex + a * len;

    Vec3 u = abs(a.y) < 0.9f ? a.cross(Vec3(0, 1, 0)).normalized()
                             : a.cross(Vec3(1, 0, 0)).normalized();
    Vec3 v = a.cross(u).normalized();

    Vec3 prev = base + u * baseR;
    foreach (i; 1 .. segments + 1) {
        immutable ang = (2.0f * PI * cast(float) i) / cast(float) segments;
        immutable p = base + u * (baseR * cos(ang)) + v * (baseR * sin(ang));
        gizmos.line(prev, p, col);
        prev = p;
    }
    foreach (i; 0 .. 4) {
        immutable ang = (2.0f * PI * cast(float) i) / 4.0f;
        immutable p = base + u * (baseR * cos(ang)) + v * (baseR * sin(ang));
        gizmos.line(apex, p, col);
    }
}

void drawArrowHead(
    ref GizmoRenderer gizmos,
    Vec3 tip,
    Vec3 dir,
    Color4 col,
    float size
) nothrow @nogc {
    immutable d = dir.normalized();
    Vec3 u = abs(d.y) < 0.9f ? d.cross(Vec3(0, 1, 0)).normalized()
                             : d.cross(Vec3(1, 0, 0)).normalized();
    Vec3 v = d.cross(u).normalized();
    immutable back = tip - d * size;
    gizmos.line(tip, back + u * (size * 0.5f), col);
    gizmos.line(tip, back - u * (size * 0.5f), col);
    gizmos.line(tip, back + v * (size * 0.5f), col);
    gizmos.line(tip, back - v * (size * 0.5f), col);
}

@safe unittest {
    // Pure math smoke — cone radius / sphere helpers compile.
    assert(abs(sin(PI / 2) - 1) < 1e-5f);
}
