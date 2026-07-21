# Plano: ECS paralelo (scheduler)

> **Status:** pendente · Prioridade: baixa · Ver [roadmap.md](roadmap.md)

## Objetivo

Executar systems independentes em paralelo (stages + waves), com
declaração explícita de leituras/escritas de componentes — sem data races,
respeitando `@safe` e o hot path `@nogc` do core.

**A API serial continua para sempre.** Scheduler é opt-in; jogos atuais
não precisam migrar.

## Estado atual

Paths reais:

- [`ecs/world.d`](../source/engine/ecs/world.d) +
  [`store.d`](../source/engine/ecs/store.d) — sparse-set; sem schedule
- Systems = funções livres; ordem manual no loop do jogo
- Física Box3D pode usar `workerCount` **fora** do ECS
  ([`physics/world.d`](../source/engine/physics/world.d))

## Fora de escopo

- Auto-paralelizar encoding GPU
- Substituir o ECS SoA
- Paralelizar narrowphase em D (backend é Box3D)
- Stages estilo Bevy completos na primeira entrega — só o mínimo abaixo

## Dependências

- Nenhuma feature pendente. Política GC/threads (abaixo) deve estar
  documentada antes de merge.

## Política GC / threads

- Systems `@nogc` no frame path **não** alocam na GC a partir de workers
- Systems com GC só rodam na main thread (ou stage serial marcado)
- Sem compartilhar slices GC entre threads sem sync
- `FrameArena`: uma arena por thread ou só na main — decidir na
  implementação e documentar; default sugerido = arena só na main na v1

## Fases

### ECS-P1 — Modelo de acesso

- [ ] `Reads!T` / `Writes!T` (templates) + validação debug de conflitos
- [ ] Mesmo componente em write → mesma wave serial

**DoD:** unittest falha se dois writers do mesmo `T` forem colocados na
mesma wave.

### ECS-P2 — Schedule mínimo

- [ ] Três stages fixos: `PreUpdate`, `Update`, `PostUpdate`
- [ ] Ordenação topológica dentro do stage
- [ ] Waves paralelas para systems sem conflito

**DoD:** schedule serial (1 thread) produz a mesma ordem estável documentada.

### ECS-P3 — Runtime paralelo

- [ ] Thread pool mínimo (ou `std.parallelism` atrás de wrapper)
- [ ] Barriers entre waves
- [ ] Opt-in: `Schedule.runParallel` vs `runSerial`

**DoD:** dois systems read-only distintos correm em threads diferentes
(assert de thread id em debug).

### ECS-P4 — Integração

- [ ] Hook opcional no game loop / App
- [ ] Benchmark: N systems triviais × 10k+ entities vs serial
- [ ] Guia: como migrar um loop manual

**DoD:** demos existentes sem schedule continuam idênticos.

## Critérios de aceite

1. Writers do mesmo componente nunca correm juntos (testado).
2. Readers independentes podem paralelizar.
3. Build/jogo sem scheduler = comportamento atual (opt-in).
4. Sem regressão nos demos existentes.

## Referências

- `source/engine/ecs/world.d`, `store.d`
- [why-this-is-fast.md](why-this-is-fast.md)
- [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)
