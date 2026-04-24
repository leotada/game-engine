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

## Estrutura em dois épicos

O porte está organizado em **dois épicos** com escopos bem separados:

### Épico 1 — Rigid body para jogos (foco atual)

Conjunto mínimo, mas completo, para jogos que usam física de
várias maneiras: muitos corpos rígidos colidindo a 60+ FPS, gatilhos
(sensors) e raycast contra a cena. Sem joints, sem ilhas, sem
multithread, sem QuadTree, sem mesh/heightfield/softbody, sem decorated
ou compound shapes. **Tudo o que ficar de fora vai para o Épico 2 sem
quebrar a API gameplay-facing definida aqui.**

| #     | Fase                                                              | Estado       | Commit    |
| ----- | ----------------------------------------------------------------- | ------------ | --------- |
| 0     | Backup + remoção do `engine.physics`                              | ✅ Concluída | `7ce026b` |
| 1     | `jph.core` (Ref, Array, JobSystem, …)                             | ✅ Concluída | `0fe3b25` |
| 2a    | `jph.geometry` primitives + GJK                                   | ✅ Concluída | `5fd5f5c` |
| 2b    | `jph.geometry` EPA + raios                                        | ✅ Concluída | `17d259a` |
| 3     | `jph.physics.body` (IDs, MP, enums, MotionProperties)             | ✅ Concluída | `a325c5a` |
| 4a.0  | Shape base + infra (`Shape`, `ShapeSettings`, `SubShapeID`, …)    | ✅ Concluída | —         |
| 4a.1  | `ConvexShape` + Sphere/Box/Capsule                                | ✅ Concluída | —         |
| 4a.2  | Cylinder, TaperedCylinder, TaperedCapsule, Triangle               | ✅ Concluída | —         |
| 4a.3  | Degenerate (`PlaneShape`, `EmptyShape`)                           | ✅ Concluída | —         |
| E1-1  | `MassProperties.Rotate`                                           | ✅ Concluída | —         |
| E1-2  | Narrowphase enxuto (Box/Sphere/Capsule × Box/Plane + GJK fallback)| ✅ Concluída | —         |
| E1-3  | Broadphase brute-force                                            | ✅ Concluída | —         |
| E1-3b | `BroadPhaseGrid` (spatial hash O(n·k))                            | ✅ Concluída | —         |
| E1-P  | Tuning de performance (dedup pares, ERP, iterações)               | ⏳ Em curso  | —         |
| E1-4  | `ContactConstraintManager` + solver PGS                           | ✅ Concluída | —         |
| E1-5  | `BodyManager` + `BodyInterface` + `PhysicsSystem.Step()`          | ✅ Concluída | —         |
| E1-6  | Sensores (triggers) + `ContactListener`                           | ⏳ Em curso  | —         |
| E1-7  | Scene-level raycast (`NarrowPhaseQuery.CastRay`)                  | ⬜ Pendente  | —         |
| E1-8  | Sleep simples (sem ilhas)                                         | ✅ Concluída | —         |
| E1-9  | Migrar `test_physics.d` e `benchmark.d`                           | ⬜ Pendente  | —         |
| E1-10 | Documentar API gameplay-facing                                    | ⬜ Pendente  | —         |

Status do Épico 1: **17 de 21 fases concluídas** (E1-P em curso); faltam raycast de cena, migração dos demos e tuning de performance.

### Épico 2 — Jolt completo (pós-MVP)

Funcionalidades avançadas, ordem sugerida quando o Épico 1 estiver
verde no benchmark. Cada fase deve preservar a API pública estabilizada
no Épico 1 (apenas adiciona).

| #    | Fase                                                              | Estado       |
| ---- | ----------------------------------------------------------------- | ------------ |
| E2-1 | `IslandBuilder` (convergência + sleep correto sob contato)        | ⬜ Pendente  |
| E2-2 | `BroadPhaseQuadTree` (O(n log n))                                 | ⬜ Pendente  |
| E2-3 | SIMD em lote (`RayAABox4`, `RayTriangle4`, `Vec4` ops)            | ⬜ Pendente  |
| E2-4 | Decorated shapes (Scaled, RotatedTranslated, OffsetCOM)           | ⬜ Pendente  |
| E2-5 | `StaticCompoundShape` (BVH)                                       | ⬜ Pendente  |
| E2-6 | Named constraints (Fixed, Point, Distance, Hinge, Slider, …)      | ⬜ Pendente  |
| E2-7 | `ConvexHullShape` + builder                                       | ⬜ Pendente  |
| E2-8 | `MeshShape`, `HeightFieldShape`, `MutableCompoundShape`           | ⬜ Pendente  |
| E2-9 | `SoftBodyShape` + soft body solver                                | ⬜ Pendente  |
| E2-10| `JobSystemTaskPool` (multithread)                                 | ⬜ Pendente  |
| E2-11| Double-precision world + serialização + step listeners            | ⬜ Pendente  |

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

## Épico 1 — Rigid body para jogos ⏳

Foco: corpos rígidos suficientes para jogos que usam física de várias
maneiras (plataformas, puzzles, ragdoll-leve, projéteis, gatilhos de
área, line-of-sight). Tudo single-thread, sem joints, sem ilhas, sem
QuadTree, sem decorated/compound shapes, sem mesh/heightfield/softbody.

**Total estimado:** ~4.000 LOC novas (vs ~10.500 do Jolt completo).

### Cortes do Épico 1 (movidos para o Épico 2)

| Adiado para Épico 2                                            | Justificativa                                                                                  |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Decorated shapes (Scaled / RotatedTranslated / OffsetCOM)      | Bodies usam `BoxShape`/`SphereShape`/etc. direto; pose vem do `Body`.                          |
| `StaticCompoundShape` (+ BVH)                                  | Bodies de shape única bastam para o recorte de jogos visado.                                   |
| `ConvexHullShape` (+ builder)                                  | Primitivas cobrem 95% do uso comum.                                                            |
| Manifold clipping convexo genérico                             | Box-vs-Box analítico (SAT + clipping); pares mistos via fallback GJK+EPA.                      |
| `BroadPhaseQuadTree` + `RayAABox4`/`RayTriangle4` SIMD         | `BroadPhaseGrid` (hash espacial) já implementado; QuadTree é Épico 2.                          |
| Named constraints (fixed/point/distance/hinge/slider)          | Sem joints no recorte.                                                                         |
| `IslandBuilder`                                                | Tudo numa única "ilha" global; sleep apenas por timer.                                         |
| `JobSystemTaskPool`                                            | `JobSystemSingleThreaded` já existe e cobre o recorte.                                         |
| Mesh / HeightField / SoftBody                                  | Não são necessários para o conjunto de jogos visado.                                           |

### E1-1 — `MassProperties.Rotate` ✅

- [x] `MassProperties.Rotate(Mat44)` em
  `engine.jph.physics.body.massproperties` para transformar o tensor
  de inércia para world-space todo frame.

### E1-2 — Narrowphase enxuto ✅

- [x] `collision/collide_shape.d` — `CollideShapeResult`,
  `CollideShapeSettings`, `ECollisionMode`.
- [x] `collision/object_layer.d` — `ObjectLayer` (uint16) + filtros.
- [x] `collision/broad_phase_layer.d` — `BroadPhaseLayer` (uint8) +
  interface mínima.
- [x] `collision/collide_box_vs_box.d` — manifold SAT analítico
  (15 eixos, edge-edge via cross-product, face clipping
  Sutherland–Hodgman + redução para ≤4 contatos persistentes).
- [x] `collision/collide_box_vs_plane.d`,
  `collision/collide_sphere_vs_plane.d`,
  `collision/collide_capsule_vs_plane.d` — contatos analíticos para o
  conjunto suportado.
- [x] `collision/collide_convex_vs_convex.d` — fallback genérico via
  GJK + EPA da Phase 2 (cobre Box/Sphere/Capsule mistos).
- [x] `collision/collision_dispatch.d` — tabela de despachos com
  fallback GJK+EPA.

### E1-3 — Broadphase brute-force ✅

- [x] `broadphase/broad_phase.d` — interface base.
- [x] `broadphase/broad_phase_brute_force.d` — varredura O(n²) sobre
  `Body[]` AABB list, gera `BodyPair[]` ativo por frame.

### E1-3b — `BroadPhaseGrid` (spatial hash) ✅

Substitui o brute-force por padrão em `PhysicsSystem`. Hash 3D uniforme
com tabela open-addressed (`HASH_SIZE=8192`): cada body dinâmico é
inserido nas células que sua AABB cobre (até 8 células); narrowphase
recebe apenas pares de corpos em células vizinhas (27-cell neighborhood).
Bodies estáticos (ex.: chão 40 m) ficam em lista separada e são testados
diretamente — sem inflar o grid com AABBs enormes.

Complexidade vs brute-force para N dinâmicos + S estáticos:
- Brute-force: O(N × (N+S)) testes de AABB por frame
- Grid:        O(N × (k×27 + S)) onde k = avg de bodies por célula ≪ N

Benchmark medido (1000 dinâmicos, 1 estático, célula=2m): ≈200 000 testes
de AABB por frame vs ≈1 000 000 do brute-force (≈5× menos trabalho).

- [x] `broadphase/broad_phase_grid.d` — hash 3D, pool de `CellEntry`,
  `gridCoord()` com floor negativo correto, `cellHash()` com co-primos.
- [x] `PhysicsSystem` inicializa com `new BroadPhaseGrid(2.0f)` — célula
  de 2 m é ótima para corpos de 1 m com spacing ≥ 1 m.
- [x] Bodies estáticos separados em `mStaticBodyIDs` dentro do grid.

### E1-P — Tuning de performance ⏳

Diagnóstico do benchmark de 1000 cubos (release, 12 s, `BroadPhaseGrid`):

| t (s) | fps  | pairs  | manifolds | avgY  |
|------:|-----:|-------:|----------:|------:|
|   2.1 | 29.7 |  5 941 |     2 254 |  4.74 |
|   4.1 | 10.0 | 10 653 |     2 487 |  3.48 |
|  12.1 | 10.0 | 15 209 |     3 705 |  1.12 |

**Problema 1 — pares duplicados no broadphase (2× inflação)**

`BroadPhaseGrid.FindCollidingPairs` emite o par (A,B) quando processa A
e também (B,A) quando processa B. A narrowphase executa `CollideBoxVsBox`
para ambos, dobrando o custo. O `ContactConstraintManager` absorve o
duplicado via cache, mas o custo da narrowphase já foi pago.

Fix (O(1)): dentro do loop de vizinhança do grid, adicionar guard:
```d
if (entry.bodyID.GetIndex() <= bodyID1.GetIndex()) {
    idx = entry.next;
    continue; // apenas emite pares canônicos (menor_idx, maior_idx)
}
```
Efeito esperado: pairs 15 000 → ~7 500; manifolds e fps proporcionais.

**Problema 2 — avgY caindo (cubos afundando 1,12 m em 12 s)**

Causa: `mBaumgarteERP=0.2` corrige apenas 20 % da penetração por step;
`mNumPositionIterations=2` é insuficiente para pilhas de 10 camadas.

Fix: ajustar `physics_settings.d`:
- `mBaumgarteERP` 0.2 → 0.3
- `mNumPositionIterations` 2 → 4
- `mNumVelocityIterations` 10 → 8 (reduz custo sem perder estabilidade
  após a correção do dedup)

**Problema 3 — nenhum body dormindo (`active=1000` ao final)**

Sleep por timer não funciona em pilhas densas: o corpo de baixo
continua recebendo impulsos dos de cima → timer nunca estoura.
Requer `IslandBuilder` (E2-1) para detectar ilhas estabilizadas e
dormir o grupo inteiro de uma vez.

**Tarefas:**

- [ ] `broadphase/broad_phase_grid.d` — dedup por índice no loop de
  vizinhança dinâmico-dinâmico.
- [ ] `physics_settings.d` — novos defaults: `mBaumgarteERP=0.3f`,
  `mNumPositionIterations=4`, `mNumVelocityIterations=8`.
- [ ] `demo/benchmark.d` — corrigir comentário do módulo (usa grid, não
  brute-force).
- [ ] `dub run --config=test-physics --force` — assertions devem passar.
- [ ] Benchmark release 12 s — meta: fps ≥ 20, avgY ≥ 3.0 ao final.
- [ ] Commit após validação.

**Próximo passo de performance após E1-P:** `IslandBuilder` (E2-1) —
habilita sleep por ilha e reduz `mActiveBodies` de 1000 → ~200 em 12 s,
com ganho de fps proporcional.

### E1-4 — `ContactConstraintManager` + solver PGS ✅

- [x] `physics_settings.d` — steps, slop, baumgarte, iterations.
- [x] `constraints/contact_constraint_manager.d` — por contato:
  jacobianos normal + 2 atritos; cache de warm-start chaveado por
  `SubShapeIDPair`; PGS sequencial (8 iters velocidade, 2 iters
  posição) com warm-start por ponto mais próximo (5 cm threshold).

### E1-5 — `BodyManager` + `BodyInterface` + `PhysicsSystem.Step()` ✅

- [x] `body/body.d` — composição final (transform, shape ref,
  motion props ptr, layers, flags, `mIsSensor`).
- [x] `body/body_manager.d` — pool SoA de `Body` + `MotionProperties`,
  free-list de `BodyID`s.
- [x] `body/body_creation_settings.d`.
- [x] `body/body_interface.d` — API pública (`AddBody`, `RemoveBody`,
  `SetPosition`, `SetLinearVelocity`, `ActivateBody`, …).
- [x] `physics_system.d` — `Step(dt, settings)` orquestra:
  forças → broadphase → narrowphase → solver de contatos →
  integração → atualização de transforms.

### E1-6 — Sensores (triggers) + `ContactListener` ⏳

Triggers são corpos com `mIsSensor = true`: detectam sobreposição mas
não geram resposta de contato. O `ContactListener` é a maneira
gameplay-facing de reagir a colisões e a entradas/saídas em sensores.

- [x] `Body.IsSensor()` + flag `mIsSensor` em `BodyCreationSettings`.
- [x] Filtro em `Body.sFindCollidingPairsCanCollide` — sensores
  não colidem com kinematicos passivos.
- [ ] `collision/contact_listener.d` — interface `ContactListener` com:
  - `OnContactValidate(body1, body2, manifold) -> EValidateResult`
  - `OnContactAdded(body1, body2, manifold, settings)`
  - `OnContactPersisted(body1, body2, manifold, settings)`
  - `OnContactRemoved(SubShapeIDPair)`
- [ ] `PhysicsSystem.SetContactListener(ContactListener)`.
- [ ] Integrar callbacks no fim do narrowphase: emitir `Added`/`Persisted`
  comparando com o cache do `ContactConstraintManager` do frame anterior;
  emitir `Removed` para chaves que desapareceram.
- [ ] Skip da geração de constraints quando `body1.IsSensor() || body2.IsSensor()`
  — só dispara o callback (`OnContactAdded`/`Persisted`/`Removed`).
- [ ] `BodyCreationSettings.mUserData` (uint64) — payload livre para o
  jogo associar entidades ECS aos bodies.
- [ ] Unittest: dois bodies dinâmicos atravessando um sensor disparam
  `OnContactAdded` na entrada e `OnContactRemoved` na saída sem
  alterar velocidades.

### E1-7 — Scene-level raycast ⬜

`Shape.CastRay` (por-shape) já existe. Falta o nível "consulta na cena":
um raio contra todos os bodies, com filtros e `RayCastResult` agregado.

- [ ] `collision/ray_cast.d` — `RRayCast` (origem world-space + direção),
  `RayCastSettings` (`mTreatConvexAsSolid`, `mBackFaceMode`).
- [ ] `collision/cast_result.d` — `RayCastResult` agregado com `mBodyID`,
  `mSubShapeID2`, `mFraction`. (Já existe per-shape; estender para
  carregar `BodyID`.)
- [ ] `collision/cast_collector.d` — interface `CastRayCollector` +
  implementações `ClosestHitCollisionCollector`,
  `AnyHitCollisionCollector`, `AllHitCollisionCollector`.
- [ ] `collision/narrow_phase_query.d` — `NarrowPhaseQuery` com:
  - `CastRay(RRayCast, ref RayCastResult, BroadPhaseLayerFilter,
    ObjectLayerFilter, BodyFilter, ShapeFilter) -> bool`
    (atalho closest-hit).
  - `CastRay(RRayCast, RayCastSettings, CastRayCollector, …)`
    (versão completa).
  - Usa `BroadPhase.CastRay` (a adicionar) → para cada body candidato,
    transforma o raio para local-space e chama `Shape.CastRay`.
- [ ] `BroadPhase.CastRay(ray, collector, …)` — no `BroadPhaseBruteForce`,
  varre todos os bodies e usa `RayAABox` per-body como early-out.
- [ ] `PhysicsSystem.GetNarrowPhaseQuery()` — exposição da query.
- [ ] Unittest: raio contra cena com 5 bodies (esfera, caixa, cápsula,
  plano, sensor) — closest-hit retorna o mais próximo, `BodyFilter`
  ignora bodies específicos, sensor é ignorável via `ShapeFilter`.

### E1-8 — Sleep simples (sem ilhas) ✅

- [x] `mVelocitySleepThreshold` e `mTimeBeforeSleep` já existiam em `PhysicsSettings`.
- [x] Loop de sleep-check em `PhysicsSystem.Step()`: acumula `mSleepTestTimer` via
  `AccumulateSleepTime(dt, mTimeBeforeSleep)` enquanto `|v|² + |ω|² < threshold²`;
  ao estourar, zeraa velocidades e chama `DeactivateBody()`.
- [x] Body acorda ao receber contato (wake-on-contact loop pós-manifold), ou via
  `SetLinearVelocity`/`SetAngularVelocity`/`SetPosition`/`AddForce` (já existentes em
  `BodyInterface`).
- [x] `GetNumActiveBodies()` já refletia apenas bodies no array ativo (sem alterações).
- [x] Dois unittests em `physics_system.d`: sleep por timer e wake por `SetLinearVelocity`.

### E1-9 — Migrar demos ⬜

- [ ] `source/demo/test_physics.d` — sandbox com gravidade, chão,
  empilhamento, drops simples (sphere/capsule), 1 sensor de área que
  loga entrada/saída, 1 raycast por frame para detectar "chão".
- [ ] `source/demo/benchmark.d` — 1000 cubos dinâmicos + chão estático
  via `BodyInterface`. FPS deve igualar ou superar a versão pré-porte.

### E1-10 — Documentar API gameplay-facing ⬜

- [ ] `docs/physics-quickstart.md` — receita de "como criar um corpo,
  registrar um listener, fazer raycast".
- [ ] Cobertura mínima: `BodyCreationSettings`, `BodyInterface`,
  `ContactListener`, `NarrowPhaseQuery`, `PhysicsSettings`.

### Riscos críticos do Épico 1

1. **Solver PGS (E1-4, já implementado)** — Baumgarte, slop, iterações.
   Pilhas de cubos são o teste-padrão de estabilidade; revisitar se
   `benchmark.d` mostrar jitter.
2. **Sensores no dispatch (E1-6)** — sensor não pode entrar no
   `ContactConstraintManager`, mas precisa gerar manifolds para o
   listener. Dois caminhos no narrowphase ou um flag no manifold.
3. **Sleep sem ilhas (E1-8)** — sem `IslandBuilder`, ou nada dorme,
   ou tudo dorme cedo demais. Threshold conservador + acordar agressivo.
4. **Tensor de inércia em world-space (E1-5)** — `R · I_local · Rᵀ`
   recalculado todo frame; já implementado em `IntegrateMotion`.

---

## Épico 2 — Implementação completa do Jolt ⬜

Funcionalidades avançadas. Cada fase é aditiva sobre a API estabilizada
no Épico 1 — quem só precisa de "rigid body para jogos" pode parar lá.

### E2-1 — `IslandBuilder` ⬜

- [ ] `island_builder.d` — agrupa bodies conectados por contatos ou
  constraints por frame (union-find sobre pairs).
- [ ] `physics_system.d` — usar ilhas no solver (per-island PGS) e no
  sleep (uma ilha inteira dorme/acorda junta).
- [ ] Reduz jitter em pilhas grandes; pré-requisito para multithread.

### E2-2 — `BroadPhaseQuadTree` ⬜

> **Contexto:** `BroadPhaseGrid` (spatial hash, E1-3b) já substitui o
> brute-force e reduz AABB tests em ≈5×. O QuadTree do Jolt (O(n log n)
> com atualização incremental) é necessário para cenas dinâmicas grandes
> (>5000 bodies móveis) ou para `CastRay` broadphase eficiente.
> Para o benchmark de 1000 cubos, E1-P (dedup + tuning) é suficiente.

- [ ] `broad_phase_quad_tree.d` — árvore de 4 filhos com nós SoA.
- [ ] `quad_tree.d` — insert/remove/update em batch, cast ray /
  sphere / box / point.
- [ ] `broad_phase_layer_interface.d`,
  `broad_phase_layer_interface_table.d` (a versão completa).
- [ ] Substitui `BroadPhaseGrid` (que fica disponível para debug/small scenes).

### E2-3 — SIMD em lote ⬜

- [ ] `RayAABox4` — interseção com 4 AABoxes em paralelo.
- [ ] `RayTriangle4` — interseção com 4 triângulos em paralelo.
- [ ] `UVec4` / `Vec4.sMin/sMax/sSelect/sAnd/sOr` que forem necessários.
- [ ] Usados pela `QuadTree` (E2-2) e pelo `MeshShape` (E2-8).

### E2-4 — Decorated shapes ⬜

- [ ] `scaled_shape.d` (requer `MassProperties.Scale`).
- [ ] `rotated_translated_shape.d`.
- [ ] `offset_center_of_mass_shape.d`.

### E2-5 — `StaticCompoundShape` ⬜

- [ ] `static_compound_shape.d` com partição BVH (sort+mediana, não SAH).

### E2-6 — Named constraints ⬜

- [ ] `constraints/constraint.d` — base + `ConstraintSettings`.
- [ ] `fixed_constraint.d`, `point_constraint.d`,
  `distance_constraint.d`, `hinge_constraint.d`,
  `slider_constraint.d`, `cone_constraint.d`,
  `swing_twist_constraint.d`, `six_dof_constraint.d`.
- [ ] `constraint_manager.d` (solver de constraints integrado às ilhas
  do E2-1).
- [ ] `penetration_axis.d`, `estimate_collision_response.d`.

### E2-7 — `ConvexHullShape` + builder ⬜

- [ ] `convex_hull_shape.d` — points + faces + edges (geração offline).
- [ ] `engine.jph.geometry.convex_hull_builder` (~800 LOC).

### E2-8 — Mesh / HeightField / MutableCompound ⬜

- [ ] `mesh_shape.d` — BVH de triângulos para terreno/colisão estática.
- [ ] `height_field_shape.d` — campo de alturas comprimido.
- [ ] `mutable_compound_shape.d` — compound editável em runtime.

### E2-9 — `SoftBodyShape` ⬜

- [ ] `soft_body_shape.d` + soft body solver (XPBD ou similar).

### E2-10 — `JobSystemTaskPool` ⬜

- [ ] `core/job_system_task_pool.d` — thread-pool com worker queues e
  dependências entre jobs.
- [ ] Paralelizar: broadphase batch update, narrowphase por par, solver
  por ilha.
- [ ] Instrumentação / profiling integrado (opcional).

### E2-11 — Double-precision + serialização + step listeners ⬜

- [ ] World em `double` (`RVec3`/`DVec3`) para mundos grandes.
- [ ] `physics_scene.d` + serialização binária.
- [ ] `physics_step_listener.d`, `body_activation_listener.d`.

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
