# Plano: PBR (metallic / roughness + IBL)

> **Status:** feito · Prioridade: média · Ver [roadmap.md](roadmap.md)

## Objetivo

Estender o shading atual (Lambert N·L + albedo) para metallic-roughness
(glTF) com IBL (irradiance + prefiltered specular + BRDF LUT), mantendo
instancing e a API `Material` / `Scene3DTextured`. Inclui amostragem da
shadow map existente (PCF) no path lit.

## Estado atual

Paths reais:

- Shader textured: **Cook-Torrance GGX + IBL + PCF** com LDR clamp
  ([`source/engine/gpu/shaders.d`](../source/engine/gpu/shaders.d))
- [`Material`](../source/engine/graphics/material.d) = `@group(1)` com
  `MaterialParams` UBO + sampler + albedo + maps opcionais (defaults 1×1)
- [`ShadowMap`](../source/engine/gpu/shadow.d) = depth pass + comparison
  sampler; amostrado no path texturizado via `Scene3DTextured.setLighting`
- [`IblEnvironment`](../source/engine/gpu/ibl.d) = cubemap procedural +
  irradiance + specular mips + BRDF LUT (`@group(2)`)
- [`assets/gltf.d`](../source/engine/assets/gltf.d) = mesh +
  `pbrMetallicRoughness` (factors + BMP/TGA maps); asset de exemplo em
  `assets/models/pbr_cube.gltf`

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

- [x] Sample `shadow.depthView` + comparison sampler no fragment textured
- [x] Bind light VP + shadow resources no frame bind group (`setLighting`)
- [x] Demo mínimo (showcase/editor + `pbr`) usando `ShadowMap.create(gpu, resolution)`

**DoD:** sombra visível no path padrão; API =
`ShadowMap.create(gpu, resolution)` + `beginShadowPass` /
`endShadowPass` / `directionalLightVP` (não métodos inventados no guide antigo).

### PBR-1 — Modelo de material

- [x] Uniform: `metallic`, `roughness`, `baseColorFactor`, flags
- [x] Texturas opcionais: metallicRoughness, normal, occlusion, emissive
- [x] Path “albedo-only / colored” permanece para demos atuais

**DoD:** material sem maps extras renderiza igual ao path atual (+ sombra).

### PBR-2 — Shader BRDF

- [x] WGSL: Cook-Torrance GGX + diffuse energy-conserving
- [x] Validar com esferas metal/dielectric (roughness 0 → 1)

**DoD:** referência visual: grade 5×2 de esferas (metal/dielectric ×
roughness) em demo ou screenshot doc.

### PBR-3 — IBL

- [x] Procedural sky → cubemap (sem HDR externo obrigatório)
- [x] Precompute irradiance + specular mips + BRDF LUT no startup
- [x] Bind groups: environment + LUT (`@group(2)`)

**DoD:** esfera metal rough=0 reflete o environment de forma estável.

### PBR-4 — glTF materials

- [x] Estender `assets/gltf.d` para `pbrMetallicRoughness` + textures
- [x] Fallback quando o asset não tiver maps

**DoD:** 1 asset glTF PBR versionado ou documentado sob `assets/` carrega
sem pipeline manual.

### PBR-5 — Integração scene

- [x] `Scene3DTextured` / Material API atualizada (`setLighting`, `setEnvironment`)
- [x] Demo `pbr`: esferas PBR-2 + 1 modelo glTF + sombra + IBL

**DoD:** `dub run --config=pbr` e `dub run --config=showcase` OK; `editor` OK.

## Critérios de aceite

1. Metallic-roughness renderiza com e sem IBL.
2. Shadow PCF no path lit padrão (não só infra depth).
3. glTF PBR comum carrega sem setup manual de pipeline.
4. Demos albedo/checker não quebram.
5. Sem post: LDR clamp; com post HDR: tone map.

## Referências

- `source/engine/gpu/shaders.d`, `graphics/material.d`, `assets/gltf.d`,
  `gpu/shadow.d`, `gpu/ibl.d`
- [graphics.md](graphics.md), [plan-post-processing.md](plan-post-processing.md)
