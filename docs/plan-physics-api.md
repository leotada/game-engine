# Plano: API física gameplay (Box3D)

> **Status:** P0–P4 + P6 concluídos · P5 (mesh) adiado · Ver [roadmap.md](roadmap.md)

## Objetivo

Completar a camada D `engine.physics` sobre Box3D para que jogos usem
física sem chamar `bindings.box3d` diretamente — shapes comuns, queries,
joints básicos, character controller e documentação.

Backend: **Box3D** (C). Bindings manuais em `source/bindings/box3d/`.
API gameplay em `source/engine/physics/`.

Guia de uso: [physics-quickstart.md](physics-quickstart.md).

O porte nativo Jolt foi cancelado ([jph-port-plan.md](jph-port-plan.md)).
Benchmark da migração: [physics-box3d-benchmark.md](physics-box3d-benchmark.md).

## Estado atual

| Módulo | Capacidade |
|:---|:---|
| [`world.d`](../source/engine/physics/world.d) | create/destroy world, step, gravity, sleep, CCD, hit threshold |
| [`body.d`](../source/engine/physics/body.d) | box / sphere / capsule / cylinder (static/kinematic/dynamic), sensors, ground slab, velocities, impulses |
| [`events.d`](../source/engine/physics/events.d) | contact begin/end, sensor enter/exit, hit events → `ContactListener` |
| [`queries.d`](../source/engine/physics/queries.d) | `castRayClosest`, `overlapAabb`, `overlapSphere`, query filter |
| [`joints.d`](../source/engine/physics/joints.d) | distance, revolute, weld |
| [`character.d`](../source/engine/physics/character.d) | `CharacterController` (CastMover + CollideMover + SolvePlanes) |
| [`convert.d`](../source/engine/physics/convert.d) | Vec3/Quat ↔ tipos Box3D |

Demos: `pong3d`, `marble_run`, `test_physics_box3d` (smoke estendido).

## Fora de escopo / adiado

- Soft bodies / cloth
- Multithread Box3D além do `workerCount` já exposto no world
- Editor visual de colliders ([plan-editor-ux.md](plan-editor-ux.md))
- **P5** triangle mesh / heightfield (lib tem API; wrapper D ainda não)

## Fases

### P0 — Documentação quickstart

- [x] Seção Physics no [game-development-guide.md](game-development-guide.md)
- [x] `docs/physics-quickstart.md`
- [x] Exemplo mínimo alinhado com demos

**DoD:** quickstart dedicado + link a partir do guide. ✅

### P1 — Completar shapes comuns

- [x] Bindings capsule / cylinder / hull
- [x] Capsule static/dynamic/sensor
- [x] Static / kinematic sphere
- [x] Cylinder via hull
- [x] Smoke em `test_physics_box3d`

**DoD:** ✅

### P2 — Queries

- [x] `overlapAabb` / `overlapSphere`
- [x] Filtro default documentado

**DoD:** ✅

### P3 — Joints

- [x] Bindings + `engine.physics.joints` (distance, revolute, weld)
- [x] Smoke pendulum / hinge em `test_physics_box3d`

**DoD:** ✅

### P4 — Character controller

- [x] `CharacterController` com mover Box3D
- [x] Smoke walk em `test_physics_box3d`

**DoD:** ✅

### P5 — Mesh / terreno (adiado)

- [ ] Triangle mesh estático a partir de `TexMesh` / glTF
- [ ] Heightfield se houver caso de uso

**DoD:** adiado — lib exporta `b3CreateMeshShape`; wrapper D futuro.

### P6 — Limpeza JPH

- [x] Remover `public import engine.jph` de `source/engine/package.d`
- [x] Apagar `source/engine/jph/`
- [x] `import engine;` re-exporta só física Box3D

**DoD:** ✅ (ver commit / tree atual)

## Critérios de aceite

1. Jogo novo: world + bodies + sensors + raycast/overlap + joints + character **sem** `import bindings.box3d`.
2. `docs/physics-quickstart.md` cobre o happy path.
3. `dub build` / `dub run --config=test-physics-box3d` verdes.
4. Nenhum caminho de build trata JPH como backend ativo.

## Referências

- Código: `source/engine/physics/`, `source/bindings/box3d/`
- Demos: `source/demo/pong3d.d`, `marble_run.d`, `test_physics_box3d.d`
- Uso: [physics-quickstart.md](physics-quickstart.md)
- Benchmark: [physics-box3d-benchmark.md](physics-box3d-benchmark.md)
