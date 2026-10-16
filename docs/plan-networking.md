# Plan: Networking

> **Status:** pending · Priority: low · See [roadmap.md](roadmap.md)

## Objective

Authoritative client/server multiplayer primitives: transport, POD serialization, tick synchronization, and entity state replication — minimum baseline for 2–8 players over LAN.

## Current State

- The engine is single-player; `engine.net` and sockets do not exist in the public API.
- ECS components are already POD — excellent for binary snapshotting and delta compression.
- Box3D physics is not cross-platform deterministic by default → v1 targets **authoritative server + client-side interpolation**, not lockstep simulation.

## Out of Scope

- Matchmaking services, cloud relay servers, advanced anti-cheat
- Complete game replay / demo recording
- Peer-to-peer (P2P) mesh architectures
- Complex reliability protocols (large sliding windows, NACK streams) — v1 uses selective ACKs for entity spawn, despawn, and critical game events

## Dependencies

- Stable physics simulation for the chosen demo ([plan-physics-api.md](plan-physics-api.md))
- Binary byte serializer for `isPod!T` types

## Phases

### NET-1 — Low-Level Transport

- [ ] UDP via POSIX `extern(C)` sockets (no third-party dependencies)
- [ ] Minimal `@trusted` wrapper in `engine.net.transport`
- [ ] Non-blocking I/O with selective ACK headers for critical messages

**DoD:** Two separate local processes exchange UDP datagrams over localhost.

### NET-2 — POD Serialization

- [ ] Bit/byte stream writer for `isPod!T` structs
- [ ] Compact serialization for `EntityId`, `Vec3`, and `Quat`
- [ ] Zero `string` types on the wire — protocol IDs or fixed buffers only

**DoD:** Round-trip serialization of a POD component buffer with zero GC allocations.

### NET-3 — Fixed Tick Model

- [ ] Fixed server simulation tick rate (30 or 60 Hz) decoupled from display refresh
- [ ] Client input queue buffer + snapshot interpolation
- [ ] Documented clock synchronization vs physics substeps

**DoD:** Client smoothly interpolates the position of a remote physics body without stuttering over a local network.

### NET-4 — Entity Replication

- [ ] Replication sets for active gameplay components
- [ ] Entity spawn and despawn protocol packets
- [ ] Authority and ownership tracking (assigning client input to pawns)

**DoD:** Remotely spawned entity appears, updates, and despawns consistently on both host and client.

### NET-5 — Multiplayer Demo

- [ ] 2-player mini-game (e.g. 3D Pong or arena combat)
- [ ] Standalone dedicated host and client binaries

**DoD:** A playable 2-player match runs smoothly over LAN.

## Acceptance Criteria

1. Two processes synchronize replicated entities at ≥ 30 Hz stably over LAN.
2. Network payloads are strictly POD without GC pointers.
3. Single-player performance remains completely unaffected (networking is 100% opt-in).

## References

- [plan-physics-api.md](plan-physics-api.md)
- [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)
