// Ported from meshoptimizer v1.3 (src/simplifier.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Position rescale and quadric error metrics. Upstream `simplifier.cpp` does
/// this math in `float` only; there is no `double` in that file.
module engine.meshopt.simplify.quadric;

import engine.meshopt.internal.vec : Vec3;
import engine.meshopt.simplify.topology : EdgeAdjacency, VertexKind, asU32, loadF, oppositeVertex;
import engine.meshopt.types : SimplifyOptions, SimplifyVertexFlags;

@safe:

package enum maxAttributes = 32;

package float sqrtF(float x) nothrow @nogc @trusted {
    import core.stdc.math : sqrtf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &sqrtf)(x);
}

package float fabsF(float x) nothrow @nogc @trusted {
    import core.stdc.math : fabsf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &fabsf)(x);
}

package struct Quadric {
    float a00 = 0, a11 = 0, a22 = 0;
    float a10 = 0, a20 = 0, a21 = 0;
    float b0 = 0, b1 = 0, b2 = 0, c = 0;
    float w = 0;
}

package struct QuadricGrad {
    float gx = 0, gy = 0, gz = 0, gw = 0;
}

package struct Reservoir {
    float x = 0, y = 0, z = 0;
    float r = 0, g = 0, b = 0;
    float w = 0;
}

package float normalize(ref Vec3 v) nothrow @nogc {
    float length = sqrtF(v.x * v.x + v.y * v.y + v.z * v.z);
    if (length > 0) {
        v.x /= length;
        v.y /= length;
        v.z /= length;
    }
    return length;
}

package void quadricAdd(ref Quadric q, const(Quadric) r) nothrow @nogc {
    q.a00 += r.a00;
    q.a11 += r.a11;
    q.a22 += r.a22;
    q.a10 += r.a10;
    q.a20 += r.a20;
    q.a21 += r.a21;
    q.b0 += r.b0;
    q.b1 += r.b1;
    q.b2 += r.b2;
    q.c += r.c;
    q.w += r.w;
}

package void quadricAddGrad(ref QuadricGrad g, const(QuadricGrad) r) nothrow @nogc {
    g.gx += r.gx;
    g.gy += r.gy;
    g.gz += r.gz;
    g.gw += r.gw;
}

package void quadricAddGrads(scope QuadricGrad[] g, scope const(QuadricGrad)[] r, size_t attributeCount) nothrow @nogc {
    foreach (k; 0 .. attributeCount) {
        g[k].gx += r[k].gx;
        g[k].gy += r[k].gy;
        g[k].gz += r[k].gz;
        g[k].gw += r[k].gw;
    }
}

package float quadricEval(const(Quadric) q, const(Vec3) v) nothrow @nogc {
    float rx = (q.b0 + q.a10 * v.y) * 2.0f;
    float ry = (q.b1 + q.a21 * v.z) * 2.0f;
    float rz = (q.b2 + q.a20 * v.x) * 2.0f;
    rx += q.a00 * v.x;
    ry += q.a11 * v.y;
    rz += q.a22 * v.z;
    return q.c + rx * v.x + ry * v.y + rz * v.z;
}

package float quadricError(const(Quadric) q, const(Vec3) v) nothrow @nogc {
    float r = quadricEval(q, v);
    float s = q.w == 0.0f ? 0.0f : 1.0f / q.w;
    return fabsF(r) * s;
}

package float quadricErrorAttr(const(Quadric) q, const(QuadricGrad)[] g, size_t attributeCount, const(Vec3) v, const(float)[] va, bool clamped) nothrow @nogc {
    float r = quadricEval(q, v);
    foreach (k; 0 .. attributeCount) {
        float a = va[k];
        float gv = v.x * g[k].gx + v.y * g[k].gy + v.z * g[k].gz + g[k].gw;
        r += a * (a * q.w - 2 * gv);
    }
    float e = fabsF(r);
    return clamped ? (e < q.w ? e : q.w) : e;
}

package void quadricFromPlane(ref Quadric q, float a, float b, float c, float d, float w) nothrow @nogc {
    float aw = a * w;
    float bw = b * w;
    float cw = c * w;
    float dw = d * w;
    q.a00 = a * aw;
    q.a11 = b * bw;
    q.a22 = c * cw;
    q.a10 = a * bw;
    q.a20 = a * cw;
    q.a21 = b * cw;
    q.b0 = a * dw;
    q.b1 = b * dw;
    q.b2 = c * dw;
    q.c = d * dw;
    q.w = w;
}

package void quadricFromPoint(ref Quadric q, float x, float y, float z, float w) nothrow @nogc {
    q.a00 = w;
    q.a11 = w;
    q.a22 = w;
    q.a10 = 0;
    q.a20 = 0;
    q.a21 = 0;
    q.b0 = -x * w;
    q.b1 = -y * w;
    q.b2 = -z * w;
    q.c = (x * x + y * y + z * z) * w;
    q.w = w;
}

package void quadricFromTriangle(ref Quadric q, const(Vec3) p0, const(Vec3) p1, const(Vec3) p2, float weight) nothrow @nogc {
    Vec3 p10 = Vec3(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z);
    Vec3 p20 = Vec3(p2.x - p0.x, p2.y - p0.y, p2.z - p0.z);
    Vec3 normal = Vec3(p10.y * p20.z - p10.z * p20.y, p10.z * p20.x - p10.x * p20.z, p10.x * p20.y - p10.y * p20.x);
    float area = normalize(normal);
    float distance = normal.x * p0.x + normal.y * p0.y + normal.z * p0.z;
    quadricFromPlane(q, normal.x, normal.y, normal.z, -distance, sqrtF(area) * weight);
}

package void quadricFromTriangleEdge(ref Quadric q, const(Vec3) p0, const(Vec3) p1, const(Vec3) p2, float weight) nothrow @nogc {
    Vec3 p10 = Vec3(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z);
    float lengthsq = p10.x * p10.x + p10.y * p10.y + p10.z * p10.z;
    float length = sqrtF(lengthsq);
    Vec3 p20 = Vec3(p2.x - p0.x, p2.y - p0.y, p2.z - p0.z);
    float p20p = p20.x * p10.x + p20.y * p10.y + p20.z * p10.z;
    Vec3 perp = Vec3(p20.x * lengthsq - p10.x * p20p, p20.y * lengthsq - p10.y * p20p, p20.z * lengthsq - p10.z * p20p);
    normalize(perp);
    float distance = perp.x * p0.x + perp.y * p0.y + perp.z * p0.z;
    quadricFromPlane(q, perp.x, perp.y, perp.z, -distance, length * weight);
}

package void quadricFromAttributes(ref Quadric q, scope QuadricGrad[] g, const(Vec3) p0, const(Vec3) p1, const(Vec3) p2, scope const(float)[] va0, scope const(float)[] va1, scope const(float)[] va2, size_t attributeCount) nothrow @nogc {
    Vec3 p10 = Vec3(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z);
    Vec3 p20 = Vec3(p2.x - p0.x, p2.y - p0.y, p2.z - p0.z);
    Vec3 normal = Vec3(p10.y * p20.z - p10.z * p20.y, p10.z * p20.x - p10.x * p20.z, p10.x * p20.y - p10.y * p20.x);
    float area = sqrtF(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z) * 0.5f;
    float w = area;
    Vec3 v0 = p10;
    Vec3 v1 = p20;
    float d00 = v0.x * v0.x + v0.y * v0.y + v0.z * v0.z;
    float d01 = v0.x * v1.x + v0.y * v1.y + v0.z * v1.z;
    float d11 = v1.x * v1.x + v1.y * v1.y + v1.z * v1.z;
    float denom = d00 * d11 - d01 * d01;
    float denomr = denom == 0 ? 0.0f : 1.0f / denom;
    float gx1 = (d11 * v0.x - d01 * v1.x) * denomr;
    float gx2 = (d00 * v1.x - d01 * v0.x) * denomr;
    float gy1 = (d11 * v0.y - d01 * v1.y) * denomr;
    float gy2 = (d00 * v1.y - d01 * v0.y) * denomr;
    float gz1 = (d11 * v0.z - d01 * v1.z) * denomr;
    float gz2 = (d00 * v1.z - d01 * v0.z) * denomr;
    q = Quadric.init;
    q.w = w;
    foreach (k; 0 .. attributeCount) {
        float a0 = va0[k], a1 = va1[k], a2 = va2[k];
        float gx = gx1 * (a1 - a0) + gx2 * (a2 - a0);
        float gy = gy1 * (a1 - a0) + gy2 * (a2 - a0);
        float gz = gz1 * (a1 - a0) + gz2 * (a2 - a0);
        float gw = a0 - p0.x * gx - p0.y * gy - p0.z * gz;
        q.a00 += w * (gx * gx);
        q.a11 += w * (gy * gy);
        q.a22 += w * (gz * gz);
        q.a10 += w * (gy * gx);
        q.a20 += w * (gz * gx);
        q.a21 += w * (gz * gy);
        q.b0 += w * (gx * gw);
        q.b1 += w * (gy * gw);
        q.b2 += w * (gz * gw);
        q.c += w * (gw * gw);
        g[k].gx = w * gx;
        g[k].gy = w * gy;
        g[k].gz = w * gz;
        g[k].gw = w * gw;
    }
}

package void quadricVolumeGradient(ref QuadricGrad g, const(Vec3) p0, const(Vec3) p1, const(Vec3) p2) nothrow @nogc {
    Vec3 p10 = Vec3(p1.x - p0.x, p1.y - p0.y, p1.z - p0.z);
    Vec3 p20 = Vec3(p2.x - p0.x, p2.y - p0.y, p2.z - p0.z);
    Vec3 normal = Vec3(p10.y * p20.z - p10.z * p20.y, p10.z * p20.x - p10.x * p20.z, p10.x * p20.y - p10.y * p20.x);
    float area = normalize(normal) * 0.5f;
    g.gx = normal.x * area;
    g.gy = normal.y * area;
    g.gz = normal.z * area;
    g.gw = (-p0.x * normal.x - p0.y * normal.y - p0.z * normal.z) * area;
}

package bool quadricSolve(ref Vec3 p, const(Quadric) q, const(QuadricGrad) gv) nothrow @nogc {
    float a00 = q.a00, a11 = q.a11, a22 = q.a22;
    float a10 = q.a10, a20 = q.a20, a21 = q.a21;
    float x0 = -q.b0, x1 = -q.b1, x2 = -q.b2;
    float eps = 1e-6f * q.w;
    float d0 = a00;
    float l10 = a10 / d0;
    float l20 = a20 / d0;
    float d1 = a11 - a10 * l10;
    float dl21 = a21 - a20 * l10;
    float l21 = dl21 / d1;
    float d2 = a22 - a20 * l20 - dl21 * l21;
    float y0 = x0;
    float y1 = x1 - l10 * y0;
    float y2 = x2 - l20 * y0 - l21 * y1;
    float z0 = y0 / d0;
    float z1 = y1 / d1;
    float z2 = y2 / d2;
    float a30 = gv.gx, a31 = gv.gy, a32 = gv.gz;
    float x3 = -gv.gw;
    float l30 = a30 / d0;
    float dl31 = a31 - a30 * l10;
    float l31 = dl31 / d1;
    float dl32 = a32 - a30 * l20 - dl31 * l21;
    float l32 = dl32 / d2;
    float d3 = 0.0f - a30 * l30 - dl31 * l31 - dl32 * l32;
    float y3 = x3 - l30 * y0 - l31 * y1 - l32 * y2;
    float z3 = fabsF(d3) > eps ? y3 / d3 : 0.0f;
    float lambda = z3;
    float pz = z2 - l32 * lambda;
    float py = z1 - l21 * pz - l31 * lambda;
    float px = z0 - l10 * py - l20 * pz - l30 * lambda;
    p.x = px;
    p.y = py;
    p.z = pz;
    return fabsF(d0) > eps && fabsF(d1) > eps && fabsF(d2) > eps;
}

package void quadricReduceAttributes(ref Quadric q, const(Quadric) a, const(QuadricGrad)[] g, size_t attributeCount) nothrow @nogc {
    q.a00 += a.a00 * q.w;
    q.a11 += a.a11 * q.w;
    q.a22 += a.a22 * q.w;
    q.a10 += a.a10 * q.w;
    q.a20 += a.a20 * q.w;
    q.a21 += a.a21 * q.w;
    q.b0 += a.b0 * q.w;
    q.b1 += a.b1 * q.w;
    q.b2 += a.b2 * q.w;
    float iaw = a.w == 0 ? 0.0f : q.w / a.w;
    foreach (k; 0 .. attributeCount) {
        const(QuadricGrad) grad = g[k];
        q.a00 -= (grad.gx * grad.gx) * iaw;
        q.a11 -= (grad.gy * grad.gy) * iaw;
        q.a22 -= (grad.gz * grad.gz) * iaw;
        q.a10 -= (grad.gx * grad.gy) * iaw;
        q.a20 -= (grad.gx * grad.gz) * iaw;
        q.a21 -= (grad.gy * grad.gz) * iaw;
        q.b0 -= (grad.gx * grad.gw) * iaw;
        q.b1 -= (grad.gy * grad.gw) * iaw;
        q.b2 -= (grad.gz * grad.gw) * iaw;
    }
}

/// `result.length == 0` skips the write, matching a null destination. Extent is still returned.
package float rescalePositions(Vec3[] result, size_t vertexCount, ulong address, size_t strideFloats, const(uint)[] sparse, float[] outOffset) nothrow @nogc {
    float[3] minv = [float.max, float.max, float.max];
    float[3] maxv = [-float.max, -float.max, -float.max];
    foreach (i; 0 .. vertexCount) {
        uint ri = sparse.length ? sparse[i] : asU32(i);
        float x = loadF(address, ri * strideFloats + 0);
        float y = loadF(address, ri * strideFloats + 1);
        float z = loadF(address, ri * strideFloats + 2);
        if (result.length) {
            result[i].x = x;
            result[i].y = y;
            result[i].z = z;
        }
        float[3] v = [x, y, z];
        foreach (j; 0 .. 3) {
            float vj = v[j];
            minv[j] = minv[j] > vj ? vj : minv[j];
            maxv[j] = maxv[j] < vj ? vj : maxv[j];
        }
    }
    float extent = 0.0f;
    extent = (maxv[0] - minv[0]) < extent ? extent : (maxv[0] - minv[0]);
    extent = (maxv[1] - minv[1]) < extent ? extent : (maxv[1] - minv[1]);
    extent = (maxv[2] - minv[2]) < extent ? extent : (maxv[2] - minv[2]);
    if (result.length) {
        float scale = extent == 0 ? 0.0f : 1.0f / extent;
        foreach (i; 0 .. vertexCount) {
            result[i].x = (result[i].x - minv[0]) * scale;
            result[i].y = (result[i].y - minv[1]) * scale;
            result[i].z = (result[i].z - minv[2]) * scale;
        }
    }
    if (outOffset.length) {
        outOffset[0] = minv[0];
        outOffset[1] = minv[1];
        outOffset[2] = minv[2];
    }
    return extent;
}

package void rescaleAttributes(float[] result, ulong address, size_t strideFloats, scope const(float)[] weights, size_t attributeCount, scope const(uint)[] attributeRemap, const(uint)[] sparse, size_t vertexCount) nothrow @nogc {
    foreach (i; 0 .. vertexCount) {
        uint ri = sparse.length ? sparse[i] : asU32(i);
        foreach (k; 0 .. attributeCount) {
            uint rk = attributeRemap[k];
            float a = loadF(address, ri * strideFloats + rk);
            result[i * attributeCount + k] = a * weights[rk];
        }
    }
}

package void finalizeVertices(ulong posAddress, size_t posStride, ulong attrAddress, size_t attrStride, scope const(float)[] weights, size_t attributeCount, size_t vertexCount, const(Vec3)[] positions, const(float)[] attributes, const(uint)[] sparse, scope const(uint)[] attributeRemap, float vertexScale, scope const(float)[] offset, const(ubyte)[] vertexKind, const(ubyte)[] vertexUpdate, scope const(ubyte)[] vertexLock) nothrow @nogc {
    import engine.meshopt.simplify.topology : storeF;
    foreach (i; 0 .. vertexCount) {
        if (!vertexUpdate[i])
            continue;
        uint ri = sparse.length ? sparse[i] : asU32(i);
        if (vertexLock.length && (vertexLock[ri] & SimplifyVertexFlags.lock) != 0)
            continue;
        if (vertexKind[i] != VertexKind.locked) {
            Vec3 p = positions[i];
            storeF(posAddress, ri * posStride + 0, p.x * vertexScale + offset[0]);
            storeF(posAddress, ri * posStride + 1, p.y * vertexScale + offset[1]);
            storeF(posAddress, ri * posStride + 2, p.z * vertexScale + offset[2]);
        }
        if (attributeCount) {
            foreach (k; 0 .. attributeCount) {
                uint rk = attributeRemap[k];
                float value = attributes[i * attributeCount + k] / weights[rk];
                storeF(attrAddress, ri * attrStride + rk, value);
            }
        }
    }
}

package void fillFaceQuadrics(Quadric[] vertexQuadrics, QuadricGrad[] volumeGradients, scope const(uint)[] indices, size_t indexCount, const(Vec3)[] positions, const(uint)[] remap) nothrow @nogc {
    for (size_t i = 0; i < indexCount; i += 3) {
        uint i0 = indices[i + 0];
        uint i1 = indices[i + 1];
        uint i2 = indices[i + 2];
        Quadric q;
        quadricFromTriangle(q, positions[i0], positions[i1], positions[i2], 1.0f);
        quadricAdd(vertexQuadrics[remap[i0]], q);
        quadricAdd(vertexQuadrics[remap[i1]], q);
        quadricAdd(vertexQuadrics[remap[i2]], q);
        if (volumeGradients.length) {
            QuadricGrad gv;
            quadricVolumeGradient(gv, positions[i0], positions[i1], positions[i2]);
            quadricAddGrad(volumeGradients[remap[i0]], gv);
            quadricAddGrad(volumeGradients[remap[i1]], gv);
            quadricAddGrad(volumeGradients[remap[i2]], gv);
        }
    }
}

package void fillVertexQuadrics(Quadric[] vertexQuadrics, const(Vec3)[] positions, const(uint)[] remap, scope const(ubyte)[] vertexLock, const(uint)[] sparse, uint options) nothrow @nogc {
    float factor = (options & SimplifyOptions.regularizeLight) != 0 ? 1e-2f
        : ((options & SimplifyOptions.regularize) != 0 ? 1e-1f : 1e-7f);
    foreach (i; 0 .. positions.length) {
        if (remap[i] != i)
            continue;
        uint ri = sparse.length ? sparse[i] : asU32(i);
        bool priority = vertexLock.length != 0 && (vertexLock[ri] & SimplifyVertexFlags.priority) != 0;
        Vec3 p = positions[i];
        float w = vertexQuadrics[i].w * (priority ? 1.0f : factor);
        Quadric q;
        quadricFromPoint(q, p.x, p.y, p.z, w);
        quadricAdd(vertexQuadrics[i], q);
    }
}

package void fillEdgeQuadrics(Quadric[] vertexQuadrics, scope const(uint)[] indices, size_t indexCount, const(Vec3)[] positions, const(uint)[] remap, const(ubyte)[] vertexKind, const(uint)[] loop, const(uint)[] loopback) nothrow @nogc {
    static immutable int[4] next = [1, 2, 0, 1];
    for (size_t i = 0; i < indexCount; i += 3) {
        foreach (e; 0 .. 3) {
            uint i0 = indices[i + e];
            uint i1 = indices[i + next[e]];
            ubyte k0 = vertexKind[i0];
            ubyte k1 = vertexKind[i1];
            if (k0 == VertexKind.manifold || k1 == VertexKind.manifold)
                continue;
            if (k0 != VertexKind.border && k0 != VertexKind.seam && k0 != VertexKind.fringe
                && k1 != VertexKind.border && k1 != VertexKind.seam && k1 != VertexKind.fringe)
                continue;
            if ((k0 == VertexKind.border || k0 == VertexKind.seam) && loop[i0] != i1)
                continue;
            if ((k1 == VertexKind.border || k1 == VertexKind.seam) && loopback[i1] != i0)
                continue;
            if ((k0 == VertexKind.fringe || k1 == VertexKind.fringe) && (k0 == VertexKind.complex || k1 == VertexKind.complex))
                continue;
            uint i2 = indices[i + next[e + 1]];
            enum float kEdgeWeightSeam = 0.5f;
            enum float kEdgeWeightBorder = 10.0f;
            float edgeWeight = (k0 == VertexKind.seam || k1 == VertexKind.seam) ? kEdgeWeightSeam : kEdgeWeightBorder;
            Quadric q;
            quadricFromTriangleEdge(q, positions[i0], positions[i1], positions[i2], edgeWeight);
            Quadric qt;
            quadricFromTriangle(qt, positions[i0], positions[i1], positions[i2], edgeWeight);
            qt.w = 0;
            quadricAdd(q, qt);
            quadricAdd(vertexQuadrics[remap[i0]], q);
            quadricAdd(vertexQuadrics[remap[i1]], q);
        }
    }
}

package void fillFoldQuadrics(Quadric[] vertexQuadrics, const(EdgeAdjacency) adjacency, const(Vec3)[] positions, const(uint)[] remap, const(uint)[] wedge) nothrow @nogc {
    foreach (i0; 0 .. positions.length) {
        for (uint i = adjacency.offsets[i0]; i < adjacency.offsets[i0 + 1]; ++i) {
            uint i1 = adjacency.data[i].next;
            uint i2 = adjacency.data[i].prev;
            if (remap[i1] > remap[i0])
                continue;
            uint i3 = oppositeVertex(adjacency, i1, asU32(i0), remap, wedge);
            if (i3 == uint.max)
                continue;
            Vec3 p10 = Vec3(positions[i1].x - positions[i0].x, positions[i1].y - positions[i0].y, positions[i1].z - positions[i0].z);
            Vec3 p20 = Vec3(positions[i2].x - positions[i0].x, positions[i2].y - positions[i0].y, positions[i2].z - positions[i0].z);
            Vec3 p30 = Vec3(positions[i3].x - positions[i0].x, positions[i3].y - positions[i0].y, positions[i3].z - positions[i0].z);
            Vec3 normal = Vec3(p10.y * p20.z - p10.z * p20.y, p10.z * p20.x - p10.x * p20.z, p10.x * p20.y - p10.y * p20.x);
            Vec3 opposite = Vec3(p30.y * p10.z - p30.z * p10.y, p30.z * p10.x - p30.x * p10.z, p30.x * p10.y - p30.y * p10.x);
            float nl = sqrtF(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z);
            float ol = sqrtF(opposite.x * opposite.x + opposite.y * opposite.y + opposite.z * opposite.z);
            if (normal.x * opposite.x + normal.y * opposite.y + normal.z * opposite.z >= -0.85f * nl * ol)
                continue;
            Quadric q, qo;
            quadricFromTriangleEdge(q, positions[i0], positions[i1], positions[i2], 1.0f);
            quadricFromTriangleEdge(qo, positions[i0], positions[i1], positions[i3], 1.0f);
            quadricAdd(q, qo);
            quadricAdd(vertexQuadrics[remap[i0]], q);
            quadricAdd(vertexQuadrics[remap[i1]], q);
        }
    }
}

package void fillAttributeQuadrics(Quadric[] attributeQuadrics, QuadricGrad[] attributeGradients, scope const(uint)[] indices, size_t indexCount, const(Vec3)[] positions, const(float)[] attributes, size_t attributeCount) nothrow @nogc {
    for (size_t i = 0; i < indexCount; i += 3) {
        uint i0 = indices[i + 0];
        uint i1 = indices[i + 1];
        uint i2 = indices[i + 2];
        Quadric qa;
        QuadricGrad[maxAttributes] g;
        quadricFromAttributes(qa, g[], positions[i0], positions[i1], positions[i2],
            attributes[i0 * attributeCount .. i0 * attributeCount + attributeCount],
            attributes[i1 * attributeCount .. i1 * attributeCount + attributeCount],
            attributes[i2 * attributeCount .. i2 * attributeCount + attributeCount],
            attributeCount);
        quadricAdd(attributeQuadrics[i0], qa);
        quadricAdd(attributeQuadrics[i1], qa);
        quadricAdd(attributeQuadrics[i2], qa);
        quadricAddGrads(attributeGradients[i0 * attributeCount .. i0 * attributeCount + attributeCount], g[], attributeCount);
        quadricAddGrads(attributeGradients[i1 * attributeCount .. i1 * attributeCount + attributeCount], g[], attributeCount);
        quadricAddGrads(attributeGradients[i2 * attributeCount .. i2 * attributeCount + attributeCount], g[], attributeCount);
    }
}
