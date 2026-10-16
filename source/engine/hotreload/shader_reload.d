/// Shader hot-reloader: watches assets/shaders/, preprocesses changed shaders,
/// and transactionally updates active GPU pipelines without restarting.
module engine.hotreload.shader_reload;

import std.file : exists, isDir, dirEntries, SpanMode, timeLastModified;
import std.datetime.systime : SysTime;
import std.path : baseName, relativePath, buildPath;
import std.string : endsWith;
import engine.hotreload.watcher : FileWatcher;
import engine.hotreload.shader_source : loadAndPreprocessShader;
import engine.core.log : info, warn, err;

import engine.scene.scene3d : Scene3D;
import engine.scene.scene3d_textured : Scene3DTextured;
import engine.devtools.gizmos : GizmoRenderer;
import engine.ui.render.batch : UiBatchRenderer;
import engine.gpu.renderer : Renderer;

@safe:

struct ShaderHotReloader {
    FileWatcher watcher;
    string shadersDir = "assets/shaders";
    SysTime[string] fileModTimes;
    bool enabled = true;
    bool initialized = false;

    bool init(string dir = "assets/shaders") @trusted {
        shadersDir = dir;
        if (!exists(dir) || !isDir(dir)) {
            warn("ShaderHotReloader: directory '%s' does not exist", dir);
            return false;
        }

        // Record initial timestamps
        try {
            foreach (entry; dirEntries(dir, SpanMode.breadth)) {
                if (!entry.isDir && entry.name.endsWith(".wgsl")) {
                    fileModTimes[entry.name] = entry.timeLastModified;
                }
            }
        } catch (Exception e) {
            warn("ShaderHotReloader: failed to scan directory '%s': %s", dir, e.msg);
        }

        if (!watcher.init([dir], 0.2f)) {
            warn("ShaderHotReloader: failed to initialize FileWatcher");
            return false;
        }

        initialized = true;
        info("ShaderHotReloader: watching '%s' for live WGSL changes", dir);
        return true;
    }

    void shutdown() @trusted {
        if (initialized) {
            watcher.shutdown();
            fileModTimes.clear();
            initialized = false;
        }
    }

    /// Poll for changes and reload any affected shaders.
    /// Returns the number of shaders successfully reloaded.
    uint pollAndReload(
        scope Scene3D* scene = null,
        scope Scene3DTextured* texScene = null,
        scope GizmoRenderer* gizmos = null,
        scope UiBatchRenderer* uiRenderer = null,
        scope Renderer* renderer = null,
        float dt = 0.016f
    ) scope @trusted {
        if (!enabled || !initialized) return 0;

        if (!watcher.poll(dt)) return 0;

        // Detect which files actually changed
        string[] changedFiles;
        bool commonChanged = false;

        try {
            foreach (entry; dirEntries(shadersDir, SpanMode.breadth)) {
                if (entry.isDir || !entry.name.endsWith(".wgsl")) continue;

                auto mtime = entry.timeLastModified;
                auto pOld = entry.name in fileModTimes;
                if (pOld is null || *pOld != mtime) {
                    fileModTimes[entry.name] = mtime;
                    changedFiles ~= entry.name;
                    immutable bName = entry.name.baseName;
                    if (bName == "pbr_brdf.wgsl" ||
                        bName == "shadows.wgsl" ||
                        bName == "fullscreen_vs.wgsl") {
                        commonChanged = true;
                    }
                }
            }
        } catch (Exception e) {
            err("ShaderHotReloader: error scanning files: %s", e.msg);
            return 0;
        }

        if (changedFiles.length == 0 && !commonChanged) return 0;

        info("ShaderHotReloader: detected shader changes (%d files, commonChanged=%s)",
            cast(int) changedFiles.length, commonChanged ? "true" : "false");

        uint reloadedCount = 0;

        // Helper to reload a single shader file
        bool tryReloadFile(string fullOrRelPath) {
            string rel = relativePath(fullOrRelPath, shadersDir);
            immutable name = baseName(rel);

            auto res = loadAndPreprocessShader(rel, null, shadersDir);
            if (!res.success) {
                err("ShaderHotReloader: preprocessing failed for '%s': %s", rel, res.errorMessage);
                return false;
            }

            bool ok = false;
            switch (name) {
                case "colored3d.wgsl":
                    if (scene !is null) {
                        ok = scene.reloadShader(res.code);
                    }
                    break;
                case "textured3d_pbr.wgsl":
                    if (texScene !is null) {
                        ok = texScene.reloadShader(res.code);
                    }
                    break;
                case "gizmo_line.wgsl":
                    if (gizmos !is null) {
                        ok = gizmos.reloadShader(res.code);
                    }
                    break;
                case "ui2d.wgsl":
                    if (uiRenderer !is null) {
                        ok = uiRenderer.reloadShader(res.code);
                    }
                    break;
                case "post_bloom_threshold.wgsl":
                    if (renderer !is null) {
                        ok = renderer.reloadPostShader("bloom_threshold", res.code);
                    }
                    break;
                case "post_bloom_down_karis.wgsl":
                    if (renderer !is null) {
                        ok = renderer.reloadPostShader("bloom_down_karis", res.code);
                    }
                    break;
                case "post_bloom_down.wgsl":
                    if (renderer !is null) {
                        ok = renderer.reloadPostShader("bloom_down", res.code);
                    }
                    break;
                case "post_bloom_up.wgsl":
                    if (renderer !is null) {
                        ok = renderer.reloadPostShader("bloom_up", res.code);
                    }
                    break;
                case "post_tonemap.wgsl":
                    if (renderer !is null) {
                        ok = renderer.reloadPostShader("tonemap", res.code);
                    }
                    break;
                case "post_fxaa.wgsl":
                    if (renderer !is null) {
                        ok = renderer.reloadPostShader("fxaa", res.code);
                    }
                    break;
                case "post_blit.wgsl":
                    if (renderer !is null) {
                        ok = renderer.reloadPostShader("blit", res.code);
                    }
                    break;
                default:
                    // Common or unhandled shader
                    break;
            }

            if (ok) {
                info("ShaderHotReloader: successfully reloaded '%s'", name);
            } else if (name != "fullscreen_vs.wgsl" && name != "pbr_brdf.wgsl" && name != "shadows.wgsl") {
                warn("ShaderHotReloader: failed or skipped reloading '%s'", name);
            }
            return ok;
        }

        if (commonChanged) {
            // Reload all dependent shaders
            immutable allShaders = [
                "colored3d.wgsl",
                "textured3d_pbr.wgsl",
                "post_bloom_threshold.wgsl",
                "post_bloom_down_karis.wgsl",
                "post_bloom_down.wgsl",
                "post_bloom_up.wgsl",
                "post_tonemap.wgsl",
                "post_fxaa.wgsl",
                "post_blit.wgsl",
            ];
            foreach (rel; allShaders) {
                if (exists(buildPath(shadersDir, rel)) && tryReloadFile(rel)) reloadedCount++;
            }
        } else {
            foreach (path; changedFiles) {
                if (tryReloadFile(path)) reloadedCount++;
            }
        }

        return reloadedCount;
    }
}
