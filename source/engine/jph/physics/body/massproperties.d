// Jolt — Physics/Body/MassProperties.{h,cpp} port.
//
// Mass + inertia tensor describing a body for construction. The full Jolt
// implementation includes:
//   * `DecomposePrincipalMomentsOfInertia` (eigenvalue decomposition)
//   * `Rotate` (3x3 inertia rotation)
//   * `Scale` (anisotropic scaling)
// Those are deferred until a shape implementation needs them (ConvexHull /
// Compound shapes, Phase 4+). This first port covers the common construction
// helpers used by primitive shapes.
//
// Source: ref/JoltPhysics/Jolt/Physics/Body/MassProperties.h + .cpp.
module engine.jph.physics.body.massproperties;

import std.math : sqrt;
import engine.jph.math.vec3;
import engine.jph.math.vec4;
import engine.jph.math.mat44;

@safe:

/// Construction-time mass + inertia tensor for a body.
struct MassProperties {
@safe:
    /// Mass of the shape (kg). Default zero so an uninitialised
    /// MassProperties is obviously invalid.
    float mMass = 0.0f;

    /// Inertia tensor of the shape (kg m^2). Default zero matrix.
    Mat44 mInertia = Mat44.sZero();

    /// Set mass and inertia of a solid box of size `inBoxSize` and density
    /// `inDensity`. Inertia uses the standard m/12 * (size_b^2 + size_c^2)
    /// formula along each principal axis.
    void SetMassAndInertiaOfSolidBox(Vec3 inBoxSize, float inDensity) pure nothrow @nogc {
        mMass = inBoxSize.GetX() * inBoxSize.GetY() * inBoxSize.GetZ() * inDensity;

        immutable float sx2 = inBoxSize.GetX() * inBoxSize.GetX();
        immutable float sy2 = inBoxSize.GetY() * inBoxSize.GetY();
        immutable float sz2 = inBoxSize.GetZ() * inBoxSize.GetZ();
        immutable float k = mMass / 12.0f;
        mInertia = Mat44.sScale(Vec3(k * (sy2 + sz2),
                                     k * (sx2 + sz2),
                                     k * (sx2 + sy2)));
    }

    /// Set the mass to `inMass` and scale the inertia tensor accordingly.
    /// If the current mass is zero only the mass is updated (no inertia
    /// to scale).
    void ScaleToMass(float inMass) pure nothrow @nogc {
        if (mMass > 0.0f) {
            immutable float scale = inMass / mMass;
            mMass = inMass;
            foreach (i; 0 .. 3)
                mInertia.SetColumn4(i, mInertia.GetColumn4(i) * scale);
        } else {
            mMass = inMass;
        }
    }

    /// Translate the inertia using the parallel-axis theorem:
    ///   I' = I + m * (|t|^2 E - t t^T)
    /// where E is the 3x3 identity. Bottom-right of the matrix is reset
    /// to 1 since the additions perturb it.
    void Translate(Vec3 inTranslation) pure nothrow @nogc {
        immutable float dot = inTranslation.Dot(inTranslation);
        mInertia += mMass * (Mat44.sScale(Vec3(dot, dot, dot))
                           - Mat44.sOuterProduct(inTranslation, inTranslation));
        // Restore canonical bottom row.
        mInertia.SetColumn4(3, Vec4(0, 0, 0, 1));
    }

    /// Inverse of `SetMassAndInertiaOfSolidBox`: recover an equivalent box
    /// size from a diagonalised inertia tensor.
    static Vec3 sGetEquivalentSolidBoxSize(float inMass, Vec3 inInertiaDiagonal) pure nothrow @nogc {
        immutable Vec3 d = inInertiaDiagonal * (12.0f / inMass);
        return Vec3(sqrt(0.5f * (-d.GetX() + d.GetY() + d.GetZ())),
                    sqrt(0.5f * ( d.GetX() - d.GetY() + d.GetZ())),
                    sqrt(0.5f * ( d.GetX() + d.GetY() - d.GetZ())));
    }
}

unittest {
    // 1x1x1 unit-density cube: mass = 1, inertia diagonal = m/6 ≈ 0.16667.
    MassProperties mp;
    mp.SetMassAndInertiaOfSolidBox(Vec3(1, 1, 1), 1.0f);
    assert(mp.mMass == 1.0f);

    immutable float k = 1.0f / 6.0f;
    foreach (i; 0 .. 3) {
        immutable float diag = mp.mInertia(i, i);
        assert(diag > k - 1.0e-5f && diag < k + 1.0e-5f);
    }

    // ScaleToMass = 2 doubles mass and inertia.
    mp.ScaleToMass(2.0f);
    assert(mp.mMass == 2.0f);
    foreach (i; 0 .. 3) {
        immutable float diag = mp.mInertia(i, i);
        immutable float want = 2.0f * k;
        assert(diag > want - 1.0e-5f && diag < want + 1.0e-5f);
    }

    // sGetEquivalentSolidBoxSize round-trip on a uniform cube.
    immutable Vec3 size = MassProperties.sGetEquivalentSolidBoxSize(
        2.0f, Vec3(2.0f * k, 2.0f * k, 2.0f * k));
    foreach (i; 0 .. 3) {
        immutable float v = i == 0 ? size.GetX() : (i == 1 ? size.GetY() : size.GetZ());
        assert(v > 1.0f - 1.0e-4f && v < 1.0f + 1.0e-4f);
    }

    // Parallel axis: shift by (1,0,0) on a 1 kg point-like body adds m*1
    // to Iyy and Izz, leaves Ixx unchanged.
    MassProperties pt;
    pt.mMass = 1.0f;
    pt.mInertia = Mat44.sZero();
    pt.mInertia.SetColumn4(3, Vec4(0, 0, 0, 1));
    pt.Translate(Vec3(1, 0, 0));
    assert(pt.mInertia(0, 0) > -1.0e-5f && pt.mInertia(0, 0) < 1.0e-5f);
    assert(pt.mInertia(1, 1) > 1.0f - 1.0e-5f && pt.mInertia(1, 1) < 1.0f + 1.0e-5f);
    assert(pt.mInertia(2, 2) > 1.0f - 1.0e-5f && pt.mInertia(2, 2) < 1.0f + 1.0e-5f);
}
