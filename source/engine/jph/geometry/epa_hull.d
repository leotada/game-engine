// Jolt — Geometry/EPAConvexHullBuilder.h port.
//
// A convex-hull builder specialised for the EPA penetration-depth algorithm.
// Trades accuracy for speed and aborts gracefully when numerical issues create
// hull defects.
//
// Differences from the C++ original:
//  * Triangles are stored in a fixed-size pool indexed by `int` handles;
//    -1 means "null". This lets us avoid raw `Triangle*` pointers in @safe
//    code and keeps the whole structure trivially copyable.
//  * The triangle priority queue is a hand-rolled binary max-heap stored in
//    a flat int[256] buffer (Jolt uses BinaryHeapPush/Pop on a StaticArray
//    of pointers).
//  * Positions are read through a `const(StaticArray!(Vec3, cMaxPoints))*`
//    held by the builder, mirroring Jolt's reference semantics.
//
// Source: ref/JoltPhysics/Jolt/Geometry/EPAConvexHullBuilder.h.
module engine.jph.geometry.epa_hull;

import std.math : fabs;
import engine.jph.math.vec3;
import engine.jph.core.staticarray : StaticArray;

@safe:

enum int cMaxTriangles  = 256;
enum int cMaxPoints     = cMaxTriangles / 2; // 128
enum int cMaxEdgeLength = 128;
enum float cMinTriangleArea    = 1.0e-10f;
enum float cBarycentricEpsilon = 1.0e-3f;

alias EPAPoints = StaticArray!(Vec3, cMaxPoints);

/// Edge of a triangle. mNeighbourTriangle == -1 means "no neighbour".
struct Edge {
@safe:
    int mNeighbourTriangle = -1;
    int mNeighbourEdge = 0;
    int mStartIdx = 0;
}

/// Single triangle in the EPA hull.
struct Triangle {
@safe:
    Edge[3] mEdge;
    Vec3 mNormal;
    Vec3 mCentroid;
    float mClosestLenSq = float.max;
    float[2] mLambda = [0.0f, 0.0f];
    bool mLambdaRelativeTo0;
    bool mClosestPointInterior;
    bool mRemoved;
    bool mInQueue;

    /// Initialise from 3 indices and a positions array.
    void init(int i0, int i1, int i2, const(Vec3)[] inPositions) pure nothrow @nogc {
        assert(i0 != i1 && i0 != i2 && i1 != i2);
        mEdge[0] = Edge(-1, 0, i0);
        mEdge[1] = Edge(-1, 0, i1);
        mEdge[2] = Edge(-1, 0, i2);
        mClosestLenSq = float.max;
        mClosestPointInterior = false;
        mRemoved = false;
        mInQueue = false;

        immutable Vec3 y0 = inPositions[i0];
        immutable Vec3 y1 = inPositions[i1];
        immutable Vec3 y2 = inPositions[i2];

        mCentroid = (y0 + y1 + y2) / 3.0f;

        immutable Vec3 y10 = y1 - y0;
        immutable Vec3 y20 = y2 - y0;
        immutable Vec3 y21 = y2 - y1;

        // Pick the more accurate edge pair. See box2d.org "troublesome
        // triangle" article — using the two shortest edges to compute the
        // normal greatly reduces numerical drift on slivers.
        immutable float y20sq = y20.Dot(y20);
        immutable float y21sq = y21.Dot(y21);

        if (y20sq < y21sq) {
            mNormal = y10.Cross(y20);
            immutable float nLenSq = mNormal.LengthSq();
            if (nLenSq > cMinTriangleArea) {
                immutable float cDotN = mCentroid.Dot(mNormal);
                mClosestLenSq = fabs(cDotN) * cDotN / nLenSq;

                immutable float y10sq = y10.LengthSq();
                immutable float y10y20 = y10.Dot(y20);
                immutable float det = y10sq * y20sq - y10y20 * y10y20;
                if (det > 0.0f) {
                    immutable float y0y10 = y0.Dot(y10);
                    immutable float y0y20 = y0.Dot(y20);
                    immutable float l0 = (y10y20 * y0y20 - y20sq * y0y10) / det;
                    immutable float l1 = (y10y20 * y0y10 - y10sq * y0y20) / det;
                    mLambda[0] = l0;
                    mLambda[1] = l1;
                    mLambdaRelativeTo0 = true;
                    if (l0 > -cBarycentricEpsilon
                            && l1 > -cBarycentricEpsilon
                            && l0 + l1 < 1.0f + cBarycentricEpsilon)
                        mClosestPointInterior = true;
                }
            }
        } else {
            mNormal = y10.Cross(y21);
            immutable float nLenSq = mNormal.LengthSq();
            if (nLenSq > cMinTriangleArea) {
                immutable float cDotN = mCentroid.Dot(mNormal);
                mClosestLenSq = fabs(cDotN) * cDotN / nLenSq;

                immutable float y10sq = y10.LengthSq();
                immutable float y10y21 = y10.Dot(y21);
                immutable float det = y10sq * y21sq - y10y21 * y10y21;
                if (det > 0.0f) {
                    immutable float y1y10 = y1.Dot(y10);
                    immutable float y1y21 = y1.Dot(y21);
                    immutable float l0 = (y21sq * y1y10 - y10y21 * y1y21) / det;
                    immutable float l1 = (y10y21 * y1y10 - y10sq * y1y21) / det;
                    mLambda[0] = l0;
                    mLambda[1] = l1;
                    mLambdaRelativeTo0 = false;
                    if (l0 > -cBarycentricEpsilon
                            && l1 > -cBarycentricEpsilon
                            && l0 + l1 < 1.0f + cBarycentricEpsilon)
                        mClosestPointInterior = true;
                }
            }
        }
    }

    bool IsFacing(Vec3 inPos) const pure nothrow @nogc {
        assert(!mRemoved);
        return mNormal.Dot(inPos - mCentroid) > 0.0f;
    }

    bool IsFacingOrigin() const pure nothrow @nogc {
        assert(!mRemoved);
        return mNormal.Dot(mCentroid) < 0.0f;
    }

    int nextEdge(int i) const pure nothrow @nogc { return (i + 1) % 3; }
}

alias Edges        = StaticArray!(Edge, cMaxEdgeLength);
alias NewTriangles = StaticArray!(int,  cMaxEdgeLength);

/// Convex hull builder used by EPA. Index-based pool + binary-heap queue.
struct EPAConvexHullBuilder {
@safe:
    @disable this(this);

    private const(EPAPoints)* mPositions;

    // Triangle pool.
    private Triangle[cMaxTriangles] mPool;
    private int[cMaxTriangles] mFreeStack;
    private int mFreeCount;
    private int mHighWatermark;

    // Priority queue (max-heap; smallest mClosestLenSq sits on top).
    private int[cMaxTriangles] mQueueBuf;
    private int mQueueSize;

    /// Build a hull that reads from the caller's points list.
    this(ref const(EPAPoints) inPositions) @trusted pure nothrow @nogc {
        mPositions = &inPositions;
    }

    /// Direct mutable access to a triangle by handle.
    ref Triangle tri(int h) return pure nothrow @nogc {
        assert(h >= 0 && h < mHighWatermark);
        return mPool[h];
    }

    /// Read-only access to a triangle by handle.
    ref const(Triangle) triC(int h) const return pure nothrow @nogc {
        assert(h >= 0 && h < mHighWatermark);
        return mPool[h];
    }

    private const(Vec3) posAt(int idx) const @trusted pure nothrow @nogc {
        return (*mPositions)[cast(uint) idx];
    }

    private const(Vec3)[] posSlice() const @trusted pure nothrow @nogc {
        return (*mPositions).data();
    }

    /// Reset and seed with two back-to-back triangles sharing 3 points.
    void Initialize(int i1, int i2, int i3) pure nothrow @nogc {
        mFreeCount = 0;
        mHighWatermark = 0;
        mQueueSize = 0;

        immutable int t1 = createTriangle(i1, i2, i3);
        immutable int t2 = createTriangle(i1, i3, i2);
        assert(t1 >= 0 && t2 >= 0);

        sLinkTriangle(t1, 0, t2, 2);
        sLinkTriangle(t1, 1, t2, 1);
        sLinkTriangle(t1, 2, t2, 0);

        queuePush(t1);
        queuePush(t2);
    }

    bool HasNextTriangle() const pure nothrow @nogc { return mQueueSize > 0; }

    int PeekClosestTriangleInQueue() const pure nothrow @nogc {
        assert(mQueueSize > 0);
        return mQueueBuf[0];
    }

    int PopClosestTriangleFromQueue() pure nothrow @nogc {
        return queuePop();
    }

    /// Find the triangle on which inPosition is the furthest in front.
    int FindFacingTriangle(Vec3 inPos, ref float outBestDistSq) pure nothrow @nogc {
        int best = -1;
        float bestSq = 0.0f;
        foreach (i; 0 .. mQueueSize) {
            immutable int h = mQueueBuf[i];
            if (mPool[h].mRemoved) continue;
            immutable float dot = mPool[h].mNormal.Dot(inPos - mPool[h].mCentroid);
            if (dot > 0.0f) {
                immutable float dsq = dot * dot / mPool[h].mNormal.LengthSq();
                if (dsq > bestSq) {
                    best = h;
                    bestSq = dsq;
                }
            }
        }
        outBestDistSq = bestSq;
        return best;
    }

    /// Expand the hull with a new support point. Returns false on numerical
    /// failure (caller should bail out cleanly).
    bool AddPoint(int inFacingTri, int inIdx, float inClosestDistSq,
                  ref NewTriangles outTris) pure nothrow @nogc {
        immutable Vec3 pos = posAt(inIdx);

        Edges edges;
        if (!findEdge(inFacingTri, pos, edges))
            return false;

        immutable int n = cast(int) edges.size();
        foreach (i; 0 .. n) {
            int nt = createTriangle(edges[cast(uint) i].mStartIdx,
                                    edges[cast(uint)((i + 1) % n)].mStartIdx,
                                    inIdx);
            if (nt < 0)
                return false;
            outTris.push_back(nt);

            if ((mPool[nt].mClosestPointInterior && mPool[nt].mClosestLenSq < inClosestDistSq)
                    || mPool[nt].mClosestLenSq < 0.0f)
                queuePush(nt);
        }

        foreach (i; 0 .. n) {
            sLinkTriangle(outTris[cast(uint) i], 0,
                          edges[cast(uint) i].mNeighbourTriangle,
                          edges[cast(uint) i].mNeighbourEdge);
            sLinkTriangle(outTris[cast(uint) i], 1,
                          outTris[cast(uint)((i + 1) % n)], 2);
        }
        return true;
    }

    /// Return a triangle to the pool. Assumes the triangle has been unlinked.
    void FreeTriangle(int h) pure nothrow @nogc {
        assert(h >= 0 && h < mHighWatermark);
        debug {
            assert(mPool[h].mRemoved);
            foreach (ref e; mPool[h].mEdge) assert(e.mNeighbourTriangle == -1);
        }
        mFreeStack[mFreeCount++] = h;
    }

    // ---- internals ----

    private int createTriangle(int i0, int i1, int i2) pure nothrow @nogc {
        int h;
        if (mFreeCount > 0) {
            h = mFreeStack[--mFreeCount];
        } else {
            if (mHighWatermark >= cMaxTriangles)
                return -1;
            h = mHighWatermark++;
        }
        mPool[h].init(i0, i1, i2, posSlice());
        return h;
    }

    private void sLinkTriangle(int h1, int e1, int h2, int e2) pure nothrow @nogc {
        assert(e1 >= 0 && e1 < 3);
        assert(e2 >= 0 && e2 < 3);
        assert(mPool[h1].mEdge[e1].mNeighbourTriangle == -1);
        assert(mPool[h2].mEdge[e2].mNeighbourTriangle == -1);
        // Vertex-match invariant.
        assert(mPool[h1].mEdge[e1].mStartIdx
                == mPool[h2].mEdge[(e2 + 1) % 3].mStartIdx);
        assert(mPool[h2].mEdge[e2].mStartIdx
                == mPool[h1].mEdge[(e1 + 1) % 3].mStartIdx);

        mPool[h1].mEdge[e1].mNeighbourTriangle = h2;
        mPool[h1].mEdge[e1].mNeighbourEdge     = e2;
        mPool[h2].mEdge[e2].mNeighbourTriangle = h1;
        mPool[h2].mEdge[e2].mNeighbourEdge     = e1;
    }

    private void unlinkTriangle(int h) pure nothrow @nogc {
        foreach (i; 0 .. 3) {
            immutable int nh = mPool[h].mEdge[i].mNeighbourTriangle;
            if (nh != -1) {
                immutable int neIdx = mPool[h].mEdge[i].mNeighbourEdge;
                assert(mPool[nh].mEdge[neIdx].mNeighbourTriangle == h);
                assert(mPool[nh].mEdge[neIdx].mNeighbourEdge == i);
                mPool[nh].mEdge[neIdx].mNeighbourTriangle = -1;
                mPool[h].mEdge[i].mNeighbourTriangle = -1;
            }
        }
        if (!mPool[h].mInQueue)
            FreeTriangle(h);
    }

    /// DFS from `inFacing` collecting the silhouette edges around all
    /// triangles that face `inVertex`. Returns false if islands are detected
    /// (numerical precision failure) or fewer than 3 edges survive.
    private bool findEdge(int inFacing, Vec3 inVertex, ref Edges outEdges) pure nothrow @nogc {
        assert(outEdges.empty);
        assert(mPool[inFacing].IsFacing(inVertex));

        mPool[inFacing].mRemoved = true;

        struct Frame { int tri; int edge; int iter; }
        Frame[cMaxEdgeLength] stack;
        int sp = 0;
        stack[0] = Frame(inFacing, 0, -1);

        int nextExpectedStart = -1;

        for (;;) {
            ++stack[sp].iter;
            if (stack[sp].iter >= 3) {
                immutable int doomed = stack[sp].tri;
                unlinkTriangle(doomed);
                if (--sp < 0)
                    break;
            } else {
                immutable int curTri = stack[sp].tri;
                immutable int eIdx = (stack[sp].edge + stack[sp].iter) % 3;
                immutable int nh = mPool[curTri].mEdge[eIdx].mNeighbourTriangle;
                immutable int neIdx = mPool[curTri].mEdge[eIdx].mNeighbourEdge;
                immutable int eStart = mPool[curTri].mEdge[eIdx].mStartIdx;
                if (nh != -1 && !mPool[nh].mRemoved) {
                    if (mPool[nh].IsFacing(inVertex)) {
                        mPool[nh].mRemoved = true;
                        ++sp;
                        assert(sp < cMaxEdgeLength);
                        stack[sp] = Frame(nh, neIdx, 0);
                    } else {
                        if (eStart != nextExpectedStart && nextExpectedStart != -1)
                            return false;
                        nextExpectedStart = mPool[nh].mEdge[neIdx].mStartIdx;
                        outEdges.push_back(mPool[curTri].mEdge[eIdx]);
                    }
                }
            }
        }
        assert(outEdges.empty || outEdges[0].mStartIdx == nextExpectedStart);
        return outEdges.size() >= 3;
    }

    // ---- binary-heap queue (max-heap; predicate "a less-or-equal b" =
    //      a.mClosestLenSq > b.mClosestLenSq, so the top has the SMALLEST
    //      mClosestLenSq). Mirrors BinaryHeapPush/Pop. ----

    private bool less(int a, int b) const pure nothrow @nogc {
        return mPool[a].mClosestLenSq > mPool[b].mClosestLenSq;
    }

    private void queuePush(int h) pure nothrow @nogc {
        assert(mQueueSize < cMaxTriangles);
        mPool[h].mInQueue = true;
        mQueueBuf[mQueueSize++] = h;

        int cur = mQueueSize - 1;
        while (cur > 0) {
            immutable int parent = (cur - 1) >> 1;
            if (less(mQueueBuf[parent], mQueueBuf[cur])) {
                immutable int tmp = mQueueBuf[parent];
                mQueueBuf[parent] = mQueueBuf[cur];
                mQueueBuf[cur] = tmp;
                cur = parent;
            } else {
                break;
            }
        }
    }

    private int queuePop() pure nothrow @nogc {
        assert(mQueueSize > 0);
        immutable int top = mQueueBuf[0];

        --mQueueSize;
        if (mQueueSize > 0) {
            mQueueBuf[0] = mQueueBuf[mQueueSize];
            int largest = 0;
            for (;;) {
                immutable int child = (largest << 1) + 1;
                if (child >= mQueueSize) break;
                int prev = largest;
                if (less(mQueueBuf[largest], mQueueBuf[child]))
                    largest = child;
                immutable int child2 = child + 1;
                if (child2 < mQueueSize && less(mQueueBuf[largest], mQueueBuf[child2]))
                    largest = child2;
                if (largest == prev) break;
                immutable int tmp = mQueueBuf[prev];
                mQueueBuf[prev] = mQueueBuf[largest];
                mQueueBuf[largest] = tmp;
            }
        }
        return top;
    }
}

unittest {
    // Build a tetrahedron whose face containing the origin is found by
    // FindFacingTriangle; verify Initialize+heap basics.
    EPAPoints pts;
    pts.push_back(Vec3( 1, 0, 0));
    pts.push_back(Vec3(-1, 1, 0));
    pts.push_back(Vec3(-1,-1, 1));
    pts.push_back(Vec3(-1,-1,-1));

    auto hull = EPAConvexHullBuilder(pts);
    hull.Initialize(0, 1, 2);
    assert(hull.HasNextTriangle());

    immutable int top = hull.PeekClosestTriangleInQueue();
    assert(top >= 0);
}
