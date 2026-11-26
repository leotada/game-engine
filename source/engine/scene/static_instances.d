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
import engine.gpu.buffer : createBufferWithUsage, createVertexBuffer, destroyBuffer, updateBuffer;
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
import engine.scene.cascades : ReceiverCull;
import engine.gpu.static_cull : CullGroup, CullMeta, cullMetaOf, MeshPool, StaticGpuData;
import bindings.wgpu : WGPUBuffer, WGPUBufferUsage, WGPUQueue;

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
    /**
     * Cull, pick LODs and build the draws on the GPU: per instance instead of
     * per cell range, with a handful of indirect multi-draws instead of one
     * draw per range. Camera and directional shadow views only; point and spot
     * shadows keep the CPU path. Needs the `indirectFirstInstance` and
     * `multiDrawIndirectCount` features (otherwise the CPU path is used).
     * Meshes are copied at build: later `TexMesh.updateVertices` are not seen.
     */
    bool gpuCull = false;
    /// With `gpuCull`: take every decision from the bounds of the instance's cell
    /// range, like the CPU path. For comparisons; draws more instances.
    bool rangeLodParity = false;
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
    /// `cellBounds[cell]` = union of every range bound in that cell (empty for unused cells).
    Aabb[] cellBounds;
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
    uint maxCell = 0;
    foreach (ref r; layout.ranges) if (r.cell > maxCell) maxCell = r.cell;
    layout.cellBounds = new Aabb[maxCell + 1];
    foreach (ref r; layout.ranges)
        layout.cellBounds[r.cell] = layout.cellBounds[r.cell].merge(r.bounds);
    return layout;
}

/**
 * Coarse culling pass: `visible[c]` = whether cell `c`'s bounds touch `frustum`.
 * `visible.length` must be at least `cellBounds.length`. Ranges of an invisible
 * cell can be skipped without testing them (`collectVisibleRuns`).
 */
void markVisibleCells(scope const(Aabb)[] cellBounds, ref const Frustum frustum,
                      scope bool[] visible, ref const StaticViewParams view) nothrow @nogc {
    foreach (c, ref b; cellBounds)
        visible[c] = frustum.intersectsAabb(b) && (!view.receiverCull || view.receiver.keeps(b));
}

/// ditto, frustum only.
void markVisibleCells(scope const(Aabb)[] cellBounds, ref const Frustum frustum,
                      scope bool[] visible) nothrow @nogc {
    StaticViewParams plain;
    markVisibleCells(cellBounds, frustum, visible, plain);
}

/// Camera / LOD inputs of one culling pass.
struct StaticViewParams {
    Vec3 cameraPos;
    float fovY = 0.9f;
    float screenHeight = 1080;
    float lodBias = 1;
    /// Apply group max-distance / min-pixel culling (color and directional passes).
    bool distanceCull = true;
    /// Shadow cascades: also require `receiver.keeps(bounds)` (receiver-aware culling).
    bool receiverCull = false;
    ReceiverCull receiver;
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
                          scope StaticRun[] outRuns, scope const(bool)[] cellVisible = null) nothrow @nogc {
    size_t n = 0;
    immutable bool useCells = cellVisible.length > 0;
    foreach (ref r; ranges) {
        if (useCells && !cellVisible[r.cell]) continue;
        if (!frustum.intersectsAabb(r.bounds)) continue;
        if (view.receiverCull && !view.receiver.keeps(r.bounds)) continue;
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
    /// Union of the range bounds per cell (coarse culling, `markVisibleCells`).
    package(engine) Pod!Aabb[] cellBounds;
    package(engine) WGPUBuffer instanceBuf;
    package(engine) uint instanceCount;
    private Pod!uint[] slotOf;
    private WGPUQueue queue;
    /// GPU culling state; inactive on the CPU path.
    StaticGpuData gpuData;
    private bool rangeParity;

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
        sib.cellBounds = layout.cellBounds;
        sib.slotOf = layout.slotOf;
        sib.instanceCount = cast(uint) layout.instances.length;
        immutable useGpu = opts.gpuCull && layout.instances.length > 0 && StaticGpuData.supported(gpu)
            // One compute workgroup per block, at most 65535 per dispatch.
            && layout.instances.length / 64 + layout.groups.length <= 65_535;
        if (opts.gpuCull && !useGpu)
            info("StaticInstanceBuffer: GPU culling not supported here, using the CPU path");
        if (useGpu) {
            sib.rangeParity = opts.rangeLodParity;
            sib.instanceBuf = createBufferWithUsage(gpu.getDevice(), layout.instances.length * TexInstanceData.sizeof,
                WGPUBufferUsage.vertex | WGPUBufferUsage.copyDst | WGPUBufferUsage.storage);
            updateBuffer(sib.queue, sib.instanceBuf, layout.instances);
            sib.buildGpu(gpu, layout);
        } else if (layout.instances.length) {
            sib.instanceBuf = createVertexBuffer(gpu.getDevice(), sib.queue, layout.instances);
        }
        info("StaticInstanceBuffer: ", sib.instanceCount, " instances, ", sib.groups.length,
             " groups, ", sib.ranges.length, " ranges, ", sib.cellBounds.length, " cells");
        return sib;
    }

    /// Build the GPU culling tables (load time).
    private void buildGpu(ref GpuContext gpu, ref StaticLayout layout) {
        import std.algorithm.sorting : sort;
        auto metas = new CullMeta[layout.instances.length];
        auto table = new CullGroup[groups.length];
        foreach (ref r; ranges) {
            auto g = &table[r.group];
            if (g.count == 0) g.first = r.firstInstance;
            g.count += r.count;
            immutable c = r.bounds.min * 0.5f + r.bounds.max * 0.5f, e = r.bounds.max * 0.5f - r.bounds.min * 0.5f;
            foreach (slot; r.firstInstance .. r.firstInstance + r.count) {
                if (rangeParity) {
                    metas[slot] = CullMeta([c.x, c.y, c.z], r.maxScale, [e.x, e.y, e.z], r.maxRadius);
                } else {
                    Mat4 m;
                    m.m = layout.instances[slot].model;
                    metas[slot] = cullMetaOf(meshes[groups[r.group].mesh].localSphere.transformed(m), maxAxisScale(m));
                }
            }
        }
        gpuData.pool = MeshPool.build(gpu, meshes);
        auto order = new uint[groups.length];
        foreach (i, ref o; order) o = cast(uint) i;
        // Neighbors in this order share pool buffers, then the shadow state, then the material.
        ulong key(uint gi) {
            auto mesh = meshes[groups[gi].mesh];
            auto mat = materials[groups[gi].material];
            immutable ulong cls = (mat.surfaceShader != 0 || mat.renderState.alphaMask) ? 1 : 0;
            // Casters of one surface shader stay neighbors, so the shadow pass can batch them.
            immutable ulong shader = mat.surfaceShader < 255 ? mat.surfaceShader : 255;
            return (cast(ulong) MeshPool.strideIndex(mesh.vertexStride) << 63)
                 | (cast(ulong) MeshPool.formatIndex(mesh.indexFormat) << 62)
                 | (cls << 61) | (cast(ulong) mat.renderState.depthWrite << 60)
                 | (cast(ulong) mat.renderState.doubleSided << 59)
                 | (cast(ulong) mat.renderState.alphaMask << 58)
                 | (shader << 50)
                 | ((cast(ulong) mat.surfaceSlot.chunk & 0x3F) << 44)
                 | ((cast(ulong) groups[gi].material & 0x1FFFF) << 27)
                 | (cast(ulong) mesh.hasVertexColors << 26) | (gi & 0x3FF_FFFF);
        }
        order.sort!((a, b) => key(a) < key(b));
        foreach (i, ref t; table) fillGroup(t, cast(uint) i);
        gpuData.build(gpu, table, order, metas, instanceBuf);
        bool anySurface = false;
        foreach (m; materials) anySurface |= m.surfaceShader != 0;
        if (anySurface) {
            auto slots = new uint[layout.instances.length];
            foreach (gi, ref t; table)
                slots[t.first .. t.first + t.count] = materials[groups[gi].material].surfaceSlot.index;
            gpuData.setParamIndices(gpu, slots);
        }
    }

    /// Copy the culling, LOD and index ranges of group `gi` into its GPU record.
    private void fillGroup(ref CullGroup t, uint gi) nothrow @nogc {
        auto g = &groups[gi];
        auto mesh = meshes[g.mesh];
        auto mat = materials[g.material];
        auto slot = gpuData.pool.slots[g.mesh];
        t.lodLevels = g.lodLevels;
        t.baseVertex = slot.baseVertex;
        t.maxDistance = g.maxDistance;
        t.minPixels = g.minPixelSize;
        t.meshScale = g.lodMeshScale;
        t.displacement = mat.displacementBound;
        foreach (l; 0 .. 8) {
            t.errors[l] = l < g.lodLevels ? g.lodErrors[l] : 0;
            immutable c = mesh.colorLodRange(cast(ubyte) l);
            immutable s = mesh.shadowLodDraw(cast(ubyte) l, mat.renderState.alphaMask);
            t.color[l] = [slot.firstIndex + c.first, c.count];
            t.shadow[l] = [(s.useLodRange ? slot.firstIndex : slot.firstShadowIndex) + s.first, s.count];
        }
    }

    /// Pick up material and culling changes made since the last frame.
    package(engine) void refreshGpuGroups() nothrow @nogc {
        foreach (i; 0 .. gpuData.groups.length) {
            CullGroup t = gpuData.groups[i];
            fillGroup(t, gpuData.partGroup[i]);
            if (t != gpuData.groups[i]) {
                gpuData.groups[i] = t;
                gpuData.dirty = true;
            }
        }
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
        if (gpuData.active && !rangeParity) {
            foreach (ref r; ranges)
                if (slotOf[descIndex] >= r.firstInstance && slotOf[descIndex] < r.firstInstance + r.count) {
                    auto sphere = meshes[groups[r.group].mesh].localSphere.transformed(model);
                    gpuData.setMeta(queue, slotOf[descIndex], cullMetaOf(sphere, maxAxisScale(model)));
                    break;
                }
        }
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

    /// True when this buffer is culled on the GPU (`StaticBuildOptions.gpuCull`).
    bool gpuCulled() const nothrow @nogc { return gpuData.active; }

    void destroy() nothrow @nogc {
        gpuData.destroy();
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

unittest {
    // The cell mask only skips work: the runs equal the plain per-range scan.
    import std.random : Random, uniform;
    import engine.scene.camera : Camera;
    auto rng = Random(7);
    StaticInstanceDesc[] descs;
    foreach (i; 0 .. 3000)
        descs ~= prop(uniform(0, 4, rng), uniform(0, 2, rng), uniform(-900.0f, 900.0f, rng),
                      uniform(-900.0f, 900.0f, rng), uniform(0.5f, 3.0f, rng));
    BoundingSphere[4] spheres;
    foreach (ref sp; spheres) sp = BoundingSphere(Vec3(0, 0, 0), 1.5f);
    auto layout = buildStaticLayout(descs, spheres[], 128);
    foreach (ref r; layout.ranges) assert(!layout.cellBounds[r.cell].empty);
    auto visible = new bool[layout.cellBounds.length];
    auto a = new StaticRun[layout.ranges.length], b = new StaticRun[layout.ranges.length];
    foreach (k; 0 .. 40) {
        auto cam = Camera.create(uniform(0.5f, 1.4f, rng), 16.0f / 9.0f, 0.5f, uniform(80.0f, 900.0f, rng));
        immutable pos = Vec3(uniform(-800.0f, 800.0f, rng), 5, uniform(-800.0f, 800.0f, rng));
        cam.lookAt(pos, pos + Vec3(uniform(-1.0f, 1.0f, rng), -0.1f, uniform(-1.0f, 1.0f, rng)));
        immutable f = Frustum.fromViewProj(cam.viewProjection());
        StaticViewParams view;
        view.cameraPos = pos;
        view.distanceCull = (k & 1) == 0;
        immutable na = collectVisibleRuns(layout.groups, layout.ranges, f, view, a);
        markVisibleCells(layout.cellBounds, f, visible);
        immutable nb = collectVisibleRuns(layout.groups, layout.ranges, f, view, b, visible);
        assert(na == nb);
        foreach (i; 0 .. na) assert(a[i] == b[i]);
    }
}
