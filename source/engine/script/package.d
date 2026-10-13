/// Public API for game scripting.
module engine.script;

public import engine.script.context : ScriptContext;
public import engine.reflect.attrs :
    component, export_, exported, hide, range, tooltip, header,
    formerlyNamed, runInEditor, system, Stage;
public import engine.math.vec : Vec2, Vec3, Vec4;
public import engine.math.quat : Quat;
public import engine.math.mat : Mat4;
public import engine.ecs.store : EntityId;
public import engine.ecs.scene_world : SceneWorld;
public import engine.scene.graph : Transform;
public import engine.platform.input : Key, MouseButton, InputState;
public import engine.core.strings : StringId;
