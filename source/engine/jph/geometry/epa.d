// Jolt — Geometry/EPAPenetrationDepth.h port.
//
// Expanding Polytope Algorithm. Two-stage API: GJK first reports
// NotColliding / Colliding / Indeterminate; the latter triggers EPA which
// expands a convex hull of the Minkowski difference until the closest
// face to the origin is found.
//
// Differences from the C++ original:
//  * Triangles are referenced by `int` handles (the EPAConvexHullBuilder
//    pool index), not pointers.
//  * Templated support objects are passed via `ref const(...)` instead of
//    C++ references.
//
// Source: ref/JoltPhysics/Jolt/Geometry/EPAPenetrationDepth.h.
module engine.jph.geometry.epa;

import std.math : sqrt;
import engine.jph.math.vec3;
import engine.jph.math.mat44;
import engine.jph.math.quat : Quat;
import engine.jph.math.scalar : Square, DegreesToRadians;
import engine.jph.geometry.gjk : GJKClosestPoint;
import engine.jph.geometry.convexsupport : AddConvexRadius, TransformedConvexObject;
import engine.jph.geometry.epa_hull;

@safe:

enum int cMaxPointsToIncludeOriginInHull = 32;
static assert(cMaxPointsToIncludeOriginInHull < cMaxPoints);

/// EStatus mirrors `EPAPenetrationDepth::EStatus`.
enum EStatus {
    NotColliding,
    Colliding,
    Indeterminate,
}

// Locally-scoped @trusted helpers: we own these arrays and only need raw
// pointers so GJK can write into them via memcpy. The mY pointer requires
// the array to be non-empty; callers must resize it first.
private Vec3* simplexFirstY(ref SupportPoints s) @trusted pure nothrow @nogc {
    assert(s.mY.size() > 0);
    return &s.mY.data()[0];
}
private Vec3* simplexFirstP(ref SupportPoints s) @trusted pure nothrow @nogc {
    return s.mP.ptr;
}
private Vec3* simplexFirstQ(ref SupportPoints s) @trusted pure nothrow @nogc {
    return s.mQ.ptr;
}

/// Holds the support points (Minkowski difference plus the per-shape
/// support vertices) used by the EPA hull.
struct SupportPoints {
@safe:
    @disable this(this);

    EPAPoints mY;
    Vec3[cMaxPoints] mP;
    Vec3[cMaxPoints] mQ;

    /// Compute the support of the Minkowski difference in `inDirection`,
    /// store both per-shape support vertices and the difference.
    Vec3 Add(A, B)(ref const A inA, ref const B inB, Vec3 inDirection, ref int outIndex) {
        Vec3 p = inA.GetSupport(inDirection);
        Vec3 q = inB.GetSupport(-inDirection);
        Vec3 w = p - q;
        outIndex = cast(int) mY.size();
        mY.push_back(w);
        mP[cast(uint) outIndex] = p;
        mQ[cast(uint) outIndex] = q;
        return w;
    }
}

/// Driver for GJK + EPA. Holds the GJK state across the two steps so that
/// EPA can consume the GJK simplex.
struct EPAPenetrationDepth {
@safe:
    @disable this(this);

    GJKClosestPoint mGJK;

    // -- Step 1: GJK ----------------------------------------------------------

    EStatus GetPenetrationDepthStepGJK(AE, BE)(
            ref const AE inAExcl, float inConvexRadiusA,
            ref const BE inBExcl, float inConvexRadiusB,
            float inTolerance,
            ref Vec3 ioV, ref Vec3 outPointA, ref Vec3 outPointB) {
        assert(!ioV.IsNearZero(), "ioV must be non-zero (likely a degenerate triangle)");

        immutable float combined = inConvexRadiusA + inConvexRadiusB;
        immutable float combinedSq = combined * combined;
        immutable float distSq = mGJK.GetClosestPoints(inAExcl, inBExcl, inTolerance,
                                                       combinedSq, ioV, outPointA, outPointB);
        if (distSq > combinedSq)
            return EStatus.NotColliding;
        if (distSq > 0.0f) {
            // Inside convex radius: pull contact points back to true surfaces.
            immutable float vLen = cast(float) sqrt(cast(double) distSq);
            outPointA = outPointA + ioV * (inConvexRadiusA / vLen);
            outPointB = outPointB - ioV * (inConvexRadiusB / vLen);
            return EStatus.Colliding;
        }
        return EStatus.Indeterminate;
    }

    // -- Step 2: EPA ----------------------------------------------------------

    bool GetPenetrationDepthStepEPA(AI, BI)(
            ref const AI inAIncl, ref const BI inBIncl, float inTolerance,
            ref Vec3 outV, ref Vec3 outPointA, ref Vec3 outPointB) {
        assert(inTolerance >= float.epsilon);

        SupportPoints support;

        // Pull the simplex out of GJK directly into our support arrays.
        // Resize to capacity first so the underlying buffer is addressable;
        // we'll trim back down once we know how many points GJK wrote.
        support.mY.resize(cMaxPoints);
        uint nPoints;
        mGJK.GetClosestPointsSimplex(simplexFirstY(support), simplexFirstP(support),
                                     simplexFirstQ(support), nPoints);
        support.mY.resize(nPoints);

        // Pad up to >=4 points so we have a hull with non-zero volume.
        switch (support.mY.size()) {
            case 1:
                // Single point at the origin (otherwise GJK would have
                // already exited). Replace it with a tetrahedron.
                assert(support.mY[0].IsNearZero(Square(inTolerance)));
                support.mY.pop_back();
                int p1, p2, p3, p4;
                support.Add(inAIncl, inBIncl, Vec3( 0,  1,  0), p1);
                support.Add(inAIncl, inBIncl, Vec3(-1, -1, -1), p2);
                support.Add(inAIncl, inBIncl, Vec3( 1, -1, -1), p3);
                support.Add(inAIncl, inBIncl, Vec3( 0, -1,  1), p4);
                assert(p1 == 0 && p2 == 1 && p3 == 2 && p4 == 3);
                break;
            case 2:
                // Edge: build a triangle around it by rotating a perpendicular
                // axis 120° three times.
                immutable Vec3 axis = (support.mY[1] - support.mY[0]).Normalized();
                immutable Mat44 rot = Mat44.sRotation(axis, DegreesToRadians(120.0f));
                immutable Vec3 d1 = axis.GetNormalizedPerpendicular();
                immutable Vec3 d2 = rot * d1;
                immutable Vec3 d3 = rot * d2;
                int q1, q2, q3;
                support.Add(inAIncl, inBIncl, d1, q1);
                support.Add(inAIncl, inBIncl, d2, q2);
                support.Add(inAIncl, inBIncl, d3, q3);
                assert(q1 == 2 && q2 == 3 && q3 == 4);
                break;
            case 3:
            case 4:
                break;
            default:
                assert(0, "unexpected simplex size");
        }
        assert(support.mY.size() >= 3);

        auto hull = EPAConvexHullBuilder(support.mY);
        hull.Initialize(0, 1, 2);

        // Add any remaining initial simplex points (3rd / 4th).
        for (uint i = 3; i < support.mY.size(); ++i) {
            float distSq;
            immutable int t = hull.FindFacingTriangle(support.mY[i], distSq);
            if (t != -1) {
                NewTriangles newTris;
                if (!hull.AddPoint(t, cast(int) i, float.max, newTris))
                    return false;
            }
        }

        // -- Phase A: ensure the origin is inside the hull --------------------
        for (;;) {
            int t = hull.PeekClosestTriangleInQueue();
            if (hull.tri(t).mRemoved) {
                hull.PopClosestTriangleFromQueue();
                if (!hull.HasNextTriangle())
                    return false;
                hull.FreeTriangle(t);
                continue;
            }
            if (hull.tri(t).mClosestLenSq >= 0.0f)
                break;

            hull.PopClosestTriangleFromQueue();

            int newIdx;
            immutable Vec3 w = support.Add(inAIncl, inBIncl, hull.tri(t).mNormal, newIdx);

            NewTriangles newTris;
            if (!hull.tri(t).IsFacing(w) || !hull.AddPoint(t, newIdx, float.max, newTris))
                return false;

            assert(hull.tri(t).mRemoved);
            hull.FreeTriangle(t);

            if (!hull.HasNextTriangle()
                    || support.mY.size() >= cMaxPointsToIncludeOriginInHull)
                return false;
        }

        // -- Phase B: expand until the closest face stops moving --------------
        float closestDistSq = float.max;
        int last = -1;
        bool flipVSign = false;

        do {
            int t = hull.PopClosestTriangleFromQueue();
            if (hull.tri(t).mRemoved) {
                hull.FreeTriangle(t);
                continue;
            }
            if (hull.tri(t).mClosestLenSq >= closestDistSq)
                break;

            if (last != -1)
                hull.FreeTriangle(last);
            last = t;

            int newIdx;
            immutable Vec3 w = support.Add(inAIncl, inBIncl, hull.tri(t).mNormal, newIdx);
            immutable float dot = hull.tri(t).mNormal.Dot(w);
            if (dot < 0.0f)
                return false;
            immutable float distSq = Square(dot) / hull.tri(t).mNormal.LengthSq();

            if (distSq - hull.tri(t).mClosestLenSq < hull.tri(t).mClosestLenSq * inTolerance)
                break;

            if (distSq < closestDistSq)
                closestDistSq = distSq;

            if (!hull.tri(t).IsFacing(w))
                break;

            NewTriangles newTris;
            if (!hull.AddPoint(t, newIdx, closestDistSq, newTris))
                break;

            // Defect detection: if any new triangle faces the origin, the
            // hull has degenerated. Decide whether to flip the sign before
            // bailing out.
            bool defect = false;
            foreach (k; 0 .. newTris.size()) {
                if (hull.tri(newTris[k]).IsFacingOrigin()) {
                    defect = true;
                    break;
                }
            }
            if (defect) {
                immutable Vec3 w2 = inAIncl.GetSupport(-hull.tri(t).mNormal)
                                  - inBIncl.GetSupport( hull.tri(t).mNormal);
                immutable float dot2 = -hull.tri(t).mNormal.Dot(w2);
                if (dot2 < dot)
                    flipVSign = true;
                break;
            }
        }
        while (hull.HasNextTriangle() && support.mY.size() < cMaxPoints);

        if (last == -1)
            return false;

        // outV = projection of the closest face's centroid along its normal.
        outV = (hull.tri(last).mCentroid.Dot(hull.tri(last).mNormal)
                / hull.tri(last).mNormal.LengthSq()) * hull.tri(last).mNormal;
        if (outV.IsNearZero())
            return false;
        if (flipVSign)
            outV = -outV;

        // Recover contact points on A and B via the stored barycentric
        // lambdas of the closest face.
        immutable int i0 = hull.tri(last).mEdge[0].mStartIdx;
        immutable int i1 = hull.tri(last).mEdge[1].mStartIdx;
        immutable int i2 = hull.tri(last).mEdge[2].mStartIdx;
        immutable Vec3 p0 = support.mP[cast(uint) i0];
        immutable Vec3 p1 = support.mP[cast(uint) i1];
        immutable Vec3 p2 = support.mP[cast(uint) i2];
        immutable Vec3 q0 = support.mQ[cast(uint) i0];
        immutable Vec3 q1 = support.mQ[cast(uint) i1];
        immutable Vec3 q2 = support.mQ[cast(uint) i2];

        immutable float l0 = hull.tri(last).mLambda[0];
        immutable float l1 = hull.tri(last).mLambda[1];
        if (hull.tri(last).mLambdaRelativeTo0) {
            outPointA = p0 + l0 * (p1 - p0) + l1 * (p2 - p0);
            outPointB = q0 + l0 * (q1 - q0) + l1 * (q2 - q0);
        } else {
            outPointA = p1 + l0 * (p0 - p1) + l1 * (p2 - p1);
            outPointB = q1 + l0 * (q0 - q1) + l1 * (q2 - q1);
        }
        return true;
    }

    // -- Combined GJK + EPA ---------------------------------------------------

    bool GetPenetrationDepth(AE, AI, BE, BI)(
            ref const AE inAExcl, ref const AI inAIncl, float inConvexRadiusA,
            ref const BE inBExcl, ref const BI inBIncl, float inConvexRadiusB,
            float inCollisionToleranceSq, float inPenetrationTolerance,
            ref Vec3 ioV, ref Vec3 outPointA, ref Vec3 outPointB) {
        final switch (GetPenetrationDepthStepGJK(inAExcl, inConvexRadiusA,
                                                 inBExcl, inConvexRadiusB,
                                                 inCollisionToleranceSq,
                                                 ioV, outPointA, outPointB)) {
            case EStatus.Colliding:
                return true;
            case EStatus.NotColliding:
                return false;
            case EStatus.Indeterminate:
                return GetPenetrationDepthStepEPA(inAIncl, inBIncl, inPenetrationTolerance,
                                                  ioV, outPointA, outPointB);
        }
    }

    // -- Cast-shape entry -----------------------------------------------------

    bool CastShape(A, B)(Mat44 inStart, Vec3 inDirection,
                         float inCollisionTolerance, float inPenetrationTolerance,
                         ref const A inA, ref const B inB,
                         float inConvexRadiusA, float inConvexRadiusB,
                         bool inReturnDeepestPoint, ref float ioLambda,
                         ref Vec3 outPointA, ref Vec3 outPointB,
                         ref Vec3 outContactNormal) {
        if (!mGJK.CastShape(inStart, inDirection, inCollisionTolerance, inA, inB,
                            inConvexRadiusA, inConvexRadiusB, ioLambda,
                            outPointA, outPointB, outContactNormal))
            return false;

        immutable bool normalInvalid =
                outContactNormal.IsNearZero(Square(inCollisionTolerance));

        if (inReturnDeepestPoint
                && ioLambda == 0.0f
                && (inConvexRadiusA + inConvexRadiusB == 0.0f || normalInvalid)) {
            auto a = AddConvexRadius!A(&inA, inConvexRadiusA);
            auto b = AddConvexRadius!B(&inB, inConvexRadiusB);
            auto ta = TransformedConvexObject!(AddConvexRadius!A)(inStart, &a);
            if (!GetPenetrationDepthStepEPA(ta, b, inPenetrationTolerance,
                                            outContactNormal, outPointA, outPointB))
                outContactNormal = inDirection;
        } else if (normalInvalid) {
            outContactNormal = inDirection;
        }
        return true;
    }
}

unittest {
    // Sanity: two overlapping spheres → EPA reports a non-zero penetration
    // along the connecting axis.
    import engine.jph.geometry.convexsupport : PointConvexSupport;
    import engine.jph.geometry.sphere : Sphere;

    // Build a custom sphere convex with GetSupport.
    static struct UnitSphereAt {
    @safe:
        Vec3 c;
        float r;
        Vec3 GetSupport(Vec3 d) const pure nothrow @nogc {
            immutable Vec3 n = d.NormalizedOr(Vec3(1, 0, 0));
            return c + r * n;
        }
    }

    auto a = UnitSphereAt(Vec3( 0.0f, 0, 0), 1.0f);
    auto b = UnitSphereAt(Vec3( 1.5f, 0, 0), 1.0f);  // overlapping by 0.5

    EPAPenetrationDepth epa;
    Vec3 v = Vec3(1, 0, 0);
    Vec3 pa, pb;
    immutable s = epa.GetPenetrationDepthStepGJK(a, 0.0f, b, 0.0f, 1.0e-4f, v, pa, pb);
    assert(s == EStatus.Indeterminate);

    immutable bool ok = epa.GetPenetrationDepthStepEPA(a, b, 1.0e-3f, v, pa, pb);
    assert(ok);

    // Penetration vector should point roughly along ±X with magnitude ~0.5.
    immutable float pen = (pb - pa).Length();
    assert(pen > 0.4f && pen < 0.6f);
}
