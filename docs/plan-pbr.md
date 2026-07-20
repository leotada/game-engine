# Plano: PBR (metallic / roughness + IBL)

> **Status:** pendente · Prioridade: média · Ver [roadmap.md](roadmap.md)

## Objetivo

Estender o shading atual (Lambert N·L + albedo) para metallic-roughness
(glTF) com IBL (irradiance + prefiltered specular + BRDF LUT), mantendo
instancing e a API `Material` / `Scene3DTextured`. Inclui amostragem da
shadow map existente (PCF) no path lit.

## Estado atual

Paths reais:

- Shader textured: **Lambert N·L + albedo apenas** — sem specular/Blinn
  ([`source/engine/gpu/shaders.d`](../source/engine/gpu/shaders.d))
- [`Material`](../source/engine/graphics/material.d) = bind group com
  uniform VP + sampler + albedo (3 bindings)
- [`ShadowMap`](../source/engine/gpu/shadow.d) = depth pass + comparison
  sampler; comentário do módulo: **PCF / shadowed material fora do v1
  infra**; demos **não** importam `ShadowMap`
- [`assets/gltf.d`](../source/engine/assets/gltf.d) = primeiro primitive →
  `TexMesh` (POSITION/NORMAL/TEXCOORD_0); sem materials PBR, skin, anim, `.glb`

Política de cor até o pós-process existir: **LDR clamp** no shader PBR.
Quando [plan-post-processing.md](plan-post-processing.md) PP-1–PP-3
entregar HDR + tone map, trocar o attachment de cena para `rgba16float`.

## Fora de escopo

- Clearcoat / sheen / transmission (extensions glTF avançadas)
- Area lights / probe volumes dinâmicos (v1 = IBL estático + 1 directional)
- Soft shadows elaborados além de PCF 3×3

## Dependências

- **Pré-req interno deste plano:** fase PBR-0 (shadowed lit) usa
  `ShadowMap` já existente
- **Recomendado:** tone map HDR de [plan-post-processing.md](plan-post-processing.md)
  antes de IBL brilhante; sem isso, LDR clamp documentado

## Fases

### PBR-0 — Shadowed lit (Lambert + PCF)

- [ ] Sample `shadow.view` + comparison sampler no fragment textured
- [ ] Bind light VP + shadow resources no material/pipeline lit
- [ ] Demo mínimo (1 cubo + chão) usando `ShadowMap.create(gpu, resolution)`

**DoD:** sombra visível no path padrão; API =
`ShadowMap.create(gpu, resolution)` + `beginShadowPass` /
`endShadowPass` / `directionalLightVP` (não métodos inventados no guide antigo).

### PBR-1 — Modelo de material

- [ ] Uniform: `metallic`, `roughness`, `baseColorFactor`, flags
- [ ] Texturas opcionais: metallicRoughness, normal, occlusion, emissive
- [ ] Path “albedo-only / colored” permanece para demos atuais

**DoD:** material sem maps extras renderiza igual ao path atual (+ sombra).

### PBR-2 — Shader BRDF

- [ ] WGSL: Cook-Torrance GGX + diffuse energy-conserving
- [ ] Validar com esferas metal/dielectric (roughness 0 → 1)

**DoD:** referência visual: grade 5×2 de esferas (metal/dielectric ×
roughness) em demo ou screenshot doc.

### PBR-3 — IBL

- [ ] HDR equirect → cubemap
- [ ] Precompute irradiance + specular mips + BRDF LUT no startup
- [ ] Bind groups: environment + LUT

**DoD:** esfera metal rough=0 reflete o environment de forma estável.

### PBR-4 — glTF materials

- [ ] Estender `assets/gltf.d` para `pbrMetallicRoughness` + textures
- [ ] Fallback quando o asset não tiver maps

**DoD:** 1 asset glTF PBR versionado ou documentado sob `assets/` carrega
sem pipeline manual.

### PBR-5 — Integração scene

- [ ] `Scene3DTextured` / Material API atualizada
- [ ] Demo showcase: esferas PBR-2 + 1 modelo glTF

**DoD:** `dub run --config=showcase` (ou config nova) mostra PBR + sombra.

## Critérios de aceite

1. Metallic-roughness renderiza com e sem IBL.
2. Shadow PCF no path lit padrão (não só infra depth).
3. glTF PBR comum carrega sem setup manual de pipeline.
4. Demos albedo/checker não quebram.
5. Sem post: LDR clamp; com post HDR: tone map.

## Referências

- `source/engine/gpu/shaders.d`, `graphics/material.d`, `assets/gltf.d`,
  `gpu/shadow.d`
- [graphics.md](graphics.md), [plan-post-processing.md](plan-post-processing.md)
