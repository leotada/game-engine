// Ported from ozz-animation (MIT), (c) Guillaume Blanc,
// src/animation/runtime/ik_two_bone_job.cc + ik_aim_job.cc @ 744eb9d
/// Inverse kinematics jobs. Written with scalar math (`Vec3` / `Quat`): same algorithm and operation
/// order as upstream, without the 4-wide lane tricks.
///
/// Corrections are expressed in the *local space of their joint*; apply them on the right of the
/// joint's local rotation (`local.rotation = local.rotation * correction`) and then re-run
/// `LocalToModelJob` starting at the corrected joint (see `applyCorrection`).
///
/// Deviation: when the reference or joint plane normal has zero length (pole vector parallel to
/// the target direction), the plane alignment is skipped instead of producing NaNs.
module engine.animation.ik;

import engine.animation.math.matrix;
import engine.animation.math.scalar;
import engine.animation.math.simd;
import engine.animation.math.soa;
import std.math : sqrt, acos, fabs;

@safe:

private enum float kNormalizationToleranceEstSq = 2e-3f;

private bool isNormalizedEst(Vec3 v) pure nothrow @nogc {
    return fabs(dot(v, v) - 1.0f) < kNormalizationToleranceEstSq;
}

private float clamp(float lo, float v, float hi) pure nothrow @nogc {
    return v < lo ? lo : (v > hi ? hi : v);
}

private float len2(Vec3 v) pure nothrow @nogc { return dot(v, v); }

private Quat identityQuat() pure nothrow @nogc { return Quat(0, 0, 0, 1); }

/// Flips the quaternion sign if w < 0 so that a lerp with identity takes the shortest path.
private Quat fixUp(Quat q) pure nothrow @nogc {
    return q.w < 0 ? Quat(-q.x, -q.y, -q.z, -q.w) : q;
}

private Quat weighted(Quat q, float weight) pure nothrow @nogc {
    immutable w = weight < 0 ? 0 : weight;
    return normalize(Quat(q.x * w, q.y * w, q.z * w, (q.w - 1.0f) * w + 1.0f));
}

struct IKTwoBoneJob {
    /// Target position, model space.
    Vec3 target = Vec3(0, 0, 0);
    /// Normalized axis (in mid joint space) around which the mid joint bends.
    Vec3 midAxis = Vec3(0, 0, 1);
    /// Direction (model space) the mid joint should point to.
    Vec3 poleVector = Vec3(0, 1, 0);
    /// Rotation of the chain around the start-to-target vector, radians.
    float twistAngle = 0;
    /// Ratio of the chain length from which the chain gradually falls behind the target.
    float soften = 1;
    /// Blend between no IK (0) and full IK (1).
    float weight = 1;
    /// Model-space matrices of the chain joints.
    const(Float4x4)* startJoint, midJoint, endJoint;
    /// Outputs.
    Quat* startJointCorrection, midJointCorrection;
    /// Optional: set to true if the target is reachable.
    bool* reached;

    bool validate() const scope pure nothrow @nogc {
        return startJoint !is null && midJoint !is null && endJoint !is null
            && startJointCorrection !is null && midJointCorrection !is null && isNormalizedEst(midAxis);
    }

    bool run() scope pure nothrow @nogc @trusted {
        if (!validate()) return false;
        if (weight <= 0.0f) {
            *startJointCorrection = identityQuat();
            *midJointCorrection = identityQuat();
            if (reached !is null) *reached = false;
            return true;
        }

        // Constant setup.
        bool ok;
        immutable invStart = invert(*startJoint, ok);
        immutable invMid = invert(*midJoint, ok);
        immutable startMs = transformPoint(invMid, translationOf(*startJoint));
        immutable endMs = transformPoint(invMid, translationOf(*endJoint));
        immutable midSs = transformPoint(invStart, translationOf(*midJoint));
        immutable endSs = transformPoint(invStart, translationOf(*endJoint));
        immutable startMidMs = Vec3(-startMs.x, -startMs.y, -startMs.z);
        immutable midEndMs = endMs;
        immutable startMidSs = midSs;
        immutable midEndSs = sub(endSs, midSs);
        immutable startMidSsLen2 = len2(startMidSs);
        immutable midEndSsLen2 = len2(midEndSs);
        immutable startEndSsLen2 = len2(endSs);

        // Soften the target.
        Vec3 startTargetSs;
        float startTargetSsLen2;
        bool lreached;
        {
            immutable orig = transformPoint(invStart, target);
            immutable origLen2 = len2(orig);
            immutable smLen = sqrt(startMidSsLen2);
            immutable meLen = sqrt(midEndSsLen2);
            immutable origLen = sqrt(origLen2);
            immutable boneLenDiffAbs = fabs(smLen - meLen);
            immutable chain = smLen + meLen;
            immutable da = chain * clamp(0.0f, soften, 1.0f);
            immutable ds = chain - da;
            immutable cx = origLen > da;
            immutable cy = origLen > 0.0f;
            immutable cz = origLen > boneLenDiffAbs;
            immutable cw = ds > 0.0f;
            if (cx && cy && cw) {
                immutable alpha = (origLen - da) / ds;
                immutable op = alpha + 3.0f;
                immutable op2 = op * op;
                immutable ratio = 81.0f / (op2 * op2);
                immutable len = da + ds - ds * ratio;
                startTargetSsLen2 = len * len;
                startTargetSs = scale(orig, len / origLen);
            } else {
                startTargetSs = orig;
                startTargetSsLen2 = origLen2;
            }
            lreached = !cx && cz;
        }
        if (reached !is null) *reached = lreached && weight >= 1.0f;

        // Mid joint: law of cosines.
        immutable sum = startMidSsLen2 + midEndSsLen2;
        immutable halfRlen = 0.5f / sqrt(startMidSsLen2 * midEndSsLen2);
        immutable cosCorrected = clamp(-1.0f, (sum - startTargetSsLen2) * halfRlen, 1.0f);
        immutable cosInitial = clamp(-1.0f, (sum - startEndSsLen2) * halfRlen, 1.0f);
        immutable correctedAngle = acos(cosCorrected);
        immutable bentSideRef = cross(startMidMs, midAxis);
        immutable flip = dot(bentSideRef, midEndMs) < 0.0f;
        immutable initialAngle = flip ? -acos(cosInitial) : acos(cosInitial);
        immutable midRotMs = fromAxisAngle(midAxis, correctedAngle - initialAngle);

        // Start joint.
        immutable poleSs = transformVector(invStart, poleVector);
        immutable midEndSsFinal = transformVector(invStart,
            transformVector(*midJoint, rotate(midRotMs, midEndMs)));
        immutable startEndSsFinal = add(startMidSs, midEndSsFinal);
        immutable endToTargetRotSs = fromVectors(startEndSsFinal, startTargetSs);
        Quat startRotSs = endToTargetRotSs;
        if (startTargetSsLen2 > 0.0f) {
            immutable refPlaneNormalSs = cross(startTargetSs, poleSs);
            immutable refLen2 = len2(refPlaneNormalSs);
            immutable midAxisSs = transformVector(invStart, transformVector(*midJoint, midAxis));
            immutable jointPlaneNormalSs = rotate(endToTargetRotSs, midAxisSs);
            immutable jointLen2 = len2(jointPlaneNormalSs);
            if (refLen2 > 0.0f && jointLen2 > 0.0f) {
                immutable rsX = 1.0f / sqrt(startTargetSsLen2);
                immutable rsY = 1.0f / sqrt(refLen2);
                immutable rsZ = 1.0f / sqrt(jointLen2);
                immutable rotatePlaneCos = dot(scale(refPlaneNormalSs, rsY), scale(jointPlaneNormalSs, rsZ));
                immutable axis = scale(startTargetSs, rsX);
                immutable flipAxis = dot(jointPlaneNormalSs, poleSs) < 0.0f;
                immutable axisFlipped = flipAxis ? Vec3(-axis.x, -axis.y, -axis.z) : axis;
                immutable rotatePlaneSs = fromAxisCosAngle(axisFlipped, clamp(-1.0f, rotatePlaneCos, 1.0f));
                if (twistAngle != 0.0f) {
                    startRotSs = mul(mul(fromAxisAngle(axis, twistAngle), rotatePlaneSs), endToTargetRotSs);
                } else {
                    startRotSs = mul(rotatePlaneSs, endToTargetRotSs);
                }
            }
        }

        // Weight and output.
        immutable startFu = fixUp(startRotSs);
        immutable midFu = fixUp(midRotMs);
        if (weight < 1.0f) {
            *startJointCorrection = weighted(startFu, weight);
            *midJointCorrection = weighted(midFu, weight);
        } else {
            *startJointCorrection = startFu;
            *midJointCorrection = midFu;
        }
        return true;
    }
}

struct IKAimJob {
    /// Target position, model space.
    Vec3 target = Vec3(0, 0, 0);
    /// Normalized joint-space axis that should aim at the target.
    Vec3 forward = Vec3(1, 0, 0);
    /// Joint-space offset of the aiming point from the joint origin.
    Vec3 offset = Vec3(0, 0, 0);
    /// Joint-space up axis, aligned toward the pole vector.
    Vec3 up = Vec3(0, 1, 0);
    /// Model-space pole vector.
    Vec3 poleVector = Vec3(0, 1, 0);
    float twistAngle = 0;
    float weight = 1;
    /// Model-space matrix of the joint.
    const(Float4x4)* joint;
    Quat* jointCorrection;
    bool* reached;

    bool validate() const scope pure nothrow @nogc {
        return joint !is null && jointCorrection !is null && isNormalizedEst(forward);
    }

    bool run() scope pure nothrow @nogc @trusted {
        if (!validate()) return false;
        bool ok;
        immutable invJoint = invert(*joint, ok);
        immutable jointToTargetJs = transformPoint(invJoint, target);
        immutable jointToTargetLen2 = len2(jointToTargetJs);

        // Offsetted forward: the vector that makes the offset point aim at the target.
        immutable aol = dot(forward, offset);
        immutable acl2 = len2(offset) - aol * aol;
        immutable r2 = jointToTargetLen2;
        immutable lreached = !(acl2 > r2);
        if (reached !is null) *reached = lreached;
        if (!lreached || jointToTargetLen2 == 0.0f) {
            *jointCorrection = identityQuat();
            return true;
        }
        immutable ail = sqrt(r2 - acl2);
        immutable offsettedForward = add(offset, scale(forward, ail - aol));

        immutable toTargetRot = fromVectors(offsettedForward, jointToTargetJs);
        immutable correctedUp = rotate(toTargetRot, up);
        immutable poleJs = transformVector(invJoint, poleVector);
        immutable refNormal = cross(poleJs, jointToTargetJs);
        immutable jointNormal = cross(correctedUp, jointToTargetJs);
        immutable refLen2 = len2(refNormal);
        immutable jointLen2 = len2(jointNormal);

        Vec3 axis;
        Quat rotatePlane;
        if (jointToTargetLen2 != 0.0f && jointLen2 != 0.0f && refLen2 != 0.0f) {
            immutable rsX = 1.0f / sqrt(jointToTargetLen2);
            immutable rsY = 1.0f / sqrt(jointLen2);
            immutable rsZ = 1.0f / sqrt(refLen2);
            axis = scale(jointToTargetJs, rsX);
            immutable cosAngle = dot(scale(jointNormal, rsY), scale(refNormal, rsZ));
            immutable flip = dot(refNormal, correctedUp) < 0.0f;
            immutable axisFlipped = flip ? Vec3(-axis.x, -axis.y, -axis.z) : axis;
            rotatePlane = fromAxisCosAngle(axisFlipped, clamp(-1.0f, cosAngle, 1.0f));
        } else {
            axis = scale(jointToTargetJs, 1.0f / sqrt(jointToTargetLen2));
            rotatePlane = identityQuat();
        }

        Quat twisted = twistAngle != 0.0f
            ? mul(mul(fromAxisAngle(axis, twistAngle), rotatePlane), toTargetRot)
            : mul(rotatePlane, toTargetRot);
        immutable fu = fixUp(twisted);
        *jointCorrection = weight < 1.0f ? weighted(twisted, weight) : fu;
        return true;
    }
}

/// Applies an IK correction to joint `joint` of a local-space SoA pose (right-multiplies the
/// joint's local rotation). Afterwards re-run `LocalToModelJob` with `from = joint`.
void applyCorrection(SoaTransform[] pose, int joint, Quat correction) pure nothrow @nogc {
    auto t = &pose[joint / 4];
    immutable lane = joint & 3;
    immutable q = mul(Quat(t.rotation.x[lane], t.rotation.y[lane], t.rotation.z[lane], t.rotation.w[lane]),
                      correction);
    t.rotation.x[lane] = q.x;
    t.rotation.y[lane] = q.y;
    t.rotation.z[lane] = q.z;
    t.rotation.w[lane] = q.w;
}

version (unittest) {
    import std.math : abs;

    private Float4x4 at(Vec3 p, Quat q = Quat(0, 0, 0, 1)) {
        // Rotation matrix from quaternion, translation p.
        Float4x4 m = Float4x4.identity();
        immutable x = rotate(q, Vec3(1, 0, 0)), y = rotate(q, Vec3(0, 1, 0)), z = rotate(q, Vec3(0, 0, 1));
        m.cols[0] = SimdFloat4(x.x, x.y, x.z, 0);
        m.cols[1] = SimdFloat4(y.x, y.y, y.z, 0);
        m.cols[2] = SimdFloat4(z.x, z.y, z.z, 0);
        m.cols[3] = SimdFloat4(p.x, p.y, p.z, 1);
        return m;
    }

    // Straight chain along +X with unit bones: start (0,0,0), mid (1,0,0), end (2,0,0).
    // Returns the end effector position after applying the corrections.
    private Vec3 solve(scope ref IKTwoBoneJob job, ref Quat cs, ref Quat cm) @trusted {
        auto s = at(Vec3(0, 0, 0)), m = at(Vec3(1, 0, 0)), e = at(Vec3(2, 0, 0));
        job.startJoint = &s;
        job.midJoint = &m;
        job.endJoint = &e;
        job.startJointCorrection = &cs;
        job.midJointCorrection = &cm;
        assert(job.run());
        // start' = Cs; mid' = start' * T(1,0,0) * Cm
        immutable midPos = rotate(cs, Vec3(1, 0, 0));
        immutable endPos = add(midPos, rotate(mul(cs, cm), Vec3(1, 0, 0)));
        return endPos;
    }

    private float dist(Vec3 a, Vec3 b) { return sqrt(len2(sub(a, b))); }
}

@trusted unittest {
    // Reachable targets are reached exactly (within estimate-free tolerance).
    foreach (t; [Vec3(1, 1, 0), Vec3(0.5f, 1.2f, 0.3f), Vec3(-0.5f, 0.7f, 0.9f), Vec3(1.5f, 0.2f, -0.4f)]) {
        IKTwoBoneJob job;
        job.target = t;
        bool reached;
        job.reached = &reached;
        Quat cs, cm;
        immutable end = solve(job, cs, cm);
        assert(reached);
        assert(dist(end, t) < 1e-4f);
    }
}

@trusted unittest {
    // Unreachable (too far): chain stretches toward the target, `reached` false.
    IKTwoBoneJob job;
    job.target = Vec3(0, 5, 0);
    bool reached = true;
    job.reached = &reached;
    Quat cs, cm;
    immutable end = solve(job, cs, cm);
    assert(!reached);
    assert(dist(end, Vec3(0, 2, 0)) < 1e-4f);
}

@trusted unittest {
    // Weight 0: identity corrections, not reached. Weight 0.5: halfway between.
    IKTwoBoneJob job;
    job.target = Vec3(1, 1, 0);
    job.weight = 0;
    bool reached = true;
    job.reached = &reached;
    Quat cs, cm;
    solve(job, cs, cm);
    assert(!reached && cs == Quat(0, 0, 0, 1) && cm == Quat(0, 0, 0, 1));

    job.weight = 0.5f;
    Quat hs, hm;
    solve(job, hs, hm);
    job.weight = 1;
    Quat fs, fm;
    solve(job, fs, fm);
    // Half weight rotates by about half the angle: w' = cos(angle/4) vs cos(angle/2).
    immutable ang = 2 * acos(fs.w), angh = 2 * acos(hs.w);
    assert(abs(angh - ang * 0.5f) < 0.02f);
}

@trusted unittest {
    // Soften < 1: target near full extension is pulled back (chain does not fully stretch).
    IKTwoBoneJob job;
    job.target = Vec3(1.95f, 0.05f, 0);
    job.soften = 0.8f;
    Quat cs, cm;
    immutable end = solve(job, cs, cm);
    assert(sqrt(len2(end)) < sqrt(len2(job.target)) - 1e-3f);
    // soften = 1 reaches it.
    job.soften = 1;
    immutable end1 = solve(job, cs, cm);
    assert(dist(end1, job.target) < 1e-3f);
}

@trusted unittest {
    // Pole vector decides the bend side; twist keeps the end effector on target.
    IKTwoBoneJob job;
    job.target = Vec3(1.2f, 0, 0);
    job.poleVector = Vec3(0, 0, 1);
    Quat cs, cm;
    immutable end = solve(job, cs, cm);
    assert(dist(end, job.target) < 1e-4f);
    immutable mid = rotate(cs, Vec3(1, 0, 0));
    assert(mid.z > 0.1f);
    job.poleVector = Vec3(0, 0, -1);
    solve(job, cs, cm);
    assert(rotate(cs, Vec3(1, 0, 0)).z < -0.1f);

    job.poleVector = Vec3(0, 1, 0);
    job.twistAngle = 0.7f;
    immutable twisted = solve(job, cs, cm);
    assert(dist(twisted, job.target) < 1e-4f);
}

@trusted unittest {
    // Degenerate cases never produce NaN: pole parallel to target, target at the start joint.
    import std.math : isNaN;
    IKTwoBoneJob job;
    job.target = Vec3(0, 1.5f, 0);
    job.poleVector = Vec3(0, 1, 0);
    Quat cs, cm;
    solve(job, cs, cm);
    assert(!isNaN(cs.x) && !isNaN(cs.w) && !isNaN(cm.w));
    job.target = Vec3(0, 0, 0);
    solve(job, cs, cm);
    assert(!isNaN(cs.x) && !isNaN(cs.w) && !isNaN(cm.w));
    // Validation: null pointers / non-normalized axis.
    IKTwoBoneJob bad;
    assert(!bad.run());
    job.midAxis = Vec3(0, 0, 2);
    assert(!job.validate());
}

@trusted unittest {
    // Aim: after applying the correction, the forward axis points at the target.
    foreach (t; [Vec3(0, 3, 0), Vec3(2, 1, -1), Vec3(-1, -1, 2)]) {
        auto j = at(Vec3(0.5f, 0.5f, 0));
        Quat c;
        bool reached;
        IKAimJob job;
        job.joint = &j;
        job.jointCorrection = &c;
        job.reached = &reached;
        job.target = t;
        assert(job.run() && reached);
        immutable dir = rotate(c, job.forward); // joint space
        immutable want = sub(t, Vec3(0.5f, 0.5f, 0));
        immutable n = scale(want, 1.0f / sqrt(len2(want)));
        assert(dist(dir, n) < 1e-4f);
    }
}

@trusted unittest {
    // Aim with offset: the offset point (not the origin) ends up on the line to the target;
    // offset farther than the target is unreachable and gives identity.
    auto j = at(Vec3(0, 0, 0));
    Quat c;
    bool reached;
    IKAimJob job;
    job.joint = &j;
    job.jointCorrection = &c;
    job.reached = &reached;
    job.offset = Vec3(0, 0.5f, 0);
    job.target = Vec3(0, 3, 4); // distance 5
    assert(job.run() && reached);
    immutable p = rotate(c, job.offset);
    // Vector from the rotated offset point to the target is parallel to the rotated forward.
    immutable toT = sub(job.target, p);
    immutable f = rotate(c, job.forward);
    assert(len2(cross(toT, f)) < 1e-4f);
    job.target = Vec3(0, 0.2f, 0);
    assert(job.run() && !reached && c == Quat(0, 0, 0, 1));
    job.target = Vec3(0, 0, 0);
    job.offset = Vec3(0, 0, 0);
    assert(job.run() && c == Quat(0, 0, 0, 1));
}

@trusted unittest {
    // Aim weight and up/pole alignment; invalid job.
    auto j = at(Vec3(0, 0, 0));
    Quat c;
    IKAimJob job;
    job.joint = &j;
    job.jointCorrection = &c;
    job.target = Vec3(0, 2, 0);
    job.weight = 0;
    assert(job.run() && abs(c.w - 1) < 1e-6f);
    job.weight = 1;
    job.poleVector = Vec3(0, 0, 1);
    job.up = Vec3(0, 1, 0);
    assert(job.run());
    // Joint up axis, after the correction, lies in the plane of target and pole (here y-z plane
    // with target on y): it should point toward the pole side (+z) or be the target axis itself.
    immutable up2 = rotate(c, Vec3(0, 1, 0));
    assert(up2.x * up2.x < 1e-6f);
    IKAimJob bad;
    assert(!bad.run());
}

@trusted unittest {
    // applyCorrection right-multiplies the local rotation of one lane only.
    SoaTransform[1] pose;
    immutable q = fromAxisAngle(Vec3(0, 0, 1), 1.0f);
    applyCorrection(pose[], 2, q);
    assert(abs(pose[0].rotation.z[2] - q.z) < 1e-6f && abs(pose[0].rotation.w[2] - q.w) < 1e-6f);
    assert(pose[0].rotation.w[1] == 1 && pose[0].rotation.z[1] == 0);
}
