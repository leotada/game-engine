/// Minimal C bindings for zstd (vendored in `vendor/zstd`, built into `libzstd_engine.a` by
/// `tools/build_sdl3_deps.sh`). Only the one-shot API the engine needs.
module bindings.zstd;

extern (C) @nogc nothrow:

size_t ZSTD_compressBound(size_t srcSize);
size_t ZSTD_compress(void* dst, size_t dstCapacity, const(void)* src, size_t srcSize, int compressionLevel);
size_t ZSTD_decompress(void* dst, size_t dstCapacity, const(void)* src, size_t compressedSize);
uint ZSTD_isError(size_t code);
const(char)* ZSTD_getErrorName(size_t code);
ulong ZSTD_getFrameContentSize(const(void)* src, size_t srcSize);
int ZSTD_maxCLevel();

enum ulong ZSTD_CONTENTSIZE_UNKNOWN = ulong.max;
enum ulong ZSTD_CONTENTSIZE_ERROR = ulong.max - 1;
