/// Standalone CLI game exporter for Linux, Windows, macOS, and Web (WASM + WebGPU).
/// Usage: dub run --config=export -- --target=linux-x86_64 --release --archive
module tools.export_main;

import core.stdc.stdlib : exit;
import std.conv : to;
import std.stdio : stderr, writefln, writeln;
import editor.build_export :
    BuildExportOptions, ExportPipeline, ExportTarget,
    exportTargetId, exportTargetTriple, parseExportTarget;

@safe:

private immutable ExportTarget[7] ALL_TARGETS = [
    ExportTarget.linuxX86_64,
    ExportTarget.linuxArm64,
    ExportTarget.windowsX86_64,
    ExportTarget.macosArm64,
    ExportTarget.macosX86_64,
    ExportTarget.macosUniversal,
    ExportTarget.webWasm32,
];

private void writeErr(A...)(string fmt, A args) @trusted {
    stderr.writefln(fmt, args);
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

private void printUsage() {
    writeln("Game Engine Release Exporter");
    writeln("Usage: dub run --config=export -- [options]");
    writeln("Options:");
    writeln("  --target=<id>        linux-x86_64 | linux-arm64 | windows-x86_64 |");
    writeln("                       macos-arm64 | macos-x86_64 | macos-universal | web-wasm32");
    writeln("  --output=<dir>       Output bundle directory (default: build/<target>)");
    writeln("  --project=<dir>      External game project root (builds static game + engine)");
    writeln("  --engine=<dir>       Game engine root directory (auto-detected if omitted)");
    writeln("  --source=<dir>       Game source directory relative to --project (default: source)");
    writeln("  --assets=<dir>       Assets directory relative to --project (default: assets)");
    writeln("  --protect-assets     Pack assets into encrypted GEPK v1 container");
    writeln("  --embed-pak          Embed encrypted assets.pak inside executable (sets ProtectedAssets)");
    writeln("  --pak-dir=<dir>      Extra project directory (e.g. streamed chunks) packed into the pak; repeatable");
    writeln("  --pak-key=<hex>      64-bit hex encryption key for GEPK asset container");
    writeln("  --version=<id>       Extra D version identifier (repeatable)");
    writeln("  --no-verify          Skip post-build static ELF DT_NEEDED / ldd verification");
    writeln("  --scene=<path>       Startup .scene.json path");
    writeln("  --name=<bin>         Executable/bundle base name (default: game-player)");
    writeln("  --title=<title>      Display title for desktop/macOS/Web shells");
    writeln("  --compiler=<bin>     D compiler (default: auto-detect static-capable compiler)");
    writeln("  --release            Compile with release optimizations");
    writeln("  --archive            Package bundle into .tar.gz or .zip");
    writeln("  --symgc              Enable steadygc card-marking barrier builds");
    writeln("  --list-targets       Print supported export targets and LLVM triples");
    writeln("  --check-toolchains   Check host compiler, linkers, and static archives");
    writeln("  --help               Show this help");
}

void main(string[] args) {
    BuildExportOptions opts;
    opts.compiler = "";
    bool listTargets = false;
    bool checkToolchains = false;
    bool customOutput = false;
    bool customScene = false;

    foreach (arg; args[1 .. $]) {
        if (arg == "--help" || arg == "-h") {
            printUsage();
            return;
        } else if (arg == "--list-targets") {
            listTargets = true;
        } else if (arg == "--check-toolchains") {
            checkToolchains = true;
        } else if (arg == "--release") {
            opts.release = true;
        } else if (arg == "--archive") {
            opts.packageArchive = true;
        } else if (arg == "--protect-assets") {
            opts.protectAssets = true;
        } else if (arg == "--embed-pak") {
            opts.protectAssets = true;
            opts.embedAssetsPak = true;
        } else if (arg == "--no-verify") {
            opts.verifyStatic = false;
        } else if (arg == "--symgc") {
            opts.enableSymGc = true;
            opts.useCardBarrier = true;
        } else if (arg.length > 9 && arg[0 .. 9] == "--target=") {
            immutable val = arg[9 .. $];
            if (!parseExportTarget(val, opts.target)) {
                writeErr("Error: unknown export target '%s'", val);
                () @trusted { exit(2); }();
            }
            opts.targetPlatform = exportTargetId(opts.target);
        } else if (arg.length > 9 && arg[0 .. 9] == "--output=") {
            opts.outputDir = arg[9 .. $];
            customOutput = true;
        } else if (arg.length > 10 && arg[0 .. 10] == "--project=") {
            opts.projectDir = arg[10 .. $];
            if (!customScene) opts.startScene = "";
        } else if (arg.length > 9 && arg[0 .. 9] == "--engine=") {
            opts.engineDir = arg[9 .. $];
        } else if (arg.length > 9 && arg[0 .. 9] == "--source=") {
            opts.sourceDir = arg[9 .. $];
        } else if (arg.length > 9 && arg[0 .. 9] == "--assets=") {
            opts.assetsDir = arg[9 .. $];
        } else if (arg.length > 10 && arg[0 .. 10] == "--pak-dir=") {
            opts.protectAssets = true;
            opts.extraPakDirs ~= arg[10 .. $];
        } else if (arg.length > 10 && arg[0 .. 10] == "--pak-key=") {
            if (!parseHexU64(arg[10 .. $], opts.assetPakKey)) {
                writeErr("Error: invalid hex pak key '%s'", arg[10 .. $]);
                () @trusted { exit(2); }();
            }
        } else if (arg.length > 10 && arg[0 .. 10] == "--version=") {
            opts.extraVersions ~= arg[10 .. $];
        } else if (arg.length > 8 && arg[0 .. 8] == "--scene=") {
            opts.startScene = arg[8 .. $];
            customScene = true;
        } else if (arg.length > 7 && arg[0 .. 7] == "--name=") {
            opts.binaryName = arg[7 .. $];
        } else if (arg.length > 8 && arg[0 .. 8] == "--title=") {
            opts.appTitle = arg[8 .. $];
        } else if (arg.length > 11 && arg[0 .. 11] == "--compiler=") {
            opts.compiler = arg[11 .. $];
        } else {
            writeErr("Error: unrecognized argument '%s'", arg);
            printUsage();
            () @trusted { exit(2); }();
        }
    }

    if (listTargets) {
        writeln("Supported export targets:");
        foreach (tgt; ALL_TARGETS) {
            writefln("  %-16s (%s)", exportTargetId(tgt), exportTargetTriple(tgt));
        }
        return;
    }

    if (checkToolchains) {
        writeln("Host toolchain & static dependency preflight:");
        foreach (tgt; ALL_TARGETS) {
            const chk = ExportPipeline.checkToolchain(tgt, "libs", opts.enableSymGc);
            if (chk.available) {
                writefln("  [OK]      %-16s compiler=%s linker=%s",
                    exportTargetId(tgt), chk.compiler, chk.linker);
            } else {
                writefln("  [MISSING] %-16s %s",
                    exportTargetId(tgt), chk.missingReason);
            }
        }
        return;
    }

    if (!customOutput) {
        opts.outputDir = "build/" ~ exportTargetId(opts.target);
    }

    string outLog;
    if (!ExportPipeline.exportGame(opts, outLog)) {
        writeErr("Export failed:\n%s", outLog);
        () @trusted { exit(1); }();
    }

    writefln("Export succeeded: %s (%s)", opts.outputDir, exportTargetId(opts.target));
}
