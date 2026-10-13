/// Script module registration and ABI boundary.
module engine.script.module_entry;

import engine.ecs.store : EntityId;
import engine.ecs.scene_world : SceneWorld;
import engine.reflect.attrs;
import engine.reflect.descriptor : ComponentTypeId, TypeRegistry, LifecycleMask;
import engine.core.strings : StringId, StringTable;
import engine.script.context : ScriptContext;

@safe:

enum uint ENGINE_SCRIPT_ABI = 0x2026_0102;

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

        static if (__traits(hasMember, C, "onStart")) {
            desc.lifecycleMask |= LifecycleMask.onStart;
            desc.onStart = function(void* ptr, scope ref ScriptContext ctx) @trusted nothrow {
                try {
                    auto comp = cast(C*) ptr;
                    static if (__traits(compiles, comp.onStart(ctx))) {
                        comp.onStart(ctx);
                    }
                } catch (Exception) {}
            };
        }

        static if (__traits(hasMember, C, "onUpdate")) {
            desc.lifecycleMask |= LifecycleMask.onUpdate;
            desc.onUpdate = function(void* ptr, scope ref ScriptContext ctx) @trusted nothrow {
                try {
                    auto comp = cast(C*) ptr;
                    static if (__traits(compiles, comp.onUpdate(ctx, ctx.dt))) {
                        comp.onUpdate(ctx, ctx.dt);
                    } else static if (__traits(compiles, comp.onUpdate(ctx))) {
                        comp.onUpdate(ctx);
                    }
                } catch (Exception) {}
            };
        }

        static if (__traits(hasMember, C, "onFixedUpdate")) {
            desc.lifecycleMask |= LifecycleMask.onFixedUpdate;
            desc.onFixedUpdate = function(void* ptr, scope ref ScriptContext ctx) @trusted nothrow {
                try {
                    auto comp = cast(C*) ptr;
                    static if (__traits(compiles, comp.onFixedUpdate(ctx, ctx.dt))) {
                        comp.onFixedUpdate(ctx, ctx.dt);
                    } else static if (__traits(compiles, comp.onFixedUpdate(ctx))) {
                        comp.onFixedUpdate(ctx);
                    }
                } catch (Exception) {}
            };
        }

        static if (__traits(hasMember, C, "onDestroy")) {
            desc.lifecycleMask |= LifecycleMask.onDestroy;
            desc.onDestroy = function(void* ptr, scope ref ScriptContext ctx) @trusted nothrow {
                try {
                    auto comp = cast(C*) ptr;
                    static if (__traits(compiles, comp.onDestroy(ctx))) {
                        comp.onDestroy(ctx);
                    }
                } catch (Exception) {}
            };
        }

        static if (__traits(hasMember, C, "onValidate")) {
            desc.lifecycleMask |= LifecycleMask.onValidate;
            desc.onValidate = function(void* ptr, scope ref ScriptContext ctx) @trusted nothrow {
                try {
                    auto comp = cast(C*) ptr;
                    static if (__traits(compiles, comp.onValidate(ctx))) {
                        comp.onValidate(ctx);
                    }
                } catch (Exception) {}
            };
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
        systems ~= desc;
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
