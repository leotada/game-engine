/**
 * `StaticInstanceBuffer` — retained GPU instancing for static world props.
 *
 * Built once (level load / chunk activation), it sorts every instance by
 * `(mesh × material group, world cell)` and uploads them into a single GPU
 * instance buffer. Nothing is rebuilt or re-uploaded per frame: each frame
 * `Scene3DTextured` culls the per-(group, cell) ranges against the camera
 * (and shadow) frustum, picks one LOD per range from its nearest distance,
 * merges adjacent visible ranges with the same LOD and issues one
 * `drawIndexed(..., firstIndex = lodFirst[lod], firstInstance = run start)`
 * per merged run.
 *
 * Usage:
 * ---
 * TexMesh*[] meshes = [&rock, &tree];
 * Material*[] mats  = [&rockMat, &treeMat];
 * StaticInstanceDesc[] props = ...;            // mesh/material indices + model
 * auto sib = StaticInstanceBuffer.build(gpu, meshes, mats, props);
 * sib.setGroupCull(1, 800, 2);                 // trees: 800 m, 2 px minimum
 * // per frame, between scene.begin and scene.end:
 * scene.submitStatic(sib);
 * ---
 * The meshes and materials must outlive the buffer.
 */
module engine.scene.static_instances;

import engine.core.log;
import engine.core.pod : isPod, Pod;
import engine.gpu.buffer : createVertexBuffer, destroyBuffer, updateBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : TexInstanceData;
import engine.graphics.lod : LOD_NONE, projectedPixels, selectLod;
import engine.graphics.material : Material;
import engine.graphics.texmesh : TexMesh;
import engine.graphics.types : Color4;
import engine.math.bounds : Aabb, BoundingSphere, maxAxisScale;
import engine.math.frustum : Frustum;
import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import bindings.wgpu : WGPUBuffer, WGPUQueue;

@safe:

/// One static prop: indices into the mesh / material tables plus a transform.
struct StaticInstanceDesc {
    uint mesh;
    uint material;
    Mat4 model;
    Color4 tint = Color4.white;
    /// Same meaning as `Scene3DTextured.drawMatrix`'s `custom`.
    float[4] custom = [1.0f, 0.0f, 0.0f, 0.0f];
}

/// Build options.
struct StaticBuildOptions {
    /// Static cell size in meters (coarser than the dynamic grid to keep draw counts low).
    float cellSize = 128;
    /// Default culling for every group (0 = off); see `setGroupCull`.
    float maxDistance = 0;
    float minPixelSize = 0;
}

/// One (mesh, material) group with its culling and LOD parameters.
struct StaticGroup {
    uint mesh;
    uint material;
    float maxDistance = 0;
    float minPixelSize = 0;
    ubyte lodLevels;
    float lodMeshScale = 1;
    float[8] lodErrors;
}
static assert(isPod!StaticGroup);

/// Contiguous instances of one group inside one cell.
struct StaticRange {
    uint group;
    uint cell;
    uint firstInstance;
    uint count;
    /// World bounds of every instance sphere in the range.
    Aabb bounds;
    /// Largest instance axis scale (LOD world scale).
    float maxScale = 1;
    /// Largest instance world-sphere radius (min-pixel culling).
    float maxRadius = 0;
}
static assert(isPod!StaticRange);

/// One merged visible draw.
struct StaticRun {
    uint group;
    ubyte lod;
    uint firstInstance;
    uint count;
}
static assert(isPod!StaticRun);

/// CPU result of `buildStaticLayout` (load time).
struct StaticLayout {
    TexInstanceData[] instances;
    StaticGroup[] groups;
    StaticRange[] ranges;
    /// `slotOf[descIndex]` = position of that instance in `instances`.
    uint[] slotOf;
}

/**
 * Sort `descs` by (group, cell) and build the range table.
 * `meshSpheres[i]` is the object-space bounding sphere of mesh `i`.
 * Cells are `cellSize` squares on XZ anchored at the instances' minimum corner.
 */
StaticLayout buildStaticLayout(scope const(StaticInstanceDesc)[] descs,
                               scope const(BoundingSphere)[] meshSpheres, float cellSize) {
    import std.algorithm.sorting : sort;
    import std.exception : enforce;

    StaticLayout layout;
    if (descs.length == 0) return layout;
    if (!(cellSize > 0)) cellSize = 128;

    // Groups in first-seen order.
    uint[ulong] groupOf;
    auto keyGroup = new uint[descs.length];
    auto spheres = new BoundingSphere[descs.length];
    float minX = float.infinity, minZ = float.infinity;
    foreach (i, ref d; descs) {
        enforce(d.mesh < meshSpheres.length, "StaticInstanceBuffer: mesh index out of range");
        immutable key = (cast(ulong) d.mesh << 32) | d.material;
        if (auto p = key in groupOf) {
            keyGroup[i] = *p;
        } else {
            immutable g = cast(uint) layout.groups.length;
            groupOf[key] = g;
            StaticGroup grp;
            grp.mesh = d.mesh;
            grp.material = d.material;
            layout.groups ~= grp;
            keyGroup[i] = g;
        }
        spheres[i] = meshSpheres[d.mesh].transformed(d.model);
        if (spheres[i].center.x < minX) minX = spheres[i].center.x;
        if (spheres[i].center.z < minZ) minZ = spheres[i].center.z;
    }

    // Cell per instance (row-major, columns from the bounds' width).
    float maxX = -float.infinity;
    foreach (ref s; spheres) if (s.center.x > maxX) maxX = s.center.x;
    immutable uint cellsX = cast(uint)((maxX - minX) / cellSize) + 1;
    auto cellOf = new uint[descs.length];
    foreach (i, ref s; spheres) {
        immutable cx = cast(uint)((s.center.x - minX) / cellSize);
        immutable cz = cast(uint)((s.center.z - minZ) / cellSize);
        cellOf[i] = cz * cellsX + cx;
    }

    auto order = new uint[descs.length];
    foreach (i; 0 .. descs.length) order[i] = cast(uint) i;
    order.sort!((a, b) => keyGroup[a] != keyGroup[b] ? keyGroup[a] < keyGroup[b]
                        : (cellOf[a] != cellOf[b] ? cellOf[a] < cellOf[b] : a < b));

    layout.instances = new TexInstanceData[descs.length];
    layout.slotOf = new uint[descs.length];
    foreach (slot, src; order) {
        auto d = &descs[src];
        layout.instances[slot] = TexInstanceData(d.model.m, d.tint.toArray(), d.custom);
        layout.slotOf[src] = cast(uint) slot;
        immutable g = keyGroup[src], c = cellOf[src];
        if (layout.ranges.length == 0 || layout.ranges[$ - 1].group != g || layout.ranges[$ - 1].cell != c) {
            StaticRange r;
            r.group = g;
            r.cell = c;
            r.firstInstance = cast(uint) slot;
            r.maxScale = 0;
            layout.ranges ~= r;
        }
        auto r = &layout.ranges[$ - 1];
        r.count++;
        auto s = spheres[src];
        r.bounds = r.bounds.merge(Aabb(Vec3(s.center.x - s.radius, s.center.y - s.radius, s.center.z - s.radius),
                                       Vec3(s.center.x + s.radius, s.center.y + s.radius, s.center.z + s.radius)));
        immutable sc = maxAxisScale(d.model);
        if (sc > r.maxScale) r.maxScale = sc;
        if (s.radius > r.maxRadius) r.maxRadius = s.radius;
    }
    return layout;
}

/// Camera / LOD inputs of one culling pass.
struct StaticViewParams {
    Vec3 cameraPos;
    float fovY = 0.9f;
    float screenHeight = 1080;
    float lodBias = 1;
    /// Apply group max-distance / min-pixel culling (color and directional passes).
    bool distanceCull = true;
}

/// Distance from `p` to the closest point of `b` (0 inside).
float distanceToAabb(Vec3 p, Aabb b) pure nothrow @nogc {
    import core.math : sqrt;
    immutable dx = p.x < b.min.x ? b.min.x - p.x : (p.x > b.max.x ? p.x - b.max.x : 0);
    immutable dy = p.y < b.min.y ? b.min.y - p.y : (p.y > b.max.y ? p.y - b.max.y : 0);
    immutable dz = p.z < b.min.z ? b.min.z - p.z : (p.z > b.max.z ? p.z - b.max.z : 0);
    return sqrt(dx * dx + dy * dy + dz * dz);
}

/**
 * Cull ranges against `frustum`, pick one LOD per range from its nearest
 * distance to the camera, and merge adjacent visible ranges of the same
 * group and LOD. Writes at most `outRuns.length` runs; returns the count.
 */
size_t collectVisibleRuns(const(StaticGroup)[] groups, const(StaticRange)[] ranges,
                          ref const Frustum frustum, StaticViewParams view,
                          scope StaticRun[] outRuns) nothrow @nogc {
    size_t n = 0;
    foreach (ref r; ranges) {
        if (!frustum.intersectsAabb(r.bounds)) continue;
        auto g = &groups[r.group];
        immutable d = distanceToAabb(view.cameraPos, r.bounds);
        if (view.distanceCull) {
            if (g.maxDistance > 0 && d > g.maxDistance) continue;
            if (g.minPixelSize > 0 && d > r.maxRadius
                    && projectedPixels(2 * r.maxRadius, d, view.fovY, view.screenHeight) < g.minPixelSize)
                continue;
        }
        ubyte lod = 0;
        if (g.lodLevels > 1)
            lod = selectLod(g.lodErrors[0 .. g.lodLevels], LOD_NONE, g.lodMeshScale, r.maxScale, d,
                            view.fovY, view.screenHeight, view.lodBias);
        if (n > 0) {
            auto last = &outRuns[n - 1];
            if (last.group == r.group && last.lod == lod && last.firstInstance + last.count == r.firstInstance) {
                last.count += r.count;
                continue;
            }
        }
        if (n >= outRuns.length) break;
        outRuns[n++] = StaticRun(r.group, lod, r.firstInstance, r.count);
    }
    return n;
}

/// Retained, cell-sorted GPU instance buffer of static props. Move-only.
struct StaticInstanceBuffer {
    package(engine) TexMesh*[] meshes;
    package(engine) Material*[] materials;
    package(engine) Pod!StaticGroup[] groups;
    package(engine) Pod!StaticRange[] ranges;
    package(engine) WGPUBuffer instanceBuf;
    package(engine) uint instanceCount;
    private Pod!uint[] slotOf;
    private WGPUQueue queue;

    @disable this(this);

    /// Sort, group and upload `descs` once. Load time only (allocates).
    static StaticInstanceBuffer build(ref GpuContext gpu, TexMesh*[] meshes, Material*[] materials,
                                      const(StaticInstanceDesc)[] descs,
                                      StaticBuildOptions opts = StaticBuildOptions.init) {
        StaticInstanceBuffer sib;
        sib.meshes = meshes;
        sib.materials = materials;
        sib.queue = gpu.getQueue();
        auto spheres = new BoundingSphere[meshes.length];
        foreach (i, m; meshes) spheres[i] = m.localSphere;
        foreach (ref d; descs) {
            if (d.material >= materials.length) {
                err("StaticInstanceBuffer: material index out of range");
                return sib;
            }
        }
        auto layout = buildStaticLayout(descs, spheres, opts.cellSize);
        foreach (ref g; layout.groups) {
            g.maxDistance = opts.maxDistance;
            g.minPixelSize = opts.minPixelSize;
            auto mesh = meshes[g.mesh];
            auto errs = mesh.lodErrorList();
            g.lodLevels = cast(ubyte) errs.length;
            g.lodErrors[0 .. errs.length] = errs[];
            g.lodMeshScale = mesh.lodMeshScale;
        }
        sib.groups = layout.groups;
        sib.ranges = layout.ranges;
        sib.slotOf = layout.slotOf;
        sib.instanceCount = cast(uint) layout.instances.length;
        if (layout.instances.length)
            sib.instanceBuf = createVertexBuffer(gpu.getDevice(), sib.queue, layout.instances);
        info("StaticInstanceBuffer: ", sib.instanceCount, " instances, ", sib.groups.length,
             " groups, ", sib.ranges.length, " ranges");
        return sib;
    }

    /// Culling for every group of `meshIndex` (0 disables either test).
    void setMeshCull(uint meshIndex, float maxDistance, float minPixelSize = 0) nothrow @nogc {
        foreach (ref g; groups)
            if (g.mesh == meshIndex) {
                g.maxDistance = maxDistance;
                g.minPixelSize = minPixelSize;
            }
    }

    /// Culling for one group (index in build order of first appearance).
    void setGroupCull(uint group, float maxDistance, float minPixelSize = 0) nothrow @nogc {
        if (group >= groups.length) return;
        groups[group].maxDistance = maxDistance;
        groups[group].minPixelSize = minPixelSize;
    }

    /**
     * Slow path for rare edits (a destroyed fence): rewrite one instance's
     * transform in place. Range bounds are not recomputed, so keep the new
     * position inside the original cell.
     */
    void updateInstance(size_t descIndex, Mat4 model, Color4 tint = Color4.white) nothrow @nogc @trusted {
        if (descIndex >= slotOf.length || instanceBuf is null) return;
        auto data = TexInstanceData(model.m, tint.toArray(), [1.0f, 0.0f, 0.0f, 0.0f]);
        import engine.gpu.buffer : updateBuffer;
        import bindings.wgpu : wgpuQueueWriteBuffer;
        wgpuQueueWriteBuffer(queue, instanceBuf, slotOf[descIndex] * TexInstanceData.sizeof,
                             &data, TexInstanceData.sizeof);
    }

    /// Hide one instance (zero scale) — e.g. a prop replaced by a physics debris entity.
    void hideInstance(size_t descIndex) nothrow @nogc {
        Mat4 zero;
        zero.m[] = 0;
        updateInstance(descIndex, zero);
    }

    size_t groupCount() const nothrow @nogc { return groups.length; }
    size_t rangeCount() const nothrow @nogc { return ranges.length; }
    uint length() const nothrow @nogc { return instanceCount; }

    void destroy() nothrow @nogc {
        destroyBuffer(instanceBuf);
        instanceBuf = null;
        instanceCount = 0;
    }
}

// ---------------------------------------------------------------------------

version (unittest) {
    private StaticInstanceDesc prop(uint mesh, uint mat, float x, float z, float s = 1) {
        return StaticInstanceDesc(mesh, mat, Mat4.translation(x, 0, z) * Mat4.scaling(s, s, s));
    }
}

@("staticInstances.layout") @safe unittest {
    BoundingSphere[2] spheres = [BoundingSphere(Vec3(0, 0, 0), 1), BoundingSphere(Vec3(0, 1, 0), 2)];
    StaticInstanceDesc[] descs = [
        prop(0, 0, 10, 10),       // g0 cell(0,0)
        prop(1, 0, 10, 10),       // g1
        prop(0, 0, 300, 10),      // g0 cell(2,0)
        prop(0, 0, 20, 20, 3),    // g0 cell(0,0)
        prop(0, 1, 15, 15),       // g2 (same mesh, other material)
        prop(1, 0, 290, 10),      // g1 cell(2,0)
    ];
    auto layout = buildStaticLayout(descs, spheres[], 128);
    assert(layout.groups.length == 3);
    assert(layout.groups[0].mesh == 0 && layout.groups[0].material == 0);
    assert(layout.groups[1].mesh == 1 && layout.groups[2].material == 1);
    assert(layout.instances.length == 6);
    // Ranges: g0 cell0 (2), g0 cell2 (1), g1 cell0 (1), g1 cell2 (1), g2 (1)
    assert(layout.ranges.length == 5);
    assert(layout.ranges[0].group == 0 && layout.ranges[0].count == 2 && layout.ranges[0].firstInstance == 0);
    assert(layout.ranges[1].group == 0 && layout.ranges[1].firstInstance == 2);
    assert(layout.ranges[2].group == 1 && layout.ranges[2].firstInstance == 3);
    foreach (i; 1 .. layout.ranges.length)
        assert(layout.ranges[i].firstInstance == layout.ranges[i - 1].firstInstance + layout.ranges[i - 1].count);
    // Bounds and scale of the first range include the scaled prop.
    assert(layout.ranges[0].maxScale == 3 && layout.ranges[0].maxRadius == 3);
    assert(layout.ranges[0].bounds.max.x == 23 && layout.ranges[0].bounds.min.x == 9);
    // slotOf maps back: desc 3 (scaled g0 prop) sits inside range 0.
    assert(layout.slotOf[3] < 2 && layout.instances[layout.slotOf[3]].model[12] == 20);
    assert(layout.instances[layout.slotOf[5]].model[12] == 290);
}

@("staticInstances.runs") @safe unittest {
    import engine.scene.camera : Camera;
    BoundingSphere[1] spheres = [BoundingSphere(Vec3(0, 0, 0), 1)];
    // A line of props along -Z, one per 128 m cell.
    StaticInstanceDesc[] descs;
    foreach (i; 0 .. 8) descs ~= prop(0, 0, 0, -10.0f - i * 128.0f);
    descs ~= prop(0, 0, 0, 500); // behind the camera
    auto layout = buildStaticLayout(descs, spheres[], 128);
    assert(layout.ranges.length == 9);

    auto cam = Camera.create(1.0f, 1.0f, 0.1f, 5000.0f);
    cam.lookAt(Vec3(0, 1, 0), Vec3(0, 1, -1));
    auto f = Frustum.fromViewProj(cam.viewProjection());
    StaticViewParams view;
    view.cameraPos = cam.position;
    view.fovY = cam.fovY;
    view.screenHeight = 1000;
    StaticRun[16] runs;

    // No LOD chain: all eight visible ranges are contiguous → one run.
    auto n = collectVisibleRuns(layout.groups, layout.ranges, f, view, runs[]);
    assert(n == 1 && runs[0].count == 8 && runs[0].lod == 0);

    // LOD chain: near ranges LOD0, far ranges coarser → split by LOD.
    layout.groups[0].lodLevels = 3;
    // Nearest range (~9 m): LOD1 error 0.05 ≈ 5 px → LOD0. Farthest (~900 m):
    // LOD2 error 0.5 ≈ 0.5 px → LOD2. Cells sort by ascending Z, so the far
    // ranges come first.
    layout.groups[0].lodErrors[0 .. 3] = [0.0f, 0.05f, 0.5f];
    n = collectVisibleRuns(layout.groups, layout.ranges, f, view, runs[]);
    assert(n >= 2);
    ubyte minLod = ubyte.max, maxLod = 0;
    uint total = 0;
    foreach (r; runs[0 .. n]) {
        total += r.count;
        if (r.lod < minLod) minLod = r.lod;
        if (r.lod > maxLod) maxLod = r.lod;
    }
    assert(total == 8 && minLod == 0 && maxLod == 2);
    // Adjacent runs never share a LOD (they would have been merged).
    foreach (i; 1 .. n) assert(runs[i].lod != runs[i - 1].lod);

    // Distance cull keeps the first three cells (nearest points ≤ 300 m).
    layout.groups[0].lodLevels = 0;
    layout.groups[0].maxDistance = 300;
    n = collectVisibleRuns(layout.groups, layout.ranges, f, view, runs[]);
    assert(n == 1 && runs[0].count == 3);
    view.distanceCull = false;
    n = collectVisibleRuns(layout.groups, layout.ranges, f, view, runs[]);
    assert(runs[0].count == 8);

    // Min-pixel cull drops tiny far props (radius 1).
    view.distanceCull = true;
    layout.groups[0].maxDistance = 0;
    layout.groups[0].minPixelSize = 4;
    n = collectVisibleRuns(layout.groups, layout.ranges, f, view, runs[]);
    assert(n == 1 && runs[0].count < 8 && runs[0].count >= 1);
}
