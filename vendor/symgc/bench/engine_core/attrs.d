/**
 * Vendored from leotada/game-engine commit 88f28dfe57e51de07e5f0ceaa1e9e0264c6bec9c
 * Path: source/engine/core/attrs.d
 */
/**
 * Documentation / lint markers for GC-safe engine storage.
 *
 * Types tagged `@noGcStorage` are engine-owned and must contain no
 * GC-traced indirections.  `dub run --config=lint` fails CI if a marked
 * struct (or any engine struct outside jph/) stores `string`, slices,
 * delegates, or class refs.
 *
 * See docs/gc-safe-architecture-plan.md §2.5.
 */
module engine_core.attrs;

@safe:

/// Marks a struct as engine-owned storage. Lint fails if it has GC indirections.
struct noGcStorage {}
