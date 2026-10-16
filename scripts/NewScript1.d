module scripts.NewScript1;

import engine.script;

@component struct NewScript1 {
    @export_ float speed = 10.0f;

    void onStart(scope ref ScriptContext ctx) {
    }

    void onUpdate(scope ref ScriptContext ctx, float dt) {
    }
}
