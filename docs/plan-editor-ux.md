# Plano: Editor UX (scene / level editor)

> **Status:** entregue (v1) · Prioridade: média · Ver [roadmap.md](roadmap.md)
>
> **Entrega Stream J:** `dub run --config=editor` é o level editor (picking,
> gizmos+snap, multi-select, undo/redo, hierarchy/inspector, lights+shadows,
> physics Simulate/Esc, Ctrl+S/O/N scene I/O).

## Objetivo

Editor de cena interativo para **level design 3D** em cima dos gizmos/overlay
já existentes: colocar e posicionar objetos, configurar luzes (directional /
point / spot*) com **sombra**, editar atributos (mesh + material PBR + física
Box3D com mesh estático e convex hull static/dynamic), assets versionados
separados da cena, e save/load de cena — sem virar um DCC completo.

\*Spot é **cortável** se o escopo de sombra estourar; directional + point com
sombra são obrigatórios (ver § Luz).

Escopo v1:

| Pilar | O que entrega |
|:---|:---|
| **Level design** | Spawn, picking, gizmos, snap/grid, hierarquia, duplicar/apagar |
| **Luz** | Componente ECS `Light` (UI: entidade dedicada); dir/point/(spot); **sombra obrigatória** nos tipos shipados; IBL preset |
| **Primitivos / mesh** | Primitivas + meshAsset + material |
| **Física** | Primitivas + **convex hull** (static **e** dynamic) + **triangle mesh** (static only) |
| **Assets** | Formato `*.asset.json` versionado (render + collider + hull bake) — **não** embutir geometria na cena |
| **Cena** | `*.scene.json` **minificado**, versionado; refs a assets; `rot` = quaternion |

## Decisões fechadas

| # | Tópico | Decisão |
|---:|:---|:---|
| 1 | Limites de luz | **1** directional + **8** point + **4** spot (slots UBO; overflow = editor bloqueia create) |
| 2 | Sombra | **Obrigatória** para todo tipo de luz que entrar na v1. Se escopo apertar → **cortar spot**, manter dir + point com sombra |
| 3 | Light no ECS | Componente POD `Light` em entidade; UI spawna **entidade dedicada** (`Transform` + `Light`). Runtime pode anexar `Light` a qualquer entidade |
| 4 | Triangle mesh | **Só static** (e kinematic se útil). Dynamic **recusado** na API e no inspector |
| 4b | Convex hull | **Static e dynamic** (obrigatório) |
| 5 | Onde vive geometria/hull | **Asset separado** (`*.asset.json`), não pontos soltos na cena. Cena só referencia `StringId` path |
| 6 | Collider mesh | Default = mesh visual do asset; **override** opcional para outro mesh / bake hull |
| 7 | Formato disco | JSON **minificado** (sem pretty-print); binário depois se precisar |
| 8 | Rotação | Disco + engine = **quaternion** `[x,y,z,w]`. UI do editor mostra **Euler** (graus), converte sempre ao aplicar/salvar |

---

## Estado atual

Paths reais:

- [`engine.devtools.gizmos`](../source/engine/devtools/gizmos.d) — linhas 3D overlay
- [`engine.devtools.overlay`](../source/engine/devtools/overlay.d) — FPS + labels
- [`engine.editor`](../source/engine/editor/) — ED-1…ED-8 (picking, selection,
  gizmos, commands, hierarchy/inspector, lights, physics, scene I/O)
- [`source/demo/editor.d`](../source/demo/editor.d) — **level editor** wired
  (`dub run --config=editor`)

| Área | API hoje | Gap / backlog |
|:---|:---|:---|
| Scene graph | `Transform` (full quat) / `SceneGraph` | — |
| Render lit | multi-light UBO + dir/point/spot shadows | CSM, clustered, shadow cache |
| Material | `Material` / `MaterialParams` + editor override | — |
| Primitivas / glTF | `primitives`, `TexMesh`, `loadGltf*` + `*.asset.json` | — |
| Física | box/sphere/… + hull + static mesh | VHACD / mesh dynamic |
| Editor | config `editor` = level editor | PIE completo, file dialogs nativos |

## Fora de escopo

- Material graph / shader editor
- Animation timeline ([plan-animation.md](plan-animation.md))
- Multi-user editing
- Area lights / probe volumes / GI bake
- Soft bodies, joints editor, character controller UI
- Heightfield / terreno / água no **editor v1** — ver roadmap
  [plan-terrain-water.md](plan-terrain-water.md) (#7), depois deste plano
- Voxel terrain / CSG / splines
- Prefab nesting profundo / browser completo
- Play-in-editor completo (PIE mínimo opcional em ED-8)
- Triangle mesh **dynamic** / VHACD (backlog)
- JSON pretty-print no save de produção (só ferramentas de debug se útil)

## Dependências

- Gizmos/overlay
- Picking AABB/mesh; raycast Box3D se houver collider
- **GFX-L** multi-luz + sombras (pré-req ED-6)
- **PHY-H + P5** hull + mesh static (pré-req ED-5b)
- Formato **asset** + **scene** (ED-7 / AST-1)
- Hot reload opcional: [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md)

---

## Modelo de dados (ECS + editor)

Runtime / editor compartilham componentes POD. A UI pode *parecer* “Light
entity”, mas o storage é ECS:

```text
Entity
├── Transform          // sempre (ou quase); rot = quat
├── Name (StringId)    // opcional
├── Parent / hierarchy // SceneGraph
├── Visual?            // primitiva ou Handle/ref a Asset
├── MaterialOverride?  // opcional sobre o asset
├── PhysicsBody?       // motion + shape ref (primitiva | hull | mesh) via asset
└── Light?             // directional | point | spot + shadow flags
```

Spawn “Light” na UI = `createEntity` + `Transform` + `Light` (sem Visual).
Spawn “Cube” = `Transform` + `Visual` (+ Physics opcional). Nada impede
gameplay de fazer `entity.add(Light(...))` num prop depois.

Regras:

- Editor: **Transform manda**; Simulate: dynamics via `readBodyTransform`.
- UI Euler ↔ quat na borda do inspector (`eulerToQuat` / `quatToEuler`);
  gizmos e save só veem quat.
- Collider default = mesh visual do asset; override = outro mesh do mesmo
  asset ou path, ou hull bakeado no asset.
- Persistência: cena referencia assets; assets carregam geometria/hull.

---

## Luz — directional / point / spot (+ sombra)

### Estado

Hoje: 1 directional + IBL + 1 shadow map 2D. Point/spot inexistentes.

### Modelo (fechado)

| Tipo | Campos | Atenuação | Sombra v1 |
|:---|:---|:---|:---|
| **Directional** | `direction`, `color`, `intensity` | — | Ortho shadow map (como hoje); 1 caster (flag `castShadows`) |
| **Point** | `position`, `color`, `intensity`, `range` | smooth inverse-square até `range` | **Cubemap** depth (6 faces) + PCF; obrigatório |
| **Spot** | `position`, `direction`, `color`, `intensity`, `range`, `innerConeDeg`, `outerConeDeg` | idem + cone | Perspective shadow map + PCF; **só se couber no prazo** |

Limites UBO: **1 dir + 8 point + 4 spot**. Create além do limite → erro na UI.

IBL = setting global da cena, não componente `Light`.

### Política de corte de escopo

Ordem de prioridade se GFX-L estourar:

1. Manter directional lit + shadow (já existe)
2. Entregar **point lit + point shadow cubemap**
3. Spot lit + spot shadow — **cortar do v1** se necessário (voltar ao backlog)
4. Nunca shipar point/spot **sem** sombra

Se spot for cortado: limites viram 1 dir + 8 point; schema `Light.type`
ainda pode reservar `"spot"` para v2, ou omitir até existir.

### Orçamento de sombra sugerido (v1)

| Recurso | Sugestão inicial |
|:---|:---|
| Directional map | 2048² (já típico) |
| Point cubemap | até **2–4** points com `castShadows` @ 512²/face (resto lit sem shadow ou erro se exceder) |
| Spot map | até **1–2** @ 1024² se spot existir |

Editor: toggle `castShadows`; ao exceder budget, avisa e não liga mais
shadows (luz continua iluminando).

**Decisão residual (implementação):** budget exato de shadow casters point
(2 vs 4) — ajustar na GFX-L3 com profiling; documentar constante
`MAX_POINT_SHADOW_CASTERS`.

### Gizmos

- Directional: seta + AABB shadow ortho
- Point: esfera `range` + ícone; se castShadows, indicar cubemap ativo
- Spot: cone inner/outer + frustum da shadow camera

### GFX-L (pré-req engine)

- [x] **GFX-L1** — UBO multi-light + shader PBR soma dir/point/(spot)
- [x] **GFX-L2** — `Scene3DTextured.setLights` / frame lights
- [x] **GFX-L3a** — Point shadow: depth cubemap + sample no fragment; API create/update
- [x] **GFX-L3b** — Spot shadow (só se no escopo): depth 2D perspective
- [x] **GFX-L3c** — Manter directional PCF sem regressão
- [x] **GFX-L4** — Demo: sun + point lamp com sombra; spot se existir
- [x] **GFX-L5** — Budget casters + docs constantes

**DoD GFX-L:** point light com sombra visível (objeto bloqueia outro);
directional intacto. Spot: DoD separado ou “N/A se cortado”.

### ED-6 — editor de luzes

- [x] Spawn entidade Light (Transform + Light component)
- [x] Inspector: type, color, intensity, range/cones, `castShadows`, budget hint
- [x] Gizmos; IBL preset no painel Scene
- [x] Serializar no `.scene.json`
- [x] Se spot cortado: UI não oferece spot

**DoD:** dir + point (com sombra) editáveis ao vivo; save/load; spot se shipado.

---

## Colliders — mesh static + convex hull static/dynamic

### Capacidade

| Shape | Static | Kinematic | Dynamic |
|:---|:---|:---|:---|
| primitivas | ✅ | ✅ | ✅ |
| **convexHull** | ✅ | ✅ | ✅ |
| **triangleMesh** | ✅ | ✅ | ❌ |

### Fonte do collider (fechado)

```text
Asset
├── renderMesh          // visual
├── collisionMesh?      // override; default = renderMesh
└── convexHull?         // bake (pontos / hull cozido) para dynamic ou static
```

No inspector de Physics:

1. Shape: primitive | triangleMesh | convexHull
2. Se triangleMesh: fonte = visual (default) **ou** collision mesh override do asset
3. Se convexHull: **Bake from** visual / collision mesh → grava no asset
4. Motion dynamic + triangleMesh → UI disabled + API recusa

### Convex hull pipeline

```text
mesh (visual ou collision override)
  → extract unique positions (object space)
  → b3CreateHull(points, count, maxVertexCount)
  → store bake no *.asset.json
  → createStaticHull / createDynamicHull em runtime
```

Params editor: `maxVertexCount` (default **64**), preview wireframe ciano.
Falha de bake → mensagem + não grava.

### Triangle mesh pipeline (P5)

- Bindings `b3CreateMeshShape` + `createStaticMesh`
- Default verts/indices do render mesh; override se `collisionMesh` setado
- Scale: object-space unitário no cook; scale do `Transform` no body
  (recook se scale não-uniforme mudar — ou documentar limitação v1:
  só scale uniforme em mesh colliders)

### PHY-H / P5

- [x] **PHY-H1** — `createStaticHull` / `createDynamicHull` / `createKinematicHull`
- [x] **PHY-H2** — smoke hull dynamic + static
- [x] **P5a** — bindings mesh + `createStaticMesh`
- [x] **P5b** — smoke ball vs static mesh
- [x] Sem `createDynamicMesh` na API pública

### ED-5a — primitivas

- [x] Enable, motion, dims sync, mass/restitution/friction/damping
- [x] Wireframe; Simulate / Esc restore

**DoD:** sphere dynamic cai; Esc restaura.

### ED-5b — hull + mesh

- [x] Shape kinds + bake hull → **escreve asset** (não a cena)
- [x] triangleMesh static; override collision mesh
- [x] Cores gizmo: hull ciano, mesh magenta, AABB amarelo
- [x] Cena só guarda ref ao asset + motion/mass overrides locais se houver

**DoD:**  
1) asset static mesh collider; bola quica.  
2) hull dynamic bakeado no asset; Simulate.  
3) mesh+dynamic bloqueado.

---

## Assets — formato versionado (separado da cena)

A cena **não** embute geometria nem pontos de hull. Tudo que é reutilizável
vive em `*.asset.json` (minificado), referenciado por path.

### Papel

| Arquivo | Contém |
|:---|:---|
| `*.asset.json` | Definição completa de um prop/modelo: render, materiais, collision mesh opcional, hull bake, meta |
| `*.scene.json` | Entidades, transforms (quat), overrides leves, lights, settings; **refs** `StringId` → path do asset |

Fontes externas (glTF, BMP/TGA) continuam como arquivos brutos; o asset
**aponta** para eles e guarda bakes (hull) + overrides de collider.

### Schema sugerido — `game-engine.asset` v1

```json
{"format":"game-engine.asset","version":1,"kind":"model","meta":{"name":"crate"},"render":{"source":"assets/models/crate.gltf","primitive":null},"materials":[{"baseColor":[1,1,1,1],"metallic":0,"roughness":0.5,"albedo":"assets/tex/crate.bmp","flags":0}],"collision":{"triangleMesh":{"source":"render"},"convexHull":{"maxVertexCount":64,"points":[[0,0,0],[1,0,0]]}}}
```

Campos (legível):

```text
format: "game-engine.asset"
version: 1
kind: model | primitive   // primitive = box/sphere/... gerado, sem glTF
meta.name
render:
  source: path glTF | null
  primitive: { kind, dims } | null   // se kind=primitive
materials[]: MaterialParams + texture paths (strings no asset file OK;
             runtime interna em StringTable ao load)
collision:
  triangleMesh:
    source: "render" | path para mesh/glTF de colisão dedicado
  convexHull:                        // ausente = ainda não bakeado
    maxVertexCount
    points: [[x,y,z], ...]           // object space; resultado do bake
    // futuro: "cooked" binário se JSON ficar grande
```

Regras:

- `triangleMesh.source: "render"` = usa o mesmo mesh visual.
- Override = path de outro glTF/mesh (ex.: versão low-poly).
- Bake hull **atualiza o asset** (dirty flag no editor; Save Asset).
- Versionamento igual ao da cena (`migrate_vN`).
- JSON **minificado** no save.

### AST-1 — fases asset

- [x] Schema + reader/writer minificado
- [x] Load asset → `TexMesh` + `Material` + opcional hull points / mesh collider
- [x] Save asset após bake hull / mudar collision source
- [x] Exemplo `assets/models/crate.asset.json` + golden test
- [ ] Primitive assets (box etc.) geráveis pelo editor (Save As asset) —
  backlog leve; bake hull já grava no asset referenciado. Primitivos
  one-off via `visual.kind` na entidade sem asset — permitido.

**DoD:** round-trip asset com render + hull points; cena referencia e spawna.

---

## Persistência — cena versionada (JSON minificado)

### Objetivos

- Round-trip editor ↔ disco ↔ runtime loader
- `version` + migrations
- Quat no disco; sem geometria embutida

### Formato — `game-engine.scene` v1

Arquivo: `*.scene.json`, **minificado**, key order determinística.

Exemplo *expanded only for docs* (disco real sem whitespace):

```json
{
  "format": "game-engine.scene",
  "version": 1,
  "meta": { "name": "arena_01", "units": "meters" },
  "strings": ["Sun", "assets/models/crate.asset.json", "Lamp"],
  "settings": {
    "gravity": [0, -9.81, 0],
    "iblPreset": "procedural_default"
  },
  "entities": [
    {
      "id": 1,
      "name": 0,
      "parent": 0,
      "transform": {
        "pos": [0, 1, 0],
        "rot": [0, 0, 0, 1],
        "scale": [1, 1, 1]
      },
      "visual": { "asset": 1 },
      "physics": {
        "enabled": true,
        "motion": "static",
        "shape": "triangleMesh",
        "friction": 0.5,
        "restitution": 0.1
      }
    },
    {
      "id": 2,
      "name": 2,
      "parent": 0,
      "transform": {
        "pos": [0, 5, 0],
        "rot": [0, 0, 0, 1],
        "scale": [1, 1, 1]
      },
      "light": {
        "type": "point",
        "color": [1, 0.9, 0.8],
        "intensity": 40.0,
        "range": 12.0,
        "castShadows": true
      }
    }
  ]
}
```

Notas:

- `rot` = quaternion `[x,y,z,w]` sempre.
- `visual.asset` → índice em `strings` → `*.asset.json`.
- Physics shape `triangleMesh` / `convexHull` lê geometria **do asset**;
  entidade só escolhe shape kind + motion + material físico.
- Overrides locais opcionais depois (ex. mass) sem fork do asset.
- Light = bloco componente na entidade (UI cria entidade só com light).

### Versionamento

| Campo | Regra |
|:---|:---|
| `format` | `game-engine.scene` / `game-engine.asset` |
| `version` | monotônico; migrate em cadeia |
| Save | minificado; ordem de keys estável |
| Unknown fields | rejeitar com erro claro na v1 (mais simples) **ou** strip — preferir **erro** até termos necessidade de forward-compat |

### Módulos

```text
engine/assets/asset_file.d   // *.asset.json
engine/scene/scene_file.d    // *.scene.json (formato; runtime-friendly)
engine/editor/scene_load.d   // spawn EditorWorld a partir da cena
```

### ED-7

- [x] Scene + asset schemas v1
- [x] Reader/writer minificado + `strings` table
- [x] Quat only no disco; teste Euler UI → quat file
- [x] Migrations stub
- [x] Ctrl+S / Ctrl+O; New scene
- [x] Validação: light limits, mesh+dynamic, asset missing, shadow budget
- [x] Golden round-trip (minificado estável)

**DoD:** fechar processo e reabrir restaura cena + assets referenciados
(incl. hull bake e point light com `castShadows`).

---

## Fases consolidadas

### ED-1 — Picking

- [x] Ray vs AABB/mesh; highlight; opcional `castRayClosest`

**DoD:** click seleciona cubo sem física.

### ED-2 — Transform + level tools

- [x] Translate/rotate/scale; local/world; snap; grid
- [x] Delete / Duplicate / Focus
- [x] Spawn primitivos + Light entity
- [x] Rotate gizmo/inspector em Euler na UI → quat interno

**DoD:** spawn, move com snap, duplicar, apagar.

### ED-3 — Hierarquia + inspector

- [x] Tree; inspector POD; rename; parent se possível

**DoD:** editar pos no inspector move o objeto.

### ED-4 — Material

- [x] baseColor, metallic, roughness, albedo path; presets

**DoD:** slider roughness atualiza viewport.

### ED-5a — Física primitivas

- [x] Motion/dims/mass/…; Simulate/restore

**DoD:** sphere cai; Esc restaura.

### AST-1 — Asset file (pode ∥ ED-5a)

- [x] `*.asset.json` load/save; exemplo + teste

**DoD:** ver § Assets.

### ED-5b — Hull + mesh collider

- [x] Depende PHY-H, P5, AST-1
- [x] Bake hull → asset; mesh static; override collision mesh

**DoD:** ver § Colliders.

### GFX-L → ED-6 — Lights + shadows

- [x] Dir + point (+ spot se couber) com sombra
- [x] Componente Light; UI entidade dedicada

**DoD:** ver § Luz.

### ED-7 — Scene file

- [x] `*.scene.json` minificado versionado + golden

**DoD:** ver § Persistência.

### ED-8 — Polish

- [x] Multi-select, undo/redo, align ground, copy attrs, PIE opcional
  (Simulate cobre PIE físico mínimo)

**DoD:** undo de move; multi-mover 3 boxes.

### Backlog

- Spot (se cortado da v1) + spot shadows
- **Static Shadow Caching**: reuso de cubemaps para luzes e objetos estáticos (evita 6 passes por frame)
- **Clustered Forward Rendering**: compute pass em WGPU para binning de luzes em 3D clusters (suporte a 100+ point lights)
- Octahedral / Atlas Mapping de sombras pontuais
- CSM / multi directional shadows
- VHACD / mesh dynamic
- Prefabs, PIE completo, joints UI, navmesh
- Terreno / água — [plan-terrain-water.md](plan-terrain-water.md)

---

## Critérios de aceite

1. Level tools: select, gizmo (+ snap), spawn/dup/delete.
2. Material PBR + física primitiva + **hull dynamic/static** + **mesh static**.
3. **Point light com sombra** + directional com sombra; spot se não cortado.
4. Light = componente ECS; spawn UI = entidade dedicada.
5. Hull/collision vivem no **asset**; cena só referencia.
6. Collider default = visual; override possível; bake hull no asset.
7. Save/load: JSON minificado, `version`, quat no disco, Euler só na UI.
8. Config `editor` é o level editor, não gizmo sample.

## Ordem sugerida

```text
ED-1 → ED-2 → ED-3 → ED-4 ∥ ED-5a ∥ AST-1
GFX-L (∥ física) → ED-6
PHY-H + P5 → ED-5b
AST-1 + ED-5b + ED-6 → ED-7 → ED-8
```

Corte de emergência: **remover spot** de GFX-L / ED-6; nunca remover
sombra de point.

## Referências

- `source/engine/devtools/`, `source/demo/editor.d`
- `source/engine/graphics/material.d`, `primitives.d`, `texmesh.d`
- `source/engine/gpu/shadow.d`, `scene/scene3d_textured.d`
- `source/bindings/box3d/`
- [plan-physics-api.md](plan-physics-api.md), [physics-quickstart.md](physics-quickstart.md)
- [plan-pbr.md](plan-pbr.md), [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md)
- Box3D: [Shape](https://box2d.org/documentation3d/group__shape.html),
  [Hull](https://box2d.org/documentation3d/group__hull.html)
