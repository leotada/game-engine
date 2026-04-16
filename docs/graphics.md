# Arquitetura Gráfica

A engine usa **WGPU-native** como abstração GPU e **SDL3** para janelas/eventos, rodando nativamente em Wayland no Linux.

## Modelo em 3 Camadas (inspirado no Godot)

```
┌──────────────────────────────────────────────────────┐
│  Scene Layer — API de jogo (engine/scene/*)           │
│  ├── Scene3D  → batched instanced renderer            │
│  │   ├── begin(camera)  → reset batches, upload VP    │
│  │   ├── draw(mesh, pos, scale, color, rotY)          │
│  │   ├── drawMatrix(mesh, model, color)               │
│  │   └── end(frame)     → upload + draw all batches   │
│  └── Camera   → perspective projection + view matrix  │
│      ├── create(fovY, width, height)                  │
│      └── lookAt(eye, target)                          │
├──────────────────────────────────────────────────────┤
│  Graphics Layer — recursos gráficos (engine/graphics/*)│
│  ├── Mesh       → GPU vertex/index buffers            │
│  │   ├── cube/pyramid/diamond(gpu) — built-in shapes  │
│  │   └── fromData(gpu, verts, indices) — custom       │
│  ├── Color4     → RGBA float (white, red, green, etc) │
│  ├── Vert       → float[3] pos + float[3] normal     │
│  └── primitives → vertex/index data arrays            │
├──────────────────────────────────────────────────────┤
│  GPU Layer — wrappers WGPU low-level (engine/gpu/*)   │
│  ├── App/Renderer → beginFrame/endFrame               │
│  ├── Pipeline3D   → instanced 3D, depth test, cull   │
│  ├── PipelineText → alpha-blended bitmap text         │
│  ├── TextRenderer → bitmap font atlas (8×8 CP437)    │
│  ├── Buffers      → vertex, index, uniform, dynamic  │
│  ├── Shaders      → embedded WGSL sources            │
│  └── GpuContext   → Instance→Adapter→Device→Queue    │
├──────────────────────────────────────────────────────┤
│  Bindings (bindings/wgpu.d + bindings/sdl3.d)        │
│  └── extern(C) nothrow @nogc — API C99 direta        │
├──────────────────────────────────────────────────────┤
│  libwgpu_native.a          │  libSDL3.so              │
│  (Vulkan/Metal/DX12)       │  (Wayland/X11)           │
└──────────────────────────────────────────────────────┘
```

### Quando usar cada camada

| Quero... | Usar |
|:---|:---|
| Desenhar objetos 3D com cores | `Scene3D` + `Mesh` + `Camera` |
| Texto HUD | `TextRenderer` |
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

# Release otimizado
dub build --config=demo --build=release
dub build --config=benchmark --build=release
```
