# Plano: Hot reload (assets + dados)

> **Status:** pendente · Prioridade: média · Ver [roadmap.md](roadmap.md)

## Objetivo

Iterar conteúdo sem restart do processo: recarregar texturas/meshes/WAV e
tunables de dados durante o desenvolvimento.

**v1 = assets + dados apenas.** Reload de código D (shared `.so`) e
embed de Lua/Wren ficam **fora de escopo**.

## Estado atual

- Gameplay em D no mesmo binário (`dub run --config=…`)
- Assets BMP/glTF/WAV são load-once; sem watcher
- Sem VM, sem `dlopen` de systems

## Fora de escopo (v1)

- Shared library + `dlopen` de systems de gameplay
- Linguagem de scripting embutida (Lua/Wren/etc.)
- Reload do core GPU/bindings
- Play-in-editor (ver [plan-editor-ux.md](plan-editor-ux.md) backlog)

## Dependências

- Handles GPU / `StringId` para swap seguro de recursos
- UX de “reload” pode aparecer no overlay ou no editor depois

## Fases

### HR-1 — Hot reload de assets

- [ ] Watcher de arquivos (inotify) para texturas / glTF / WAV
- [ ] Reimport + swap de GPU resources / handles
- [ ] Ownership: loaders em `engine.assets`; upload em `engine.gpu` /
  `engine.graphics` — documentar quem libera o recurso antigo
- [ ] Log claro em falha de parse (mantém asset anterior)

**DoD:** editar um BMP/TGA em disco atualiza a textura sem fechar o jogo.

### HR-2 — Dados de jogo

- [ ] Formato simples (JSON ou TOML) para tunables: speeds, HP, spawns
- [ ] Reload aplica em componentes vivos via `StringId` keys
- [ ] Strings temporárias de debug via `FrameArena`

**DoD:** mudar um float no arquivo de dados altera comportamento no próximo
reload (tecla ou debounce do watcher).

### HR-3 — DX

- [ ] Comando / tecla “reload all”
- [ ] Overlay mostra último reload / erros
- [ ] Nota curta no game-development-guide

**DoD:** um atalho recarrega assets+dados observados.

## Critérios de aceite

1. Mudar uma textura em disco reflete no jogo sem restart (HR-1).
2. Mudar um tunable em arquivo de dados aplica em runtime (HR-2).
3. Nenhum path de hot-reload de código D ou VM na v1.

## Referências

- `source/engine/assets/`, `devtools/overlay.d`, `core/strings.d`
- [plan-editor-ux.md](plan-editor-ux.md)
