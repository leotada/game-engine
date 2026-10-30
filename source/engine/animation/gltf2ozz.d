/// Wrapper around upstream's offline `gltf2ozz` converter. The runtime port does not contain the
/// offline pipeline; the editor calls the external tool when it is installed.
module engine.animation.gltf2ozz;

@safe:

/// Full path of `gltf2ozz` on `PATH`, or null.
string findGltf2Ozz() {
    import std.file : exists;
    import std.path : buildPath, pathSeparator;
    import std.process : environment;
    import std.algorithm : splitter;
    foreach (dir; environment.get("PATH", "").splitter(pathSeparator)) {
        if (dir.length == 0) continue;
        immutable p = buildPath(dir, "gltf2ozz");
        if (exists(p)) return p;
    }
    return null;
}

/// Converts `gltfPath` into `.ozz` files next to it (`outDir`), using upstream's default
/// config. Returns false and sets `message` if the tool is missing or fails.
bool convertGltfToOzz(string gltfPath, string outDir, out string message) @trusted {
    import std.file : exists, mkdirRecurse;
    import std.path : buildPath, baseName, stripExtension;
    import std.process : execute;
    if (!exists(gltfPath)) { message = "file not found: " ~ gltfPath; return false; }
    immutable tool = findGltf2Ozz();
    if (tool is null) { message = "gltf2ozz not found on PATH (build ozz-animation's tools)"; return false; }
    try {
        mkdirRecurse(outDir);
        immutable stem = baseName(stripExtension(gltfPath));
        auto r = execute([tool, "--file=" ~ gltfPath,
                          "--skeleton=" ~ buildPath(outDir, stem ~ "_skeleton.ozz"),
                          "--animation=" ~ buildPath(outDir, stem ~ "_" ~ "*.ozz")]);
        message = r.output;
        return r.status == 0;
    } catch (Exception e) {
        message = e.msg;
        return false;
    }
}

unittest {
    import std.process : environment;
    // Missing tool or file are reported, never thrown.
    string msg;
    assert(!convertGltfToOzz("does/not/exist.gltf", "build/gltf2ozz_test", msg) && msg.length > 0);
    // A fake tool on PATH is found and its exit status is respected.
    import std.file : mkdirRecurse, write, rmdirRecurse, exists, setAttributes;
    enum dir = "build/fake_gltf2ozz_bin";
    mkdirRecurse(dir);
    scope (exit) if (exists(dir)) rmdirRecurse(dir);
    write(dir ~ "/gltf2ozz", "#!/bin/sh\nexit 3\n");
    setAttributes(dir ~ "/gltf2ozz", 0b111_101_101);
    write(dir ~ "/a.gltf", "{}");
    immutable old = environment.get("PATH", "");
    environment["PATH"] = dir ~ ":" ~ old;
    scope (exit) environment["PATH"] = old;
    assert(findGltf2Ozz() !is null);
    assert(!convertGltfToOzz(dir ~ "/a.gltf", dir ~ "/out", msg));
}
