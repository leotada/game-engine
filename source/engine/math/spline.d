/**
 * 3D splines for roads, rails, rivers and traffic paths.
 *
 * `Spline3` holds either a Catmull-Rom curve (passes through every control
 * point; centripetal by default, so no cusps or self-loops on uneven
 * spacing) or a piecewise cubic Bézier (`P0, C0, C1, P1, C2, C3, P2, ...`).
 * Curves are parameterised by `u ∈ [0, segmentCount]`, segment `i` covering
 * `[i, i + 1]`.
 *
 * `rebuild()` (load time; allocates) bakes an arc-length lookup table plus a
 * rotation-minimizing frame per sample. Afterwards every query is
 * `@nogc nothrow` and safe in the frame loop:
 * - `sampleAtDistance`, `tangentAtDistance`, `frameAtDistance` — constant
 *   speed placement (vehicles, props every N metres);
 * - `closestPoint` — distance along the curve and lateral offset of a world
 *   position (lane keeping, "am I on the road");
 * - `extrudeRibbon` — procedural road / river mesh as `TexVert` + indices,
 *   ready for `TexMesh.fromData`.
 *
 * Frames: `FrameMode.upVector` keeps the ribbon level (right = tangent ×
 * world up), which is what roads want; `FrameMode.rotationMinimizing`
 * transports the normal along the curve without twist (loops, rails,
 * tubes), with the closing twist of closed curves spread evenly.
 */
module engine.math.spline;

import core.stdc.math : fabsf;
import engine.core.pod : Pod;
import engine.graphics.types : TexVert;
import engine.math.vec : Vec3;

@safe:

enum SplineKind : ubyte {
    catmullRom,
    bezier,
}

enum FrameMode : ubyte {
    /// Right vector = tangent × up; no roll. Falls back to the
    /// rotation-minimizing frame where the tangent is parallel to `up`.
    upVector,
    /// Twist-free parallel transport (double reflection).
    rotationMinimizing,
}

/// Orthonormal frame on the curve.
struct SplineFrame {
    Vec3 position;
    /// Unit direction of travel.
    Vec3 tangent;
    /// Unit "up" (ribbon normal).
    Vec3 normal;
    /// Unit "right" (`tangent × normal`).
    Vec3 binormal;
}

/// Result of `Spline3.closestPoint`.
struct SplineHit {
    /// Curve parameter in `[0, segmentCount]`.
    float param = 0;
    /// Arc length from the start to the closest point.
    float distance = 0;
    Vec3 position;
    /// Straight-line distance from the query point.
    float separation = 0;
    /// Signed offset along the frame's `binormal` (+ right, - left).
    float lateral = 0;
}

/// One baked arc-length sample.
struct ArcSample {
    float u = 0;
    float s = 0;
    Vec3 rmfNormal;
}

struct Spline3 {
    SplineKind kind = SplineKind.catmullRom;
    bool closed = false;
    /// Catmull-Rom knot exponent: 0 uniform, 0.5 centripetal, 1 chordal.
    float alpha = 0.5f;
    /// World up used for the first frame and `FrameMode.upVector`.
    Vec3 up = Vec3(0, 1, 0);
    Pod!Vec3[] points;

    private Pod!ArcSample[] _lut;
    private float _length = 0;

    /// Number of curve segments (0 when there are too few points).
    uint segmentCount() const pure nothrow @nogc {
        immutable n = points.length;
        final switch (kind) {
            case SplineKind.catmullRom:
                if (n < 2) return 0;
                return cast(uint)(closed ? n : n - 1);
            case SplineKind.bezier:
                if (closed) return n >= 3 ? cast(uint)(n / 3) : 0;
                return n >= 4 ? cast(uint)((n - 1) / 3) : 0;
        }
    }

    /// True once `rebuild` baked the arc-length table.
    bool baked() const pure nothrow @nogc { return _lut.length >= 2; }

    /// Total arc length (after `rebuild`).
    float length() const pure nothrow @nogc { return _length; }

    /// Baked samples (read-only; debug draw, tooling).
    const(ArcSample)[] samples() const pure nothrow @nogc { return _lut; }

    /**
     * Bake the arc-length table (`samplesPerSegment` chords per segment) and
     * rotation-minimizing frames. Call after editing `points`. Allocates.
     */
    void rebuild(uint samplesPerSegment = 32) {
        _lut = null;
        _length = 0;
        immutable segs = segmentCount();
        if (segs == 0 || samplesPerSegment == 0) return;
        immutable total = segs * samplesPerSegment;
        _lut = new Pod!ArcSample[](total + 1);

        Vec3 prev = evaluate(0);
        Vec3 prevT = tangentAt(0);
        Vec3 n = initialNormal(prevT);
        _lut[0] = ArcSample(0, 0, n);
        float s = 0;
        foreach (i; 1 .. total + 1) {
            immutable u = cast(float) i / samplesPerSegment;
            immutable p = evaluate(u);
            immutable t = tangentAt(u);
            s += (p - prev).length;
            n = transportNormal(prev, prevT, n, p, t);
            _lut[i] = ArcSample(u, s, n);
            prev = p;
            prevT = t;
        }
        _length = s;

        if (closed && _length > 0) {
            // Spread the residual twist between the end and start normals.
            immutable start = _lut[0].rmfNormal;
            immutable end = _lut[$ - 1].rmfNormal;
            immutable t0 = tangentAt(0);
            float angle = pureAcos(clamp(end.dot(start), -1, 1));
            if (t0.dot(end.cross(start)) < 0) angle = -angle;
            foreach (ref smp; _lut) {
                immutable ti = tangentAt(smp.u);
                smp.rmfNormal = rotateAround(smp.rmfNormal, ti, angle * (smp.s / _length)).normalized;
            }
        }
    }

    /// Position at parameter `u ∈ [0, segmentCount]` (clamped; wraps when closed).
    Vec3 evaluate(float u) const pure nothrow @nogc {
        uint seg;
        float t;
        if (!locate(u, seg, t)) return points.length ? points[0] : Vec3(0, 0, 0);
        final switch (kind) {
            case SplineKind.catmullRom:
                Vec3 p0, p1, p2, p3;
                crPoints(seg, p0, p1, p2, p3);
                return catmullRomPoint(p0, p1, p2, p3, t, alpha);
            case SplineKind.bezier:
                Vec3 b0, b1, b2, b3;
                bezierPoints(seg, b0, b1, b2, b3);
                return bezierPoint(b0, b1, b2, b3, t);
        }
    }

    /// First derivative d(position)/du (not normalized).
    Vec3 derivative(float u) const pure nothrow @nogc {
        uint seg;
        float t;
        if (!locate(u, seg, t)) return Vec3(0, 0, 0);
        final switch (kind) {
            case SplineKind.catmullRom:
                Vec3 p0, p1, p2, p3;
                crPoints(seg, p0, p1, p2, p3);
                // Central difference inside the segment (the centripetal
                // closed form is long and buys nothing for frames).
                enum float h = 1e-3f;
                immutable ta = t - h < 0 ? 0 : t - h;
                immutable tb = t + h > 1 ? 1 : t + h;
                return (catmullRomPoint(p0, p1, p2, p3, tb, alpha)
                      - catmullRomPoint(p0, p1, p2, p3, ta, alpha)) / (tb - ta);
            case SplineKind.bezier:
                Vec3 b0, b1, b2, b3;
                bezierPoints(seg, b0, b1, b2, b3);
                return bezierDerivative(b0, b1, b2, b3, t);
        }
    }

    /// Unit tangent at parameter `u`.
    Vec3 tangentAt(float u) const pure nothrow @nogc {
        immutable d = derivative(u);
        if (d.lengthSquared > 1e-12f) return d.normalized;
        // Degenerate (coincident control points): look slightly ahead.
        immutable segs = segmentCount();
        immutable a = evaluate(u);
        immutable b = evaluate(u + 1e-2f > segs ? u - 1e-2f : u + 1e-2f);
        immutable dir = u + 1e-2f > segs ? a - b : b - a;
        return dir.lengthSquared > 1e-12f ? dir.normalized : Vec3(0, 0, 1);
    }

    /// Curve parameter at arc length `s` (clamped; wraps when closed).
    float paramAtDistance(float s) const pure nothrow @nogc @trusted {
        if (!baked) return 0;
        s = wrapDistance(s);
        size_t lo = 0, hi = _lut.length - 1;
        while (hi - lo > 1) {
            immutable mid = (lo + hi) / 2;
            if (_lut[mid].s <= s) lo = mid;
            else hi = mid;
        }
        immutable a = _lut[lo];
        immutable b = _lut[hi];
        immutable ds = b.s - a.s;
        immutable f = ds > 0 ? (s - a.s) / ds : 0;
        return a.u + (b.u - a.u) * f;
    }

    /// Arc length at curve parameter `u`.
    float distanceAtParam(float u) const pure nothrow @nogc @trusted {
        if (!baked) return 0;
        immutable maxU = _lut[$ - 1].u;
        if (u <= 0) return 0;
        if (u >= maxU) return _length;
        size_t lo = 0, hi = _lut.length - 1;
        while (hi - lo > 1) {
            immutable mid = (lo + hi) / 2;
            if (_lut[mid].u <= u) lo = mid;
            else hi = mid;
        }
        immutable a = _lut[lo];
        immutable b = _lut[hi];
        immutable f = (u - a.u) / (b.u - a.u);
        return a.s + (b.s - a.s) * f;
    }

    /// Position `s` metres along the curve.
    Vec3 sampleAtDistance(float s) const pure nothrow @nogc {
        return evaluate(paramAtDistance(s));
    }

    /// Unit tangent `s` metres along the curve.
    Vec3 tangentAtDistance(float s) const pure nothrow @nogc {
        return tangentAt(paramAtDistance(s));
    }

    /// Stable orthonormal frame `s` metres along the curve.
    SplineFrame frameAtDistance(float s, FrameMode mode = FrameMode.upVector) const pure nothrow @nogc @trusted {
        SplineFrame f;
        immutable u = paramAtDistance(s);
        f.position = evaluate(u);
        f.tangent = tangentAt(u);
        Vec3 n;
        bool haveUp;
        if (mode == FrameMode.upVector) {
            immutable right = f.tangent.cross(up);
            if (right.lengthSquared > 1e-6f) {
                f.binormal = right.normalized;
                n = f.binormal.cross(f.tangent).normalized;
                haveUp = true;
            }
        }
        if (!haveUp) {
            n = baked ? rmfNormalAt(wrapDistance(s)) : initialNormal(f.tangent);
            // Re-orthogonalize against the exact tangent.
            n = (n - f.tangent * n.dot(f.tangent)).normalized;
            if (n.lengthSquared < 0.5f) n = initialNormal(f.tangent);
            f.binormal = f.tangent.cross(n).normalized;
        }
        f.normal = n;
        return f;
    }

    /**
     * Closest point on the curve to `p` (coarse search over the baked
     * samples, then golden-section refinement). Requires `rebuild`.
     */
    SplineHit closestPoint(Vec3 p, FrameMode mode = FrameMode.upVector) const pure nothrow @nogc @trusted {
        SplineHit hit;
        if (!baked) return hit;
        size_t best = 0;
        float bestD = float.max;
        immutable maxU = _lut[$ - 1].u;
        foreach (i, ref smp; _lut) {
            immutable d = (evaluate(smp.u) - p).lengthSquared;
            if (d < bestD) {
                bestD = d;
                best = i;
            }
        }
        float lo = best > 0 ? _lut[best - 1].u : (closed ? -(_lut[1].u) : 0);
        float hi = best + 1 < _lut.length ? _lut[best + 1].u : (closed ? maxU + _lut[1].u : maxU);
        enum float invPhi = 0.6180339887f;
        float a = hi - (hi - lo) * invPhi;
        float b = lo + (hi - lo) * invPhi;
        float fa = (evaluate(wrapParam(a)) - p).lengthSquared;
        float fb = (evaluate(wrapParam(b)) - p).lengthSquared;
        foreach (_; 0 .. 40) {
            if (fa < fb) {
                hi = b;
                b = a;
                fb = fa;
                a = hi - (hi - lo) * invPhi;
                fa = (evaluate(wrapParam(a)) - p).lengthSquared;
            } else {
                lo = a;
                a = b;
                fa = fb;
                b = lo + (hi - lo) * invPhi;
                fb = (evaluate(wrapParam(b)) - p).lengthSquared;
            }
        }
        immutable u = wrapParam((lo + hi) * 0.5f);
        hit.param = u;
        hit.position = evaluate(u);
        hit.distance = distanceAtParam(u);
        hit.separation = (hit.position - p).length;
        immutable f = frameAtDistance(hit.distance, mode);
        hit.lateral = (p - hit.position).dot(f.binormal);
        return hit;
    }

    // ------------------------------------------------------------------

    private bool locate(float u, out uint seg, out float t) const pure nothrow @nogc {
        immutable segs = segmentCount();
        if (segs == 0) return false;
        u = wrapParam(u);
        if (u >= segs) {
            seg = segs - 1;
            t = 1;
            return true;
        }
        if (u <= 0) {
            seg = 0;
            t = 0;
            return true;
        }
        seg = cast(uint) u;
        t = u - seg;
        return true;
    }

    private float wrapParam(float u) const pure nothrow @nogc {
        immutable segs = cast(float) segmentCount();
        if (!closed || segs <= 0) return u < 0 ? 0 : (u > segs ? segs : u);
        while (u < 0) u += segs;
        while (u >= segs) u -= segs;
        return u;
    }

    private float wrapDistance(float s) const pure nothrow @nogc {
        if (_length <= 0) return 0;
        if (!closed) return s < 0 ? 0 : (s > _length ? _length : s);
        while (s < 0) s += _length;
        while (s > _length) s -= _length;
        return s;
    }

    private Vec3 rmfNormalAt(float s) const pure nothrow @nogc @trusted {
        size_t lo = 0, hi = _lut.length - 1;
        while (hi - lo > 1) {
            immutable mid = (lo + hi) / 2;
            if (_lut[mid].s <= s) lo = mid;
            else hi = mid;
        }
        immutable ds = _lut[hi].s - _lut[lo].s;
        immutable f = ds > 0 ? (s - _lut[lo].s) / ds : 0;
        return (_lut[lo].rmfNormal * (1 - f) + _lut[hi].rmfNormal * f).normalized;
    }

    private Vec3 initialNormal(Vec3 t) const pure nothrow @nogc {
        Vec3 n = up - t * up.dot(t);
        if (n.lengthSquared < 1e-6f) {
            immutable alt = fabsf(t.x) < 0.9f ? Vec3(1, 0, 0) : Vec3(0, 0, 1);
            n = alt - t * alt.dot(t);
        }
        return n.normalized;
    }

    private void crPoints(uint seg, out Vec3 p0, out Vec3 p1, out Vec3 p2, out Vec3 p3) const pure nothrow @nogc @trusted {
        immutable n = cast(int) points.length;
        Vec3 at(int i) {
            if (closed) return points[((i % n) + n) % n];
            if (i < 0) return points[0] * 2 - points[1];          // phantom start
            if (i >= n) return points[n - 1] * 2 - points[n - 2]; // phantom end
            return points[i];
        }
        immutable i = cast(int) seg;
        p0 = at(i - 1);
        p1 = at(i);
        p2 = at(i + 1);
        p3 = at(i + 2);
    }

    private void bezierPoints(uint seg, out Vec3 b0, out Vec3 b1, out Vec3 b2, out Vec3 b3) const pure nothrow @nogc @trusted {
        immutable n = points.length;
        immutable base = seg * 3;
        b0 = points[base];
        b1 = points[base + 1];
        b2 = points[base + 2];
        b3 = points[(base + 3) % (closed ? n : n + 1)];
    }
}

// ---------------------------------------------------------------------------
// Curve primitives
// ---------------------------------------------------------------------------

/// Cubic Bézier point.
Vec3 bezierPoint(Vec3 b0, Vec3 b1, Vec3 b2, Vec3 b3, float t) pure nothrow @nogc {
    immutable m = 1 - t;
    return b0 * (m * m * m) + b1 * (3 * m * m * t) + b2 * (3 * m * t * t) + b3 * (t * t * t);
}

/// Cubic Bézier first derivative.
Vec3 bezierDerivative(Vec3 b0, Vec3 b1, Vec3 b2, Vec3 b3, float t) pure nothrow @nogc {
    immutable m = 1 - t;
    return (b1 - b0) * (3 * m * m) + (b2 - b1) * (6 * m * t) + (b3 - b2) * (3 * t * t);
}

/**
 * Catmull-Rom point between `p1` and `p2` (Barry–Goldman pyramid) with knot
 * exponent `alpha` (0.5 = centripetal).
 */
Vec3 catmullRomPoint(Vec3 p0, Vec3 p1, Vec3 p2, Vec3 p3, float t, float alpha = 0.5f) pure nothrow @nogc {
    float knot(Vec3 a, Vec3 b) {
        immutable d = (b - a).lengthSquared;
        immutable k = purePow(d, alpha * 0.5f);
        return k < 1e-4f ? 1e-4f : k;
    }
    immutable t0 = 0.0f;
    immutable t1 = t0 + knot(p0, p1);
    immutable t2 = t1 + knot(p1, p2);
    immutable t3 = t2 + knot(p2, p3);
    immutable tt = t1 + (t2 - t1) * t;

    immutable a1 = p0 * ((t1 - tt) / (t1 - t0)) + p1 * ((tt - t0) / (t1 - t0));
    immutable a2 = p1 * ((t2 - tt) / (t2 - t1)) + p2 * ((tt - t1) / (t2 - t1));
    immutable a3 = p2 * ((t3 - tt) / (t3 - t2)) + p3 * ((tt - t2) / (t3 - t2));
    immutable b1 = a1 * ((t2 - tt) / (t2 - t0)) + a2 * ((tt - t0) / (t2 - t0));
    immutable b2 = a2 * ((t3 - tt) / (t3 - t1)) + a3 * ((tt - t1) / (t3 - t1));
    return b1 * ((t2 - tt) / (t2 - t1)) + b2 * ((tt - t1) / (t2 - t1));
}

/// Double-reflection transport of normal `n0` from (`x0`, `t0`) to (`x1`, `t1`)
/// (Wang et al. 2008, rotation-minimizing frames).
private Vec3 transportNormal(Vec3 x0, Vec3 t0, Vec3 n0, Vec3 x1, Vec3 t1) pure nothrow @nogc {
    immutable v1 = x1 - x0;
    immutable c1 = v1.dot(v1);
    if (c1 < 1e-12f) return n0;
    immutable nL = n0 - v1 * (2 / c1 * v1.dot(n0));
    immutable tL = t0 - v1 * (2 / c1 * v1.dot(t0));
    immutable v2 = t1 - tL;
    immutable c2 = v2.dot(v2);
    if (c2 < 1e-12f) return nL.normalized;
    return (nL - v2 * (2 / c2 * v2.dot(nL))).normalized;
}

/// Rodrigues rotation of `v` around unit `axis` by `angle` radians.
private Vec3 rotateAround(Vec3 v, Vec3 axis, float angle) pure nothrow @nogc {
    import core.stdc.math : cosf, sinf;
    immutable c = cosf(angle);
    immutable s = sinf(angle);
    return v * c + axis.cross(v) * s + axis * (axis.dot(v) * (1 - c));
}

// `core.stdc.math` pow/acos may set errno, so druntime does not mark them
// `pure`; the results here never depend on errno.
private float purePow(float a, float b) pure nothrow @nogc @trusted {
    import core.stdc.math : powf;
    alias Fn = float function(float, float) pure nothrow @nogc;
    return (cast(Fn) &powf)(a, b);
}

private float pureAcos(float a) pure nothrow @nogc @trusted {
    import core.stdc.math : acosf;
    alias Fn = float function(float) pure nothrow @nogc;
    return (cast(Fn) &acosf)(a);
}

private float clamp(float v, float lo, float hi) pure nothrow @nogc {
    return v < lo ? lo : (v > hi ? hi : v);
}

// ---------------------------------------------------------------------------
// Ribbon extrusion
// ---------------------------------------------------------------------------

struct RibbonOptions {
    /// Full width across the curve (metres).
    float width = 8.0f;
    /// Target spacing between cross-sections along the curve (metres).
    float step = 2.0f;
    /// Vertices across = `widthSegments + 1`.
    uint widthSegments = 1;
    /// Shift of the ribbon centre along the binormal (lanes, sidewalks).
    float lateralOffset = 0;
    /// Lift along the frame normal (avoid z-fighting with terrain).
    float verticalOffset = 0;
    /// Metres of curve per texture repeat along `v`.
    float uvLength = 8.0f;
    FrameMode frameMode = FrameMode.upVector;
}

/// CPU mesh produced by `extrudeRibbon`.
struct RibbonMesh {
    Pod!TexVert[] vertices;
    Pod!uint[] indices;
}

/**
 * Extrude a flat ribbon along `spline` (must be baked). `u` runs across the
 * width (0 = left, 1 = right), `v` along the curve (`distance / uvLength`).
 * Front faces point along the frame normal (counter-clockwise seen from
 * above). Closed curves reuse the first cross-section's positions with a
 * separate seam row so `v` stays continuous. Load-time; allocates.
 */
RibbonMesh extrudeRibbon(ref const Spline3 spline, RibbonOptions opts = RibbonOptions.init) {
    RibbonMesh mesh;
    if (!spline.baked || spline.length <= 0 || opts.width <= 0) return mesh;
    immutable float stepLen = opts.step > 0.01f ? opts.step : 0.01f;
    uint rows = cast(uint)(spline.length / stepLen + 0.5f);
    if (rows < 1) rows = 1;
    immutable cols = (opts.widthSegments == 0 ? 1 : opts.widthSegments) + 1;
    immutable uvLen = opts.uvLength > 0 ? opts.uvLength : 1;

    mesh.vertices.reserve((rows + 1) * cols);
    mesh.indices.reserve(rows * (cols - 1) * 6);
    foreach (r; 0 .. rows + 1) {
        immutable s = spline.length * r / rows;
        // A closed curve's last row sits exactly on the first one.
        immutable f = spline.frameAtDistance(closedSafe(spline, s, r == rows), opts.frameMode);
        immutable centre = f.position + f.binormal * opts.lateralOffset + f.normal * opts.verticalOffset;
        foreach (c; 0 .. cols) {
            immutable across = cast(float) c / (cols - 1);
            immutable p = centre + f.binormal * ((across - 0.5f) * opts.width);
            TexVert v;
            v.pos = [p.x, p.y, p.z];
            v.normal = [f.normal.x, f.normal.y, f.normal.z];
            v.uv = [across, s / uvLen];
            mesh.vertices ~= v;
        }
    }
    foreach (r; 0 .. rows) {
        foreach (c; 0 .. cols - 1) {
            immutable uint a = r * cols + c;
            immutable uint b = a + 1;
            immutable uint d = a + cols;
            immutable uint e = d + 1;
            // Columns run along +binormal, rows along +tangent and
            // binormal × tangent = normal, so (a, b, d) is CCW seen from the normal.
            mesh.indices ~= [a, b, d, b, e, d];
        }
    }
    return mesh;
}

private float closedSafe(ref const Spline3 spline, float s, bool lastRow) pure nothrow @nogc {
    if (spline.closed && lastRow) return 0;
    if (!spline.closed && lastRow) return spline.length;
    return s;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

version (unittest) private bool near(float a, float b, float eps = 1e-3f) pure nothrow @nogc {
    return fabsf(a - b) <= eps;
}

version (unittest) private bool nearV(Vec3 a, Vec3 b, float eps = 1e-3f) pure nothrow @nogc {
    return (a - b).length <= eps;
}

@("spline.catmullRomInterpolatesControlPoints") unittest {
    Spline3 s;
    s.points = [Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(20, 0, 10), Vec3(30, 5, 10)];
    assert(s.segmentCount == 3);
    foreach (i, p; s.points) assert(nearV(s.evaluate(i), p));
    // Uniform variant too.
    s.alpha = 0;
    foreach (i, p; s.points) assert(nearV(s.evaluate(i), p));
}

@("spline.straightLineArcLength") unittest {
    Spline3 s;
    s.points = [Vec3(0, 0, 0), Vec3(25, 0, 0), Vec3(50, 0, 0), Vec3(100, 0, 0)];
    s.rebuild(64);
    assert(near(s.length, 100, 0.05f));
    // Constant-speed sampling despite uneven control point spacing.
    assert(nearV(s.sampleAtDistance(30), Vec3(30, 0, 0), 0.05f));
    assert(nearV(s.sampleAtDistance(75), Vec3(75, 0, 0), 0.05f));
    assert(nearV(s.sampleAtDistance(-5), Vec3(0, 0, 0)));
    assert(nearV(s.sampleAtDistance(1000), Vec3(100, 0, 0)));
    assert(nearV(s.tangentAtDistance(50), Vec3(1, 0, 0)));
}

@("spline.bezierQuarterCircleLength") unittest {
    import std.math : PI;
    // Standard cubic approximation of a quarter circle of radius 10.
    enum float k = 0.5522847498f * 10;
    Spline3 s;
    s.kind = SplineKind.bezier;
    s.points = [Vec3(10, 0, 0), Vec3(10, 0, k), Vec3(k, 0, 10), Vec3(0, 0, 10)];
    assert(s.segmentCount == 1);
    s.rebuild(128);
    assert(near(s.length, cast(float)(PI * 10 / 2), 0.02f));
    assert(nearV(s.evaluate(0), Vec3(10, 0, 0)) && nearV(s.evaluate(1), Vec3(0, 0, 10)));
    // Midpoint by distance lies on the 45° diagonal.
    immutable mid = s.sampleAtDistance(s.length / 2);
    assert(near(mid.x, mid.z, 0.01f));
    assert(near(mid.length, 10, 0.03f));
    // Analytic derivative matches a finite difference.
    immutable d = s.derivative(0.3f);
    immutable fd = (s.evaluate(0.3001f) - s.evaluate(0.2999f)) / 0.0002f;
    assert(nearV(d, fd, 0.05f));
}

@("spline.closedLoopWrapsAndFramesStayContinuous") unittest {
    Spline3 s;
    s.closed = true;
    s.points = [Vec3(0, 0, 0), Vec3(50, 0, 0), Vec3(50, 0, 50), Vec3(0, 0, 50)];
    assert(s.segmentCount == 4);
    s.rebuild(48);
    assert(s.length > 150 && s.length < 220);
    assert(nearV(s.sampleAtDistance(0), s.sampleAtDistance(s.length), 1e-2f));
    assert(nearV(s.sampleAtDistance(-1), s.sampleAtDistance(s.length - 1), 1e-2f));
    // A flat loop: both frame modes keep the normal pointing up.
    foreach (i; 0 .. 20) {
        immutable dist = s.length * i / 20;
        immutable fu = s.frameAtDistance(dist, FrameMode.upVector);
        immutable fr = s.frameAtDistance(dist, FrameMode.rotationMinimizing);
        assert(fu.normal.y > 0.999f);
        assert(fr.normal.y > 0.99f);
        assert(near(fu.tangent.dot(fu.normal), 0) && near(fu.tangent.dot(fu.binormal), 0));
    }
}

@("spline.rmfHandlesVerticalTangent") unittest {
    // A climb that goes straight up: upVector mode must fall back to RMF.
    Spline3 s;
    s.kind = SplineKind.bezier;
    s.points = [Vec3(0, 0, 0), Vec3(0, 10, 0), Vec3(0, 20, 0), Vec3(0, 30, 0)];
    s.rebuild();
    immutable f = s.frameAtDistance(15);
    assert(nearV(f.tangent, Vec3(0, 1, 0)));
    assert(near(f.normal.length, 1) && near(f.binormal.length, 1));
    assert(near(f.normal.dot(f.tangent), 0) && near(f.binormal.dot(f.normal), 0));
}

@("spline.closestPointAndLateralOffset") unittest {
    Spline3 s;
    s.points = [Vec3(0, 0, 0), Vec3(100, 0, 0)];
    s.rebuild();
    // Travelling +X with +Y up, right (tangent × up) is +Z.
    auto hit = s.closestPoint(Vec3(40, 0, -3));
    assert(near(hit.distance, 40, 0.01f));
    assert(nearV(hit.position, Vec3(40, 0, 0), 0.01f));
    assert(near(hit.separation, 3, 0.01f));
    assert(near(hit.lateral, -3, 0.01f));
    assert(near(s.closestPoint(Vec3(40, 0, 2)).lateral, 2, 0.01f));
    assert(near(s.closestPoint(Vec3(-20, 0, 0)).distance, 0, 0.01f));

    Spline3 curve;
    curve.points = [Vec3(0, 0, 0), Vec3(30, 0, 10), Vec3(60, 0, -10), Vec3(90, 0, 0)];
    curve.rebuild(64);
    immutable target = curve.sampleAtDistance(57);
    immutable h2 = curve.closestPoint(target + Vec3(0, 2, 0));
    assert(near(h2.distance, 57, 0.1f));
}

@("spline.nogcQueriesAfterBake") unittest {
    Spline3 s;
    s.points = [Vec3(0, 0, 0), Vec3(10, 0, 5), Vec3(20, 0, 0)];
    s.rebuild();
    float acc = 0;
    () nothrow @nogc {
        acc += s.sampleAtDistance(3).x;
        acc += s.frameAtDistance(4).normal.y;
        acc += s.closestPoint(Vec3(5, 1, 1)).distance;
    }();
    assert(acc > 0);
}

@("spline.ribbonExtrusion") unittest {
    Spline3 s;
    s.points = [Vec3(0, 0, 0), Vec3(40, 0, 0)];
    s.rebuild();
    RibbonOptions o;
    o.width = 8;
    o.step = 10;
    o.widthSegments = 2;
    o.uvLength = 20;
    o.verticalOffset = 0.05f;
    auto m = extrudeRibbon(s, o);
    assert(m.vertices.length == 5 * 3); // 4 rows of quads → 5 cross-sections × 3 columns
    assert(m.indices.length == 4 * 2 * 6);
    foreach (i; m.indices) assert(i < m.vertices.length);
    // Travelling +X, right is +Z: column 0 (left) at z=-4, last column at z=+4.
    assert(near(m.vertices[0].pos[2], -4) && near(m.vertices[2].pos[2], 4));
    assert(near(m.vertices[0].pos[1], 0.05f));
    assert(near(m.vertices[$ - 1].pos[0], 40) && near(m.vertices[$ - 1].uv[1], 2));
    foreach (ref v; m.vertices) assert(near(v.normal[1], 1));
    // Triangle winding faces up (+Y).
    Vec3 P(uint i) { return Vec3(m.vertices[i].pos[0], m.vertices[i].pos[1], m.vertices[i].pos[2]); }
    immutable n = (P(m.indices[1]) - P(m.indices[0])).cross(P(m.indices[2]) - P(m.indices[0]));
    assert(n.y > 0);

    // Closed loop: last cross-section duplicates the first (seam).
    Spline3 loop;
    loop.closed = true;
    loop.points = [Vec3(0, 0, 0), Vec3(20, 0, 0), Vec3(20, 0, 20), Vec3(0, 0, 20)];
    loop.rebuild();
    auto lm = extrudeRibbon(loop, o);
    immutable cols = 3;
    immutable lastRow = lm.vertices.length - cols;
    foreach (c; 0 .. cols)
        foreach (k; 0 .. 3)
            assert(near(lm.vertices[c].pos[k], lm.vertices[lastRow + c].pos[k], 1e-3f));
}
