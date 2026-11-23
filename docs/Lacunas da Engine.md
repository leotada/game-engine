# O que falta na game engine para "Echoes of the Outpost"

Levantamento feito lendo o código da engine em `/home/leonardo/Projetos/game-engine` (nada foi alterado lá) e comparando com o que o jogo precisou em `source/game/*.d` e com o que o Godot entregava.

Cada item tem sempre os mesmos cinco campos:

- **Hoje na engine:** o que existe, com arquivo e linha.
- **O que falta:** a lacuna exata.
- **Mudança proposta:** API e arquivos da engine a tocar.
- **Onde será usado:** função do jogo que muda, e qual efeito do Godot volta.
- **Pronto quando:** teste objetivo de aceite.

Os identificadores E1–E23 são os mesmos da seção 6 do `Plano de Reescrita - Engine D.md`. O tamanho (P, M, G) é estimativa minha de esforço relativo, não medição.

## Estado atual (2026-11-17)

Trabalho na engine em `/home/leonardo/Projetos/game-engine`, branch `feat/custom-surface-shaders` (5 commits, ainda não integrados à `master`).

| Feito | Pendente |
|---|---|
| E1 shader customizado (1 de 8 shaders do Godot portado: asteroide mineral) | **E7** luzes pontuais (próximo), E9–E19, E21–E23 |
| E2 tempo e dados por instância | E1: portar gelo, casco, painel solar, janelas, anel, carapaça |
| E3 aditivo, unlit, sem depth write | E5: AgX e raio do bloom |
| E4 partículas, emissor e campo de poeira (CPU) | E4: compute shader (fora de escopo) |
| E5 tonemap linear e bloom *screen* | E6: gradiente e intensidade do IBL |
| E6 `IblEnvironment.createSolid` | |
| E8 atenuação de ponto e holofote | |
| E20 lotes crescentes e aviso | |

Não verificado: as demos da engine (`pbr`, `water`, `editor`, `golf`) não foram abertas depois das mudanças de shader e de layout de material.

## Índice

| # | Lacuna | Área | Tamanho | Impacto visual |
|---|---|---|---|---|
| E1 | Shader customizado por material | Render | G | Muito alto |
| E2 | Tempo global e parâmetros por instância | Render | P | Alto |
| E3 | Mistura aditiva, sem iluminação, sem escrita de profundidade | Render | M | Muito alto |
| E4 | Partículas com billboard e curva de alfa | Render | M | Alto |
| E5 | Tonemap linear e bloom configurável | Pós | P | Alto |
| E6 | Luz ambiente e céu configuráveis | Render | P | Médio |
| E7 | Mais de 8 luzes pontuais | Render | M | Alto |
| E8 | Curva de atenuação de spot e ponto | Render | P | Alto |
| E9 | Passe de pós-processamento customizado | Pós | M | Médio |
| E10 | Primitivas e ruído procedural | Geometria | P | Baixo |
| E11 | UI: linhas, polígonos, arcos, contorno | UI | M | Médio |
| E12 | Fonte: vários tamanhos e Unicode | UI | M | Médio |
| E13 | Imagens na UI e PNG | UI | P | Baixo |
| E14 | Sombras sem código manual | Render | M | Médio |
| E15 | Janela: tela cheia, título, cursor, vsync | Plataforma | P | Nenhum |
| E16 | Áudio: mixer, ganho, laço, pitch | Áudio | M | Nenhum |
| E17 | Mapa de ações de entrada | Entrada | P | Nenhum |
| E18 | Passo fixo e escala de tempo | Núcleo | P | Nenhum |
| E19 | Tweens e temporizadores | Núcleo | P | Baixo |
| E20 | Limites de lote e instância com aviso | Render | P | Nenhum (evita bug) |
| E21 | Engine consumível como dependência dub | Build | P | Nenhum |
| E22 | Captura de tela em PNG | Ferramenta | P | Nenhum |
| E23 | Steamworks | Plataforma | M | Nenhum |

---

## Parte 1 — Renderização 3D

### E1. Shader customizado por material — FEITO

> **Implementado na engine (sem commit).** API final: `scene.createSurfaceShader(wgsl)` devolve um id, que vai em `material.surfaceShader`; `material.updateSurfaceParams(gpu, float[16])` preenche `surfaceParams.p0..p3`; `scene.setTime(t)` expõe `frame.time`; `scene.reloadSurfaceShader(id, wgsl)` recompila a quente. O trecho WGSL define `fn surface(in: SurfaceIn, base: SurfaceOut) -> SurfaceOut` e, opcionalmente, `fn displace(localPos, localNormal) -> vec3<f32>`. Limite: 16 shaders por cena; o passe de sombra não executa `displace`.
> Primeiro uso no jogo: `source/game/surfaces.d` (`mineralAsteroidWgsl`), ligado em `Gfx.createMaterials`. Os outros sete shaders da tabela abaixo continuam por portar. O texto a seguir é a proposta original.

- **Hoje na engine:** existe um único shader de superfície, `assets/shaders/textured3d_pbr.wgsl`, com dois pipelines fixos (com e sem tangente) criados em `gpu/pipeline.d` e escolhidos em `scene/scene3d_textured.d:352`. `Material` (`graphics/material.d:108`) só carrega o bloco `MaterialParams` de 144 bytes e cinco texturas. A engine já tem pré-processador WGSL com `#include`, `#define` e `#ifdef`, e recarga de shader a quente (`Scene3DTextured.reloadShader`, linha 171).
- **O que falta:** não há como um jogo injetar código de superfície. A única saída hoje é montar um pipeline WGPU inteiro à mão, como a demo `source/demo/water.d` faz (84 KB).
- **Mudança proposta:**
  1. No WGSL, isolar a montagem da superfície em uma função `fn surface(in: SurfaceIn) -> SurfaceOut`, com `SurfaceOut { baseColor, metalness, roughness, emission, normal, opacity }`. O corpo padrão é o atual.
  2. `Material.createCustom(gpu, layout, wgslSurface, params)`, onde `wgslSurface` substitui essa função via `#include` e `params` é um bloco extra de até 64 bytes (4 × `vec4`).
  3. Gancho opcional `fn displace(pos, normal) -> vec3` no vértice.
  4. `Scene3DTextured` guarda um pipeline por shader distinto e troca de pipeline por lote.
  5. Entradas disponíveis no trecho: posição local e de mundo, normal, uv, `frame.time` (E2), tinta e `custom` da instância (E2).
- **Onde será usado:** substitui as cores chapadas criadas em `Gfx.createMaterials` (`source/game/gfx.d:182`). Cada shader do Godot em `Shaders/` volta para o seu lugar:

  | Shader do Godot | Material hoje (`enum M`) | Desenhado em |
  |---|---|---|
  | `brutalist_hull.gdshader` (triplanar, desgaste de borda) | `hull`, `dark` | `drawStation`, `drawShip`, `drawDerelicts`, `drawJunk` |
  | `mineral_asteroid.gdshader` (veios de minério) | `rock`, `rockLit` | `drawAsteroids` |
  | `ice_asteroid.gdshader` (brilho interno) | `ice`, `iceLit` | `drawAsteroids` |
  | `solar_panel.gdshader` (grade de células) | `solar` | `drawStation` |
  | `station_windows.gdshader` (20 janelas discretas) | `window` | `drawStation` |
  | `luminous_ring.gdshader` | `ring` | `drawTranslucent` |
  | `echo_biomech.gdshader` (carapaça pulsante) | `carapacePatrol`, `carapaceAlert`, `carapaceChase` | `drawEnemies` |
  | `enemy_dissolve.gdshader` | nenhum (inimigo some de uma vez) | `drawEnemies` |

- **Pronto quando:** um asteroide mineral mostra veios emissivos que não deslizam quando a rocha gira, e trocar o trecho WGSL em disco atualiza a imagem sem reiniciar.

### E2. Tempo global e parâmetros por instância

- **Hoje na engine:** `FrameUniforms` (`scene/scene3d_textured.d:66` e `assets/shaders/common/shadows.wgsl:34`) tem câmera e luzes, sem tempo. `InstanceData` (`graphics/types.d:35`) é `model` + `color`, e a cor só multiplica o albedo (`textured3d_pbr.wgsl:221`). A emissão vem só do material (linha 249). O próprio shader de água da engine contorna a falta de tempo passando-o por `mat._pad0` (linha 260).
- **O que falta:** `time` nos uniforms do frame e um canal livre por instância.
- **Mudança proposta:**
  1. `FrameUniforms.time` (aproveita `_padCounts`, sem mudar o tamanho de 1088 bytes) e `Scene3DTextured.setTime(float)`.
  2. `InstanceData.custom: float[4]` (80 para 96 bytes; mais um atributo de vértice em `pipeline.d`).
  3. Convenção padrão no shader PBR: `custom.x` multiplica a emissão, `custom.y` mistura para branco (flash), `custom.z` é limiar de dissolve, `custom.w` é livre.
  4. Sobrecarga `drawMatrix(mesh, material, model, tint, custom)`.
- **Onde será usado:**
  - `Gfx.setEmission` (`gfx.d:231`) desaparece: ele regrava o UBO do material a cada frame para simular pulsação, e por isso todos os objetos do mesmo material pulsam juntos.
  - `flashTint` em `drawShip` (`gfx.d:856`) vira `custom.y`: flash de dano realmente branco, hoje é só albedo clareado.
  - `drawEnemies` (`gfx.d:797`): um material de carapaça no lugar de três, com o estado (patrulha, alerta, perseguição) em `custom`, e dissolve por inimigo na morte.
  - `drawStation`: painéis solares e janelas acendem por nível de upgrade sem material novo.
  - Os 17 materiais "glow" (`M.cyan` a `M.core`) caem para dois ou três, o que libera lotes (ver E20).
- **Pronto quando:** dois Ecos lado a lado pulsam fora de fase usando o mesmo `Material`.

### E3. Mistura aditiva, material sem iluminação e sem escrita de profundidade

- **Hoje na engine:** todos os pipelines 3D de `gpu/pipeline.d` usam `srcAlpha / oneMinusSrcAlpha` com `depthWriteEnabled = true` e `cullMode = back` (linhas 107–141 e blocos equivalentes). Não existe nenhum caminho "unlit": `grep` por `unlit` na engine não retorna nada. Além disso o alfa final é empurrado para 1 pelo Fresnel em ângulo rasante (`textured3d_pbr.wgsl:445–447`), o que deixa translúcidos mais opacos nas bordas. Os lotes são desenhados na ordem de criação (`scene3d_textured.d:348`), sem ordenar translúcidos.
- **O que falta:** modo de mistura, escrita de profundidade, culling e iluminação configuráveis por material; ordenação de translúcidos.
- **Mudança proposta:**
  1. `MaterialParams` ou um `MaterialRenderState` à parte: `blendMode` (`opaque`, `alpha`, `additive`), `depthWrite`, `doubleSided`, `unlit`.
  2. `createTexturedPipeline3D` gera as variantes sob demanda (cache por combinação).
  3. `unlit` no WGSL: retorna `baseColor * tint + emission` e pula luzes, IBL e Fresnel de alfa.
  4. `Scene3DTextured.end` desenha em três grupos: opacos, depois `alpha` de trás para frente, depois `additive`.
- **Onde será usado:**
  - `drawPlasmas` (`gfx.d:888`) e `drawBeams` (`gfx.d:896`): viram brilho aditivo; hoje são esferas e caixas iluminadas pelo PBR.
  - `drawTranslucent` (`gfx.d:923`): o escudo (`M.shield`) e o anel de doca (`M.ring`) deixam de tapar a nave. Hoje o escudo usa opacidade quase zero para compensar.
  - `drawBackdrop` (`gfx.d:612`): estrelas e poeira sem iluminação e sem escrever profundidade.
  - `drawParticles` (`gfx.d:906`): pré-requisito de E4.
  - Permite juntar as duas cenas `lit` e `glow` do `Gfx` em uma.
- **Pronto quando:** dois tiros de plasma sobrepostos somam brilho em vez de um esconder o outro, e a nave fica visível através do escudo com opacidade 0,35.

### E4. Partículas com billboard e curva de alfa — FEITO (CPU)

> **FEITO (engine, versão CPU).** `engine.graphics.particles`: `ParticleSystem` (pool fixo, `spawn`/`update`/`draw`, cor e tamanho interpolados, alfa em `tint.a`), `ParticleEmitter` (taxa por segundo com resto fracionário, `burst`, cone, raio de spawn, velocidade herdada, semente própria), `setVolume` (caixa que dá a volta ao redor de um centro, com fade nas bordas XZ) e `Texture.softDisc`. No jogo: explosões, faíscas, pluma, RCS e a poeira de 1800 partículas usam isso. Fora de escopo: compute shader.

- **Hoje na engine:** não existe sistema de partículas (`grep -i particle` só acha um benchmark e o alocador). A única geometria plana é `TexMesh.quad` (`graphics/texmesh.d:66`), sem orientação para a câmera.
- **O que falta:** emissor, simulação e desenho instanciado de quads virados para a câmera, com cor, tamanho e alfa variando ao longo da vida.
- **Mudança proposta:** módulo `engine.graphics.particles`:
  - `ParticleEmitter { rate, burst, cone, speedMin/Max, damping, gravity, lifeMin/Max, sizeCurve[4], colorCurve[4], maxCount }`.
  - `ParticleSystem.emit(emitter, pos, dir)`, `update(dt)`, `draw(scene)`.
  - Simulação na CPU em `Pod!T[]`, um draw instanciado por emissor, quad expandido no vértice a partir de `cameraRight` e `cameraUp`, material aditivo sem iluminação (depende de E3).
  - Versão com compute shader fica para depois; a engine já usa compute em `water_sim_cs.wgsl`.
- **Onde será usado:** substitui `Particle`, `addParticle`, `spawnExplosion`, `spawnSparks`, `emitThrusters` e `drawParticles` em `gfx.d:55–437` e `gfx.d:906`. Hoje são no máximo 480 cubos (`MAX_PARTICLES`, `gfx.d:40`), um `drawMatrix` cada, que só encolhem. Voltam a pluma do propulsor (1000 partículas no Godot), a poeira ambiente (2000), as faíscas do cortador e os fragmentos das explosões.
- **Pronto quando:** 3000 partículas ativas custam um draw por emissor e mantêm 60 fps na máquina de desenvolvimento.

### E5. Tonemap linear e bloom configurável

- **Hoje na engine:** `PostSettings` (`gpu/post.d:17`) tem `exposure`, `bloom`, `fxaa`, `tonemapMode` (0 = ACES, 1 = Reinhard), `bloomThreshold`, `bloomKnee`, `bloomStrength`, `bloomClamp`. A cadeia de bloom tem 5 níveis fixos (`MAX_BLOOM_MIPS`, linha 29). A composição é sempre `hdr + bloom * strength` antes do tonemap (`post_tonemap.wgsl:30`).
- **O que falta:** tonemap linear (e AgX), composição do bloom em modo *screen*, raio do halo ajustável.
- **Mudança proposta:**
  1. `tonemapMode`: acrescentar `2 = linear` (só `clamp`) e `3 = AgX`.
  2. `bloomBlend` (`additive`, `screen`) e `bloomRadius` (número de níveis usados, 3 a 7).
  3. Opcional: `saturation` e `contrast` no mesmo passe.
- **Onde será usado:** `Gfx.initialize` (`gfx.d:140`), onde hoje se ajusta `app.post` com `bloomStrength 0.16`. O `WorldEnvironment` do Godot usava tonemap **Linear**, glow em modo *Screen*, `intensity 1.15`, `bloom 0.16`, `hdr_threshold 0.82`. O ACES atual dessatura o ciano do plasma e o âmbar das janelas; por isso as emissões de `window`, `solar`, `ice` e `shield` tiveram de ser reduzidas à mão.
- **Pronto quando:** uma esfera emissiva ciano pura `(0, 1, 1) × 4` sai na tela ciano saturado, não branco-azulado.

### E6. Luz ambiente e céu configuráveis

- **Hoje na engine:** `IblEnvironment.create` (`gpu/ibl.d:34`) é a única fábrica e gera sempre um céu diurno procedural (cubemap 64, irradiância 16, LUT 128). `Scene3DTextured.setEnvironment` (linha 311) aceita outro ambiente, mas não há como construir um.
- **O que falta:** ambiente de cor sólida ou gradiente, e um multiplicador de intensidade.
- **Mudança proposta:** `IblEnvironment.createSolid(gpu, layout, color)`, `createGradient(gpu, layout, zenith, horizon, ground)` e `FrameUniforms.iblIntensity`.
- **Onde será usado:** apaga o arquivo `source/game/env.d` inteiro (`DarkEnvironment`, que monta cubemaps 1×1 escuros pegando emprestados a LUT e o sampler de um ambiente doador). O valor do Godot era ambiente `(0.06, 0.08, 0.12) × 0.12`.
- **Pronto quando:** `createSolid` com preto deixa uma esfera sem luzes totalmente preta.

### E7. Mais de 8 luzes pontuais

- **Hoje na engine:** `MAX_POINT_LIGHTS = 8` e `MAX_SPOT_LIGHTS = 4` (`scene/light.d:27–29`), em arrays fixos dentro do UBO do frame. O roadmap da engine já cita *Clustered Forward Rendering* como evolução futura.
- **O que falta:** orçamento de luzes compatível com um combate.
- **Mudança proposta:** em dois passos.
  1. Curto prazo: subir para 32 pontuais em laço simples, movendo o array para um *storage buffer*. A cena é pequena e top-down, o custo é aceitável.
  2. Depois: seleção por tile ou cluster em compute.
- **Onde será usado:** `Gfx.collectLights` e `addLight` (`gfx.d:439–552`), que hoje pontuam candidatos e ficam com os 8 melhores. No Godot cada Eco, tiro de plasma, pickup, destroço e explosão tinha sua `OmniLight3D`. Com 6 Ecos, 3 tiros e a estação na tela, as luzes somem e voltam de um frame para o outro.
- **Pronto quando:** 24 luzes pontuais visíveis ao mesmo tempo sem nenhuma desaparecer ao mover a câmera.

### E8. Curva de atenuação de spot e ponto

- **Hoje na engine:** `rangeAttenuation` é fixa: `(1 − (d/r)⁴)² / (d² + 1)` (`common/pbr_brdf.wgsl:300`). O cone do spot é interpolação linear entre os cossenos, ao quadrado (`textured3d_pbr.wgsl:366–370`). `GpuPointLight` e `GpuSpotLight` (`scene/light.d:92–111`) não têm parâmetro de curva.
- **O que falta:** expoente de atenuação por luz, como `omni_attenuation` e `spot_attenuation` do Godot.
- **Mudança proposta:** campos `attenuation` em `GpuPointLight` e `GpuSpotLight`, e `angleAttenuation` no spot (cabem nos `_pad` dos UBOs de 48 e 128 bytes). Fórmula do Godot: `pow(max(1 − d/r, 0), attenuation)`, selecionável por flag para não quebrar as demos.
- **Onde será usado:** o holofote da nave em `collectLights` (`gfx.d:469`, alcance 60 m, cone 20°/38°). Com a queda `1/d²` ele morre muito antes dos 60 m, e por isso existem as constantes de compensação `SPOT_GAIN = 9` e `POINT_GAIN = 6` (`gfx.d:37–38`), que estouram o que está perto. Valores do Godot: `spot_attenuation 0.85`, `omni_attenuation 1.25`.
- **Pronto quando:** um asteroide a 50 m dentro do cone é legível sem que a nave fique estourada, com `SPOT_GAIN = 1`.

### E14. Sombras sem código manual

- **Hoje na engine:** a infraestrutura existe: `ShadowMap`, `PointShadowMap`, `SpotShadowMap`, `createShadowPipeline` (`gpu/shadow.d`), orçamento de 1 direcional, 4 pontuais e 2 spots (`scene/light.d:32–36`), e `Scene3DTextured.setLights(ls, &shadow, pts, spts)`.
- **O que falta:** o passe de profundidade precisa ser escrito pelo jogo, malha por malha, como em `source/demo/pbr.d`. A cena não reaproveita os lotes já enfileirados.
- **Mudança proposta:** `scene.renderShadows(frame, lightSet)` que percorre os mesmos lotes de `begin/drawMatrix` e desenha em cada mapa de sombra pedido por `castShadows`.
- **Onde será usado:** o jogo hoje não projeta nenhuma sombra (todas as luzes são criadas com `castShadows = false` em `gfx.d:444`). Com isso o holofote da nave lançaria sombras longas dos asteroides, que é o efeito de maior clima do roadmap "Beauty Corner".
- **Pronto quando:** ligar `castShadows` no spot do holofote produz sombra sem nenhuma linha extra de passe no jogo.

### E20. Limites de lote e instância com aviso

- **Hoje na engine:** `MAX_BATCHES = 32` e `MAX_INSTANCES_PER_BATCH = 512` (`scene3d_textured.d:100–101`). Ao passar de 32 lotes, `findOrAdd` devolve `null` e `drawMatrix` descarta o objeto em silêncio (linhas 518 e 338). O buffer de instâncias é alocado para 512 (linha 146), mas `instances ~= ...` cresce sem limite e `updateBuffer` grava o array inteiro (linha 350), ou seja, acima de 512 a escrita excede o buffer.
- **O que falta:** aviso e crescimento.
- **Mudança proposta:** `warn` único por frame no estouro de lotes; buffer de instâncias que realoca ao dobro; `MAX_BATCHES` configurável em `create`.
- **Onde será usado:** remove a divisão artificial em duas cenas (`lit` com cerca de 26 lotes e `glow` com cerca de 22) e o teto de 480 partículas, que existe só para não passar de 512 instâncias. Também é o que permite juntar estrelas e poeira em malhas menores.
- **Pronto quando:** desenhar 40 pares (malha, material) e 2000 instâncias de um mesmo par funciona, ou falha com mensagem no log.

---

## Parte 2 — Pós-processamento

### E9. Passe de pós-processamento customizado

- **Hoje na engine:** `PostProcessor` (`gpu/post.d:45`) tem a sequência fixa limiar, redução, ampliação, tonemap, FXAA, cópia. `Renderer.reloadPostShader` (linha 70) só recarrega os shaders já existentes.
- **O que falta:** inserir um passe próprio de tela cheia.
- **Mudança proposta:** `renderer.addPostPass(wgsl, uniformBytes, stage)` com `stage` em `beforeTonemap` ou `afterTonemap`, reutilizando `common/fullscreen_vs.wgsl`. Um segundo ponto de inserção depois da UI permitiria afetar a HUD.
- **Onde será usado:** `crt_overlay.gdshader` (linhas de varredura e vinheta) sobre a HUD, o menu (`drawMainMenu`, `hud.d:403`) e a oficina (`drawWorkshop`, `hud.d:497`). Também serve para o pulso vermelho de dano na tela e para aberração cromática no hit-stop.
- **Pronto quando:** um passe de vinheta de 10 linhas de WGSL funciona sem editar arquivos da engine.

---

## Parte 3 — Geometria

### E10. Primitivas e ruído procedural

- **Hoje na engine:** `TexMesh` oferece `cube`, `quad` e `sphere` (`graphics/texmesh.d:60–73`), além de `fromData`.
- **O que falta:** cilindro, cone e tronco, cápsula, prisma, toro, icosfera; junção de malhas com transformação; ruído (value, simplex, fbm).
- **Mudança proposta:** `engine.graphics.shapes` com essas fábricas devolvendo dados na CPU (`MeshData`) e `TexMesh.fromData` por cima; `MeshData.merge(other, transform)`; `engine.math.noise`.
- **Onde será usado:** `source/game/meshes.d` inteiro (`frustum`, `prism`, `torus`, `rockLobe`, `mineralAsteroid`, `iceAsteroid`, `quadField`, `trs`, `eulerDeg` e o ruído) sobe para a engine, com os testes de orientação de faces e normais que já existem lá. No jogo ficam só as receitas dos asteroides.
- **Pronto quando:** `meshes.d` cai para menos de 150 linhas.

---

## Parte 4 — Interface 2D

### E11. Linhas, polígonos, arcos e contorno de texto

- **Hoje na engine:** `UiBatchRenderer` (`ui/render/batch.d`) expõe `drawRect` (linha 323, com borda e raio) e `drawText` (linha 384). O recorte existe, mas `pushClip` e `popClip` são privados (linhas 286 e 311).
- **O que falta:** `drawLine`, `drawTriangle` ou `drawPolygon`, `drawArc` com espessura, rotação por desenho, contorno de texto, recorte público.
- **Mudança proposta:** acrescentar essas funções ao batch usando o mesmo formato de vértice; arco e linha com anti-serrilhado por distância no fragmento (`ui2d.wgsl`); `drawText(..., outlineColor, outlineWidth)`; tornar `pushClip`/`popClip` públicos.
- **Onde será usado:** `Ui.arc`, `Ui.line` e `Ui.dot` (`source/game/ui.d:234–258`) hoje desenham fileiras de retângulos redondos. São usados em `drawRadar` (`hud.d:195`: anéis, varredura, setas de borda, losangos de inimigos) e `drawReticle` (`hud.d:345`: arco de casco e de energia em volta da nave, velocímetro). `Ui.textOutlined` (`ui.d:152`) desenha o mesmo texto três vezes. O Godot usava `DrawArc`, `DrawLine`, `DrawColoredPolygon` e `DrawStringOutline`.
- **Pronto quando:** o radar inteiro custa menos de 300 vértices por frame (hoje são milhares de pontos).

### E12. Fonte com vários tamanhos e Unicode

- **Hoje na engine:** `Font` (`ui/text/font.d:24`) rasteriza uma única altura, definida em `loadFromMemory` (linha 48), em um atlas de 512×512. O cache tem 256 posições (`MAX_GLYPHS`, linha 27). Um codepoint ≥ 256 é rasterizado de novo a cada chamada e não é guardado (linhas 114–119 e 166), então cada uso consome mais espaço do atlas até ele encher (linha 177).
- **O que falta:** cache por (codepoint, tamanho) e crescimento do atlas.
- **Mudança proposta:** tabela hash `(codepoint, pixelHeight) -> Glyph`; atlas com páginas ou realocação; `drawText(font, size, ...)`. Alternativa melhor a prazo: atlas SDF único, com contorno e brilho de graça (ajuda E11).
- **Onde será usado:** `Ui` mantém dois `Font` e dois `UiBatchRenderer` (`ui.d:48–51`) só para ter 14 px e 24 px. `Ui.sanitize` (`ui.d:107`) descarta tudo fora de Latin-1, por isso os símbolos da HUD original (◈ ⚙ ⚡ ★ ▲) viraram texto. O título do menu e o banner de alerta ganham tamanhos próprios.
- **Pronto quando:** `drawText` com "◈ 120" em 14, 24 e 48 px funciona com um só `Font`, por 10 minutos, sem encher o atlas.

### E13. Imagens na UI e carregamento de PNG

- **Hoje na engine:** `Texture` carrega de pixels crus e TGA (`graphics/texture.d:35–110`). O binding de `stb_image` existe (`source/bindings/stb_image.d`), mas `Texture` não o usa. Existe o widget `image` (`ui/widgets/image.d`) que grava `textureHandle` no nó, porém `batch.d` não lê esse campo: o batch só conhece a textura do atlas de fonte.
- **O que falta:** `Texture.fromFile` para PNG/JPG e desenho de quad texturizado no batch.
- **Mudança proposta:** `Texture.fromImageFile(gpu, path)` via `stb_image`; `UiBatchRenderer.drawImage(texture, x, y, w, h, tint, uv)` com troca de bind group por segmento (a estrutura `Segment` já existe para o recorte).
- **Onde será usado:** ilustração do tutorial do escudo em `drawShieldModal` (`hud.d:581`), logotipo e arte da tela de título em `drawMainMenu`, ícones de recurso nos painéis, e as capturas para a página da Steam.
- **Pronto quando:** um PNG com transparência aparece na tela de título.

---

## Parte 5 — Plataforma, áudio e entrada

### E15. Janela: tela cheia, título, cursor e vsync

- **Hoje na engine:** `Window.create` chama `SDL_CreateWindow(title, w, h, 0)` (`platform/window.d:42`), sem flags. O único controle exposto é `setRelativeMouseMode`. `SDL_SetWindowTitle` e `SDL_HideCursor` estão no binding (`bindings/sdl3.d:346, 388`) mas sem invólucro; `SDL_SetWindowFullscreen` não está no binding. O modo de apresentação só é escolhido em `App.create`.
- **O que falta:** `setFullscreen`, `setTitle`, `setCursorVisible`, cursor customizado, janela redimensionável por opção, troca de vsync em execução.
- **Mudança proposta:** métodos em `Window` e `App.setPresentMode`; `Window.create` aceitando `WindowOptions { resizable, fullscreen, borderless }`.
- **Onde será usado:** opção "Tela cheia" do menu de configurações (existia no Godot; em `drawMainMenu` hoje só há iniciar, volume e sair). Esconder o cursor do sistema em voo, onde `drawReticle` já desenha a mira. É requisito da Fase 3 (configurações básicas para a Steam).
- **Pronto quando:** `F11` alterna tela cheia sem recriar o dispositivo GPU.

### E16. Áudio: mixer, ganho, laço e pitch

- **Hoje na engine:** `AudioEngine` (`audio/engine.d:100`) é um stream SDL; `play` enfileira o clipe no fim da fila (linha 137) e `stop` limpa tudo. Não há ganho, laço nem pitch. O comentário do próprio módulo (linhas 11–13) já diz que mixagem fica por fazer.
- **O que falta:** sons simultâneos, volume mestre e por voz, laço contínuo, variação de pitch.
- **Mudança proposta:** `AudioMixer` com N vozes misturadas em um callback de stream: `play(clip, gain, pitch, loop) -> VoiceId`, `setGain(voice, g)`, `stop(voice)`, `setMasterGain(g)`, e barramentos `sfx`/`music`. `SDL_SetAudioStreamGain` resolve o ganho mestre de imediato.
- **Onde será usado:** `source/game/audio.d` hoje abre **sete** streams (6 vozes e o drone, linhas 27–29), re-sintetiza todos os clipes a cada mudança de volume (`setVolume`, linha 50) e reenfileira o drone manualmente (`update`, linha 67). Com o mixer: uma voz em laço para o drone, pitch aleatório no tiro e nas coletas, volume mestre no controle deslizante do menu, e um barramento de música para a Fase 3.
- **Pronto quando:** oito tiros disparados em 100 ms tocam sobrepostos e o controle de volume atua sem estalo.

### E17. Mapa de ações de entrada

- **Hoje na engine:** `InputState` (`platform/input.d:255–309`) consulta teclado, mouse e gamepad separadamente (`keyDown`, `mousePressed`, `padDown`, `padLeftStick`...).
- **O que falta:** ações nomeadas com várias origens e remapeamento.
- **Mudança proposta:** `InputMap.bind("shoot", MouseButton.left, PadButton.rightShoulder)`, `input.actionDown/Pressed("shoot")`, `input.axis("move")` devolvendo `Vec2`, e gravação em arquivo.
- **Onde será usado:** o bloco de leitura em `source/app.d:88–112`, onde cada tecla está escrita à mão e o gamepad não é lido. Destrava suporte a controle (importante para a Steam e para o Steam Deck) e a tela de remapeamento.
- **Pronto quando:** o jogo inteiro é jogável no controle sem `if` extra em `app.d`.

### E23. Steamworks

- **Hoje na engine:** nada.
- **O que falta:** binding mínimo da API C (`steam_api`): inicialização, `RunCallbacks`, conquistas, estatísticas, sobreposição e nuvem de saves.
- **Mudança proposta:** `bindings/steam.d` e `engine.platform.steam` com `Steam.init(appId)`, `unlock("ACH_BEACON")`, `update()` por frame, tudo opcional por `version(Steam)`.
- **Onde será usado:** Fase 3 do roadmap do `AGENTS.md`. Os três finais em `Sim` (*The Beacon*, *The Lone Ghost*, *Cold Void*) e os três marcos de missão viram conquistas, disparadas a partir da fila de eventos que `app.d` já esvazia.
- **Pronto quando:** uma conquista de teste aparece na sobreposição com o app ID de desenvolvimento.

---

## Parte 6 — Núcleo e ferramentas

### E18. Passo fixo e escala de tempo

- **Hoje na engine:** `App` mede o frame e limita o FPS (`setTargetFps`, `app.d:59`); o `dt` vem de `FpsCounter.tick`. Não há acumulador nem escala de tempo.
- **O que falta:** laço de simulação com passo fixo e `timeScale` global.
- **Mudança proposta:** `GameClock { fixedDt, timeScale, maxSteps }` com `clock.advance(realDt)` devolvendo quantos passos rodar e o `alpha` de interpolação.
- **Onde será usado:** `source/app.d:82–83` (teto manual de `dt` em 0,05 s) e o hit-stop feito à mão com `sim.timeScale` (`app.d:116`). Com passo fixo a `Sim` fica determinística por semente também no jogo real, não só nos testes, o que permite gravar e reproduzir partidas para depurar.
- **Pronto quando:** a mesma semente e as mesmas entradas produzem o mesmo estado final a 30 e a 144 fps.

### E19. Tweens e temporizadores

- **Hoje na engine:** não existe utilitário de interpolação temporal de uso geral.
- **O que falta:** equivalente a `CreateTween` e `CreateTimer` do Godot.
- **Mudança proposta:** `engine.core.tween`: `Tweens.to(&value, target, seconds, Ease.outCubic)`, `Timers.after(seconds, callback)`, atualizados uma vez por frame, sem alocação por tween.
- **Onde será usado:** `AlertBanner` (`hud.d`, entrada e saída do banner), a abertura das telas de oficina e fim de jogo (hoje aparecem de uma vez), o `Flash` de luz de explosão em `gfx.d:65`, e o tremor de câmera.
- **Pronto quando:** o painel da oficina desliza para dentro em 0,2 s com uma linha de código.

### E21. Engine consumível como dependência dub

- **Hoje na engine:** o `dub.json` da engine usa caminhos relativos ao diretório de trabalho (`-P-Ivendor/box3d/include`, `-L./libs`), que só funcionam compilando de dentro da própria engine.
- **O que falta:** caminhos baseados em `$PACKAGE_DIR` e um exemplo de projeto externo.
- **Mudança proposta:** trocar para `-P-I$PACKAGE_DIR/vendor/box3d/include` e `-L$PACKAGE_DIR/libs`; adicionar `examples/external-game/` com um `dub.json` mínimo; documentar em `docs/game-development-guide.md`.
- **Onde será usado:** remove o symlink `vendor` e a linha `lflags-linux` do `dub.json` do jogo. É também pré-requisito para compilar a versão Windows.
- **Pronto quando:** um projeto novo em outra pasta compila só com `"dependencies": {"game-engine": {"path": "..."}}`.

### E22. Captura de tela em PNG

- **Hoje na engine:** `Renderer.requestCapture` e `readCapture` (`gpu/renderer.d:417, 441`) devolvem RGBA cru.
- **O que falta:** gravação em arquivo.
- **Mudança proposta:** `app.saveScreenshot(path)` com `stb_image_write` (ou um codificador PNG mínimo sem compressão).
- **Onde será usado:** substitui `savePpm` em `source/app.d:300`; tecla de captura para as imagens da página da Steam e para comparar com o Godot lado a lado.
- **Pronto quando:** `F12` grava um PNG que abre em qualquer visualizador.

---

## Dependências e ordem

```
E2 ──┬─> E1 (o trecho de shader lê time e custom)
     └─> E3 ──> E4 (partículas precisam de aditivo e unlit)
E20 ───> E3 (juntar as cenas lit e glow)
E5, E6, E8 independentes
E7 independente (E14 fica mais útil depois)
E12 ──> E11 (contorno de texto sai de graça com SDF)
E21 antes de qualquer build para Windows
```

Ordem que recomendo, do maior retorno visual por esforço para o menor:

1. **E2 + E3 + E20.** Plasma, feixes, escudo, anel, flash de dano e pulsação por objeto. É pouco código e é o que mais muda a primeira impressão.
2. **E5 + E8 + E6.** Três mudanças pequenas em shader que devolvem a cor e o alcance do holofote, e apagam `env.d`.
3. **E7.** Acaba com as luzes piscando em combate.
4. **E1.** O maior item; devolve as superfícies procedurais do casco, da rocha e do gelo.
5. **E4.** Pluma, poeira e explosões.
6. **E12 + E11 + E13**, depois **E9.** HUD com símbolos, arcos limpos e o filtro CRT.
7. **E14.** Sombras do holofote.
8. **E16, E15, E17.** Som, tela cheia e controle, para a Fase 3.
9. **E21, E22, E18, E19, E10, E23** conforme o empacotamento pedir.

Os itens 1 a 5 cobrem tudo o que hoje faz o jogo parecer pior do que a versão Godot.
