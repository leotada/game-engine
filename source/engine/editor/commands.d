/// Editor commands: spawn / delete / duplicate / focus + undo stack base (ED-8).
module engine.editor.commands;

import engine.core.log : warn;
import engine.core.strings : StringId, StringTable;
import engine.editor.components :
    MaterialOverride, Name, Parent, PhysicsBody, Visual, VisualKind,
    defaultHalfExtents, noParent, worldPosition;
import engine.editor.light_panel :
    canSpawnAnyLight, canSpawnLightType, defaultLightForSpawn;
import engine.editor.selection : Selection, noSelection;
import engine.ecs.store : EntityId;
import engine.math.vec : Vec3;
import engine.scene.graph : Transform;
import engine.scene.light : Light;

@safe:

enum CommandKind : uint {
    none      = 0,
    spawn     = 1,
    delete_   = 2,
    duplicate = 3,
    setTransform = 4,
    setMaterial  = 5,
}

/// Snapshot of components needed to undo spawn/delete/duplicate.
struct EntitySnapshot {
    EntityId id = EntityId.max;
    Transform transform = Transform.init;
    Name name = Name.init;
    Parent parent = Parent(noParent);
    Visual visual = Visual.init;
    MaterialOverride material = MaterialOverride.init;
    Light light = Light.init;
    PhysicsBody physics = PhysicsBody.init;
    bool hasVisual;
    bool hasMaterial;
    bool hasLight;
    bool hasPhysics;
    bool hasParent;
    bool hasName;
}

EntitySnapshot captureEntity(W)(ref W world, EntityId id) nothrow @nogc {
    EntitySnapshot s;
    s.id = id;
    if (world.has!Transform(id)) s.transform = world.get!Transform(id);
    if (world.has!Name(id)) { s.name = world.get!Name(id); s.hasName = true; }
    if (world.has!Parent(id)) { s.parent = world.get!Parent(id); s.hasParent = true; }
    if (world.has!Visual(id)) { s.visual = world.get!Visual(id); s.hasVisual = true; }
    if (world.has!MaterialOverride(id)) {
        s.material = world.get!MaterialOverride(id);
        s.hasMaterial = true;
    }
    if (world.has!Light(id)) { s.light = world.get!Light(id); s.hasLight = true; }
    if (world.has!PhysicsBody(id)) {
        s.physics = world.get!PhysicsBody(id);
        s.hasPhysics = true;
    }
    return s;
}

void applySnapshotTo(W)(ref W world, EntityId id, ref const EntitySnapshot s) nothrow {
    Transform t = s.transform;
    world.set(id, t);
    if (s.hasName) {
        Name n = s.name;
        world.set(id, n);
    }
    if (s.hasParent) {
        Parent p = s.parent;
        world.set(id, p);
    }
    if (s.hasVisual) {
        Visual v = s.visual;
        world.set(id, v);
    }
    if (s.hasMaterial) {
        MaterialOverride m = s.material;
        world.set(id, m);
    }
    if (s.hasLight) {
        Light l = s.light;
        world.set(id, l);
    }
    if (s.hasPhysics) {
        PhysicsBody phy = s.physics;
        world.set(id, phy);
    }
}

struct CommandEntry {
    CommandKind kind = CommandKind.none;
    EntityId entity = EntityId.max;
    EntityId source = EntityId.max; /// Duplicate source / related.
    EntitySnapshot before;
    EntitySnapshot after;
    Transform xformBefore;
    Transform xformAfter;
    MaterialOverride matBefore;
    MaterialOverride matAfter;
}

/// Linear undo/redo stack (capacity fixed for ED-4; ED-8 may grow).
struct CommandStack {
    enum capacity = 64;
    CommandEntry[capacity] entries;
    int count = 0;   /// Valid entries in [0, count)
    int cursor = 0;  /// Next push index; undo moves cursor back.

    void clear() nothrow @nogc {
        count = 0;
        cursor = 0;
    }

    void push(CommandEntry e) nothrow @nogc {
        if (cursor < count) {
            // Drop redo tail
            count = cursor;
        }
        if (count >= capacity) {
            // Drop oldest
            foreach (i; 1 .. capacity)
                entries[i - 1] = entries[i];
            count = capacity - 1;
            cursor = count;
        }
        entries[cursor] = e;
        cursor++;
        count = cursor;
    }

    bool canUndo() const nothrow @nogc { return cursor > 0; }
    bool canRedo() const nothrow @nogc { return cursor < count; }

    bool undo(W)(ref W world, ref Selection sel) nothrow {
        if (!canUndo()) return false;
        cursor--;
        auto e = entries[cursor];
        final switch (e.kind) {
            case CommandKind.none:
                break;
            case CommandKind.spawn:
            case CommandKind.duplicate:
                if (world.alive(e.entity)) {
                    world.destroy(e.entity);
                    if (sel.isSelected(e.entity)) sel.clear();
                }
                break;
            case CommandKind.delete_:
                // Respawn from snapshot; id may differ — update entry for redo.
                {
                    auto id = world.spawn();
                    applySnapshotTo(world, id, e.before);
                    entries[cursor].entity = id;
                    sel.select(id);
                }
                break;
            case CommandKind.setTransform:
                if (world.alive(e.entity)) {
                    world.set(e.entity, e.xformBefore);
                    sel.select(e.entity);
                }
                break;
            case CommandKind.setMaterial:
                if (world.alive(e.entity)) {
                    world.set(e.entity, e.matBefore);
                    sel.select(e.entity);
                }
                break;
        }
        return true;
    }

    bool redo(W)(ref W world, ref Selection sel) nothrow {
        if (!canRedo()) return false;
        auto e = entries[cursor];
        final switch (e.kind) {
            case CommandKind.none:
                break;
            case CommandKind.spawn:
            case CommandKind.duplicate:
                {
                    auto id = world.spawn();
                    applySnapshotTo(world, id, e.after);
                    entries[cursor].entity = id;
                    sel.select(id);
                }
                break;
            case CommandKind.delete_:
                if (world.alive(e.entity)) {
                    world.destroy(e.entity);
                    if (sel.isSelected(e.entity)) sel.clear();
                }
                break;
            case CommandKind.setTransform:
                if (world.alive(e.entity)) {
                    world.set(e.entity, e.xformAfter);
                    sel.select(e.entity);
                }
                break;
            case CommandKind.setMaterial:
                if (world.alive(e.entity)) {
                    world.set(e.entity, e.matAfter);
                    sel.select(e.entity);
                }
                break;
        }
        cursor++;
        return true;
    }
}

// ---------------------------------------------------------------------------
// High-level ops
// ---------------------------------------------------------------------------

/// Spawn a visual primitive (cube/sphere/plane) with default material override.
EntityId spawnPrimitive(
    W
)(
    ref W world,
    ref CommandStack stack,
    ref Selection sel,
    VisualKind kind,
    Transform transform = Transform.init,
    StringId name = StringId.init
) {
    Visual vis;
    vis.kind = kind;
    vis.localHalfExtents = defaultHalfExtents(kind);

    auto id = world.spawn();
    world.set(id, transform);
    world.set(id, vis);
    world.set(id, MaterialOverride.init);
    if (!name.isNull)
        world.set(id, Name(name));

    CommandEntry cmd;
    cmd.kind = CommandKind.spawn;
    cmd.entity = id;
    cmd.after = captureEntity(world, id);
    stack.push(cmd);
    sel.select(id);
    return id;
}

/// Spawn a dedicated Light entity (`Transform` + `Light`, no Visual).
/// Returns `noSelection` and does not mutate the world when the UBO budget
/// for `light.type` is full.
EntityId spawnLightEntity(
    W
)(
    ref W world,
    ref CommandStack stack,
    ref Selection sel,
    Light light = Light.init,
    Transform transform = Transform.init,
    StringId name = StringId.init
) {
    if (!canSpawnLightType(world, light.type)) {
        warn("spawnLightEntity blocked: UBO light budget full for that type");
        return noSelection;
    }

    auto id = world.spawn();
    world.set(id, transform);
    world.set(id, light);
    if (!name.isNull)
        world.set(id, Name(name));

    CommandEntry cmd;
    cmd.kind = CommandKind.spawn;
    cmd.entity = id;
    cmd.after = captureEntity(world, id);
    stack.push(cmd);
    sel.select(id);
    return id;
}

/// Spawn a Light with an auto-picked type that fits the remaining UBO budget.
/// Returns `noSelection` when every light slot is full.
EntityId spawnDefaultLightEntity(
    W
)(
    ref W world,
    ref CommandStack stack,
    ref Selection sel,
    Transform transform = Transform.init,
    StringId name = StringId.init
) {
    if (!canSpawnAnyLight(world)) {
        warn("spawnDefaultLightEntity blocked: all UBO light slots full");
        return noSelection;
    }
    return spawnLightEntity(world, stack, sel, defaultLightForSpawn(world), transform, name);
}

/// Delete selected entity (records snapshot for undo).
bool deleteEntity(W)(ref W world, ref CommandStack stack, ref Selection sel, EntityId id) {
    if (id == noSelection || !world.alive(id)) return false;

    CommandEntry cmd;
    cmd.kind = CommandKind.delete_;
    cmd.entity = id;
    cmd.before = captureEntity(world, id);
    stack.push(cmd);

    world.destroy(id);
    if (sel.isSelected(id)) {
        // Rebuild selection without this id
        Selection next;
        foreach (i; 0 .. sel.count) {
            if (sel.ids[i] != id)
                next.add(sel.ids[i]);
        }
        sel = next;
    }
    return true;
}

/// Delete every entity in the current selection (each gets its own undo entry).
int deleteSelected(W)(ref W world, ref CommandStack stack, ref Selection sel) {
    // Copy ids — selection mutates as we delete
    EntityId[Selection.capacity] copy;
    immutable n = sel.count;
    foreach (i; 0 .. n) copy[i] = sel.ids[i];
    int deleted = 0;
    foreach (i; 0 .. n) {
        if (deleteEntity(world, stack, sel, copy[i]))
            deleted++;
    }
    return deleted;
}

/// Duplicate entity (copies known editor components; offsets position slightly).
EntityId duplicateEntity(W)(
    ref W world,
    ref CommandStack stack,
    ref Selection sel,
    EntityId source,
    Vec3 offset = Vec3(0.5f, 0, 0.5f)
) {
    if (source == noSelection || !world.alive(source)) return noSelection;

    auto snap = captureEntity(world, source);
    if (snap.hasLight && !canSpawnLightType(world, snap.light.type)) {
        warn("duplicateEntity blocked: UBO light budget full for that type");
        return noSelection;
    }
    snap.transform.position = snap.transform.position + offset;

    auto id = world.spawn();
    applySnapshotTo(world, id, snap);

    CommandEntry cmd;
    cmd.kind = CommandKind.duplicate;
    cmd.entity = id;
    cmd.source = source;
    cmd.after = captureEntity(world, id);
    stack.push(cmd);
    sel.select(id);
    return id;
}

/// Duplicate all selected entities; selection becomes the new copies.
int duplicateSelected(W)(
    ref W world,
    ref CommandStack stack,
    ref Selection sel,
    Vec3 offset = Vec3(0.5f, 0, 0.5f)
) {
    EntityId[Selection.capacity] sources;
    immutable n = sel.count;
    foreach (i; 0 .. n) sources[i] = sel.ids[i];

    Selection created;
    foreach (i; 0 .. n) {
        // Temporarily select source so duplicateEntity can run; then collect
        Selection tmp;
        tmp.select(sources[i]);
        auto id = duplicateEntity(world, stack, tmp, sources[i], offset);
        if (id != noSelection)
            created.add(id);
    }
    if (!created.empty)
        sel = created;
    return created.count;
}

/// World-space point to frame the camera on (caller moves camera).
Vec3 focusPoint(W)(ref W world, EntityId id) {
    if (id == noSelection || !world.alive(id))
        return Vec3(0, 0, 0);
    return worldPosition(world, id);
}

/// Drop selected visuals so their world AABB bottom rests on Y=0 (align ground).
int alignSelectedToGround(W)(ref W world, ref CommandStack stack, ref Selection sel) {
    import engine.editor.picking : entityWorldAabb;

    int n = 0;
    foreach (i; 0 .. sel.count) {
        immutable id = sel.ids[i];
        if (!world.alive(id) || !world.has!Transform(id)) continue;
        immutable before = world.get!Transform(id);
        immutable box = entityWorldAabb(world, id);
        immutable dy = -box.min.y;
        if (dy == 0) continue;
        Transform after = before;
        after.position.y = before.position.y + dy;
        world.set(id, after);
        recordTransform(stack, id, before, after);
        n++;
    }
    return n;
}

/// Copy MaterialOverride (+ optional PhysicsBody) from primary onto other selected.
int copyAttrsFromPrimary(W)(ref W world, ref CommandStack stack, ref Selection sel) {
    if (sel.empty || sel.count < 2) return 0;
    immutable src = sel.primary;
    if (!world.alive(src)) return 0;

    MaterialOverride matSrc = MaterialOverride.init;
    bool hasMat = world.has!MaterialOverride(src);
    if (hasMat) matSrc = world.get!MaterialOverride(src);

    PhysicsBody phySrc = PhysicsBody.init;
    bool hasPhy = world.has!PhysicsBody(src);
    if (hasPhy) phySrc = world.get!PhysicsBody(src);

    int n = 0;
    foreach (i; 0 .. sel.count) {
        immutable id = sel.ids[i];
        if (id == src || !world.alive(id)) continue;
        if (hasMat) {
            MaterialOverride before = world.has!MaterialOverride(id)
                ? world.get!MaterialOverride(id) : MaterialOverride.init;
            world.set(id, matSrc);
            recordMaterial(stack, id, before, matSrc);
            n++;
        }
        if (hasPhy) {
            world.set(id, phySrc);
            n++;
        }
    }
    return n;
}

/// Record undo entries for a finished gizmo drag (multi-entity).
void recordGizmoDrag(W)(
    ref CommandStack stack,
    ref W world,
    scope const(EntityId)[] ids,
    scope const(Transform)[] starts
) nothrow @nogc {
    immutable n = ids.length < starts.length ? ids.length : starts.length;
    foreach (i; 0 .. n) {
        immutable id = ids[i];
        if (id == noSelection || !world.alive(id) || !world.has!Transform(id))
            continue;
        immutable after = world.get!Transform(id);
        if (after.position.x == starts[i].position.x
            && after.position.y == starts[i].position.y
            && after.position.z == starts[i].position.z
            && after.scale.x == starts[i].scale.x
            && after.scale.y == starts[i].scale.y
            && after.scale.z == starts[i].scale.z)
        {
            // Still record rotation changes
            immutable qb = starts[i].rotation;
            immutable qa = after.rotation;
            if (qb.x == qa.x && qb.y == qa.y && qb.z == qa.z && qb.w == qa.w)
                continue;
        }
        recordTransform(stack, id, starts[i], after);
    }
}

/// Record a transform change for undo (call after inspector / gizmo commit).
void recordTransform(ref CommandStack stack, EntityId id, Transform before, Transform after) nothrow @nogc {
    if (id == noSelection) return;
    CommandEntry cmd;
    cmd.kind = CommandKind.setTransform;
    cmd.entity = id;
    cmd.xformBefore = before;
    cmd.xformAfter = after;
    stack.push(cmd);
}

/// Record a material override change for undo.
void recordMaterial(
    ref CommandStack stack,
    EntityId id,
    MaterialOverride before,
    MaterialOverride after
) nothrow @nogc {
    if (id == noSelection) return;
    CommandEntry cmd;
    cmd.kind = CommandKind.setMaterial;
    cmd.entity = id;
    cmd.matBefore = before;
    cmd.matAfter = after;
    stack.push(cmd);
}

/// Intern a default name like "Cube" / "Light" via the world string table.
StringId defaultNameFor(ref StringTable strings, VisualKind kind) {
    final switch (kind) {
        case VisualKind.none:   return strings.intern("Entity");
        case VisualKind.cube:   return strings.intern("Cube");
        case VisualKind.sphere: return strings.intern("Sphere");
        case VisualKind.plane:  return strings.intern("Plane");
        case VisualKind.mesh:   return strings.intern("Mesh");
    }
}

StringId defaultLightName(ref StringTable strings) {
    return strings.intern("Light");
}

@safe unittest {
    import engine.editor.components : EditorWorld;
    import engine.editor.picking : pickClosestAabb;
    import engine.math.ray : Ray;

    EditorWorld world;
    CommandStack stack;
    Selection sel;

    auto a = spawnPrimitive(world, stack, sel, VisualKind.cube);
    assert(world.alive(a));
    assert(sel.isSelected(a));
    assert(stack.canUndo());

    // AABB pick along +Z toward origin cube
    auto hit = pickClosestAabb(world, Ray(Vec3(0, 0.5f, -5), Vec3(0, 0, 1)));
    assert(hit.hit);
    assert(hit.entity == a);

    // Material roughness override
    auto mat = world.get!MaterialOverride(a);
    mat.roughness = 0.2f;
    world.set(a, mat);
    assert(world.get!MaterialOverride(a).roughness == 0.2f);

    auto b = duplicateEntity(world, stack, sel, a);
    assert(world.alive(b));
    assert(b != a);

    deleteEntity(world, stack, sel, b);
    assert(!world.alive(b));

    assert(stack.undo(world, sel)); // restore b
    assert(sel.primary != noSelection);

    // Multi-select + align ground
    sel.select(a);
    sel.add(b);
    Transform ta = world.get!Transform(a);
    ta.position.y = 3;
    world.set(a, ta);
    assert(alignSelectedToGround(world, stack, sel) >= 1);
}
