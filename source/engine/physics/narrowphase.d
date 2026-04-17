// Narrowphase — specialized pair routines.
//
// Philosophy (from Bullet): for the common, cheap pairs (sphere-sphere,
// sphere-plane, sphere-box) use branch-free analytic tests. For OBB-OBB
// use the ODE-style SAT 15-axis test with Sutherland-Hodgman clipping to
// produce up to 4 contact points per manifold — essential for stable
// stacking.
//
// For the first pass, cylinder and capsule fall through to box SAT on
// their OBB approximation. This yields correct-ish normals and depths for
// the benchmark (trees at rest on a plane); precise cylinder/capsule
// contact normals can be swapped in later without changing this module's
// signature.
module engine.physics.narrowphase;

import std.math : abs, sqrt, fabs;
import engine.math.vec;
import engine.math.quat;
import engine.physics.types;

@safe:

/// Output of a single-pair narrowphase call. Writes directly into a
/// caller-provided buffer up to `MANIFOLD_CACHE_SIZE` points.
struct NarrowResult {
    ContactPoint[MANIFOLD_CACHE_SIZE] points;
    ubyte count = 0;
}

// ---------- utility ------------------------------------------------------

private Vec3 clampVec(Vec3 v, Vec3 lo, Vec3 hi) {
    return Vec3(
        v.x < lo.x ? lo.x : (v.x > hi.x ? hi.x : v.x),
        v.y < lo.y ? lo.y : (v.y > hi.y ? hi.y : v.y),
        v.z < lo.z ? lo.z : (v.z > hi.z ? hi.z : v.z));
}

private Vec3 rotRow(Quat q, int axis) {
    // q.rotate(unit axis i) — gives row `i` of the world-from-body basis.
    immutable basis = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)];
    return q.rotate(basis[axis]);
}

// Helper: build an orthonormal (tangent1, tangent2) from a unit normal.
void computeBasis(Vec3 n, out Vec3 t1, out Vec3 t2) {
    if (fabs(n.x) > 0.7071f) {
        immutable l = 1.0f / sqrt(n.y * n.y + n.x * n.x);
        t1 = Vec3(-n.y * l, n.x * l, 0);
    } else {
        immutable l = 1.0f / sqrt(n.z * n.z + n.y * n.y);
        t1 = Vec3(0, -n.z * l, n.y * l);
    }
    t2 = n.cross(t1);
}

// ---------- sphere-sphere (Bullet: btSphereSphereCollisionAlgorithm) ----

bool sphereSphere(Vec3 pa, float ra, Vec3 pb, float rb, ref NarrowResult out_) {
    immutable d2 = (pb - pa).lengthSquared;
    immutable r  = ra + rb;
    if (d2 >= r * r) return false;
    Vec3 n;
    if (d2 > 1e-12f) {
        immutable inv = 1.0f / sqrt(d2);
        n = (pb - pa) * inv;
    } else {
        n = Vec3(0, 1, 0);
    }
    ContactPoint c;
    c.normal    = n;
    c.depth     = r - sqrt(d2);
    c.worldPosA = pa + n * ra;
    c.worldPosB = pb - n * rb;
    c.localA    = c.worldPosA - pa;
    c.localB    = c.worldPosB - pb;
    out_.points[0] = c;
    out_.count = 1;
    return true;
}

// ---------- sphere vs plane ---------------------------------------------

/// Plane is `normal · x = d`.
bool spherePlane(Vec3 ps, float rs, Vec3 planeN, float planeD, ref NarrowResult out_) {
    immutable dist = planeN.dot(ps) - planeD;
    if (dist >= rs) return false;
    ContactPoint c;
    c.normal    = -planeN;           // A = sphere, B = plane → A→B = into plane
    c.depth     = rs - dist;
    c.worldPosA = ps - planeN * rs;  // deepest sphere point
    c.worldPosB = ps - planeN * dist;
    c.localA    = c.worldPosA - ps;
    c.localB    = c.worldPosB;       // plane is static → "local" == world
    out_.points[0] = c;
    out_.count = 1;
    return true;
}

// ---------- sphere vs OBB (Bullet: btSphereBoxCollisionAlgorithm) -------

bool sphereBox(Vec3 ps, float rs, Vec3 pb, Quat qb, Vec3 he,
               ref NarrowResult out_) {
    // Transform sphere centre into box local space.
    immutable local = qb.conjugate().rotate(ps - pb);
    immutable clamped = clampVec(local, -he, he);
    immutable diff = local - clamped;
    immutable d2 = diff.lengthSquared;
    if (d2 >= rs * rs) return false;

    Vec3 nLocal;
    float depth;
    if (d2 > 1e-12f) {
        immutable d = sqrt(d2);
        nLocal = diff * (1.0f / d);
        depth = rs - d;
    } else {
        // Centre inside box — push out along least-penetrated axis.
        immutable px = he.x - fabs(local.x);
        immutable py = he.y - fabs(local.y);
        immutable pz = he.z - fabs(local.z);
        if (px < py && px < pz) {
            nLocal = Vec3(local.x >= 0 ? 1 : -1, 0, 0);
            depth = rs + px;
        } else if (py < pz) {
            nLocal = Vec3(0, local.y >= 0 ? 1 : -1, 0);
            depth = rs + py;
        } else {
            nLocal = Vec3(0, 0, local.z >= 0 ? 1 : -1);
            depth = rs + pz;
        }
    }

    immutable nWorld = qb.rotate(nLocal);
    ContactPoint c;
    c.normal    = nWorld;                     // A→B where A=sphere, B=box
    c.depth     = depth;
    c.worldPosA = ps + nWorld * rs;
    c.worldPosB = pb + qb.rotate(clamped);
    c.localA    = c.worldPosA - ps;
    c.localB    = clamped;
    out_.points[0] = c;
    out_.count = 1;
    return true;
}

// ---------- box vs plane (4-point clip) ---------------------------------

bool boxPlane(Vec3 pb, Quat qb, Vec3 he, Vec3 planeN, float planeD,
              ref NarrowResult out_) {
    // 8 corners in world space; any with plane distance < 0 are contacts.
    immutable ax = qb.rotate(Vec3(1, 0, 0)) * he.x;
    immutable ay = qb.rotate(Vec3(0, 1, 0)) * he.y;
    immutable az = qb.rotate(Vec3(0, 0, 1)) * he.z;
    ubyte nOut = 0;
    for (int sx = -1; sx <= 1; sx += 2)
    for (int sy = -1; sy <= 1; sy += 2)
    for (int sz = -1; sz <= 1; sz += 2) {
        immutable w = pb + ax * sx + ay * sy + az * sz;
        immutable dist = planeN.dot(w) - planeD;
        if (dist < 0) {
            if (nOut < MANIFOLD_CACHE_SIZE) {
                ContactPoint c;
                c.normal    = -planeN;          // A=box, B=plane
                c.depth     = -dist;
                c.worldPosA = w;
                c.worldPosB = w - planeN * dist;
                c.localA    = qb.conjugate().rotate(w - pb);
                c.localB    = c.worldPosB;
                out_.points[nOut++] = c;
            }
        }
    }
    out_.count = nOut;
    return nOut > 0;
}

// ---------- box-box SAT (15 axes, face contact = 4-point clip) ----------

/// Reference-face approach: pick axis with minimum penetration, find the
/// incident face on the other box, clip it against the 4 side planes of
/// the reference face, then keep up to 4 points where clipped polygon is
/// below the reference plane.
bool boxBox(Vec3 pa, Quat qa, Vec3 hea, Vec3 pb, Quat qb, Vec3 heb,
            ref NarrowResult out_) {
    // Build 3 world basis vectors per box.
    Vec3[3] Aax = [rotRow(qa, 0), rotRow(qa, 1), rotRow(qa, 2)];
    Vec3[3] Bax = [rotRow(qb, 0), rotRow(qb, 1), rotRow(qb, 2)];

    immutable T = pb - pa;

    // R[i][j] = Aax[i] · Bax[j]; absR biased by fudge2 to break ties in
    // favor of face axes (Bullet / ODE convention).
    enum float fudge2 = 1e-5f;
    float[3][3] R;
    float[3][3] absR;
    foreach (i; 0 .. 3) {
        foreach (j; 0 .. 3) {
            R[i][j]   = Aax[i].dot(Bax[j]);
            absR[i][j] = fabs(R[i][j]) + fudge2;
        }
    }

    // Axis-scan helper.
    float bestDepth = 1e30f;
    int   bestAxis  = -1;
    Vec3  bestN     = Vec3(0, 1, 0);
    bool  bestFlip  = false;

    // Face axes of A (0..2).
    foreach (i; 0 .. 3) {
        immutable ra = (i == 0 ? hea.x : i == 1 ? hea.y : hea.z);
        immutable rb = heb.x * absR[i][0] + heb.y * absR[i][1] + heb.z * absR[i][2];
        immutable s  = Aax[i].dot(T);
        immutable d  = ra + rb - fabs(s);
        if (d < 0) return false;
        if (d < bestDepth) {
            bestDepth = d;
            bestAxis  = cast(int) i;
            bestN     = s < 0 ? Aax[i] * -1.0f : Aax[i];
            bestFlip  = false;
        }
    }
    // Face axes of B (3..5).
    foreach (i; 0 .. 3) {
        immutable ra = hea.x * absR[0][i] + hea.y * absR[1][i] + hea.z * absR[2][i];
        immutable rb = (i == 0 ? heb.x : i == 1 ? heb.y : heb.z);
        immutable s  = Bax[i].dot(T);
        immutable d  = ra + rb - fabs(s);
        if (d < 0) return false;
        if (d < bestDepth) {
            bestDepth = d;
            bestAxis  = 3 + cast(int) i;
            bestN     = s < 0 ? Bax[i] * -1.0f : Bax[i];
            bestFlip  = true;
        }
    }
    // Edge-edge axes (6..14) — for a single contact point only.
    //
    // Bias: we *only* switch to an edge-edge axis when its overlap is
    // MEANINGFULLY smaller than the best face axis so far. ODE/Bullet use
    // a ~5% margin so that identical axis-aligned boxes (where face Y and
    // edge X×Z give numerically identical overlap) always resolve to a
    // 4-point face contact, not a degenerate single-point edge contact.
    //
    // The test is `d * bias < bestDepth` with `bias > 1`; an edge-edge
    // axis must beat the face candidate by at least (bias-1) to win.
    enum float edgeBias = 1.05f;
    foreach (i; 0 .. 3) foreach (j; 0 .. 3) {
        immutable axis = Aax[i].cross(Bax[j]);
        immutable len2 = axis.lengthSquared;
        if (len2 < 1e-6f) continue;
        immutable invL = 1.0f / sqrt(len2);
        immutable n    = axis * invL;
        immutable ra   = hea.x * fabs(n.dot(Aax[0])) + hea.y * fabs(n.dot(Aax[1])) + hea.z * fabs(n.dot(Aax[2]));
        immutable rb   = heb.x * fabs(n.dot(Bax[0])) + heb.y * fabs(n.dot(Bax[1])) + heb.z * fabs(n.dot(Bax[2]));
        immutable s    = n.dot(T);
        immutable d    = ra + rb - fabs(s);
        if (d < 0) return false;
        if (d * edgeBias < bestDepth) {
            bestDepth = d;
            bestAxis  = 6 + cast(int)(i * 3 + j);
            bestN     = s < 0 ? n * -1.0f : n;
        }
    }

    // bestN points A → B. For edge-edge, generate a single deepest-point
    // contact. For face cases, clip.
    if (bestAxis >= 6) {
        // Edge-edge: contact is on the closest segment pair. Approximate by
        // the midpoint of each box projected along bestN.
        ContactPoint c;
        c.normal = bestN;
        c.depth  = bestDepth;
        immutable supportA = pa + closestSupport(Aax, hea, bestN);
        immutable supportB = pb + closestSupport(Bax, heb, -bestN);
        c.worldPosA = supportA;
        c.worldPosB = supportB;
        c.localA = qa.conjugate().rotate(supportA - pa);
        c.localB = qb.conjugate().rotate(supportB - pb);
        out_.points[0] = c;
        out_.count = 1;
        return true;
    }

    // Face contact. `ref` is the box whose face axis is chosen; `inc` is
    // the other box. We clip inc's deepest face against ref's 4 side planes.
    Vec3[3] refAx, incAx;
    Vec3    refPos, incPos;
    Vec3    refHe,  incHe;
    Quat    refQ,   incQ;
    Vec3    refN; // outward normal of reference face in world space

    if (bestAxis < 3) {
        refAx = Aax; incAx = Bax;
        refPos = pa; incPos = pb;
        refHe  = hea; incHe = heb;
        refQ   = qa; incQ   = qb;
        refN   = bestN;        // A→B
    } else {
        refAx = Bax; incAx = Aax;
        refPos = pb; incPos = pa;
        refHe  = heb; incHe  = hea;
        refQ   = qb; incQ   = qa;
        refN   = -bestN;       // B→A
    }

    // Find the incident face (the one on `inc` most anti-parallel to refN).
    int incFace = 0;
    float maxAlign = -1;
    bool  incFaceNeg = false;
    foreach (i; 0 .. 3) {
        immutable d = incAx[i].dot(refN);
        if (fabs(d) > maxAlign) {
            maxAlign = fabs(d);
            incFace = cast(int) i;
            incFaceNeg = d > 0; // incident face points opposite to refN
        }
    }
    // 4 corners of incident face in world space.
    Vec3 center = incPos + incAx[incFace] * (incFaceNeg ? -incHe.get(incFace) : incHe.get(incFace));
    immutable u = (incFace + 1) % 3;
    immutable v = (incFace + 2) % 3;
    Vec3 eu = incAx[u] * incHe.get(u);
    Vec3 ev = incAx[v] * incHe.get(v);
    Vec3[4] face = [center - eu - ev, center + eu - ev, center + eu + ev, center - eu + ev];

    // Compute reference face centre + 4 side planes.
    int refFace = bestAxis < 3 ? bestAxis : (bestAxis - 3);
    bool refFaceNeg = refN.dot(refAx[refFace]) < 0;
    Vec3 refCenter = refPos + refAx[refFace] * (refFaceNeg ? -refHe.get(refFace) : refHe.get(refFace));
    immutable ru = (refFace + 1) % 3;
    immutable rv = (refFace + 2) % 3;
    Vec3 refU = refAx[ru]; float refUHE = refHe.get(ru);
    Vec3 refV = refAx[rv]; float refVHE = refHe.get(rv);

    // Clip the 4-vertex polygon against 4 side planes (+u, -u, +v, -v).
    Vec3[8] buf1 = void; Vec3[8] buf2 = void;
    int n1 = 4;
    buf1[0] = face[0]; buf1[1] = face[1]; buf1[2] = face[2]; buf1[3] = face[3];

    int n2 = clipPolygonAxis(buf1, n1, buf2, refCenter, refU, refUHE);
    n1 = clipPolygonAxis(buf2, n2, buf1, refCenter, refU * -1.0f, refUHE);
    n2 = clipPolygonAxis(buf1, n1, buf2, refCenter, refV, refVHE);
    n1 = clipPolygonAxis(buf2, n2, buf1, refCenter, refV * -1.0f, refVHE);

    // Keep at most 4 points where (p - refCenter) · refN <= 0.
    ubyte nOut = 0;
    foreach (i; 0 .. n1) {
        immutable p = buf1[i];
        immutable d = (p - refCenter).dot(refN);
        if (d < 0 && nOut < MANIFOLD_CACHE_SIZE) {
            ContactPoint c;
            c.normal    = bestN;               // always A→B
            c.depth     = -d;
            c.worldPosA = bestAxis < 3 ? (p - bestN * -d) : p;
            c.worldPosB = bestAxis < 3 ? p : (p + bestN * -d);
            c.localA    = qa.conjugate().rotate(c.worldPosA - pa);
            c.localB    = qb.conjugate().rotate(c.worldPosB - pb);
            out_.points[nOut++] = c;
        }
    }
    out_.count = nOut;
    return nOut > 0;
}

// Helper: support point of an OBB in direction `d`, returned as offset from
// box centre.
private Vec3 closestSupport(Vec3[3] ax, Vec3 he, Vec3 d) {
    Vec3 r = Vec3(0, 0, 0);
    foreach (i; 0 .. 3) {
        immutable s = ax[i].dot(d) >= 0 ? 1.0f : -1.0f;
        r = r + ax[i] * (s * (i == 0 ? he.x : i == 1 ? he.y : he.z));
    }
    return r;
}

// Clip a convex polygon against a half-space { p : (p - origin) · axis <= size }.
private int clipPolygonAxis(scope const Vec3[] inPoly, int inN, scope ref Vec3[8] outBuf,
                            Vec3 origin, Vec3 axis, float size) {
    int outN = 0;
    if (inN == 0) return 0;
    Vec3 prev = inPoly[inN - 1];
    float prevD = (prev - origin).dot(axis) - size;
    foreach (i; 0 .. inN) {
        immutable curr = inPoly[i];
        immutable currD = (curr - origin).dot(axis) - size;
        if (prevD <= 0) {
            if (outN < cast(int) outBuf.length) outBuf[outN++] = prev;
            if (currD > 0 && outN < cast(int) outBuf.length) {
                immutable t = prevD / (prevD - currD);
                outBuf[outN++] = prev + (curr - prev) * t;
            }
        } else if (currD <= 0 && outN < cast(int) outBuf.length) {
            immutable t = prevD / (prevD - currD);
            outBuf[outN++] = prev + (curr - prev) * t;
        }
        prev = curr;
        prevD = currD;
    }
    return outN;
}

// Vec3 component helper (math module has no .get — keep it local).
private float get(Vec3 v, int i) { return i == 0 ? v.x : i == 1 ? v.y : v.z; }
// 
