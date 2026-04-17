// 
module engine.physics.broadphase;

import engine.math.vec;
import engine.physics.types;

@safe:

struct SpatialGrid(size_t DimX, size_t DimY, size_t DimZ, size_t MaxEntries = 32768) {
    enum size_t CELL_COUNT = DimX * DimY * DimZ;

    float cellSize = 4.0f;
    Vec3  origin   = Vec3(-64, -64, -64);

    private int[CELL_COUNT] cellHead; // -1 = empty
    private int[MaxEntries] nextEntry;
    private uint[MaxEntries] entryBody;
    private uint[MaxEntries] entryCell;
    private size_t entryCount;

    void clear() {
        cellHead[] = -1;
        entryCount = 0;
    }

    private void cellRange(Aabb a, out int x0, out int y0, out int z0,
                                   out int x1, out int y1, out int z1) const {
        immutable inv = 1.0f / cellSize;
        x0 = cast(int)((a.min.x - origin.x) * inv);
        y0 = cast(int)((a.min.y - origin.y) * inv);
        z0 = cast(int)((a.min.z - origin.z) * inv);
        x1 = cast(int)((a.max.x - origin.x) * inv);
        y1 = cast(int)((a.max.y - origin.y) * inv);
        z1 = cast(int)((a.max.z - origin.z) * inv);
        if (x0 < 0) x0 = 0; if (x0 >= DimX) x0 = cast(int)DimX - 1;
        if (y0 < 0) y0 = 0; if (y0 >= DimY) y0 = cast(int)DimY - 1;
        if (z0 < 0) z0 = 0; if (z0 >= DimZ) z0 = cast(int)DimZ - 1;
        if (x1 < 0) x1 = 0; if (x1 >= DimX) x1 = cast(int)DimX - 1;
        if (y1 < 0) y1 = 0; if (y1 >= DimY) y1 = cast(int)DimY - 1;
        if (z1 < 0) z1 = 0; if (z1 >= DimZ) z1 = cast(int)DimZ - 1;
    }

    void insert(uint bodyId, Aabb a) {
        // Skip bodies that are entirely outside the grid window. Otherwise
        // they would be clamped onto the border cells (see cellRange above),
        // which bloats those cells linearly with body count and degrades
        // perf as the simulation grows.
        immutable gx0 = origin.x;
        immutable gy0 = origin.y;
        immutable gz0 = origin.z;
        immutable gx1 = origin.x + cast(float) DimX * cellSize;
        immutable gy1 = origin.y + cast(float) DimY * cellSize;
        immutable gz1 = origin.z + cast(float) DimZ * cellSize;
        if (a.max.x < gx0 || a.min.x > gx1) return;
        if (a.max.y < gy0 || a.min.y > gy1) return;
        if (a.max.z < gz0 || a.min.z > gz1) return;

        int x0, y0, z0, x1, y1, z1;
        cellRange(a, x0, y0, z0, x1, y1, z1);
        foreach (zz; z0 .. z1 + 1)
            foreach (yy; y0 .. y1 + 1)
                foreach (xx; x0 .. x1 + 1) {
                    if (entryCount >= MaxEntries) return;
                    immutable cell = cast(uint)(xx + yy * DimX + zz * DimX * DimY);
                    immutable idx  = cast(int) entryCount;
                    entryBody[entryCount] = bodyId;
                    entryCell[entryCount] = cell;
                    nextEntry[entryCount] = cellHead[cell];
                    cellHead[cell] = idx;
                    ++entryCount;
                }
    }

    /// Returns the minimum cell index (xyz→linear) that body `bodyId` occupies
    /// given its aabb — used for dedup in `forEachPair`.
    private uint minCellOf(Aabb a) const {
        int x0, y0, z0, x1, y1, z1;
        cellRange(a, x0, y0, z0, x1, y1, z1);
        return cast(uint)(x0 + y0 * DimX + z0 * DimX * DimY);
    }

    /// Invoke `visit(i, j)` for every candidate pair (i < j) with overlapping
    /// cells. The caller is responsible for AABB + narrow-phase tests.
    void forEachPair(scope void delegate(uint, uint) @safe visit,
                     scope const(Aabb)[] aabbs) const {
        // Walk every non-empty cell; pairs are emitted only from the cell that
        // is the earliest (lowest linear index) covered by both bodies.
        foreach (cell; 0 .. CELL_COUNT) {
            int head = cellHead[cell];
            while (head != -1) {
                immutable a = entryBody[head];
                int next = nextEntry[head];
                while (next != -1) {
                    immutable b = entryBody[next];
                    if (a != b) {
                        uint lo = a, hi = b;
                        if (lo > hi) { lo = b; hi = a; }
                        immutable ownA = minCellOf(aabbs[lo]);
                        immutable ownB = minCellOf(aabbs[hi]);
                        immutable own  = ownA > ownB ? ownA : ownB;
                        if (own == cell) visit(lo, hi);
                    }
                    next = nextEntry[next];
                }
                head = nextEntry[head];
            }
        }
    }
}
