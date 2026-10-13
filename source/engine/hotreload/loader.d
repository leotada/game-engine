/// Dynamic shared library loader for game scripts using druntime Runtime.loadLibrary.
module engine.hotreload.loader;

import core.runtime : Runtime;
import core.sys.posix.dlfcn : dlsym;
import std.file : copy, remove, exists, mkdirRecurse;
import std.path : dirName;
import std.format : format;
import engine.script.module_entry : ENGINE_SCRIPT_ABI, ModuleRegistrar;
import engine.reflect.descriptor : TypeRegistry;
import engine.core.strings : StringTable;
import engine.ecs.scene_world : SceneWorld;
import engine.core.log : info, warn, err;

@safe:

alias AbiFn = extern(C) uint function() nothrow;
alias RegisterFn = extern(C) void function(ref ModuleRegistrar);
alias ShutdownFn = extern(C) void function() nothrow;

struct ScriptModule {
    void* handle = null;
    string instancePath;
    ModuleRegistrar registrar;
    uint abiVersion = 0;

    ShutdownFn shutdownFn = null;

    bool isLoaded() const scope nothrow @nogc {
        return handle !is null;
    }

    bool load(string sourceSoPath, ref TypeRegistry types, ref StringTable strings, size_t instanceIndex) @trusted {
        if (!exists(sourceSoPath)) {
            err("ScriptModule.load: file does not exist: %s", sourceSoPath);
            return false;
        }

        // Generate unique instance path to bypass OS dynamic linker caching of inode/filename
        instancePath = format(".engine/bin/libgame_inst_%d.so", instanceIndex);
        try {
            auto dir = dirName(instancePath);
            if (!exists(dir)) mkdirRecurse(dir);
            if (exists(instancePath)) remove(instancePath);
            copy(sourceSoPath, instancePath);
        } catch (Exception e) {
            err("ScriptModule.load: failed to copy library to instance path: %s", e.msg);
            return false;
        }

        handle = Runtime.loadLibrary(instancePath);
        if (handle is null) {
            err("ScriptModule.load: Runtime.loadLibrary failed for %s", instancePath);
            return false;
        }

        auto abiSym = cast(AbiFn) dlsym(handle, "engine_script_abi");
        if (abiSym is null) {
            err("ScriptModule.load: 'engine_script_abi' symbol not found");
            unloadInternal();
            return false;
        }

        abiVersion = abiSym();
        if (abiVersion != ENGINE_SCRIPT_ABI) {
            err("ScriptModule.load: ABI mismatch! Expected 0x%08x, got 0x%08x", ENGINE_SCRIPT_ABI, abiVersion);
            unloadInternal();
            return false;
        }

        auto regSym = cast(RegisterFn) dlsym(handle, "engine_game_register");
        if (regSym is null) {
            err("ScriptModule.load: 'engine_game_register' symbol not found");
            unloadInternal();
            return false;
        }

        shutdownFn = cast(ShutdownFn) dlsym(handle, "engine_game_shutdown");

        // Initialize registrar
        registrar.types = &types;
        registrar.strings = &strings;
        registrar.components.length = 0;
        registrar.systems.length = 0;

        try {
            regSym(registrar);
        } catch (Exception e) {
            err("ScriptModule.load: exception during engine_game_register: %s", e.msg);
            unloadInternal();
            return false;
        }

        info("ScriptModule: successfully loaded %s (%d components, %d systems)",
            instancePath, cast(int) registrar.components.length, cast(int) registrar.systems.length);
        return true;
    }

    void unload(ref SceneWorld world) @trusted {
        if (handle is null) return;

        if (shutdownFn !is null) {
            shutdownFn();
            shutdownFn = null;
        }

        // Unregister component stores from SceneWorld
        foreach (ref comp; registrar.components) {
            world.unregisterType(comp.typeId);
        }
        registrar.components.length = 0;
        registrar.systems.length = 0;

        unloadInternal();
    }

    private void unloadInternal() @trusted {
        if (handle !is null) {
            Runtime.unloadLibrary(handle);
            handle = null;
        }
        if (instancePath.length > 0) {
            try {
                if (exists(instancePath)) remove(instancePath);
            } catch (Exception) {}
            instancePath = null;
        }
    }
}
