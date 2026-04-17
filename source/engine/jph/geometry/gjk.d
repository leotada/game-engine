// Jolt — Geometry/GJKClosestPoint port. Convex-vs-convex collision /
// distance / ray-cast / shape-cast using the GJK algorithm.
//
// Caller-provided convex objects must implement `Vec3 GetSupport(Vec3)`.
// All public methods are templated on those types. The simplex state
// (mY/mP/mQ + mNumPoints) is held on the struct between calls so EPA can
// pick it up via GetClosestPointsSimplex.
//
// Source: ref/JoltPhysics/Jolt/Geometry/GJKClosestPoint.h.
module engine.jph.geometry.gjk;

import core.stdc.string : memcpy;
import std.math : sqrt;
import engine.jph.core.types;
import engine.jph.math.vec3;
import engine.jph.math.mat44;
import engine.jph.math.scalar : Square;
import engine.jph.geometry.closestpoint;
import engine.jph.geometry.convexsupport;

@safe:

struct GJKClosestPoint {
@safe:
    @disable this(this);

    Vec3[4] mY;       // Minkowski-difference simplex points.
    Vec3[4] mP;       // Support points on shape A.
    Vec3[4] mQ;       // Support points on shape B.
    int    mNumPoints = 0;

    private bool getClosest(bool LastPointPartOfClosestFeature)(
            float inPrevVLenSq, ref Vec3 outV, ref float outVLenSq, ref uint32 outSet) const pure nothrow @nogc {
        uint32 set;
        Vec3 v;

        switch (mNumPoints) {
            case 1:
                set = 0b0001;
                v = mY[0];
                break;
            case 2:
                v = GetClosestPointOnLine(mY[0], mY[1], set);
                break;
            case 3:
                v = GetClosestPointOnTriangle!LastPointPartOfClosestFeature(mY[0], mY[1], mY[2], set);
                break;
            case 4:
                v = GetClosestPointOnTetrahedron!LastPointPartOfClosestFeature(mY[0], mY[1], mY[2], mY[3], set);
                break;
            default:
                return false;
        }

        immutable float v_len_sq = v.LengthSq();
        if (v_len_sq < inPrevVLenSq) {
            outV = v;
            outVLenSq = v_len_sq;
            outSet = set;
            return true;
        }
        return false;
    }

    private float getMaxYLengthSq() const pure nothrow @nogc {
        float l = mY[0].LengthSq();
        foreach (i; 1 .. mNumPoints) {
            immutable float li = mY[i].LengthSq();
            if (li > l) l = li;
        }
        return l;
    }

    private void updatePointSetY(uint32 inSet) pure nothrow @nogc {
        int n = 0;
        foreach (i; 0 .. mNumPoints) {
            if ((inSet & (1 << i)) != 0) { mY[n] = mY[i]; ++n; }
        }
        mNumPoints = n;
    }
    private void updatePointSetP(uint32 inSet) pure nothrow @nogc {
        int n = 0;
        foreach (i; 0 .. mNumPoints) {
            if ((inSet & (1 << i)) != 0) { mP[n] = mP[i]; ++n; }
        }
        mNumPoints = n;
    }
    private void updatePointSetPQ(uint32 inSet) pure nothrow @nogc {
        int n = 0;
        foreach (i; 0 .. mNumPoints) {
            if ((inSet & (1 << i)) != 0) { mP[n] = mP[i]; mQ[n] = mQ[i]; ++n; }
        }
        mNumPoints = n;
    }
    private void updatePointSetYPQ(uint32 inSet) pure nothrow @nogc {
        int n = 0;
        foreach (i; 0 .. mNumPoints) {
            if ((inSet & (1 << i)) != 0) {
                mY[n] = mY[i]; mP[n] = mP[i]; mQ[n] = mQ[i]; ++n;
            }
        }
        mNumPoints = n;
    }

    private void calculatePointAAndB(ref Vec3 outPointA, ref Vec3 outPointB) const pure nothrow @nogc {
        switch (mNumPoints) {
            case 1:
                outPointA = mP[0];
                outPointB = mQ[0];
                break;
            case 2: {
                float u, v;
                GetBaryCentricCoordinates(mY[0], mY[1], u, v);
                outPointA = u * mP[0] + v * mP[1];
                outPointB = u * mQ[0] + v * mQ[1];
                break;
            }
            case 3: {
                float u, v, w;
                GetBaryCentricCoordinates(mY[0], mY[1], mY[2], u, v, w);
                outPointA = u * mP[0] + v * mP[1] + w * mP[2];
                outPointB = u * mQ[0] + v * mQ[1] + w * mQ[2];
                break;
            }
            default:
                break;
        }
    }

    /// Test whether two convex shapes overlap. ioV is used as the initial
    /// search direction (pass any non-zero vector; zero is allowed but slow).
    /// Returns true on overlap. On false, ioV is a separating axis.
    bool Intersects(A, B)(ref const A inA, ref const B inB, float inTolerance, ref Vec3 ioV) {
        immutable float tolerance_sq = Square(inTolerance);
        mNumPoints = 0;

        float prev_v_len_sq = float.max;

        for (;;) {
            Vec3 p = inA.GetSupport(ioV);
            Vec3 q = inB.GetSupport(-ioV);
            Vec3 w = p - q;

            if (ioV.Dot(w) < 0.0f) return false;

            mY[mNumPoints] = w;
            ++mNumPoints;

            float v_len_sq;
            uint32 set;
            if (!getClosest!true(prev_v_len_sq, ioV, v_len_sq, set)) return false;

            if (set == 0xf) { ioV = Vec3.sZero(); return true; }
            if (v_len_sq <= tolerance_sq) { ioV = Vec3.sZero(); return true; }
            if (v_len_sq <= float.epsilon * getMaxYLengthSq()) { ioV = Vec3.sZero(); return true; }

            ioV = -ioV;
            if (prev_v_len_sq - v_len_sq <= float.epsilon * prev_v_len_sq) return false;
            prev_v_len_sq = v_len_sq;
            updatePointSetY(set);
        }
    }

    /// Compute closest points between two convex shapes. Returns squared
    /// distance, or float.max if A and B are further apart than inMaxDistSq.
    /// On contact (return 0), outPointA / outPointB are invalid.
    float GetClosestPoints(A, B)(ref const A inA, ref const B inB,
                                 float inTolerance, float inMaxDistSq,
                                 ref Vec3 ioV, ref Vec3 outPointA, ref Vec3 outPointB) {
        immutable float tolerance_sq = Square(inTolerance);
        mNumPoints = 0;

        float v_len_sq = ioV.LengthSq();
        float prev_v_len_sq = float.max;

        for (;;) {
            Vec3 p = inA.GetSupport(ioV);
            Vec3 q = inB.GetSupport(-ioV);
            Vec3 w = p - q;
            immutable float dot = ioV.Dot(w);

            if (dot < 0.0f && dot * dot > v_len_sq * inMaxDistSq) return float.max;

            mY[mNumPoints] = w;
            mP[mNumPoints] = p;
            mQ[mNumPoints] = q;
            ++mNumPoints;

            uint32 set;
            if (!getClosest!true(prev_v_len_sq, ioV, v_len_sq, set)) {
                --mNumPoints;
                break;
            }

            if (set == 0xf) {
                ioV = Vec3.sZero();
                v_len_sq = 0.0f;
                break;
            }

            updatePointSetYPQ(set);

            if (v_len_sq <= tolerance_sq) {
                ioV = Vec3.sZero();
                v_len_sq = 0.0f;
                break;
            }
            if (v_len_sq <= float.epsilon * getMaxYLengthSq()) {
                ioV = Vec3.sZero();
                v_len_sq = 0.0f;
                break;
            }

            ioV = -ioV;
            if (prev_v_len_sq - v_len_sq <= float.epsilon * prev_v_len_sq) break;
            prev_v_len_sq = v_len_sq;
        }

        calculatePointAAndB(outPointA, outPointB);
        return v_len_sq;
    }

    /// Copy the simplex state out for downstream consumers (EPA).
    void GetClosestPointsSimplex(Vec3* outY, Vec3* outP, Vec3* outQ, ref uint_ outNumPoints) const @trusted pure nothrow @nogc {
        immutable size_t bytes = Vec3.sizeof * mNumPoints;
        memcpy(outY, mY.ptr, bytes);
        memcpy(outP, mP.ptr, bytes);
        memcpy(outQ, mQ.ptr, bytes);
        outNumPoints = cast(uint_) mNumPoints;
    }

    /// Ray vs convex shape. ioLambda is the max fraction along the ray on
    /// input, the actual hit fraction on output.
    bool CastRay(A)(Vec3 inRayOrigin, Vec3 inRayDirection, float inTolerance,
                    ref const A inA, ref float ioLambda) {
        immutable float tolerance_sq = Square(inTolerance);
        mNumPoints = 0;

        float lambda = 0.0f;
        Vec3 x = inRayOrigin;
        Vec3 v = x - inA.GetSupport(Vec3.sZero());
        float v_len_sq = float.max;
        bool allow_restart = false;

        for (;;) {
            Vec3 p = inA.GetSupport(v);
            Vec3 w = x - p;

            immutable float v_dot_w = v.Dot(w);
            if (v_dot_w > 0.0f) {
                immutable float v_dot_r = v.Dot(inRayDirection);
                if (v_dot_r >= -1.0e-18f) return false;

                immutable float delta = v_dot_w / v_dot_r;
                immutable float old_lambda = lambda;
                lambda -= delta;

                if (old_lambda == lambda) break;
                if (lambda >= ioLambda) return false;

                x = inRayOrigin + lambda * inRayDirection;
                v_len_sq = float.max;
                allow_restart = true;
            }

            mP[mNumPoints] = p;
            ++mNumPoints;

            foreach (i; 0 .. mNumPoints) mY[i] = x - mP[i];

            uint32 set;
            if (!getClosest!false(v_len_sq, v, v_len_sq, set)) {
                if (!allow_restart) break;
                allow_restart = false;
                mP[0] = p;
                mNumPoints = 1;
                v = x - p;
                v_len_sq = float.max;
                continue;
            } else if (set == 0xf) {
                break;
            }

            updatePointSetP(set);
            if (v_len_sq <= tolerance_sq) break;
        }

        ioLambda = lambda;
        return true;
    }

    /// Shape cast (no convex radius variant). Reduces to a ray cast against
    /// the Minkowski difference inB - transformed_a.
    bool CastShape(A, B)(Mat44 inStart, Vec3 inDirection, float inTolerance,
                         ref const A inA, ref const B inB, ref float ioLambda) {
        TransformedConvexObject!A transformed_a = TransformedConvexObject!A(inStart, inA);
        MinkowskiDifference!(B, TransformedConvexObject!A) diff =
            MinkowskiDifference!(B, TransformedConvexObject!A)(inB, transformed_a);
        return CastRay(Vec3.sZero(), inDirection, inTolerance, diff, ioLambda);
    }

    /// Shape cast with convex radii on both shapes. On hit, outPointA /
    /// outPointB hold the contact points and outSeparatingAxis the smallest
    /// separation direction (from A to B).
    bool CastShape(A, B)(Mat44 inStart, Vec3 inDirection, float inTolerance,
                         ref const A inA, ref const B inB,
                         float inConvexRadiusA, float inConvexRadiusB,
                         ref float ioLambda, ref Vec3 outPointA, ref Vec3 outPointB,
                         ref Vec3 outSeparatingAxis) {
        float tolerance_sq = Square(inTolerance);
        immutable float sum_r = inConvexRadiusA + inConvexRadiusB;

        TransformedConvexObject!A transformed_a = TransformedConvexObject!A(inStart, inA);

        mNumPoints = 0;

        float lambda = 0.0f;
        Vec3 x = Vec3.sZero();
        Vec3 v = -inB.GetSupport(Vec3.sZero()) + transformed_a.GetSupport(Vec3.sZero());
        float v_len_sq = float.max;
        bool allow_restart = false;

        Vec3 prev_v = Vec3.sZero();

        for (;;) {
            Vec3 p = transformed_a.GetSupport(-v);
            Vec3 q = inB.GetSupport(v);
            Vec3 w = x - (q - p);

            immutable float v_dot_w = v.Dot(w) - sum_r * v.Length();
            if (v_dot_w > 0.0f) {
                immutable float v_dot_r = v.Dot(inDirection);
                if (v_dot_r >= -1.0e-18f) return false;

                immutable float delta = v_dot_w / v_dot_r;
                immutable float old_lambda = lambda;
                lambda -= delta;

                if (old_lambda == lambda) break;
                if (lambda >= ioLambda) return false;

                x = lambda * inDirection;
                v_len_sq = float.max;
                tolerance_sq = Square(inTolerance + sum_r);
                allow_restart = true;
            }

            mP[mNumPoints] = p;
            mQ[mNumPoints] = q;
            ++mNumPoints;

            foreach (i; 0 .. mNumPoints) mY[i] = x - (mQ[i] - mP[i]);

            uint32 set;
            if (!getClosest!false(v_len_sq, v, v_len_sq, set)) {
                if (!allow_restart) break;
                allow_restart = false;
                mP[0] = p; mQ[0] = q;
                mNumPoints = 1;
                v = x - q;
                v_len_sq = float.max;
                continue;
            } else if (set == 0xf) {
                break;
            }

            updatePointSetPQ(set);

            if (v_len_sq <= tolerance_sq) break;

            prev_v = v;
        }

        // Recompute Y for contact-point calculation.
        foreach (i; 0 .. mNumPoints) mY[i] = x - (mQ[i] - mP[i]);

        Vec3 normalized_v = v.NormalizedOr(Vec3.sZero());
        Vec3 cra = inConvexRadiusA * normalized_v;
        Vec3 crb = inConvexRadiusB * normalized_v;

        switch (mNumPoints) {
            case 1:
                outPointB = mQ[0] + crb;
                outPointA = lambda > 0.0f ? outPointB : mP[0] - cra;
                break;
            case 2: {
                float bu, bv;
                GetBaryCentricCoordinates(mY[0], mY[1], bu, bv);
                outPointB = bu * mQ[0] + bv * mQ[1] + crb;
                outPointA = lambda > 0.0f ? outPointB : bu * mP[0] + bv * mP[1] - cra;
                break;
            }
            case 3:
            case 4: {
                float bu, bv, bw;
                GetBaryCentricCoordinates(mY[0], mY[1], mY[2], bu, bv, bw);
                outPointB = bu * mQ[0] + bv * mQ[1] + bw * mQ[2] + crb;
                outPointA = lambda > 0.0f ? outPointB : bu * mP[0] + bv * mP[1] + bw * mP[2] - cra;
                break;
            }
            default:
                break;
        }

        outSeparatingAxis = sum_r > 0.0f ? -v : -prev_v;
        ioLambda = lambda;
        return true;
    }
}
