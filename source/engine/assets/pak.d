/// Encrypted / obfuscated asset container (`GEPK` v1) and runtime VFS loader.
///
/// Packs asset files into a single binary container where path strings are never
/// stored in plaintext (indexed only by normalized FNV-1a 64-bit hashes) and
/// both the table of contents and every asset payload are stream-encrypted with
/// a SplitMix64 XOR keystream keyed by a 64-bit build key and per-entry salt.
///
/// When mounted via `mountAssetPak` / `mountAssetPakFile`, callers using
/// `readAssetBytes` / `assetExists` (such as `Font.loadFromFile`,
/// `Texture.fromImageFile`, and `gltf` loaders) transparently read decrypted
/// bytes from memory instead of loose files on disk.
module engine.assets.pak;

import std.algorithm : sort;
import std.conv : to;
import std.exception : enforce;
import std.file : dirEntries, exists, isDir, isFile, read, SpanMode;
import std.path : absolutePath, buildPath, relativePath;

@safe:

enum ulong DEFAULT_ASSET_PAK_KEY = 0x4745_504B_5052_4F54UL;
enum uint GEPK_VERSION = 1;

private enum ubyte[4] GEPK_MAGIC = [0x47, 0x45, 0x50, 0x4B]; // "GEPK"
private enum size_t HEADER_SIZE = 16;
private enum size_t ENTRY_SIZE = 24;
private enum size_t TOC_TAG_SIZE = 8;
private enum ulong TOC_TAG_VALUE = 0x5645_5249_4659_3031UL;
private enum ulong TOC_SALT_ID = 0x4745_504B_544F_4331UL;

/// Input file entry passed to `buildAssetPak`.
struct PakInput {
    string path;
    const(ubyte)[] data;
}

/// Decoded table-of-contents entry inside a `GEPK` archive.
struct PakEntry {
    ulong pathHash;
    ulong offset;
    ulong size;
}

private struct MountedAssetPak {
    bool mounted = false;
    bool allowDiskFallback = false;
    ulong key = 0;
    const(ubyte)[] rawBytes;
    PakEntry[] entries;
}

private __gshared MountedAssetPak g_mountedPak;

private void writeU32LE(scope ubyte[] dst, uint v) pure nothrow @nogc {
    dst[0] = cast(ubyte)(v & 0xFF);
    dst[1] = cast(ubyte)((v >> 8) & 0xFF);
    dst[2] = cast(ubyte)((v >> 16) & 0xFF);
    dst[3] = cast(ubyte)((v >> 24) & 0xFF);
}

private uint readU32LE(scope const(ubyte)[] src) pure nothrow @nogc {
    return cast(uint) src[0]
        | (cast(uint) src[1] << 8)
        | (cast(uint) src[2] << 16)
        | (cast(uint) src[3] << 24);
}

private void writeU64LE(scope ubyte[] dst, ulong v) pure nothrow @nogc {
    foreach (i; 0 .. 8) {
        dst[i] = cast(ubyte)((v >> (i * 8)) & 0xFF);
    }
}

private ulong readU64LE(scope const(ubyte)[] src) pure nothrow @nogc {
    ulong v = 0;
    foreach (i; 0 .. 8) {
        v |= cast(ulong) src[i] << (i * 8);
    }
    return v;
}

private bool isSep(char c) pure nothrow @nogc {
    return c == '/' || c == '\\';
}

/// Normalize a relative asset path into canonical forward-slash form
/// (e.g. `./Assets\\Models//ship.glb` -> `Assets/Models/ship.glb`).
string normalizePakPath(scope const(char)[] path) pure {
    char[] outChars;
    outChars.reserve(path.length);

    size_t i = 0;
    bool firstSeg = true;
    while (i < path.length) {
        while (i < path.length && isSep(path[i])) {
            i++;
        }
        if (i >= path.length) break;

        size_t start = i;
        while (i < path.length && !isSep(path[i])) {
            i++;
        }
        auto seg = path[start .. i];
        if (seg == ".") continue;

        if (!firstSeg) outChars ~= '/';
        outChars ~= seg;
        firstSeg = false;
    }
    return outChars.idup;
}

/// Compute normalized FNV-1a 64-bit hash of a relative asset path without allocating.
ulong pakPathHash(scope const(char)[] path) pure nothrow @nogc {
    ulong h = 0xcbf29ce484222325UL;
    enum ulong FNV_PRIME = 0x100000001b3UL;

    size_t i = 0;
    bool firstSeg = true;
    while (i < path.length) {
        while (i < path.length && isSep(path[i])) {
            i++;
        }
        if (i >= path.length) break;

        size_t start = i;
        while (i < path.length && !isSep(path[i])) {
            i++;
        }
        auto seg = path[start .. i];
        if (seg == ".") continue;

        if (!firstSeg) {
            h ^= cast(ulong) '/';
            h *= FNV_PRIME;
        }
        foreach (char c; seg) {
            h ^= cast(ulong) cast(ubyte) c;
            h *= FNV_PRIME;
        }
        firstSeg = false;
    }
    return h;
}

/// Symmetric SplitMix64 XOR stream cipher used to obfuscate TOC and payloads.
void pakCrypt(scope ubyte[] data, ulong key, ulong pathHash, ulong salt) pure nothrow @nogc {
    ulong state = key ^ pathHash ^ salt ^ 0xA076_1D64_78BD_642FUL;
    size_t i = 0;
    while (i + 8 <= data.length) {
        state += 0x9E37_79B9_7F4A_7C15UL;
        ulong z = state;
        z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBUL;
        ulong ks = z ^ (z >> 31);
        foreach (b; 0 .. 8) {
            data[i + b] ^= cast(ubyte)((ks >> (b * 8)) & 0xFF);
        }
        i += 8;
    }
    if (i < data.length) {
        state += 0x9E37_79B9_7F4A_7C15UL;
        ulong z = state;
        z = (z ^ (z >> 30)) * 0xBF58_476D_1CE4_E5B9UL;
        z = (z ^ (z >> 27)) * 0x94D0_49BB_1331_11EBUL;
        ulong ks = z ^ (z >> 31);
        size_t b = 0;
        while (i < data.length) {
            data[i] ^= cast(ubyte)((ks >> (b * 8)) & 0xFF);
            i++;
            b++;
        }
    }
}

/// Build an encrypted `GEPK` v1 container from in-memory inputs.
ubyte[] buildAssetPak(scope const(PakInput)[] inputs, ulong key, uint tocSeed = 0x4745_504BU) pure {
    immutable size_t count = inputs.length;
    immutable size_t tocBytesLen = count * ENTRY_SIZE + TOC_TAG_SIZE;
    immutable size_t dataStart = HEADER_SIZE + tocBytesLen;

    size_t totalPayload = 0;
    foreach (ref inp; inputs) {
        totalPayload += inp.data.length;
    }

    ubyte[] pak = new ubyte[dataStart + totalPayload];
    pak[0 .. 4] = GEPK_MAGIC[];
    writeU32LE(pak[4 .. 8], GEPK_VERSION);
    writeU32LE(pak[8 .. 12], cast(uint) count);
    writeU32LE(pak[12 .. 16], tocSeed);

    ulong[] seenHashes = new ulong[count];
    size_t cursor = dataStart;
    foreach (idx, ref inp; inputs) {
        immutable ulong h = pakPathHash(inp.path);
        foreach (prev; seenHashes[0 .. idx]) {
            enforce(prev != h, "buildAssetPak: duplicate or colliding normalized path hash for " ~ inp.path);
        }
        seenHashes[idx] = h;

        immutable ulong off = cast(ulong) cursor;
        immutable ulong sz = cast(ulong) inp.data.length;

        immutable size_t tocOff = HEADER_SIZE + idx * ENTRY_SIZE;
        writeU64LE(pak[tocOff .. tocOff + 8], h);
        writeU64LE(pak[tocOff + 8 .. tocOff + 16], off);
        writeU64LE(pak[tocOff + 16 .. tocOff + 24], sz);

        if (inp.data.length > 0) {
            pak[cursor .. cursor + inp.data.length] = inp.data[];
            pakCrypt(pak[cursor .. cursor + inp.data.length], key, h, off * 0x9E37_79B9_7F4A_7C15UL);
        }
        cursor += inp.data.length;
    }

    immutable size_t tagOff = HEADER_SIZE + count * ENTRY_SIZE;
    writeU64LE(pak[tagOff .. tagOff + TOC_TAG_SIZE], TOC_TAG_VALUE);
    pakCrypt(pak[HEADER_SIZE .. HEADER_SIZE + tocBytesLen], key, TOC_SALT_ID, cast(ulong) tocSeed);

    return pak;
}

/// Decrypt and validate the `GEPK` v1 table of contents.
bool parseAssetPakToc(scope const(ubyte)[] pakBytes, ulong key, out PakEntry[] outEntries) @safe {
    outEntries = null;
    if (pakBytes.length < HEADER_SIZE + TOC_TAG_SIZE) return false;
    if (pakBytes[0 .. 4] != GEPK_MAGIC[]) return false;
    if (readU32LE(pakBytes[4 .. 8]) != GEPK_VERSION) return false;

    immutable uint count = readU32LE(pakBytes[8 .. 12]);
    immutable uint tocSeed = readU32LE(pakBytes[12 .. 16]);

    immutable size_t availForToc = pakBytes.length - HEADER_SIZE - TOC_TAG_SIZE;
    if (cast(size_t) count > availForToc / ENTRY_SIZE) return false;

    immutable size_t tocLen = cast(size_t) count * ENTRY_SIZE + TOC_TAG_SIZE;
    immutable size_t dataStart = HEADER_SIZE + tocLen;

    ubyte[] tocBuf = pakBytes[HEADER_SIZE .. HEADER_SIZE + tocLen].dup;
    pakCrypt(tocBuf, key, TOC_SALT_ID, cast(ulong) tocSeed);

    if (readU64LE(tocBuf[tocLen - TOC_TAG_SIZE .. tocLen]) != TOC_TAG_VALUE) {
        return false;
    }

    PakEntry[] entries = new PakEntry[count];
    foreach (i; 0 .. count) {
        immutable size_t base = i * ENTRY_SIZE;
        PakEntry e;
        e.pathHash = readU64LE(tocBuf[base .. base + 8]);
        e.offset = readU64LE(tocBuf[base + 8 .. base + 16]);
        e.size = readU64LE(tocBuf[base + 16 .. base + 24]);

        if (e.offset < dataStart || e.size > pakBytes.length || e.offset > pakBytes.length - e.size) {
            return false;
        }
        entries[i] = e;
    }

    outEntries = entries;
    return true;
}

private bool extractWithEntries(
    scope const(ubyte)[] pakBytes,
    scope const(PakEntry)[] entries,
    ulong key,
    scope const(char)[] path,
    out ubyte[] outBytes
) @safe {
    outBytes = null;
    immutable ulong targetHash = pakPathHash(path);
    foreach (ref e; entries) {
        if (e.pathHash == targetHash) {
            immutable size_t off = cast(size_t) e.offset;
            immutable size_t sz = cast(size_t) e.size;
            if (off + sz > pakBytes.length) return false;
            outBytes = pakBytes[off .. off + sz].dup;
            if (sz > 0) {
                pakCrypt(outBytes, key, e.pathHash, e.offset * 0x9E37_79B9_7F4A_7C15UL);
            }
            return true;
        }
    }
    return false;
}

/// Extract and decrypt one asset directly from raw `GEPK` bytes.
bool readAssetFromPak(scope const(ubyte)[] pakBytes, ulong key, scope const(char)[] path, out ubyte[] outBytes) @safe {
    outBytes = null;
    PakEntry[] entries;
    if (!parseAssetPakToc(pakBytes, key, entries)) return false;
    return extractWithEntries(pakBytes, entries, key, path, outBytes);
}

/// Return true if `path` exists inside the given `GEPK` buffer for `key`.
bool pakContains(scope const(ubyte)[] pakBytes, ulong key, scope const(char)[] path) @safe {
    PakEntry[] entries;
    if (!parseAssetPakToc(pakBytes, key, entries)) return false;
    immutable ulong targetHash = pakPathHash(path);
    foreach (ref e; entries) {
        if (e.pathHash == targetHash) return true;
    }
    return false;
}

/// Recursively collect all regular files in `inputDir` (sorted deterministically)
/// and pack them into an encrypted `GEPK` v1 container.
ubyte[] packDirectoryToPak(
    string inputDir,
    ulong key,
    string pathPrefix = "",
    uint tocSeed = 0x4745_504BU
) @trusted {
    enforce(exists(inputDir) && isDir(inputDir), "packDirectoryToPak: directory not found: " ~ inputDir);

    immutable string absInputDir = absolutePath(inputDir);
    string[] relPaths;
    foreach (entry; dirEntries(absInputDir, SpanMode.depth)) {
        if (!entry.isFile) continue;
        relPaths ~= normalizePakPath(relativePath(entry.name, absInputDir));
    }
    relPaths.sort();

    immutable string normPrefix = normalizePakPath(pathPrefix);
    PakInput[] inputs = new PakInput[relPaths.length];
    foreach (i, rel; relPaths) {
        immutable string keyPath = normPrefix.length > 0 ? (normPrefix ~ "/" ~ rel) : rel;
        immutable string diskPath = buildPath(absInputDir, rel);
        inputs[i] = PakInput(keyPath, cast(const(ubyte)[]) read(diskPath));
    }

    return buildAssetPak(inputs, key, tocSeed);
}

/// Mount an in-memory `GEPK` asset pack (for example via `import("assets.pak")`).
bool mountAssetPak(const(ubyte)[] pakBytes, ulong key, bool allowDiskFallback = false) @safe {
    PakEntry[] entries;
    if (!parseAssetPakToc(pakBytes, key, entries)) {
        return false;
    }
    () @trusted {
        g_mountedPak.mounted = true;
        g_mountedPak.allowDiskFallback = allowDiskFallback;
        g_mountedPak.key = key;
        g_mountedPak.rawBytes = pakBytes;
        g_mountedPak.entries = entries;
    }();
    return true;
}

/// Load a `GEPK` asset pack file from disk and mount it in memory.
bool mountAssetPakFile(string pakPath, ulong key, bool allowDiskFallback = false) @trusted {
    if (!exists(pakPath) || !isFile(pakPath)) return false;
    auto bytes = cast(const(ubyte)[]) read(pakPath);
    return mountAssetPak(bytes, key, allowDiskFallback);
}

/// Unmount the active asset pack and return to disk loading.
void unmountAssetPak() nothrow @nogc @trusted {
    g_mountedPak.mounted = false;
    g_mountedPak.allowDiskFallback = false;
    g_mountedPak.key = 0;
    g_mountedPak.rawBytes = null;
    g_mountedPak.entries = null;
}

/// Return true if an encrypted `GEPK` asset pack is currently mounted.
bool isAssetPakMounted() nothrow @nogc @trusted {
    return g_mountedPak.mounted;
}

/// Check whether `path` is available in the mounted pak (or on disk when unmounted / fallback allowed).
bool assetExists(scope const(char)[] path) @safe {
    if (path.length == 0) return false;
    bool mounted = false;
    bool fallback = false;
    bool foundInPak = false;
    immutable ulong targetHash = pakPathHash(path);
    () @trusted {
        mounted = g_mountedPak.mounted;
        fallback = g_mountedPak.allowDiskFallback;
        if (mounted) {
            foreach (ref e; g_mountedPak.entries) {
                if (e.pathHash == targetHash) {
                    foundInPak = true;
                    break;
                }
            }
        }
    }();

    if (mounted) {
        if (foundInPak) return true;
        if (!fallback) return false;
    }

    return () @trusted { return exists(path); }();
}

/// Read an asset into `outBytes` from the mounted pak (decrypting on demand)
/// or from disk when unmounted / `allowDiskFallback` is enabled.
bool readAssetBytes(scope const(char)[] path, out ubyte[] outBytes) @safe {
    outBytes = null;
    if (path.length == 0) return false;

    bool mounted = false;
    bool fallback = false;
    bool foundInPak = false;
    () @trusted {
        mounted = g_mountedPak.mounted;
        fallback = g_mountedPak.allowDiskFallback;
        if (mounted) {
            foundInPak = extractWithEntries(
                g_mountedPak.rawBytes,
                g_mountedPak.entries,
                g_mountedPak.key,
                path,
                outBytes
            );
        }
    }();

    if (foundInPak) return true;
    if (mounted && !fallback) return false;

    return () @trusted {
        if (!exists(path) || isDir(path)) return false;
        outBytes = cast(ubyte[]) read(path);
        return true;
    }();
}

@("pak: path normalization, encryption obfuscation, wrong-key rejection, and VFS isolation")
unittest {
    import std.algorithm : canFind;
    import std.file : mkdirRecurse, rmdirRecurse, write;

    scope (exit) unmountAssetPak();

    assert(normalizePakPath("./Assets\\Models//player_ship.glb") == "Assets/Models/player_ship.glb");
    assert(pakPathHash("./Assets\\Models//player_ship.glb") == pakPathHash("Assets/Models/player_ship.glb"));
    assert(pakPathHash("/Assets/Fonts/./DejaVuSansMono.ttf") == pakPathHash("Assets/Fonts/DejaVuSansMono.ttf"));

    const ubyte[] fakeGlb = cast(const(ubyte)[]) "glTF\x02\x00\x00\x00PLAYER_SHIP_GEOMETRY_BYTES_123456";
    const ubyte[] fakePng = cast(const(ubyte)[]) "\x89PNG\r\n\x1a\nIHDR_TUTORIAL_TEXTURE_DATA_987654";

    immutable ulong testKey = 0x1234_5678_9ABC_DEF0UL;
    auto pak = buildAssetPak([
        PakInput("Assets/Models/player_ship.glb", fakeGlb),
        PakInput("Assets/Tutorials/shield_tutorial.png", fakePng),
    ], testKey);

    // Neither plaintext file paths nor raw file magic headers may appear in the pak.
    assert(!pak.canFind(cast(const(ubyte)[]) "player_ship.glb"));
    assert(!pak.canFind(cast(const(ubyte)[]) "shield_tutorial.png"));
    assert(!pak.canFind(cast(const(ubyte)[]) "glTF"));
    assert(!pak.canFind(cast(const(ubyte)[]) "\x89PNG"));

    // Valid key extracts exact payloads across normalized path variants.
    ubyte[] outGlb;
    assert(readAssetFromPak(pak, testKey, "./Assets\\Models/player_ship.glb", outGlb));
    assert(outGlb == fakeGlb);

    ubyte[] outPng;
    assert(readAssetFromPak(pak, testKey, "Assets/Tutorials/shield_tutorial.png", outPng));
    assert(outPng == fakePng);

    // Wrong key is rejected by TOC validation.
    PakEntry[] badToc;
    assert(!parseAssetPakToc(pak, testKey ^ 1UL, badToc));
    assert(!readAssetFromPak(pak, testKey ^ 1UL, "Assets/Models/player_ship.glb", outGlb));
    assert(!mountAssetPak(pak, testKey ^ 1UL, false));

    // Disk isolation when mounted with allowDiskFallback = false.
    immutable string tmpDir = "build/test_pak_tmp";
    if (exists(tmpDir)) rmdirRecurse(tmpDir);
    mkdirRecurse(tmpDir);
    scope (exit) {
        if (exists(tmpDir)) rmdirRecurse(tmpDir);
    }
    immutable string diskOnlyFile = tmpDir ~ "/loose_asset.txt";
    write(diskOnlyFile, "loose disk data");

    assert(mountAssetPak(pak, testKey, false));
    assert(isAssetPakMounted());
    assert(assetExists("Assets/Models/player_ship.glb"));
    assert(!assetExists(diskOnlyFile));

    ubyte[] vfsBytes;
    assert(readAssetBytes("Assets/Tutorials/shield_tutorial.png", vfsBytes));
    assert(vfsBytes == fakePng);
    assert(!readAssetBytes(diskOnlyFile, vfsBytes));

    // Directory packing round-trip.
    write(tmpDir ~ "/sub.bin", cast(const(ubyte)[]) "BINARY_PAYLOAD_XYZ");
    auto dirPak = packDirectoryToPak(tmpDir, testKey, "GameAssets");
    assert(pakContains(dirPak, testKey, "GameAssets/loose_asset.txt"));
    assert(pakContains(dirPak, testKey, "GameAssets/sub.bin"));
    ubyte[] subBytes;
    assert(readAssetFromPak(dirPak, testKey, "GameAssets/sub.bin", subBytes));
    assert(subBytes == cast(const(ubyte)[]) "BINARY_PAYLOAD_XYZ");

    unmountAssetPak();
    assert(!isAssetPakMounted());
    assert(assetExists(diskOnlyFile));
    assert(readAssetBytes(diskOnlyFile, vfsBytes));
    assert(vfsBytes == cast(const(ubyte)[]) "loose disk data");
}
