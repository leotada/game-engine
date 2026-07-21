# Plano: Animação skeletal

> **Status:** pendente · Prioridade: média · Ver [roadmap.md](roadmap.md)

## Objetivo

Skinning GPU a partir de glTF: joints, weights, inverse bind matrices,
clips e amostragem por tempo — suficiente para personagens e props
animados.

API escolhida: **componentes ECS POD** (`SkeletonPose`, `AnimationPlayer`),
não uma classe `AnimatedModel`.

## Estado atual

Paths reais:

- [`assets/gltf.d`](../source/engine/assets/gltf.d) — mesh estático → `TexMesh`;
  sem `JOINTS_0` / `WEIGHTS_0`, sem `skin`, sem `animations`, sem `.glb`
- Sem pipeline de vertex skinning
- [`scene/graph.d`](../source/engine/scene/graph.d) — hierarquia de transforms;
  **não** é skeleton

## Fora de escopo

- Morph targets / blend shapes (fase posterior)
- Retargeting entre skeletons
- Ragdoll físico — **bloqueado** em joints Box3D
  ([plan-physics-api.md](plan-physics-api.md) P3); não faz parte deste plano

## Dependências

- glTF loader atual (estender)
- [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) — poses/clips
  em storage engine devem ser `isPod`

## Fases

### AN-1 — Dados POD

- [ ] `Skeleton` / joints por índice (sem class refs)
- [ ] `Skin` — IBM + joint indices
- [ ] `AnimationClip` — keyframes em buffers contíguos
- [ ] `StringId` para nomes de joints/clips
- [ ] Componentes: `SkeletonPose`, `AnimationPlayer`

**DoD:** tipos compilam com `isPod` / `Pod!T` onde vivem no ECS.

### AN-2 — Loader glTF

- [ ] Parse skins + accessors JOINTS/WEIGHTS
- [ ] Parse animations (LINEAR; CUBICSPLINE depois se necessário)
- [ ] Asset de teste documentado (path sob `assets/` ou URL fixa no doc)

**DoD:** load de 1 glTF skinned popula `Skin` + clips sem render ainda.

### AN-3 — Avaliação de pose

- [ ] Sample clip(s) → local transforms → world matrices do skeleton
- [ ] Blend de 2 clips (lerp/slerp) mínimo
- [ ] `@nogc` no hot path; scratch via `FrameArena` se precisar

**DoD:** matrizes de bone mudam com o tempo em unittest/demo headless.

### AN-4 — Skinning GPU

- [ ] Vertex shader com UBO/storage de bone matrices
- [ ] Pipeline dedicado ou flag no textured pipeline
- [ ] Limite de bones documentado

**DoD:** mesh skinned renderiza na pose amostrada.

### AN-5 — Demo

- [ ] Systems que atualizam `AnimationPlayer` / `SkeletonPose`
- [ ] Demo: personagem idle/walk ou prop animado

**DoD:** `dub run` de uma config mostra animação looping.

## Critérios de aceite

1. Modelo glTF com skin reproduz a animação de referência.
2. Pose evaluation + upload de bones no frame path `@nogc`.
3. Componentes de animação são POD no ECS.

## Referências

- `source/engine/assets/gltf.d`, `graphics/texmesh.d`, `scene/graph.d`
- [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)
