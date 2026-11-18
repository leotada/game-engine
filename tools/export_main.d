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

private void printUsage() {
    writeln("Game Engine Release Exporter");
    writeln("Usage: dub run --config=export -- [options]");
    writeln("Options:");
    writeln("  --target=<id>        linux-x86_64 | linux-arm64 | windows-x86_64 |");
    writeln("                       macos-arm64 | macos-x86_64 | macos-universal | web-wasm32");
    writeln("  --output=<dir>       Output bundle directory (default: build/<target>)");
    writeln("  --scene=<path>       Startup .scene.json path");
    writeln("  --name=<bin>         Executable/bundle base name (default: game-player)");
    writeln("  --title=<title>      Display title for desktop/macOS/Web shells");
    writeln("  --compiler=<bin>     D compiler (default: ldc2)");
    writeln("  --release            Compile with release optimizations");
    writeln("  --archive            Package bundle into .tar.gz or .zip");
    writeln("  --symgc              Enable steadygc card-marking barrier builds");
    writeln("  --list-targets       Print supported export targets and LLVM triples");
    writeln("  --check-toolchains   Check host compiler, linkers, and static archives");
    writeln("  --help               Show this help");
}

void main(string[] args) {
    BuildExportOptions opts;
    opts.compiler = "ldc2";
    bool listTargets = false;
    bool checkToolchains = false;
    bool customOutput = false;

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
        } else if (arg == "--symgc") {
            opts.enableSymGc = true;
            opts.useCardBarrier = true;
        } else if (arg.length > 9 && arg[0 .. 9] == "--target=") {
            immutable val = arg[9 .. $];
            if (!parseExportTarget(val, opts.target)) {
                stderr.writefln("Error: unknown export target '%s'", val);
                () @trusted { exit(2); }();
            }
            opts.targetPlatform = exportTargetId(opts.target);
        } else if (arg.length > 9 && arg[0 .. 9] == "--output=") {
            opts.outputDir = arg[9 .. $];
            customOutput = true;
        } else if (arg.length > 8 && arg[0 .. 8] == "--scene=") {
            opts.startScene = arg[8 .. $];
        } else if (arg.length > 7 && arg[0 .. 7] == "--name=") {
            opts.binaryName = arg[7 .. $];
        } else if (arg.length > 8 && arg[0 .. 8] == "--title=") {
            opts.appTitle = arg[8 .. $];
        } else if (arg.length > 11 && arg[0 .. 11] == "--compiler=") {
            opts.compiler = arg[11 .. $];
        } else {
            stderr.writefln("Error: unrecognized argument '%s'", arg);
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
        stderr.writefln("Export failed:\n%s", outLog);
        () @trusted { exit(1); }();
    }

    writefln("Export succeeded: %s (%s)", opts.outputDir, exportTargetId(opts.target));
}
