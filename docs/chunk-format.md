# GESC: binary scene chunks

`engine.scene.chunk_binary` reads and writes `.gesc`, a compact, compressed container for the content of a
`game-engine.scene` chunk. It replaces `chunk_<x>_<z>.scene.json` for streamed worlds; the JSON path still
works (the streamer picks the reader by the file's content, not its extension).

## Why

JSON costs parse time and size: the 9 km² Viatura VI map was 22.5 MB / 55 k entities and took ~2 s just to
parse. As 144 `.gesc` chunks it is 1.3 MB and each chunk decodes on its own.

## Layout (little-endian)

```
header : "GESC" | version u32 | blockCount u32 | reserved u32          (16 bytes)
table  : blockCount x { kind u32 | codec u32 | offset u64 | storedSize u32 | rawSize u32 | crc32 u32 | pad u32 }
blocks : payloads, 16-byte aligned; crc32 is over the decompressed bytes
```

Codecs: `0` stored, `1` zstd (a block is stored raw when compression does not shrink it).

### zstd backend and levels

Blocks are standard zstd frames (with content size and checksum), produced and read by `engine.assets.zstd`, which is
backed by the pure-D zipd codec vendored in `vendor/zipd` (no C library, no GC, no threads). Frames interoperate with
the reference implementation in both directions: `zstd -d` reads what the engine writes, and the engine reads frames
from `zstd`/libzstd (dictionaries are not supported). The unit tests carry frames written by the zstd CLI and, when the
CLI is installed, check our frames against `zstd -d`.

The zipd encoder has levels `1..9` (match-search effort); `--level` / `encodeChunk(..., level)` values outside that
range are clamped (`0` and negatives become 1, libzstd levels `10..19` and above become 9). The default stays 6. The
encoder uses a 1 MiB window and a hash-chain matcher, so it is slower than libzstd (decoding roughly 5-7x, encoding 2x at
level 6 with an optimized build) at similar ratios; on scene chunks (tens of KB) the sizes are within a few percent.

| Kind | Content |
|:---|:---|
| `header` | schema version, meta, settings, cell bounds, chunk manifest, string table |
| `entities` | count, then one **column** per field: ids, parents, name indices, flags, pos x/y/z, rot x/y/z/w, scale x/y/z |
| `visual` / `material` / `physics` / `light` | records for the entities that have the component, in entity order |
| `assetLinks` | `{guid, path, kind}` |
| `customJson` | custom components `{entity index, type name, json}` (resolved by name at load, like scene JSON) |
| `user` | named, opaque blocks that a game defines (packed instance arrays, light lists...) |
| `types` (v2) | schema of every binary component type: name, `sizeof`, `alignof`, fields (name, `@formerlyNamed`, `FieldKind`, offset, size, array length) |
| `component` (v2) | one block per type: type name, block-local string table, entity indices, then the raw component structs |

Unknown block kinds are skipped, so a newer writer's extra blocks do not break an older reader. A reader never
trusts a size: counts are checked against the bytes left, block offsets against the file length, decoded
sizes against the zstd frame header, and every block against its CRC32.

## Binary component blocks (version 2)

`customJson` costs one `parseJSON` per component (55 k components made up ~450 ms of the 22.5 MB map's decode).
`engine.scene.chunk_components` cooks the custom components whose type the *writing* process registers into
`types` + `component` blocks instead; the rest stay in `customJson`.

```
types     : u32 typeCount | per type: str name | u32 sizeof | u32 alignof | u32 fieldCount |
            per field: str name | str formerlyNamed | u8 FieldKind | u32 offset | u32 size | u32 arrayLen
component : str typeName | u32 count | u32 stringCount, stringCount x str |
            u32 entityIndex[count] | zero padding to 16 bytes (relative to the block) | count x sizeof structs
```

- **Mapping is by type name** (`TypeRegistry.find`). A `ComponentTypeId` is an index into one process's registry
  and is not stable across processes, so it is never stored. A stored type the reading world does not register
  is skipped and reported (`GescApplyResult.unresolvedTypes`, a warning in `WorldStreamer`).
- **Same layout** (same size and fields at the same offsets): the records are copied with one memcpy into one
  array and inserted with `SceneWorld.rawAddBatch`. **Different layout** (field added, removed, renamed with
  `@formerlyNamed`, numeric type changed, e.g. `uint` to `float`): each reader field is filled from the stored
  field with the same name (or its `@formerlyNamed` name); anything the file lacks keeps the reader's default.
  `struct_` / fixed-array fields are copied raw only when kind and size match, and must not contain `StringId`
  or entity references.
- **`StringId`** fields are stored as indices into the block's own string table and re-interned into the
  world's `StringTable` on load. **`@entityRef uint`** fields (`engine.reflect.attrs.entityRef`) hold the
  chunk-local entity id and are remapped to the live `EntityId` (`0` or an unknown id becomes `EntityId.max`).
- JSON stays the editable source (`*.scene.json`); `.gesc` is the cooked artifact. A component whose JSON does not
  fit its registered type stays in `customJson`, and so does a type that holds a `StringId` or `@entityRef` inside a
  nested struct or fixed array (binary records only rewrite top-level ones). `gescMaterializeJson` turns binary components back into JSON
  using the schemas stored in the file (no registry needed).

### Compatibility

- A file with `types` / `component` blocks is stamped **version 2**; a file without them stays **version 1**
  (byte-identical to what the previous writer produced). The current reader accepts both: chunks written before
  version 2, or chunks whose components are all JSON, load unchanged. A version-1-only reader rejects a version-2
  file ("unsupported GESC version") instead of silently dropping its components.
- Decoding and applying are separate: `decodeChunk` only needs buffers and keeps the raw `typesBlock` /
  `componentBlocks`; `applyGescComponents` / `applyChunk` need the destination `SceneWorld`.

## API

- `encodeChunk(scene, userBlocks, zstdLevel)` / `decodeChunk(bytes, out chunk, out err)`: whole-file round trip
  (`sceneToMinifiedJson` of the result equals the input's).
- `encodeChunkWithComponents(scene, types, strings, userBlocks, zstdLevel)` (`engine.scene.chunk_components`):
  like `encodeChunk`, plus binary components for every type registered in `types`.
- `applyChunk(world, chunk, rootOffset, opts, out comps)`: batched spawn of the chunk's entities, binary
  components by type name, JSON fallback for the rest. `applyGescComponents` is the components half alone.
- `gescInfo(bytes, out info, out err)`: block table for tools (component blocks list their type name).
- `parseChunkBytes(bytes)`: GESC or JSON, by content (used by `WorldStreamer`).
- `GescBlockHandler { name, onLoad, onUnload, ctx }` + `WorldStreamer.addBlockHandler`: a game gets its own
  `user` blocks when a chunk becomes active and a call when it unloads, with no ECS entity per item.

## GC-free decoding (streamer worker)

`engine.scene.chunk_binary_nogc` is a second decoder with the same acceptance rules and error strings as
`decodeChunk`, built to run on the `WorldStreamer` worker thread (GC-excluded):

- `readChunkNoGc(bytes, chunk, err)` (`nothrow @nogc`) validates the container, checks every CRC, inflates the zstd
  blocks and decodes header, entity columns, visual / material / physics / light records, asset links, user blocks
  and the raw `types` / `component` blocks into a `GescChunkNoGc`. A decode is a handful of `malloc`s and no GC
  allocation (tested like `zstd.noGcAllocation`).
- `GescChunkNoGc` owns a chain of malloc blocks: move-only (`@disable this(this)`), freed by `release()` or its
  destructor. Strings and slices inside are non-owning views valid until then; never append to or keep them.
  `gescChunkNoGcNew` / `gescChunkNoGcFree` give a heap handle (the streamer's job records copy handles around), and
  `gescNoGcLiveAllocations()` / `gescNoGcLiveBytes()` expose accounting for leak tests.
- `applyChunkNoGc(world, chunk, ...)` (main thread) lends the decoded rows to `applyChunk` as a zero-copy view.
- `toGescChunk` makes a deep GC copy, equivalent to `decodeChunk`'s result (used by the equivalence tests).

Limits: `customJson` blocks are validated structurally on the worker but their JSON text is parsed on the main
thread at apply time (`std.json` needs the GC), so a JSON syntax error surfaces there, not in `readChunkNoGc`.
`*.scene.json` chunks have no GC-free path and are still parsed on the main thread. Cook custom components into
binary blocks (`encodeChunkWithComponents`) to keep the main thread free of JSON.

## Tool

`dub build --config=gesc` builds `game-engine-gesc`:

```
game-engine-gesc encode <in.scene.json> <out.gesc> [--level=6]
game-engine-gesc decode <in.gesc> <out.scene.json>
game-engine-gesc info   <file.gesc>
game-engine-gesc verify <file.gesc> ...
game-engine-gesc split  <in.scene.json> <outDir> [--cell-size=256] [--level=6] [--json]
game-engine-gesc bench  <in.scene.json>
```

`decode` refuses files that carry binary component blocks (the tool does not link `chunk_components` yet; keep the
`.scene.json` source). `bench` measures the SceneFile-level decode.

`split` writes one chunk per cell (by the XZ origin of each root entity; children follow their parent, ids and
strings are renumbered per chunk) plus `world.scene.json`, a v2 root scene with the chunk manifest.

## Versioning

New data = a new block kind (old readers skip it); data an old reader must not lose bumps the version, as the
binary component blocks do (`GESC_VERSION = 2`, `GESC_VERSION_BASE = 1`). An incompatible change bumps `GESC_VERSION`; convert old
files with `decode` + `encode` or rebuild them from the JSON source, which stays the editable form.

## Known limitations

- **Integrity:** CRC32 covers block payloads only. The file header, the block table and alignment padding have no
  checksum; table fields are bounds-checked on decode, so a flipped bit there is either rejected or harmless padding.
- **Failed chunks:** a chunk that fails to decode goes `active` with zero entities, counts as a load and is retried on
  every reload (two warning lines each time). The rest of the world keeps streaming.
- **CLI tool:** `game-engine-gesc` does not link the component layer (it does not know game types). `decode` refuses
  files with binary component blocks and `encode` cannot cook them; call `encodeChunkWithComponents` from the game.
- **Pak:** `scenePath` values must equal the pak keys (for example `Assets/world/x.gesc`). The engine does not mount
  the embedded pak at startup (`mountAssetPak`); the game must. Do not unmount a pak while workers are streaming.
- **GC use on the main thread:** non-cooked `customJson` and `.scene.json` chunks are parsed with the GC on the main
  thread; cook components into binary blocks to avoid it.
- **Compression:** the zipd codec supports levels 1..9 only, a 1 MiB encoder window and no dictionaries; decoding is
  several times slower than libzstd but small in absolute terms (well under 1 ms for a typical chunk).
- **Not implemented:** block index for mmap, header/table checksum, and an automatic version migration command.
