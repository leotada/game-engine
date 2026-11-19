/**
 * `SpatialGrid` — loose uniform grid over the XZ plane for open-world
 * culling queries (frustum + distance) over dynamic objects.
 *
 * - Items are bounding spheres placed in the cell containing their center.
 *   Cells are "loose": the query expands each cell by half a cell, so any
 *   sphere with `radius <= cellSize / 2` is found through its home cell.
 *   Larger spheres (and centers outside the grid) go to an always-tested
 *   overflow list.
 * - Per-cell intrusive doubly-linked lists make insert / update / remove
 *   O(1); item storage is `PodBuffer` (malloc), so every operation is
 *   `nothrow @nogc` and the GC never scans it.
 * - Each cell keeps a grow-only Y range so tall frustum tests stay tight.
 *
 * Typical use: one grid per world (64 m cells over 3 km = 47 × 47 cells),
 * `update` moving objects each frame, `query` once per camera / light.
 */
module engine.scene.spatial_grid;

import engine.core.podbuf : PodBuffer;
import engine.math.bounds : Aabb, BoundingSphere;
import engine.math.frustum : Frustum;
import engine.math.vec : Vec3;

@safe:

/// Item handle returned by `SpatialGrid.insert`.
alias GridItem = uint;
enum GridItem GRID_NONE = uint.max;

private struct GridEntry {
    uint userId;
    BoundingSphere sphere;
    /// Home cell, or `OVERFLOW_CELL`; `FREE_CELL` when on the free list.
    uint cell;
    uint next = GRID_NONE;
    uint prev = GRID_NONE;
}

private enum uint OVERFLOW_CELL = uint.max - 1;
private enum uint FREE_CELL = uint.max;

struct SpatialGrid {
    private float originX = 0, originZ = 0;
    private float cellSize_ = 64;
    private uint cellsX, cellsZ;
    private PodBuffer!uint cellHead;
    private PodBuffer!float cellMinY;
    private PodBuffer!float cellMaxY;
    private PodBuffer!GridEntry items;
    private PodBuffer!uint freeItems;
    private uint overflowHead = GRID_NONE;
    private uint liveCount;

    @disable this(this);

    /// Grid covering `[originX, originX + sizeX) × [originZ, originZ + sizeZ)`.
    static SpatialGrid create(float originX, float originZ, float sizeX, float sizeZ,
                              float cellSize = 64) nothrow @nogc {
        SpatialGrid g;
        g.originX = originX;
        g.originZ = originZ;
        g.cellSize_ = cellSize > 0 ? cellSize : 64;
        g.cellsX = cast(uint)((sizeX + g.cellSize_ - 1) / g.cellSize_);
        g.cellsZ = cast(uint)((sizeZ + g.cellSize_ - 1) / g.cellSize_);
        if (g.cellsX == 0) g.cellsX = 1;
        if (g.cellsZ == 0) g.cellsZ = 1;
        immutable n = cast(size_t) g.cellsX * g.cellsZ;
        g.cellHead.resize(n);
        g.cellMinY.resize(n);
        g.cellMaxY.resize(n);
        g.cellHead[][] = GRID_NONE;
        g.cellMinY[][] = float.infinity;
        g.cellMaxY[][] = -float.infinity;
        return g;
    }

    float cellSize() const nothrow @nogc { return cellSize_; }
    uint cellCountX() const nothrow @nogc { return cellsX; }
    uint cellCountZ() const nothrow @nogc { return cellsZ; }
    /// Live items.
    uint length() const nothrow @nogc { return liveCount; }

    /// Add a sphere tagged with `userId` (entity id, instance index...).
    GridItem insert(uint userId, BoundingSphere sphere) nothrow @nogc {
        uint h;
        if (freeItems.length) {
            h = freeItems[freeItems.length - 1];
            freeItems.resize(freeItems.length - 1);
        } else {
            h = cast(uint) items.length;
            items.put(GridEntry.init);
        }
        items[h] = GridEntry(userId, sphere, FREE_CELL, GRID_NONE, GRID_NONE);
        link(h, homeCell(sphere));
        liveCount++;
        return h;
    }

    /// Move / resize an item. Re-links only when its home cell changes.
    void update(GridItem h, BoundingSphere sphere) nothrow @nogc {
        if (!isLive(h)) return;
        immutable cell = homeCell(sphere);
        items[h].sphere = sphere;
        if (cell != items[h].cell) {
            unlink(h);
            link(h, cell);
        } else if (cell != OVERFLOW_CELL) {
            growCellY(cell, sphere);
        }
    }

    void remove(GridItem h) nothrow @nogc {
        if (!isLive(h)) return;
        unlink(h);
        items[h].cell = FREE_CELL;
        freeItems.put(h);
        liveCount--;
    }

    bool isLive(GridItem h) const nothrow @nogc {
        return h < items.length && items[h].cell != FREE_CELL;
    }

    /// `userId` stored for item `h`.
    uint userIdOf(GridItem h) const nothrow @nogc { return items[h].userId; }

    /**
     * Write the `userId` of every item whose sphere intersects `frustum` and
     * lies within `maxDistance` of `camPos` (`maxDistance <= 0`: unlimited).
     * Returns how many ids were written; stops when `outIds` is full.
     */
    size_t query(ref const Frustum frustum, Vec3 camPos, float maxDistance,
                 scope uint[] outIds) const nothrow @nogc {
        size_t count = 0;
        bool accept(ref const GridEntry e) {
            if (!frustum.intersectsSphere(e.sphere)) return false;
            if (maxDistance > 0) {
                immutable d = (e.sphere.center - camPos).length();
                if (d - e.sphere.radius > maxDistance) return false;
            }
            return true;
        }

        for (uint it = overflowHead; it != GRID_NONE && count < outIds.length; it = items[it].next)
            if (accept(items[it])) outIds[count++] = items[it].userId;

        // Broad phase: frustum corner box, clipped to the distance sphere.
        float minX = frustum.bounds.min.x, maxX = frustum.bounds.max.x;
        float minZ = frustum.bounds.min.z, maxZ = frustum.bounds.max.z;
        if (maxDistance > 0) {
            if (camPos.x - maxDistance > minX) minX = camPos.x - maxDistance;
            if (camPos.x + maxDistance < maxX) maxX = camPos.x + maxDistance;
            if (camPos.z - maxDistance > minZ) minZ = camPos.z - maxDistance;
            if (camPos.z + maxDistance < maxZ) maxZ = camPos.z + maxDistance;
        }
        immutable loose = cellSize_ * 0.5f;
        int cx0 = cellCoord(minX - loose, originX), cx1 = cellCoord(maxX + loose, originX);
        int cz0 = cellCoord(minZ - loose, originZ), cz1 = cellCoord(maxZ + loose, originZ);
        if (cx1 < 0 || cz1 < 0 || cx0 >= cast(int) cellsX || cz0 >= cast(int) cellsZ) return count;
        if (cx0 < 0) cx0 = 0;
        if (cz0 < 0) cz0 = 0;
        if (cx1 >= cast(int) cellsX) cx1 = cellsX - 1;
        if (cz1 >= cast(int) cellsZ) cz1 = cellsZ - 1;

        foreach (cz; cz0 .. cz1 + 1) {
            foreach (cx; cx0 .. cx1 + 1) {
                immutable cell = cast(uint)(cz * cellsX + cx);
                if (cellHead[cell] == GRID_NONE) continue;
                immutable x0 = originX + cx * cellSize_, z0 = originZ + cz * cellSize_;
                immutable box = Aabb(Vec3(x0 - loose, cellMinY[cell], z0 - loose),
                                     Vec3(x0 + cellSize_ + loose, cellMaxY[cell], z0 + cellSize_ + loose));
                if (!frustum.intersectsAabb(box)) continue;
                for (uint it = cellHead[cell]; it != GRID_NONE; it = items[it].next) {
                    if (count >= outIds.length) return count;
                    if (accept(items[it])) outIds[count++] = items[it].userId;
                }
            }
        }
        return count;
    }

    /// Free all memory.
    void release() nothrow @nogc {
        cellHead.release();
        cellMinY.release();
        cellMaxY.release();
        items.release();
        freeItems.release();
        overflowHead = GRID_NONE;
        liveCount = 0;
    }

    private int cellCoord(float v, float origin) const nothrow @nogc {
        immutable f = (v - origin) / cellSize_;
        return f < 0 ? cast(int) f - 1 : cast(int) f;
    }

    private uint homeCell(BoundingSphere s) const nothrow @nogc {
        if (s.radius > cellSize_ * 0.5f) return OVERFLOW_CELL;
        immutable cx = cellCoord(s.center.x, originX), cz = cellCoord(s.center.z, originZ);
        if (cx < 0 || cz < 0 || cx >= cast(int) cellsX || cz >= cast(int) cellsZ) return OVERFLOW_CELL;
        return cast(uint)(cz * cellsX + cx);
    }

    private void growCellY(uint cell, BoundingSphere s) nothrow @nogc {
        immutable lo = s.center.y - s.radius, hi = s.center.y + s.radius;
        if (lo < cellMinY[cell]) cellMinY[cell] = lo;
        if (hi > cellMaxY[cell]) cellMaxY[cell] = hi;
    }

    private void link(uint h, uint cell) nothrow @nogc @trusted {
        uint* head = cell == OVERFLOW_CELL ? &overflowHead : &cellHead[cell];
        items[h].cell = cell;
        items[h].prev = GRID_NONE;
        items[h].next = *head;
        if (*head != GRID_NONE) items[*head].prev = h;
        *head = h;
        if (cell != OVERFLOW_CELL) growCellY(cell, items[h].sphere);
    }

    private void unlink(uint h) nothrow @nogc {
        immutable cell = items[h].cell;
        immutable prev = items[h].prev, next = items[h].next;
        if (prev != GRID_NONE) items[prev].next = next;
        else if (cell == OVERFLOW_CELL) overflowHead = next;
        else cellHead[cell] = next;
        if (next != GRID_NONE) items[next].prev = prev;
        items[h].prev = items[h].next = GRID_NONE;
    }
}

@("spatialGrid.query") nothrow @nogc unittest {
    import engine.math.mat : Mat4;
    import engine.scene.camera : Camera;

    auto grid = SpatialGrid.create(-512, -512, 1024, 1024, 64);
    assert(grid.cellCountX == 16 && grid.cellCountZ == 16);
    // Row of props along -Z in front of the camera, and some behind it.
    foreach (uint i; 0 .. 20)
        grid.insert(i, BoundingSphere(Vec3(0, 1, -10.0f - i * 20.0f), 1));
    foreach (uint i; 0 .. 5)
        grid.insert(100 + i, BoundingSphere(Vec3(0, 1, 30.0f + i * 20.0f), 1));
    auto big = grid.insert(999, BoundingSphere(Vec3(300, 0, 0), 200)); // overflow list
    assert(grid.length == 26);

    auto cam = Camera.create(1.0f, 1.0f, 0.1f, 500.0f);
    cam.lookAt(Vec3(0, 2, 0), Vec3(0, 2, -1));
    auto f = Frustum.fromViewProj(cam.viewProjection());

    uint[64] ids;
    auto n = grid.query(f, cam.position, 0, ids[]);
    // 20 in front (z = -10 .. -390) and the large sphere reaching x = 100 at z = 0?
    // It spans x ∈ [100, 500] near z = 0: outside the frustum near the apex.
    assert(n == 20);
    foreach (id; ids[0 .. n]) assert(id < 20);

    // Distance limit keeps only the first ones (z >= -105).
    n = grid.query(f, cam.position, 105, ids[]);
    assert(n == 5);

    // Output buffer bounds the result.
    n = grid.query(f, cam.position, 0, ids[0 .. 3]);
    assert(n == 3);

    // Move one item behind the camera, remove another, re-add (free list reuse).
    grid.update(0, BoundingSphere(Vec3(0, 1, 50), 1));
    grid.remove(1);
    n = grid.query(f, cam.position, 0, ids[]);
    assert(n == 18);
    auto h = grid.insert(77, BoundingSphere(Vec3(5, 1, -60), 1));
    assert(h == 1); // reused slot
    n = grid.query(f, cam.position, 0, ids[]);
    assert(n == 19);

    // Overflow sphere comes into view when the camera turns to +X.
    cam.lookAt(Vec3(0, 2, 0), Vec3(1, 2, 0));
    f = Frustum.fromViewProj(cam.viewProjection());
    n = grid.query(f, cam.position, 0, ids[]);
    bool sawBig = false;
    foreach (id; ids[0 .. n]) if (id == 999) sawBig = true;
    assert(sawBig);
    grid.remove(big);
    assert(!grid.isLive(big));
    grid.release();
}
