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
| E1-9  | Migrar `test_physics.d` e `benchmark.d`                           | ✅ Concluída | —         |
| E1-10 | Documentar API gameplay-facing                                    | ⬜ Pendente  | —         |

Status do Épico 1: **17 de 21 fases concluídas**; `E1-P` e `E1-6` seguem em curso, e ainda faltam a query de raycast em cena e a documentação gameplay-facing.

### Épico 2 — Jolt completo (pós-MVP)

Funcionalidades avançadas, ordem sugerida quando o Épico 1 estiver
verde no benchmark. Cada fase deve preservar a API pública estabilizada
no Épico 1 (apenas adiciona).

| #    | Fase                                                              | Estado       |
| ---- | ----------------------------------------------------------------- | ------------ |
| E2-1 | `IslandBuilder` (convergência + sleep correto sob contato)        | ⬜ Pendente  |
| E2-2 | `BroadPhaseQuadTree` (O(n log n))                                 | ⏳ Em curso  |
| E2-3 | SIMD em lote (`RayAABox4`, `RayTriangle4`, `Vec4` ops)            | ⏳ Em curso  |
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
área, line-of-sight). Tudo single-thread, sem joints, sem ilhas; o
caminho padrão do MVP continua no `BroadPhaseGrid` (o `BroadPhaseQuadTree`
já existe como alternativa opcional), sem decorated/compound shapes,
sem mesh/heightfield/softbody.

**Total estimado:** ~4.000 LOC novas (vs ~10.500 do Jolt completo).

### Cortes do Épico 1 (movidos para o Épico 2)

| Adiado para Épico 2                                            | Justificativa                                                                                  |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Decorated shapes (Scaled / RotatedTranslated / OffsetCOM)      | Bodies usam `BoxShape`/`SphereShape`/etc. direto; pose vem do `Body`.                          |
| `StaticCompoundShape` (+ BVH)                                  | Bodies de shape única bastam para o recorte de jogos visado.                                   |
| `ConvexHullShape` (+ builder)                                  | Primitivas cobrem 95% do uso comum.                                                            |
| Manifold clipping convexo genérico                             | Box-vs-Box analítico (SAT + clipping); pares mistos via fallback GJK+EPA.                      |
| `BroadPhaseQuadTree` + `RayAABox4`/`RayTriangle4` SIMD         | `BroadPhaseGrid` segue como default do MVP; o QuadTree já foi iniciado no Épico 2, mas o caminho SIMD ainda fica para depois. |
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

Substitui o brute-force por padrão em `PhysicsSystem`. A versão atual
reconstrói um hash 3D uniforme por frame com query por faixa exata de
células, sem o scan antigo de 27 vizinhos: cada body dinâmico é inserido
nas células que sua AABB cobre; o par só é emitido na célula canônica
compartilhada. Bodies estáticos (ex.: chão 40 m) ficam em lista separada
e são testados diretamente — sem inflar o grid com AABBs enormes.

Complexidade vs brute-force para N dinâmicos + S estáticos:
- Brute-force: O(N × (N+S)) testes de AABB por frame
- Grid:        O(N × (d×c + S)) onde d = diâmetro médio do body em células
               e c = avg de bodies por célula ≪ N

Benchmark medido (1000 dinâmicos, 1 estático, query exata, célula=1m):
≈30 000 testes de AABB por frame vs ≈1 000 000 do brute-force (≈33× menos
trabalho), com saída de ~3 000 pares em vez de ~15 000.

- [x] `broadphase/broad_phase_grid.d` — hash 3D, pool de `CellEntry`,
  `gridCoord()` com floor negativo correto, `cellHash()` com co-primos,
  query por faixa exata e dedup por célula canônica.
- [x] `PhysicsSystem` inicializa com `new BroadPhaseGrid(1.0f)` — célula
  de 1 m com query exata é o default atual do runtime.
- [x] Bodies estáticos separados em `mStaticBodyIDs` dentro do grid.

### E1-P — Tuning de performance ⏳

O grosso do tuning estrutural já entrou no broadphase padrão:

- `BroadPhaseGrid` agora usa query por faixa exata de células e dedup por
  célula canônica compartilhada, eliminando o padrão antigo de 27 vizinhos
  e a inflação de pares duplicados.
- `PhysicsSystem` passou a usar `new BroadPhaseGrid(1.0f)` por padrão.
- O comentário do módulo documenta a nova ordem de grandeza do benchmark:
  ~30 000 testes de AABB/frame e ~3 000 pares no caso de 1000 cubos.

Pendências atuais:

- [x] `broadphase/broad_phase_grid.d` — dedup dinâmico-dinâmico no loop
  principal e query exata de células.
- [ ] `physics_settings.d` — novos defaults: `mBaumgarteERP=0.3f`,
  `mNumPositionIterations=4`, `mNumVelocityIterations=8`.
- [ ] `demo/benchmark.d` — comentário do módulo ainda menciona
  brute-force, embora o runtime use grid.
- [x] `dub run --config=test-physics --force` — sandbox atual executa e
  termina com `PASS`.
- [ ] Benchmark release 12 s — revalidar a meta de fps/avgY com a versão
  atual do grid.
- [ ] Commit após validação.

**Próximo passo de performance após E1-P:** `IslandBuilder` (E2-1) —
resolver sleep/convergência de pilhas densas sem depender só do timer de
repouso por body.

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
- [x] `ContactConstraintManager` ignora manifolds com sensor na fase de
  geração de constraints — sensor continua gerando detecção, mas não
  participa da resposta física.
- [x] `BodyCreationSettings.mUserData` (uint64) — payload livre para o
  jogo associar entidades ECS aos bodies.
- [ ] `collision/contact_listener.d` — interface `ContactListener` com:
  - `OnContactValidate(body1, body2, manifold) -> EValidateResult`
  - `OnContactAdded(body1, body2, manifold, settings)`
  - `OnContactPersisted(body1, body2, manifold, settings)`
  - `OnContactRemoved(SubShapeIDPair)`
- [ ] `PhysicsSystem.SetContactListener(ContactListener)`.
- [ ] Integrar callbacks no fim do narrowphase: emitir `Added`/`Persisted`
  comparando com o cache do `ContactConstraintManager` do frame anterior;
  emitir `Removed` para chaves que desapareceram.
- [ ] Unittest: dois bodies dinâmicos atravessando um sensor disparam
  `OnContactAdded` na entrada e `OnContactRemoved` na saída sem
  alterar velocidades.

Hoje o sandbox `test_physics.d` já valida entrada/saída em sensores por
varredura manual de manifolds; o que falta é transformar isso na API
gameplay-facing via `ContactListener`.

### E1-7 — Scene-level raycast ⬜

`Shape.CastRay` (por-shape) já existe. Falta o nível "consulta na cena":
um raio contra todos os bodies, com filtros e `RayCastResult` agregado.

Hoje `source/demo/test_physics.d` faz isso manualmente: transforma o raio
para o espaço local de cada body e chama `Shape.CastRay` inline. A fase
continua pendente porque esse fluxo ainda não foi encapsulado em
`NarrowPhaseQuery`/`BroadPhase.CastRay`.

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

### E1-9 — Migrar demos ✅

- [x] `source/demo/test_physics.d` — sandbox com gravidade, chão,
  empilhamento, drops simples (sphere/capsule), 1 sensor de área que
  loga entrada/saída e 1 raycast inline por frame. Validado com
  `dub run --config=test-physics --force`.
- [x] `source/demo/benchmark.d` — benchmark visual com cubos dinâmicos +
  chão estático via `BodyInterface`. Compila com
  `dub build --config=benchmark --force`.

### E1-10 — Documentar API gameplay-facing ⬜

- [ ] `docs/physics-quickstart.md` — receita de "como criar um corpo,
  registrar um listener, fazer raycast".
- [ ] Cobertura mínima: `BodyCreationSettings`, `BodyInterface`,
  `ContactListener`, `NarrowPhaseQuery`, `PhysicsSettings`.

### Riscos críticos do Épico 1

1. **Solver PGS (E1-4, já implementado)** — Baumgarte, slop, iterações.
   Pilhas de cubos são o teste-padrão de estabilidade; revisitar se
   `benchmark.d` mostrar jitter.
2. **Sensores / listener (E1-6)** — o solver já ignora constraints de
  sensor, mas ainda falta consolidar a API de callbacks
  `Added`/`Persisted`/`Removed` sobre os manifolds gerados.
3. **Sleep sem ilhas (E1-8)** — sem `IslandBuilder`, ou nada dorme,
   ou tudo dorme cedo demais. Threshold conservador + acordar agressivo.
4. **Tensor de inércia em world-space (E1-5)** — `R · I_local · Rᵀ`
   recalculado todo frame; já implementado em `IntegrateMotion`.

---

## Épico 2 — Implementação completa do Jolt ⏳

Funcionalidades avançadas. Cada fase é aditiva sobre a API estabilizada
no Épico 1 — quem só precisa de "rigid body para jogos" pode parar lá.

### E2-1 — `IslandBuilder` ⬜

- [ ] `island_builder.d` — agrupa bodies conectados por contatos ou
  constraints por frame (union-find sobre pairs).
- [ ] `physics_system.d` — usar ilhas no solver (per-island PGS) e no
  sleep (uma ilha inteira dorme/acorda junta).
- [ ] Reduz jitter em pilhas grandes; pré-requisito para multithread.

### E2-2 — `BroadPhaseQuadTree` ⏳

> **Contexto:** `BroadPhaseGrid` (spatial hash, E1-3b) já substitui o
> brute-force e reduz AABB tests em ≈5×. O QuadTree do Jolt (O(n log n)
> com atualização incremental) é necessário para cenas dinâmicas grandes
> (>5000 bodies móveis) ou para `CastRay` broadphase eficiente.
> Para o benchmark de 1000 cubos, E1-P (dedup + tuning) é suficiente.

- [x] `broad_phase_quad_tree.d` — adapter broadphase com dinâmica/cinética
  no tree e corpos estáticos em lista flat, além de testes integrados via
  `PhysicsSystem.InitWithBroadPhase()`.
- [x] `quad_tree.d` — build O(N log N) por Morton code, nós SoA e query de
  pares para broadphase single-threaded.
- [ ] `broad_phase_layer_interface_table.d` (a versão completa).
- [ ] Queries adicionais (`CastRay`, sphere/box/point) e atualização
  incremental do tree.
- [ ] Tornar o `BroadPhaseQuadTree` o caminho padrão em vez do grid.

### E2-3 — SIMD em lote ⏳

- [ ] `RayAABox4` — interseção com 4 AABoxes em paralelo.
- [ ] `RayTriangle4` — interseção com 4 triângulos em paralelo.
- [x] `UVec4` + subset de comparações/seleções em `Vec3`/`Vec4` já existe
  e é usado por `AABox`, GJK/EPA e utilitários geométricos.
- [ ] Portar o restante necessário para batch broadphase / `MeshShape`.

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
