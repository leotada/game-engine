# Plan: Real-Time OpenPBR Surface v1.1 Shading Model

> **Status:** Done (`OPBR-1`–`OPBR-5`) · Priority: High · See [roadmap.md](roadmap.md)

## Objective

Replace the initial glTF 2.0 metallic-roughness shading model ([plan-pbr.md](plan-pbr.md)) with a **clean, canonical Real-Time OpenPBR Surface (v1.1) shading architecture** ([ASWF OpenPBR Specification](https://github.com/AcademySoftwareFoundation/OpenPBR)) in the engine's single-pass `rgba16Float` HDR WebGPU forward renderer (`Scene3DTextured`). Because the engine is in active development, we prioritize a clean, idiomatic OpenPBR data model and shader formulation over legacy struct field compatibility.

## Current State

- **Material GPU UBO & Bind Group:** [`source/engine/graphics/material.d`](../source/engine/graphics/material.d) — 32-byte `MaterialParams` (`baseColorFactor`, `metallic`, `roughness`, `flags`, `_pad`) bound at `@group(1) @binding(0)` alongside 1 sampler and 5 texture views (`albedo`, `metallicRoughness`, `normal`, `occlusion`, `emissive`) with 1×1 default fallback textures (`MaterialDefaults`).
- **Pipeline Layout:** [`source/engine/gpu/pipeline.d`](../source/engine/gpu/pipeline.d) — `MATERIAL_PARAMS_SIZE = 32`, `createTexturedPipeline3D` builds standard (stride 32) and tangent (`MESH_TANGENT`, stride 48) pipelines.
- **Shaders:** [`assets/shaders/textured3d_pbr.wgsl`](../assets/shaders/textured3d_pbr.wgsl) and [`assets/shaders/common/pbr_brdf.wgsl`](../assets/shaders/common/pbr_brdf.wgsl) — single-scattering isotropic Cook-Torrance GGX, Lambertian diffuse, Schlick Fresnel with fixed `0.04` dielectric $F_0$, and split-sum IBL.
- **IBL Precomputation:** [`source/engine/gpu/ibl.d`](../source/engine/gpu/ibl.d) — `IblEnvironment` generates a 64² procedural sky cubemap, 16² irradiance cubemap, 5-mip GGX specular cubemap, and a 128² `rgba8Unorm` BRDF LUT (`generateBrdfLut`) where only channels `R` and `G` are populated (`B = 0`, `A = 255`).
- **Assets & Scene Serialization:**
  - [`source/engine/assets/gltf.d`](../source/engine/assets/gltf.d) — parses `pbrMetallicRoughness`, `normalTexture`, `occlusionTexture`, `emissiveTexture`, `emissiveFactor`; ignores `extensions`.
  - [`source/engine/assets/asset_file.d`](../source/engine/assets/asset_file.d) — `AssetMaterialSlot` stores only `baseColor`, `metallic`, `roughness`, `albedo`, `flags`.
  - [`source/engine/scene/scene_file.d`](../source/engine/scene/scene_file.d), [`source/engine/editor/components.d`](../source/engine/editor/components.d), [`source/engine/editor/scene_load.d`](../source/engine/editor/scene_load.d), [`source/engine/editor/inspector.d`](../source/engine/editor/inspector.d), [`source/editor/panels/inspector.d`](../source/editor/panels/inspector.d) — `MaterialOverride` and `SceneMaterialData` expose only `baseColor`, `metallic`, `roughness`, `flags`.

## Out of Scope

- **Multi-pass Refractive Transmission (`transmission_weight`):** Screen-space refraction (opaque HDR color copy + mip pyramid + dispersion) is deferred until a game project requires refractive glass/water volumes.
- **Volumetric / Screen-Space Subsurface Scattering (`subsurface_weight`):** Separable SSS blur passes or path-traced random-walk SSS are excluded to keep the forward pass single-pass, simple, and allocation-free.
- **MaterialX / OpenUSD XML/USDA Parsers:** Authoring and import use the engine's native `*.asset.json` / `*.scene.json` formats and glTF 2.0 `KHR_materials_*` extensions.

## Dependencies

- Completed [plan-pbr.md](plan-pbr.md) (HDR forward pipeline, PCF shadows, IBL `@group(2)`).
- Completed [plan-post-processing.md](plan-post-processing.md) (`rgba16Float` target, Karis bloom, ACES tone mapping, FXAA).
- Completed [plan-meshoptimizer.md](plan-meshoptimizer.md) M8 (MikkTSpace tangent generation for anisotropic GGX and normal mapping).

## Technical Design

### 1. Canonical OpenPBR `MaterialParams` UBO (144 bytes / 9 × `vec4<f32>`)

Replace the 32-byte `MaterialParams` in `source/engine/graphics/material.d` (and `MATERIAL_PARAMS_SIZE = 144` in `source/engine/gpu/pipeline.d`) with a clean, 16-byte-aligned POD struct using canonical OpenPBR parameter names and defaults:

```d
/// Bit flags controlling optional texture maps and shading features.
enum MaterialFlags : uint {
    none              = 0,
    metallicRoughness = 1 << 0,
    normal            = 1 << 1,
    occlusion         = 1 << 2,
    emissive          = 1 << 3,
}

/// Canonical OpenPBR Surface uniform block (144 bytes = 9 × vec4<f32>).
struct MaterialParams {
    // vec4 [0] (offset 0..16): Base color & weight
    float[3] baseColor = [0.8f, 0.8f, 0.8f];      // openpbr: base_color
    float    baseWeight = 1.0f;                   // openpbr: base_weight [0..1]

    // vec4 [1] (offset 16..32): Base metalness, diffuse roughness, Specular weight & roughness
    float    baseMetalness = 0.0f;                // openpbr: base_metalness [0..1]
    float    baseDiffuseRoughness = 0.0f;         // openpbr: base_diffuse_roughness [0..1]
    float    specularWeight = 1.0f;               // openpbr: specular_weight [0..1]
    float    specularRoughness = 0.3f;            // openpbr: specular_roughness [0..1]

    // vec4 [2] (offset 32..48): Specular color (dielectric tint & F82 conductor edge tint) & IOR
    float[3] specularColor = [1.0f, 1.0f, 1.0f];  // openpbr: specular_color
    float    specularIor = 1.5f;                  // openpbr: specular_ior (F0 = ((n-1)/(n+1))^2 = 0.04)

    // vec4 [3] (offset 48..64): Specular anisotropy & Coat weight / roughness / IOR
    float    specularAnisotropy = 0.0f;           // openpbr: specular_anisotropy [-1..1]
    float    coatWeight = 0.0f;                   // openpbr: coat_weight [0..1]
    float    coatRoughness = 0.1f;                // openpbr: coat_roughness [0..1]
    float    coatIor = 1.6f;                      // openpbr: coat_ior

    // vec4 [4] (offset 64..80): Coat color & darkening
    float[3] coatColor = [1.0f, 1.0f, 1.0f];      // openpbr: coat_color (absorption transmittance)
    float    coatDarkening = 1.0f;                // openpbr: coat_darkening [0..1]

    // vec4 [5] (offset 80..96): Fuzz (sheen) color & weight
    float[3] fuzzColor = [1.0f, 1.0f, 1.0f];      // openpbr: fuzz_color
    float    fuzzWeight = 0.0f;                   // openpbr: fuzz_weight [0..1]

    // vec4 [6] (offset 96..112): Fuzz roughness & Thin-film iridescence
    float    fuzzRoughness = 0.5f;                // openpbr: fuzz_roughness [0..1]
    float    thinFilmWeight = 0.0f;               // openpbr: thin_film_weight [0..1]
    float    thinFilmThickness = 500.0f;          // openpbr: thin_film_thickness (nanometers)
    float    thinFilmIor = 1.4f;                  // openpbr: thin_film_ior

    // vec4 [7] (offset 112..128): Emission
    float[3] emissionColor = [1.0f, 1.0f, 1.0f];  // openpbr: emission_color
    float    emissionLuminance = 0.0f;            // openpbr: emission_luminance (HDR nit/scale)

    // vec4 [8] (offset 128..144): Geometry opacity & flags
    float    geometryOpacity = 1.0f;              // openpbr: geometry_opacity [0..1]
    uint     flags = MaterialFlags.none;          // bound texture map bitmask
    float    _pad0 = 0.0f;
    float    _pad1 = 0.0f;
}
static assert(MaterialParams.sizeof == 144);
static assert(isPod!MaterialParams);
```

### 2. OpenPBR Slab Stack Equations (`assets/shaders/common/openpbr_brdf.wgsl`)

1. **Effective IOR Under Coat & Dielectric $F_0$:**
   - Ambient-to-coat dielectric reflectance: $F_{0,\text{coat}} = \left(\frac{n_{\text{coat}} - 1}{n_{\text{coat}} + 1}\right)^2$.
   - Base dielectric interface relative IOR accounts for presence of coat: $\eta_b = \frac{n_{\text{spec}}}{\text{mix}(1.0, n_{\text{coat}}, w_{\text{coat}})}$, yielding $F_{0,\text{dielectric}} = \text{clamp}\left(\left(\frac{\eta_b - 1}{\eta_b + 1}\right)^2 \cdot w_{\text{spec}}, 0.0, 1.0\right) \cdot C_{\text{spec}}$.
2. **$F_{82}$-Tint Conductor Fresnel (OpenPBR Eq. 24):**
   - Conductors use $F_0 = w_{\text{base}} C_{\text{base}}$ at normal incidence and $C_{\text{spec}}$ as the edge tint at $\bar{\mu} = 1/7$ ($\approx 82^\circ$):
     $$F_{\text{metal}}(\mu) = F_{\text{Schlick}}(\mu, F_0) - \frac{\mu(1 - \mu)^6}{\bar{\mu}(1 - \bar{\mu})^6} \left(F_{\text{Schlick}}(\bar{\mu}, F_0) \cdot (1 - C_{\text{spec}})\right)$$
3. **Thin-Film Iridescence (`thinFilmWeight > 0`):**
   - Evaluates Belcour & Barla (2017) analytical Airy reflectance in XYZ/sRGB for optical path difference $\text{OPD} = 2 n_{\text{film}} d_{\text{film}} \cos\theta_t$, blended with the base Fresnel by `thinFilmWeight`.
4. **Anisotropic GGX NDF & Smith Height-Correlated $G_2$:**
   - Maps `specularRoughness` ($r$) and `specularAnisotropy` ($a \in [-1, 1]$) to directional roughnesses $\alpha_t, \alpha_b$:
     $$\alpha = r^2, \quad \alpha_t = \alpha \sqrt{\frac{2}{1 + (1 - a)^2}}, \quad \alpha_b = \alpha (1 - a) \sqrt{\frac{2}{1 + (1 - a)^2}}$$
   - Evaluates anisotropic GGX $D(\mathbf{h}; \alpha_t, \alpha_b)$ and Smith $G_2(\mathbf{v}, \mathbf{l}; \alpha_t, \alpha_b)$ in the vertex tangent frame $(\mathbf{T}, \mathbf{B}, \mathbf{N})$. Fast-paths to isotropic GGX when $|a| < 10^{-3}$.
5. **Multi-Scattering GGX Energy Compensation (Turquin / Fdez-Agüera):**
   - Using directional albedo $E(\mu_o) = \text{brdfLut}(\mu_o, r).x + \text{brdfLut}(\mu_o, r).y$:
     $$f_{\text{spec,ms}} = f_{\text{spec,ss}} \cdot \left(1 + F_0 \frac{1 - E(\mu_o)}{\max(E(\mu_o), 10^{-3})}\right)$$
6. **Fujii Qualitative Oren-Nayar Diffuse (OpenPBR §6.1):**
   - Controlled by `baseDiffuseRoughness` ($r_d$). Reduces to exact Lambert $\frac{w_{\text{base}} C_{\text{base}}}{\pi}$ when $r_d = 0$, and adds retro-reflection at grazing angles for rough clay/matte surfaces.
7. **Coat Slab Layering (OpenPBR §6.3):**
   - Secondary dielectric GGX lobe with roughness $r_c = \text{coatRoughness}$ and $F_{0,\text{coat}}$.
   - Base roughness widening under rough coat:
     $$r_{\text{base}}' = \text{mix}\left(r_{\text{base}}, \left(1 - (1 - r_{\text{base}})^4 (1 - r_c)^4\right)^{1/4}, w_{\text{coat}}\right)$$
   - View & light absorption transmittance through colored coat:
     $$T_{\text{coat}} = \text{mix}\left(\mathbf{1}, C_{\text{coat}}^{\frac{1}{2\mu_o} + \frac{1}{2\mu_i}}, w_{\text{coat}}\right)$$
   - Internal reflection darkening (`coatDarkening`): modulates base substrate energy according to total internal reflection inside the dielectric coat slab.
8. **Fuzz / Sheen Top Slab (OpenPBR §6.4):**
   - Charlie micro-fiber NDF $D_{\text{Charlie}}(r_f) = \frac{(2 + 1/r_f)\sin(\theta_h)^{1/r_f}}{2\pi}$ with Estevez-Kulla visibility and directional albedo $E_{\text{fuzz}}(\mu_o, r_f)$ read from `brdfLut.b`.
   - Attenuates all underlying slabs (Coat + Base + Emission) by $1 - w_{\text{fuzz}} E_{\text{fuzz}}(\mu_o, r_f)$.

### 3. 3-Channel IBL LUT (`source/engine/gpu/ibl.d`)

- `generateBrdfLut(uint size)` already creates an `rgba8Unorm` 2D LUT.
- Populate channel `B` (byte index `+ 2`) with the numerical integral of the Charlie sheen BRDF over the hemisphere for `(NdotV, fuzzRoughness)`.
- Zero changes to `@group(2)` bind group layout or texture memory footprint.
- In `textured3d_pbr.wgsl`, IBL evaluates:
  - Base diffuse irradiance + multi-scattering specular IBL (with bent reflection vector for anisotropy),
  - Coat specular IBL (`textureSampleLevel(specularMap, iblSampler, R_N, coatRoughness * SPECULAR_MIPS)`) when `coatWeight > 0`,
  - Fuzz ambient IBL (`irradiance * fuzzColor * fuzzLutB`) when `fuzzWeight > 0`.

### 4. glTF 2.0 `KHR_materials_*` Extension Mapping (`source/engine/assets/gltf.d`)

| glTF 2.0 Property / Extension | OpenPBR `MaterialParams` Target |
|:---|:---|
| `pbrMetallicRoughness.baseColorFactor` | `baseColor` (`.rgb`), `geometryOpacity` (`.a`) |
| `pbrMetallicRoughness.metallicFactor` | `baseMetalness` |
| `pbrMetallicRoughness.roughnessFactor` | `specularRoughness` |
| `emissiveFactor` + `KHR_materials_emissive_strength` | `emissionColor`, `emissionLuminance` (default `1.0` when `emissiveFactor != 0` or `emissiveTexture` present, scaled by `emissiveStrength`) |
| `KHR_materials_ior.ior` | `specularIor` |
| `KHR_materials_specular` (`specularFactor`, `specularColorFactor`) | `specularWeight`, `specularColor` |
| `KHR_materials_clearcoat` (`clearcoatFactor`, `clearcoatRoughnessFactor`) | `coatWeight`, `coatRoughness` |
| `KHR_materials_sheen` (`sheenColorFactor`, `sheenRoughnessFactor`) | `fuzzWeight = 1.0`, `fuzzColor`, `fuzzRoughness` |
| `KHR_materials_iridescence` (`iridescenceFactor`, `iridescenceIor`, `iridescenceThicknessMaximum`) | `thinFilmWeight`, `thinFilmIor`, `thinFilmThickness` |
| `KHR_materials_anisotropy` (`anisotropyStrength`) | `specularAnisotropy` |
| `KHR_materials_diffuse_transmission` / Oren-Nayar | `baseDiffuseRoughness` |

## Phases

### OPBR-1 — Canonical `MaterialParams` UBO & Call-Site Migration

- [x] Replace the 32-byte `MaterialParams` with the 144-byte OpenPBR POD struct in `source/engine/graphics/material.d` and update `MATERIAL_PARAMS_SIZE = 144` in `source/engine/gpu/pipeline.d`.
- [x] Update all call sites across `gltf.d`, `demo/editor.d`, `demo/pbr.d`, `demo/golf.d`, and `source/editor/`.

**DoD:** `static assert(MaterialParams.sizeof == 144)` and `static assert(isPod!MaterialParams)` pass; `dub test --config=library` passes.

### OPBR-2 — 3-Channel GGX + Charlie Sheen BRDF LUT (`ibl.d`)

- [x] Extend `generateBrdfLut` in `source/engine/gpu/ibl.d` to integrate Charlie sheen directional albedo into channel `B` of `brdfLutTex`.
- [x] Add unit tests in `ibl.d` verifying monotonic, finite, non-zero `R`, `G`, `B` LUT values across roughness/cosine bounds.

**DoD:** Unit tests in `ibl.d` pass and `@group(2)` bind group layout remains unchanged.

### OPBR-3 — OpenPBR WGSL Shader Stack (`pbr_brdf.wgsl` & `textured3d_pbr.wgsl`)

- [x] Implement Fujii Oren-Nayar diffuse, Dielectric IOR + Multi-scattering GGX, $F_{82}$-tint conductor Fresnel, Anisotropic GGX, Thin-Film Airy iridescence, Coat slab (absorption tint, darkening, and base roughness coupling), and Fuzz/Sheen slab in `assets/shaders/common/pbr_brdf.wgsl`.
- [x] Wire the OpenPBR stack into `assets/shaders/textured3d_pbr.wgsl` for both direct lighting (directional/point/spot + PCF shadows) and IBL.

**DoD:** Shaders compile and hot-reload cleanly; `editor` and `player` pass `--headless-frames=600 --assert-no-gc`.

### OPBR-4 — glTF `KHR_materials_*` Extensions & Asset/Scene Schema

- [x] Extend `parseGltfMaterial` / `parseGltfMaterialJson` in `source/engine/assets/gltf.d` to parse `KHR_materials_ior`, `KHR_materials_specular`, `KHR_materials_clearcoat`, `KHR_materials_sheen`, `KHR_materials_iridescence`, `KHR_materials_emissive_strength`, and `KHR_materials_anisotropy`.
- [x] Update `AssetMaterialSlot` (`asset_file.d`), `SceneMaterialData` (`scene_file.d`), `MaterialOverride` (`components.d`), and the Editor Inspector (`inspector.d`, `panels/inspector.d`).

**DoD:** Unit tests verify glTF extension parsing and `*.asset.json` / `*.scene.json` round-trip serialization with OpenPBR fields; zero GC-safe lint violations in updated modules.

### OPBR-5 — OpenPBR Material Showcase (`demo/pbr.d`) & Documentation

- [x] Upgrade `source/demo/pbr.d` to a 4-row × 5-column OpenPBR sphere matrix (Row 0: Dielectric IOR & Oren-Nayar diffuse; Row 1: $F_{82}$-tint Conductors & Anisotropy; Row 2: Colored Automotive Clearcoat + Darkening; Row 3: Charlie Velvet Fuzz & Thin-Film Iridescence).
- [x] Update `docs/graphics.md` with the OpenPBR UBO layout, slab model, and glTF extension mapping.

**DoD:** `dub build --config=pbr`, `dub run --config=editor -- --headless-frames=600 --assert-no-gc`, and `dub run --config=player -- --headless-frames=600 --assert-no-gc` pass with zero GC allocations in the frame loop.

## Acceptance Criteria

1. `MaterialParams` and `MaterialOverride` use canonical OpenPBR v1.1 parameter names and pass `isPod!T` and `dub run --config=lint`.
2. Direct lighting and IBL evaluate all single-pass OpenPBR slabs (Base/Oren-Nayar, Specular/F82/Anisotropy/Multi-scattering, Thin-Film, Coat, Fuzz, Emission) with energy-conserving slab attenuation.
3. glTF 2.0 files using `KHR_materials_*` extensions populate the corresponding OpenPBR fields automatically.
4. Zero GC allocations in the frame loop (`--headless-frames=600 --assert-no-gc` passes on both `editor` and `player`).

## References

- [ASWF OpenPBR Specification](https://github.com/AcademySoftwareFoundation/OpenPBR)
- [graphics.md](graphics.md)
- [plan-pbr.md](plan-pbr.md)
- [plan-post-processing.md](plan-post-processing.md)
- [plan-meshoptimizer.md](plan-meshoptimizer.md)
