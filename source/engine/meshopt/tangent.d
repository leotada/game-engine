// Ported from meshoptimizer v1.3 (src/tangentspace.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Per-corner tangents and crease-aware normals. `result` is one vector per corner.
module engine.meshopt.tangent;

import engine.meshopt.internal.hash : hashBuckets, hashLookup;
import engine.meshopt.scratch : MeshoptScratch, defaultScratch;
import engine.meshopt.types : FloatStream, TangentOptions;

@safe:

private enum bool isIndex(I) = is(I == uint) || is(I == ushort);

private float sqrtF(float x) nothrow @nogc @trusted {
    import core.stdc.math : sqrtf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &sqrtf)(x);
}

private float fabsF(float x) nothrow @nogc @trusted {
    import core.stdc.math : fabsf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &fabsf)(x);
}

private float cosF(float x) nothrow @nogc @trusted {
    import core.stdc.math : cosf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &cosf)(x);
}

private float ceilF(float x) nothrow @nogc @trusted {
    import core.stdc.math : ceilf;
    alias F = float function(float) nothrow @nogc @trusted;
    return (cast(F) &ceilf)(x);
}

private float loadFloat(ulong address, size_t floatIndex) nothrow @nogc @trusted {
    import engine.meshopt.internal.bits : bitsFloat;
    ubyte* p = cast(ubyte*)(address + floatIndex * 4);
    uint u = p[0] | (cast(uint) p[1] << 8) | (cast(uint) p[2] << 16) | (cast(uint) p[3] << 24);
    return bitsFloat(u);
}

private uint loadBits(ulong address, size_t floatIndex) nothrow @nogc @trusted {
    ubyte* p = cast(ubyte*)(address + floatIndex * 4);
    return p[0] | (cast(uint) p[1] << 8) | (cast(uint) p[2] << 16) | (cast(uint) p[3] << 24);
}

private struct Tangent {
    float x, y, z, w;
}

private struct Normal {
    float x, y, z;
    int id;
}

private struct VertexHasherF(bool positionOnly) {
    ulong positions;
    size_t posStride;
    ulong normals;
    size_t nrmStride;
    ulong uvs;
    size_t uvStride;

    size_t hash(uint index) const nothrow @nogc {
        uint x = loadBits(positions, index * posStride + 0);
        uint y = loadBits(positions, index * posStride + 1);
        uint z = loadBits(positions, index * posStride + 2);
        x = x == 0x80000000 ? 0 : x;
        y = y == 0x80000000 ? 0 : y;
        z = z == 0x80000000 ? 0 : z;
        x ^= x >> 17;
        y ^= y >> 17;
        z ^= z >> 17;
        if (positionOnly)
            return (x * 73856093) ^ (y * 19349663) ^ (z * 83492791);

        uint n0 = loadBits(normals, index * nrmStride + 0);
        uint n1 = loadBits(normals, index * nrmStride + 1);
        uint n2 = loadBits(normals, index * nrmStride + 2);
        x ^= n0 == 0x80000000 ? 0 : n0 >> 15;
        y ^= n1 == 0x80000000 ? 0 : n1 >> 15;
        z ^= n2 == 0x80000000 ? 0 : n2 >> 15;
        uint t0 = loadBits(uvs, index * uvStride + 0);
        uint t1 = loadBits(uvs, index * uvStride + 1);
        uint w = (t0 ^ t1) & 0x7fffffff;
        w ^= w >> 13;
        return (x * 73856093) ^ (y * 19349663) ^ (z * 83492791) ^ (w * 50331653);
    }

    bool equal(uint lhs, uint rhs) const nothrow @nogc {
        float lx = loadFloat(positions, lhs * posStride + 0);
        float ly = loadFloat(positions, lhs * posStride + 1);
        float lz = loadFloat(positions, lhs * posStride + 2);
        float rx = loadFloat(positions, rhs * posStride + 0);
        float ry = loadFloat(positions, rhs * posStride + 1);
        float rz = loadFloat(positions, rhs * posStride + 2);
        if (lx != rx || ly != ry || lz != rz)
            return false;
        if (positionOnly)
            return true;
        float lnx = loadFloat(normals, lhs * nrmStride + 0);
        float lny = loadFloat(normals, lhs * nrmStride + 1);
        float lnz = loadFloat(normals, lhs * nrmStride + 2);
        float rnx = loadFloat(normals, rhs * nrmStride + 0);
        float rny = loadFloat(normals, rhs * nrmStride + 1);
        float rnz = loadFloat(normals, rhs * nrmStride + 2);
        float lu = loadFloat(uvs, lhs * uvStride + 0);
        float lv = loadFloat(uvs, lhs * uvStride + 1);
        float ru = loadFloat(uvs, rhs * uvStride + 0);
        float rv = loadFloat(uvs, rhs * uvStride + 1);
        return lnx == rnx && lny == rny && lnz == rnz && lu == ru && lv == rv;
    }
}

private void buildVertexRemap(bool positionOnly)(uint[] remap, FloatStream positions, FloatStream normals, FloatStream uvs, ref MeshoptScratch scratch) {
    VertexHasherF!positionOnly hasher;
    hasher.positions = positions.address;
    hasher.posStride = positions.strideFloats;
    hasher.normals = normals.address;
    hasher.nrmStride = normals.strideFloats;
    hasher.uvs = uvs.address;
    hasher.uvStride = uvs.strideFloats;
    size_t tableSize = hashBuckets(remap.length);
    uint[] table = scratch.allocate!uint(tableSize);
    table[] = uint.max;
    foreach (i; 0 .. remap.length) {
        uint index = cast(uint) i;
        size_t slot = hashLookup(table, hasher, index, uint.max);
        if (table[slot] == uint.max)
            table[slot] = index;
        remap[index] = table[slot];
    }
}

private uint mapped(scope const(uint)[] indices, scope const(uint)[] remap, size_t i, bool indexed) nothrow @nogc {
    return indexed ? remap[indices[i]] : remap[i];
}

private uint sourceIndex(scope const(uint)[] indices, size_t i, bool indexed) nothrow @nogc {
    return indexed ? indices[i] : cast(uint) i;
}

/// `offsets.length == vertexCount + 1`. After the call, vertex `i` owns `data[offsets[i] .. offsets[i + 1]]`.
private void buildCornerAdjacency(scope uint[] offsets, scope uint[] data, scope const(uint)[] indices, scope const(uint)[] remap, bool indexed) {
    size_t vertexCount = remap.length;
    size_t indexCount = data.length;
    offsets[] = 0;
    foreach (i; 0 .. indexCount) {
        uint v = mapped(indices, remap, i, indexed);
        offsets[v + 1]++;
    }
    uint offset = 0;
    foreach (i; 0 .. vertexCount) {
        uint count = offsets[i + 1];
        offsets[i + 1] = offset;
        offset += count;
    }
    assert(offset == indexCount);
    size_t faceCount = indexCount / 3;
    foreach (i; 0 .. faceCount) {
        uint a = mapped(indices, remap, i * 3 + 0, indexed);
        uint b = mapped(indices, remap, i * 3 + 1, indexed);
        uint c = mapped(indices, remap, i * 3 + 2, indexed);
        data[offsets[a + 1]++] = cast(uint)(i << 2) | 0;
        data[offsets[b + 1]++] = cast(uint)(i << 2) | 1;
        data[offsets[c + 1]++] = cast(uint)(i << 2) | 2;
    }
    offsets[0] = 0;
    assert(offsets[vertexCount] == indexCount);
}

private uint follow2(scope uint[] parents, uint index) nothrow @nogc {
    while (index != parents[index]) {
        uint parent = parents[index];
        parents[index] = parents[parent];
        index = parent;
    }
    return index;
}

private enum int[4] kNext = [1, 2, 0, 1];

private void mergeTangentGroups(scope uint[] groups, scope uint[] facegroups, scope ubyte[] facesign, scope const(uint)[] data, scope const(uint)[] indices, scope const(uint)[] remap, bool indexed) {
    foreach (i; 0 .. data.length) {
        uint ti = data[i] >> 2;
        uint cib = ti * 3 + kNext[(data[i] & 3) + 0];
        uint cic = ti * 3 + kNext[(data[i] & 3) + 1];
        uint nib = mapped(indices, remap, cib, indexed);
        uint nic = mapped(indices, remap, cic, indexed);
        foreach (j; i + 1 .. data.length) {
            uint tj = data[j] >> 2;
            uint cjb = tj * 3 + kNext[(data[j] & 3) + 0];
            uint cjc = tj * 3 + kNext[(data[j] & 3) + 1];
            uint njb = mapped(indices, remap, cjb, indexed);
            uint njc = mapped(indices, remap, cjc, indexed);
            if ((njb == nic || njc == nib) && (facesign[ti] | facesign[tj]) != 3) {
                if ((facesign[ti] & facesign[tj]) == 0) {
                    uint gti = follow2(facegroups, ti);
                    uint gtj = follow2(facegroups, tj);
                    if (gti != gtj) {
                        if ((facesign[gti] | facesign[gtj]) == 3)
                            continue;
                        facegroups[gtj] = gti;
                        facesign[gti] |= facesign[gtj];
                    }
                }
                uint gi = follow2(groups, ti * 3 + (data[i] & 3));
                uint gj = follow2(groups, tj * 3 + (data[j] & 3));
                if (gi != gj)
                    groups[gj] = gi;
            }
        }
    }
}

private void mergeNormalGroups(scope uint[] groups, scope const(uint)[] data, scope const(uint)[] indices, scope const(uint)[] remap, scope const(Normal)[] faceNormals, float creaseCutoff, bool indexed) {
    foreach (i; 0 .. data.length) {
        uint ti = data[i] >> 2;
        uint cib = ti * 3 + kNext[(data[i] & 3) + 0];
        uint cic = ti * 3 + kNext[(data[i] & 3) + 1];
        uint nib = mapped(indices, remap, cib, indexed);
        uint nic = mapped(indices, remap, cic, indexed);
        Normal fi = faceNormals[ti];
        foreach (j; i + 1 .. data.length) {
            uint tj = data[j] >> 2;
            uint cjb = tj * 3 + kNext[(data[j] & 3) + 0];
            uint cjc = tj * 3 + kNext[(data[j] & 3) + 1];
            uint njb = mapped(indices, remap, cjb, indexed);
            uint njc = mapped(indices, remap, cjc, indexed);
            Normal fj = faceNormals[tj];
            if ((njb == nic || njc == nib) && fi.x * fj.x + fi.y * fj.y + fi.z * fj.z > creaseCutoff && fi.id == fj.id) {
                uint gi = follow2(groups, ti * 3 + (data[i] & 3));
                uint gj = follow2(groups, tj * 3 + (data[j] & 3));
                if (gi != gj)
                    groups[gj] = gi;
            }
        }
    }
}

/// Approximation of `acos`. Max error is about 5e-4. Clamps to [-1, 1].
private float optacos(float x) nothrow @nogc {
    float ax = fabsF(x);
    ax = ax > 1.0f ? 1.0f : ax;
    float r = 1.570337f + ax * (-0.2053972f + ax * 0.05147786f);
    r *= sqrtF(1.0f - ax);
    return x < 0.0f ? 3.1415926f - r : r;
}

private void computeFaceTangents(scope Tangent[] result, scope const(uint)[] indices, FloatStream positions, FloatStream uvs, bool indexed) {
    foreach (i; 0 .. result.length) {
        uint a = sourceIndex(indices, i * 3 + 0, indexed);
        uint b = sourceIndex(indices, i * 3 + 1, indexed);
        uint c = sourceIndex(indices, i * 3 + 2, indexed);
        float pax = loadFloat(positions.address, a * positions.strideFloats + 0);
        float pay = loadFloat(positions.address, a * positions.strideFloats + 1);
        float paz = loadFloat(positions.address, a * positions.strideFloats + 2);
        float pbx = loadFloat(positions.address, b * positions.strideFloats + 0);
        float pby = loadFloat(positions.address, b * positions.strideFloats + 1);
        float pbz = loadFloat(positions.address, b * positions.strideFloats + 2);
        float pcx = loadFloat(positions.address, c * positions.strideFloats + 0);
        float pcy = loadFloat(positions.address, c * positions.strideFloats + 1);
        float pcz = loadFloat(positions.address, c * positions.strideFloats + 2);
        float tax = loadFloat(uvs.address, a * uvs.strideFloats + 0);
        float tay = loadFloat(uvs.address, a * uvs.strideFloats + 1);
        float tbx = loadFloat(uvs.address, b * uvs.strideFloats + 0);
        float tby = loadFloat(uvs.address, b * uvs.strideFloats + 1);
        float tcx = loadFloat(uvs.address, c * uvs.strideFloats + 0);
        float tcy = loadFloat(uvs.address, c * uvs.strideFloats + 1);
        float dp1x = pbx - pax, dp1y = pby - pay, dp1z = pbz - paz;
        float dp2x = pcx - pax, dp2y = pcy - pay, dp2z = pcz - paz;
        float dt1x = tbx - tax, dt1y = tby - tay;
        float dt2x = tcx - tax, dt2y = tcy - tay;
        float rx = dt2y * dp1x - dt1y * dp2x;
        float ry = dt2y * dp1y - dt1y * dp2y;
        float rz = dt2y * dp1z - dt1y * dp2z;
        float det = dt1x * dt2y - dt1y * dt2x;
        float rw = det == 0.0f ? 0.0f : (det > 0.0f ? 1.0f : -1.0f);
        rw = (pax == pbx && pay == pby && paz == pbz) ? 0.0f : rw;
        rw = (pax == pcx && pay == pcy && paz == pcz) ? 0.0f : rw;
        rw = (pbx == pcx && pby == pcy && pbz == pcz) ? 0.0f : rw;
        float rl = sqrtF(rx * rx + ry * ry + rz * rz);
        float rs = rl != 0.0f ? rw / rl : 0.0f;
        result[i].x = rx * rs;
        result[i].y = ry * rs;
        result[i].z = rz * rs;
        result[i].w = rw;
    }
}

private void computeFaceNormals(scope Normal[] result, scope const(uint)[] indices, FloatStream positions, bool indexed) {
    foreach (i; 0 .. result.length) {
        uint a = sourceIndex(indices, i * 3 + 0, indexed);
        uint b = sourceIndex(indices, i * 3 + 1, indexed);
        uint c = sourceIndex(indices, i * 3 + 2, indexed);
        float pax = loadFloat(positions.address, a * positions.strideFloats + 0);
        float pay = loadFloat(positions.address, a * positions.strideFloats + 1);
        float paz = loadFloat(positions.address, a * positions.strideFloats + 2);
        float pbx = loadFloat(positions.address, b * positions.strideFloats + 0);
        float pby = loadFloat(positions.address, b * positions.strideFloats + 1);
        float pbz = loadFloat(positions.address, b * positions.strideFloats + 2);
        float pcx = loadFloat(positions.address, c * positions.strideFloats + 0);
        float pcy = loadFloat(positions.address, c * positions.strideFloats + 1);
        float pcz = loadFloat(positions.address, c * positions.strideFloats + 2);
        float dp1x = pbx - pax, dp1y = pby - pay, dp1z = pbz - paz;
        float dp2x = pcx - pax, dp2y = pcy - pay, dp2z = pcz - paz;
        float nx = dp1y * dp2z - dp1z * dp2y;
        float ny = dp1z * dp2x - dp1x * dp2z;
        float nz = dp1x * dp2y - dp1y * dp2x;
        float nl = sqrtF(nx * nx + ny * ny + nz * nz);
        float ns = nl != 0.0f ? 1.0f / nl : 0.0f;
        result[i].x = nx * ns;
        result[i].y = ny * ns;
        result[i].z = nz * ns;
        result[i].id = nl != 0.0f ? 1 : 0;
    }
}

private void accumulateTangents(scope float[4][] result, scope const(uint)[] groups, scope const(uint)[] indices, scope const(Tangent)[] faceTangents, FloatStream positions, FloatStream normals, uint options, bool indexed) {
    size_t faceCount = faceTangents.length;
    foreach (i; 0 .. faceCount) {
        Tangent t = faceTangents[i];
        if (t.w == 0.0f)
            continue;
        foreach (k; 0 .. 3) {
            uint slot = groups[i * 3 + k];
            uint a = sourceIndex(indices, i * 3 + k, indexed);
            uint b = sourceIndex(indices, i * 3 + kNext[k], indexed);
            uint c = sourceIndex(indices, i * 3 + kNext[k + 1], indexed);
            float pax = loadFloat(positions.address, a * positions.strideFloats + 0);
            float pay = loadFloat(positions.address, a * positions.strideFloats + 1);
            float paz = loadFloat(positions.address, a * positions.strideFloats + 2);
            float pbx = loadFloat(positions.address, b * positions.strideFloats + 0);
            float pby = loadFloat(positions.address, b * positions.strideFloats + 1);
            float pbz = loadFloat(positions.address, b * positions.strideFloats + 2);
            float pcx = loadFloat(positions.address, c * positions.strideFloats + 0);
            float pcy = loadFloat(positions.address, c * positions.strideFloats + 1);
            float pcz = loadFloat(positions.address, c * positions.strideFloats + 2);
            float nx = loadFloat(normals.address, a * normals.strideFloats + 0);
            float ny = loadFloat(normals.address, a * normals.strideFloats + 1);
            float nz = loadFloat(normals.address, a * normals.strideFloats + 2);
            float sd = t.x * nx + t.y * ny + t.z * nz;
            float sx = t.x - nx * sd, sy = t.y - ny * sd, sz = t.z - nz * sd;
            float sl = sqrtF(sx * sx + sy * sy + sz * sz);
            float dp1x = pbx - pax, dp1y = pby - pay, dp1z = pbz - paz;
            float dp2x = pcx - pax, dp2y = pcy - pay, dp2z = pcz - paz;
            float dp1d = dp1x * nx + dp1y * ny + dp1z * nz;
            float dp2d = dp2x * nx + dp2y * ny + dp2z * nz;
            dp1x -= nx * dp1d;
            dp1y -= ny * dp1d;
            dp1z -= nz * dp1d;
            dp2x -= nx * dp2d;
            dp2y -= ny * dp2d;
            dp2z -= nz * dp2d;
            float dp1l = dp1x * dp1x + dp1y * dp1y + dp1z * dp1z;
            float dp2l = dp2x * dp2x + dp2y * dp2y + dp2z * dp2z;
            float dpl = sqrtF(dp1l * dp2l);
            float cosa = (dp1x * dp2x + dp1y * dp2y + dp1z * dp2z) * (dpl == 0.0f ? 0.0f : 1.0f / dpl);
            float angle = optacos(cosa);
            float w = angle * (sl == 0.0f ? 0.0f : 1.0f / sl);
            if ((options & TangentOptions.compatible) == 0)
                w *= dpl;
            result[slot][0] += sx * w;
            result[slot][1] += sy * w;
            result[slot][2] += sz * w;
        }
    }
}

private void accumulateNormals(scope float[3][] result, scope const(uint)[] groups, scope const(uint)[] indices, scope const(Normal)[] faceNormals, FloatStream positions, bool indexed) {
    size_t faceCount = faceNormals.length;
    foreach (i; 0 .. faceCount) {
        Normal n = faceNormals[i];
        foreach (k; 0 .. 3) {
            uint slot = groups[i * 3 + k];
            uint a = sourceIndex(indices, i * 3 + k, indexed);
            uint b = sourceIndex(indices, i * 3 + kNext[k], indexed);
            uint c = sourceIndex(indices, i * 3 + kNext[k + 1], indexed);
            float pax = loadFloat(positions.address, a * positions.strideFloats + 0);
            float pay = loadFloat(positions.address, a * positions.strideFloats + 1);
            float paz = loadFloat(positions.address, a * positions.strideFloats + 2);
            float pbx = loadFloat(positions.address, b * positions.strideFloats + 0);
            float pby = loadFloat(positions.address, b * positions.strideFloats + 1);
            float pbz = loadFloat(positions.address, b * positions.strideFloats + 2);
            float pcx = loadFloat(positions.address, c * positions.strideFloats + 0);
            float pcy = loadFloat(positions.address, c * positions.strideFloats + 1);
            float pcz = loadFloat(positions.address, c * positions.strideFloats + 2);
            float dp1x = pbx - pax, dp1y = pby - pay, dp1z = pbz - paz;
            float dp2x = pcx - pax, dp2y = pcy - pay, dp2z = pcz - paz;
            float dp1l = dp1x * dp1x + dp1y * dp1y + dp1z * dp1z;
            float dp2l = dp2x * dp2x + dp2y * dp2y + dp2z * dp2z;
            float dpl = sqrtF(dp1l * dp2l);
            float cosa = (dp1x * dp2x + dp1y * dp2y + dp1z * dp2z) * (dpl == 0.0f ? 0.0f : 1.0f / dpl);
            float angle = optacos(cosa);
            float w = angle * dpl;
            result[slot][0] += n.x * w;
            result[slot][1] += n.y * w;
            result[slot][2] += n.z * w;
        }
    }
}

private void smoothNormals(scope float[3][] result, scope float[] scratch, scope const(uint)[] groups, float alpha) {
    size_t indexCount = groups.length;
    size_t faceCount = indexCount / 3;
    scratch[] = 0.0f;
    foreach (i; 0 .. faceCount) {
        foreach (k; 0 .. 3) {
            uint ga = groups[i * 3 + k];
            uint gb = groups[i * 3 + kNext[k]];
            float nax = result[ga][0], nay = result[ga][1], naz = result[ga][2];
            float nbx = result[gb][0], nby = result[gb][1], nbz = result[gb][2];
            float dp = nax * nbx + nay * nby + naz * nbz;
            float w = dp > 0.0f ? dp * dp : 0.0f;
            float nx = (nbx - nax) * w, ny = (nby - nay) * w, nz = (nbz - naz) * w;
            scratch[ga * 4 + 0] += nx;
            scratch[ga * 4 + 1] += ny;
            scratch[ga * 4 + 2] += nz;
            scratch[ga * 4 + 3] += 1.0f;
            scratch[gb * 4 + 0] -= nx;
            scratch[gb * 4 + 1] -= ny;
            scratch[gb * 4 + 2] -= nz;
            scratch[gb * 4 + 3] += 1.0f;
        }
    }
    foreach (i; 0 .. indexCount) {
        if (groups[i] == i && scratch[i * 4 + 3] > 0.0f) {
            float sw = alpha / scratch[i * 4 + 3];
            float rx = result[i][0] + scratch[i * 4 + 0] * sw;
            float ry = result[i][1] + scratch[i * 4 + 1] * sw;
            float rz = result[i][2] + scratch[i * 4 + 2] * sw;
            float rl = sqrtF(rx * rx + ry * ry + rz * rz);
            float rs = rl == 0.0f ? 0.0f : 1.0f / rl;
            result[i][0] = rx * rs;
            result[i][1] = ry * rs;
            result[i][2] = rz * rs;
        }
    }
}

private void checkStreams(FloatStream positions, FloatStream normals, FloatStream uvs, size_t indexCount, size_t resultLength) nothrow @nogc {
    assert(indexCount % 3 == 0);
    assert(resultLength == indexCount);
    assert(positions.strideFloats * 4 >= 12 && positions.strideFloats * 4 <= 256);
    assert(normals.strideFloats * 4 >= 12 && normals.strideFloats * 4 <= 256);
    assert(uvs.strideFloats * 4 >= 8 && uvs.strideFloats * 4 <= 256);
    assert(normals.count == positions.count);
    assert(uvs.count == positions.count);
}

/**
 * Per-corner tangents. `result.length` is the corner count (`indices.length`,
 * or `positions.count` when `indices` is empty — the unindexed triangle list).
 * `w` is the handedness, +1 or -1. Reconstruct the bitangent with
 * `cross(normal, tangent.xyz) * tangent.w`.
 */
void generateTangents(I)(scope float[4][] result, scope const(I)[] indices, FloatStream positions, FloatStream normals, FloatStream uvs, TangentOptions opts = TangentOptions.none, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    bool indexed = indices.length != 0;
    size_t indexCount = indexed ? indices.length : positions.count;
    checkStreams(positions, normals, uvs, indexCount, result.length);
    if (!indexed)
        assert(indexCount == positions.count);
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);

    uint[] idx;
    if (indexed) {
        idx = scratch.allocate!uint(indexCount);
        foreach (i, v; indices)
            idx[i] = v;
    }
    uint[] remap = scratch.allocate!uint(positions.count);
    buildVertexRemap!false(remap, positions, normals, uvs, scratch);

    uint[] offsets = scratch.allocate!uint(positions.count + 1);
    uint[] adjacency = scratch.allocate!uint(indexCount);
    buildCornerAdjacency(offsets, adjacency, idx, remap, indexed);

    size_t faceCount = indexCount / 3;
    Tangent[] faceTangents = scratch.allocate!Tangent(faceCount);
    computeFaceTangents(faceTangents, idx, positions, uvs, indexed);

    uint[] groups = scratch.allocate!uint(indexCount);
    foreach (i; 0 .. indexCount)
        groups[i] = cast(uint) i;
    uint[] facegroups = scratch.allocate!uint(faceCount);
    ubyte[] facesign = scratch.allocate!ubyte(faceCount);
    foreach (i; 0 .. faceCount) {
        facegroups[i] = cast(uint) i;
        facesign[i] = cast(ubyte)((faceTangents[i].w > 0.0f ? 1 : 0) | (faceTangents[i].w < 0.0f ? 2 : 0));
    }
    foreach (i; 0 .. positions.count) {
        if (offsets[i + 1] != offsets[i]) {
            uint begin = offsets[i];
            uint end = offsets[i + 1];
            mergeTangentGroups(groups, facegroups, facesign, adjacency[begin .. end], idx, remap, indexed);
        }
    }
    foreach (i; 0 .. indexCount)
        groups[i] = follow2(groups, cast(uint) i);

    foreach (ref slot; result)
        slot[] = 0.0f;
    accumulateTangents(result, groups, idx, faceTangents, positions, normals, opts, indexed);

    foreach (i; 0 .. faceCount) {
        uint fg = follow2(facegroups, cast(uint) i);
        float w = (facesign[fg] & 1) ? 1.0f : -1.0f;
        result[i * 3 + 0][3] = w;
        result[i * 3 + 1][3] = w;
        result[i * 3 + 2][3] = w;
    }
    foreach (i; 0 .. indexCount) {
        if (groups[i] == i) {
            float l = sqrtF(result[i][0] * result[i][0] + result[i][1] * result[i][1] + result[i][2] * result[i][2]);
            float s = l == 0.0f ? 0.0f : 1.0f / l;
            result[i][0] *= s;
            result[i][1] *= s;
            result[i][2] *= s;
            result[i][0] = (l == 0.0f && (opts & TangentOptions.zeroFallback) == 0) ? 1.0f : result[i][0];
        }
    }
    foreach (i; 0 .. indexCount) {
        if (groups[i] != i)
            result[i][0 .. 3] = result[groups[i]][0 .. 3];
    }
}

/**
 * Experimental per-corner normals. Edges whose face angle is below `creaseAngle`
 * (radians) are averaged. `smoothing` in about [0, 5] blends neighbors afterward.
 * An empty `indices` slice is the unindexed triangle list (`positions.count` corners).
 */
void generateNormals(I)(scope float[3][] result, scope const(I)[] indices, FloatStream positions, float creaseAngle, float smoothing = 0, ref MeshoptScratch scratch = defaultScratch())
if (isIndex!I) {
    bool indexed = indices.length != 0;
    size_t indexCount = indexed ? indices.length : positions.count;
    assert(indexCount % 3 == 0);
    assert(result.length == indexCount);
    assert(positions.strideFloats * 4 >= 12 && positions.strideFloats * 4 <= 256);
    assert(creaseAngle >= 0.0f && creaseAngle <= 3.1415927f);
    assert(smoothing >= 0.0f);
    if (!indexed)
        assert(indexCount == positions.count);
    immutable mark = scratch.mark();
    scope (exit)
        scratch.release(mark);

    float creaseCutoff = cosF(creaseAngle);
    uint[] idx;
    if (indexed) {
        idx = scratch.allocate!uint(indexCount);
        foreach (i, v; indices)
            idx[i] = v;
    }
    FloatStream none;
    uint[] remap = scratch.allocate!uint(positions.count);
    buildVertexRemap!true(remap, positions, none, none, scratch);

    uint[] offsets = scratch.allocate!uint(positions.count + 1);
    uint[] adjacency = scratch.allocate!uint(indexCount);
    buildCornerAdjacency(offsets, adjacency, idx, remap, indexed);

    size_t faceCount = indexCount / 3;
    Normal[] faceNormals = scratch.allocate!Normal(faceCount);
    computeFaceNormals(faceNormals, idx, positions, indexed);

    uint[] groups = scratch.allocate!uint(indexCount);
    foreach (i; 0 .. indexCount)
        groups[i] = cast(uint) i;
    foreach (i; 0 .. positions.count) {
        if (offsets[i + 1] != offsets[i]) {
            uint begin = offsets[i];
            uint end = offsets[i + 1];
            mergeNormalGroups(groups, adjacency[begin .. end], idx, remap, faceNormals, creaseCutoff, indexed);
        }
    }
    foreach (i; 0 .. indexCount)
        groups[i] = follow2(groups, cast(uint) i);

    foreach (ref slot; result)
        slot[] = 0.0f;
    accumulateNormals(result, groups, idx, faceNormals, positions, indexed);

    foreach (i; 0 .. indexCount) {
        if (groups[i] == i) {
            float l = sqrtF(result[i][0] * result[i][0] + result[i][1] * result[i][1] + result[i][2] * result[i][2]);
            float s = l == 0.0f ? 0.0f : 1.0f / l;
            result[i][0] *= s;
            result[i][1] *= s;
            result[i][2] *= s;
        }
    }
    if (smoothing > 0.0f) {
        int passes = cast(int) ceilF(smoothing);
        passes = passes < 10 ? passes : 10;
        float[] smooth = scratch.allocate!float(indexCount * 4);
        foreach (pass; 0 .. passes) {
            float rem = smoothing - cast(float) pass;
            float alpha = 0.5f * (rem < 1.0f ? rem : 1.0f);
            smoothNormals(result, smooth, groups, alpha);
        }
    }
    foreach (i; 0 .. indexCount) {
        if (groups[i] != i)
            result[i][] = result[groups[i]][];
    }
}

@("generateTangents.handedness") unittest {
    static struct V {
        float[3] pos;
        float[3] nrm;
        float[2] uv;
    }

    V[4] quad = [
        V([0, 0, 0], [0, 1, 0], [0, 0]),
        V([1, 0, 0], [0, 1, 0], [1, 0]),
        V([1, 0, 1], [0, 1, 0], [1, 1]),
        V([0, 0, 1], [0, 1, 0], [0, 1]),
    ];
    V[4] mirrored = quad;
    mirrored[0].uv = [1, 0];
    mirrored[1].uv = [0, 0];
    mirrored[2].uv = [0, 1];
    mirrored[3].uv = [1, 1];
    uint[6] idx = [0, 1, 2, 0, 2, 3];

    FloatStream pos = streamOf!(V, "pos")(quad[]);
    FloatStream nrm = streamOf!(V, "nrm")(quad[]);
    FloatStream uv = streamOf!(V, "uv")(quad[]);
    float[4][6] tangents;
    generateTangents(tangents[], idx[], pos, nrm, uv, TangentOptions.compatible);
    foreach (t; tangents[])
        assert(t[3] == 1.0f);

    FloatStream uvM = streamOf!(V, "uv")(mirrored[]);
    float[4][6] flipped;
    generateTangents(flipped[], idx[], pos, nrm, uvM, TangentOptions.compatible);
    foreach (t; flipped[])
        assert(t[3] == -1.0f);
}

@("tangent.golden") @trusted unittest {
    import std.file : read;
    import engine.meshopt.internal.bits : floatBits;
    import engine.meshopt.quantize : goldenParamsHash;

    void checkGolden(string name, bool tangents) {
        ubyte[] file = cast(ubyte[]) read("tests/meshopt/golden/" ~ name ~ ".bin");
        assert(file.length >= 52, name);
        assert(file[0 .. 8] == cast(const(ubyte)[]) "MOPTGLD1", name);
        assert(loadU32(file, 8) == 1030, name);
        assert(loadU32(file, 44) == goldenParamsHash(name), name);
        uint cases = loadU32(file, 48);
        size_t at = 52;
        foreach (_; 0 .. cases) {
            uint vc = loadU32(file, at);
            uint indexCount = loadU32(file, at + 4);
            uint posStride = loadU32(file, at + 8);
            uint nrmStride = loadU32(file, at + 12);
            uint uvStride = loadU32(file, at + 16);
            uint options = loadU32(file, at + 20);
            float crease = loadF32(file, at + 24);
            float smoothing = loadF32(file, at + 28);
            at += 32;
            uint[] idx;
            if (indexCount) {
                idx.length = indexCount;
                foreach (i; 0 .. indexCount) {
                    idx[i] = loadU32(file, at);
                    at += 4;
                }
            }
            float[] pos = takeFloats(file, at, vc * posStride);
            at += vc * posStride * 4;
            size_t corners = indexCount ? indexCount : vc;
            if (tangents) {
                float[] nrm = takeFloats(file, at, vc * nrmStride);
                at += vc * nrmStride * 4;
                float[] uv = takeFloats(file, at, vc * uvStride);
                at += vc * uvStride * 4;
                float[4][] expect = new float[4][](corners);
                foreach (i; 0 .. corners) {
                    foreach (k; 0 .. 4) {
                        expect[i][k] = loadF32(file, at);
                        at += 4;
                    }
                }
                float[4][] got = new float[4][](corners);
                generateTangents(got, idx, streamFloats(pos, posStride, vc), streamFloats(nrm, nrmStride, vc), streamFloats(uv, uvStride, vc), cast(TangentOptions) options);
                foreach (i; 0 .. corners) {
                    foreach (k; 0 .. 4)
                        assert(floatBits(got[i][k]) == floatBits(expect[i][k]), name);
                }
                if (indexCount && indexCount <= 65536) {
                    ushort[] narrow = new ushort[idx.length];
                    foreach (i, v; idx)
                        narrow[i] = cast(ushort) v;
                    float[4][] got16 = new float[4][](corners);
                    generateTangents(got16, narrow, streamFloats(pos, posStride, vc), streamFloats(nrm, nrmStride, vc), streamFloats(uv, uvStride, vc), cast(TangentOptions) options);
                    foreach (i; 0 .. corners)
                        assert(got16[i] == got[i]);
                }
            } else {
                float[3][] expect = new float[3][](corners);
                foreach (i; 0 .. corners) {
                    foreach (k; 0 .. 3) {
                        expect[i][k] = loadF32(file, at);
                        at += 4;
                    }
                }
                float[3][] got = new float[3][](corners);
                generateNormals(got, idx, streamFloats(pos, posStride, vc), crease, smoothing);
                foreach (i; 0 .. corners) {
                    foreach (k; 0 .. 3)
                        assert(floatBits(got[i][k]) == floatBits(expect[i][k]), name);
                }
            }
        }
        assert(at == file.length, name);
    }

    checkGolden("generateTangents", true);
    checkGolden("generateNormals", false);
}

private uint loadU32(const(ubyte)[] b, size_t at) pure nothrow @nogc {
    return b[at] | (cast(uint) b[at + 1] << 8) | (cast(uint) b[at + 2] << 16) | (cast(uint) b[at + 3] << 24);
}

private float loadF32(const(ubyte)[] b, size_t at) pure nothrow @nogc {
    import engine.meshopt.internal.bits : bitsFloat;
    return bitsFloat(loadU32(b, at));
}

private float[] takeFloats(const(ubyte)[] b, size_t at, size_t n) pure nothrow {
    float[] d = new float[n];
    foreach (i; 0 .. n)
        d[i] = loadF32(b, at + i * 4);
    return d;
}

private FloatStream streamFloats(return scope const(float)[] data, size_t strideFloats, size_t count) nothrow @nogc @trusted {
    FloatStream s;
    s.strideFloats = strideFloats;
    s.count = count;
    if (count)
        s.address = cast(ulong) data.ptr;
    return s;
}

private FloatStream streamOf(T, string field)(const(T)[] verts) nothrow @nogc @trusted {
    enum off = mixin("T." ~ field ~ ".offsetof");
    FloatStream s;
    s.strideFloats = T.sizeof / 4;
    s.count = verts.length;
    if (verts.length)
        s.address = cast(ulong)(cast(const(ubyte)*) verts.ptr + off);
    return s;
}
