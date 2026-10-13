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
import engine.scene.graph : Transform;
import engine.scene.scene_file : SceneFile, loadSceneFile, saveSceneFile;
import engine.editor.scene_load : loadSceneIntoWorld, worldToSceneFile;
import engine.editor.light_panel : SceneLightSettings;
import engine.core.log : info, warn, err;

@safe:

/// Attached to entities that originate from a prefab asset.
@component struct PrefabInstance {
    AssetGuid prefabGuid;
    uint sourceRoot = 0;
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

/// Instantiates a prefab into the world, attaching PrefabInstance to the root.
EntityId instantiatePrefab(
    ref SceneWorld world,
    ref const SceneFile prefab,
    ref StringTable strings,
    AssetGuid prefabGuid = AssetGuid.init,
    Vec3 offsetPosition = Vec3(0, 0, 0)
) @trusted {
    SceneLightSettings dummySettings;
    SceneFile copy = cast(SceneFile) prefab;

    // Load entities into world
    auto res = loadSceneIntoWorld(world, copy, dummySettings);
    if (copy.entities.length == 0) return EntityId.max;

    auto rootFileId = copy.entities[0].id;
    if (auto p = rootFileId in res.fileIdToEntity) {
        auto liveId = *p;

        // Apply offset
        if (world.has!Transform(liveId)) {
            auto t = world.get!Transform(liveId);
            t.position = t.position + offsetPosition;
            world.set(liveId, t);
        }

        // Attach PrefabInstance
        world.set(liveId, PrefabInstance(prefabGuid, rootFileId));
        return liveId;
    }

    return EntityId.max;
}

/// Reverts a prefab instance back to the prefab's original state.
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
    Transform currentXform;
    if (world.has!Transform(instanceRoot)) {
        currentXform = world.get!Transform(instanceRoot);
    }

    world.destroy(instanceRoot);
    auto id = instantiatePrefab(world, prefab, strings, inst.prefabGuid, currentXform.position);
    info("Prefab revertido");
    return id;
}

/// Applies changes made on the instance back to the prefab definition file.
void applyPrefabOverrides(
    ref SceneWorld world,
    EntityId instanceRoot,
    string prefabPath,
    ref StringTable strings
) @trusted {
    if (!world.alive(instanceRoot) || !world.has!PrefabInstance(instanceRoot)) return;

    SceneLightSettings dummySettings;
    auto updated = worldToSceneFile(world, dummySettings);
    savePrefabFile(prefabPath, updated);
    info("Applied prefab overrides from instance %d to %s", instanceRoot, prefabPath);
}

unittest {
    import engine.scene.scene_file : SceneEntityData;
    import engine.editor.components : VisualKind;

    SceneWorld world;
    auto guid = AssetGuid.generate();

    SceneFile pf;
    pf.meta.name = "TestCubePrefab";
    auto entityData = SceneEntityData();
    entityData.id = 1;
    entityData.transform.pos = [0, 2, 0];
    entityData.visual.hasKind = true;
    entityData.visual.kind = "cube";
    pf.entities ~= entityData;

    // Instantiate prefab
    auto liveId = instantiatePrefab(world, pf, world.strings, guid, Vec3(5, 0, 0));
    assert(liveId != EntityId.max);
    assert(world.alive(liveId));
    assert(world.has!PrefabInstance(liveId));
    assert(world.get!PrefabInstance(liveId).prefabGuid == guid);
    assert(world.has!Transform(liveId));
    assert(world.get!Transform(liveId).position == Vec3(5, 2, 0));

    // Override field on instance
    world.get!Transform(liveId).position = Vec3(10, 2, 0);
    assert(world.get!Transform(liveId).position == Vec3(10, 2, 0));

    // Revert prefab
    revertPrefab(world, liveId, pf, world.strings);
    auto allEntities = world.query!PrefabInstance();
    EntityId revertedId = EntityId.max;
    foreach (e; allEntities) {
        revertedId = e;
        break;
    }
    assert(revertedId != EntityId.max);
    assert(world.has!Transform(revertedId));
}
