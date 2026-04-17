# Arquitetura Gráfica

A engine usa **WGPU-native** como abstração GPU e **SDL3** para janelas/eventos, rodando nativamente em Wayland no Linux.

## Modelo em 3 Camadas (inspirado no Godot)

```
┌──────────────────────────────────────────────────────┐
│  Scene Layer — API de jogo (engine/scene/*)           │
│  ├── Scene3D          → batched instanced (colorido)  │
│  ├── Scene3DTextured  → batched instanced (texturas)  │
│  ├── SceneGraph       → hierarquia Transform          │
│  ├── Camera           → projeção perspectiva          │
│  └── Controllers      → Orbit / Fly / FirstPerson    │
├──────────────────────────────────────────────────────┤
│  Graphics Layer — recursos gráficos (engine/graphics/*)│
│  ├── Mesh       → vertex/index (pos+normal)           │
│  ├── TexMesh    → vertex/index (pos+normal+uv)        │
│  ├── Texture    → GPU texture + TGA loader            │
│  ├── Material   → bind group (uniform + sampler + tex)│
│  ├── Color4     → RGBA float                          │
│  └── primitives → cube, pyramid, diamond, quad        │
├──────────────────────────────────────────────────────┤
│  GPU Layer — wrappers WGPU low-level (engine/gpu/*)   │
│  ├── App/Renderer → beginFrame/endFrame               │
│  ├── Pipeline3D   → colored + textured instanced     │
│  ├── PipelineText → alpha-blended bitmap text         │
│  ├── ShadowMap    → depth32Float + depth-only pipeline│
│  ├── TextRenderer → bitmap font atlas (8×8 CP437)    │
│  ├── Buffers      → vertex, index, uniform, dynamic  │
│  ├── Shaders      → embedded WGSL sources            │
│  └── GpuContext   → Instance→Adapter→Device→Queue    │
├──────────────────────────────────────────────────────┤
│  Assets + DevTools                                    │
│  ├── assets/bmp.d   → 24/32-bpp BMP → Texture        │
│  ├── assets/gltf.d  → glTF 2.0 mesh → TexMesh        │
│  ├── devtools/gizmos.d  → linhas 3D overlay         │
│  └── devtools/overlay.d → FPS + label debug HUD      │
├──────────────────────────────────────────────────────┤
│  Bindings (bindings/wgpu.d + bindings/sdl3.d)        │
│  └── extern(C) nothrow @nogc — API C99 direta        │
├──────────────────────────────────────────────────────┤
│  libwgpu_native.a          │  libSDL3.so              │
│  (Vulkan/Metal/DX12)       │  (Wayland/X11 + áudio)  │
└──────────────────────────────────────────────────────┘
```

### Quando usar cada camada

| Quero... | Usar |
|:---|:---|
| Desenhar objetos 3D coloridos | `Scene3D` + `Mesh` + `Camera` |
| Desenhar objetos 3D com texturas | `Scene3DTextured` + `TexMesh` + `Material` |
| Hierarquia de transforms (planetas, luas, juntas) | `SceneGraph` |
| Câmera orbital / voo livre / FPS | `engine.scene.controllers` |
| Sombras direcionais | `ShadowMap` + pipeline texturizado |
| Carregar BMP / glTF do disco | `engine.assets.bmp`, `engine.assets.gltf` |
| Tocar WAV / efeitos sonoros | `engine.audio.engine` |
| Texto HUD | `TextRenderer` |
| Debug: linhas 3D, grid, eixos | `engine.devtools.gizmos` |
| Debug: FPS + labels estruturados | `engine.devtools.overlay` |
| Criar formas personalizadas | `Mesh.fromData` + `Vert` |
| Pipeline/shader customizado | `engine.gpu.pipeline`, `engine.gpu.shader` |
| Controle direto de buffers | `engine.gpu.buffer` |
| Chamadas WGPU brutas | `bindings.wgpu` |

## WGPU-native

Backend GPU baseado na spec WebGPU, implementado em Rust pelo projeto [wgpu](https://github.com/gfx-rs/wgpu-native). Vantagens sobre bgfx ou OpenGL direto:

- **Vulkan, Metal e DX12** via uma API unificada e moderna
- **Validação rigorosa** em debug — erros claros em vez de estado GL silencioso
- **API declarativa** — descriptors explícitos para pipelines, buffers, texturas
- **Suporte a compute shaders** nativo (futuro: simulações GPU)

### Integração

Assim como o bgfx anterior, usamos **bindings manuais `extern(C)`** em vez de pacotes bindbc. Razões:

1. Controle total sobre quais funções/structs incluir
2. Sem dependência de pacotes dub de terceiros que podem ficar desatualizados
3. Zero overhead de wrapper — chamadas diretas para a ABI C

As bindings estão em `source/bindings/wgpu.d`, baseadas no `webgpu.h` oficial do repositório webgpu-native/webgpu-headers.

### Lifecycle GPU

```
wgpuCreateInstance()
  └─→ wgpuInstanceCreateSurface()     ← Wayland wl_display + wl_surface
  └─→ wgpuInstanceRequestAdapter()    ← compatível com surface, high-perf
        └─→ wgpuAdapterRequestDevice()
              └─→ wgpuDeviceGetQueue()
              └─→ wgpuSurfaceConfigure()  ← formato BGRA8, FIFO present
```

### Frame Loop

```
1. wgpuSurfaceGetCurrentTexture()     ← acquire swapchain image
2. wgpuTextureCreateView()            ← view para render attachment
3. wgpuDeviceCreateCommandEncoder()   ← command buffer recording
4. wgpuCommandEncoderBeginRenderPass()← color clear + depth clear (1.0)
5.   wgpuRenderPassEncoderSetPipeline()  ← Pipeline3D (instanced)
6.   wgpuRenderPassEncoderSetBindGroup() ← VP uniform buffer
7.   wgpuRenderPassEncoderSetVertexBuffer(0) ← geometry (pos+normal)
8.   wgpuRenderPassEncoderSetVertexBuffer(1) ← instance data (model mats)
9.   wgpuRenderPassEncoderSetIndexBuffer()   ← triangle indices
10.  wgpuRenderPassEncoderDrawIndexed()      ← instanced draw call
11.  ... text overlay draw calls (PipelineText) ...
12. wgpuRenderPassEncoderEnd()
13. wgpuCommandEncoderFinish()         ← produce WGPUCommandBuffer
14. wgpuQueueSubmit()                  ← send to GPU
15. wgpuSurfacePresent()               ← display frame
```

## Render Pipelines

### Pipeline3D

Pipeline para geometria 3D com instanced rendering:

- **Vertex buffer 0** — geometria: `float32x3 position + float32x3 normal` (stride=24)
- **Vertex buffer 1** — instâncias: `4×float32x4` model matrix columns (stride=64, step=instance)
- **Depth** — depth24Plus, depthWriteEnabled, depthCompare=less
- **Primitive** — triangleList, CCW front face, back-face culling
- **Shader** — WGSL com transformação VP × model e iluminação direcional N·L

### PipelineText

Pipeline para texto bitmap (FPS overlay):

- **Vertex buffer** — `float32x2 position + float32x2 texcoord` (stride=16)
- **Blend** — srcAlpha / oneMinusSrcAlpha (alpha blending)
- **Depth** — depth24Plus, depthWrite=false, depthCompare=always (overlay)
- **Font atlas** — 128×48 R8Unorm texture, 8×8 CP437 glyphs (ASCII 32-127)
- **Shader** — WGSL com uniform screen size, sampler + texture binding

### Pipeline3D Textured

Variante do Pipeline3D que amostra uma textura albedo por material:

- **Vertex buffer 0** — geometria: `float32x3 position + float32x3 normal + float32x2 uv` (stride=32)
- **Vertex buffer 1** — instâncias: 4×`float32x4` model matrix columns (stride=64, step=instance)
- **Bind group** — `@group(0)` VP uniform; `@group(1)` sampler + texture_2d (albedo)
- **Depth/culling** — iguais ao Pipeline3D colorido
- **Uso** — `Scene3DTextured` agrupa instâncias por `Material`, emitindo uma draw call por material

### ShadowMap (depth-only pipeline)

Mapa de profundidade para sombras direcionais:

- **Target** — textura 2D `depth32Float` (default 2048×2048)
- **Pipeline** — pipeline dedicado sem fragment shader (depth-only write)
- **VP da luz** — `directionalLightVP()` gera uma `Mat4` de projeção ortográfica + lookAt a partir da direção da luz e de uma bounding box do mundo
- **Fluxo** — (1) render pass só de profundidade na shadow map, (2) render pass normal no swapchain usando a shadow map como textura extra para sample comparison

## Benchmark

O benchmark 3D demonstra o pipeline completo com 1000 cubos girando:

- **1000 cubos** em grid 10×10×10, espaçamento 1.5
- **Instanced rendering** — uma draw call para todos os cubos
- **~1800 FPS** (Linux/Vulkan, mailbox present mode, sem vsync)
- **FPS overlay** — texto bitmap atualizado a cada frame
- **Câmera perspectiva** — FOV 45°, lookAt, near=0.1, far=200.0

## SDL3

SDL3 é usado exclusivamente para:

- **Janela** — `SDL_CreateWindow()` com suporte nativo Wayland
- **Eventos** — teclado, mouse, quit, window close
- **Propriedades Wayland** — `SDL_GetWindowProperties()` extrai `wl_display` e `wl_surface` para criar a surface WGPU

Não usamos o renderer SDL nem SDL_gpu. O SDL é uma camada fina de plataforma; toda renderização passa pelo WGPU.

### Bindings SDL3

Em `source/bindings/sdl3.d` — subset da API necessário para Phase 1:

- Init/Quit, Window, Events, Properties, Timer
- `SDL_Scancode` com valores USB HID
- `SDL_Event` union (128 bytes, compatível com SDL3)
- Strings de propriedade para Wayland (`SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER`, etc.)

## Shaders

A engine usa **WGSL** (WebGPU Shading Language), compilados diretamente pelo WGPU runtime. Os shader sources estão embutidos em `engine/gpu/shaders.d`.

### cube3dShaderSource

Vertex shader que transforma posições com VP × model matrix (instanced) e passa normal para o fragment. Fragment shader faz iluminação direcional N·L:

```wgsl
@group(0) @binding(0) var<uniform> vp: mat4x4f;

@vertex
fn vs_main(
    @location(0) pos: vec3f,
    @location(1) normal: vec3f,
    @location(2) model0: vec4f,  // model matrix columns (per-instance)
    @location(3) model1: vec4f,
    @location(4) model2: vec4f,
    @location(5) model3: vec4f,
) -> VSOut {
    let model = mat4x4f(model0, model1, model2, model3);
    var out: VSOut;
    out.position = vp * model * vec4f(pos, 1.0);
    out.normal = (model * vec4f(normal, 0.0)).xyz;
    return out;
}
```

### text2dShaderSource

Vertex shader para quads de texto com coordenadas de tela. Fragment shader amostra atlas R8Unorm e aplica cor:

```wgsl
@group(0) @binding(0) var<uniform> screenSize: vec2f;
@group(0) @binding(1) var fontSampler: sampler;
@group(0) @binding(2) var fontTexture: texture_2d<f32>;
```

## Texturas e Materiais

`engine/graphics/texture.d` encapsula criação de texturas RGBA8 em GPU, samplers configuráveis e carregamento de arquivos TGA sem compressão. Também expõe helpers procedurais (`checker`, `solid`) para testes.

`engine/graphics/material.d` combina um sampler + textura + uniform buffer em um `WGPUBindGroup` pronto para uso com o pipeline texturizado. Materiais são o "atalho" que o `Scene3DTextured` usa para agrupar instâncias.

### Formatos de imagem suportados

| Formato | Módulo | Observações |
|:---|:---|:---|
| TGA (não comprimido) | `engine.graphics.texture` | 24/32-bpp, loader minimalista |
| BMP (24/32-bpp, não comprimido) | `engine.assets.bmp` | Inverte verticalmente a ordem das linhas |
| glTF 2.0 (mesh) | `engine.assets.gltf` | Apenas geometria — não carrega texturas/materiais/skin |

## SceneGraph

Hierarquia de transforms para objetos compostos (planetas e luas, corpo + membros, câmera em cockpit, etc.).

- **Nós** são índices (`uint`) em arrays paralelos — `parent[]`, `local[]`, `world[]`
- **Uma única passada** propaga `world = parent.world × local` em ordem topológica
- **Sem ponteiros** — sem GC pressure, cache-friendly, compatível com `@nogc`
- Útil combinado com `Scene3DTextured.drawMatrix(mesh, world, material)`

## Controllers de Câmera

`engine/scene/controllers.d` oferece três controladores prontos para uso:

| Controller | Entrada | Uso típico |
|:---|:---|:---|
| `OrbitCamera` | mouse drag + scroll | editor, model viewer, RTS |
| `FlyCamera` | WASD + mouse look | debug, showcase |
| `FirstPersonCamera` | WASD + mouse look + gravidade opcional | gameplay FPS |

Todos atualizam a `Camera` interna via `lookAt` — são controllers, não câmeras em si.

## Áudio

`engine/audio/engine.d` expõe uma API simples sobre SDL3 audio streams:

- **`AudioEngine.create()`** — inicializa o subsistema de áudio SDL3
- **`AudioClip.loadWav(path)`** — decodifica um WAV em memória (PCM)
- **`engine.play(clip)`** — toca o clip sem bloquear; múltiplas instâncias se sobrepõem

Áudio é orientado a gameplay — não roda dentro do frame loop gráfico nem exige `@nogc`.

## DevTools

Ferramentas de depuração e tooling de editor, em `engine/devtools/`:

- **`Gizmos`** — primitivas imediatas em 3D (linha, eixos XYZ, grid, bounding box). Usa topology `lineList` com depth overlay para aparecerem sempre sobre a cena. API `begin/end` por frame, sem alocações no hot path.
- **`DebugOverlay`** — overlay estruturado de FPS + labels arbitrários, renderizado sobre o `TextRenderer`. Ideal para posição da câmera, contadores, flags de estado.

## Estrutura de Bibliotecas

```
libs/
└── libwgpu_native.a    # WGPU-native (Vulkan backend no Linux)
```

Instalação:

```bash
curl -sL https://github.com/gfx-rs/wgpu-native/releases/latest/download/wgpu-linux-x86_64-release.zip \
  -o /tmp/wgpu.zip
unzip -o /tmp/wgpu.zip -d /tmp/wgpu
cp /tmp/wgpu/lib/libwgpu_native.a libs/
```

## Build

```bash
# Demo com clear screen
dub build --config=demo

# Benchmark 3D (1000 cubos + FPS)
dub build --config=benchmark
dub run --config=benchmark

# Crystal Collector (gameplay)
dub run --config=game

# Solar system (scene graph + texturas)
dub run --config=showcase

# Editor tooling (gizmos + debug overlay)
dub run --config=editor

# Release otimizado
dub build --config=demo --build=release
dub build --config=benchmark --build=release
```
