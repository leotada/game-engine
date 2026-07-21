# Plano: Networking

> **Status:** pendente · Prioridade: baixa · Ver [roadmap.md](roadmap.md)

## Objetivo

Primitivas client/server para multiplayer autoritativo: transporte,
serialização POD, tick sync e replicação de entidades — mínimo para
2–8 jogadores em LAN.

## Estado atual

- Engine single-player; **não existe** `engine.net` nem sockets na API
- Componentes já são POD — bom para snapshot/delta
- Física Box3D não é determinística cross-platform por default → v1 =
  servidor autoritativo + interpolation, **não** lockstep

## Fora de escopo

- Matchmaking, relay cloud, anti-cheat avançado
- Replay completo / demo recording (pode reutilizar `engine.ser` depois)
- P2P sem host
- Reliability elaborada (janela grande, NACK streams) — v1 só acks
  seletivos para spawn/despawn/eventos críticos

## Dependências

- Física estável o bastante para o demo escolhido
  ([plan-physics-api.md](plan-physics-api.md))
- Módulo compartilhado futuro **`engine.ser`** (byte writer para `isPod!T`)
  — mesmo núcleo útil para save de cena no
  [plan-editor-ux.md](plan-editor-ux.md); este plano **não** implementa
  `engine.ser` sozinho além do necessário para NET-2

## Fases

### NET-1 — Transporte

- [ ] UDP via sockets POSIX `extern(C)` (sem bindbc)
- [ ] Wrapper `@trusted` mínimo em `engine.net.transport`
- [ ] Ack seletivo opcional só para mensagens críticas

**DoD:** dois processos trocam datagramas em localhost.

### NET-2 — Serialização

- [ ] Bit/byte writer para structs `isPod!T` (embrião de `engine.ser`)
- [ ] EntityId + generation, Vec3/Quat compactados
- [ ] Sem `string` na wire — `StringId` ou IDs de protocolo

**DoD:** round-trip de um componente POD em buffer sem GC.

### NET-3 — Tick model

- [ ] Server tick fixo (30 ou 60 Hz) separado do render
- [ ] Client: input buffer + interpolation
- [ ] Documentar clock vs physics substeps

**DoD:** cliente interpola posição de um body remoto sem stutter óbvio em LAN.

### NET-4 — Replicação

- [ ] Sets always-replicate de componentes
- [ ] Spawn/despawn messages
- [ ] Ownership (quem manda input do pawn)

**DoD:** spawn remoto aparece e some nos dois lados.

### NET-5 — Demo

- [ ] Mini jogo 2 jogadores (variante de `pong3d` ou arena)
- [ ] Host+client processos separados

**DoD:** partida curta jogável em LAN.

## Critérios de aceite

1. Dois processos sincronizam entidades a ≥30 Hz estável em LAN.
2. Payloads são POD (sem GC pointers na wire).
3. Single-player continua zero-cost (networking opt-in).

## Referências

- [plan-physics-api.md](plan-physics-api.md), [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)
- `source/demo/pong3d.d` como candidato a vertical slice
