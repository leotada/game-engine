/// Prefab asset format, PrefabInstance component, instantiation, override tracking, and apply/revert.
module engine.scene.prefab;

import std.file : exists, readText, write;
import std.json : JSONValue, parseJSON, JSONType;
import engine.core.pod : isPod;
import engine.core.strings : StringId, StringTable;
import engine.ecs.store : EntityId;
import engine.ecs.scene_world : SceneWorld;
import engine.math.vec : Vec3;
import engine.project.asset_ref : AssetGuid;
import engine.reflect.attrs : component, export_;
import engine.editor.components : MaterialOverride, Name, Parent, PhysicsBody, Visual, noParent;
import engine.editor.scene_load :
    SceneLoadOptions, collectSubtreeEntities, lightFromData, lightToData, loadSceneAdditive, materialFromData,
    materialToData, physicsFromData, physicsToData, subtreeToSceneFile;
import engine.math.quat : Quat;
import engine.reflect.descriptor : FieldKind, invalidComponentTypeId;
import engine.reflect.serialize : deserializeComponent, serializeComponent;
import engine.scene.graph : Transform;
import engine.scene.light : Light;
import engine.scene.scene_file :
    SceneComponentData, SceneEntityData, SceneFile, SceneLightData, SceneMaterialData, SceneMeta, ScenePhysicsData,
    SceneTransformData, loadSceneFile, saveSceneFile;
import engine.core.log : info, warn, err;

@safe:

/// Attached to entities that originate from a prefab asset.
@component struct PrefabInstance {
    AssetGuid prefabGuid;
    uint sourceRoot = 0;
    Vec3 spawnOffset = Vec3(0, 0, 0);
}

static assert(isPod!PrefabInstance);

struct PrefabPropertyOverride {
    uint entityLocalId;
    StringId componentName;
    StringId fieldName;
    JSONValue overrideValue;
}

/// Loads a prefab file (*.prefab.json) from disk.
SceneFile loadPrefabFile(string path) @trusted {
    return loadSceneFile(path);
}

/// Saves a prefab file (*.prefab.json) to disk.
void savePrefabFile(string path, ref const SceneFile prefab) @trusted {
    saveSceneFile(path, prefab);
}

/// Instantiates a prefab additively into the world, attaching `PrefabInstance` to the root.
EntityId instantiatePrefab(
    ref SceneWorld world,
    ref const SceneFile prefab,
    ref StringTable strings,
    AssetGuid prefabGuid = AssetGuid.init,
    Vec3 offsetPosition = Vec3(0, 0, 0)
) @trusted {
    if (prefab.entities.length == 0) return EntityId.max;

    SceneFile copy = cast(SceneFile) prefab;
    copy.entities = copy.entities.dup; // loading clamps shadow flags in place
    SceneLoadOptions opts;
    opts.checkAssetFiles = false;

    auto res = loadSceneAdditive(world, copy, offsetPosition, opts);
    auto rootFileId = copy.entities[0].id;
    if (auto p = rootFileId in res.fileIdToEntity) {
        auto liveId = *p;
        world.set(liveId, PrefabInstance(prefabGuid, rootFileId, offsetPosition));
        return liveId;
    }

    return EntityId.max;
}

/// Destroys `instanceRoot` and every descendant entity in its `Parent` hierarchy.
void destroyPrefabHierarchy(ref SceneWorld world, EntityId instanceRoot) @trusted {
    auto subtree = collectSubtreeEntities(world, instanceRoot);
    foreach_reverse (e; subtree) {
        if (world.alive(e))
            world.destroy(e);
    }
}

/// Reverts a prefab instance (and all its children) back to the prefab's original state.
/// Returns the new root, or `EntityId.max` when the instance is missing.
EntityId revertPrefab(
    ref SceneWorld world,
    EntityId instanceRoot,
    ref const SceneFile prefab,
    ref StringTable strings
) @trusted {
    if (!world.alive(instanceRoot) || !world.has!PrefabInstance(instanceRoot))
        return EntityId.max;

    auto inst = world.get!PrefabInstance(instanceRoot);
    EntityId externalParent = noParent;
    if (world.has!Parent(instanceRoot))
        externalParent = world.get!Parent(instanceRoot).entity;

    destroyPrefabHierarchy(world, instanceRoot);
    auto id = instantiatePrefab(world, prefab, strings, inst.prefabGuid, inst.spawnOffset);
    if (id != EntityId.max && externalParent != noParent && world.alive(externalParent))
        world.set(id, Parent(externalParent));
    info("Reverted prefab instance");
    return id;
}

/// Applies changes made on the prefab instance subtree back to the prefab definition file.
void applyPrefabOverrides(
    ref SceneWorld world,
    EntityId instanceRoot,
    string prefabPath,
    ref StringTable strings
) @trusted {
    if (!world.alive(instanceRoot) || !world.has!PrefabInstance(instanceRoot)) return;

    immutable inst = world.get!PrefabInstance(instanceRoot);
    SceneMeta meta = SceneMeta("prefab", "meters");
    if (world.has!Name(instanceRoot)) {
        immutable sid = world.get!Name(instanceRoot).id;
        if (!sid.isNull)
            meta.name = world.strings.get(sid).idup;
    }

    auto updated = subtreeToSceneFile(world, instanceRoot, inst.spawnOffset, meta);
    savePrefabFile(prefabPath, updated);
    info("Applied prefab overrides from instance %d to %s (%d entities)",
        instanceRoot, prefabPath, cast(int) updated.entities.length);
}

/// Compute property-level overrides between a live prefab instance subtree and its source `SceneFile`.
PrefabPropertyOverride[] diffPrefabOverrides(
    ref SceneWorld world,
    EntityId instanceRoot,
    ref const SceneFile prefab,
    ref StringTable strings
) @trusted {
    PrefabPropertyOverride[] overrides;
    if (!world.alive(instanceRoot) || !world.has!PrefabInstance(instanceRoot))
        return overrides;

    immutable inst = world.get!PrefabInstance(instanceRoot);
    auto liveScene = subtreeToSceneFile(world, instanceRoot, inst.spawnOffset);
    auto match = matchPrefabEntities(prefab, liveScene);

    uint toPrefabId(uint liveFileId) @safe {
        foreach (pi, li; match)
            if (li >= 0 && liveScene.entities[li].id == liveFileId)
                return prefab.entities[pi].id;
        return 0;
    }

    foreach (pi, ref const baseE; prefab.entities) {
        if (match[pi] < 0)
            continue;
        const liveE = &liveScene.entities[match[pi]];
        immutable localId = baseE.id;

        void add(string comp, string field, JSONValue val) {
            overrides ~= PrefabPropertyOverride(localId, strings.intern(comp), strings.intern(field), val);
        }
        // Every field of one data section that differs. A section only the instance has differs in all its fields.
        void section(T)(string comp, ref const T live, ref const T base, bool baseHas) {
            static foreach (i; 0 .. T.tupleof.length) {
                if (!baseHas || live.tupleof[i] != base.tupleof[i])
                    add(comp, __traits(identifier, T.tupleof[i]), toJson(live.tupleof[i]));
            }
        }

        section("Transform", liveE.transform, baseE.transform, true);
        immutable liveName = entityName(liveScene, *liveE);
        if (liveName != entityName(prefab, baseE))
            add("Name", "name", JSONValue(liveName));
        if (liveE.hasMaterial)
            section("MaterialOverride", liveE.material, baseE.material, baseE.hasMaterial);
        if (liveE.hasLight)
            section("Light", liveE.light, baseE.light, baseE.hasLight);
        if (liveE.hasPhysics)
            section("PhysicsBody", liveE.physics, baseE.physics, baseE.hasPhysics);

        foreach (ref const lc; liveE.customComponents) {
            immutable tid = world.types.find(lc.typeName, world.strings);
            if (tid == invalidComponentTypeId || lc.data.type != JSONType.object)
                continue;
            // The prefab file may omit fields at their default: compare complete components.
            auto bytes = new ubyte[world.types.getType(tid).size];
            bool baseHas;
            foreach (ref const bc; baseE.customComponents) {
                if (bc.typeName == lc.typeName) {
                    deserializeComponent(world.types, tid, bc.data, bytes, world.strings, (uint id) => id);
                    baseHas = true;
                }
            }
            JSONValue baseJson;
            if (baseHas)
                baseJson = serializeComponent(world.types, tid, bytes, world.strings, (uint id) => id);
            foreach (ref const fd; world.types.getFields(tid)) {
                string field = world.strings.get(fd.name).idup;
                auto lv = field in lc.data.object;
                if (lv is null)
                    continue;
                JSONValue v = *lv;
                if (fd.kind == FieldKind.entityRef)
                    v = JSONValue(cast(long) toPrefabId(cast(uint) jsonNum(v)));
                if (baseHas && field in baseJson.object && baseJson[field] == v)
                    continue;
                add(lc.typeName, field, v);
            }
        }
    }

    return overrides;
}

/// Apply `PrefabPropertyOverride` entries to a `SceneFile` in place.
void applyPropertyOverridesToSceneFile(
    ref SceneFile prefab,
    scope const(PrefabPropertyOverride)[] overrides,
    ref const StringTable strings
) @trusted {
    foreach (ref const ov; overrides) {
        SceneEntityData* target = null;
        foreach (ref e; prefab.entities) {
            if (e.id == ov.entityLocalId) {
                target = &e;
                break;
            }
        }
        if (target is null) continue;

        string comp = strings.get(ov.componentName).idup;
        string field = strings.get(ov.fieldName).idup;
        switch (comp) {
            case "Transform":
                setField(target.transform, field, ov.overrideValue);
                break;
            case "Name":
                if (ov.overrideValue.type == JSONType.string) {
                    target.hasName = ov.overrideValue.str.length > 0;
                    if (target.hasName) {
                        target.name = cast(int) prefab.strings.length;
                        prefab.strings ~= ov.overrideValue.str;
                    }
                }
                break;
            case "MaterialOverride":
                target.hasMaterial = true;
                setField(target.material, field, ov.overrideValue);
                break;
            case "Light":
                target.hasLight = true;
                setField(target.light, field, ov.overrideValue);
                break;
            case "PhysicsBody":
                target.hasPhysics = true;
                setField(target.physics, field, ov.overrideValue);
                break;
            default:
                SceneComponentData* c;
                foreach (ref cc; target.customComponents)
                    if (cc.typeName == comp) c = &cc;
                if (c is null) {
                    target.customComponents ~= SceneComponentData(comp, JSONValue(string[string].init));
                    c = &target.customComponents[$ - 1];
                }
                JSONValue value = ov.overrideValue;
                c.data[field] = value;
                break;
        }
    }
}

/// Apply `PrefabPropertyOverride` entries directly to a live prefab instance subtree.
/// `prefab` is the definition the overrides' entity ids belong to; without it, the ids are taken as 1-based positions
/// in `collectSubtreeEntities` order.
bool applyPropertyOverrides(
    ref SceneWorld world,
    EntityId instanceRoot,
    scope const(PrefabPropertyOverride)[] overrides,
    ref StringTable strings,
    scope const(SceneFile)* prefab = null
) @trusted {
    if (!world.alive(instanceRoot) || !world.has!PrefabInstance(instanceRoot))
        return false;

    auto subtree = collectSubtreeEntities(world, instanceRoot);
    EntityId[uint] liveOf;
    if (prefab is null) {
        foreach (i, id; subtree)
            liveOf[cast(uint) i + 1] = id;
    } else {
        auto liveScene = subtreeToSceneFile(world, instanceRoot);
        foreach (pi, li; matchPrefabEntities(*prefab, liveScene))
            if (li >= 0)
                liveOf[prefab.entities[pi].id] = subtree[li];
    }

    foreach (ref const ov; overrides) {
        auto pt = ov.entityLocalId in liveOf;
        if (pt is null || !world.alive(*pt)) continue;
        immutable target = *pt;

        string comp = strings.get(ov.componentName).idup;
        string field = strings.get(ov.fieldName).idup;
        switch (comp) {
            case "Transform":
                if (!world.has!Transform(target)) break;
                auto t = world.get!Transform(target);
                SceneTransformData d;
                d.pos = [t.position.x, t.position.y, t.position.z];
                d.rot = [t.rotation.x, t.rotation.y, t.rotation.z, t.rotation.w];
                d.scale = [t.scale.x, t.scale.y, t.scale.z];
                if (!setField(d, field, ov.overrideValue)) break;
                t.position = Vec3(d.pos[0], d.pos[1], d.pos[2]);
                if (field == "pos" && target == instanceRoot)
                    t.position = t.position + world.get!PrefabInstance(instanceRoot).spawnOffset;
                t.rotation = Quat(d.rot[0], d.rot[1], d.rot[2], d.rot[3]);
                t.scale = Vec3(d.scale[0], d.scale[1], d.scale[2]);
                world.set(target, t);
                break;
            case "Name":
                if (ov.overrideValue.type != JSONType.string) break;
                world.set(target, Name(ov.overrideValue.str.length
                    ? world.strings.intern(ov.overrideValue.str) : StringId.init));
                break;
            case "MaterialOverride":
                SceneMaterialData m;
                if (world.has!MaterialOverride(target))
                    m = materialToData(world.get!MaterialOverride(target));
                if (setField(m, field, ov.overrideValue))
                    world.set(target, materialFromData(m));
                break;
            case "Light":
                SceneLightData l;
                if (world.has!Light(target))
                    l = lightToData(world.get!Light(target));
                if (setField(l, field, ov.overrideValue))
                    world.set(target, lightFromData(l));
                break;
            case "PhysicsBody":
                ScenePhysicsData p;
                StringId asset;
                if (world.has!PhysicsBody(target)) {
                    p = physicsToData(world.get!PhysicsBody(target));
                    asset = world.get!PhysicsBody(target).assetPath;
                }
                if (setField(p, field, ov.overrideValue)) {
                    auto pb = physicsFromData(p, asset);
                    if (world.has!PhysicsBody(target)) {
                        pb.halfExtents = world.get!PhysicsBody(target).halfExtents;
                        pb.showCollider = world.get!PhysicsBody(target).showCollider;
                    }
                    world.set(target, pb);
                }
                break;
            default:
                immutable tid = world.types.find(comp, world.strings);
                if (tid == invalidComponentTypeId) break;
                auto bytes = new ubyte[world.types.getType(tid).size];
                auto cur = world.rawGet(tid, target);
                JSONValue json = JSONValue(string[string].init);
                if (cur !is null)
                    json = serializeComponent(world.types, tid, cur, world.strings);
                JSONValue value = ov.overrideValue;
                foreach (ref const fd; world.types.getFields(tid)) {
                    if (fd.kind != FieldKind.entityRef || world.strings.get(fd.name) != field) continue;
                    auto r = cast(uint) jsonNum(value) in liveOf;
                    value = JSONValue(cast(long)(r is null ? EntityId.max : *r));
                }
                json[field] = value;
                deserializeComponent(world.types, tid, json, bytes, world.strings);
                world.rawAdd(tid, target, bytes);
                break;
        }
    }
    return true;
}

/// For every prefab entity, the index in `live.entities` of the entity it corresponds to, or -1. Roots pair up;
/// children of paired entities pair by name first, then by order, so a child deleted from (or added to) an instance
/// does not shift its siblings.
private int[] matchPrefabEntities(ref const SceneFile prefab, ref const SceneFile live) {
    auto result = new int[](prefab.entities.length);
    result[] = -1;
    if (prefab.entities.length == 0 || live.entities.length == 0)
        return result;
    auto taken = new bool[](live.entities.length);
    result[0] = 0;
    taken[0] = true;

    size_t[] queue = [0];
    while (queue.length) {
        immutable pi = queue[0];
        queue = queue[1 .. $];
        immutable pid = prefab.entities[pi].id, lid = live.entities[result[pi]].id;
        foreach (byName; [true, false]) {
            foreach (ci, ref const pc; prefab.entities) {
                if (ci == 0 || pc.parent != pid || result[ci] >= 0)
                    continue;
                immutable name = entityName(prefab, pc);
                foreach (li, ref const lc; live.entities) {
                    if (taken[li] || lc.parent != lid || (byName && entityName(live, lc) != name))
                        continue;
                    result[ci] = cast(int) li;
                    taken[li] = true;
                    queue ~= ci;
                    break;
                }
            }
        }
    }
    return result;
}

private string entityName(ref const SceneFile scene, ref const SceneEntityData e) {
    return e.hasName && e.name >= 0 && e.name < cast(int) scene.strings.length ? scene.strings[e.name] : "";
}

private JSONValue toJson(T)(const T v) {
    static if (is(T : E[N], E, size_t N) && !is(T == string))
        return JSONValue(v[].dup);
    else
        return JSONValue(v);
}

/// Set the member `field` of a scene data section from JSON. False when it does not exist or the value does not fit.
private bool setField(T)(ref T data, string field, ref const JSONValue v) @trusted {
    static foreach (i; 0 .. T.tupleof.length) {
        if (field == __traits(identifier, T.tupleof[i])) {
            alias M = typeof(T.tupleof[i]);
            static if (is(M == bool)) {
                if (v.type != JSONType.true_ && v.type != JSONType.false_) return false;
                data.tupleof[i] = v.type == JSONType.true_;
                return true;
            } else static if (is(M == string)) {
                if (v.type != JSONType.string) return false;
                data.tupleof[i] = v.str;
                return true;
            } else static if (is(M : E[N], E, size_t N)) {
                if (v.type != JSONType.array || v.array.length < N) return false;
                foreach (k; 0 .. N)
                    data.tupleof[i][k] = cast(E) jsonNum(v.array[k]);
                return true;
            } else {
                data.tupleof[i] = cast(M) jsonNum(v);
                return true;
            }
        }
    }
    return false;
}

/**
 * Hot-reload: rebuild every live instance of the prefab `prefabGuid` from
 * `newPrefab`, keeping each instance's own property overrides.
 *
 * Overrides are measured against `oldPrefab` (the definition the instances
 * were spawned from), then every instance is re-instantiated from
 * `newPrefab` under the same external parent and the overrides are applied
 * again. Edited prefab fields therefore reach every instance, while values
 * changed on a single instance (moved root, recolored child, ...) survive.
 *
 * Instance entities get new IDs; code holding raw `EntityId`s into an
 * instance subtree must re-resolve them. Returns the number of instances
 * rebuilt. Load-time work (allocates).
 */
uint reloadPrefabInstances(
    ref SceneWorld world,
    AssetGuid prefabGuid,
    ref const SceneFile oldPrefab,
    ref const SceneFile newPrefab
) @trusted {
    if (prefabGuid.isNull || newPrefab.entities.length == 0) return 0;

    EntityId[] roots;
    foreach (e; world.query!PrefabInstance()) {
        if (!world.alive(e)) continue;
        if (world.get!PrefabInstance(e).prefabGuid == prefabGuid) roots ~= e;
    }

    uint rebuilt;
    foreach (root; roots) {
        if (!world.alive(root)) continue;
        auto overrides = diffPrefabOverrides(world, root, oldPrefab, world.strings);
        immutable fresh = revertPrefab(world, root, newPrefab, world.strings);
        if (fresh == EntityId.max) continue;
        applyPropertyOverrides(world, fresh, overrides, world.strings, &newPrefab);
        rebuilt++;
    }
    if (rebuilt) info("Prefab hot-reload: rebuilt ", rebuilt, " instance(s)");
    return rebuilt;
}

private double jsonNum(ref const JSONValue v) {
    if (v.type == JSONType.float_) return v.floating;
    if (v.type == JSONType.integer) return cast(double) v.integer;
    if (v.type == JSONType.uinteger) return cast(double) v.uinteger;
    return 0.0;
}

unittest {
    import std.file : mkdirRecurse, rmdirRecurse;
    import engine.scene.scene_file : SceneEntityData, sceneNoParent;

    SceneWorld world;
    auto guid = AssetGuid.generate();

    // Existing unrelated entity in the world must survive additive prefab ops.
    auto bystander = world.spawn();
    world.set(bystander, Transform(Vec3(-50, 0, 0)));
    world.set(bystander, Name(world.strings.intern("Bystander")));

    // Multi-node prefab: root (1) -> child (2) -> grandchild (3)
    SceneFile pf;
    pf.meta.name = "TestVehiclePrefab";
    pf.strings = ["Chassis", "DoorFL", "Mirror"];
    SceneEntityData rootE;
    rootE.id = 1;
    rootE.hasName = true;
    rootE.name = 0;
    rootE.transform.pos = [0, 2, 0];
    rootE.visual.hasKind = true;
    rootE.visual.kind = "cube";

    SceneEntityData childE;
    childE.id = 2;
    childE.parent = 1;
    childE.hasName = true;
    childE.name = 1;
    childE.transform.pos = [1, 0, 0];

    SceneEntityData grandE;
    grandE.id = 3;
    grandE.parent = 2;
    grandE.hasName = true;
    grandE.name = 2;
    grandE.transform.pos = [0, 0.5f, 0];

    pf.entities = [rootE, childE, grandE];

    // 1. Additive instantiation preserves bystander
    auto liveId = instantiatePrefab(world, pf, world.strings, guid, Vec3(5, 0, 0));
    assert(liveId != EntityId.max);
    assert(world.alive(bystander));
    assert(world.entityCount() == 4);
    assert(world.get!Transform(liveId).position == Vec3(5, 2, 0));

    // 2. Override child transform and verify diffPrefabOverrides + applyPropertyOverrides
    auto subtree = collectSubtreeEntities(world, liveId);
    assert(subtree.length == 3);
    world.get!Transform(subtree[1]).position = Vec3(2, 0, 0);
    auto diffs = diffPrefabOverrides(world, liveId, pf, world.strings);
    assert(diffs.length == 1);
    assert(diffs[0].entityLocalId == 2);

    // 3. applyPrefabOverrides writes only the 3-entity subtree (not bystander)
    if (!exists("build/test_prefab")) mkdirRecurse("build/test_prefab");
    scope (exit) {
        if (exists("build/test_prefab")) rmdirRecurse("build/test_prefab");
    }
    immutable pfPath = "build/test_prefab/vehicle.prefab.json";
    applyPrefabOverrides(world, liveId, pfPath, world.strings);
    auto savedPf = loadPrefabFile(pfPath);
    assert(savedPf.entities.length == 3);
    assert(savedPf.entities[0].parent == sceneNoParent);
    assert(savedPf.entities[0].transform.pos == [0.0f, 2.0f, 0.0f]);
    assert(savedPf.entities[1].transform.pos == [2.0f, 0.0f, 0.0f]);

    // 4. revertPrefab destroys full child hierarchy (no orphaned children) and re-instantiates
    auto revertedId = revertPrefab(world, liveId, pf, world.strings);
    assert(revertedId != EntityId.max);
    assert(world.alive(bystander));
    assert(world.entityCount() == 4);
    auto revertedSub = collectSubtreeEntities(world, revertedId);
    assert(revertedSub.length == 3);
    assert(world.get!Transform(revertedSub[1]).position == Vec3(1, 0, 0));

    // Re-apply captured override to the reverted instance
    assert(applyPropertyOverrides(world, revertedId, diffs, world.strings));
    assert(world.get!Transform(revertedSub[1]).position == Vec3(2, 0, 0));
}

@("prefab.hotReloadKeepsInstanceOverrides") unittest {
    import engine.scene.scene_file : SceneEntityData;

    SceneWorld world;
    auto guid = AssetGuid.generate();
    auto otherGuid = AssetGuid.generate();

    SceneFile v1;
    v1.meta.name = "Lamp";
    v1.strings = ["Base", "Bulb"];
    SceneEntityData base;
    base.id = 1;
    base.hasName = true;
    base.name = 0;
    base.transform.pos = [0, 0, 0];
    SceneEntityData bulb;
    bulb.id = 2;
    bulb.parent = 1;
    bulb.hasName = true;
    bulb.name = 1;
    bulb.transform.pos = [0, 1, 0];
    bulb.transform.scale = [1, 1, 1];
    v1.entities = [base, bulb];

    auto parentEntity = world.spawn();
    world.set(parentEntity, Transform(Vec3(0, 0, 0)));
    auto a = instantiatePrefab(world, v1, world.strings, guid, Vec3(10, 0, 0));
    auto b = instantiatePrefab(world, v1, world.strings, guid, Vec3(20, 0, 0));
    auto unrelated = instantiatePrefab(world, v1, world.strings, otherGuid, Vec3(30, 0, 0));
    world.set(a, Parent(parentEntity));

    // Instance A overrides its root position; instance B is untouched.
    world.get!Transform(a).position = Vec3(11, 0, 0);

    // The prefab file changes: the bulb moves up and grows.
    SceneFile v2 = v1;
    v2.entities = v1.entities.dup;
    v2.entities[1].transform.pos = [0, 3, 0];
    v2.entities[1].transform.scale = [2, 2, 2];

    assert(reloadPrefabInstances(world, guid, v1, v2) == 2);

    EntityId[] roots;
    foreach (e; world.query!PrefabInstance())
        if (world.get!PrefabInstance(e).prefabGuid == guid) roots ~= e;
    assert(roots.length == 2);
    foreach (r; roots) {
        auto sub = collectSubtreeEntities(world, r);
        assert(sub.length == 2);
        assert(world.get!Transform(sub[1]).position == Vec3(0, 3, 0));
        assert(world.get!Transform(sub[1]).scale == Vec3(2, 2, 2));
        immutable rootPos = world.get!Transform(r).position;
        if (world.get!PrefabInstance(r).spawnOffset == Vec3(10, 0, 0)) {
            assert(rootPos == Vec3(11, 0, 0)); // per-instance override kept
            assert(world.has!Parent(r) && world.get!Parent(r).entity == parentEntity);
        } else {
            assert(rootPos == Vec3(20, 0, 0));
        }
    }
    // Instances of other prefabs are left alone.
    assert(world.alive(unrelated));
    assert(world.get!Transform(collectSubtreeEntities(world, unrelated)[1]).position == Vec3(0, 1, 0));
}

@("prefab: reload keeps every kind of override, with recycled ids, odd entity ids and deleted children")
unittest {
    import engine.reflect.attrs : entityRef;
    import engine.scene.scene_file : sceneNoParent;
    import std.json : parseJSON;

    @component static struct Gun { int ammo = 10; float spread = 1; @entityRef uint barrel = uint.max; }

    SceneFile v1;
    v1.strings = ["Tank", "Turret", "Wheel", "Antenna"];
    static SceneEntityData ent(uint id, uint parent, int name) {
        SceneEntityData e;
        e.id = id;
        e.parent = parent;
        e.hasName = true;
        e.name = name;
        return e;
    }
    auto root = ent(10, sceneNoParent, 0);
    root.hasPhysics = true;
    auto turret = ent(25, 10, 1);
    turret.customComponents ~= SceneComponentData("Gun", parseJSON(`{"ammo": 30, "barrel": 40}`));
    auto antenna = ent(40, 25, 3);          // depth first: not the breadth-first order
    auto wheel = ent(30, 10, 2);
    wheel.transform.pos = [0, 1, 0];
    v1.entities = [root, turret, antenna, wheel];

    SceneWorld w;
    w.ensureRegistered!Gun();
    EntityId[] holes;
    foreach (_; 0 .. 6) holes ~= w.spawn();
    foreach (h; holes) w.destroy(h); // recycled ids come back in reverse
    auto g = AssetGuid.generate();
    auto id = instantiatePrefab(w, v1, w.strings, g, Vec3(0, 0, 0));
    EntityId find(string name) {
        foreach (e; w.query!Name())
            if (w.strings.get(w.get!Name(e).id) == name) return e;
        return EntityId.max;
    }
    assert(w.get!Gun(find("Turret")).barrel == find("Antenna"));
    assert(diffPrefabOverrides(w, id, v1, w.strings).length == 0);

    w.set(id, Name(w.strings.intern("Boss")));
    auto pb = w.get!PhysicsBody(id);
    pb.mass = 50;
    pb.friction = 0.9f;
    w.set(id, pb);
    MaterialOverride mo;
    mo.active = true;
    mo.baseMetalness = 1;
    w.set(find("Wheel"), mo);
    auto gun = w.get!Gun(find("Turret"));
    gun.spread = 4;
    w.set(find("Turret"), gun);
    Light light;
    light.range = 33;
    w.set(find("Antenna"), light);
    w.get!Transform(find("Wheel")).position = Vec3(7, 1, 0);

    SceneFile v2 = v1;
    v2.entities = v1.entities.dup;
    v2.entities[1].customComponents = [SceneComponentData("Gun", parseJSON(`{"ammo": 99, "barrel": 40}`))];
    assert(reloadPrefabInstances(w, g, v1, v2) == 1);

    auto boss = find("Boss");
    assert(boss != EntityId.max && w.get!PhysicsBody(boss).mass == 50 && w.get!PhysicsBody(boss).friction == 0.9f);
    assert(w.get!MaterialOverride(find("Wheel")).baseMetalness == 1);
    assert(w.get!Transform(find("Wheel")).position == Vec3(7, 1, 0));
    assert(w.get!Light(find("Antenna")).range == 33);
    assert(w.get!Gun(find("Turret")) == Gun(99, 4, find("Antenna")));

    // Deleting a child must not hand its siblings' overrides to the wrong entity.
    w.destroy(find("Antenna"));
    w.destroy(find("Turret"));
    auto diffs = diffPrefabOverrides(w, boss, v2, w.strings);
    foreach (ref d; diffs)
        assert(d.entityLocalId == 10 || d.entityLocalId == 30);
    applyPropertyOverridesToSceneFile(v2, diffs, w.strings);
    assert(v2.strings[v2.entities[0].name] == "Boss" && v2.entities[0].physics.mass == 50);
    assert(v2.entities[3].material.baseMetalness == 1 && v2.entities[3].transform.pos == [7.0f, 1.0f, 0.0f]);
}
