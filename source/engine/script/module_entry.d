/// Script module registration and ABI boundary.
module engine.script.module_entry;

import engine.ecs.store : EntityId;
import engine.ecs.scene_world : SceneWorld;
import engine.reflect.attrs;
import engine.reflect.descriptor : ComponentTypeId, TypeRegistry, LifecycleMask;
import engine.core.strings : StringId, StringTable;
import engine.script.context : ScriptContext;
import engine.core.log : err;

@safe:

enum uint ENGINE_SCRIPT_ABI = 0x2026_0103;

alias ScriptLifecycleFn = void function(void* compPtr, scope ref ScriptContext ctx) @safe nothrow;
alias SystemFn = void function(ref SceneWorld world, float dt);

struct ScriptComponentDescriptor {
    StringId qualifiedName;
    ComponentTypeId typeId;
    uint lifecycleMask;
    ScriptLifecycleFn onStart;
    ScriptLifecycleFn onUpdate;
    ScriptLifecycleFn onFixedUpdate;
    ScriptLifecycleFn onLateUpdate;
    ScriptLifecycleFn onDestroy;
    ScriptLifecycleFn onValidate;
}

struct ScriptSystemDescriptor {
    Stage stage = Stage.update;
    int order = 0;
    SystemFn callback;
}

/// Type-erased entry point of one component method. Exceptions are logged: they must not cross into the engine.
private void lifecycleThunk(C, string method)(void* ptr, scope ref ScriptContext ctx) @trusted nothrow {
    try
        callLifecycle!(C, method)(*cast(C*) ptr, ctx);
    catch (Exception e)
        err(__traits(identifier, C) ~ "." ~ method ~ ": exception: ", e.msg);
}

/// Calls `comp.method` with whichever supported parameter list it declares. Not `nothrow`, so methods need no
/// particular attributes; a method with any other signature is a compile error instead of silently never running.
private void callLifecycle(C, string method)(ref C comp, ref ScriptContext ctx) @system {
    static if (__traits(compiles, __traits(getMember, comp, method)(ctx, ctx.dt)))
        __traits(getMember, comp, method)(ctx, ctx.dt);
    else static if (__traits(compiles, __traits(getMember, comp, method)(ctx)))
        __traits(getMember, comp, method)(ctx);
    else static if (__traits(compiles, __traits(getMember, comp, method)(ctx.dt)))
        __traits(getMember, comp, method)(ctx.dt);
    else static if (__traits(compiles, __traits(getMember, comp, method)()))
        __traits(getMember, comp, method)();
    else
        static assert(false, C.stringof ~ "." ~ method
            ~ " must be callable as (ref ScriptContext, float dt), (ref ScriptContext), (float dt) or ()");
}

/// Registrar passed across the dynamic library boundary to discover components and systems.
struct ModuleRegistrar {
    TypeRegistry* types = null;
    StringTable* strings = null;
    ScriptComponentDescriptor[] components;
    ScriptSystemDescriptor[] systems;

    void registerComponent(C)() @trusted {
        static assert(is(C == struct), "Component must be a struct");
        immutable name = __traits(identifier, C);
        assert(types !is null && strings !is null, "Registrar not initialized");

        ComponentTypeId tid = types.register!C(*strings);

        ScriptComponentDescriptor desc;
        desc.qualifiedName = strings.intern(name);
        desc.typeId = tid;

        static foreach (method; ["onStart", "onUpdate", "onFixedUpdate", "onLateUpdate", "onDestroy", "onValidate"]) {
            static if (__traits(hasMember, C, method)) {
                desc.lifecycleMask |= __traits(getMember, LifecycleMask, method);
                __traits(getMember, desc, method) = &lifecycleThunk!(C, method);
            }
        }

        components ~= desc;
    }

    void registerSystem(alias Fn)() @trusted {
        ScriptSystemDescriptor desc;
        static if (__traits(getAttributes, Fn).length > 0) {
            foreach (attr; __traits(getAttributes, Fn)) {
                static if (is(typeof(attr) == system)) {
                    desc.stage = attr.stage;
                    desc.order = attr.order;
                }
            }
        }
        desc.callback = function(ref SceneWorld world, float dt) {
            Fn(world, dt);
        };
        // Kept sorted by `order`; systems with the same order keep their registration order.
        size_t at = systems.length;
        while (at > 0 && systems[at - 1].order > desc.order)
            at--;
        systems = systems[0 .. at] ~ desc ~ systems[at .. $];
    }
}

template registerModuleInRegistrar(alias M) {
    void registerModuleInRegistrar(ref ModuleRegistrar r) {
        static foreach (memberName; __traits(allMembers, M)) {
            static if (__traits(compiles, __traits(getMember, M, memberName))) {
                alias Member = __traits(getMember, M, memberName);
                static if (is(Member == struct)) {
                    static if (hasUda!(Member, component)) {
                        r.registerComponent!Member();
                    }
                } else static if (is(typeof(Member) == function)) {
                    static if (hasUda!(Member, system)) {
                        r.registerSystem!Member();
                    }
                }
            }
        }
    }
}

private template hasUda(alias T, alias UdaType) {
    enum hasUda = () {
        foreach (attr; __traits(getAttributes, T)) {
            static if (is(attr == UdaType) || is(typeof(attr) == UdaType))
                return true;
        }
        return false;
    }();
}

mixin template GameModuleEntry(Modules...) {
    extern(C) export uint engine_script_abi() nothrow {
        return ENGINE_SCRIPT_ABI;
    }

    extern(C) export void engine_game_register(ref ModuleRegistrar r) {
        static foreach (M; Modules) {
            registerModuleInRegistrar!M(r);
        }
    }

    extern(C) export void engine_game_shutdown() nothrow {
    }
}
