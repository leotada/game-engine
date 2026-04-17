// Jolt — Geometry/OrientedBox port (rotation/translation matrix + half-extents).
//
// Source: ref/JoltPhysics/Jolt/Geometry/OrientedBox.h + .cpp.
module engine.jph.geometry.orientedbox;

import std.math : fabs;
import engine.jph.math.vec3;
import engine.jph.math.vec4;
import engine.jph.math.mat44;
import engine.jph.geometry.aabox;

@safe:

struct OrientedBox {
@safe:
    Mat44 mOrientation;
    Vec3  mHalfExtents;

    this(Mat44 inOrientation, Vec3 inHalfExtents) pure nothrow @nogc {
        mOrientation = inOrientation;
        mHalfExtents = inHalfExtents;
    }
    this(Mat44 inOrientation, const AABox inBox) pure nothrow @nogc {
        mOrientation = inOrientation.PreTranslated(inBox.GetCenter());
        mHalfExtents = inBox.GetExtent();
    }

    bool Overlaps(const AABox inBox, float inEpsilon = 1.0e-6f) const pure nothrow @nogc {
        // Real-Time Collision Detection - Christer Ericson, 4.4.1.
        Vec3 a_center = inBox.GetCenter();
        Vec3 a_half_extents = inBox.GetExtent();

        Mat44 rot = Mat44(mOrientation.GetColumn4(0),
                          mOrientation.GetColumn4(1),
                          mOrientation.GetColumn4(2),
                          mOrientation.GetColumn4(3) - Vec4(a_center, 0));

        Vec3 epsilon = Vec3.sReplicate(inEpsilon);
        Vec3[3] abs_r = [rot.GetAxisX().Abs() + epsilon,
                         rot.GetAxisY().Abs() + epsilon,
                         rot.GetAxisZ().Abs() + epsilon];

        float ra, rb;
        foreach (i; 0 .. 3) {
            ra = a_half_extents[i];
            rb = mHalfExtents[0]*abs_r[0][i] + mHalfExtents[1]*abs_r[1][i] + mHalfExtents[2]*abs_r[2][i];
            if (fabs(rot(i, 3)) > ra + rb) return false;
        }
        foreach (i; 0 .. 3) {
            ra = a_half_extents.Dot(abs_r[i]);
            rb = mHalfExtents[i];
            if (fabs(rot.GetTranslation().Dot(rot.GetColumn3(i))) > ra + rb) return false;
        }

        // Cross-product axes.
        ra = a_half_extents[1]*abs_r[0][2] + a_half_extents[2]*abs_r[0][1];
        rb = mHalfExtents[1]*abs_r[2][0] + mHalfExtents[2]*abs_r[1][0];
        if (fabs(rot(2, 3)*rot(1, 0) - rot(1, 3)*rot(2, 0)) > ra + rb) return false;

        ra = a_half_extents[1]*abs_r[1][2] + a_half_extents[2]*abs_r[1][1];
        rb = mHalfExtents[0]*abs_r[2][0] + mHalfExtents[2]*abs_r[0][0];
        if (fabs(rot(2, 3)*rot(1, 1) - rot(1, 3)*rot(2, 1)) > ra + rb) return false;

        ra = a_half_extents[1]*abs_r[2][2] + a_half_extents[2]*abs_r[2][1];
        rb = mHalfExtents[0]*abs_r[1][0] + mHalfExtents[1]*abs_r[0][0];
        if (fabs(rot(2, 3)*rot(1, 2) - rot(1, 3)*rot(2, 2)) > ra + rb) return false;

        ra = a_half_extents[0]*abs_r[0][2] + a_half_extents[2]*abs_r[0][0];
        rb = mHalfExtents[1]*abs_r[2][1] + mHalfExtents[2]*abs_r[1][1];
        if (fabs(rot(0, 3)*rot(2, 0) - rot(2, 3)*rot(0, 0)) > ra + rb) return false;

        ra = a_half_extents[0]*abs_r[1][2] + a_half_extents[2]*abs_r[1][0];
        rb = mHalfExtents[0]*abs_r[2][1] + mHalfExtents[2]*abs_r[0][1];
        if (fabs(rot(0, 3)*rot(2, 1) - rot(2, 3)*rot(0, 1)) > ra + rb) return false;

        ra = a_half_extents[0]*abs_r[2][2] + a_half_extents[2]*abs_r[2][0];
        rb = mHalfExtents[0]*abs_r[1][1] + mHalfExtents[1]*abs_r[0][1];
        if (fabs(rot(0, 3)*rot(2, 2) - rot(2, 3)*rot(0, 2)) > ra + rb) return false;

        ra = a_half_extents[0]*abs_r[0][1] + a_half_extents[1]*abs_r[0][0];
        rb = mHalfExtents[1]*abs_r[2][2] + mHalfExtents[2]*abs_r[1][2];
        if (fabs(rot(1, 3)*rot(0, 0) - rot(0, 3)*rot(1, 0)) > ra + rb) return false;

        ra = a_half_extents[0]*abs_r[1][1] + a_half_extents[1]*abs_r[1][0];
        rb = mHalfExtents[0]*abs_r[2][2] + mHalfExtents[2]*abs_r[0][2];
        if (fabs(rot(1, 3)*rot(0, 1) - rot(0, 3)*rot(1, 1)) > ra + rb) return false;

        ra = a_half_extents[0]*abs_r[2][1] + a_half_extents[1]*abs_r[2][0];
        rb = mHalfExtents[0]*abs_r[1][2] + mHalfExtents[1]*abs_r[0][2];
        if (fabs(rot(1, 3)*rot(0, 2) - rot(0, 3)*rot(1, 2)) > ra + rb) return false;

        return true;
    }

    bool Overlaps(const OrientedBox inBox, float inEpsilon = 1.0e-6f) const pure nothrow @nogc {
        Mat44 rot = mOrientation.InversedRotationTranslation() * inBox.mOrientation;
        Vec3 epsilon = Vec3.sReplicate(inEpsilon);
        Vec3[3] abs_r = [rot.GetAxisX().Abs() + epsilon,
                         rot.GetAxisY().Abs() + epsilon,
                         rot.GetAxisZ().Abs() + epsilon];

        float ra, rb;
        foreach (i; 0 .. 3) {
            ra = mHalfExtents[i];
            rb = inBox.mHalfExtents[0]*abs_r[0][i] + inBox.mHalfExtents[1]*abs_r[1][i] + inBox.mHalfExtents[2]*abs_r[2][i];
            if (fabs(rot(i, 3)) > ra + rb) return false;
        }
        foreach (i; 0 .. 3) {
            ra = mHalfExtents.Dot(abs_r[i]);
            rb = inBox.mHalfExtents[i];
            if (fabs(rot.GetTranslation().Dot(rot.GetColumn3(i))) > ra + rb) return false;
        }

        ra = mHalfExtents[1]*abs_r[0][2] + mHalfExtents[2]*abs_r[0][1];
        rb = inBox.mHalfExtents[1]*abs_r[2][0] + inBox.mHalfExtents[2]*abs_r[1][0];
        if (fabs(rot(2, 3)*rot(1, 0) - rot(1, 3)*rot(2, 0)) > ra + rb) return false;

        ra = mHalfExtents[1]*abs_r[1][2] + mHalfExtents[2]*abs_r[1][1];
        rb = inBox.mHalfExtents[0]*abs_r[2][0] + inBox.mHalfExtents[2]*abs_r[0][0];
        if (fabs(rot(2, 3)*rot(1, 1) - rot(1, 3)*rot(2, 1)) > ra + rb) return false;

        ra = mHalfExtents[1]*abs_r[2][2] + mHalfExtents[2]*abs_r[2][1];
        rb = inBox.mHalfExtents[0]*abs_r[1][0] + inBox.mHalfExtents[1]*abs_r[0][0];
        if (fabs(rot(2, 3)*rot(1, 2) - rot(1, 3)*rot(2, 2)) > ra + rb) return false;

        ra = mHalfExtents[0]*abs_r[0][2] + mHalfExtents[2]*abs_r[0][0];
        rb = inBox.mHalfExtents[1]*abs_r[2][1] + inBox.mHalfExtents[2]*abs_r[1][1];
        if (fabs(rot(0, 3)*rot(2, 0) - rot(2, 3)*rot(0, 0)) > ra + rb) return false;

        ra = mHalfExtents[0]*abs_r[1][2] + mHalfExtents[2]*abs_r[1][0];
        rb = inBox.mHalfExtents[0]*abs_r[2][1] + inBox.mHalfExtents[2]*abs_r[0][1];
        if (fabs(rot(0, 3)*rot(2, 1) - rot(2, 3)*rot(0, 1)) > ra + rb) return false;

        ra = mHalfExtents[0]*abs_r[2][2] + mHalfExtents[2]*abs_r[2][0];
        rb = inBox.mHalfExtents[0]*abs_r[1][1] + inBox.mHalfExtents[1]*abs_r[0][1];
        if (fabs(rot(0, 3)*rot(2, 2) - rot(2, 3)*rot(0, 2)) > ra + rb) return false;

        ra = mHalfExtents[0]*abs_r[0][1] + mHalfExtents[1]*abs_r[0][0];
        rb = inBox.mHalfExtents[1]*abs_r[2][2] + inBox.mHalfExtents[2]*abs_r[1][2];
        if (fabs(rot(1, 3)*rot(0, 0) - rot(0, 3)*rot(1, 0)) > ra + rb) return false;

        ra = mHalfExtents[0]*abs_r[1][1] + mHalfExtents[1]*abs_r[1][0];
        rb = inBox.mHalfExtents[0]*abs_r[2][2] + inBox.mHalfExtents[2]*abs_r[0][2];
        if (fabs(rot(1, 3)*rot(0, 1) - rot(0, 3)*rot(1, 1)) > ra + rb) return false;

        ra = mHalfExtents[0]*abs_r[2][1] + mHalfExtents[1]*abs_r[2][0];
        rb = inBox.mHalfExtents[0]*abs_r[1][2] + inBox.mHalfExtents[1]*abs_r[0][2];
        if (fabs(rot(1, 3)*rot(0, 2) - rot(0, 3)*rot(1, 2)) > ra + rb) return false;

        return true;
    }
}
