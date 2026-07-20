# Plano: Pós-processamento

> **Status:** pendente · Prioridade: média · Ver [roadmap.md](roadmap.md)

## Objetivo

Pipeline de pós-processamento offscreen: render da cena para um color
target intermediário, depois passes fullscreen (tone mapping, bloom, FXAA)
antes do present na surface.

Não depende de PBR. PBR pode usar HDR + tone map depois que PP-1–PP-3
existirem; até lá, PBR pode clampar em LDR.

## Estado atual

Paths reais:

- [`source/engine/gpu/renderer.d`](../source/engine/gpu/renderer.d) —
  `beginFrame` / `endFrame` desenham no swapchain; depth de cena
  `depth24Plus`
- [`source/engine/gpu/shadow.d`](../source/engine/gpu/shadow.d) —
  offscreen `depth32Float` (sombra), sem color MRT
- Sem texture HDR/LDR de cena, sem fullscreen triangle, sem post pipeline

Ordem de frame desejada depois deste plano:

```
shadow depth pass (opcional) → scene color offscreen (+ depth)
  → bloom (se ligado) → tone map → FXAA → present
```

## Fora de escopo

- SSR, SSAO, TAA
- Editor de stack de efeitos ([plan-editor-ux.md](plan-editor-ux.md))
- Exigir PBR antes de shippar post

## Dependências

- Nenhuma feature pendente. Reusa create texture / bind group patterns de
  `shadow.d` e `pipeline.d`.

## Fases

### PP-1 — Offscreen color + depth da cena

- [ ] Texture de cor do tamanho da janela (`bgra8unorm` primeiro; `rgba16float` quando PBR/HDR precisar)
- [ ] Resize junto com depth em `onResize`
- [ ] Scene3D / Renderer renderizam no offscreen em vez do swapchain

**DoD:** cena idêntica visualmente, mas o color attachment não é mais a
surface.

### PP-2 — Fullscreen pass base (blit)

- [ ] Vertex shader fullscreen triangle (sem vertex buffer)
- [ ] Pipeline + bind group: color input + sampler
- [ ] Blit offscreen → surface

**DoD:** imagem final = blit 1:1 do offscreen (prova o caminho; sem
efeitos).

### PP-3 — Tone mapping

- [ ] Uniform: exposure + modo (Reinhard; ACES aproximado depois)
- [ ] Até PBR/HDR: aceitar input LDR e só aplicar exposure

**DoD:** exposure runtime altera o brilho final sem outro efeito.

### PP-4 — Bloom

- [ ] Threshold + downsample + upsample
- [ ] Mix com a imagem tone-mapped
- [ ] Limitar mips / resolução em debug

**DoD:** bloom toggável; custo documentado no benchmark ou overlay.

### PP-5 — FXAA

- [ ] FXAA no **LDR final**, depois do tone map
- [ ] Toggle runtime

**DoD:** arestas suavizam com FXAA on; off restaura o blit nítido.

### PP-6 — API gameplay

- [ ] Flags / struct em `App` ou `Renderer`: `bloom`, `fxaa`, `exposure`
- [ ] Demo ou flag no `showcase` / `benchmark`

**DoD:** um jogo liga efeitos sem tocar WGSL.

## Critérios de aceite

1. Cena renderiza via offscreen sem regressão visual grave.
2. Tone map + bloom + FXAA toggáveis.
3. Frame path continua `@nogc` no core GPU.
4. Resize de janela recria targets sem leak.
5. Não requer [plan-pbr.md](plan-pbr.md).

## Referências

- `source/engine/gpu/renderer.d`, `shadow.d`, `pipeline.d`
- [plan-pbr.md](plan-pbr.md) — HDR/tone map é pré-requisito natural do PBR
- [graphics.md](graphics.md)
