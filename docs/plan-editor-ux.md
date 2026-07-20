# Plano: Editor UX (scene editor)

> **Status:** pendente · Prioridade: média · Ver [roadmap.md](roadmap.md)

## Objetivo

Editor de cena interativo em cima dos gizmos/overlay já existentes:
selecionar entidades, manipular transforms, inspecionar componentes e
salvar/carregar cenas — sem virar um DCC completo na v1.

## Estado atual

Paths reais:

- [`engine.devtools.gizmos`](../source/engine/devtools/gizmos.d) — linhas 3D overlay
- [`engine.devtools.overlay`](../source/engine/devtools/overlay.d) — FPS + labels
- [`source/demo/editor.d`](../source/demo/editor.d) — **não é scene editor**:
  fly-camera + cubos de referência; teclas `G` (gizmos), `F1` (overlay),
  WASD/Space/Ctrl/Shift/mouse. Sem picking, painéis, serialização ou
  hierarquia editável
- Config dub `editor` aponta para esse demo

## Fora de escopo

- Material graph / shader editor
- Animation timeline completa ([plan-animation.md](plan-animation.md))
- Multi-user collaborative editing
- Play-in-editor (backlog pós-v1; não faz parte das fases ED-1–ED-4)

## Dependências

- Gizmos/overlay (já existem)
- Picking: **AABB/mesh primeiro**; raycast Box3D só se o objeto tiver collider
- Save/load: formato de cena pode compartilhar ideias com futuro
  `engine.ser` ([plan-networking.md](plan-networking.md))

## Fases

### ED-1 — Picking

- [ ] Ray vs AABB (e/ou bounds do mesh) a partir da câmera + mouse
- [ ] Highlight da seleção (gizmo AABB / outline simples)
- [ ] Opcional: se existir body Box3D, `castRayClosest` como refinamento

**DoD:** clicar num cubo do demo seleciona e destaca sem exigir física.

### ED-2 — Transform gizmos

- [ ] Translate / rotate / scale interativos
- [ ] Local vs world space
- [ ] Snap (grid) opcional

**DoD:** arrastar translate move a entidade selecionada.

### ED-3 — Hierarquia + inspector

- [ ] Lista de entidades / scene graph tree (texto overlay + teclado na v1)
- [ ] Inspector editável para POD comuns (Vec3, floats, enums)
- [ ] Immediate-mode UI próprio só se overlay texto for insuficiente

**DoD:** editar posição no inspector reflete no objeto.

### ED-4 — Persistência

- [ ] Formato de cena versionado (JSON ou binário)
- [ ] Save/load de transforms + refs a assets (`StringId` paths)
- [ ] Round-trip com uma cena do showcase

**DoD:** salvar, fechar, reabrir restaura transforms.

### Backlog (fora do DoD v1)

- Play-in-editor (spawn game loop com a cena carregada)
- Multi-select, prefabs, undo stack

## Critérios de aceite

1. Selecionar um mesh na viewport e mover com gizmo de translate.
2. Salvar cena e recarregar restaura transforms.
3. Config `editor` deixa de ser só “gizmo sample” e monta uma cena simples.

## Referências

- `source/engine/devtools/`, `source/demo/editor.d`
- [plan-physics-api.md](plan-physics-api.md), [plan-scripting-hot-reload.md](plan-scripting-hot-reload.md)
