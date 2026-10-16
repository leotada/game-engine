module scripts.NewScript;

import engine.script;

@component struct NewScript {
    @export_ float speed = 10.0f;

    void onStart(scope ref ScriptContext ctx) {
    }

    void onUpdate(scope ref ScriptContext ctx, float dt) {
    }
}
