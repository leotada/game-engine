# Port Plan: meshoptimizer → pure D (`engine.meshopt.*`)

> **Status:** M0 landed (decisions D1–D4 in §12, M0 corrections in §2.1) · **Upstream:** [zeux/meshoptimizer](https://github.com/zeux/meshoptimizer) **v1.3** commit `9e1f07b159d3cb777f1c67ed31fc11fd117986f4` (`MESHOPTIMIZER_VERSION 1030`, released 2026-09-25) · **License:** MIT (© 2016-2026 Arseny Kapoulkine), text in [third-party-licenses.md](third-party-licenses.md)
>
> Related: [graphics.md](graphics.md) · [plan-pbr.md](plan-pbr.md) · [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) · [jph-port-plan.md](jph-port-plan.md) (lessons learned) · [roadmap.md](roadmap.md)

This document is the plan for rewriting meshoptimizer, a C++ mesh-processing library, as a native D package inside the engine. It does not bind to the C++ library. The port is incremental, with one commit per phase. Each phase has a validation gate against the upstream library, and each delivered module is wired into the engine's asset pipeline as soon as it is ready. A module is not left unused until the end of the project.

---

## 1. Goals and Non-Goals

### 1.1 Why port meshoptimizer

meshoptimizer is the industry-standard toolkit for preparing triangle meshes for the GPU. The engine currently has none of its capabilities:

| Gap in the engine today | What meshoptimizer brings |
|:---|:---|
| Imported glTF meshes are uploaded as-is (`engine/assets/gltf.d` → `TexMesh.fromData`), with no reindexing or reordering | Vertex deduplication, vertex-cache / overdraw / vertex-fetch optimization (typically 10–40% faster vertex processing) |
| No LOD system; every object renders at full detail | Quadric-error simplifier with attribute awareness, locked borders, error metrics for screen-space LOD selection |
| Shadow pass (`engine/gpu/shadow.d`) draws the full-attribute mesh | Position-only shadow index buffers (fewer unique vertices in depth passes) |
| `gltf.d` stores `ushort[]` indices and rejects any index above 65535. It never reads `extensions`, so `EXT_meshopt_compression` bufferViews are misread as raw floats or indices | Index/vertex codecs + filters (the exact format behind `EXT_meshopt_compression` produced by `gltfpack`). M7 decodes a compressed bufferView before any accessor read |
| PBR normal mapping needs tangents; glTF files often ship without them | MikkTSpace-compatible tangent generation (`generateTangents`) |
| Collision meshes for Box3D (`AssetCollision`) are raw render meshes | Sloppy/prune simplification to build cheap collision proxies |
| No cluster-based rendering path | Meshlet building, cluster bounds/cones, cluster partitioning (foundation for GPU-driven culling and Nanite-style cluster LOD) |

### 1.2 Why a native D port instead of a C/C++ binding

- **Single-language toolchain**: no C++ compiler is required to build the engine (DUB only, per `AGENTS.md`). meshoptimizer is C++ (templates, `operator new`), so ImportC cannot consume it, and a binding would force a C++ build step onto every platform target (Linux, Windows, Android, macOS, iOS).
- **Safety model**: the decoders process untrusted input (downloaded or modded assets). A `@safe` D implementation with bounds-checked API entry points fits the engine's `@safe:` / DIP1000 rules.
- **GC-safe integration**: scratch memory, output buffers and statistics can use the engine's own primitives (`Pod!T`, `FrameArena`, a dedicated scratch allocator) instead of global `meshopt_setAllocator` callbacks.
- **CTFE**: several upstream lookup tables are built at startup or written out by hand, for example the vertex-codec shuffle tables and the vertex-cache score tables. In D they become `static immutable` values computed at compile time.
- **The library ports well**: the v1.3 `src/*.cpp` tree is 15665 lines of mostly scalar, self-contained algorithmic C++ (plus a 1724-line header) with no external dependencies. It has no virtual dispatch and no exceptions, and it already uses explicit temporary allocation.

### 1.3 Non-goals

- **No API/ABI compatibility with the C header.** The D API is idiomatic: slices, templates on the index type, and `enum` flag sets. A thin C-shaped compatibility layer can be added later if it is ever needed.
- **Not ported in the first pass (deferred, see §9):**
  - Opacity micromaps (`opacitymap.cpp`): WebGPU has no ray-tracing pipeline.
  - The experimental voxel remesher (`remesher.cpp`).
  - `meshopt_setAllocatorCache`.
- **No `EXT_meshopt_compression` encoder CLI** (a `gltfpack` equivalent). The engine needs the decoders at runtime and the encoders inside its own asset pipeline. A full glTF repacker is out of scope.

### 1.4 Lessons from the cancelled Jolt port

The native port of JoltPhysics was abandoned because it ran about 4× slower than the C++ original with LDC release builds and about 30× slower with DMD (see [physics-box3d-benchmark.md](physics-box3d-benchmark.md)). The plan guards against repeating that outcome in three ways:

1. **Performance is a phase gate, not a final check.** Every phase is benchmarked against the C++ reference on the same inputs (§7.3). The gates are tiered (D2): strict for the load-time decoders and relaxed for offline, import-time functions, where the user never waits on a frame.
2. **Go/No-Go checkpoint after M2** (§5). Before starting the simplifier, which is the largest and most expensive module, the project confirms that the cheap modules reach parity.
3. **Output-equivalence testing against the reference.** The deterministic algorithms are checked byte for byte against a reference build of the C++ library. This build is a test oracle only and is never linked into the engine (§7.1).

meshoptimizer is a far better candidate than Jolt. It has no simulation state, no threading, no class hierarchy and no hot-path virtual calls, and most of it runs offline at import time, where a 1.2× slowdown is irrelevant. Only the **decoders** are on a load-time critical path.

---

## 2. Upstream Inventory (v1.3)

Source of truth: `ref/meshoptimizer/` (a gitignored clone, pinned to tag `v1.3`, commit `9e1f07b`). Do not revive a Jolt tree under `ref/`.

```bash
git clone --branch v1.3 --depth 1 https://github.com/zeux/meshoptimizer ref/meshoptimizer
# HEAD is 9e1f07b159d3cb777f1c67ed31fc11fd117986f4
```

Line counts below are `wc -l` on that commit. `allocator.cpp` is 21 lines because `meshopt_Allocator` lives in the header; only `meshopt_setAllocator` is in the `.cpp`.

| Upstream file | Lines | Public API covered | D module | Phase | Runtime-critical? |
|:---|---:|:---|:---|:---:|:---:|
| `allocator.cpp` | 21 | `setAllocator`, `setAllocatorCache` | `meshopt.scratch` | M0 | — |
| `quantization.cpp` | 127 | `quantizeHalf/Float`, `dequantizeHalf`, `computePositionExponent` (+ inline `quantizeUnorm/Snorm` from header) | `meshopt.quantize` | M0 | yes (helpers) |
| `indexgenerator.cpp` | 825 | `generateVertexRemap{,Multi,Custom}`, `remapVertexBuffer`, `remapIndexBuffer`, `filterIndexBuffer{,Multi}`, `generateShadowIndexBuffer{,Multi}`, `generatePositionRemap`, `generateAdjacencyIndexBuffer`, `generateTessellationIndexBuffer`, `generateProvokingIndexBuffer` | `meshopt.indexgen` | M1 | no |
| `vcacheoptimizer.cpp` | 467 | `optimizeVertexCache{,Strip,Fifo}` | `meshopt.vcache` | M2 | no |
| `overdrawoptimizer.cpp` | 333 | `optimizeOverdraw` | `meshopt.overdraw` | M2 | no |
| `vfetchoptimizer.cpp` | 71 | `optimizeVertexFetch{,Remap}` | `meshopt.vfetch` | M2 | no |
| `indexanalyzer.cpp` | 125 | `analyzeVertexCache`, `analyzeVertexFetch` | `meshopt.analyze` | M2 | no |
| `rasterizer.cpp` | 289 | `analyzeOverdraw`, `analyzeCoverage` | `meshopt.analyze` | M2 | no |
| `stripifier.cpp` | 296 | `stripify{,Bound}`, `unstripify{,Bound}` | `meshopt.stripify` | M2 | no |
| `simplifier.cpp` | 2947 | `simplify`, `simplifyWithAttributes`, `simplifyWithUpdate`, `simplifySloppy`, `simplifyPrune`, `simplifyPoints`, `simplifyScale` | `meshopt.simplify.*` | M4 | no |
| `indexcodec.cpp` | 703 | `encode/decodeIndexBuffer`, `encode/decodeIndexSequence`, `*Version`, `*Bound` | `meshopt.codec.index` | M6 | **decode: yes** |
| `vertexcodec.cpp` | 1880 | `encode/decodeVertexBuffer`, `encodeVertexBufferLevel`, `*Version`, `*Bound` (scalar + SSSE3/AVX-512/NEON/WASM decoders) | `meshopt.codec.vertex` | M6 | **decode: yes** |
| `vertexfilter.cpp` | 1503 | `encode/decodeFilter{Oct,Quat,Exp,Color}` (scalar + SSE/NEON/WASM) | `meshopt.codec.filter` | M6 | **decode: yes** |
| `meshletcodec.cpp` | 1051 | `encodeMeshlet{,Bound}`, `decodeMeshlet{,Raw}` (scalar + SSE4.1/NEON) | `meshopt.codec.meshlet` | M9 | decode: yes |
| `tangentspace.cpp` | 730 | `generateTangents`, `generateNormals` (experimental) | `meshopt.tangent` | M8 | no |
| `clusterizer.cpp` | 1377 | `buildMeshlets{,Scan,Bound,Flex,Spatial}`, `computeClusterBounds`, `computeMeshletBounds`, `computeSphereBounds` | `meshopt.cluster` | M9 | no |
| `meshletutils.cpp` | 619 | `optimizeMeshlet{,Level}`, `extractMeshletIndices` | `meshopt.meshlet` | M9 | no |
| `partition.cpp` | 621 | `partitionClusters` | `meshopt.partition` | M9 | no |
| `spatialorder.cpp` | 341 | `spatialSortRemap`, `spatialSortTriangles`, `spatialClusterPoints` | `meshopt.spatial` | M9 | no |
| `opacitymap.cpp` | 557 | `opacityMap{Measure,Rasterize,EntrySize,Compact}` | — | deferred | — |
| `remesher.cpp` | 782 | `remesh` (experimental) | — | deferred | — |
| `meshoptimizer.h` | 1724 | Types, enums, inline helpers, C++ template wrappers (`meshopt_IndexAdapter`) | `meshopt.types` + templates | M0 | — |
| **Total** | **17389** | | | | |

### 2.1 Corrections locked at M0

These override any older sentence in this document.

- **Pin.** Tag `v1.3`, commit `9e1f07b159d3cb777f1c67ed31fc11fd117986f4`, `MESHOPTIMIZER_VERSION 1030`. The header is 1724 lines (`wc -l`). Pre-clone estimates (header 1735 or 1725, and the `.cpp` counts replaced above) are not used.
- **Strides.** v1.3 allows vertex strides that are not multiples of 4. `FloatStream` stays a multiple of 4 (`strideFloats`, byte stride = `strideFloats * 4`). Raw `VertexStream.stride` must not be forced to a multiple of 4. `filterIndexBuffer` and `generateShadowIndexBuffer` take both `vertexSize` and `vertexStride`, with `stride >= size`.
- **Views are POD.** `VertexStream` and `FloatStream` store the buffer address as `ulong`, not a slice or pointer, so `isPod` holds. The caller keeps the buffer alive for the call. A slice would be a GC-traced indirection.
- **Codec versions.** Do not port the process-global `meshopt_encodeIndexVersion` / `meshopt_encodeVertexVersion` setters. They are not thread-safe upstream, and an editor import thread can run while a load decodes. Pass the version as an argument. Decoders still accept both on-disk versions (v0 and v1).
- **Half floats.** `engine.animation.math.half` is the ozz binary16 decoder (it preserves denormals). It must not be reused for meshopt `quantizeHalf` / `dequantizeHalf`, which flush denormals to zero and canonicalize NaNs. The quantizer is a separate port of `quantization.cpp`.
- **glTF compression.** `source/engine/assets/gltf.d` does not explicitly reject `EXT_meshopt_compression`. It never reads `extensions`, so a compressed `bufferView` is misread as raw floats or indices. M7 must decode before accessor reads (`readFloatVec`, `readIndices`). Integration belongs in `source/engine/assets/gltf.d` only. `engine.animation.gltf_skin` only reads joints and weights and is out of scope.
- **Index format today.** `createIndexBuffer` (`engine/gpu/buffer.d`) is already generic. These draw sites hardcode `WGPUIndexFormat.uint16` and `indexCount * ushort.sizeof`: `source/engine/scene/scene3d.d`, `source/engine/scene/scene3d_textured.d`, and both draws in `source/engine/gpu/shadow.d` (`submitShadowPass`, `submitPointShadowFace`). `source/engine/gpu/skinned.d` already uses `uint32` and is outside this static-mesh path. M3 switches the three uint16 sites to the mesh's index format.
- **M8 shadow stride.** When a mesh is `TexTanVert` (48 bytes), the shadow vertex layout stride is updated to 48 even though the depth shader does not read the tangent. Skinned `float[3]` tangents in `SkinningJob` (`engine/animation/skinning.d`) and `assets/shaders/skinned.wgsl` stay as they are. M8 is the static PBR path.
- **M5 collision.** M5 adds a generated collision payload (baked triangle mesh and/or decimated hull input). It does not overload `AssetTriangleMesh.source` (that field stays a path: `"render"` or another glTF).
- **Corpus.** `assets/models/meshopt/pirate.obj` is upstream `demo/pirate.obj` (CC-BY-SA 3.0, Clint Bellanger; see [third-party-licenses.md](third-party-licenses.md)). Procedural grid, sphere, torus, UV-seam, and non-manifold soup meshes are generated in tests (`engine.meshopt.corpus`). A scanned mesh is optional and only if its license is compatible and the corpus stays ≤ 10 MB. M0 does not commit one.
- **License.** Upstream MIT text is in `docs/third-party-licenses.md`, added before any ported function. Each ported module carries the v1.3 header comment. `public import engine.meshopt` is added to `source/engine/package.d` at M3, not before.

Reference material used for tests:

- `demo/tests.cpp` (≈3.7k lines of regression tests, ported in each phase)
- `demo/clusterlod.h` and `demo/nanite.cpp` (the reference for cluster-LOD integration in M10)
- `tools/codecfuzz.cpp`, `tools/simplifyfuzz.cpp` and `tools/clusterfuzz.cpp` (fuzz harnesses, ported in §7.4)
- `tools/codectest.cpp` and `tools/codecbench.cpp` (codec benchmarks)
- `demo/pirate.obj` / `demo/pirate.glb` (the standard test mesh)

---

## 3. Package Layout

```
source/engine/meshopt/
├── package.d              # public import of the stable API (no internal/)
├── types.d                # Meshlet, Bounds, *Statistics, option enums, VertexStream
├── scratch.d              # MeshoptScratch: stack-ordered bump allocator (malloc-backed, @nogc)
├── quantize.d             # quantizeUnorm/Snorm/Half/Float, dequantizeHalf, computePositionExponent
├── indexgen.d             # remap / reindex / shadow / adjacency / tessellation / provoking
├── vcache.d               # Forsyth-style vertex cache optimizer + strip + FIFO (Tipsify)
├── overdraw.d             # Overdraw optimizer (cluster sort by view-independent occlusion)
├── vfetch.d               # Vertex fetch optimizer
├── analyze.d              # analyzeVertexCache/Fetch/Overdraw/Coverage (+ software rasterizer)
├── stripify.d             # stripify / unstripify
├── simplify/
│   ├── package.d          # simplify, simplifyWithAttributes, simplifyWithUpdate, simplifyScale
│   ├── topology.d         # edge adjacency, vertex kinds (Manifold/Border/Seam/Complex/Locked)
│   ├── quadric.d          # Quadric / QuadricGrad / volume gradients, attribute quadrics
│   ├── collapse.d         # collapse candidates, ranking, edge-collapse application, remap
│   ├── sloppy.d           # simplifySloppy (grid-based clustering)
│   ├── prune.d            # simplifyPrune + Prune option (component removal)
│   └── points.d           # simplifyPoints
├── cluster.d              # buildMeshlets*, computeClusterBounds/MeshletBounds/SphereBounds
├── meshlet.d              # optimizeMeshlet{,Level}, extractMeshletIndices
├── partition.d            # partitionClusters
├── spatial.d              # spatialSortRemap/Triangles, spatialClusterPoints (Morton order)
├── tangent.d              # generateTangents, generateNormals
├── codec/
│   ├── index.d            # index buffer + index sequence codecs (v0/v1)
│   ├── vertex.d           # vertex codec (v0/v1, levels), scalar decode
│   ├── vertex_simd.d      # version(LDC) x86 SSSE3/AVX-512 + AArch64 NEON decode kernels
│   ├── filter.d           # oct/quat/exp/color filters (scalar)
│   ├── filter_simd.d      # SIMD filter kernels
│   └── meshlet.d          # meshlet codec (+ SIMD kernels)
├── internal/
│   ├── hash.d             # open-addressing hash table with quadratic probing (meshopt's hashLookup)
│   ├── sort.d             # radix sorts + upstream's exact insertion/heap orders
│   ├── bits.d             # floatBits/bitsFloat, zigzag, varint, popcount, rotl
│   └── vec.d              # tiny float3 helpers (no dependency on engine.math types in kernels)
└── pipeline.d             # High-level engine API: MeshOptSettings, optimizeMesh, buildLodChain, …
```

Module naming follows `AGENTS.md` (`module engine.meshopt.simplify.quadric;`). Every module starts with `@safe:`. `engine/package.d` gains `public import engine.meshopt;` only once M3 lands.

---

## 4. Translation Rules (C++ → D)

These rules apply to every phase. Each one is checked in code review.

### 4.1 Types and naming

| C++ | D |
|:---|:---|
| `unsigned int`, `unsigned short`, `unsigned char`, `signed char` | `uint`, `ushort`, `ubyte`, `byte` |
| `size_t` | `size_t` |
| `float v[3]` in structs | `float[3]` |
| `meshopt_Meshlet`, `meshopt_Bounds`, `meshopt_*Statistics` | `Meshlet`, `Bounds`, `VertexCacheStatistics`, … (field names in camelCase: `vertexOffset`, `coneAxisS8`) |
| Anonymous `enum { meshopt_SimplifyLockBorder = 1 << 0, … }` | `enum SimplifyOptions : uint { none = 0, lockBorder = 1 << 0, … }` (bit values identical to upstream for golden-file compatibility) |
| `meshopt_SimplifyVertex_*` | `enum SimplifyVertexFlags : ubyte { lock = 1, protect = 2, priority = 4 }` |
| `meshopt_EncodeExpMode` | `enum EncodeExpMode { separate, sharedVector, sharedComponent, clamped }` |
| `meshopt_Stream` | `struct VertexStream { ulong address; size_t size; size_t stride; }` — `stride` is bytes between elements, `stride >= size`, and it is **not** required to be a multiple of 4. `address` is the first byte (0 = null) so the struct stays `isPod`. |
| `meshopt_` function prefix | none. The functions live in the `engine.meshopt` namespace (`engine.meshopt.simplify(...)`). |

All public structs must pass `isPod!T` and are declared with `Pod!T` wherever they are stored in engine memory.

### 4.2 Pointers → slices

Every `T* destination, size_t count` pair becomes a slice. Strided float inputs, described in C as `const float* vertex_positions, size_t vertex_count, size_t stride_bytes`, become:

```d
/// Strided view over float3 attributes. The byte stride is strideFloats * 4,
/// so a FloatStream is always a multiple of 4. Raw VertexStream.stride is not.
struct FloatStream {
    ulong address;         // first float of element 0; 0 = null. POD (no slice).
    size_t strideFloats;   // = strideBytes / 4
    size_t count;

    float[3] get3(size_t i) const pure nothrow @nogc { … }
}

FloatStream positionsOf(T, string field = "pos")(const(T)[] verts) @trusted; // offsetof-based view, the only @trusted cast
```

The engine vertex types (`Vert`, `TexVert`, future skinned vertices) get zero-copy `FloatStream` views through a single audited `@trusted` helper that uses `offsetof`. `T.sizeof` must be a multiple of 4. This view is not used for a raw `VertexStream` whose stride is not a multiple of 4.

### 4.3 Index type templating

Upstream C++ wrappers (`meshopt_IndexAdapter<T>`) convert 16-bit indices to 32 bits through a temporary copy. The D port is templated end-to-end instead:

```d
size_t simplify(I)(I[] destination, const(I)[] indices, FloatStream positions,
                   size_t targetIndexCount, float targetError,
                   SimplifyOptions options = SimplifyOptions.none,
                   float* resultError = null,           // or `out float`, see §4.6
                   ref MeshoptScratch scratch = defaultScratch())
    if (is(I == uint) || is(I == ushort));
```

`ushort` remains first-class because the engine's current meshes use 16-bit indices (`Mesh.fromData(..., const(ushort)[])`). Where the algorithm itself needs 32-bit indices internally (for example, simplifier remaps), the template converts once into scratch memory. This mirrors upstream behavior and allocation order, so outputs stay comparable.

### 4.4 Memory: `MeshoptScratch`

Upstream allocates only temporaries, in strict stack order, through `meshopt_Allocator` (up to 24 blocks per call, freed in the destructor). The D replacement:

```d
struct MeshoptScratch {
    @disable this(this);
    T[] allocate(T)(size_t n) @trusted nothrow @nogc if (isPod!T);  // bump; grows by chained malloc blocks
    size_t mark() const pure nothrow @nogc;
    void release(size_t mark) nothrow @nogc;                         // pops back to mark
    ~this();                                                          // frees all blocks
}

ref MeshoptScratch defaultScratch() @trusted nothrow @nogc;  // thread-local instance
```

- Every public function opens a scope with `immutable m = scratch.mark(); scope(exit) scratch.release(m);`.
- All memory is malloc-backed and untraced by the GC, so `MeshoptScratch` never adds GC roots. That matches the steadygc/`Pod!T` policy.
- Blocks are retained after `release`. A long import job therefore reaches a steady state with zero `malloc` calls, which covers the behavior of `setAllocatorCache` for free.
- Uninitialized memory is allowed (`allocate` does not zero). Upstream relies on explicit `memset`, and the port keeps those `memset`s as `[] = 0` at the same points.

### 4.5 Attributes

| Layer | Attributes |
|:---|:---|
| All algorithm functions (`engine.meshopt.*` except `pipeline.d`) | `@safe nothrow @nogc` (+ `pure` where no thread-local scratch is touched) |
| Decoders (`codec/*`) | `@safe nothrow @nogc`, and they return an error code (`int`, 0 = success, matching upstream values) instead of throwing |
| SIMD kernels / inner loops that need raw pointers | `@trusted` private functions that take already-validated slices, documented with a `/// Invariants:` comment block |
| `pipeline.d` (engine convenience layer) | `@safe`. It may use the GC because it runs at import or load time and never in the frame loop. |

`@system` is not used anywhere.

### 4.6 Semantics that differ between C++ and D

| Topic | Rule |
|:---|:---|
| Implicit narrowing | D rejects `ubyte x = a + b;`, so add explicit `cast(ubyte)` exactly where C++ truncates. Never "fix" a truncation that upstream relies on. |
| Integer promotion | Same as C (`ubyte + ubyte → int`). Shifts of `int` by ≥ 32 are invalid in D as in C, so review every variable shift in the codecs. |
| Signed overflow | Defined (wrapping) in D and UB in C++. Upstream avoids it, so there is no behavior change. |
| Type punning (`memcpy(&u, &f, 4)`) | Use `internal.bits.floatBits(float) → uint` and `bitsFloat(uint) → float`, which are `pure @trusted` and union-based. |
| Unaligned loads in codecs | Read through `ubyte[]` + `littleEndianToNative` or explicit shifts in the scalar path. SIMD paths use `loadUnaligned`. |
| `float` math functions | Use `core.math.sqrt` / `core.stdc.math.{sqrtf,fabsf,logf,powf,floorf,ldexpf,frexpf}`. **Never use `std.math` functions that compute in `real`**, because DMD on x86 may use 80-bit x87 and break bit-exactness. |
| FP contraction | The reference oracle builds with `-ffp-contract=off`. LDC builds of the port are verified with `--fp-contract=off` for golden tests, and production LDC builds may enable contraction (results then need only be equivalent within tolerance, see §7.1). DMD never contracts. |
| Sorting | **Port upstream's own sort routines exactly** (radix sorts, insertion sorts, heap). Never substitute `std.algorithm.sort`: it is unstable and orders equal keys differently, which changes outputs. |
| Static tables | Upstream code that builds tables at runtime (for example, `decodeBytesGroupBuildTables`) becomes `static immutable … = buildTables();` and is computed through CTFE. |
| `assert` | Keep every upstream `assert` as a D `assert`. Add `in` contracts on public functions for size requirements (`destination.length >= …`). |
| Bounds checks | `@safe` code keeps bounds checks in `-release` (`-boundscheck=safeonly`). Hot kernels that measurably suffer move to `@trusted` pointer loops **only after** a benchmark shows the difference (§7.3). |

---

## 5. Phases

One phase equals one commit (or a short commit series for M4 and M6). Every phase must end with:

- `dub test --config=library` green on **DMD** and **LDC**
- `dub run --config=lint` clean
- golden tests for the phase's modules green (§7.1)
- the benchmark table in §7.3 updated for the phase's modules
- the phase's status row in this document updated

### Phase overview

| # | Phase | Upstream source | Est. D LOC | Depends on | Status |
|:---|:---|:---|---:|:---|:---|
| M0 | Infrastructure: package skeleton, scratch, bits/hash/sort, quantize, oracle + golden harness, bench harness | `allocator`, `quantization`, header | ~900 | — | ✅ Done |
| M1 | Indexing & reindexing | `indexgenerator` | ~800 | M0 | ⏳ Pending |
| M2 | Pipeline optimizers + analyzers + stripifier | `vcache`, `overdraw`, `vfetch`, `indexanalyzer`, `rasterizer`, `stripifier` | ~1300 | M1 | ⏳ Pending |
| **G1** | **Go/No-Go checkpoint**: performance and equivalence review | — | — | M2 | ⏳ Pending |
| M3 | Engine integration I: import-time optimization pipeline, 32-bit indices, stats in editor | — | ~700 | G1 | ⏳ Pending |
| M8 | Tangent & normal generation + PBR integration (real tangents replace the shader's fixed-axis approximation) | `tangentspace` | ~650 | M3 | ⏳ Pending |
| M4a | Simplifier core: topology, quadrics, collapse loop, `simplify` | `simplifier` (≈55%) | ~1600 | M3 | ⏳ Pending |
| M4b | Simplifier attributes & options: `WithAttributes`, `WithUpdate`, vertex locks, Permissive, Regularize(Light), PreserveFolds, ErrorClamped, Prune option | `simplifier` (≈30%) | ~900 | M4a | ⏳ Pending |
| M4c | `simplifySloppy`, `simplifyPrune`, `simplifyPoints`, `simplifyScale` | `simplifier` (≈15%) | ~500 | M4a | ⏳ Pending |
| M5 | Engine integration II: LOD chains, `MeshLod` component, shadow LOD, collision proxies | — | ~900 | M4b/c | ⏳ Pending |
| M6a | Codecs (scalar): index + vertex + filters | `indexcodec`, `vertexcodec`, `vertexfilter` (scalar paths) | ~1900 | M0 | ⏳ Pending |
| M6b | Codec SIMD decode: SSSE3 / AVX-512 / NEON (LDC) | SIMD paths | ~1000 | M6a | ⏳ Pending |
| M7 | Engine integration III: `EXT_meshopt_compression` + `KHR_mesh_quantization` in glTF loader, compressed `.asset` mesh payloads | — | ~800 | M6a | ⏳ Pending |
| M9 | Clusters: meshlets, bounds, meshlet optimizer/codec, spatial order, partitioning | `clusterizer`, `meshletutils`, `meshletcodec`, `spatialorder`, `partition` | ~3200 | M2 | ⏳ Pending |
| M10 | Research: GPU cluster culling + cluster LOD (Nanite-style) prototype | `demo/clusterlod.h`, `demo/nanite.cpp` | ~1500 | M9, M4b | 🔬 Optional |

The delivery order is the table order (D1): import optimization (M0–M3), then **tangents (M8)**, then **LODs (M4/M5)**, then **compression (M6/M7)**, then clusters (M9/M10). Tangents come first because they are small and independent, and because they fix a visible bug: `assets/shaders/textured3d_pbr.wgsl:60-65` derives the tangent frame by Gram-Schmidt from a fixed model-space X axis, so normal maps are oriented incorrectly on most meshes. Phase IDs are kept stable; only the order changed. M6 depends only on M0, so it can run in parallel with M4/M5 if two people are working on the port.

---

### M0 — Infrastructure

**Deliverables**

1. `ref/meshoptimizer` cloned at `v1.3`. Record the upstream commit hash in this document (§11).
2. Package skeleton `source/engine/meshopt/` (§3), with `types.d` containing all public structs and enums.
3. `scratch.d` (§4.4) with unit tests for mark/release ordering, block growth, steady state with no reallocation, and `isPod` enforcement.
4. `internal/bits.d`, `internal/hash.d` (generic `hashLookup!(Hasher)` matching upstream's quadratic probing and `hashBuckets` sizing), `internal/sort.d`, and `internal/vec.d`.
5. `quantize.d`, a full port of `quantization.cpp` plus the header inline helpers `quantizeUnorm`, `quantizeSnorm`, `quantizeHalf`, `quantizeFloat`, `dequantizeHalf` and `computePositionExponent`. These are `pure nothrow @nogc` and CTFE-able. Do not call `engine.animation.math.half` (that module is the ozz binary16 decoder and preserves denormals).
6. **Oracle and golden-data tooling** (§7.1): `tools/meshopt-oracle/build_ref.sh` builds `libs/libmeshoptimizer_ref.a` from `ref/meshoptimizer/src` with `clang++ -O2 -ffp-contract=off`, and a `dub` configuration `meshopt-oracle` holds the minimal `extern(C)` declarations used **only by the oracle tool** (it is never part of `library`).
7. Benchmark harness `tools/benchmarks/meshopt_bench.d` (dub config `meshopt-bench`). It runs each ported function and its C++ counterpart (when the oracle library is present) on the test corpus and prints a markdown table.
8. Test corpus under `assets/models/meshopt/` (≤ 10 MB total, Git LFS not required):
   - `pirate.obj` from upstream `demo/pirate.obj` (CC-BY-SA 3.0)
   - a procedural grid, sphere and torus generated in-test
   - a mesh with UV seams and hard edges (generated in-test)
   - a non-manifold "soup" mesh (generated in-test)
   - a high-poly scan is optional, and only if the license is compatible and the corpus stays ≤ 10 MB. M0 does not commit one.

**Exit criteria**: quantization is bit-exact versus the oracle for all 2³² `quantizeHalf` inputs (an exhaustive test, behind `version(MeshoptExhaustive)`), and the scratch allocator passes `--assert-no-gc`.

---

### M1 — Indexing & Reindexing

Port `indexgenerator.cpp` in full.

| Function | Notes |
|:---|:---|
| `generateVertexRemap(I)(uint[] remap, const(I)[] indices, const(ubyte)[] vertices, size_t vertexSize)` | Binary-equivalence hashing (MurmurHash2-style `VertexHasher`). An `indices.length == 0` input is the unindexed case. Typed overload `generateVertexRemap!(V)(…, const(V)[] vertices)` for engine vertex structs. |
| `generateVertexRemapMulti` | Takes `const(VertexStream)[]`. |
| `generateVertexRemapCustom` | Upstream takes a C callback. D takes a **template alias predicate** (`alias equal`), so the compiler inlines the comparison. That is the compile-time dispatch rule from `AGENTS.md`. |
| `remapVertexBuffer` / `remapIndexBuffer` | Typed generic versions plus a raw `ubyte[]` + `vertexSize` version. |
| `filterIndexBuffer{,Multi}` | Removes degenerate triangles. The single-stream form takes both `vertexSize` and `vertexStride` (`stride >= size`). Stride is not required to be a multiple of 4. |
| `generateShadowIndexBuffer{,Multi}` | Used by the shadow pass in M3. The single-stream form takes both `vertexSize` and `vertexStride` (`stride >= size`). |
| `generatePositionRemap` | |
| `generateAdjacencyIndexBuffer`, `generateTessellationIndexBuffer` | Ported for completeness. WebGPU has no geometry/tessellation stages, but the outputs are useful for silhouette/outline compute passes. |
| `generateProvokingIndexBuffer` | |

**Tests**: port the corresponding blocks of `demo/tests.cpp`. Golden comparisons are **byte-exact** for every function in this phase.

---

### M2 — Pipeline Optimizers, Analyzers, Stripifier

| Module | Port details |
|:---|:---|
| `vcache.d` | Forsyth/Tom-Forsyth-style score-based optimizer with upstream's tuned `VertexScoreTable` (CTFE `static immutable`). Strip variant (`optimizeVertexCacheStrip`) and Tipsify FIFO variant (`optimizeVertexCacheFifo`). |
| `overdraw.d` | Cluster generation from the vcache result plus a view-independent sort by cluster centroid and normal (`threshold` parameter, 1.05 by default). |
| `vfetch.d` | `optimizeVertexFetch` (reorders the vertex buffer) and `optimizeVertexFetchRemap`. |
| `analyze.d` | `analyzeVertexCache` (FIFO simulation with `cacheSize`, `warpSize`, `primGroupSize`), `analyzeVertexFetch`, and `analyzeOverdraw` / `analyzeCoverage` using upstream's 256×256 software rasterizer (port `rasterizer.cpp` verbatim, including its fixed-point edge functions). |
| `stripify.d` | `stripify`, `stripifyBound`, `unstripify`, `unstripifyBound` with `restartIndex` semantics. |

**Tests**: byte-exact goldens for all functions; the statistics structs (ACMR, ATVR, overfetch, overdraw) must match exactly.

### G1 — Go/No-Go Checkpoint

The checkpoint happens before the most expensive work (M4, about 3k lines of upstream code). Collect the following:

| Metric | Target | Action if missed |
|:---|:---|:---|
| LDC `-O3 -release` vs clang `-O2` (geomean over the M1+M2 functions on the corpus) | ≤ 1.5× | > 2.0×: profiling pass before M4 starts |
| DMD `-O -release` vs clang | ≤ 3× (informational) | — |
| Golden equivalence | 100% byte-exact | any unexplained mismatch blocks M3 |
| `@trusted` lines added | ≤ 2% of module LOC | — |

The outcome is recorded in §11. Under D2, M1/M2 are import-time functions, so G1 is a **tuning checkpoint and does not decide whether the port continues**. The port stays pure D in every outcome, and binding the C++ library is not an option. A gap above 2× triggers a focused profiling pass (bounds checks, `real` promotion and missed inlining are the usual causes) before the simplifier work begins, because the same patterns would carry over into M4.

---

### M3 — Engine Integration I: Import-Time Optimization

This phase makes the M1/M2 work immediately visible in every demo and in the editor.

1. **`engine/meshopt/pipeline.d`**:
   ```d
   struct MeshOptSettings {
       bool  reindex         = true;   // generateVertexRemap + remap*
       bool  vertexCache     = true;   // optimizeVertexCache
       float overdrawThreshold = 1.05f; // 0 disables optimizeOverdraw
       bool  vertexFetch     = true;   // optimizeVertexFetch
       bool  shadowIndices   = true;   // generateShadowIndexBuffer (positions only)
   }

   struct OptimizedMesh(V, I) {
       V[] vertices;
       I[] indices;
       I[] shadowIndices;           // empty when disabled
       MeshStats before, after;     // ACMR/ATVR/overfetch/overdraw
   }

   OptimizedMesh!(V, I) optimizeMesh(V, I)(const(V)[] verts, const(I)[] indices,
                                          const MeshOptSettings s = MeshOptSettings.init);
   ```
   This layer may use the GC (it is import-time, not frame-path).
2. **glTF loader** (`source/engine/assets/gltf.d` only — not `engine.animation.gltf_skin`):
   - accept `u32` indices instead of rejecting values above 65535. `GltfMesh.indices` becomes `uint[]`, and the loader narrows to `ushort` only when `vertices.length <= 65536`.
   - run `optimizeMesh` after loading, controlled by a setting in the asset's `.meta` sidecar (`AssetDatabase`).
3. **GPU side**: `Mesh` / `TexMesh` accept `uint` index buffers (`WGPUIndexFormat.uint32`) in addition to `ushort`. `createIndexBuffer` is already generic. Switch the draw sites that hardcode `WGPUIndexFormat.uint16` — `scene3d.d`, `scene3d_textured.d`, and both draws in `shadow.d` — to the mesh's index format. `skinned.d` already uses `uint32` and is out of scope. Add a `shadowIndexBuffer` to the mesh types, used by `engine/gpu/shadow.d` when present.
4. **Editor**:
   - an Inspector "Mesh Optimization" section on model assets (toggles from `MeshOptSettings`, stored in `.meta`), with a "Reimport" button
   - a read-only stats block (before/after ACMR, ATVR, overdraw, vertex count)
5. **Demo validation**: `benchmark` and `pbr` load optimized meshes. Record frame time before and after in §11 (GPU-bound scenarios only; CPU-bound frames will not move).

**Exit criteria**: `dub run --config=editor -- --headless-frames=600 --assert-no-gc` still passes, because optimization happens at import or load time, outside the frame loop.

---

### M8 — Tangent & Normal Generation (delivered right after M3, D1)

**Motivation**: the PBR vertex shader (`assets/shaders/textured3d_pbr.wgsl:60-65`) has no tangent input. It builds the tangent by Gram-Schmidt from the model-space X axis (or Z when X is nearly parallel to the normal). This approximation ignores UV orientation, so normal maps are rotated or mirrored on most meshes, and especially across UV seams and mirrored UV islands.

- Port `tangentspace.cpp`:
  - `generateTangents` with the `TangentOptions.compatible` (MikkTSpace-compatible weighting and fallbacks) and `TangentOptions.zeroFallback` options, producing per-corner `float[4]` (xyz plus handedness w = ±1)
  - `generateNormals` (experimental upstream): crease-angle-based per-corner normals with optional smoothing iterations
- Vertex layout:
  - add `TexTanVert { float[3] pos; float[3] normal; float[2] uv; float[4] tangent; }` (stride 48) to `engine/graphics/types.d`, with a matching vertex buffer layout in `engine/gpu/pipeline.d`
  - keep `TexVert` (stride 32) for meshes without normal maps, so unrelated pipelines pay no bandwidth cost
- Shadow vertex layout: when the mesh is `TexTanVert`, the shadow pipeline's vertex stride becomes 48 even though the depth shader does not read the tangent. Keep stride 32 for `TexVert`. Skinned `float[3]` tangents in `SkinningJob` and `skinned.wgsl` are not changed; M8 is the static PBR path.
- Shader:
  - `textured3d_pbr.wgsl` gains a per-vertex tangent attribute at `@location(8) tangent: vec4<f32>`. Locations 0–2 are vertex attributes and 3–7 are per-instance data (`model0..3`, `tint`), so existing locations are not renumbered.
  - the bitangent becomes `cross(N, T) * tangent.w`
  - the fixed-axis fallback is removed from the normal-mapped variant (selected through the WGSL `#ifdef` preprocessor) and kept only for the no-normal-map variant
- Loader integration:
  - the glTF loader reads `TANGENT` when present
  - when `TANGENT` is missing and the material has a normal map, the loader generates tangents with `compatible = true`, because glTF normal maps are baked against MikkTSpace
  - the per-corner output is reindexed with `generateVertexRemapMulti` (position + normal + uv + tangent streams), followed by the M3 pipeline
- Procedural primitives (`engine/graphics/primitives.d`, `TexMesh.sphere`) gain tangents through the same function.
- Validation: a visual regression scene in the `pbr` demo with a mirrored-UV normal-mapped asset, compared before and after (screenshots in `assets/screenshots/`).

**Equivalence**: byte-exact goldens (with fp-contract off), and a MikkTSpace cross-check on `pirate.glb` with tolerance 1e-4.

---

### M4 — Simplifier (`simplifier.cpp`, 2947 lines)

The simplifier is the largest and most delicate module. It is split into three sub-phases, each with its own commit and goldens.

**M4a — Core** (`simplify/topology.d`, `quadric.d`, `collapse.d`, `package.d`)

- Edge adjacency build (`EdgeAdjacency`), position remap / wedge tables (`buildPositionRemap`), and vertex classification (`classifyVertices`: `Kind_Manifold`, `Kind_Border`, `Kind_Seam`, `Kind_Complex`, `Kind_Fringe`, `Kind_Locked`) with the upstream `kCanCollapse` / `kHasOpposite` tables (CTFE).
- Position rescaling to the unit cube (`rescalePositions`) and error scaling.
- Quadric accumulation (plane, edge/border, and volume gradient quadrics), with `double` used exactly where upstream uses `double`.
- Collapse candidate pickup and ranking (`pickEdgeCollapses`, `rankEdgeCollapses`), ordering (`sortEdgeCollapses`, upstream's radix sort on error bits), the `performEdgeCollapses` pass with per-pass limits, `remapIndexBuffer`, and `remapEdgeLoops`.
- `simplify()` with the `lockBorder`, `sparse` and `errorAbsolute` options, plus `resultError`.

**M4b — Attributes & advanced options**

- `simplifyWithAttributes`: attribute quadrics with gradients (`QuadricGrad`) and `attributeWeights`. Up to 32 attributes, as upstream allows.
- `vertexLock` array with `SimplifyVertexFlags.lock`, `.protect` and `.priority`.
- `simplifyWithUpdate`: in-place index, position and attribute update (optimal vertex placement).
- Options `prune`, `regularize`, `regularizeLight`, `permissive`, `preserveFolds` and `errorClamped` (experimental upstream; ported but marked `@("experimental")` in docs).

**M4c — Variants**

- `simplifySloppy` (grid-based vertex clustering with a binary search on grid size, plus `vertexLock`)
- `simplifyPrune` (removes small disconnected components below an error threshold)
- `simplifyPoints` (point-cloud decimation with an optional color metric)
- `simplifyScale` (computes the mesh extent used to convert relative error into world units)

**Equivalence policy for M4**: the simplifier is floating-point heavy. With `--fp-contract=off` and the math-function rules from §4.6, the target is **byte-exact index output** on all corpus meshes. If a residual mismatch is traced to libm differences, the fallback criterion is:

- the output triangle count is within ±1%
- `resultError` is within 1e-5 relative
- the Hausdorff distance (computed in-test) is within 1.05× of the reference

Every such exception is documented in §11.

**Fuzzing**: port `tools/simplifyfuzz.cpp` (random topology, degenerate triangles, NaN-free random positions). The simplifier must never crash, never read out of bounds, and never return more indices than it received.

---

### M5 — Engine Integration II: LODs, Shadow LODs, Collision Proxies

1. **LOD chain generation** in `pipeline.d`:
   ```d
   struct LodSettings {
       uint   maxLods      = 5;
       float  ratio        = 0.5f;     // target index count multiplier per level
       float  maxError     = 0.05f;    // relative error cap
       bool   attributes   = true;     // use simplifyWithAttributes (normals, uvs)
       float  normalWeight = 0.5f;
       float  uvWeight     = 0.25f;
       bool   sloppyFallback = true;   // when topology blocks progress (< 10% reduction per level)
   }

   struct LodLevel(I) { I[] indices; float error; }   // error in mesh-relative units
   LodLevel!(I)[] buildLodChain(V, I)(…);
   ```
   All LOD levels share one vertex buffer, which is sorted by `optimizeVertexFetch` over the concatenation of LOD0..N index buffers. That gives the best cache behavior with a single GPU vertex buffer and an index range per LOD.
2. **Asset format**: `.asset` (`engine/assets/asset_file.d`) gains an optional `lods` array: `{ indexOffset, indexCount, error }` per level. The scene-file and asset versions bump with migration (older assets load as a single LOD).
3. **Runtime**:
   - a POD component `MeshLod { ubyte levelCount; ubyte current; float[8] errors; float bias = 1; }`
   - a gameplay-layer `lodSelectSystem`, which converts `error × simplifyScale × worldScale` to projected pixels using camera FOV and distance and picks the coarsest level under 1 px (biasable). It is `@nogc`, reuses the instanced draw path, and changes only the index range.
   - optional hysteresis to avoid popping; dithered cross-fade is deferred
4. **Shadow LOD**: the shadow pass picks `current + 1` (or a configurable offset), so it uses position-only shadow indices from the coarser level.
5. **Collision proxies**: add a generated collision payload (baked triangles from `simplifySloppy` or `simplify` with `lockBorder` at a target triangle budget, and a convex-hull point list decimated with `simplifyPoints`). Do not overload `AssetTriangleMesh.source`; that field stays a path (`"render"` or another glTF).
6. **Editor**:
   - a LOD preview slider in Scene View
   - per-LOD triangle counts and error values in the Inspector
   - a "Generate LODs" import option in `.meta`

**Exit criteria**:

- a new `lod-stress` demo: 10k instances of the dragon at varying distances shows a measured GPU time reduction
- the selection system has no GC allocations (`--assert-no-gc`)

---

### M6 — Codecs

**M6a — Scalar implementation** (`codec/index.d`, `codec/vertex.d`, `codec/filter.d`)

- **Index codec**:
  - `encodeIndexBuffer` / `decodeIndexBuffer` (edge FIFO + vertex FIFO + varint, versions 0 and 1)
  - `encodeIndexSequence` / `decodeIndexSequence`
  - `decodeIndexVersion` and the `Bound` helpers
  - do **not** port the process-global `encodeIndexVersion` setter. Pass the version as an argument (the setter is not thread-safe upstream). Decoders still accept both on-disk versions.
- **Vertex codec**:
  - versions v0 and v1 (current default), `encodeVertexBufferLevel` (levels 0–3)
  - do **not** port the process-global `encodeVertexVersion` setter. Pass the version as an argument. Decoders still accept both on-disk versions.
  - the byte-group encoding (`kByteGroupSize = 16`, block size up to 256 vertices, bit widths 0/1/2/4/8, and the v1 control modes)
  - the scalar decoder, ported from upstream's `SIMD_FALLBACK` path, which is the reference behavior
- **Filters**:
  - encode and decode for `oct` (8/16-bit), `quat` (16-bit), `exp` (all four `EncodeExpMode`s) and `color` (YCoCg)
  - scalar decoders operating in place on `ubyte[]` with a `stride` in bytes

**Security requirements (decoders)**:

- decoders never read past `buffer.length` and never write past `destination.length`; failures return a nonzero code exactly as upstream does
- they are `@safe` with explicit length checks at each block boundary
- they are fuzzed with a port of `tools/codecfuzz.cpp`, using LDC `--fsanitize=fuzzer,address` in a dedicated `meshopt-fuzz` dub config, plus a 10-minute run per decoder before the phase merges
- decoded output for corrupted input may be garbage, as upstream documents, but the decoder must not crash, hang or allocate unboundedly

**Equivalence**: byte-exact in both directions. D-encoded data decodes with the C++ decoder and vice versa, for all versions and levels, which is required for glTF interoperability.

**M6b — SIMD decoders** (`codec/vertex_simd.d`, `codec/filter_simd.d`)

- `version(LDC)` only. DMD keeps the scalar path, which is correct and portable; DMD is a development compiler.
- x86-64: an SSSE3 path (`pshufb`-based byte-group decode via `ldc.gccbuiltins_x86` / `ldc.simd`) and an AVX-512 VBMI path. Dispatch at runtime with `core.cpuid` (cached function pointer chosen on first call), as upstream does with `cpuid`.
- AArch64 (Android/macOS/iOS targets): a NEON path through `ldc.simd` / `__ir` / `ldc.gccbuiltins_aarch64`.
- Shuffle and lookup tables (`kDecodeBytesGroupShuffle`, `kDecodeBytesGroupCount`) are CTFE-generated `static immutable align(16)` arrays.
- Every SIMD kernel has a differential unit test against the scalar path on random inputs (all bit widths, all tail sizes).

**Performance target**: decode throughput (GB/s, `tools/codecbench.cpp` methodology) within 1.15× of the C++ SIMD path with LDC. Scalar DMD is informational only.

---

### M7 — Engine Integration III: Compressed Geometry

1. **glTF `EXT_meshopt_compression`** in `source/engine/assets/gltf.d` only (not `engine.animation.gltf_skin`). The loader does not reject the extension today: it never reads `extensions`, so a compressed `bufferView` is misread as raw data. Decode the extension (`mode`: `ATTRIBUTES` / `TRIANGLES` / `INDICES`; `filter`: `NONE` / `OCTAHEDRAL` / `QUATERNION` / `EXPONENTIAL` / `COLOR`) into the fallback buffer **before** accessor reads (`readFloatVec`, `readIndices`). Files produced by `gltfpack -c` / `-cc` then load directly.
2. **`KHR_mesh_quantization`**: accept normalized and unnormalized integer attributes (`SHORT`/`BYTE` positions, normals, tangents, UVs) and **dequantize them to `float` on load** into the existing `Vert`/`TexVert` layouts (D4). This also covers the node/mesh transform that gltfpack uses to rescale dequantized positions. Files are smaller on disk; GPU memory is unchanged. Native quantized GPU layouts are a separate graphics task (§9).
3. **Engine `.asset` binary mesh payload**: an optional compressed mesh blob (vertex streams encoded with `encodeVertexBuffer` v1 level 2 + oct/exp filters, indices with `encodeIndexBuffer` v1). Expected size is about 4–6× smaller than raw before general-purpose compression, and the data compresses further with zstd/deflate if a compressor is added later.
4. **Load-time measurement**: decode is the only runtime-critical meshoptimizer code. Add the asset-load time of the `pbr` demo and of a 1M-triangle test scene to §11.

---

### M9 — Clusters (Meshlets)

| Module | Content |
|:---|:---|
| `cluster.d` | `buildMeshlets` (greedy with adjacency, live-triangle tracking and a kd-tree for seed selection), `buildMeshletsScan`, `buildMeshletsBound`, `buildMeshletsFlex` (min/max triangles, `splitFactor`), `buildMeshletsSpatial` (SAH-driven, for RT-style BVH leaves), `computeClusterBounds`, `computeMeshletBounds`, `computeSphereBounds`. Limits: `maxVertices ≤ 256`, `maxTriangles ≤ 512`, enforced by `in` contracts. |
| `meshlet.d` | `optimizeMeshlet`, `optimizeMeshletLevel` (levels 0–9; ≥ 1 may rotate triangle corners), `extractMeshletIndices`. |
| `codec/meshlet.d` | `encodeMeshlet{,Bound}`, `decodeMeshlet` (2/4-byte vertex refs, 3/4-byte triangles), `decodeMeshletRaw`; scalar first, then SSE4.1/NEON under `version(LDC)`. |
| `spatial.d` | Morton-code spatial sort of vertices and triangles, and `spatialClusterPoints` (useful for particles, point clouds, and instance batching). |
| `partition.d` | `partitionClusters` (graph partitioning by shared vertices plus spatial proximity, target size up to +33%). |

**Engine use without mesh shaders**: WebGPU has no mesh or task shaders. Meshlets serve three purposes:

1. **Cluster culling** with `Bounds` (sphere and normal cone). This is done on the CPU first for static meshes (per-cluster frustum and backface-cone rejection in a `@nogc` system), then in M10 with compute culling writing `drawIndexedIndirect` arguments.
2. **Spatial ordering** for better vertex locality: `spatialSortTriangles` before `optimizeVertexCache` on scanned or soup meshes.
3. **Compression**: meshlet codec payloads for M10 streaming.

**Fuzzing**: port `tools/clusterfuzz.cpp`.

---

### M10 — Research: GPU-Driven Clusters and Cluster LOD (Optional)

This is a prototype modeled on upstream `demo/clusterlod.h` and `demo/nanite.cpp`:

- Build a cluster DAG offline: meshlets → `partitionClusters` → merge each group → `simplifyWithAttributes` with `lockBorder` and the sparse option → re-split into meshlets → repeat. Store the per-cluster group error and parent error for monotonic LOD selection.
- Runtime:
  - a compute pass performs frustum culling, cone culling, the LOD cut test (`error(self) ≤ threshold < error(parent)`) and, later, Hi-Z occlusion
  - it appends visible clusters into an indirect buffer, which is drawn with `drawIndexedIndirect`, or with multi-draw-indirect when the wgpu-native build in `libs/` exposes it (check the native feature flags before relying on it)
- Prerequisites outside this plan:
  - compute pipeline helpers in `engine/gpu/` (already partially present through post-processing)
  - storage-buffer bindings
  - the Clustered Forward work listed in the roadmap

This phase produces a design report and a demo. It ships in the engine only if it beats per-object LOD (M5) in the `lod-stress` scene.

---

## 6. Public API Sketch (stable surface)

```d
import engine.meshopt;

// --- indexing ---
size_t generateVertexRemap(I, V)(uint[] remap, const(I)[] indices, const(V)[] vertices);
void   remapVertexBuffer(V)(V[] dst, const(V)[] src, const(uint)[] remap);
void   remapIndexBuffer(I)(I[] dst, const(I)[] src, const(uint)[] remap);
void   generateShadowIndexBuffer(I)(I[] dst, const(I)[] indices, const(ubyte)[] vertices, size_t vertexSize, size_t vertexStride); // stride >= size; stride need not be a multiple of 4

// --- optimization ---
void   optimizeVertexCache(I)(I[] dst, const(I)[] indices, size_t vertexCount);
void   optimizeOverdraw(I)(I[] dst, const(I)[] indices, FloatStream positions, float threshold = 1.05f);
size_t optimizeVertexFetch(V, I)(V[] dstVerts, I[] indices, const(V)[] verts);

// --- analysis ---
VertexCacheStatistics analyzeVertexCache(I)(const(I)[] indices, size_t vertexCount, uint cacheSize = 16, uint warpSize = 0, uint primGroupSize = 0);
OverdrawStatistics    analyzeOverdraw(I)(const(I)[] indices, FloatStream positions);

// --- simplification ---
size_t simplify(I)(I[] dst, const(I)[] indices, FloatStream positions, size_t targetIndexCount,
                   float targetError, SimplifyOptions opts = SimplifyOptions.none, out float resultError);
size_t simplifyWithAttributes(I)(I[] dst, const(I)[] indices, FloatStream positions,
                   FloatStream attributes, const(float)[] attributeWeights,
                   const(ubyte)[] vertexLock, size_t targetIndexCount, float targetError,
                   SimplifyOptions opts, out float resultError);
float  simplifyScale(FloatStream positions);

// --- codecs (decoders return 0 on success, upstream error codes otherwise) ---
size_t encodeVertexBuffer(ubyte[] dst, const(ubyte)[] vertices, size_t vertexSize, int level = 2, int version_ = -1);
int    decodeVertexBuffer(ubyte[] dst, size_t vertexCount, size_t vertexSize, const(ubyte)[] encoded);
size_t encodeIndexBuffer(I)(ubyte[] dst, const(I)[] indices);
int    decodeIndexBuffer(I)(I[] dst, const(ubyte)[] encoded);
void   decodeFilterOct(ubyte[] buffer, size_t count, size_t stride);

// --- clusters ---
size_t buildMeshlets(I)(Meshlet[] meshlets, uint[] meshletVertices, ubyte[] meshletTriangles,
                        const(I)[] indices, FloatStream positions,
                        size_t maxVertices, size_t maxTriangles, float coneWeight);
Bounds computeMeshletBounds(const(uint)[] meshletVertices, const(ubyte)[] meshletTriangles, FloatStream positions);

// --- tangents ---
void generateTangents(I)(float[4][] result, const(I)[] indices, FloatStream positions,
                         FloatStream normals, FloatStream uvs, TangentOptions opts = TangentOptions.none);

// --- engine pipeline (GC allowed, import-time) ---
OptimizedMesh!(V, I)  optimizeMesh(V, I)(const(V)[] verts, const(I)[] indices, const MeshOptSettings s = MeshOptSettings.init);
LodLevel!(I)[]        buildLodChain(V, I)(const(V)[] verts, const(I)[] indices, const LodSettings s = LodSettings.init);
```

Every low-level function also accepts an optional trailing `ref MeshoptScratch scratch` (defaulting to the thread-local instance), so editor import jobs on worker threads can own their scratch arenas.

---

## 7. Validation Strategy

### 7.1 Differential testing against the reference ("oracle")

- **Oracle build**: `tools/meshopt-oracle/build_ref.sh` compiles `ref/meshoptimizer/src/*.cpp` with `clang++ -O2 -ffp-contract=off -DMESHOPTIMIZER_NO_WRAPPERS` into `libs/libmeshoptimizer_ref.a`. That path is gitignored (`*.a`).
- **Golden generator**: `dub run --config=meshopt-oracle -- generate` runs every upstream function on every corpus mesh with a fixed matrix of parameters and writes `tests/meshopt/golden/<function>/<mesh>_<params>.bin` with a small header (function, params hash, upstream version). Goldens are **committed**, so day-to-day `dub test` and CI never need a C++ compiler.
- **Golden test**: unit tests in each module load the matching goldens (`version(MeshoptGolden)`, enabled in the `library` test config) and compare byte for byte.
- **Live differential mode**: `dub run --config=meshopt-oracle -- diff --random=10000` feeds random meshes (random topology, seams, degenerates, duplicate vertices) to both implementations and reports the first divergence with a minimized repro. It runs before merging M1, M2, M4, M6 and M9.
- **Upgrading upstream**: bump the tag, regenerate goldens, and review the diff. A golden that changed upstream points to the exact behavior change to port.

### 7.2 Unit tests

- Port `demo/tests.cpp` test-for-test (≈3.7k lines), one `unittest` block per upstream test function and named identically (`@("decodeVertexV1") unittest { … }`).
- Engine-specific tests cover `FloatStream` views over `Vert`/`TexVert`, `ushort` vs `uint` index paths producing identical results, and scratch reuse.

### 7.3 Benchmarks

`dub run --config=meshopt-bench --build=release --compiler=ldc2` prints this table, which is pasted into §11 at every phase:

| Function | Mesh | C++ (ms) | D LDC (ms) | D DMD (ms) | LDC ratio |
|:---|:---|---:|---:|---:|---:|
| `optimizeVertexCache` | dragon 100k | … | … | … | … |
| `simplify` 10% | dragon 100k | … | … | … | … |
| `decodeVertexBuffer` | 1M verts × 16 B | … GB/s | … GB/s | … GB/s | … |

Gates (D2):

- **import-time functions** (indexing, optimizers, simplifier, tangents, clusterizer): target ≤ 1.5×, hard limit 2× with LDC. These run once per asset import; a 2× slowdown on a 100k-triangle mesh costs milliseconds to a few seconds in the editor and nothing in-game.
- **decoders** (index, vertex, filter, meshlet codecs, the only code on the asset-load path): ≤ 1.15× (SIMD vs SIMD) / ≤ 1.3× (scalar vs scalar). These limits are hard; a decoder phase does not merge until they pass.

Every optimization that introduces `@trusted` code must come with a before/after row.

### 7.4 Fuzzing and sanitizers

- `meshopt-fuzz` dub config (LDC, `--fsanitize=fuzzer,address`). It holds ports of `codecfuzz` (every decoder plus filters), `simplifyfuzz` and `clusterfuzz`.
- Seed corpora come from the goldens.
- Minimum run before merging a phase that touches decoders: 10 minutes per target with no findings.

### 7.5 GC policy verification

- All `engine.meshopt` modules except `pipeline.d` are `@nogc` (compiler-enforced).
- `dub run --config=lint` gains a rule that no `engine.meshopt` struct may hold GC indirections (already covered by `Pod!T`).
- Runtime systems introduced in M5/M9 (LOD selection, CPU cluster culling) are exercised under `--assert-no-gc` in the `player` and `editor` headless runs.

---

## 8. Build Configuration Changes

| Config | Purpose | Notes |
|:---|:---|:---|
| `library` (existing) | Includes `source/engine/meshopt/` automatically through `sourcePaths` | No new libs, no C/C++ files. |
| `meshopt-bench` (new) | Benchmarks | D-only timings by default. `-version=MeshoptOracle` also times `libmeshoptimizer_ref.a`. Dub invokes `cc` directly and ignores `pragma(lib)`, so that link needs `-L-lmeshoptimizer_ref -L-lstdc++` (the archive is optional and gitignored). |
| `meshopt-oracle` (new) | Golden generation + live diff | Requires `tools/meshopt-oracle/build_ref.sh` and `clang++` with libstdc++. **Never** a dependency of other configs. |
| `meshopt-fuzz` (new) | libFuzzer targets | LDC only. |

`AGENTS.md` changes, made when M3 lands:

- add `meshopt/` to the directory tree with a one-line description
- add a "Mesh processing" note: use `engine.meshopt.pipeline` at import time and never call simplification or optimization from the frame loop
- add an entry under Common Mistakes: "Using `std.math` real-precision functions or `std.algorithm.sort` inside `engine.meshopt` breaks bit-exactness with upstream"

---

## 9. Deferred / Out of Scope

| Item | Reason | Revisit when |
|:---|:---|:---|
| Opacity micromaps (`opacitymap.cpp`) | WebGPU has no ray tracing / OMM consumers | wgpu exposes ray tracing with OMM support |
| Voxel remesher (`remesher.cpp`, experimental) | Experimental upstream; no immediate engine consumer | Need for impostor/proxy generation for far LODs (HLOD) |
| `setAllocatorCache` | Subsumed by `MeshoptScratch` block retention | — |
| WASM SIMD paths | Not an engine target platform | A web build target is added |
| Adjacency/tessellation consumers | No geometry/tessellation stages in WebGPU | Outline/silhouette compute pass is planned |
| `gltfpack`-style CLI | Separate tool, large surface (texture compression, scene flattening) | Need for an offline repack step in `build_export.d` |
| Native quantized GPU vertex layouts (D4) | M7 dequantizes on load; native layouts touch `engine/gpu/pipeline.d` and every vertex shader | Vertex memory or bandwidth becomes a measured bottleneck (large scenes, mobile targets) |

---

## 10. Risks and Open Questions

| # | Risk / question | Mitigation / proposed answer |
|:---|:---|:---|
| R1 | Performance gap (Jolt precedent) | Tiered gates (D2): hard limits only on decoders, ≤ 2× allowed for import-time code. G1 tuning checkpoint; `@trusted` kernels only with measured wins; LDC is the release compiler. No C++ fallback. |
| R2 | Floating-point divergence breaks byte-exact goldens (simplifier, tangents, clusterizer) | fp-contract off in both builds; `core.stdc.math` float functions; documented tolerance fallback (M4) only after root-causing. |
| R3 | Bounds checks in `@safe` code slow inner loops under `-release` (`safeonly`) | Validate once at entry; hoist slices; move only proven-hot loops to audited `@trusted` kernels. |
| R4 | SIMD in D: `ldc.simd` / `gccbuiltins` are LDC-specific; DMD `core.simd` is limited | **Resolved (D3):** raw LDC builtins under `version(LDC)` in the `*_simd.d` modules, with no new dub dependency. DMD uses the scalar paths. `intel-intrinsics` was considered and rejected. |
| R5 | Upstream evolves quickly (v1.0 → v1.3 within a year; new experimental APIs) | Pin to a tag; port only stable APIs first; golden regeneration diff surfaces behavior changes on upgrade; track upstream `CHANGELOG`/release notes per bump. |
| R6 | License compliance | meshoptimizer is MIT. Each ported module carries a header: `// Ported from meshoptimizer v1.3 (src/<file>.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.` Add the upstream license text to `docs/third-party-licenses.md` (new) and to the player export bundle. |
| R7 | 16-bit vs 32-bit indices throughout the renderer | M3 adds `uint` index support to `Mesh`/`TexMesh`; `pipeline.d` narrows to `ushort` when possible (smaller buffers). |
| R8 | Quantized vertex formats (`KHR_mesh_quantization`) require new pipeline layouts | **Resolved (D4):** dequantize to `float` on load in M7. Native quantized GPU layouts are deferred (§9). |
| R9 | `simplifier.cpp` complexity (≈3k lines, many interacting options) | Split M4 into three commits; port `demo/tests.cpp` simplifier tests first (test-first); live differential fuzzing before merge. |

---

## 11. Progress Log

Update this section at the end of every phase.

| Phase | Commit | Date | Golden equivalence | LDC ratio (geomean) | Notes |
|:---|:---|:---|:---|:---|:---|
| M0 | — | 2026-11-02 | quantize* bit-exact on committed goldens (exhaustive `quantizeHalf` is `version(MeshoptExhaustive)` only) | D-only table in `meshopt-bench` (C++ column with `-version=MeshoptOracle`) | Upstream commit `9e1f07b159d3cb777f1c67ed31fc11fd117986f4` (tag v1.3, `MESHOPTIMIZER_VERSION 1030`). Header is 1724 lines (`wc -l`). No scanned mesh. `encode*Version` setters are not ported. `dub test --config=library` is green on DMD. A full LDC library link fails on the prebuilt DMD `libsymgc-cards.a` (`__dmd_personality_v0`); the M0 unittests themselves pass under ldc2. |
| M1 | 5b79f97 | 2026-11-02 | byte-exact on committed goldens (corpus + odd stride); live `diff --random=10000` matches the C++ oracle | see G1 | `indexgenerator.cpp` is 825 lines. `generateVertexRemapCustom` is a template alias predicate (`meshoptPositionsEqual` when the C callback is null). Empty index slices are the unindexed case. `dub test --config=library` is green on DMD. |
| M2 | — | 2026-11-02 | byte-exact on committed goldens; live `diff --random=32` (raster on corpus + 8 random) matches the C++ oracle | see G1 | `vcacheoptimizer.cpp` 467, `overdrawoptimizer.cpp` 333, `vfetchoptimizer.cpp` 71, `indexanalyzer.cpp` 125, `rasterizer.cpp` 289, `stripifier.cpp` 296. Upstream sorts only. `float` locals are zeroed explicitly (`float.init` is NaN). |
| G1 | — | 2026-11-02 | 100% byte-exact | **1.10** LDC, 2.58 DMD (informational) | Decision: **continue**. Grid 64 (8192 tris), clang `-O2 -ffp-contract=off` vs LDC `-O3 -release -mcpu=native` / DMD `-O -release`. LDC ratios: remap 1.01, filter 0.91, shadow 0.89, adjacency 0.71, provoking 1.56, vcache 1.33, fifo 1.15, overdraw 1.25, vfetch 1.70, analyzeCache 1.41, analyzeOverdraw 0.70, stripify 1.10. Worst LDC is 1.70, so no profiling pass. `@trusted` markers are 26 / 2541 lines (1.02%) in the M1+M2 modules. |
| M3 | — | — | — | — | Demo frame time before/after: |
| M8 | — | — | — | — | Normal-map regression screenshots: |
| M4a | — | — | — | — | |
| M4b | — | — | — | — | |
| M4c | — | — | — | — | |
| M5 | — | — | — | — | `lod-stress` GPU time before/after: |
| M6a | ab1d77a | 2026-11-02 | byte-exact vs scalar C++ (`MESHOPTIMIZER_NO_SIMD`) on committed goldens, both directions, v0/v1, levels 0–3 | scalar vertex ~1.29× (D slower than clang scalar); index ~1.21× | Decoders are `@safe nothrow @nogc` and return upstream codes. Version is an argument. `dub test --config=library` green on DMD. libFuzzer+ASan of the decoders ran 181s (902473 inputs) with no crash. |
| M6b | 23fd849 | 2026-11-02 | LDC SSSE3 decode matches the scalar goldens | vertex SIMD 4.34 / 4.68 GB/s = 1.08× (pass ≤1.15). Index 2.00 / 2.42 GB/s = 1.21× (pass ≤1.3, no SIMD upstream). Oct8 0.59 / 2.27 GB/s = 3.83× **miss** | SSSE3 vertex decode via `ldc.gccbuiltins_x86`, runtime `core.cpuid` (SSSE3+POPCNT). AVX-512 is not dispatched (this host has none; upstream only compiles it when the target flags are on). NEON is not compiled on x86_64. Oct8 stays scalar: upstream SSE uses `rsqrt` and is not bit-exact with `SIMD_FALLBACK`. D scalar oct8 is faster than C++ scalar (0.59 vs 0.19 GB/s). |
| M7 | local | 2026-11-02 | loader unit test: meshopt triangles+attributes and ushort-normalized positions | — | `EXT_meshopt_compression` is decoded before accessor reads. `KHR_mesh_quantization` dequantizes to float in `TexVert`. The node that instances mesh 0 (parents included) is baked in, which is the gltfpack rescale. Indices stay `ushort`; a decoded index above 65535 fails with the existing error. Compressed `.asset` mesh blob is **deferred** (asset format is still v1 with no migration path for a new payload). |
| M9 | — | — | — | — | |
| M10 | — | — | — | — | |

---

## 12. Decision Log

| ID | Date | Decision | Alternatives considered | Rationale |
|:---|:---|:---|:---|:---|
| D1 | 2026-10-29 | **Delivery order after M3: tangents (M8) → LODs (M4/M5) → compression (M6/M7) → clusters (M9/M10).** | LODs first (original order); compression first | M8 is small (~750 upstream lines), depends only on M1/M3, and fixes a visible bug: the PBR shader's fixed-axis tangent approximation (`textured3d_pbr.wgsl:60-65`) orients normal maps incorrectly. LODs remain the biggest performance win and follow immediately. |
| D2 | 2026-10-29 | **Tiered performance policy, always pure D.** Decoders: hard limits ≤ 1.15× (SIMD) / ≤ 1.3× (scalar). Import-time functions: target ≤ 1.5×, hard limit 2×. A C++ binding fallback is ruled out. | Uniform 1.25× gate everywhere; allow a C++ fallback behind a build flag | Only the decoders run on the asset-load path; everything else runs once per import, where a 2× slowdown is not user-visible in-game. A C++ fallback would break the pure-D goal and add a C++ build step on every target platform. |
| D3 | 2026-10-29 | **SIMD via raw LDC builtins** (`ldc.simd`, `ldc.gccbuiltins_x86`, `ldc.gccbuiltins_aarch64`) under `version(LDC)`, with runtime dispatch through `core.cpuid`. DMD uses the scalar path. | `intel-intrinsics` dub package; scalar only | No new dub dependency. The SIMD surface is small (the vertex, filter and meshlet decode kernels), and DMD is the development compiler only. |
| D4 | 2026-10-29 | **`KHR_mesh_quantization`: dequantize to `float` on load** into the existing vertex layouts. | Native quantized GPU layouts | No renderer or shader changes. The disk-size benefit is kept; the GPU-memory benefit is deferred (§9). |

---

## Appendix A — Function Coverage Checklist

Every public upstream function, with its target phase. ☐ = not started, ☑ = ported and golden-verified.

**Indexing (M1)**: ☑ generateVertexRemap ☑ generateVertexRemapMulti ☑ generateVertexRemapCustom ☑ remapVertexBuffer ☑ remapIndexBuffer ☑ filterIndexBuffer ☑ filterIndexBufferMulti ☑ generateShadowIndexBuffer ☑ generateShadowIndexBufferMulti ☑ generatePositionRemap ☑ generateAdjacencyIndexBuffer ☑ generateTessellationIndexBuffer ☑ generateProvokingIndexBuffer

**Optimization & analysis (M2)**: ☑ optimizeVertexCache ☑ optimizeVertexCacheStrip ☑ optimizeVertexCacheFifo ☑ optimizeOverdraw ☑ optimizeVertexFetch ☑ optimizeVertexFetchRemap ☑ analyzeVertexCache ☑ analyzeVertexFetch ☑ analyzeOverdraw ☑ analyzeCoverage ☑ stripify ☑ stripifyBound ☑ unstripify ☑ unstripifyBound

**Simplification (M4)**: ☐ simplify ☐ simplifyWithAttributes ☐ simplifyWithUpdate ☐ simplifySloppy ☐ simplifyPrune ☐ simplifyPoints ☐ simplifyScale

**Codecs (M6/M9)**: ☑ encodeIndexBuffer ☑ encodeIndexBufferBound ☑ encodeIndexVersion *(argument, not the process-global setter)* ☑ decodeIndexBuffer ☑ decodeIndexVersion ☑ encodeIndexSequence ☑ encodeIndexSequenceBound ☑ decodeIndexSequence ☑ encodeVertexBuffer ☑ encodeVertexBufferBound ☑ encodeVertexBufferLevel ☑ encodeVertexVersion *(argument, not the process-global setter)* ☑ decodeVertexBuffer ☑ decodeVertexVersion ☑ decodeFilterOct ☑ decodeFilterQuat ☑ decodeFilterExp ☑ decodeFilterColor ☑ encodeFilterOct ☑ encodeFilterQuat ☑ encodeFilterExp ☑ encodeFilterColor ☐ encodeMeshlet ☐ encodeMeshletBound ☐ decodeMeshlet ☐ decodeMeshletRaw

**Clusters (M9)**: ☐ buildMeshlets ☐ buildMeshletsScan ☐ buildMeshletsBound ☐ buildMeshletsFlex ☐ buildMeshletsSpatial ☐ optimizeMeshlet ☐ optimizeMeshletLevel ☐ computeClusterBounds ☐ computeMeshletBounds ☐ computeSphereBounds ☐ extractMeshletIndices ☐ partitionClusters ☐ spatialSortRemap ☐ spatialSortTriangles ☐ spatialClusterPoints

**Tangents (M8)**: ☐ generateTangents ☐ generateNormals

**Quantization & memory (M0)**: ☑ quantizeUnorm ☑ quantizeSnorm ☑ quantizeHalf ☑ quantizeFloat ☑ dequantizeHalf ☑ computePositionExponent ☑ setAllocator → `MeshoptScratch`

**Deferred**: opacityMapMeasure · opacityMapRasterize · opacityMapEntrySize · opacityMapCompact · remesh · setAllocatorCache
