// Jolt — box-vs-box contact generation with face clipping for up to 4 stable
// contact points per pair.
//
// Pipeline:
//   1. OrientedBox broad overlap test (early exit).
//   2. GJK+EPA to find the penetration axis and an initial contact point pair.
//   3. Face selection: choose the reference face on box1 (most aligned with
//      the contact normal) and the incident face on box2 (most aligned with
//      -normal), each with 4 world-space vertices.
//   4. Sutherland-Hodgman clipping of the incident face against the 4 edge
//      half-spaces of the reference face (ClipPolyVsPoly port from ClipPoly.h).
//   5. Project each surviving clipped point onto the reference face plane
//      along the penetration axis to get the paired point on box1, filter by
//      distance tolerance.
//   6. Prune to cMaxContactPoints (≤4) using the area-maximising heuristic
//      from ManifoldBetweenTwoFaces.cpp (PruneContactPoints).
//   7. Fallback: if clipping produced nothing, emit the single EPA contact.
//
// References:
//   ref/JoltPhysics/Jolt/Geometry/AABox.h               GetSupportingFace
//   ref/JoltPhysics/Jolt/Geometry/ClipPoly.h             ClipPolyVsPlane/Poly
//   ref/JoltPhysics/Jolt/Physics/Collision/ManifoldBetweenTwoFaces.cpp
module engine.jph.physics.collision.collide_box_vs_box;

import std.math : fabs;
import engine.jph.geometry.aabox : AABox;
import engine.jph.geometry.convexsupport : AddConvexRadius, TransformedConvexObject;
import engine.jph.geometry.epa : EPAPenetrationDepth;
import engine.jph.geometry.orientedbox : OrientedBox;
import engine.jph.math.mat44 : Mat44;
import engine.jph.math.quat : Quat;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.body : Body;
import engine.jph.physics.body.body_creation_settings : BodyCreationSettings;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.body.motionproperties : MotionProperties;
import engine.jph.physics.body.motiontype : EMotionType;
import engine.jph.physics.collision.collide_shape : CollideShapeSettings,
                                                    ContactManifold,
                                                    InitializeContactManifold,
                                                    cMaxContactPoints;
import engine.jph.physics.shape.box_shape : BoxShape;

@safe:

// ---------------------------------------------------------------------------
// Private helpers — all pure nothrow @nogc @safe
// ---------------------------------------------------------------------------

private Vec3 reduceHalfExtent(Vec3 inHalfExtent, float inConvexRadius) pure nothrow @nogc {
    immutable Vec3 radius = Vec3.sReplicate(inConvexRadius);
    return Vec3.sMax(inHalfExtent - radius, Vec3.sZero());
}

/// Port of AABox::GetSupportingFace (ref/JoltPhysics/Jolt/Geometry/AABox.h L237).
///
/// Returns the 4 vertices of the face whose outward normal is most anti-aligned
/// with `dir` (local-space direction).  Vertices are in CCW order when viewed
/// from the PENETRATION-AXIS direction (penAxis = -normal = body1→body2).
///
/// Calling conventions used by CollideBoxVsBox:
///   reference face (box1): dir = transform1.Multiply3x3Transposed(normal)
///   incident   face (box2): dir = transform2.Multiply3x3Transposed(-normal)
private Vec3[4] getSupportingFaceLocal(const ref AABox box,
                                       Vec3 dir) pure nothrow @nogc {
    immutable int axis = dir.Abs().GetHighestComponentIndex();
    Vec3[4] v = void;
    if (dir[cast(uint) axis] < 0.0f) {
        switch (axis) {
        case 0:
            v[0] = Vec3(box.mMax.GetX(), box.mMin.GetY(), box.mMin.GetZ());
            v[1] = Vec3(box.mMax.GetX(), box.mMax.GetY(), box.mMin.GetZ());
            v[2] = Vec3(box.mMax.GetX(), box.mMax.GetY(), box.mMax.GetZ());
            v[3] = Vec3(box.mMax.GetX(), box.mMin.GetY(), box.mMax.GetZ());
            break;
        case 1:
            v[0] = Vec3(box.mMin.GetX(), box.mMax.GetY(), box.mMin.GetZ());
            v[1] = Vec3(box.mMin.GetX(), box.mMax.GetY(), box.mMax.GetZ());
            v[2] = Vec3(box.mMax.GetX(), box.mMax.GetY(), box.mMax.GetZ());
            v[3] = Vec3(box.mMax.GetX(), box.mMax.GetY(), box.mMin.GetZ());
            break;
        default: // axis == 2
            v[0] = Vec3(box.mMin.GetX(), box.mMin.GetY(), box.mMax.GetZ());
            v[1] = Vec3(box.mMax.GetX(), box.mMin.GetY(), box.mMax.GetZ());
            v[2] = Vec3(box.mMax.GetX(), box.mMax.GetY(), box.mMax.GetZ());
            v[3] = Vec3(box.mMin.GetX(), box.mMax.GetY(), box.mMax.GetZ());
            break;
        }
    } else {
        switch (axis) {
        case 0:
            v[0] = Vec3(box.mMin.GetX(), box.mMin.GetY(), box.mMin.GetZ());
            v[1] = Vec3(box.mMin.GetX(), box.mMin.GetY(), box.mMax.GetZ());
            v[2] = Vec3(box.mMin.GetX(), box.mMax.GetY(), box.mMax.GetZ());
            v[3] = Vec3(box.mMin.GetX(), box.mMax.GetY(), box.mMin.GetZ());
            break;
        case 1:
            v[0] = Vec3(box.mMin.GetX(), box.mMin.GetY(), box.mMin.GetZ());
            v[1] = Vec3(box.mMax.GetX(), box.mMin.GetY(), box.mMin.GetZ());
            v[2] = Vec3(box.mMax.GetX(), box.mMin.GetY(), box.mMax.GetZ());
            v[3] = Vec3(box.mMin.GetX(), box.mMin.GetY(), box.mMax.GetZ());
            break;
        default: // axis == 2
            v[0] = Vec3(box.mMin.GetX(), box.mMin.GetY(), box.mMin.GetZ());
            v[1] = Vec3(box.mMin.GetX(), box.mMax.GetY(), box.mMin.GetZ());
            v[2] = Vec3(box.mMax.GetX(), box.mMax.GetY(), box.mMin.GetZ());
            v[3] = Vec3(box.mMax.GetX(), box.mMin.GetY(), box.mMin.GetZ());
            break;
        }
    }
    return v;
}

/// Sutherland-Hodgman single halfspace clip.
/// Port of ClipPolyVsPlane (ref/JoltPhysics/Jolt/Geometry/ClipPoly.h).
///
/// "Inside" = (planeOrigin − point) · planeNormal < 0.
/// Returns the number of points written to outBuf (max 8).
private int clipPolyVsPlane(scope const Vec3[] inPoly,
                             Vec3 planeOrigin,
                             Vec3 planeNormal,
                             ref Vec3[8] outBuf) pure nothrow @nogc {
    immutable int n = cast(int) inPoly.length;
    if (n < 1)
        return 0;

    int outCount = 0;
    Vec3  e1       = inPoly[n - 1];
    float prevNum  = (planeOrigin - e1).Dot(planeNormal);
    bool  prevIn   = prevNum < 0.0f;

    foreach (j; 0 .. n) {
        immutable Vec3  e2  = inPoly[j];
        immutable float num = (planeOrigin - e2).Dot(planeNormal);
        bool curIn = num < 0.0f;

        if (curIn != prevIn) {
            // Edge crosses the plane — emit intersection
            immutable Vec3  e12   = e2 - e1;
            immutable float denom = e12.Dot(planeNormal);
            if (denom != 0.0f) {
                if (outCount < 8)
                    outBuf[outCount++] = e1 + e12 * (prevNum / denom);
            } else {
                curIn = prevIn; // parallel edge — treat as same side
            }
        }
        if (curIn && outCount < 8)
            outBuf[outCount++] = e2;

        prevNum = num;
        prevIn  = curIn;
        e1      = e2;
    }
    return outCount;
}

/// Clips the incident face against the 4 edges of the reference face.
/// Port of ClipPolyVsPoly (ref/JoltPhysics/Jolt/Geometry/ClipPoly.h).
///
/// penAxis = -normal (body1→body2 direction).  Using penAxis as the clipping-
/// polygon normal produces inward-pointing edge planes for the reference face
/// when its vertices are in CCW order from the penAxis direction (which
/// GetSupportingFace guarantees).
///
/// Returns count of result points in outBuf (0 if the faces do not overlap).
private int clipFaceVsFace(const ref Vec3[4] incFace,
                            const ref Vec3[4] refFace,
                            Vec3 penAxis,
                            ref Vec3[8] outBuf) pure nothrow @nogc {
    // Two ping-pong clip buffers — a 4-vertex polygon clipped against 4
    // half-spaces yields at most 8 vertices.
    Vec3[8][2] bufs = void;
    int[2]     counts;
    int cur = 0;

    foreach (i; 0 .. 4) bufs[0][i] = incFace[i];
    counts[0] = 4;

    foreach (i; 0 .. 4) {
        immutable Vec3 clipE1     = refFace[i];
        immutable Vec3 clipE2     = refFace[(i + 1) % 4];
        // inward edge plane normal for the reference polygon
        immutable Vec3 clipNormal = penAxis.Cross(clipE2 - clipE1);

        immutable int next    = 1 - cur;
        counts[next] = clipPolyVsPlane(bufs[cur][0 .. counts[cur]],
                                        clipE1, clipNormal, bufs[next]);
        if (counts[next] == 0)
            return 0;
        cur = next;
    }

    outBuf[0 .. counts[cur]] = bufs[cur][0 .. counts[cur]];
    return counts[cur];
}

/// Reduces a contact-point set to at most cMaxContactPoints (4) using the
/// area-maximising heuristic from PruneContactPoints in
/// ref/JoltPhysics/Jolt/Physics/Collision/ManifoldBetweenTwoFaces.cpp.
///
/// penAxis must be normalised.  Updates out1/out2/outDepth in place and
/// returns the pruned count.
private int pruneContactPoints(Vec3 penAxis,
                                scope const Vec3[]  p1,
                                scope const Vec3[]  p2,
                                scope const float[] depths,
                                ref Vec3[cMaxContactPoints]  out1,
                                ref Vec3[cMaxContactPoints]  out2,
                                ref float[cMaxContactPoints] outDepth) pure nothrow @nogc {
    immutable int n = cast(int) p1.length;
    if (n <= cast(int) cMaxContactPoints) {
        foreach (i; 0 .. n) {
            out1[i]     = p1[i];
            out2[i]     = p2[i];
            outDepth[i] = depths[i];
        }
        return n;
    }

    // Project points onto plane perpendicular to penAxis (relative to body COM,
    // which here is implicitly origin-relative).
    Vec3[8]  proj    = void;
    float[8] depthSq = void;
    foreach (i; 0 .. n) {
        proj[i]    = p1[i] - penAxis * p1[i].Dot(penAxis);
        float d2   = (p2[i] - p1[i]).LengthSq();
        depthSq[i] = d2 > 1.0e-6f ? d2 : 1.0e-6f;
    }

    // 1. Furthest from origin × deepest penetration
    int   pt1 = 0;
    float best = proj[0].LengthSq() * depthSq[0];
    foreach (i; 1 .. n) {
        immutable float v = proj[i].LengthSq() * depthSq[i];
        if (v > best) { best = v; pt1 = i; }
    }
    immutable Vec3 pt1v = proj[pt1];

    // 2. Furthest from pt1 × deepest
    int pt2 = (pt1 == 0) ? 1 : 0;
    best = (proj[pt2] - pt1v).LengthSq() * depthSq[pt2];
    foreach (i; 0 .. n) {
        if (i == pt1) continue;
        immutable float v = (proj[i] - pt1v).LengthSq() * depthSq[i];
        if (v > best) { best = v; pt2 = i; }
    }

    // 3. Extreme points on both sides of line (pt1 → pt2)
    immutable Vec3 perp = (proj[pt2] - pt1v).Cross(penAxis);
    int   pt3 = -1, pt4 = -1;
    float minVal = 0.0f, maxVal = 0.0f;
    foreach (i; 0 .. n) {
        if (i == pt1 || i == pt2) continue;
        immutable float v = perp.Dot(proj[i] - pt1v);
        if (v < minVal)      { minVal = v; pt3 = i; }
        else if (v > maxVal) { maxVal = v; pt4 = i; }
    }

    // Emit up to 4 points in polygon order
    int cnt = 0;
    out1[cnt] = p1[pt1]; out2[cnt] = p2[pt1]; outDepth[cnt] = depths[pt1]; cnt++;
    if (pt3 >= 0) { out1[cnt] = p1[pt3]; out2[cnt] = p2[pt3]; outDepth[cnt] = depths[pt3]; cnt++; }
    out1[cnt] = p1[pt2]; out2[cnt] = p2[pt2]; outDepth[cnt] = depths[pt2]; cnt++;
    if (pt4 >= 0) { out1[cnt] = p1[pt4]; out2[cnt] = p2[pt4]; outDepth[cnt] = depths[pt4]; cnt++; }
    return cnt;
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

bool CollideBoxVsBox(ref const Body inBody1,
                     ref const Body inBody2,
                     CollideShapeSettings inSettings,
                     ref ContactManifold ioManifold) nothrow @nogc {
    auto box1 = cast(const BoxShape) inBody1.GetShape();
    auto box2 = cast(const BoxShape) inBody2.GetShape();
    if (box1 is null || box2 is null)
        return false;

    immutable Vec3  halfExtent1 = box1.GetHalfExtent();
    immutable Vec3  halfExtent2 = box2.GetHalfExtent();
    immutable Mat44 transform1  = inBody1.GetCenterOfMassTransform();
    immutable Mat44 transform2  = inBody2.GetCenterOfMassTransform();

    // -----------------------------------------------------------------------
    // Broad overlap test
    // -----------------------------------------------------------------------
    immutable OrientedBox oriented1 = OrientedBox(transform1, halfExtent1);
    immutable OrientedBox oriented2 = OrientedBox(transform2, halfExtent2);
    if (!oriented1.Overlaps(oriented2))
        return false;

    // -----------------------------------------------------------------------
    // GJK + EPA — finds penetration axis and a single contact point pair
    // -----------------------------------------------------------------------
    immutable float convexRadius1 = box1.GetConvexRadius();
    immutable float convexRadius2 = box2.GetConvexRadius();
    immutable AABox localBox1 = AABox.sFromTwoPoints(
        -reduceHalfExtent(halfExtent1, convexRadius1),
         reduceHalfExtent(halfExtent1, convexRadius1));
    immutable AABox localBox2 = AABox.sFromTwoPoints(
        -reduceHalfExtent(halfExtent2, convexRadius2),
         reduceHalfExtent(halfExtent2, convexRadius2));

    auto box1WithRadius = AddConvexRadius!AABox(localBox1, convexRadius1);
    auto box2WithRadius = AddConvexRadius!AABox(localBox2, convexRadius2);
    auto box1Excl = TransformedConvexObject!AABox(transform1, localBox1);
    auto box2Excl = TransformedConvexObject!AABox(transform2, localBox2);
    auto box1Incl = TransformedConvexObject!(AddConvexRadius!AABox)(transform1, box1WithRadius);
    auto box2Incl = TransformedConvexObject!(AddConvexRadius!AABox)(transform2, box2WithRadius);

    EPAPenetrationDepth epa;
    Vec3 separatingAxis =
        inBody1.GetCenterOfMassPosition() - inBody2.GetCenterOfMassPosition();
    if (separatingAxis.IsNearZero())
        separatingAxis = Vec3.sAxisY();

    Vec3 pointOn1, pointOn2;
    if (!epa.GetPenetrationDepth(box1Excl, box1Incl, convexRadius1,
                                  box2Excl, box2Incl, convexRadius2,
                                  inSettings.mCollisionTolerance,
                                  inSettings.mPenetrationTolerance,
                                  separatingAxis,
                                  pointOn1, pointOn2))
        return false;

    // Contact normal (body2 → body1).
    // After GetPenetrationDepth, 'separatingAxis' (= ioV from GJK/EPA) has been
    // modified in-place.  GJK convention: ioV points FROM the Minkowski-diff
    // closest face TOWARD the origin = FROM body1 TOWARD body2.  The contact
    // normal is body2→body1, so we NEGATE it.  This is the correct physics
    // normal for any box orientation; the old COM-to-COM direction was only
    // valid for centred sphere-like contacts and caused lateral explosions when
    // cubes were off-centre on the floor (tilted normal → horizontal impulse).
    immutable float mtdLen = separatingAxis.Length();
    if (mtdLen <= inSettings.mPenetrationTolerance)
        return false;
    immutable Vec3  normal      = -separatingAxis / mtdLen;  // body2→body1
    immutable float singleDepth = mtdLen;

    // -----------------------------------------------------------------------
    // Face selection
    //
    // penetration axis (penAxis) = -normal = body1 → body2 direction.
    // GetSupportingFace(d) returns the face most anti-aligned with d, with
    // vertices CCW when viewed from the +penAxis direction.
    //
    // reference face on box1: facing toward body2 → dir ≈  normal in local
    // incident  face on box2: facing toward body1 → dir ≈ -normal in local
    // -----------------------------------------------------------------------
    immutable AABox fullBox1 = AABox.sFromTwoPoints(-halfExtent1, halfExtent1);
    immutable AABox fullBox2 = AABox.sFromTwoPoints(-halfExtent2, halfExtent2);

    immutable Vec3[4] face1Local =
        getSupportingFaceLocal(fullBox1, transform1.Multiply3x3Transposed( normal));
    immutable Vec3[4] face2Local =
        getSupportingFaceLocal(fullBox2, transform2.Multiply3x3Transposed(-normal));

    Vec3[4] face1World = void, face2World = void;
    foreach (i; 0 .. 4) {
        face1World[i] = transform1 * face1Local[i];
        face2World[i] = transform2 * face2Local[i];
    }

    // -----------------------------------------------------------------------
    // Sutherland-Hodgman clipping:
    //   clip incident face (box2) against edge half-spaces of reference (box1)
    //   using penAxis = -normal as the clipping-polygon outward normal
    // -----------------------------------------------------------------------
    immutable Vec3 penAxis = -normal;
    Vec3[8] clipped = void;
    immutable int clippedCount =
        clipFaceVsFace(face2World, face1World, penAxis, clipped);

    // -----------------------------------------------------------------------
    // Project clipped points onto the reference face plane along penAxis.
    //
    // Solves (ManifoldBetweenTwoFaces.cpp):
    //   p1 = p2 − distance × penAxis
    //   (p1 − planeOrigin) · planeNormal = 0
    //   → distance = (p2 − planeOrigin) · planeNormal / (penAxis · planeNormal)
    //
    // planeNormal ≈ penAxis (≈ -normal) — positive dot product guarantees
    // negative distance for penetrating contacts → depth = -distance > 0.
    // Accept when distance × |penAxis| < maxContactDist (= distance < tol,
    // since |penAxis| = 1).
    // -----------------------------------------------------------------------
    immutable Vec3  planeOrigin = face1World[0];
    immutable Vec3  planeNormal = (face1World[1] - face1World[0])
                                     .Cross(face1World[2] - face1World[0]);
    immutable float axisDotPlane = penAxis.Dot(planeNormal);

    // Buffer for validated contacts (at most 8 from clipping)
    Vec3[8]  validP1 = void, validP2 = void;
    float[8] validDepth = void;
    int      validCount = 0;

    immutable float maxContactDist = inSettings.mMaxSeparationDistance
                                   + inSettings.mPenetrationTolerance;

    if (clippedCount > 0 && fabs(axisDotPlane) > 1.0e-6f) {
        foreach (i; 0 .. clippedCount) {
            immutable Vec3  p2       = clipped[i];
            immutable float distance =
                (p2 - planeOrigin).Dot(planeNormal) / axisDotPlane;
            if (distance < maxContactDist && validCount < 8) {
                validP1[validCount]    = p2 - distance * penAxis;
                validP2[validCount]    = p2;
                validDepth[validCount] = -distance; // positive = penetrating
                validCount++;
            }
        }
    }

    // -----------------------------------------------------------------------
    // Fallback: if clipping produced no valid contacts, emit the EPA single
    // contact (vertex–face, edge–edge, or heavily tilted box).
    // -----------------------------------------------------------------------
    if (validCount == 0) {
        InitializeContactManifold(ioManifold,
                                   inBody1.GetID(), inBody2.GetID(), normal);
        return ioManifold.AddContactPoint(pointOn1, pointOn2, singleDepth);
    }

    // -----------------------------------------------------------------------
    // Populate manifold (prune if > cMaxContactPoints)
    // -----------------------------------------------------------------------
    InitializeContactManifold(ioManifold, inBody1.GetID(), inBody2.GetID(), normal);

    if (validCount <= cast(int) cMaxContactPoints) {
        foreach (i; 0 .. validCount)
            ioManifold.AddContactPoint(validP1[i], validP2[i], validDepth[i]);
    } else {
        Vec3[cMaxContactPoints]  pruned1    = void;
        Vec3[cMaxContactPoints]  pruned2    = void;
        float[cMaxContactPoints] prunedDepth = void;
        immutable int cnt = pruneContactPoints(
            penAxis,
            validP1[0 .. validCount], validP2[0 .. validCount],
            validDepth[0 .. validCount],
            pruned1, pruned2, prunedDepth);
        foreach (i; 0 .. cnt)
            ioManifold.AddContactPoint(pruned1[i], pruned2[i], prunedDepth[i]);
    }

    return !ioManifold.IsEmpty();
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

unittest {
    // Face-on-face: small cube (0.5 half-extent) sitting on top of a wide slab
    // (1×0.5×1).  Face clipping should give 4 contacts at each corner of the
    // small cube's bottom face, all at the same depth (~0.1 m).
    auto motionPool = new MotionProperties[1];
    Body body1, body2;
    BodyCreationSettings settings1 = BodyCreationSettings(
        new BoxShape(Vec3(0.5f, 0.5f, 0.5f)),
        Vec3(0.0f, 0.9f, 0.0f),
        Quat.sIdentity(),
        EMotionType.Dynamic);
    BodyCreationSettings settings2 = BodyCreationSettings(
        new BoxShape(Vec3(1.0f, 0.5f, 1.0f)),
        Vec3(0.0f, 0.0f, 0.0f),
        Quat.sIdentity(),
        EMotionType.Static);
    body1.Initialize(BodyID(1, 1), settings1, 0, &motionPool[0]);
    body2.Initialize(BodyID(2, 1), settings2, 0, null);

    ContactManifold manifold;
    assert(CollideBoxVsBox(body1, body2, CollideShapeSettings.init, manifold));
    assert(manifold.GetNumContactPoints() == 4,
           "face-on-face should give 4 contact points");
    assert(manifold.mWorldSpaceNormal.GetY() > 0.5f,
           "contact normal should point upward");
    foreach (i; 0 .. manifold.GetNumContactPoints())
        assert(manifold.GetContactPoint(i).mPenetrationDepth > 0.05f,
               "each contact depth should be > 0.05");
}

unittest {
    // Edge contact: box1 rotated 45° around Z so an edge touches the flat top
    // of box2.  Face clipping should give 1 or 2 contact points (edge–face),
    // never 0 (falls back to EPA single contact at minimum).
    // Position y=1.0: core bottom = 1.0 − √(0.45²+0.45²) ≈ 0.364 < core top
    // of box2 (0.45) → cores overlap, EPA converges.
    import std.math : PI;
    import engine.jph.math.quat : Quat;

    auto motionPool = new MotionProperties[1];
    Body body1, body2;
    BodyCreationSettings settings1 = BodyCreationSettings(
        new BoxShape(Vec3(0.5f, 0.5f, 2.0f)),
        Vec3(0.0f, 1.0f, 0.0f),
        Quat.sRotation(Vec3.sAxisZ(), cast(float)(PI / 4.0)),
        EMotionType.Dynamic);
    BodyCreationSettings settings2 = BodyCreationSettings(
        new BoxShape(Vec3(2.0f, 0.5f, 2.0f)),
        Vec3(0.0f, 0.0f, 0.0f),
        Quat.sIdentity(),
        EMotionType.Static);
    body1.Initialize(BodyID(1, 1), settings1, 0, &motionPool[0]);
    body2.Initialize(BodyID(2, 1), settings2, 0, null);

    ContactManifold manifold;
    assert(CollideBoxVsBox(body1, body2, CollideShapeSettings.init, manifold));
    assert(manifold.GetNumContactPoints() >= 1,
           "edge contact must give at least 1 contact point");
    assert(manifold.mWorldSpaceNormal.GetY() > 0.5f);
}