# Roadmap — o que falta

Visão consolidada do trabalho restante. O roadmap inicial (fases 1–12 do
README) está **completo**. Física rígida gameplay via **Box3D**
(`engine.physics`) — ver [physics-quickstart.md](physics-quickstart.md).

O porte nativo Jolt (`engine.jph`) foi **cancelado** e removido — ver
[jph-port-plan.md](jph-port-plan.md).

## Prioridade sugerida

Ordem por **desbloqueio**: jogabilidade → higiene GC → visual (fechar
infra de sombra, depois polish) → conteúdo animado → tooling de iteração
→ escala.

| # | Feature | Doc | Prioridade | Dependências / por quê nesta posição |
|---:|:---|:---|:---|:---|
| 1 | API física gameplay (Box3D) | [plan-physics-api.md](plan-physics-api.md) · [physics-quickstart.md](physics-quickstart.md) | **feito** (P5 mesh adiado) | Base de gameplay; demos `pong3d`, etc. |
| 2 | Fechar GC-safe (adoção + lint) | [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md) | **feito** (#9 Handle API adiado) | Storage POD + lint |
| 3 | PBR + amostragem de sombra | [plan-pbr.md](plan-pbr.md) | **feito** (PBR-0–5) | Textured path: GGX + IBL + PCF; demo `pbr` |
| 4 | Pós-processamento | [plan-post-processing.md](plan-post-processing.md) | **feito** (PP-1–6) | HDR offscreen + bloom + ACES + FXAA; `App.post` |
| 5 | Animação skeletal | [plan-animation.md](plan-animation.md) | média | glTF loader; poses em storage engine = `isPod` |
| 6 | Editor de cena / level design | [plan-editor-ux.md](plan-editor-ux.md) | média | Multi-luz c/ sombra (spot cortável); hull+mesh; `*.asset.json` + `*.scene.json` minificado |
| 7 | Editor de terreno e água | [plan-terrain-water.md](plan-terrain-water.md) | média | Depois do editor de cena; heightfield (P5); brushes + water plane |
| 8 | Hot reload (assets + dados) | [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md) | média | Iteração diária (editor/assets); antes de escala |
| 9 | ECS paralelo | [plan-parallel-ecs.md](plan-parallel-ecs.md) | baixa | API serial estável; opt-in |
| 10 | Networking | [plan-networking.md](plan-networking.md) | baixa | `engine.ser` + física estável |

### Notas de ordem

- **PBR + post:** cena em `rgba16float`; bloom + ACES + FXAA em
  [`plan-post-processing.md`](plan-post-processing.md). Present continua SDR.
- **Hot reload antes de ECS paralelo:** ganho de produtividade no dia a dia;
  paralelismo é escala, não desbloqueia conteúdo.
- **Terreno/água (#7) depois do editor (#6):** reutiliza picking, assets,
  save/load e gizmos; heightfield Box3D desbloqueia collider do terreno.
- **GC-safe (#2) fechado:** `Pod!T[]` no storage, `World.strings`,
  `App.frameArena`, `dub run --config=lint`. Novos buffers devem
  nascer em `Pod!T` / `Handle!T` / `StringId`.

## Já entregue (não reabrir)

- Core: SDL3 + WGPU + ECS SoA + math
- Render: meshes, instancing, depth de cena, luz direcional N·L, texto bitmap
- **ShadowMap infra:** depth pass `depth32Float` + comparison sampler +
  PCF no pipeline textured (`Scene3DTextured.setLighting`)
- Scene: graph, câmeras (orbit/fly/fps), materials PBR (metallic-roughness)
- Assets: BMP + glTF mesh + `pbrMetallicRoughness` (`loadGltfPbr`)
- **PBR + IBL:** Cook-Torrance GGX, procedural IBL, demo `dub run --config=pbr`
- **Post:** HDR scene RT (`rgba16float`), bloom, ACES tone map, FXAA;
  `app.resolvePost(frame)` antes do HUD; `App.post` settings
- Audio: WAV via SDL3 streams
- DevTools: gizmos 3D + overlay FPS/labels
- Física gameplay: `PhysicsWorld`, boxes/spheres/capsules/cylinders, sensors,
  raycast + overlap, joints (distance/revolute/weld), character controller,
  contact/sensor/hit events (Box3D) — [physics-quickstart.md](physics-quickstart.md)
- Primitivas GC-safe: `Pod!T`, `Handle!T`, `StringId`, `FrameArena`,
  `@noGcStorage` + lint (`dub run --config=lint`) — ver [gc-safe-architecture-plan.md](gc-safe-architecture-plan.md)

## Limpeza pendente (não-feature)

- Mesh collider estático (plan-physics-api P5) — opcional, quando houver caso de uso
