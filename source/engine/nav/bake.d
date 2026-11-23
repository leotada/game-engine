/// Navigation mesh baking and binary `.navmesh` serialization.
module engine.nav.bake;

import core.stdc.stdlib : free, malloc;
import std.file : read, write;
import engine.math.vec : Vec3;
import engine.nav.types;
import engine.nav.mesh : NavMesh, NavTileCache;
import recast = bindings.recast;
import bindings.recast : NavOffMeshConnectionC;

@safe:

/// Bake triangle soup (`verts`, `indices`) into `mesh` (and optional `tc` for dynamic obstacles).
/// `links` are off-mesh connections (jumps, ladders, drops); they are stored in the tile data, so
/// they survive `.navmesh` save/load, and with a `tc` they also survive obstacle tile rebuilds.
/// Returns the number of tiles built (`<= 0` on failure).
int bakeNavMesh(ref NavMesh mesh,
                ref NavTileCache tc,
                scope const(Vec3)[] verts,
                scope const(int)[] indices,
                const ref NavBakeConfig cfg,
                scope const(ubyte)[] triAreas = null,
                scope const(NavOffMeshConnection)[] links = null) @trusted nothrow @nogc {
    if (!mesh.isValid() || verts.length == 0 || indices.length < 3 || (indices.length % 3) != 0) {
        return 0;
    }
    immutable int triCount = cast(int) (indices.length / 3);
    if (triAreas.length > 0 && triAreas.length != cast(size_t) triCount) {
        return 0;
    }
    auto cCfg = cfg.toC();
    // Vec3 is 3 packed floats (`x, y, z`), validated statically.
    static assert(Vec3.sizeof == 3 * float.sizeof);

    NavOffMeshConnectionC[] cLinks;
    if (links.length > 0) {
        auto mem = cast(NavOffMeshConnectionC*) malloc(links.length * NavOffMeshConnectionC.sizeof);
        if (mem is null) return 0;
        cLinks = mem[0 .. links.length];
        foreach (i, ref l; links) cLinks[i] = l.toC();
    }
    scope(exit) if (cLinks.length > 0) free(cLinks.ptr);

    return recast.navBakeGeometryEx(
        mesh.handle,
        tc.handle,
        cast(const(float)*) verts.ptr,
        cast(int) verts.length,
        indices.ptr,
        triCount,
        triAreas.length > 0 ? triAreas.ptr : null,
        &cCfg,
        cLinks.length > 0 ? cLinks.ptr : null,
        cast(int) cLinks.length);
}

/// Bake triangle soup into a `NavMesh` without a `NavTileCache`.
int bakeNavMesh(ref NavMesh mesh,
                scope const(Vec3)[] verts,
                scope const(int)[] indices,
                const ref NavBakeConfig cfg,
                scope const(ubyte)[] triAreas = null,
                scope const(NavOffMeshConnection)[] links = null) nothrow @nogc {
    NavTileCache unused;
    return bakeNavMesh(mesh, unused, verts, indices, cfg, triAreas, links);
}

/// Serialize all tiles of `mesh` into a GC-owned byte buffer (`.navmesh` format).
bool saveNavMeshToBytes(ref const NavMesh mesh, out ubyte[] outBytes) @trusted {
    if (!mesh.isValid()) return false;
    ubyte* ptr = null;
    int size = 0;
    if (!recast.navSaveMeshToBuffer(mesh.handle, &ptr, &size) || ptr is null || size <= 0) {
        return false;
    }
    scope(exit) recast.navFreeBuffer(ptr);
    outBytes = ptr[0 .. cast(size_t) size].dup;
    return true;
}

/// Like `saveNavMeshToBytes`, but also stores the `NavTileCache` (compressed layers, cache params and
/// off-mesh links), so `loadNavMeshAndCacheFromBytes` can restore the obstacle layer without re-baking.
/// Dynamic obstacles themselves are not stored. An invalid `tc` writes the plain mesh-only format.
bool saveNavMeshToBytes(ref const NavMesh mesh, ref const NavTileCache tc, out ubyte[] outBytes) @trusted {
    if (!mesh.isValid()) return false;
    ubyte* ptr = null;
    int size = 0;
    if (!recast.navSaveMeshAndTileCacheToBuffer(mesh.handle, tc.handle, &ptr, &size) || ptr is null || size <= 0) {
        return false;
    }
    scope(exit) recast.navFreeBuffer(ptr);
    outBytes = ptr[0 .. cast(size_t) size].dup;
    return true;
}

/// Load a `NavMesh` and, when the buffer carries one, its `NavTileCache`, from a `.navmesh` buffer.
/// `tc` stays invalid for a mesh-only file; the call returns false when `data` is corrupt.
bool loadNavMeshAndCacheFromBytes(scope const(ubyte)[] data, out NavMesh mesh, out NavTileCache tc)
        @trusted nothrow @nogc {
    if (data.length == 0) return false;
    mesh.handle = recast.navLoadMeshAndTileCacheFromBuffer(data.ptr, cast(int) data.length, &tc.handle);
    return mesh.isValid();
}

/// Write a `NavMesh` and its `NavTileCache` to a `.navmesh` file on disk.
bool saveNavMeshFile(ref const NavMesh mesh, ref const NavTileCache tc, string path) {
    ubyte[] bytes;
    if (!saveNavMeshToBytes(mesh, tc, bytes)) return false;
    write(path, bytes);
    return true;
}

/// Load a `NavMesh` from a binary `.navmesh` buffer.
NavMesh loadNavMeshFromBytes(scope const(ubyte)[] data) @trusted nothrow @nogc {
    NavMesh m;
    if (data.length == 0) return m;
    m.handle = recast.navLoadMeshFromBuffer(data.ptr, cast(int) data.length);
    return m;
}

/// Write a `NavMesh` to a `.navmesh` file on disk.
bool saveNavMeshFile(ref const NavMesh mesh, string path) {
    ubyte[] bytes;
    if (!saveNavMeshToBytes(mesh, bytes)) return false;
    write(path, bytes);
    return true;
}

/// Load a `NavMesh` from a `.navmesh` file on disk.
NavMesh loadNavMeshFile(string path) {
    auto raw = cast(const(ubyte)[]) read(path);
    return loadNavMeshFromBytes(raw);
}
