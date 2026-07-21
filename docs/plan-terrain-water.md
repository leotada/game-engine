# Plano: Editor de terreno e água

> **Status:** pendente · Prioridade: baixa–média · Ver [roadmap.md](roadmap.md)

## Objetivo

Ferramentas de level design para **heightfield / terrain** e **água**
(lago/oceano simples), integradas ao editor de cena
([plan-editor-ux.md](plan-editor-ux.md)) — brush de altura, material/splat
básico, collider heightfield, superfície de água com material e nível.

Não é um world builder AAA (sem rivérios procedurais, sem fluid sim completa).

## Dependências

- Editor de cena v1 (picking, gizmos, save/load, assets) — [plan-editor-ux.md](plan-editor-ux.md)
- Física: heightfield Box3D (extensão de P5) — [plan-physics-api.md](plan-physics-api.md)
- Multi-luz + sombra úteis para preview — GFX-L no plano do editor

## Escopo sugerido (v1)

### Terreno

- [ ] Heightmap (grid) como asset (`*.asset.json` kind `terrain` ou arquivo dedicado)
- [ ] Mesh GPU a partir do heightmap + LOD simples (opcional na v1: sem LOD)
- [ ] Brush: raise / lower / smooth / flatten (raio + strength)
- [ ] Textura / splat até N layers (começar com 1 albedo + tiling)
- [ ] Collider `heightfield` static sync com o heightmap
- [ ] Serializar no asset; cena referencia o terreno como entidade

### Água

- [ ] Plano / grid de água com nível Y e bounds XZ
- [ ] Material água (cor, roughness alto, opacity/alpha ou refraction simples)
- [ ] Movimento leve (UV scroll ou vertex wave barato) — sem simulação SPH
- [ ] (Opcional) stencil/depth para “abaixo d’água” tint
- [ ] Entidade `Water` na cena; gizmo de nível

## Fora de escopo (v1)

- Erosão / rivers / hydraulic erosion
- Ocean FFT / Gerstner completo
- Caustics, shore foam avançado, underwater volume lighting
- Voxel terrain / CSG
- Streaming de tiles de mundo aberto

## Fases (rascunho)

| Fase | Conteúdo |
|:---|:---|
| TW-1 | Heightmap asset + mesh render + load/save |
| TW-2 | Brushes no editor + undo de stroke |
| TW-3 | Heightfield collider Box3D |
| TW-4 | Water plane + material + entidade cena |
| TW-5 | Polish: splat 2–4 layers, wave UV, golden scene |

## Critérios de aceite

1. Pintar terreno no editor, salvar, reabrir com o mesmo relief.
2. Character/bola colide com o heightfield.
3. Colocar água com nível editável e ver na viewport.
4. Cena de exemplo `assets/scenes/terrain_water.scene.json`.

## Referências

- [plan-editor-ux.md](plan-editor-ux.md), [plan-physics-api.md](plan-physics-api.md) (P5/heightfield)
- [plan-pbr.md](plan-pbr.md), `source/engine/gpu/shaders.d`
