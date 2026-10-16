# Engine Documentation

Index of documents in `docs/`. Guides describe existing features and architecture; plans describe pending milestones. Overview: [roadmap.md](roadmap.md).

## Guides (Current State)

| Document | Description |
|:---|:---|
| [game-development-guide.md](game-development-guide.md) | How to build a 3D game using the high-level API |
| [physics-quickstart.md](physics-quickstart.md) | Box3D gameplay physics API: world, shapes, sensors, queries, joints, character |
| [graphics.md](graphics.md) | 3-layer GPU architecture (WGPU) |
| [multiplatform-and-shaders.md](multiplatform-and-shaders.md) | Multiplatform support (Wayland/X11, Win32, Android, Metal) & modular shaders with hot-reload |
| [editor-guide.md](editor-guide.md) | Visual editor architecture, panels, play mode, and workflow |
| [scripting-guide.md](scripting-guide.md) | D scripting API, reflection attributes, lifecycle, and hot-reload rules |
| [why-this-is-fast.md](why-this-is-fast.md) | Why the ECS/SoA architecture is fast |
| [incremental-gc-research.md](incremental-gc-research.md) | Garbage collection research, pause metrics, and benchmarks |
| [physics-box3d-benchmark.md](physics-box3d-benchmark.md) | JPH-D vs Box3D physics migration benchmark |

## Roadmap and Plans

| Document | Status | Scope |
|:---|:---|:---|
| [roadmap.md](roadmap.md) | Active | Work backlog, priorities, and implementation order |
| [plan-physics-api.md](plan-physics-api.md) | P0–P4+P6 done; P5 mesh deferred | Complete gameplay API on top of Box3D (#1) |
| [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) | Done (#9 deferred) | GC-safe adoption + static lint (#2) |
| [plan-pbr.md](plan-pbr.md) | Done | PBR + PCF shadow + IBL (#3) |
| [plan-post-processing.md](plan-post-processing.md) | Done | Bloom, tone mapping, FXAA (#4) |
| [plan-animation.md](plan-animation.md) | Pending | Skeletal animation + glTF skinning (#5) |
| [plan-editor-ux.md](plan-editor-ux.md) | Delivered (v1) | Full scene editor UX (#6) |
| [plan-terrain-water.md](plan-terrain-water.md) | Pending | Terrain and water editor (#7) |
| [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md) | In Progress (Shaders done) | Asset and data hot-reload (#8) |
| [plan-parallel-ecs.md](plan-parallel-ecs.md) | Pending | Parallel system scheduler (#9) |
| [plan-networking.md](plan-networking.md) | Pending | Multiplayer primitives (#10) |

## History / Cancelled

| Document | Status | Note |
|:---|:---|:---|
| [jph-port-plan.md](jph-port-plan.md) | **Cancelled** | Jolt→D port abandoned; `engine.jph` tree removed in favor of Box3D (physics P6) |

## Plan Conventions

Every `plan-*.md` document follows:

1. **Objective**
2. **Current State** — with actual repository paths (no overclaiming)
3. **Out of Scope**
4. **Dependencies**
5. **Phases** — each with a single-line **Definition of Done (DoD)**
6. **Acceptance Criteria** (for the entire plan)
7. **Cross References**

**Language**: All documentation, architecture plans, and code comments must be written in English.
When updating any plan, verify the referenced code before marking anything as completed.
