/// Navigation mesh baking and binary `.navmesh` serialization.
module engine.nav.bake;

import std.file : read, write;
import engine.math.vec : Vec3;
import engine.nav.types;
import engine.nav.mesh : NavMesh, NavTileCache;
import recast = bindings.recast;

@safe:

/// Bake triangle soup (`verts`, `indices`) into `mesh` (and optional `tc` for dynamic obstacles).
/// Returns the number of tiles built (`<= 0` on failure).
int bakeNavMesh(ref NavMesh mesh,
                ref NavTileCache tc,
                scope const(Vec3)[] verts,
                scope const(int)[] indices,
                const ref NavBakeConfig cfg,
                scope const(ubyte)[] triAreas = null) @trusted nothrow @nogc {
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
    return recast.navBakeGeometry(
        mesh.handle,
        tc.handle,
        cast(const(float)*) verts.ptr,
        cast(int) verts.length,
        indices.ptr,
        triCount,
        triAreas.length > 0 ? triAreas.ptr : null,
        &cCfg);
}

/// Bake triangle soup into a `NavMesh` without a `NavTileCache`.
int bakeNavMesh(ref NavMesh mesh,
                scope const(Vec3)[] verts,
                scope const(int)[] indices,
                const ref NavBakeConfig cfg,
                scope const(ubyte)[] triAreas = null) nothrow @nogc {
    NavTileCache unused;
    return bakeNavMesh(mesh, unused, verts, indices, cfg, triAreas);
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
