// Jolt — Geometry/ClosestPoint port. Closest-point-to-origin queries on
// line/triangle/tetrahedron simplices used by GJK and EPA.
//
// outSet is a bitmask describing which simplex features are part of the
// closest feature: bit i corresponds to vertex i.
//
// Source: ref/JoltPhysics/Jolt/Geometry/ClosestPoint.h.
module engine.jph.geometry.closestpoint;

import std.math : fabs;
import engine.jph.core.types;
import engine.jph.math.vec3;
import engine.jph.math.vec4;
import engine.jph.math.uvec4;
import engine.jph.math.scalar : Square, Clamp;

@safe:

/// Barycentric coordinates of origin's projection onto line (A, B):
/// `closest = A * outU + B * outV`. Returns false if the line is degenerate.
bool GetBaryCentricCoordinates(Vec3 inA, Vec3 inB, ref float outU, ref float outV) pure nothrow @nogc {
    Vec3 ab = inB - inA;
    immutable float denom = ab.LengthSq();
    if (denom < Square(float.epsilon)) {
        if (inA.LengthSq() < inB.LengthSq()) {
            outU = 1.0f; outV = 0.0f;
        } else {
            outU = 0.0f; outV = 1.0f;
        }
        return false;
    } else {
        outV = -inA.Dot(ab) / denom;
        outU = 1.0f - outV;
    }
    return true;
}

/// Barycentric coordinates on triangle (A, B, C). Includes Christer
/// Ericson's "shortest edge" rearrangement to keep the products as small
/// as possible for accuracy.
bool GetBaryCentricCoordinates(Vec3 inA, Vec3 inB, Vec3 inC,
                               ref float outU, ref float outV, ref float outW) pure nothrow @nogc {
    Vec3 v0 = inB - inA;
    Vec3 v1 = inC - inA;
    Vec3 v2 = inC - inB;

    immutable float d00 = v0.LengthSq();
    immutable float d11 = v1.LengthSq();
    immutable float d22 = v2.LengthSq();

    if (d00 <= d22) {
        immutable float d01 = v0.Dot(v1);
        immutable float denom = d00 * d11 - d01 * d01;
        if (denom < 1.0e-12f) {
            if (d00 > d11) {
                GetBaryCentricCoordinates(inA, inB, outU, outV);
                outW = 0.0f;
            } else {
                GetBaryCentricCoordinates(inA, inC, outU, outW);
                outV = 0.0f;
            }
            return false;
        } else {
            immutable float a0 = inA.Dot(v0);
            immutable float a1 = inA.Dot(v1);
            outV = (d01 * a1 - d11 * a0) / denom;
            outW = (d01 * a0 - d00 * a1) / denom;
            outU = 1.0f - outV - outW;
        }
    } else {
        immutable float d12 = v1.Dot(v2);
        immutable float denom = d11 * d22 - d12 * d12;
        if (denom < 1.0e-12f) {
            if (d11 > d22) {
                GetBaryCentricCoordinates(inA, inC, outU, outW);
                outV = 0.0f;
            } else {
                GetBaryCentricCoordinates(inB, inC, outV, outW);
                outU = 0.0f;
            }
            return false;
        } else {
            immutable float c1 = inC.Dot(v1);
            immutable float c2 = inC.Dot(v2);
            outU = (d22 * c1 - d12 * c2) / denom;
            outV = (d11 * c2 - d12 * c1) / denom;
            outW = 1.0f - outU - outV;
        }
    }
    return true;
}

/// Closest point on the line (A, B) to the origin. outSet is 0b01 if A,
/// 0b10 if B, 0b11 if interior of the segment.
Vec3 GetClosestPointOnLine(Vec3 inA, Vec3 inB, ref uint32 outSet) pure nothrow @nogc {
    float u, v;
    GetBaryCentricCoordinates(inA, inB, u, v);
    if (v <= 0.0f) {
        outSet = 0b0001;
        return inA;
    } else if (u <= 0.0f) {
        outSet = 0b0010;
        return inB;
    } else {
        outSet = 0b0011;
        return u * inA + v * inB;
    }
}

/// Closest point on triangle (A, B, C) to the origin. Bits in outSet
/// indicate which vertices are part of the closest feature
/// (1 = A, 2 = B, 4 = C; combinations encode edges/face).
///
/// `MustIncludeC` skips checks that would result in a closest feature
/// not containing C.
Vec3 GetClosestPointOnTriangle(bool MustIncludeC = false)(Vec3 inA, Vec3 inB, Vec3 inC,
                                                          ref uint32 outSet) pure nothrow @nogc {
    // Swap A and C so the shortest edge is always AB / AC. Improves accuracy
    // for the ab x ac normal calculation.
    UVec4 swap_ac;
    {
        Vec3 ac = inC - inA;
        Vec3 bc = inC - inB;
        swap_ac = Vec4.sLess(bc.DotV4(bc), ac.DotV4(ac));
    }
    Vec3 a = Vec3.sSelect(inA, inC, swap_ac);
    Vec3 c = Vec3.sSelect(inC, inA, swap_ac);

    Vec3 ab = inB - a;
    Vec3 ac = c - a;
    Vec3 n = ab.Cross(ac);
    immutable float n_len_sq = n.LengthSq();

    if (n_len_sq < 1.0e-10f) {
        // Degenerate triangle: fall back to vertex / edge tests.
        uint32 closest_set = 0b0100;
        Vec3 closest_point = inC;
        float best_dist_sq = inC.LengthSq();

        static if (!MustIncludeC) {
            immutable float a_lsq = inA.LengthSq();
            if (a_lsq < best_dist_sq) {
                closest_set = 0b0001; closest_point = inA; best_dist_sq = a_lsq;
            }
            immutable float b_lsq = inB.LengthSq();
            if (b_lsq < best_dist_sq) {
                closest_set = 0b0010; closest_point = inB; best_dist_sq = b_lsq;
            }
        }

        immutable float ac_lsq = ac.LengthSq();
        if (ac_lsq > Square(float.epsilon)) {
            immutable float vv = Clamp(-a.Dot(ac) / ac_lsq, 0.0f, 1.0f);
            Vec3 q = a + vv * ac;
            immutable float qsq = q.LengthSq();
            if (qsq < best_dist_sq) {
                closest_set = 0b0101; closest_point = q; best_dist_sq = qsq;
            }
        }

        Vec3 bc = inC - inB;
        immutable float bc_lsq = bc.LengthSq();
        if (bc_lsq > Square(float.epsilon)) {
            immutable float vv = Clamp(-inB.Dot(bc) / bc_lsq, 0.0f, 1.0f);
            Vec3 q = inB + vv * bc;
            immutable float qsq = q.LengthSq();
            if (qsq < best_dist_sq) {
                closest_set = 0b0110; closest_point = q; best_dist_sq = qsq;
            }
        }

        static if (!MustIncludeC) {
            ab = inB - inA;
            immutable float ab_lsq = ab.LengthSq();
            if (ab_lsq > Square(float.epsilon)) {
                immutable float vv = Clamp(-inA.Dot(ab) / ab_lsq, 0.0f, 1.0f);
                Vec3 q = inA + vv * ab;
                immutable float qsq = q.LengthSq();
                if (qsq < best_dist_sq) {
                    closest_set = 0b0011; closest_point = q; best_dist_sq = qsq;
                }
            }
        }

        outSet = closest_set;
        return closest_point;
    }

    // Vertex region outside A.
    Vec3 ap = -a;
    immutable float d1 = ab.Dot(ap);
    immutable float d2 = ac.Dot(ap);
    if (d1 <= 0.0f && d2 <= 0.0f) {
        outSet = swap_ac.GetX() ? 0b0100 : 0b0001;
        return a;
    }

    // Vertex region outside B.
    Vec3 bp = -inB;
    immutable float d3 = ab.Dot(bp);
    immutable float d4 = ac.Dot(bp);
    if (d3 >= 0.0f && d4 <= d3) {
        outSet = 0b0010;
        return inB;
    }

    // Edge region of AB.
    if (d1 * d4 <= d3 * d2 && d1 >= 0.0f && d3 <= 0.0f) {
        immutable float vv = d1 / (d1 - d3);
        outSet = swap_ac.GetX() ? 0b0110 : 0b0011;
        return a + vv * ab;
    }

    // Vertex region outside C.
    Vec3 cp = -c;
    immutable float d5 = ab.Dot(cp);
    immutable float d6 = ac.Dot(cp);
    if (d6 >= 0.0f && d5 <= d6) {
        outSet = swap_ac.GetX() ? 0b0001 : 0b0100;
        return c;
    }

    // Edge region of AC.
    if (d5 * d2 <= d1 * d6 && d2 >= 0.0f && d6 <= 0.0f) {
        immutable float ww = d2 / (d2 - d6);
        outSet = 0b0101;
        return a + ww * ac;
    }

    // Edge region of BC.
    immutable float d4_d3 = d4 - d3;
    immutable float d5_d6 = d5 - d6;
    if (d3 * d6 <= d5 * d4 && d4_d3 >= 0.0f && d5_d6 >= 0.0f) {
        immutable float ww = d4_d3 / (d4_d3 + d5_d6);
        outSet = swap_ac.GetX() ? 0b0011 : 0b0110;
        return inB + ww * (c - inB);
    }

    // Inside face.
    outSet = 0b0111;
    return n * (a + inB + c).Dot(n) / (3.0f * n_len_sq);
}

/// True if the origin lies on the same side as `inD` of the plane through
/// (A, B, C). Used to test if origin is inside a tetrahedron.
bool OriginOutsideOfPlane(Vec3 inA, Vec3 inB, Vec3 inC, Vec3 inD) pure nothrow @nogc {
    Vec3 n = (inB - inA).Cross(inC - inA);
    immutable float signp = inA.Dot(n);
    immutable float signd = (inD - inA).Dot(n);
    return signp * signd > -float.epsilon;
}

/// For each of the 4 tetrahedron faces, returns 0xFFFFFFFF if origin is
/// outside that face, 0 otherwise. Returns all-ones for degenerate
/// tetrahedra.
UVec4 OriginOutsideOfTetrahedronPlanes(Vec3 inA, Vec3 inB, Vec3 inC, Vec3 inD) pure nothrow @nogc {
    Vec3 ab = inB - inA;
    Vec3 ac = inC - inA;
    Vec3 ad = inD - inA;
    Vec3 bd = inD - inB;
    Vec3 bc = inC - inB;

    Vec3 ab_x_ac = ab.Cross(ac);
    Vec3 ac_x_ad = ac.Cross(ad);
    Vec3 ad_x_ab = ad.Cross(ab);
    Vec3 bd_x_bc = bd.Cross(bc);

    immutable float sp0 = inA.Dot(ab_x_ac);
    immutable float sp1 = inA.Dot(ac_x_ad);
    immutable float sp2 = inA.Dot(ad_x_ab);
    immutable float sp3 = inB.Dot(bd_x_bc);
    Vec4 signp = Vec4(sp0, sp1, sp2, sp3);

    immutable float sd0 =  ad.Dot(ab_x_ac);
    immutable float sd1 =  ab.Dot(ac_x_ad);
    immutable float sd2 =  ac.Dot(ad_x_ab);
    immutable float sd3 = -ab.Dot(bd_x_bc);
    Vec4 signd = Vec4(sd0, sd1, sd2, sd3);

    immutable int sb = signd.GetSignBits();
    switch (sb) {
        case 0:
            return Vec4.sGreaterOrEqual(signp, Vec4.sReplicate(-float.epsilon));
        case 0xf:
            return Vec4.sLessOrEqual(signp, Vec4.sReplicate(float.epsilon));
        default:
            return UVec4(0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu, 0xFFFFFFFFu);
    }
}

/// Closest point on tetrahedron (A, B, C, D) to the origin. outSet uses
/// bits 1=A, 2=B, 4=C, 8=D (interior = 0b1111).
Vec3 GetClosestPointOnTetrahedron(bool MustIncludeD = false)(
        Vec3 inA, Vec3 inB, Vec3 inC, Vec3 inD, ref uint32 outSet) pure nothrow @nogc {
    uint32 closest_set = 0b1111;
    Vec3 closest_point = Vec3.sZero();
    float best_dist_sq = float.max;

    UVec4 ooo = OriginOutsideOfTetrahedronPlanes(inA, inB, inC, inD);

    if (ooo.GetX()) {
        static if (MustIncludeD) {
            closest_set = 0b0001;
            closest_point = inA;
        } else {
            closest_point = GetClosestPointOnTriangle!false(inA, inB, inC, closest_set);
        }
        best_dist_sq = closest_point.LengthSq();
    }
    if (ooo.GetY()) {
        uint32 set;
        Vec3 q = GetClosestPointOnTriangle!MustIncludeD(inA, inC, inD, set);
        immutable float dsq = q.LengthSq();
        if (dsq < best_dist_sq) {
            best_dist_sq = dsq;
            closest_point = q;
            closest_set = (set & 0b0001) + ((set & 0b0110) << 1);
        }
    }
    if (ooo.GetZ()) {
        uint32 set;
        Vec3 q = GetClosestPointOnTriangle!MustIncludeD(inA, inB, inD, set);
        immutable float dsq = q.LengthSq();
        if (dsq < best_dist_sq) {
            best_dist_sq = dsq;
            closest_point = q;
            closest_set = (set & 0b0011) + ((set & 0b0100) << 1);
        }
    }
    if (ooo.GetW()) {
        uint32 set;
        Vec3 q = GetClosestPointOnTriangle!MustIncludeD(inB, inC, inD, set);
        immutable float dsq = q.LengthSq();
        if (dsq < best_dist_sq) {
            closest_point = q;
            closest_set = set << 1;
        }
    }

    outSet = closest_set;
    return closest_point;
}
