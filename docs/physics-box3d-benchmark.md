# Box3D Physics Benchmark

This documents the benchmark run used to validate the gameplay physics migration from the native D JPH port to Box3D.

## Scenario

- Config: `benchmark`
- Compiler: `ldc2`
- Build: `release`
- Workload: 800 dynamic cubes, 1 static floor, visual rendering enabled
- Duration: 12 seconds
- Command:

```bash
dub run --compiler=ldc2 --config=benchmark --build=release --force
```

The JPH baseline was measured from the pre-migration `HEAD` in a temporary worktree. The Box3D result was measured from the migrated tree.

## Results

| Physics backend | Avg FPS | Max GC pause | GC collections | Total GC pause |
|---|---:|---:|---:|---:|
| JPH D port | 799.3 | 1.8 ms | 199 | 40.1 ms |
| Box3D | 3514.1 | 0.8 ms | 826 | 120.5 ms |

Box3D is approximately **4.4x faster** in the LDC2 release benchmark.

## Notes

- The DMD release comparison was much larger because DMD optimized the old D JPH port poorly. LDC2 is the relevant release compiler and gives the fairer production comparison.
- Box3D showed more GC collections and higher total GC pause in this benchmark, but a lower worst pause. The extra collection count is likely benchmark/render-loop allocation pressure, not physics core allocation.
- Stability was good in the Box3D run: `peak_below_floor=0`.
- The old JPH benchmark reported `peak_pairs=1019` and `peak_manifolds=837`; the migrated Box3D benchmark currently reports stability counters instead of pair/manifold internals.

## Current Interpretation

The migration gives a strong release-mode throughput win while also providing missing gameplay features such as sensors, raycasts, CCD, joints, meshes, and the production C API surface. The next benchmark work should focus on reducing render/HUD allocation churn so GC totals reflect physics behavior more cleanly.
