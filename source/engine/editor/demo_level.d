/// Demo level shared by the editor and library tests: static floor, falling cube, game camera.
module engine.editor.demo_level;

import std.math : PI;

import engine.ecs.store : EntityId;
import engine.editor.components :
    Camera3D, MaterialOverride, Name, PhysicsBody, PhysicsMotion, PhysicsShapeKind,
    Visual, VisualKind, defaultHalfExtents, worldPosition;
import engine.editor.selection : Selection, noSelection;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;
import engine.scene.graph : Transform;

@safe:

/// GPU lens for the entity `Camera3D` on `id`. Looks along local -Z.
Camera sceneCameraToGpu(W)(ref W world, EntityId id, float viewW, float viewH) {
    Camera3D lens = Camera3D.init;
    Transform xform = Transform.init;
    if (world.alive(id)) {
        if (world.has!Camera3D(id))
            lens = world.get!Camera3D(id);
        if (world.has!Transform(id))
            xform = world.get!Transform(id);
    }
    float aspect = 16.0f / 9.0f;
    if (viewH > 1.0f)
        aspect = viewW / viewH;
    immutable fov = lens.fovYDeg * (cast(float) PI / 180.0f);
    Camera cam = Camera.create(fov, aspect, lens.nearPlane, lens.farPlane);
    immutable eye = world.alive(id) && world.has!Transform(id)
        ? worldPosition(world, id)
        : xform.position;
    immutable q = xform.rotation;
    cam.up = q.rotate(Vec3(0, 1, 0));
    cam.lookAt(eye, eye + q.rotate(Vec3(0, 0, -1)));
    return cam;
}

/// First `Camera3D` with `current != 0`, or `noSelection`.
EntityId findCurrentCamera(W)(ref W world) {
    foreach (e; world.query!Camera3D()) {
        if (!world.alive(e))
            continue;
        if (world.get!Camera3D(e).current != 0)
            return e;
    }
    return noSelection;
}

/// Clears the world and spawns Chão (static plane), Cubo (dynamic), and Câmera (current).
/// Selects the cube. Does not push undo commands.
void spawnDemoLevel(W)(ref W world, ref Selection selection) {
    world.clearEntities();
    selection.clear();

    {
        Transform t;
        t.position = Vec3(0, 0, 0);
        t.scale = Vec3(1, 1, 1);
        Visual vis;
        vis.kind = VisualKind.plane;
        vis.localHalfExtents = defaultHalfExtents(VisualKind.plane);
        MaterialOverride mat;
        mat.baseColor[0] = 0.35f;
        mat.baseColor[1] = 0.38f;
        mat.baseColor[2] = 0.34f;
        mat.baseColor[3] = 1;
        PhysicsBody body;
        body.enabled = 1;
        body.motion = PhysicsMotion.static_;
        body.shape = PhysicsShapeKind.primitive;
        body.halfExtents = vis.localHalfExtents;
        body.mass = 1;
        auto id = world.spawn();
        world.set(id, t);
        world.set(id, vis);
        world.set(id, mat);
        world.set(id, body);
        world.set(id, Name(world.strings.intern("Chão")));
    }
    EntityId cube;
    {
        Transform t;
        t.position = Vec3(0, 2, 0);
        t.scale = Vec3(1, 1, 1);
        Visual vis;
        vis.kind = VisualKind.cube;
        vis.localHalfExtents = defaultHalfExtents(VisualKind.cube);
        MaterialOverride mat;
        mat.baseColor[0] = 0.75f;
        mat.baseColor[1] = 0.45f;
        mat.baseColor[2] = 0.25f;
        mat.baseColor[3] = 1;
        PhysicsBody body;
        body.enabled = 1;
        body.motion = PhysicsMotion.dynamic_;
        body.shape = PhysicsShapeKind.primitive;
        body.halfExtents = vis.localHalfExtents;
        body.mass = 1;
        cube = world.spawn();
        world.set(cube, t);
        world.set(cube, vis);
        world.set(cube, mat);
        world.set(cube, body);
        world.set(cube, Name(world.strings.intern("Cubo")));
    }
    {
        Transform t;
        t.position = Vec3(0, 1.6f, 8);
        t.scale = Vec3(1, 1, 1);
        Visual vis;
        vis.kind = VisualKind.none;
        vis.localHalfExtents = Vec3(0.25f, 0.2f, 0.4f);
        Camera3D lens;
        lens.current = 1;
        lens.fovYDeg = 70;
        lens.nearPlane = 0.1f;
        lens.farPlane = 1000;
        auto id = world.spawn();
        world.set(id, t);
        world.set(id, vis);
        world.set(id, lens);
        world.set(id, Name(world.strings.intern("Câmera")));
    }

    selection.select(cube);
}

@safe unittest {
    import engine.ecs.scene_world : SceneWorld;
    import engine.editor.physics_sim : PhysicsSimSession;
    import engine.physics.world : PhysicsWorld;

    SceneWorld world;
    world.ensureRegistered!Camera3D();
    Selection selection;
    spawnDemoLevel(world, selection);
    assert(world.entityCount() == 3);

    int dynamics = 0;
    int statics = 0;
    bool groundPlane = false;
    bool cubeDynamic = false;
    foreach (e; world.query!PhysicsBody()) {
        if (!world.alive(e))
            continue;
        auto pb = world.get!PhysicsBody(e);
        if (pb.enabled == 0)
            continue;
        if (pb.motion == PhysicsMotion.dynamic_) {
            dynamics++;
            cubeDynamic = world.has!Visual(e)
                && world.get!Visual(e).kind == VisualKind.cube
                && world.get!Transform(e).position.y == 2.0f;
        } else if (pb.motion == PhysicsMotion.static_) {
            statics++;
            groundPlane = world.has!Visual(e)
                && world.get!Visual(e).kind == VisualKind.plane;
        }
    }
    assert(dynamics == 1);
    assert(statics == 1);
    assert(groundPlane);
    assert(cubeDynamic);

    immutable cam = findCurrentCamera(world);
    assert(cam != noSelection);
    assert(world.get!Camera3D(cam).current == 1);
    auto gpu = sceneCameraToGpu(world, cam, 160.0f, 90.0f);
    assert(gpu.position.x == 0 && gpu.position.y == 1.6f && gpu.position.z == 8);
    assert(gpu.target.z < gpu.position.z);
    assert(gpu.target.x == gpu.position.x);
    assert(gpu.target.y == gpu.position.y);

    PhysicsWorld physics = PhysicsWorld.createDefault();
    PhysicsSimSession sim;
    assert(sim.beginSimulate(world, physics));
    foreach (_; 0 .. 20)
        sim.tick(world, physics, 1.0f / 60.0f);
    bool fell = false;
    foreach (e; world.query!(Transform, PhysicsBody)()) {
        if (!world.alive(e))
            continue;
        auto pb = world.get!PhysicsBody(e);
        if (pb.motion == PhysicsMotion.dynamic_ && world.get!Transform(e).position.y < 2.0f)
            fell = true;
    }
    assert(fell);
    sim.stopSimulate(world);
}
