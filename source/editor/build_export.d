/// Build and standalone player export pipeline (ED-8).
module editor.build_export;

import std.file : exists, mkdirRecurse, copy, dirEntries, SpanMode, isFile, write, setAttributes, getAttributes;
import std.path : buildPath, baseName, dirName;
import std.process : executeShell;
import std.format : format;
import engine.core.log : info, warn, err;

@safe:

struct BuildExportOptions {
    string targetPlatform = "linux-x86_64";
    string outputDir = "build/linux-x86_64";
    string startScene = "assets/scenes/arena_01.scene.json";
    string[] includedScenes;
    bool release = false;
    string compiler = "dmd";
    bool useCardBarrier = false; // default false for stock DMD, opt-in for custom DMD/LDC
}

struct ExportPipeline {
    static bool exportGame(const ref BuildExportOptions opts, out string outLog) @trusted {
        outLog = "";
        info("Export: starting game export to %s...", opts.outputDir);

        try {
            // 1. Prepare target directories
            if (!exists(opts.outputDir)) mkdirRecurse(opts.outputDir);
            auto targetAssets = buildPath(opts.outputDir, "assets");
            if (!exists(targetAssets)) mkdirRecurse(targetAssets);
            auto targetLibs = buildPath(opts.outputDir, "libs");
            if (!exists(targetLibs)) mkdirRecurse(targetLibs);

            // 2. Copy assets
            if (exists("assets")) {
                foreach (entry; dirEntries("assets", SpanMode.depth)) {
                    if (!entry.isFile) continue;
                    string relPath = entry.name;
                    string dest = buildPath(opts.outputDir, relPath);
                    auto destDir = dirName(dest);
                    if (!exists(destDir)) mkdirRecurse(destDir);
                    copy(entry.name, dest);
                }
            }
            info("Export: copied assets to target bundle");

            // 3. Copy runtime shared libraries from libs/
            if (exists("libs")) {
                foreach (entry; dirEntries("libs", SpanMode.shallow)) {
                    if (entry.isFile && (entry.name.length >= 3 && entry.name[$ - 3 .. $] == ".so")) {
                        string dest = buildPath(targetLibs, baseName(entry.name));
                        copy(entry.name, dest);
                    }
                }
            }

            // 4. Build standalone player
            string extraFlags = "";
            if (opts.useCardBarrier) {
                if (opts.compiler == "ldc2" || opts.compiler == "ldc") {
                    extraFlags = ` --dflags="-gc-card-marking -d-version=Symgc_cards -d-version=Symgc_druntime_hooks"`;
                } else if (opts.compiler == "dmd") {
                    extraFlags = ` --dflags="-preview=gcbarrier -version=Symgc_cards -version=Symgc_druntime_hooks"`;
                }
            }
            string dubCmd = format("dub build --config=player --compiler=%s %s%s",
                opts.compiler, opts.release ? "--build=release" : "", extraFlags);
            info("Export: compiling standalone player (%s)...", dubCmd);
            auto res = executeShell(dubCmd);
            outLog ~= res.output;

            if (res.status != 0) {
                err("Export: build failed with exit code %d:\n%s", res.status, res.output);
                return false;
            }

            // 5. Copy player executable to bundle
            string playerBin = "game-engine-player";
            if (exists(playerBin)) {
                string destBin = buildPath(opts.outputDir, "game-player");
                copy(playerBin, destBin);
                // Make executable
                auto attrs = getAttributes(destBin);
                setAttributes(destBin, attrs | 0b001001001); // chmod +x
            }

            // 6. Generate run.sh launcher
            string launcherScript =
                "#!/bin/bash\n" ~
                "DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd)\"\n" ~
                "export LD_LIBRARY_PATH=\"$DIR/libs:$LD_LIBRARY_PATH\"\n" ~
                "export SDL_VIDEODRIVER=\"${SDL_VIDEODRIVER:-wayland,x11}\"\n" ~
                "export SYMGC_HEAP_RESERVE_GIB=\"${SYMGC_HEAP_RESERVE_GIB:-256}\"\n" ~
                "export SYMGC_CONCURRENT=\"${SYMGC_CONCURRENT:-1}\"\n" ~
                "\"$DIR/game-player\" --scene=\"" ~ opts.startScene ~ "\" \"$@\"\n";

            string launcherPath = buildPath(opts.outputDir, "run.sh");
            write(launcherPath, launcherScript);
            auto runAttrs = getAttributes(launcherPath);
            setAttributes(launcherPath, runAttrs | 0b001001001);

            info("Export: successfully packaged game in %s!", opts.outputDir);
            return true;
        } catch (Exception e) {
            err("Export: fatal error during export: %s", e.msg);
            outLog ~= "\nFatal error: " ~ e.msg;
            return false;
        }
    }
}

unittest {
    BuildExportOptions opts;
    opts.outputDir = "build/test_export";
    opts.startScene = "assets/scenes/arena_01.scene.json";
    string outLog;
    assert(ExportPipeline.exportGame(opts, outLog), "ExportPipeline failed: " ~ outLog);
    assert(exists("build/test_export/game-player"));
    assert(exists("build/test_export/run.sh"));
    assert(exists("build/test_export/assets/scenes/arena_01.scene.json"));

    import std.file : rmdirRecurse;
    if (exists("build/test_export")) rmdirRecurse("build/test_export");
}
