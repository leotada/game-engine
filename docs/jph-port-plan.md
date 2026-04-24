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
| MVP | Caminho mínimo (cubos rígidos)            | ⏳ Em curso  | —         |
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

### Phase 4a.3 — degenerate ✅

- [x] `plane_shape.d` — plano infinito (`MustBeStatic = true`); meio-espaço
  negativo é sólido. Bounds locais artificialmente clipadas a `±halfExtent`
  (default `1000.0f`) para que o broad-phase não precise lidar com infinito.
  `CastRay` analítico: origem em meio-espaço sólido devolve `fraction = 0`;
  caso contrário `fraction = -signedDistance / dot(dir, normal)`. Settings
  validam `mPlane.GetNormal().IsNormalized()`.
- [x] `empty_shape.d` — placeholder sem volume nem colisão; `CastRay` sempre
  retorna `false`. Útil para corpos cinemáticos que só seguram constraints
  ou quando a forma final ainda não é conhecida. `IsValidScale` aceita
  qualquer escala. `GetCenterOfMass` configurável via construtor.

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

## MVP — Caminho mínimo para benchmark de cubos rígidos ⏳

Track paralelo, focado em fechar o primeiro recorte de **corpos rígidos
simples**: `benchmark.d` restaurado, `test_physics.d` headless restaurado,
e suporte de primeira classe para **boxes, spheres, capsules e um chão
plano estático** com gravidade, contatos, atrito e sleeping.
**Sem joints, sem QuadTree, sem decorated/compound shapes, sem SIMD em
lote, sem multithread.** Tudo o que for cortado aqui volta depois numa
fase "post-MVP" sem quebrar a API.

**Total estimado:** ~4.000 LOC novas (vs ~10.500 do plano completo).

### Cortes aceitos para o MVP

| Adiado                                                         | Justificativa                                                                                  |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Phase 4a.4 (Scaled / RotatedTranslated / OffsetCOM)            | Cubos usam `BoxShape` direto; pose vem do `Body`.                                              |
| Phase 4a.5 (StaticCompound + BVH)                              | Bodies de shape única.                                                                         |
| Phase 4b (ConvexHull + builder)                                | Box é primitiva.                                                                               |
| Manifold clipping genérico para qualquer par convexo           | Box-vs-Box fica analítico (SAT + face clipping). Box/Sphere/Capsule mistos podem começar em fallback GJK+EPA. |
| Phase 6 QuadTree + RayAABox4/RayTriangle4                      | `BroadPhaseBruteForce` (O(n²)) basta para 1000 corpos.                                         |
| Phase 7 named constraints (fixed/point/distance/hinge/slider)  | Benchmark não tem joints. Apenas contact constraints.                                          |
| Position solver completo / Baumgarte tunado                    | Começar com PGS de velocidade + projeção de penetração simples; refinar se pilhas instabilizam. |
| IslandBuilder                                                  | Tudo numa única "ilha" global no v1.                                                            |
| Phase 10 JobSystemTaskPool                                     | `JobSystemSingleThreaded` já existe.                                                            |

### Sequência de fases MVP

#### MVP-1 — `MassProperties.Rotate` (mini-4a.4)

- [ ] Portar só `MassProperties.Rotate(Mat44)` em
  `engine.jph.physics.body.massproperties` (~80 LOC). Necessário para
  transformar o tensor de inércia para world-space todo frame.

#### MVP-2 — Narrowphase enxuto

- [ ] `collision/collide_shape.d` — `CollideShapeResult`,
  `CollideShapeSettings`, `ECollisionMode`.
- [x] `collision/object_layer.d` — `ObjectLayer` (uint16) + filtros.
- [x] `collision/broad_phase_layer.d` — `BroadPhaseLayer` (uint8) +
  interface mínima.
- [ ] `collision/collide_box_vs_box.d` — manifold SAT analítico
  (15 eixos, edge-edge via cross-product, face clipping
  Sutherland–Hodgman + redução para ≤4 contatos persistentes).
- [ ] `collision/collide_box_vs_plane.d`,
  `collision/collide_sphere_vs_plane.d`,
  `collision/collide_capsule_vs_plane.d` — contatos analíticos para o
  conjunto mínimo suportado pelo sandbox.
- [ ] `collision/collide_convex_vs_convex.d` — fallback genérico via
  GJK + EPA da Phase 2 (cobre Box/Sphere/Capsule mistos enquanto o
  narrowphase específico não chega).
- [ ] `collision/collision_dispatch.d` — tabela 2×2 inicial (Box×Box,
  Box×Plane); resto cai no fallback GJK+EPA.

#### MVP-3 — BroadPhase brute-force

- [x] `broadphase/broad_phase.d` — interface base.
- [x] `broadphase/broad_phase_brute_force.d` — varredura O(n²) sobre
  `Body[]` AABB list, gera `BodyPair[]` ativo por frame.

#### MVP-4 — ContactConstraintManager + solver

- [ ] `physics_settings.d` — steps, slop, baumgarte, iterations.
- [ ] `constraints/contact_constraint_manager.d` — por contato:
  jacobianos normal + 2 atritos; cache de warm-start chaveado por
  `SubShapeIDPair`; PGS sequencial (8 iters velocidade, 2 iters
  posição). **Maior risco do MVP:** estabilidade do solver determina
  se pilhas de cubos descansam sem jitter.

#### MVP-5 — BodyManager + PhysicsSystem (mini-Phase 8)

- [x] `body/body.d` — composição final (transform, shape ref,
  motion props ptr, layers, flags).
- [x] `body/body_manager.d` — pool SoA de `Body` + `MotionProperties`,
  free-list de `BodyID`s.
- [x] `body/body_creation_settings.d`.
- [x] `body/body_interface.d` — API pública (`AddBody`, `RemoveBody`,
  `SetPosition`, `SetLinearVelocity`, `ActivateBody`, …).
- [ ] `physics_system.d` — orquestra: integrar forças → broadphase →
  narrowphase → solver de contatos → integrar velocidades →
  atualizar transforms → timers de sleep. **Sem IslandBuilder no v1.**
- [x] Estado atual de `physics_system.d`: owner mínimo de `BodyManager` +
  `BodyInterface` + `BroadPhaseBruteForce`, com coleta de `BodyPair[]`
  e atualização de `broadphasePairs` nas estatísticas.
- [ ] Sleep simples: threshold de velocidade + timer por body
  (sem ilhas).

#### MVP-6 — Migrar demos

- [ ] `source/demo/test_physics.d` — sandbox (gravidade, chão,
  empilhamento, além de drops simples de sphere/capsule) para validação
  rápida.
- [ ] `source/demo/benchmark.d` — 1000 cubos dinâmicos + chão
  estático via novo `BodyInterface`. FPS deve igualar ou superar a
  versão pré-porte.
- [ ] Documentar a API gameplay-facing em `docs/`.

### Riscos críticos do MVP

1. **Solver PGS (MVP-4)** — Baumgarte, slop, número de iterações.
   Pilhas de cubos são o teste-padrão de estabilidade.
2. **Manifold SAT Box-vs-Box (MVP-2)** — contatos persistentes
   precisam de face clipping correto para a pilha não vibrar.
   Referência: `ref/JoltPhysics/Jolt/Physics/Collision/Shape/BoxShape.cpp`
   (`sCollideBoxVsBox`).
3. **Tensor de inércia em world-space (MVP-5)** — `R · I_local · Rᵀ`
   precisa ser recalculado todo frame para corpos rotacionados.
4. **Sleep sem ilhas (MVP-5)** — sem IslandBuilder, ou nada dorme,
   ou tudo dorme cedo demais. Ajustar threshold conservador.

### Reincorporação pós-MVP (ordem sugerida)

Quando o benchmark estiver verde, retomar o plano completo nesta ordem
(sem quebrar a API gameplay-facing já estabilizada):

1. **IslandBuilder** → convergência do solver + sleeping correto sob
   contato sustentado.
2. **BroadPhaseQuadTree** (Phase 6) → de O(n²) para O(n log n).
3. **RayAABox4 / RayTriangle4** (SIMD) → raycasts contra árvore.
4. **Decorated shapes (4a.4)** + **StaticCompound (4a.5)** → autoria de
   shapes não-cubo.
5. **Named constraints (Phase 7 completa)** → joints.
6. **`ConvexHullShape` (4b)** → autoria de convexos arbitrários.
7. **JobSystemTaskPool (Phase 10)** → multithread.

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
