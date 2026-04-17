// Islands — disjoint-set / union-find over contact graph. Used by the
// solver to solve each connected component independently (Bullet's
// btSimulationIslandManager), and by sleeping to deactivate whole islands
// at once.
//
// Static bodies act as roots that never union (`parent[i] = i` with
// invMass[i] == 0 → skipped). We do path compression + union by rank.
module engine.physics.islands;

@safe:

struct IslandSolver(uint MaxBodies) {
@safe:
    int[MaxBodies]  parent;
    ubyte[MaxBodies] rank_;
    uint count;

    void init_(uint n)  {
        count = n;
        foreach (i; 0 .. n) { parent[i] = cast(int) i; rank_[i] = 0; }
    }

    int find(int i)  {
        while (parent[i] != i) {
            parent[i] = parent[parent[i]];  // path halving
            i = parent[i];
        }
        return i;
    }

    void union_(int a, int b)  {
        immutable ra = find(a);
        immutable rb = find(b);
        if (ra == rb) return;
        if (rank_[ra] < rank_[rb])      parent[ra] = rb;
        else if (rank_[ra] > rank_[rb]) parent[rb] = ra;
        else { parent[rb] = ra; rank_[ra]++; }
    }
}
