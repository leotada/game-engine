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
    SceneLoadOptions, collectSubtreeEntities, loadSceneAdditive, subtreeToSceneFile;
import engine.scene.graph : Transform;
import engine.scene.light : Light;
import engine.scene.scene_file : SceneEntityData, SceneFile, SceneMeta, loadSceneFile, saveSceneFile;
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
    immutable count = liveScene.entities.length < prefab.entities.length
        ? liveScene.entities.length : prefab.entities.length;

    void addOverride(uint localId, string comp, string field, JSONValue val) {
        overrides ~= PrefabPropertyOverride(
            localId, strings.intern(comp), strings.intern(field), val);
    }

    foreach (i; 0 .. count) {
        const liveE = liveScene.entities[i];
        const baseE = prefab.entities[i];
        immutable localId = baseE.id;

        if (liveE.transform.pos != baseE.transform.pos)
            addOverride(localId, "Transform", "pos", JSONValue(liveE.transform.pos[]));
        if (liveE.transform.rot != baseE.transform.rot)
            addOverride(localId, "Transform", "rot", JSONValue(liveE.transform.rot[]));
        if (liveE.transform.scale != baseE.transform.scale)
            addOverride(localId, "Transform", "scale", JSONValue(liveE.transform.scale[]));

        string liveName = liveE.hasName && liveE.name >= 0 && liveE.name < cast(int) liveScene.strings.length
            ? liveScene.strings[liveE.name] : "";
        string baseName = baseE.hasName && baseE.name >= 0 && baseE.name < cast(int) prefab.strings.length
            ? prefab.strings[baseE.name] : "";
        if (liveName != baseName)
            addOverride(localId, "Name", "name", JSONValue(liveName));

        if (liveE.hasMaterial != baseE.hasMaterial ||
            (liveE.hasMaterial && liveE.material.baseColor != baseE.material.baseColor)) {
            addOverride(localId, "MaterialOverride", "baseColor",
                JSONValue(liveE.material.baseColor[]));
        }
        if (liveE.hasMaterial && (!baseE.hasMaterial ||
            liveE.material.geometryOpacity != baseE.material.geometryOpacity)) {
            addOverride(localId, "MaterialOverride", "geometryOpacity",
                JSONValue(liveE.material.geometryOpacity));
        }

        if (liveE.hasLight && (!baseE.hasLight || liveE.light.intensity != baseE.light.intensity))
            addOverride(localId, "Light", "intensity", JSONValue(liveE.light.intensity));
        if (liveE.hasLight && (!baseE.hasLight || liveE.light.color != baseE.light.color))
            addOverride(localId, "Light", "color", JSONValue(liveE.light.color[]));

        if (liveE.hasPhysics && (!baseE.hasPhysics || liveE.physics.mass != baseE.physics.mass))
            addOverride(localId, "PhysicsBody", "mass", JSONValue(liveE.physics.mass));
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

        auto comp = strings.get(ov.componentName);
        auto field = strings.get(ov.fieldName);
        if (comp == "Transform") {
            if (field == "pos" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 3) {
                foreach (k; 0 .. 3)
                    target.transform.pos[k] = cast(float) jsonNum(ov.overrideValue.array[k]);
            } else if (field == "rot" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 4) {
                foreach (k; 0 .. 4)
                    target.transform.rot[k] = cast(float) jsonNum(ov.overrideValue.array[k]);
            } else if (field == "scale" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 3) {
                foreach (k; 0 .. 3)
                    target.transform.scale[k] = cast(float) jsonNum(ov.overrideValue.array[k]);
            }
        } else if (comp == "MaterialOverride") {
            target.hasMaterial = true;
            if (field == "baseColor" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 3) {
                foreach (k; 0 .. 3)
                    target.material.baseColor[k] = cast(float) jsonNum(ov.overrideValue.array[k]);
            } else if (field == "geometryOpacity") {
                target.material.geometryOpacity = cast(float) jsonNum(ov.overrideValue);
            }
        } else if (comp == "Light") {
            target.hasLight = true;
            if (field == "intensity") {
                target.light.intensity = cast(float) jsonNum(ov.overrideValue);
            } else if (field == "color" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 3) {
                foreach (k; 0 .. 3)
                    target.light.color[k] = cast(float) jsonNum(ov.overrideValue.array[k]);
            }
        } else if (comp == "PhysicsBody") {
            target.hasPhysics = true;
            if (field == "mass")
                target.physics.mass = cast(float) jsonNum(ov.overrideValue);
        }
    }
}

/// Apply `PrefabPropertyOverride` entries directly to a live prefab instance subtree.
bool applyPropertyOverrides(
    ref SceneWorld world,
    EntityId instanceRoot,
    scope const(PrefabPropertyOverride)[] overrides,
    ref StringTable strings
) @trusted {
    if (!world.alive(instanceRoot) || !world.has!PrefabInstance(instanceRoot))
        return false;

    auto subtree = collectSubtreeEntities(world, instanceRoot);
    foreach (ref const ov; overrides) {
        if (ov.entityLocalId == 0 || ov.entityLocalId > subtree.length)
            continue;
        immutable target = subtree[ov.entityLocalId - 1];
        if (!world.alive(target)) continue;

        auto comp = strings.get(ov.componentName);
        auto field = strings.get(ov.fieldName);
        if (comp == "Transform" && world.has!Transform(target)) {
            auto t = world.get!Transform(target);
            if (field == "pos" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 3) {
                t.position = Vec3(
                    cast(float) jsonNum(ov.overrideValue.array[0]),
                    cast(float) jsonNum(ov.overrideValue.array[1]),
                    cast(float) jsonNum(ov.overrideValue.array[2]));
                if (target == instanceRoot)
                    t.position = t.position + world.get!PrefabInstance(instanceRoot).spawnOffset;
            } else if (field == "rot" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 4) {
                t.rotation.x = cast(float) jsonNum(ov.overrideValue.array[0]);
                t.rotation.y = cast(float) jsonNum(ov.overrideValue.array[1]);
                t.rotation.z = cast(float) jsonNum(ov.overrideValue.array[2]);
                t.rotation.w = cast(float) jsonNum(ov.overrideValue.array[3]);
            } else if (field == "scale" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 3) {
                t.scale = Vec3(
                    cast(float) jsonNum(ov.overrideValue.array[0]),
                    cast(float) jsonNum(ov.overrideValue.array[1]),
                    cast(float) jsonNum(ov.overrideValue.array[2]));
            }
            world.set(target, t);
        } else if (comp == "MaterialOverride") {
            MaterialOverride mat;
            if (world.has!MaterialOverride(target))
                mat = world.get!MaterialOverride(target);
            if (field == "baseColor" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 3) {
                foreach (k; 0 .. 3)
                    mat.baseColor[k] = cast(float) jsonNum(ov.overrideValue.array[k]);
            } else if (field == "geometryOpacity") {
                mat.geometryOpacity = cast(float) jsonNum(ov.overrideValue);
            }
            world.set(target, mat);
        } else if (comp == "Light" && world.has!Light(target)) {
            auto l = world.get!Light(target);
            if (field == "intensity")
                l.intensity = cast(float) jsonNum(ov.overrideValue);
            else if (field == "color" && ov.overrideValue.type == JSONType.array && ov.overrideValue.array.length >= 3)
                foreach (k; 0 .. 3)
                    l.color[k] = cast(float) jsonNum(ov.overrideValue.array[k]);
            world.set(target, l);
        }
    }
    return true;
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
        applyPropertyOverrides(world, fresh, overrides, world.strings);
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
