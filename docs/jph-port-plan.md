# Plano de porte: JoltPhysics → D (`engine.jph.*`)

Porte incremental e commit-por-fase do Jolt Physics (C++) para D nativo
dentro do namespace `engine.jph`. Source-of-truth: `ref/JoltPhysics/Jolt/`.

## Convenções globais do porte

- **Uma fase por commit.** Cada fase termina com `dub test --config=library`
  verde e os 7 `dub build --config=<cfg>` limpos.
- **POD-first.** Sem classes, sem GC pointers dentro de estruturas de dados
  quentes; `!hasIndirections!T` é a régua.
- **`@safe:` no topo.** Interop não-seguro fica em `@trusted` mínimo.
- **Sem `@nogc` forçado fora do hot path da engine.** O frame path da
  engine-core permanece `@nogc`; gameplay/API pode usar o GC.
- **Índices em vez de ponteiros** para estruturas em pool (e.g. triângulos
  do EPA, Shape refs).
- **Sem dependências bindbc-*.** Bindings são `extern(C) nothrow @nogc`
  manuais em `source/bindings/`.

## Resumo das fases

| #   | Fase                                      | Estado       | Commit    |
| --- | ----------------------------------------- | ------------ | --------- |
| 0   | Backup + remoção do `engine.physics`      | ✅ Concluída | `7ce026b` |
| 1   | `jph.core` (Ref, Array, JobSystem, …)     | ✅ Concluída | `0fe3b25` |
| 2a  | `jph.geometry` primitives + GJK           | ✅ Concluída | `5fd5f5c` |
| 2b  | `jph.geometry` EPA + raios                | ✅ Concluída | `17d259a` |
| 3   | `jph.physics.body` (IDs, MP, enums)       | ✅ Concluída | `a325c5a` |
| 4   | `jph` shapes                              | ⏳ Em curso  | —         |
| 5   | Narrowphase + dispatch                    | ⬜ Pendente  | —         |
| 6   | BroadPhaseQuadTree + SIMD rays            | ⬜ Pendente  | —         |
| 7   | Constraints + ContactConstraintManager    | ⬜ Pendente  | —         |
| 8   | PhysicsSystem + IslandBuilder + API       | ⬜ Pendente  | —         |
| 9   | Migrar `benchmark.d` e `test_physics.d`   | ⬜ Pendente  | —         |
| 10  | (opcional) JobSystemTaskPool              | ⬜ Pendente  | —         |

Status: **4 de 11 fases concluídas**, fase 4 em andamento.

---

## Phase 0 — Backup, remoção, stubs ✅

**Commit:** `7ce026b`

- [x] Criar branch `pre-jph-port` preservando a implementação anterior.
- [x] Apagar `source/engine/physics/` (versão antiga, classe-based).
- [x] Remover `import engine.physics.*;` dos demos; stub de build.
- [x] Criar `source/engine/jph/package.d` vazio (só re-export).
- [x] Confirmar que todos os 7 `dub build --config=*` ainda compilam.

---

## Phase 1 — `jph.core` ✅

**Commit:** `0fe3b25`. Infraestrutura usada por todo o resto.

- [x] `engine.jph.core.types` — aliases (`uint_`, `uint8`, `uint16`,
  `uint32`, `uint64`, `Float3`, `Double3`).
- [x] `engine.jph.core.scalar` — helpers numéricos (`Min`, `Max`, `Square`,
  `Sign`, `DegreesToRadians`, `RadiansToDegrees`).
- [x] `engine.jph.core.staticarray` — `StaticArray(T, N)` com `size()`,
  `push_back(auto ref)`, `pop_back`, `resize`, `data()`, operador de
  índice, `@disable this(this)`.
- [x] `engine.jph.core.array` — `Array(T)` (vector dinâmico com GC; usa
  `T[]` sob o capô com invariantes Jolt-compatíveis).
- [x] `engine.jph.core.refcount` — `Ref(T)` intrusivo (base + ponteiro).
- [x] `engine.jph.core.jobsystem` — interface estática `JobSystem` +
  stub single-threaded `JobSystemSingleThreaded`.
- [x] `engine.jph.core.tempallocator` — alocador linear por frame.
- [x] Unittests cobrindo `StaticArray`, `Array` e `Ref`.

---

## Phase 2 — `jph.geometry` ✅

### Phase 2a — Primitives + GJK ✅

**Commit:** `5fd5f5c`

- [x] `plane.d` — `Plane` (equação `n·p + d = 0`).
- [x] `triangle.d` — `Triangle { Vec3[3] mV; }`.
- [x] `sphere.d` — `Sphere { Vec3 mCenter; float mRadius; }`.
- [x] `aabox.d` — `AABox` com `Contains`, `Overlaps`, `Expand`, `Transformed`.
- [x] `orientedbox.d` — OBB (centro + eixos meio-extent).
- [x] `convexsupport.d` — `TransformedConvexObject`, `AddConvexRadius`,
  `PointConvexSupport`, `TriangleConvexSupport`.
- [x] `closestpoint.d` — distância ponto-simplex (2/3/4 vértices).
- [x] `gjk.d` — `GJKClosestPoint` com `GetClosestPoints`,
  `GetClosestPointsSimplex`, `Intersects`, `CastShape`.
- [x] `Vec4` ctor adicional; re-exports em `math/package.d` e
  `geometry/package.d`.

### Phase 2b — EPA + raios ✅

**Commit:** `17d259a`

- [x] `epa_hull.d` — `EPAConvexHullBuilder` (~430 LOC): pool fixo de 256
  triângulos, free-stack, max-heap manual por `mClosestLenSq`, seleção
  dos dois pares de aresta mais curtos, `FindEdge` com DFS explícito.
- [x] `epa.d` — `EPAPenetrationDepth` (GJK → EPA), `EStatus {NotColliding,
  Colliding, Indeterminate}`, `GetPenetrationDepthStepGJK/StepEPA`,
  `GetPenetrationDepth` combinado, `CastShape`.
- [x] `ray_aabox.d` — método de slabs + duas variantes de saída.
- [x] `ray_sphere.d`, `ray_triangle.d` (Möller–Trumbore),
  `ray_cylinder.d` (cap test), `ray_capsule.d`.
- [x] `math/findroot.d` — raiz de quadrática (usada por sphere/cylinder).
- [x] Adiados (virão junto com BroadPhase — Phase 6): `RayAABox4`,
  `RayTriangle4` e demais variantes SIMD em lote.

---

## Phase 3 — `jph.physics.body` ✅

**Commit:** `a325c5a`

- [x] `bodyid.d` — `BodyID` 32-bit empacotado (23-bit index +
  8-bit sequence + 1-bit broadphase reservado).
- [x] `bodytype.d`, `motiontype.d`, `motionquality.d` — enums simples.
- [x] `alloweddofs.d` — bitfield + helpers `dofOr/And/Xor/Not/Has`
  (D não permite overloads de operador em enums).
- [x] `bodypair.d` — par de 8 bytes, `opEquals/opCmp` via `uint64` packed.
- [x] `massproperties.d` — `SetMassAndInertiaOfSolidBox`, `ScaleToMass`,
  `Translate` (teorema dos eixos paralelos), `sGetEquivalentSolidBoxSize`.
- [x] `motionproperties.d` — velocidades linear/angular, acumuladores de
  força/torque, massa inversa, inércia inversa diagonal + rotação,
  damping, fator de gravidade, clamp de velocidades, máscaras de DOF
  (`LockTranslation` / `LockAngular`), timer de sleep, helpers para
  passos de solver, `ApplyForceTorqueAndDragInternal`.
- [x] Helpers Mat44 adicionados: `+= / -=`, `Multiply3x3RightTransposed`,
  `sOuterProduct`.
- [x] Adiados: `MoveKinematic` (precisa de `Quat::GetAngularVelocity(dt)`),
  gyroscopic force, sleep-test spheres (por ora só timer), BodyAccess
  thread-safety asserts, stats, serialização, double-precision.

---

## Phase 4 — Shapes ⏳

Base polimórfica + formas primitivas convexas. Dividida em Phase 4a
(primitivas + decorated + StaticCompound) e Phase 4b
(ConvexHull + builder, futura).

Design: classes ref-counted (`mixin RefTargetMixin!T` de
`engine.jph.core.reference`), espelhando a hierarquia C++ do Jolt. Exceção
consciente à regra "no classes" do AGENTS.md, alinhada a
`JobSystem`/`TempAllocator` que já são classes.

### Phase 4a.0 — Infraestrutura base ✅

- [x] `physics/shape/sub_shape_id.d` — `SubShapeID` (uint32 packed,
  `cEmpty=0xFFFFFFFF`, `MaxBits=32`, `PopID`/`PushID` com 64-bit math),
  `SubShapeIDCreator`, `SubShapeIDPair` (BodyID×2 + SubShapeID×2 + FNV-1a
  `GetHash` + total-order `opCmp`).
- [x] `physics/shape/scale_helpers.d` — `cMinScale`, `cScaleToleranceSq`,
  `IsNotScaled`, `IsUniformScale`, `IsUniformScaleXZ`, `IsInsideOut`,
  `IsZeroScale`, `ScaleConvexRadius`, `MakeNonZeroScale`,
  `MakeUniformScale`, `MakeUniformScaleXZ`, `CanScaleBeRotated`,
  `RotateScale` (R^T·diag(s)·R inline via `Mat44.opCall(row,col)`).
- [x] `physics/shape/physics_material.d` — `class PhysicsMaterial` stub
  com `RefTargetMixin`, `GetDebugName()`, `sDefault()` singleton + alias
  `PhysicsMaterialRefC = RefConst!PhysicsMaterial`.
- [x] `physics/shape/cast_result.d` — `RayCast`, `BroadPhaseCastResult`
  (`mFraction = 1 + 1e-7f`), `RayCastResult`.
- [x] `physics/shape/shape.d` — `EShapeType` (12 valores), `EShapeSubType`
  (34 valores numéricos exatos do Jolt), `ShapeResult` (`sOk`/`sError`),
  `abstract class ShapeSettings`, `class ShapeFilter` com singleton
  `sDefault`, `ShapeStats`, `abstract class Shape` com vtable virtual
  completa (bounds/mass/material/normal/raycast/leaf/scale/stats).
- [x] Reference.h fixes: `mixin RefTargetMixin` agora importa
  símbolos via FQN (atomics, jphDelete, cEmbedded), `Ref!T.GetPtr` é
  `@trusted` para casts de `inout`.

### Phase 4a.1 — ConvexShape + primitivas básicas ✅

- [x] `convex_shape.d` — `abstract class ConvexShape : Shape` com
  `mMaterial` (RefConst!PhysicsMaterial pré-fillado com sDefault no ctor),
  `mDensity`, `Support`/`SupportBuffer` (4160-byte aligned)/`ESupportMode`,
  abstract `GetSupportFunction`. `ConvexShapeSettings` análogo.
- [x] `sphere_shape.d` — `SphereShape` (point + convex radius), suporta só
  scale uniforme, `SphereNoConvex`/`SphereWithConvex` placement-emplaced
  no SupportBuffer via `core.lifetime.emplace`.
- [x] `box_shape.d` — `BoxShape` com `cDefaultConvexRadius=0.05`, convex
  radius descontado das half-extents para não inflar a caixa, `BoxSupport`
  com `AABox.GetSupport` para o GJK, raycast via `RayAABox` slab.
- [x] `capsule_shape.d` — `CapsuleShape` (segmento Y + convex radius),
  `IsSphere()` quando halfHeight==0, scale uniforme obrigatório,
  raycast via `RayCapsule`.

### Phase 4a.2 — primitivas restantes ✅

- [x] `cylinder_shape.d` — Y-axis cylinder com convex radius esculpido nas
  bordas (não infla a caixa), `IsValidScale` exige scale uniforme em XZ,
  raycast via `RayCylinder`.
- [x] `tapered_cylinder_shape.d` — radii top/bottom independentes, COM
  deslocada ao longo de Y (override de `GetCenterOfMass`); inertia
  fechada (Maxima); fallback para `CylinderShape` quando radii batem.
- [x] `tapered_capsule_shape.d` — duas semiesferas + frustum tangente,
  só scale uniforme. Quando degenera para esfera com offset, retorna
  erro temporariamente até `RotatedTranslatedShape` (4a.4) chegar.
- [x] `triangle_shape.d` — convex radius só usado para shape-vs-shape;
  raycast via `RayTriangle`; `GetMassProperties()` retorna properties
  vazias (triangle não tem volume).
- [x] `convex_shape.d` ganhou fallback `CastRay` via GJK
  (`engine.jph.geometry.gjk.GJKClosestPoint.CastRay`) — usado pelos
  taperdos que não têm forma analítica.

### Phase 4a.3 — degenerate

- [ ] `plane_shape.d`.
- [ ] `empty_shape.d`.

### Phase 4a.4 — decorated

- [ ] `scaled_shape.d` (requer portar `MassProperties.Scale`/`Rotate`).
- [ ] `rotated_translated_shape.d`.
- [ ] `offset_center_of_mass_shape.d`.

### Phase 4a.5 — composto

- [ ] `static_compound_shape.d` com partição BVH (sort+mediana, não SAH).

### Phase 4b (sub-fase futura, plano separado)

- [ ] `convex_hull_shape.d` — points + faces + edges (geração offline).
- [ ] `engine.jph.geometry.convex_hull_builder` (~800 LOC).

### Adiados para uma fase futura

- `MeshShape`, `HeightFieldShape`, `MutableCompoundShape`, `SoftBodyShape`.

**Saída esperada:** 25+ módulos passando unittests; demos continuam a
compilar.

---

## Phase 5 — Narrowphase + dispatch ⬜

- [ ] `collision/collide_shape.d` — `CollideShapeResult`,
  `CollideShapeSettings`, `ECollisionMode`.
- [ ] `collision/cast_result.d` — `CastResult`, `CastShapeResult`,
  `RayCastResult`.
- [ ] `collision/collide_convex_vs_triangles.d`.
- [ ] `collision/collision_dispatch.d` — tabela
  `sCollisionFunctions[sub_type_a][sub_type_b]`.
- [ ] Ponte `ShapeVsShape` usando GJK + EPA da Phase 2.
- [ ] `collision/manifold_between_two_faces.d` — clipping de faces para
  gerar contact manifolds (usado pelo solver).
- [ ] `collision/collide_shape_dispatch.d` e `cast_shape_dispatch.d`.
- [ ] `collision/broad_phase_layer.d`, `object_layer.d`,
  `object_vs_broad_phase_layer_filter.d`,
  `object_layer_pair_filter.d`.

---

## Phase 6 — BroadPhaseQuadTree + SIMD ray ⬜

- [ ] `broad_phase.d` — `BroadPhase` base e `BroadPhaseBruteForce` (debug).
- [ ] `broad_phase_quad_tree.d` — árvore de 4 filhos com nós SoA.
- [ ] `quad_tree.d` — insert/remove/update em batch, cast ray / sphere /
  box / point.
- [ ] Implementar as variantes SIMD adiadas:
  - [ ] `RayAABox4` — interseção com 4 AABoxes em paralelo.
  - [ ] `RayTriangle4` — interseção com 4 triângulos em paralelo.
  - [ ] `UVec4` / `Vec4.sMin/sMax/sSelect/sAnd/sOr` que forem necessários.
- [ ] `broad_phase_layer_interface.d`,
  `broad_phase_layer_interface_table.d`.

---

## Phase 7 — Constraints + ContactConstraintManager ⬜

- [ ] `constraints/constraint.d` — base + `ConstraintSettings`.
- [ ] Constraints mínimas:
  - [ ] `fixed_constraint.d`, `point_constraint.d`,
    `distance_constraint.d`, `hinge_constraint.d`,
    `slider_constraint.d`.
- [ ] `constraint_manager.d`.
- [ ] `contact_constraint_manager.d` — geração de jacobianos + warm start +
  solver de velocidade e posição (Gauss-Seidel sequencial).
- [ ] `penetration_axis.d`, `estimate_collision_response.d`.
- [ ] `physics_settings.d` — steps, baumgarte, erp, slop.

---

## Phase 8 — PhysicsSystem + IslandBuilder + BodyInterface ⬜

- [ ] `body/body_manager.d` — alocação/reciclagem de `BodyID`, arrays SoA
  de `Body` + `MotionProperties`.
- [ ] `body/body.d` — composição final (`BodyID`, transform, shape ref,
  motion props ptr, layers, flags).
- [ ] `body/body_creation_settings.d` e `body/body_filter.d`.
- [ ] `body/body_interface.d` — API pública para criar/destruir, set
  transform, aplicar impulsos.
- [ ] `body/body_activation_listener.d`.
- [ ] `island_builder.d` — agrupamento de bodies conectados por contatos
  ou constraints por frame.
- [ ] `physics_system.d` — orquestra broadphase → narrowphase →
  constraints → solver → integração.
- [ ] `physics_update_context.d`, `physics_step_listener.d`.
- [ ] `contact_listener.d`, `physics_scene.d`.

---

## Phase 9 — Migrar demos ⬜

- [ ] `source/demo/benchmark.d` — usar novo `PhysicsSystem` +
  `BodyInterface` para criar as 1000 caixas instanciadas.
- [ ] `source/demo/test_physics.d` — sandbox mínimo (gravity, chão,
  empilhamento) para validação visual.
- [ ] Garantir FPS estável no benchmark (≥ antes do porte).
- [ ] Documentar a API gameplay-facing em `docs/`.

---

## Phase 10 (opcional) — JobSystemTaskPool ⬜

- [ ] `core/job_system_task_pool.d` — thread-pool com worker queues e
  dependências entre jobs.
- [ ] Paralelizar: broadphase batch update, narrowphase por par, solver
  por ilha.
- [ ] Instrumentação / profiling integrado (opcional).

---

## Notas operacionais

- **Verificar builds por fase:**
  ```bash
  dub test --config=library --force
  for cfg in demo benchmark editor game showcase library test-physics; do
    dub build --config=$cfg --force
  done
  ```
- **Reference source:** `ref/JoltPhysics/Jolt/`.
- **Branch:** `ai_reboot` (default: `master`).
- **Política de GC:** engine-core no frame path é `@nogc`; gameplay e
  APIs públicas podem alocar.
