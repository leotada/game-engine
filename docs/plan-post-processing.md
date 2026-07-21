# Plano: Pós-processamento

> **Status:** feito · Prioridade: média · Ver [roadmap.md](roadmap.md)

## Objetivo

Pipeline de pós-processamento offscreen: render da cena para um color
target intermediário HDR (`rgba16float`), depois passes fullscreen
(bloom, tone mapping ACES, FXAA) antes do present na surface SDR.

## Estado atual

Paths reais:

- [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d) —
  `beginFrame` → HDR offscreen; `resolvePost` → bloom/tonemap/FXAA →
  swapchain; `endFrame` present. Depth de cena `depth24Plus`
- [`source/engine/gpu/post.d`](../source/engine/gpu/post.d) —
  `PostProcessor` + `PostSettings` (exposure, bloom, fxaa, tonemapMode)
- [`source/engine/gpu/shaders.d`](../source/engine/gpu/shaders.d) —
  fullscreen triangle + threshold/downsample/upsample/tonemap/FXAA WGSL
- PBR fragment: sem clamp LDR (`max(0)` only); tone map comprime para SDR

Ordem de frame:

```
shadow depth pass (opcional) → scene color HDR offscreen (+ depth)
  → bloom (se ligado) → tone map → FXAA → UI/text no swapchain → present
```

## Fora de escopo

- SSR, SSAO, TAA
- Editor de stack de efeitos ([plan-editor-ux.md](plan-editor-ux.md))
- HDR de monitor / swapchain HDR10

## Dependências

- Nenhuma. Reusa patterns de `shadow.d` e `pipeline.d`.

## Fases

### PP-1 — Offscreen color + depth da cena

- [x] Texture de cor HDR do tamanho da janela (`rgba16float`)
- [x] Resize junto com depth em `Renderer.resize`
- [x] Scene3D / Scene3DTextured / gizmos renderizam no offscreen
      (`Renderer.sceneFormat()`)

**DoD:** color attachment da cena não é mais a surface.

### PP-2 — Fullscreen pass base

- [x] Vertex shader fullscreen triangle (sem vertex buffer)
- [x] `resolvePost`: fecha pass HDR, post, reabre pass UI no swapchain

**DoD:** imagem final chega à surface via post path.

### PP-3 — Tone mapping

- [x] Uniform: exposure + modo (ACES Narkowicz default; Reinhard)
- [x] Clamp PBR removido; HDR interno → SDR no tone map

**DoD:** exposure runtime altera o brilho (`+/-` no demo `pbr`).

### PP-4 — Bloom

- [x] Threshold + downsample + upsample (dual-filter)
- [x] Mix no tone map (`bloomStrength`)
- [x] Toggle `PostSettings.bloom`

**DoD:** bloom toggável (`B` no demo `pbr`).

Notas de qualidade (fireflies):
- Threshold usa soft knee + `bloomClamp` (default 8) para limitar spikes HDR.
- 1º downsample usa **Karis average**; mips seguintes usam box 13-tap.
- Specular GGX directo no PBR é soft-clamped a 16.
- Defaults: `threshold=1.2`, `knee=0.7`, `strength=0.12`, `bloomClamp=8`
  (Karis + clamp evitam flicker; strength alto o bastante para ver o glow).

### PP-5 — FXAA

- [x] FXAA no LDR final, depois do tone map
- [x] Toggle runtime

**DoD:** `F` no demo `pbr` liga/desliga FXAA.

### PP-6 — API gameplay

- [x] `PostSettings` em `Renderer` / `App.post`
- [x] Demo `pbr` com keys; demais demos usam defaults + `resolvePost`

**DoD:** jogo liga efeitos sem tocar WGSL.

## Critérios de aceite

1. Cena renderiza via offscreen HDR sem regressão grave.
2. Tone map + bloom + FXAA toggáveis.
3. Frame path continua `@nogc` no core GPU.
4. Resize de janela recria targets sem leak (`Renderer.resize`).
5. Texto/UI desenha no pass present (após `resolvePost`).

## Referências

- `source/engine/gpu/renderer.d`, `post.d`, `shadow.d`, `pipeline.d`
- [plan-pbr.md](plan-pbr.md) — HDR interno desbloqueia IBL sem clamp
- [graphics.md](graphics.md)
