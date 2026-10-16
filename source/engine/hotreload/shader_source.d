/// WGSL Shader Preprocessor with #include, #define, #ifdef/#ifndef, and hybrid disk/embedded loading.
module engine.hotreload.shader_source;

import std.algorithm : canFind, startsWith;
import std.array : appender, split;
import std.file : exists, readText;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.string : indexOf, lastIndexOf, splitLines, strip;
import std.typecons : Yes;
import engine.core.log : info, warn, err;

@safe:

/// Structure representing a preprocessed shader result.
struct PreprocessedShader {
    string code;
    string[] includedFiles;
    bool success;
    string errorMessage;
}

/// Preprocesses WGSL source text, resolving `#include`, `#define`, `#ifdef`, `#ifndef`, `#else`, `#endif`.
PreprocessedShader preprocessShader(
    string sourceCode,
    string currentVirtualPath = "",
    const(string)[] initialDefines = null,
    string baseDir = "assets/shaders"
) @trusted {
    PreprocessedShader result;
    result.success = true;

    bool[string] definedSymbols;
    foreach (d; initialDefines) {
        definedSymbols[d.strip()] = true;
    }

    bool[string] includedCanonical;
    string[] includeStack;

    if (currentVirtualPath.length > 0) {
        string normalizedRoot = buildNormalizedPath(currentVirtualPath);
        includedCanonical[normalizedRoot] = true;
        includeStack ~= normalizedRoot;
    }

    string processText(string text, string currentDir, string currentFile) {
        auto outApp = appender!string();
        auto lines = text.splitLines(Yes.keepTerminator); // Keep terminators

        // Conditional compilation state stack: (active, hasExecutedBranch)
        struct CondState {
            bool active;
            bool conditionMet;
        }
        CondState[] condStack;

        bool isCurrentlyEmitting() {
            foreach (ref st; condStack) {
                if (!st.active) return false;
            }
            return true;
        }

        foreach (size_t lineIdx, line; lines) {
            string trimmed = line.strip();

            if (trimmed.startsWith("#define")) {
                if (isCurrentlyEmitting()) {
                    string symbol = trimmed[7 .. $].strip();
                    if (symbol.length > 0) {
                        definedSymbols[symbol] = true;
                    }
                }
                continue;
            }

            if (trimmed.startsWith("#undef")) {
                if (isCurrentlyEmitting()) {
                    string symbol = trimmed[6 .. $].strip();
                    definedSymbols.remove(symbol);
                }
                continue;
            }

            if (trimmed.startsWith("#ifdef")) {
                string symbol = trimmed[6 .. $].strip();
                bool parentActive = isCurrentlyEmitting();
                bool matches = (symbol in definedSymbols) !is null;
                condStack ~= CondState(parentActive && matches, matches);
                continue;
            }

            if (trimmed.startsWith("#ifndef")) {
                string symbol = trimmed[7 .. $].strip();
                bool parentActive = isCurrentlyEmitting();
                bool matches = (symbol !in definedSymbols);
                condStack ~= CondState(parentActive && matches, matches);
                continue;
            }

            if (trimmed.startsWith("#else")) {
                if (condStack.length > 0) {
                    bool parentActive = true;
                    if (condStack.length > 1) {
                        foreach (ref st; condStack[0 .. $ - 1]) {
                            if (!st.active) { parentActive = false; break; }
                        }
                    }
                    condStack[$ - 1].active = parentActive && !condStack[$ - 1].conditionMet;
                }
                continue;
            }

            if (trimmed.startsWith("#endif")) {
                if (condStack.length > 0) {
                    condStack = condStack[0 .. $ - 1];
                }
                continue;
            }

            if (trimmed.startsWith("#include")) {
                if (!isCurrentlyEmitting()) continue;

                // Extract quoted path: #include "path"
                auto firstQuote = trimmed.indexOf('"');
                auto lastQuote = trimmed.lastIndexOf('"');
                if (firstQuote >= 0 && lastQuote > firstQuote) {
                    string includeRel = trimmed[firstQuote + 1 .. lastQuote];
                    string resolvedVirtual;
                    if (includeRel.startsWith("/") || includeRel.startsWith("\\")) {
                        resolvedVirtual = buildNormalizedPath(includeRel[1 .. $]);
                    } else if (currentDir.length > 0) {
                        resolvedVirtual = buildNormalizedPath(currentDir, includeRel);
                    } else {
                        resolvedVirtual = buildNormalizedPath(includeRel);
                    }

                    // Check for circular inclusion
                    if (includeStack.canFind(resolvedVirtual)) {
                        warn("Shader Preprocessor: circular include detected for '", resolvedVirtual, "' - skipping");
                        continue;
                    }

                    // Pragma once semantics: if already included in this translation unit, skip
                    if (resolvedVirtual in includedCanonical) {
                        continue;
                    }

                    includedCanonical[resolvedVirtual] = true;
                    result.includedFiles ~= resolvedVirtual;
                    includeStack ~= resolvedVirtual;

                    // Read content: use embedded source in CTFE, or try disk first at runtime
                    string includePathOnDisk = buildPath(baseDir, resolvedVirtual);
                    string includedContent = "";
                    bool loaded = false;

                    if (__ctfe) {
                        includedContent = getEmbeddedShaderSource(resolvedVirtual);
                        loaded = (includedContent.length > 0);
                    } else {
                        try {
                            if (exists(includePathOnDisk)) {
                                includedContent = readText(includePathOnDisk);
                                loaded = true;
                            }
                        } catch (Exception e) {
                            warn("Shader Preprocessor: failed to read include from disk '", includePathOnDisk, "': ", e.msg);
                        }

                        if (!loaded) {
                            includedContent = getEmbeddedShaderSource(resolvedVirtual);
                            loaded = (includedContent.length > 0);
                        }
                    }

                    if (loaded) {
                        string nextDir = dirName(resolvedVirtual);
                        if (nextDir == ".") nextDir = "";
                        string processedChild = processText(includedContent, nextDir, resolvedVirtual);
                        outApp.put(processedChild);
                        outApp.put("\n");
                    } else {
                        err("Shader Preprocessor: could not locate shader include '", resolvedVirtual, "'");
                        result.success = false;
                        result.errorMessage = "Missing include: " ~ resolvedVirtual;
                    }

                    includeStack = includeStack[0 .. $ - 1];
                }
                continue;
            }

            // Normal shader code line
            if (isCurrentlyEmitting()) {
                outApp.put(line);
            }
        }

        return outApp.data;
    }

    string entryDir = currentVirtualPath.length > 0 ? dirName(currentVirtualPath) : "";
    if (entryDir == ".") entryDir = "";

    result.code = processText(sourceCode, entryDir, currentVirtualPath);
    return result;
}

/// Loads and preprocesses a shader from disk or fallback embedded resources.
PreprocessedShader loadAndPreprocessShader(
    string virtualPath,
    const(string)[] initialDefines = null,
    string baseDir = "assets/shaders"
) @trusted {
    string filePath = buildPath(baseDir, virtualPath);
    string sourceText;
    bool loaded = false;

    try {
        if (exists(filePath)) {
            sourceText = readText(filePath);
            loaded = true;
        }
    } catch (Exception e) {
        warn("Shader source: failed reading ", filePath, ": ", e.msg);
    }

    if (!loaded) {
        sourceText = getEmbeddedShaderSource(virtualPath);
        if (sourceText.length > 0) {
            loaded = true;
        }
    }

    if (!loaded) {
        PreprocessedShader errResult;
        errResult.success = false;
        errResult.errorMessage = "Shader not found: " ~ virtualPath;
        return errResult;
    }

    return preprocessShader(sourceText, virtualPath, initialDefines, baseDir);
}

/// Embedded fallback dictionary containing standard shaders compiled into the binary.
string getEmbeddedShaderSource(string virtualPath) nothrow @trusted {
    switch (virtualPath) {
        case "common/fullscreen_vs.wgsl":
            return import("common/fullscreen_vs.wgsl");
        case "common/pbr_brdf.wgsl":
            return import("common/pbr_brdf.wgsl");
        case "common/shadows.wgsl":
            return import("common/shadows.wgsl");
        case "cube3d.wgsl":
            return import("cube3d.wgsl");
        case "colored3d.wgsl":
            return import("colored3d.wgsl");
        case "textured3d_pbr.wgsl":
            return import("textured3d_pbr.wgsl");
        case "shadow_depth.wgsl":
            return import("shadow_depth.wgsl");
        case "gizmo_line.wgsl":
            return import("gizmo_line.wgsl");
        case "text2d.wgsl":
            return import("text2d.wgsl");
        case "ui2d.wgsl":
            return import("ui2d.wgsl");
        case "post_bloom_threshold.wgsl":
            return import("post_bloom_threshold.wgsl");
        case "post_bloom_down_karis.wgsl":
            return import("post_bloom_down_karis.wgsl");
        case "post_bloom_down.wgsl":
            return import("post_bloom_down.wgsl");
        case "post_bloom_up.wgsl":
            return import("post_bloom_up.wgsl");
        case "post_tonemap.wgsl":
            return import("post_tonemap.wgsl");
        case "post_fxaa.wgsl":
            return import("post_fxaa.wgsl");
        case "post_blit.wgsl":
            return import("post_blit.wgsl");
        default:
            return "";
    }
}

unittest {
    // 1. Test basic preprocess with defines
    string src = `
#define USE_FOG
#ifdef USE_FOG
fn applyFog() -> f32 { return 1.0; }
#else
fn applyFog() -> f32 { return 0.0; }
#endif
#ifndef NO_SPEC
fn specular() -> f32 { return 0.5; }
#endif
`;
    auto p1 = preprocessShader(src, "test.wgsl");
    assert(p1.success);
    assert(p1.code.canFind("applyFog() -> f32 { return 1.0; }"));
    assert(!p1.code.canFind("applyFog() -> f32 { return 0.0; }"));
    assert(p1.code.canFind("specular() -> f32 { return 0.5; }"));

    // 2. Test embedded shader access and #include resolution
    auto pTextured = loadAndPreprocessShader("textured3d_pbr.wgsl");
    assert(pTextured.success, pTextured.errorMessage);
    assert(pTextured.code.canFind("evalBRDF"));
    assert(pTextured.code.canFind("FrameUniforms"));
    assert(pTextured.code.canFind("sampleDirShadowPCF"));
    assert(!pTextured.code.canFind("#include"));

    // 3. Test post-processing shader with fullscreen triangle include
    auto pTonemap = loadAndPreprocessShader("post_tonemap.wgsl");
    assert(pTonemap.success);
    assert(pTonemap.code.canFind("fn vs_main"));
    assert(pTonemap.code.canFind("acesNarkowicz"));
}
