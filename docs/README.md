# Documentação da Engine

Índice dos documentos em `docs/`. Guias descrevem o que já existe; planos
descrevem o que falta. Visão geral: [roadmap.md](roadmap.md).

## Guias (estado atual)

| Documento | Conteúdo |
|:---|:---|
| [game-development-guide.md](game-development-guide.md) | Como montar um jogo 3D com a API de alto nível |
| [physics-quickstart.md](physics-quickstart.md) | API gameplay Box3D: world, shapes, sensors, queries, joints, character |
| [graphics.md](graphics.md) | Arquitetura GPU (WGPU) em 3 camadas |
| [why-this-is-fast.md](why-this-is-fast.md) | Por que o ECS/SoA é rápido |
| [incremental-gc-research.md](incremental-gc-research.md) | Pesquisa e benchmarks do GC |
| [physics-box3d-benchmark.md](physics-box3d-benchmark.md) | Benchmark JPH-D vs Box3D (migração) |

## Roadmap e planos

| Documento | Status | Escopo |
|:---|:---|:---|
| [roadmap.md](roadmap.md) | ativo | Visão geral do que falta e ordem sugerida |
| [plan-physics-api.md](plan-physics-api.md) | P0–P4+P6 feitos; P5 mesh adiado | Completar API gameplay sobre Box3D (#1) |
| [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) | feito (#9 adiado) | Adoção GC-safe + lint (#2) |
| [plan-pbr.md](plan-pbr.md) | pendente | PBR + PCF shadow + IBL (#3) |
| [plan-post-processing.md](plan-post-processing.md) | pendente | Bloom, tone mapping, FXAA (#4) |
| [plan-animation.md](plan-animation.md) | pendente | Skeletal animation + skin glTF (#5) |
| [plan-editor-ux.md](plan-editor-ux.md) | pendente | Scene editor completo (#6) |
| [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md) | pendente | Hot reload de assets + dados (#7) |
| [plan-parallel-ecs.md](plan-parallel-ecs.md) | pendente | Scheduler paralelo de systems (#8) |
| [plan-networking.md](plan-networking.md) | pendente | Primitivas multiplayer (#9) |

## Histórico / cancelado

| Documento | Status | Nota |
|:---|:---|:---|
| [jph-port-plan.md](jph-port-plan.md) | **cancelado** | Porte Jolt→D abandonado; tree `engine.jph` removida (physics P6) |

## Convenções dos planos

Cada `plan-*.md` (e o checklist do GC) segue:

1. **Objetivo**
2. **Estado atual** — com paths reais de arquivos (não overclaim)
3. **Fora de escopo**
4. **Dependências**
5. **Fases** — cada uma com **DoD** de uma linha
6. **Critérios de aceite** (plano inteiro)
7. **Referências** cruzadas

Idioma: português nos planos ativos. O corpo histórico do GC plan permanece
em inglês; o checklist no topo é a fonte de verdade do progresso.

Ao atualizar um plano, confira o código citado antes de marcar algo como
“já existe”.
