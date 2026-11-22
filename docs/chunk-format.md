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

Unknown block kinds are skipped, so a newer writer's extra blocks do not break an older reader. A reader never
trusts a size: counts are checked against the bytes left, block offsets against the file length, decoded
sizes against the zstd frame header, and every block against its CRC32.

## API

- `encodeChunk(scene, userBlocks, zstdLevel)` / `decodeChunk(bytes, out chunk, out err)`: whole-file round trip
  (`sceneToMinifiedJson` of the result equals the input's).
- `gescInfo(bytes, out info, out err)`: block table for tools.
- `parseChunkBytes(bytes)`: GESC or JSON, by content (used by `WorldStreamer`).
- `GescBlockHandler { name, onLoad, onUnload, ctx }` + `WorldStreamer.addBlockHandler`: a game gets its own
  `user` blocks when a chunk becomes active and a call when it unloads, with no ECS entity per item.

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

`split` writes one chunk per cell (by the XZ origin of each root entity; children follow their parent, ids and
strings are renumbered per chunk) plus `world.scene.json`, a v2 root scene with the chunk manifest.

## Versioning

New data = a new block kind (old readers skip it). An incompatible change bumps `GESC_VERSION`; convert old
files with `decode` + `encode` or rebuild them from the JSON source, which stays the editable form.
