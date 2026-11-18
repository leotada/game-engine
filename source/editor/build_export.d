/// Build and standalone multiplatform game export pipeline (ED-8).
/// Supports static self-contained release builds across Linux, Windows, macOS, and Web (WASM + WebGPU).
module editor.build_export;

import std.algorithm : any, canFind;
import std.array : join, replace;
import std.file : copy, dirEntries, exists, getAttributes, isDir, isFile, mkdirRecurse, readText, remove, setAttributes, SpanMode, write;
import std.format : format;
import std.path : baseName, buildPath, dirName;
import std.process : environment, executeShell;
import std.string : split, strip, toLower;
import engine.core.log : err, info, warn;

@safe:

enum ExportTarget : ubyte {
    linuxX86_64 = 0,
    linuxArm64 = 1,
    windowsX86_64 = 2,
    macosArm64 = 3,
    macosX86_64 = 4,
    macosUniversal = 5,
    webWasm32 = 6,
}

struct ToolchainCheck {
    bool available = false;
    string compiler;
    string linker;
    string missingReason;
    string[] missingLibs;
}

struct BuildExportOptions {
    string targetPlatform = "linux-x86_64";
    string outputDir = "build/linux-x86_64";
    string startScene = "assets/scenes/arena_01.scene.json";
    string[] includedScenes;
    bool release = false;
    string compiler = "ldc2";
    bool useCardBarrier = false;

    ExportTarget target = ExportTarget.linuxX86_64;
    string binaryName = "game-player";
    string appTitle = "Game Engine Player";
    string appId = "com.gameengine.player";
    string appVersion = "1.0.0";
    string iconPath = "";
    bool packageArchive = false;
    bool useStaticDeps = true;
    bool enableSymGc = false;
}

private struct TargetSpec {
    ExportTarget target;
    string id;
    string ldcTriple;
    string libsSubdir;
    string exeExt;
}

private immutable TargetSpec[7] TARGET_SPECS = [
    TargetSpec(ExportTarget.linuxX86_64,    "linux-x86_64",    "x86_64-unknown-linux-gnu",    "linux-x86_64",    ""),
    TargetSpec(ExportTarget.linuxArm64,     "linux-arm64",     "aarch64-unknown-linux-gnu",   "linux-arm64",     ""),
    TargetSpec(ExportTarget.windowsX86_64,  "windows-x86_64",  "x86_64-pc-windows-msvc",      "windows-x86_64",  ".exe"),
    TargetSpec(ExportTarget.macosArm64,     "macos-arm64",     "arm64-apple-macos12.0",       "macos-arm64",     ""),
    TargetSpec(ExportTarget.macosX86_64,    "macos-x86_64",    "x86_64-apple-macos11.0",      "macos-x86_64",    ""),
    TargetSpec(ExportTarget.macosUniversal, "macos-universal", "arm64-apple-macos12.0",       "macos-arm64",     ""),
    TargetSpec(ExportTarget.webWasm32,      "web-wasm32",      "wasm32-unknown-emscripten",   "web-wasm32",      ".html"),
];

private ref immutable(TargetSpec) specFor(ExportTarget target) nothrow @nogc pure {
    return TARGET_SPECS[cast(size_t) target];
}

/// Parse CLI/display target identifiers into `ExportTarget`.
bool parseExportTarget(scope const(char)[] id, out ExportTarget outTarget) nothrow @nogc pure {
    switch (id) {
        case "linux":
        case "linux-x86_64":
        case "linux_x86_64":
            outTarget = ExportTarget.linuxX86_64;
            return true;
        case "linux-arm64":
        case "linux-aarch64":
            outTarget = ExportTarget.linuxArm64;
            return true;
        case "windows":
        case "win64":
        case "windows-x86_64":
            outTarget = ExportTarget.windowsX86_64;
            return true;
        case "macos-arm64":
        case "darwin-arm64":
            outTarget = ExportTarget.macosArm64;
            return true;
        case "macos-x86_64":
        case "darwin-x86_64":
            outTarget = ExportTarget.macosX86_64;
            return true;
        case "macos":
        case "darwin":
        case "macos-universal":
            outTarget = ExportTarget.macosUniversal;
            return true;
        case "web":
        case "wasm":
        case "web-wasm32":
        case "wasm32":
            outTarget = ExportTarget.webWasm32;
            return true;
        default:
            return false;
    }
}

string exportTargetId(ExportTarget target) nothrow @nogc pure {
    return specFor(target).id;
}

string exportTargetTriple(ExportTarget target) nothrow @nogc pure {
    return specFor(target).ldcTriple;
}

string[] requiredStaticLibs(ExportTarget target, bool includeSymGc = false) pure {
    final switch (target) {
        case ExportTarget.linuxX86_64:
        case ExportTarget.linuxArm64:
        case ExportTarget.macosArm64:
        case ExportTarget.macosX86_64:
        case ExportTarget.macosUniversal:
            auto libs = [
                "libSDL3_ttf.a",
                "libSDL3_image.a",
                "libfreetype.a",
                "libSDL3.a",
                "libwgpu_native.a",
                "libbox3d.a",
            ];
            if (includeSymGc) {
                libs ~= "libsymgc-cards.a";
            }
            return libs;
        case ExportTarget.windowsX86_64:
            auto libs = [
                "SDL3_ttf-static.lib",
                "SDL3_image-static.lib",
                "freetype.lib",
                "SDL3-static.lib",
                "wgpu_native.lib",
                "box3d.lib",
            ];
            if (includeSymGc) {
                libs ~= "symgc-cards.lib";
            }
            return libs;
        case ExportTarget.webWasm32:
            return [
                "libSDL3_ttf.a",
                "libSDL3_image.a",
                "libfreetype.a",
                "libSDL3.a",
                "libbox3d.a",
            ];
    }
}

private ExportTarget effectiveTarget(const ref BuildExportOptions opts) nothrow @nogc pure {
    if (opts.target != ExportTarget.linuxX86_64) {
        return opts.target;
    }
    ExportTarget parsed;
    if (opts.targetPlatform.length > 0 && parseExportTarget(opts.targetPlatform, parsed)) {
        return parsed;
    }
    return opts.target;
}

private string findExecutableOnPath(scope const(char)[] tool) @trusted {
    if (tool.length == 0) return null;
    if (tool.canFind('/') && exists(tool) && isFile(tool)) {
        return tool.idup;
    }
    string pathEnv;
    try {
        pathEnv = environment.get("PATH", "");
    } catch (Exception) {
        return null;
    }
    version (Windows) {
        enum sep = ';';
    } else {
        enum sep = ':';
    }
    foreach (dir; pathEnv.split(sep)) {
        if (dir.length == 0) continue;
        string candidate = buildPath(dir, tool);
        try {
            if (exists(candidate) && isFile(candidate)) {
                return candidate;
            }
        } catch (Exception) {}
    }
    return null;
}

private string firstExecutable(scope const(string)[] candidates) @safe {
    foreach (cand; candidates) {
        auto found = findExecutableOnPath(cand);
        if (found.length > 0) return found;
    }
    return null;
}

private string[] missingLibsForSubdir(string libsRoot, string subdir,
                                      scope const(string)[] libs) @safe {
    string[] missing;
    foreach (lib; libs) {
        immutable p = buildPath(libsRoot, subdir, lib);
        if (!exists(p)) {
            missing ~= p;
        }
    }
    return missing;
}

private string escapeXml(scope const(char)[] s) pure {
    string outStr;
    foreach (char c; s) {
        if (c == '&') outStr ~= "&amp;";
        else if (c == '<') outStr ~= "&lt;";
        else if (c == '>') outStr ~= "&gt;";
        else if (c == '"') outStr ~= "&quot;";
        else outStr ~= c;
    }
    return outStr;
}

private string sanitizeDesktopFileId(scope const(char)[] name) pure {
    string outStr;
    foreach (char c; name) {
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '-' || c == '_') {
            outStr ~= c;
        } else if (c == ' ') {
            outStr ~= '-';
        }
    }
    return outStr.length > 0 ? outStr : "game-player";
}

struct ExportPipeline {
    /// Inspect host tools (`ldc2`/`dmd`/`emcc`, target linker) and staged static libraries.
    static ToolchainCheck checkToolchain(ExportTarget target, string libsRoot = "libs",
                                         bool enableSymGc = false) @trusted {
        ToolchainCheck chk;
        immutable reqLibs = requiredStaticLibs(target, enableSymGc);

        final switch (target) {
            case ExportTarget.linuxX86_64:
                chk.compiler = firstExecutable(["ldc2", "dmd"]);
                chk.linker = firstExecutable(["clang", "gcc", "cc"]);
                chk.missingLibs = missingLibsForSubdir(libsRoot, "linux-x86_64", reqLibs);
                break;
            case ExportTarget.linuxArm64:
                chk.compiler = firstExecutable(["ldc2"]);
                chk.linker = firstExecutable(["aarch64-linux-gnu-gcc", "zig", "clang"]);
                chk.missingLibs = missingLibsForSubdir(libsRoot, "linux-arm64", reqLibs);
                break;
            case ExportTarget.windowsX86_64:
                chk.compiler = firstExecutable(["ldc2"]);
                chk.linker = firstExecutable(["lld-link", "x86_64-w64-mingw32-gcc", "zig"]);
                chk.missingLibs = missingLibsForSubdir(libsRoot, "windows-x86_64", reqLibs);
                break;
            case ExportTarget.macosArm64:
                chk.compiler = firstExecutable(["ldc2"]);
                version (OSX) {
                    chk.linker = firstExecutable(["clang", "ld64.lld", "zig"]);
                } else {
                    chk.linker = firstExecutable(["ld64.lld", "zig", "oa64-clang"]);
                }
                chk.missingLibs = missingLibsForSubdir(libsRoot, "macos-arm64", reqLibs);
                break;
            case ExportTarget.macosX86_64:
                chk.compiler = firstExecutable(["ldc2"]);
                version (OSX) {
                    chk.linker = firstExecutable(["clang", "ld64.lld", "zig"]);
                } else {
                    chk.linker = firstExecutable(["ld64.lld", "zig", "o64-clang"]);
                }
                chk.missingLibs = missingLibsForSubdir(libsRoot, "macos-x86_64", reqLibs);
                break;
            case ExportTarget.macosUniversal:
                chk.compiler = firstExecutable(["ldc2"]);
                version (OSX) {
                    chk.linker = firstExecutable(["lipo"]);
                } else {
                    chk.linker = firstExecutable(["llvm-lipo", "lipo"]);
                }
                chk.missingLibs ~= missingLibsForSubdir(libsRoot, "macos-arm64", reqLibs);
                chk.missingLibs ~= missingLibsForSubdir(libsRoot, "macos-x86_64", reqLibs);
                break;
            case ExportTarget.webWasm32:
                chk.compiler = firstExecutable(["ldc2"]);
                chk.linker = firstExecutable(["emcc"]);
                chk.missingLibs = missingLibsForSubdir(libsRoot, "web-wasm32", reqLibs);
                break;
        }

        string[] reasons;
        if (chk.compiler.length == 0) {
            reasons ~= "missing D compiler (ldc2 required for cross/static export)";
        }
        if (chk.linker.length == 0) {
            reasons ~= format("missing target linker/SDK for %s", exportTargetId(target));
        }
        if (chk.missingLibs.length > 0) {
            reasons ~= format("missing static archives in %s/%s (run ./tools/build_sdl3_deps.sh %s)",
                libsRoot, specFor(target).libsSubdir, specFor(target).id);
        }

        chk.available = reasons.length == 0;
        chk.missingReason = reasons.join("; ");
        return chk;
    }

    /// Generate the ordered static archive and system library linker arguments per target.
    static string[] buildStaticLinkArgs(ExportTarget target, string libsDir,
                                        bool enableSymGc = false) pure {
        string[] args;
        immutable reqLibs = requiredStaticLibs(target, enableSymGc);
        foreach (lib; reqLibs) {
            args ~= buildPath(libsDir, lib);
        }

        final switch (target) {
            case ExportTarget.linuxX86_64:
            case ExportTarget.linuxArm64:
                args ~= ["-lm", "-ldl", "-lpthread", "-lrt"];
                break;
            case ExportTarget.windowsX86_64:
                args ~= [
                    "user32.lib", "gdi32.lib", "winmm.lib", "imm32.lib",
                    "ole32.lib", "oleaut32.lib", "version.lib", "uuid.lib",
                    "advapi32.lib", "setupapi.lib", "shell32.lib",
                    "d3d12.lib", "dxgi.lib", "dxguid.lib",
                    "/SUBSYSTEM:WINDOWS",
                ];
                break;
            case ExportTarget.macosArm64:
            case ExportTarget.macosX86_64:
            case ExportTarget.macosUniversal:
                args ~= [
                    "-framework", "Metal",
                    "-framework", "QuartzCore",
                    "-framework", "Cocoa",
                    "-framework", "IOKit",
                    "-framework", "CoreVideo",
                    "-framework", "CoreAudio",
                    "-framework", "AudioToolbox",
                    "-framework", "GameController",
                    "-framework", "ForceFeedback",
                    "-framework", "Carbon",
                    "-framework", "UniformTypeIdentifiers",
                    "-liconv", "-lc++", "-ObjC",
                ];
                break;
            case ExportTarget.webWasm32:
                args ~= [
                    "-sUSE_WEBGPU=1",
                    "-sASYNCIFY=1",
                    "-sALLOW_MEMORY_GROWTH=1",
                    "-sINITIAL_MEMORY=67108864",
                    "--preload-file", "assets@/assets",
                ];
                break;
        }

        return args;
    }

    /// Construct the compiler / dub command line for native targets.
    static string buildCompileCommand(const ref BuildExportOptions opts) pure {
        immutable tgt = effectiveTarget(opts);
        immutable bool symGc = opts.enableSymGc || opts.useCardBarrier;
        immutable string compilerBin = opts.compiler.length > 0 ? opts.compiler : "ldc2";
        immutable bool isLdc = (compilerBin == "ldc2" || compilerBin == "ldc");

        if (tgt == ExportTarget.linuxX86_64) {
            string configName = opts.useStaticDeps ? "player-static" : "player";
            string extraFlags = "";
            if (symGc) {
                configName = opts.useStaticDeps ? "player-static" : "player-symgc";
                if (isLdc) {
                    extraFlags = ` --dflags="-gc-card-marking -d-version=Symgc_cards -d-version=Symgc_druntime_hooks"`;
                } else {
                    extraFlags = ` --dflags="-preview=gcbarrier -version=Symgc_cards -version=Symgc_druntime_hooks"`;
                }
            }
            return format("dub build --config=%s --compiler=%s%s%s",
                configName,
                compilerBin,
                opts.release ? " --build=release" : "",
                extraFlags);
        }

        if (tgt == ExportTarget.webWasm32) {
            return buildWebExportCommands(opts)[1];
        }

        immutable spec = specFor(tgt);
        immutable libsDir = buildPath("libs", spec.libsSubdir);
        immutable outBin = buildPath(opts.outputDir,
            (opts.binaryName.length > 0 ? opts.binaryName : "game-player") ~ spec.exeExt);

        string[] cmd = [
            "ldc2",
            format("-mtriple=%s", spec.ldcTriple),
            opts.release ? "-O3" : "-O0",
            "-release",
            "-preview=dip1000",
            "-I=source",
            "-I=source/bindings/box3d",
            "-J=assets/shaders",
            "-d-version=StaticSDLDeps",
        ];
        if (symGc) {
            cmd ~= ["-d-version=Symgc_cards", "-d-version=Symgc_druntime_hooks", "-gc-card-marking"];
        }
        cmd ~= "tools/player/player_main.d";
        foreach (arg; buildStaticLinkArgs(tgt, libsDir, symGc)) {
            cmd ~= format("-L=%s", arg);
        }
        cmd ~= format("-of=%s", outBin);
        return cmd.join(" ");
    }

    /// Construct the two-stage `(ldc2 -> .o, emcc -> .html/.js/.wasm/.data)` WebAssembly commands.
    static string[2] buildWebExportCommands(const ref BuildExportOptions opts) pure {
        immutable binStem = opts.binaryName.length > 0 ? opts.binaryName : "game-player";
        immutable libsDir = buildPath("libs", "web-wasm32");
        immutable objDir = buildPath(opts.outputDir, "obj");
        immutable htmlOut = buildPath(opts.outputDir, binStem ~ ".html");
        immutable shellOut = buildPath(opts.outputDir, "shell.generated.html");

        string ldcCmd = format(
            "ldc2 -c -mtriple=wasm32-unknown-emscripten %s -preview=dip1000 "
            ~ "-I=source -I=source/bindings/box3d -J=assets/shaders "
            ~ "-d-version=WebAssembly -d-version=StaticSDLDeps -od=%s "
            ~ "tools/player/player_main.d",
            opts.release ? "-O3 -release" : "-O1",
            objDir);

        string[] emccArgs = [
            "emcc",
            buildPath(objDir, "player_main.o"),
            libsDir ~ "/libSDL3_ttf.a",
            libsDir ~ "/libSDL3_image.a",
            libsDir ~ "/libfreetype.a",
            libsDir ~ "/libSDL3.a",
            libsDir ~ "/libbox3d.a",
            "-sUSE_WEBGPU=1",
            "-sASYNCIFY=1",
            "-sALLOW_MEMORY_GROWTH=1",
            "-sINITIAL_MEMORY=67108864",
            "--shell-file", shellOut,
            "--preload-file", "assets@/assets",
            "-o", htmlOut,
        ];
        return [ldcCmd, emccArgs.join(" ")];
    }

    static string renderWebShellHtml(scope const(char)[] shellTemplate, const ref BuildExportOptions opts) pure {
        immutable title = opts.appTitle.length > 0 ? opts.appTitle : "Game Engine Player";
        return shellTemplate.idup.replace("{{APP_TITLE}}", escapeXml(title));
    }

    static void writeThirdPartyLicenses(string destDir) @trusted {
        immutable dest = buildPath(destDir, "THIRD-PARTY-LICENSES.txt");
        if (exists("docs/third-party-licenses.md")) {
            write(dest, readText("docs/third-party-licenses.md"));
            return;
        }
        write(dest,
            "Game Engine Third-Party Licenses\n\n"
            ~ "- SDL3, SDL3_image, SDL3_ttf: zlib License (https://libsdl.org)\n"
            ~ "- FreeType 2: FreeType License (FTL) (https://freetype.org)\n"
            ~ "- meshoptimizer: MIT License\n");
    }

    static void writeLinuxRunScript(string destDir, const ref BuildExportOptions opts) @trusted {
        immutable binName = opts.binaryName.length > 0 ? opts.binaryName : "game-player";
        immutable libLine = opts.useStaticDeps
            ? "# Self-contained static dependencies (no LD_LIBRARY_PATH override required)\n"
            : "export LD_LIBRARY_PATH=\"$DIR/libs:${LD_LIBRARY_PATH:-}\"\n";
        immutable script =
            "#!/usr/bin/env bash\n"
            ~ "set -euo pipefail\n"
            ~ "DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n"
            ~ libLine
            ~ "export SDL_VIDEODRIVER=\"${SDL_VIDEODRIVER:-wayland,x11}\"\n"
            ~ "exec \"$DIR/" ~ binName ~ "\" --scene=\"" ~ opts.startScene ~ "\" \"$@\"\n";

        immutable launcherPath = buildPath(destDir, "run.sh");
        write(launcherPath, script);
        auto attrs = getAttributes(launcherPath);
        setAttributes(launcherPath, attrs | 0b001_001_001);
    }

    static void writeLinuxDesktopEntry(string destDir, const ref BuildExportOptions opts) @trusted {
        immutable binName = opts.binaryName.length > 0 ? opts.binaryName : "game-player";
        immutable title = opts.appTitle.length > 0 ? opts.appTitle : "Game Engine Player";
        immutable desktop =
            "[Desktop Entry]\n"
            ~ "Type=Application\n"
            ~ "Version=1.0\n"
            ~ "Name=" ~ title ~ "\n"
            ~ "Exec=" ~ binName ~ " --scene=" ~ opts.startScene ~ "\n"
            ~ "Terminal=false\n"
            ~ "Categories=Game;\n";
        write(buildPath(destDir, sanitizeDesktopFileId(binName) ~ ".desktop"), desktop);
    }

    static void writeMacOsInfoPlist(string plistPath, const ref BuildExportOptions opts) @trusted {
        immutable binName = opts.binaryName.length > 0 ? opts.binaryName : "game-player";
        immutable title = escapeXml(opts.appTitle.length > 0 ? opts.appTitle : "Game Engine Player");
        immutable bundleId = escapeXml(opts.appId.length > 0 ? opts.appId : "com.gameengine.player");
        immutable ver = escapeXml(opts.appVersion.length > 0 ? opts.appVersion : "1.0.0");

        immutable plist =
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            ~ "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            ~ "<plist version=\"1.0\">\n"
            ~ "<dict>\n"
            ~ "  <key>CFBundleName</key>\n"
            ~ "  <string>" ~ title ~ "</string>\n"
            ~ "  <key>CFBundleDisplayName</key>\n"
            ~ "  <string>" ~ title ~ "</string>\n"
            ~ "  <key>CFBundleIdentifier</key>\n"
            ~ "  <string>" ~ bundleId ~ "</string>\n"
            ~ "  <key>CFBundleVersion</key>\n"
            ~ "  <string>" ~ ver ~ "</string>\n"
            ~ "  <key>CFBundleShortVersionString</key>\n"
            ~ "  <string>" ~ ver ~ "</string>\n"
            ~ "  <key>CFBundlePackageType</key>\n"
            ~ "  <string>APPL</string>\n"
            ~ "  <key>CFBundleExecutable</key>\n"
            ~ "  <string>" ~ escapeXml(binName) ~ "</string>\n"
            ~ "  <key>NSHighResolutionCapable</key>\n"
            ~ "  <true/>\n"
            ~ "</dict>\n"
            ~ "</plist>\n";
        write(plistPath, plist);
    }

    static bool packageOutputArchive(ExportTarget target, string outputDir,
                                     out string outLog) @trusted {
        auto parent = dirName(outputDir);
        auto base = baseName(outputDir);
        immutable archivePath = (target == ExportTarget.linuxX86_64 || target == ExportTarget.linuxArm64)
            ? outputDir ~ ".tar.gz"
            : outputDir ~ ".zip";

        if (exists(archivePath)) {
            remove(archivePath);
        }

        string cmd;
        if (target == ExportTarget.linuxX86_64 || target == ExportTarget.linuxArm64) {
            cmd = format("tar -czf \"%s\" -C \"%s\" \"%s\"", archivePath, parent, base);
        } else {
            cmd = format("cd \"%s\" && zip -qr \"%s.zip\" \"%s\"", parent, base, base);
        }

        auto res = executeShell(cmd);
        outLog ~= res.output;
        return res.status == 0;
    }

    private static void copyBundleAssetsAndProject(string assetDestDir, string rootDestDir) @trusted {
        if (exists("assets")) {
            foreach (entry; dirEntries("assets", SpanMode.depth)) {
                if (!entry.isFile) continue;
                string dest = buildPath(assetDestDir, entry.name);
                auto destParent = dirName(dest);
                if (!exists(destParent)) mkdirRecurse(destParent);
                copy(entry.name, dest);
            }
        }
        if (exists("project.json")) {
            copy("project.json", buildPath(rootDestDir, "project.json"));
        }
        writeThirdPartyLicenses(rootDestDir);
    }

    static bool exportGame(const ref BuildExportOptions opts, out string outLog) @trusted {
        outLog = "";
        immutable tgt = effectiveTarget(opts);
        immutable bool symGc = opts.enableSymGc || opts.useCardBarrier;
        immutable binName = opts.binaryName.length > 0 ? opts.binaryName : "game-player";
        info("Export: starting %s export to %s...", exportTargetId(tgt), opts.outputDir);

        try {
            if (opts.useStaticDeps || tgt != ExportTarget.linuxX86_64) {
                const chk = checkToolchain(tgt, "libs", symGc);
                if (!chk.available) {
                    err("Export: preflight check failed: %s", chk.missingReason);
                    outLog ~= "Toolchain preflight failed: " ~ chk.missingReason ~ "\n";
                    return false;
                }
            }

            if (!exists(opts.outputDir)) mkdirRecurse(opts.outputDir);

            if (tgt == ExportTarget.webWasm32) {
                return exportWebWasm(opts, outLog);
            }

            if (tgt == ExportTarget.macosArm64 || tgt == ExportTarget.macosX86_64 ||
                tgt == ExportTarget.macosUniversal) {
                return exportMacOsBundle(opts, tgt, outLog);
            }

            // Linux or Windows bundle directory
            auto targetAssets = buildPath(opts.outputDir, "assets");
            if (!exists(targetAssets)) mkdirRecurse(targetAssets);
            copyBundleAssetsAndProject(opts.outputDir, opts.outputDir);

            if (!opts.useStaticDeps && exists("libs")) {
                auto targetLibs = buildPath(opts.outputDir, "libs");
                if (!exists(targetLibs)) mkdirRecurse(targetLibs);
                foreach (entry; dirEntries("libs", SpanMode.shallow)) {
                    if (entry.isFile && (entry.name.length >= 3 && entry.name[$ - 3 .. $] == ".so")) {
                        copy(entry.name, buildPath(targetLibs, baseName(entry.name)));
                    }
                }
            }

            immutable string cmd = buildCompileCommand(opts);
            info("Export: running %s", cmd);
            auto res = executeShell(cmd);
            outLog ~= res.output;
            if (res.status != 0) {
                err("Export: compilation failed (%d):\n%s", res.status, res.output);
                return false;
            }

            if (tgt == ExportTarget.linuxX86_64) {
                immutable produced = opts.useStaticDeps
                    ? "game-engine-player-static"
                    : (symGc ? "game-engine-player-symgc" : "game-engine-player");
                if (exists(produced)) {
                    immutable destBin = buildPath(opts.outputDir, binName);
                    copy(produced, destBin);
                    auto attrs = getAttributes(destBin);
                    setAttributes(destBin, attrs | 0b001_001_001);
                }
                writeLinuxRunScript(opts.outputDir, opts);
                writeLinuxDesktopEntry(opts.outputDir, opts);
            }

            if (opts.packageArchive) {
                if (!packageOutputArchive(tgt, opts.outputDir, outLog)) {
                    warn("Export: archive packaging failed (unarchived bundle remains valid)");
                }
            }

            info("Export: successfully packaged %s release in %s", exportTargetId(tgt), opts.outputDir);
            return true;
        } catch (Exception e) {
            err("Export: fatal error during export: %s", e.msg);
            outLog ~= "\nFatal error: " ~ e.msg;
            return false;
        }
    }

    private static BuildExportOptions cloneOpts(const ref BuildExportOptions src) pure {
        BuildExportOptions dst;
        dst.targetPlatform = src.targetPlatform;
        dst.outputDir      = src.outputDir;
        dst.startScene     = src.startScene;
        dst.includedScenes = src.includedScenes.dup;
        dst.release        = src.release;
        dst.compiler       = src.compiler;
        dst.useCardBarrier = src.useCardBarrier;
        dst.target         = src.target;
        dst.binaryName     = src.binaryName;
        dst.appTitle       = src.appTitle;
        dst.appId          = src.appId;
        dst.appVersion     = src.appVersion;
        dst.iconPath       = src.iconPath;
        dst.packageArchive = src.packageArchive;
        dst.useStaticDeps  = src.useStaticDeps;
        dst.enableSymGc    = src.enableSymGc;
        return dst;
    }

    private static bool exportMacOsBundle(const ref BuildExportOptions opts, ExportTarget tgt,
                                          ref string outLog) @trusted {
        immutable appName = sanitizeDesktopFileId(opts.appTitle.length > 0 ? opts.appTitle : "GamePlayer");
        immutable binName = opts.binaryName.length > 0 ? opts.binaryName : "game-player";
        immutable appDir = buildPath(opts.outputDir, appName ~ ".app");
        immutable contentsDir = buildPath(appDir, "Contents");
        immutable macOsDir = buildPath(contentsDir, "MacOS");
        immutable resDir = buildPath(contentsDir, "Resources");

        mkdirRecurse(macOsDir);
        mkdirRecurse(resDir);
        writeMacOsInfoPlist(buildPath(contentsDir, "Info.plist"), opts);
        copyBundleAssetsAndProject(resDir, resDir);

        immutable string outBin = buildPath(macOsDir, binName);
        if (tgt == ExportTarget.macosUniversal) {
            BuildExportOptions armOpts = cloneOpts(opts);
            armOpts.target = ExportTarget.macosArm64;
            armOpts.outputDir = macOsDir;
            armOpts.binaryName = binName ~ "-arm64";

            BuildExportOptions x64Opts = cloneOpts(opts);
            x64Opts.target = ExportTarget.macosX86_64;
            x64Opts.outputDir = macOsDir;
            x64Opts.binaryName = binName ~ "-x86_64";

            foreach (cmd; [buildCompileCommand(armOpts), buildCompileCommand(x64Opts)]) {
                auto r = executeShell(cmd);
                outLog ~= r.output;
                if (r.status != 0) return false;
            }
            immutable lipoCmd = format("lipo -create \"%s\" \"%s\" -output \"%s\"",
                buildPath(macOsDir, armOpts.binaryName),
                buildPath(macOsDir, x64Opts.binaryName),
                outBin);
            auto lres = executeShell(lipoCmd);
            outLog ~= lres.output;
            if (lres.status != 0) return false;
        } else {
            BuildExportOptions singleOpts = cloneOpts(opts);
            singleOpts.outputDir = macOsDir;
            auto r = executeShell(buildCompileCommand(singleOpts));
            outLog ~= r.output;
            if (r.status != 0) return false;
        }

        if (findExecutableOnPath("codesign").length > 0) {
            auto cs = executeShell(format("codesign --force --deep -s - \"%s\"", appDir));
            outLog ~= cs.output;
        }
        if (opts.packageArchive) {
            packageOutputArchive(tgt, opts.outputDir, outLog);
        }
        return true;
    }

    private static bool exportWebWasm(const ref BuildExportOptions opts, ref string outLog) @trusted {
        immutable objDir = buildPath(opts.outputDir, "obj");
        if (!exists(objDir)) mkdirRecurse(objDir);

        immutable shellSrc = exists("tools/web/shell.html")
            ? readText("tools/web/shell.html")
            : "<!doctype html><html><body><canvas id=\"canvas\"></canvas>{{{ SCRIPT }}}</body></html>";
        write(buildPath(opts.outputDir, "shell.generated.html"), renderWebShellHtml(shellSrc, opts));

        foreach (cmd; buildWebExportCommands(opts)) {
            info("Export Web: %s", cmd);
            auto res = executeShell(cmd);
            outLog ~= res.output;
            if (res.status != 0) {
                err("Export Web failed (%d):\n%s", res.status, res.output);
                return false;
            }
        }
        writeThirdPartyLicenses(opts.outputDir);
        if (opts.packageArchive) {
            packageOutputArchive(ExportTarget.webWasm32, opts.outputDir, outLog);
        }
        return true;
    }
}

unittest {
    ExportTarget parsed;
    assert(parseExportTarget("linux-x86_64", parsed) && parsed == ExportTarget.linuxX86_64);
    assert(parseExportTarget("linux-arm64", parsed) && parsed == ExportTarget.linuxArm64);
    assert(parseExportTarget("windows-x86_64", parsed) && parsed == ExportTarget.windowsX86_64);
    assert(parseExportTarget("macos-arm64", parsed) && parsed == ExportTarget.macosArm64);
    assert(parseExportTarget("macos-x86_64", parsed) && parsed == ExportTarget.macosX86_64);
    assert(parseExportTarget("macos-universal", parsed) && parsed == ExportTarget.macosUniversal);
    assert(parseExportTarget("web-wasm32", parsed) && parsed == ExportTarget.webWasm32);
    assert(!parseExportTarget("nonexistent-target", parsed));

    assert(exportTargetTriple(ExportTarget.windowsX86_64) == "x86_64-pc-windows-msvc");
    assert(exportTargetTriple(ExportTarget.webWasm32) == "wasm32-unknown-emscripten");

    // Static link arg generation per platform
    auto linuxArgs = ExportPipeline.buildStaticLinkArgs(ExportTarget.linuxX86_64, "libs/linux-x86_64");
    assert(linuxArgs.any!(a => a.canFind("libSDL3_ttf.a")));
    assert(linuxArgs.any!(a => a.canFind("libSDL3.a")));
    assert(linuxArgs.any!(a => a == "-ldl"));

    auto winArgs = ExportPipeline.buildStaticLinkArgs(ExportTarget.windowsX86_64, "libs/windows-x86_64");
    assert(winArgs.any!(a => a.canFind("SDL3-static.lib")));
    assert(winArgs.any!(a => a == "d3d12.lib"));
    assert(winArgs.any!(a => a == "/SUBSYSTEM:WINDOWS"));

    auto macArgs = ExportPipeline.buildStaticLinkArgs(ExportTarget.macosArm64, "libs/macos-arm64");
    assert(macArgs.any!(a => a == "Metal"));
    assert(macArgs.any!(a => a == "-ObjC"));

    auto webArgs = ExportPipeline.buildStaticLinkArgs(ExportTarget.webWasm32, "libs/web-wasm32");
    assert(webArgs.any!(a => a == "-sUSE_WEBGPU=1"));
    assert(webArgs.any!(a => a == "assets@/assets"));

    // Web command & shell rendering verification
    BuildExportOptions webOpts;
    webOpts.target = ExportTarget.webWasm32;
    webOpts.appTitle = "Crystal Collector Web";
    webOpts.binaryName = "crystal";
    webOpts.outputDir = "build/test_web";
    webOpts.release = true;
    auto webCmds = ExportPipeline.buildWebExportCommands(webOpts);
    assert(webCmds[0].canFind("wasm32-unknown-emscripten"));
    assert(webCmds[0].canFind("-d-version=WebAssembly"));
    assert(webCmds[1].canFind("-sUSE_WEBGPU=1"));
    assert(ExportPipeline.renderWebShellHtml("<title>{{APP_TITLE}}</title>", webOpts)
        == "<title>Crystal Collector Web</title>");

    // Info.plist generation check
    if (!exists("build/test_plist")) mkdirRecurse("build/test_plist");
    BuildExportOptions macOpts;
    macOpts.appTitle = "Demo App";
    macOpts.appId = "dev.example.demo";
    macOpts.binaryName = "demo-bin";
    macOpts.appVersion = "2.1.0";
    ExportPipeline.writeMacOsInfoPlist("build/test_plist/Info.plist", macOpts);
    immutable plistText = readText("build/test_plist/Info.plist");
    assert(plistText.canFind("<string>Demo App</string>"));
    assert(plistText.canFind("<string>dev.example.demo</string>"));
    assert(plistText.canFind("<string>demo-bin</string>"));

    import std.file : rmdirRecurse;
    if (exists("build/test_plist")) rmdirRecurse("build/test_plist");

    // Host Linux x86_64 preflight & static bundle export check
    const linuxChk = ExportPipeline.checkToolchain(ExportTarget.linuxX86_64);
    assert(linuxChk.available, "Host Linux toolchain preflight failed: " ~ linuxChk.missingReason);

    BuildExportOptions opts;
    opts.outputDir = "build/test_export";
    opts.startScene = "assets/scenes/arena_01.scene.json";
    opts.compiler = "ldc2";
    opts.release = true;
    opts.useStaticDeps = true;
    string outLog;
    assert(ExportPipeline.exportGame(opts, outLog), "ExportPipeline failed: " ~ outLog);
    assert(exists("build/test_export/game-player"));
    assert(exists("build/test_export/run.sh"));
    assert(exists("build/test_export/game-player.desktop"));
    assert(exists("build/test_export/THIRD-PARTY-LICENSES.txt"));
    assert(exists("build/test_export/assets/scenes/arena_01.scene.json"));

    auto lddRes = executeShell("ldd build/test_export/game-player");
    assert(lddRes.status == 0, "ldd failed on exported static binary");
    assert(!lddRes.output.canFind("libSDL3"), "libSDL3 dynamically linked:\n" ~ lddRes.output);
    assert(!lddRes.output.canFind("libfreetype"), "libfreetype dynamically linked:\n" ~ lddRes.output);
    assert(!lddRes.output.canFind("libwgpu"), "libwgpu dynamically linked:\n" ~ lddRes.output);
    assert(!lddRes.output.canFind("libbox3d"), "libbox3d dynamically linked:\n" ~ lddRes.output);

    if (exists("build/test_export")) rmdirRecurse("build/test_export");
}
