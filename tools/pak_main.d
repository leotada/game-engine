/// Standalone CLI packer for `GEPK` v1 encrypted/obfuscated asset containers.
/// Usage: game-engine-pak --input=Assets --output=build/assets.pak [--prefix=Assets] [--key=0x...] [--verify]
module tools.pak_main;

import core.stdc.stdlib : exit;
import std.algorithm : canFind, sort;
import std.conv : to;
import std.file : dirEntries, exists, isDir, mkdirRecurse, read, SpanMode, write;
import std.path : absolutePath, baseName, buildPath, dirName, relativePath;
import std.stdio : stderr, writefln, writeln;
import engine.assets.pak :
    DEFAULT_ASSET_PAK_KEY,
    normalizePakPath,
    packDirectoryToPak,
    PakEntry,
    parseAssetPakToc,
    readAssetFromPak;

@safe:

private void writeErr(A...)(string fmt, A args) @trusted {
    stderr.writefln(fmt, args);
}

private void printUsage() {
    writeln("Game Engine Asset Packer (GEPK v1)");
    writeln("Usage: game-engine-pak --input=<dir> --output=<file> [options]");
    writeln("Options:");
    writeln("  --input=<dir>     Source asset directory to pack");
    writeln("  --output=<file>   Destination .pak file path");
    writeln("  --prefix=<str>    Virtual path prefix (default: basename of --input)");
    writeln("  --key=<hex>       64-bit encryption key (e.g. 0x454F544F56455354)");
    writeln("  --seed=<hex>      32-bit TOC salt (default: 0x4745504B)");
    writeln("  --verify          Verify round-trip decryption and magic-header obfuscation");
    writeln("  --help            Show this help");
}

private bool parseHexU64(scope const(char)[] s, out ulong val) pure nothrow @nogc {
    auto hex = s;
    if (hex.length >= 2 && hex[0] == '0' && (hex[1] == 'x' || hex[1] == 'X')) {
        hex = hex[2 .. $];
    }
    if (hex.length == 0 || hex.length > 16) return false;
    ulong acc = 0;
    foreach (char c; hex) {
        acc <<= 4;
        if (c >= '0' && c <= '9') acc |= cast(ulong)(c - '0');
        else if (c >= 'a' && c <= 'f') acc |= cast(ulong)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') acc |= cast(ulong)(c - 'A' + 10);
        else return false;
    }
    val = acc;
    return true;
}

private bool verifyPackedDirectory(
    string inputDir,
    string pathPrefix,
    ulong key,
    scope const(ubyte)[] pakBytes
) @trusted {
    PakEntry[] toc;
    if (!parseAssetPakToc(pakBytes, key, toc)) {
        writeErr("Verify failed: invalid TOC or key mismatch");
        return false;
    }

    if (pakBytes.canFind(cast(const(ubyte)[]) "glTF\x02\x00\x00\x00")) {
        writeErr("Verify failed: plaintext GLB magic header found in pak");
        return false;
    }
    if (pakBytes.canFind(cast(const(ubyte)[]) "\x89PNG\r\n\x1a\n")) {
        writeErr("Verify failed: plaintext PNG magic header found in pak");
        return false;
    }

    immutable string absInputDir = absolutePath(inputDir);
    string[] relPaths;
    foreach (entry; dirEntries(absInputDir, SpanMode.depth)) {
        if (!entry.isFile) continue;
        relPaths ~= normalizePakPath(relativePath(entry.name, absInputDir));
    }
    relPaths.sort();

    if (toc.length != relPaths.length) {
        writeErr("Verify failed: TOC entry count %d != disk file count %d",
            cast(int) toc.length, cast(int) relPaths.length);
        return false;
    }

    immutable string normPrefix = normalizePakPath(pathPrefix);
    foreach (rel; relPaths) {
        immutable string leaf = baseName(rel);
        if (leaf.length >= 5 && pakBytes.canFind(cast(const(ubyte)[]) leaf)) {
            writeErr("Verify failed: plaintext filename '%s' leaked into pak", leaf);
            return false;
        }
        immutable string keyPath = normPrefix.length > 0 ? (normPrefix ~ "/" ~ rel) : rel;
        ubyte[] decrypted;
        if (!readAssetFromPak(pakBytes, key, keyPath, decrypted)) {
            writeErr("Verify failed: missing key entry '%s'", keyPath);
            return false;
        }
        auto original = cast(const(ubyte)[]) read(buildPath(absInputDir, rel));
        if (decrypted != original) {
            writeErr("Verify failed: decrypted payload mismatch for '%s'", keyPath);
            return false;
        }
    }
    return true;
}

void main(string[] args) {
    string inputDir;
    string outputFile;
    string prefix;
    bool prefixSet = false;
    ulong key = DEFAULT_ASSET_PAK_KEY;
    uint seed = 0x4745_504BU;
    bool verify = false;

    foreach (arg; args[1 .. $]) {
        if (arg == "--help" || arg == "-h") {
            printUsage();
            return;
        } else if (arg == "--verify") {
            verify = true;
        } else if (arg.length > 8 && arg[0 .. 8] == "--input=") {
            inputDir = arg[8 .. $];
        } else if (arg.length > 9 && arg[0 .. 9] == "--output=") {
            outputFile = arg[9 .. $];
        } else if (arg.length > 9 && arg[0 .. 9] == "--prefix=") {
            prefix = arg[9 .. $];
            prefixSet = true;
        } else if (arg.length > 6 && arg[0 .. 6] == "--key=") {
            if (!parseHexU64(arg[6 .. $], key)) {
                writeErr("Error: invalid hex key '%s'", arg[6 .. $]);
                () @trusted { exit(2); }();
            }
        } else if (arg.length > 7 && arg[0 .. 7] == "--seed=") {
            ulong s64;
            if (!parseHexU64(arg[7 .. $], s64)) {
                writeErr("Error: invalid hex seed '%s'", arg[7 .. $]);
                () @trusted { exit(2); }();
            }
            seed = cast(uint) s64;
        } else {
            writeErr("Error: unrecognized argument '%s'", arg);
            printUsage();
            () @trusted { exit(2); }();
        }
    }

    if (inputDir.length == 0 || outputFile.length == 0) {
        writeErr("Error: --input=<dir> and --output=<file> are required");
        printUsage();
        () @trusted { exit(2); }();
    }
    if (!exists(inputDir) || !isDir(inputDir)) {
        writeErr("Error: input directory does not exist: %s", inputDir);
        () @trusted { exit(1); }();
    }

    if (!prefixSet) {
        prefix = baseName(inputDir);
    }

    auto pakBytes = packDirectoryToPak(inputDir, key, prefix, seed);

    if (verify) {
        if (!verifyPackedDirectory(inputDir, prefix, key, pakBytes)) {
            () @trusted { exit(1); }();
        }
    }

    auto parent = dirName(outputFile);
    if (parent.length > 0 && parent != "." && !exists(parent)) {
        mkdirRecurse(parent);
    }
    write(outputFile, pakBytes);

    PakEntry[] entries;
    parseAssetPakToc(pakBytes, key, entries);
    writefln("Packed %d assets from '%s' -> '%s' (%d bytes, prefix='%s'%s)",
        cast(int) entries.length, inputDir, outputFile, cast(int) pakBytes.length,
        prefix, verify ? ", verified" : "");
}
