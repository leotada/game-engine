/// ED-6 lights UI: inspector Light section, Scene IBL preset panel, UBO +
/// shadow-caster budget counting / enforcement, ECS → LightSet packing.
module engine.editor.light_panel;

import engine.core.log : warn;
import engine.ecs.store : EntityId;
import engine.editor.components : worldPosition;
import engine.editor.selection : Selection, noSelection;
import engine.editor.ui :
    UiContext, UiRect, checkbox, combo, label, panel, separator, sliderFloat;
import engine.gpu.shadow : directionalLightVP, spotLightVPFromCone;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;
import engine.scene.light :
    GpuDirLight, GpuPointLight, GpuSpotLight, Light, LightSet, LightType,
    MAX_DIR_LIGHTS, MAX_DIR_SHADOW_CASTERS, MAX_POINT_LIGHTS,
    MAX_POINT_SHADOW_CASTERS, MAX_SPOT_LIGHTS, MAX_SPOT_SHADOW_CASTERS;

@safe:

// ---------------------------------------------------------------------------
// IBL / scene settings (global — not a Light component)
// ---------------------------------------------------------------------------

/// Procedural IBL look presets (GPU rebuild is owned by the host / Stream J).
enum IblPreset : uint {
    defaultSky = 0,
    studio     = 1,
    outdoor    = 2,
    dusk       = 3,
    night      = 4,
}

/// Scene-level lighting settings edited by the Scene panel.
struct SceneLightSettings {
    IblPreset iblPreset = IblPreset.defaultSky;
    float iblIntensity = 1.0f;
    /// Ortho half-extent used when packing directional shadow VPs / gizmos.
    float dirShadowRadius = 14.0f;
    Vec3 dirShadowCenter = Vec3(0, 1, 0);
}

/// Persistent UI state for Scene + Light inspector widgets.
struct LightPanelState {
    bool lightTypeOpen = false;
    bool iblPresetOpen = false;
    SceneLightSettings scene;
    /// Last budget-warning string length (for unit tests / debug).
    uint lastWarnFlags = 0;
}

enum uint WarnUboOverflow = 1;
enum uint WarnShadowBudget = 2;
enum uint WarnTypeChangeBlocked = 4;

// ---------------------------------------------------------------------------
// Budget counting
// ---------------------------------------------------------------------------

/// Live counts of lights / shadow casters in the editor world.
struct LightBudgetCounts {
    uint dir;
    uint point;
    uint spot;
    uint dirShadows;
    uint pointShadows;
    uint spotShadows;
}

/// Count lights of each type. Pass `exclude` to ignore an entity (type change).
LightBudgetCounts countLightBudgets(W)(ref W world, EntityId exclude = noSelection)
        nothrow @nogc {
    LightBudgetCounts c;
    foreach (id; world.query!(Light)()) {
        if (!world.alive(id) || id == exclude) continue;
        immutable light = world.get!Light(id);
        final switch (light.type) {
            case LightType.directional:
                c.dir++;
                if (light.castShadows) c.dirShadows++;
                break;
            case LightType.point:
                c.point++;
                if (light.castShadows) c.pointShadows++;
                break;
            case LightType.spot:
                c.spot++;
                if (light.castShadows) c.spotShadows++;
                break;
        }
    }
    return c;
}

/// True if a new light of `type` fits in the UBO slot budget.
bool canSpawnLightType(W)(ref W world, LightType type) nothrow @nogc {
    immutable c = countLightBudgets(world);
    final switch (type) {
        case LightType.directional: return c.dir < MAX_DIR_LIGHTS;
        case LightType.point:       return c.point < MAX_POINT_LIGHTS;
        case LightType.spot:        return c.spot < MAX_SPOT_LIGHTS;
    }
}

/// True if any light type still has a free UBO slot.
bool canSpawnAnyLight(W)(ref W world) nothrow @nogc {
    immutable c = countLightBudgets(world);
    return c.dir < MAX_DIR_LIGHTS
        || c.point < MAX_POINT_LIGHTS
        || c.spot < MAX_SPOT_LIGHTS;
}

/// Pick a default Light for spawn: prefer free dir, then point, then spot.
Light defaultLightForSpawn(W)(ref W world) nothrow @nogc {
    immutable c = countLightBudgets(world);
    Light light;
    if (c.dir < MAX_DIR_LIGHTS) {
        light.type = LightType.directional;
        light.intensity = 2.5f;
        light.castShadows = c.dirShadows < MAX_DIR_SHADOW_CASTERS ? 1 : 0;
        return light;
    }
    if (c.point < MAX_POINT_LIGHTS) {
        light.type = LightType.point;
        light.intensity = 8.0f;
        light.range = 12.0f;
        light.castShadows = c.pointShadows < MAX_POINT_SHADOW_CASTERS ? 1 : 0;
        return light;
    }
    light.type = LightType.spot;
    light.intensity = 12.0f;
    light.range = 16.0f;
    light.innerConeDeg = 15.0f;
    light.outerConeDeg = 25.0f;
    light.castShadows = c.spotShadows < MAX_SPOT_SHADOW_CASTERS ? 1 : 0;
    return light;
}

/// True if enabling `castShadows` on `type` fits the caster budget
/// (counts exclude `exclude`, typically the entity being edited).
bool canEnableCastShadows(W)(ref W world, LightType type, EntityId exclude = noSelection)
        nothrow @nogc {
    immutable c = countLightBudgets(world, exclude);
    final switch (type) {
        case LightType.directional: return c.dirShadows < MAX_DIR_SHADOW_CASTERS;
        case LightType.point:       return c.pointShadows < MAX_POINT_SHADOW_CASTERS;
        case LightType.spot:        return c.spotShadows < MAX_SPOT_SHADOW_CASTERS;
    }
}

/// True if changing `exclude`'s type to `newType` still fits UBO caps.
bool canChangeLightType(W)(ref W world, EntityId exclude, LightType newType) nothrow @nogc {
    if (exclude != noSelection && world.alive(exclude) && world.has!Light(exclude)) {
        if (world.get!Light(exclude).type == newType)
            return true;
    }
    return canSpawnLightTypeCountingExclude(world, newType, exclude);
}

private bool canSpawnLightTypeCountingExclude(W)(
    ref W world, LightType type, EntityId exclude
) nothrow @nogc {
    immutable c = countLightBudgets(world, exclude);
    final switch (type) {
        case LightType.directional: return c.dir < MAX_DIR_LIGHTS;
        case LightType.point:       return c.point < MAX_POINT_LIGHTS;
        case LightType.spot:        return c.spot < MAX_SPOT_LIGHTS;
    }
}

/// Apply `castShadows` request; if over budget, leave off and return false.
bool trySetCastShadows(W)(
    ref W world,
    EntityId id,
    ref Light light,
    bool want
) nothrow @nogc {
    if (!want) {
        light.castShadows = 0;
        return true;
    }
    if (!canEnableCastShadows(world, light.type, id)) {
        light.castShadows = 0;
        warn("Light castShadows blocked: shadow caster budget full");
        return false;
    }
    light.castShadows = 1;
    return true;
}

// ---------------------------------------------------------------------------
// Direction helpers (Transform local -Y = ray into scene)
// ---------------------------------------------------------------------------

/// Illumination ray direction (light → scene). Local −Y.
Vec3 lightRayDirection(Quat rotation) {
    return rotation.rotate(Vec3(0, -1, 0)).normalized();
}

/// Shading L vector for directional lights (surface → light).
Vec3 lightShadingDirection(Quat rotation) {
    return -lightRayDirection(rotation);
}

Vec3 lightRayDirection(ref const Transform t) {
    return lightRayDirection(t.rotation);
}

// ---------------------------------------------------------------------------
// Pack ECS → LightSet
// ---------------------------------------------------------------------------

/// Pack world lights into a `LightSet` for `Scene3DTextured.setLights`.
/// UBO overflow lights are skipped. Shadow flags that exceed caster budgets
/// are cleared in the packed set (ECS component unchanged — call
/// `reconcileShadowBudgets` to write back warnings).
LightSet packLightsFromWorld(W)(
    ref W world,
    ref const SceneLightSettings settings
) {
    LightSet set;
    set.dirEnabled = false;
    set.pointCount = 0;
    set.spotCount = 0;
    set.shadowBias = 0.0004f;

    uint dirShadows = 0, pointShadows = 0, spotShadows = 0;

    foreach (id; world.query!(Light)()) {
        if (!world.alive(id) || !world.has!Transform(id)) continue;
        immutable light = world.get!Light(id);
        immutable t = world.get!Transform(id);
        immutable pos = worldPosition(world, id);
        immutable ray = lightRayDirection(t);
        immutable col = Vec3(light.color[0], light.color[1], light.color[2]);

        final switch (light.type) {
            case LightType.directional: {
                if (set.dirEnabled) break; // UBO: only first dir
                GpuDirLight d;
                d.direction = -ray;
                d.color = col;
                d.intensity = light.intensity;
                immutable radius = light.range > 0.1f ? light.range : settings.dirShadowRadius;
                d.viewProj = directionalLightVP(d.direction, settings.dirShadowCenter, radius);
                d.castShadows = light.castShadows != 0
                    && dirShadows < MAX_DIR_SHADOW_CASTERS;
                if (d.castShadows) dirShadows++;
                set.dir = d;
                set.dirEnabled = true;
                break;
            }
            case LightType.point: {
                if (set.pointCount >= MAX_POINT_LIGHTS) break;
                GpuPointLight p;
                p.position = pos;
                p.color = col;
                p.intensity = light.intensity;
                p.range = light.range;
                p.castShadows = light.castShadows != 0
                    && pointShadows < MAX_POINT_SHADOW_CASTERS;
                if (p.castShadows) pointShadows++;
                set.points[set.pointCount++] = p;
                break;
            }
            case LightType.spot: {
                if (set.spotCount >= MAX_SPOT_LIGHTS) break;
                GpuSpotLight s;
                s.position = pos;
                s.direction = ray;
                s.color = col;
                s.intensity = light.intensity;
                s.range = light.range;
                s.innerConeDeg = light.innerConeDeg;
                s.outerConeDeg = light.outerConeDeg;
                s.viewProj = spotLightVPFromCone(
                    pos, ray, light.outerConeDeg, 0.1f, light.range > 0.1f ? light.range : 25.0f);
                s.castShadows = light.castShadows != 0
                    && spotShadows < MAX_SPOT_SHADOW_CASTERS;
                if (s.castShadows) spotShadows++;
                set.spots[set.spotCount++] = s;
                break;
            }
        }
    }
    return set;
}

/// Clear `castShadows` on lights that exceed caster budgets (stable entity order).
/// Returns number of lights demoted. Logs once per demotion.
uint reconcileShadowBudgets(W)(ref W world) {
    uint dirS, pointS, spotS;
    uint demoted = 0;
    foreach (id; world.query!(Light)()) {
        if (!world.alive(id)) continue;
        auto light = world.get!Light(id);
        if (light.castShadows == 0) continue;

        bool ok = false;
        final switch (light.type) {
            case LightType.directional:
                ok = dirS < MAX_DIR_SHADOW_CASTERS;
                if (ok) dirS++;
                break;
            case LightType.point:
                ok = pointS < MAX_POINT_SHADOW_CASTERS;
                if (ok) pointS++;
                break;
            case LightType.spot:
                ok = spotS < MAX_SPOT_SHADOW_CASTERS;
                if (ok) spotS++;
                break;
        }
        if (!ok) {
            light.castShadows = 0;
            world.set(id, light);
            demoted++;
            warn("Light castShadows cleared: shadow caster budget exceeded");
        }
    }
    return demoted;
}

// ---------------------------------------------------------------------------
// Budget hint formatting (stack buffer, no GC)
// ---------------------------------------------------------------------------

/// Write a short budget summary into `buf`. Returns slice length.
size_t formatLightBudgetHint(ref const LightBudgetCounts c, scope char[] buf)
        nothrow @nogc {
    size_t n = 0;
    void put(char ch) {
        if (n < buf.length) buf[n++] = ch;
    }
    void putStr(scope const(char)[] s) {
        foreach (ch; s) put(ch);
    }
    void putU(uint v) {
        char[10] dig = void;
        size_t nd = 0;
        if (v == 0) {
            dig[nd++] = '0';
        } else {
            while (v > 0 && nd < dig.length) {
                dig[nd++] = cast(char)('0' + (v % 10));
                v /= 10;
            }
        }
        foreach_reverse (i; 0 .. nd) put(dig[i]);
    }

    putStr("UBO d");
    putU(c.dir); put('/'); putU(MAX_DIR_LIGHTS);
    putStr(" p");
    putU(c.point); put('/'); putU(MAX_POINT_LIGHTS);
    putStr(" s");
    putU(c.spot); put('/'); putU(MAX_SPOT_LIGHTS);
    return n;
}

size_t formatShadowBudgetHint(ref const LightBudgetCounts c, scope char[] buf)
        nothrow @nogc {
    size_t n = 0;
    void put(char ch) {
        if (n < buf.length) buf[n++] = ch;
    }
    void putStr(scope const(char)[] s) {
        foreach (ch; s) put(ch);
    }
    void putU(uint v) {
        char[10] dig = void;
        size_t nd = 0;
        if (v == 0) {
            dig[nd++] = '0';
        } else {
            while (v > 0 && nd < dig.length) {
                dig[nd++] = cast(char)('0' + (v % 10));
                v /= 10;
            }
        }
        foreach_reverse (i; 0 .. nd) put(dig[i]);
    }

    putStr("Sh d");
    putU(c.dirShadows); put('/'); putU(MAX_DIR_SHADOW_CASTERS);
    putStr(" p");
    putU(c.pointShadows); put('/'); putU(MAX_POINT_SHADOW_CASTERS);
    putStr(" s");
    putU(c.spotShadows); put('/'); putU(MAX_SPOT_SHADOW_CASTERS);
    return n;
}

// ---------------------------------------------------------------------------
// Inspector — Light section
// ---------------------------------------------------------------------------

/// Draw Light component fields for the selected entity. Returns true if changed.
bool drawLightInspectorSection(W)(
    ref UiContext ui,
    ref W world,
    EntityId id,
    ref LightPanelState state
) {
    if (id == noSelection || !world.alive(id) || !world.has!Light(id))
        return false;

    separator(ui);
    label(ui, "Light");

    auto light = world.get!Light(id);
    bool changed = false;
    state.lastWarnFlags = 0;

    immutable budgets = countLightBudgets(world);
    {
        char[64] hint = void;
        immutable hn = formatLightBudgetHint(budgets, hint[]);
        label(ui, hint[0 .. hn]);
        immutable sn = formatShadowBudgetHint(budgets, hint[]);
        label(ui, hint[0 .. sn]);
    }

    int lt = cast(int) light.type;
    if (lt < 0) lt = 0;
    if (lt > 2) lt = 2;
    scope const(char[])[] types = ["directional", "point", "spot"];
    if (combo(ui, "Type", types, lt, state.lightTypeOpen)) {
        immutable newType = cast(LightType) lt;
        if (canChangeLightType(world, id, newType)) {
            light.type = newType;
            // Drop shadow if new type has no free caster slot.
            if (light.castShadows && !canEnableCastShadows(world, newType, id)) {
                light.castShadows = 0;
                state.lastWarnFlags |= WarnShadowBudget;
                warn("castShadows cleared after light type change (budget)");
            }
            world.set(id, light);
            changed = true;
        } else {
            state.lastWarnFlags |= WarnTypeChangeBlocked;
            warn("Light type change blocked: UBO budget full for that type");
        }
    }

    if (sliderFloat(ui, "Color R", light.color[0], 0, 1)) changed = true;
    if (sliderFloat(ui, "Color G", light.color[1], 0, 1)) changed = true;
    if (sliderFloat(ui, "Color B", light.color[2], 0, 1)) changed = true;
    if (sliderFloat(ui, "Intensity", light.intensity, 0, 40)) changed = true;

    if (light.type == LightType.directional) {
        if (sliderFloat(ui, "Ortho radius", light.range, 1, 100))
            changed = true;
    } else {
        if (sliderFloat(ui, "Range", light.range, 0.1f, 100))
            changed = true;
    }

    if (light.type == LightType.spot) {
        if (sliderFloat(ui, "Inner cone", light.innerConeDeg, 1, 80))
            changed = true;
        if (sliderFloat(ui, "Outer cone", light.outerConeDeg, 1, 89))
            changed = true;
        if (light.outerConeDeg < light.innerConeDeg)
            light.outerConeDeg = light.innerConeDeg;
    }

    bool castSh = light.castShadows != 0;
    if (checkbox(ui, "Cast shadows", castSh)) {
        if (!trySetCastShadows(world, id, light, castSh))
            state.lastWarnFlags |= WarnShadowBudget;
        changed = true;
    }

    if (changed)
        world.set(id, light);
    return changed;
}

// ---------------------------------------------------------------------------
// Scene panel (IBL preset)
// ---------------------------------------------------------------------------

/// Draw Scene settings (IBL preset + intensity). Returns true if changed.
bool drawScenePanel(W)(
    ref UiContext ui,
    UiRect area,
    ref LightPanelState state
) {
    panel(ui, "Scene", area);
    bool changed = false;

    label(ui, "IBL");
    int preset = cast(int) state.scene.iblPreset;
    if (preset < 0) preset = 0;
    if (preset > 4) preset = 4;
    scope const(char[])[] names = [
        "defaultSky", "studio", "outdoor", "dusk", "night"
    ];
    if (combo(ui, "Preset", names, preset, state.iblPresetOpen)) {
        state.scene.iblPreset = cast(IblPreset) preset;
        changed = true;
    }
    if (sliderFloat(ui, "IBL intensity", state.scene.iblIntensity, 0, 4))
        changed = true;
    if (sliderFloat(ui, "Dir shadow R", state.scene.dirShadowRadius, 1, 80))
        changed = true;

    separator(ui);
    label(ui, "Limits");
    {
        char[48] line = void;
        size_t n = 0;
        void put(char c) { if (n < line.length) line[n++] = c; }
        void putStr(scope const(char)[] s) { foreach (ch; s) put(ch); }
        putStr("dir/pt/sp ");
        // static caps — no world needed
        put('1'); put('/'); put('8'); put('/'); put('4');
        label(ui, line[0 .. n]);
        n = 0;
        putStr("sh 1/4/2");
        label(ui, line[0 .. n]);
    }
    return changed;
}

/// Compact Scene block for embedding under Hierarchy (no outer panel chrome).
bool drawSceneSettingsInline(ref UiContext ui, ref LightPanelState state) {
    separator(ui);
    label(ui, "Scene / IBL");
    bool changed = false;
    int preset = cast(int) state.scene.iblPreset;
    if (preset < 0) preset = 0;
    if (preset > 4) preset = 4;
    scope const(char[])[] names = [
        "defaultSky", "studio", "outdoor", "dusk", "night"
    ];
    if (combo(ui, "IBL preset", names, preset, state.iblPresetOpen)) {
        state.scene.iblPreset = cast(IblPreset) preset;
        changed = true;
    }
    if (sliderFloat(ui, "IBL inten.", state.scene.iblIntensity, 0, 4))
        changed = true;
    return changed;
}

@safe unittest {
    import engine.editor.components : EditorWorld;

    EditorWorld world;
    LightPanelState panel;

    assert(canSpawnAnyLight(world));

    auto a = world.spawn();
    world.set(a, Transform(Vec3(0, 2, 0)));
    world.set(a, defaultLightForSpawn(world));
    assert(world.has!Light(a));
    assert(world.has!Transform(a));

    // Fill directional slot — second dir spawn must fail via canSpawn.
    assert(!canSpawnLightType(world, LightType.directional));

    auto b = world.spawn();
    Light point = Light.init;
    point.type = LightType.point;
    world.set(b, Transform(Vec3(1, 2, 0)));
    world.set(b, point);

    auto counts = countLightBudgets(world);
    assert(counts.dir == 1);
    assert(counts.point == 1);

    char[64] buf = void;
    immutable n = formatLightBudgetHint(counts, buf[]);
    assert(n > 0);

    auto la = world.get!Light(a);
    assert(trySetCastShadows(world, a, la, true));
    world.set(a, la);

    auto packed = packLightsFromWorld(world, panel.scene);
    assert(packed.dirEnabled);
    assert(packed.pointCount == 1);
}
