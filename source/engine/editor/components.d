/// POD editor / scene components shared by the level editor and runtime.
///
/// Typical editor world:
/// ```
/// alias EditorWorld = World!(
///     Transform, Name, Parent, Visual, MaterialOverride, Light, PhysicsBody, Camera3D);
/// ```
module engine.editor.components;

import engine.core.handle : Handle;
import engine.core.pod : isPod;
import engine.core.strings : StringId;
import engine.ecs.store : EntityId;
import engine.ecs.world : World;
import engine.graphics.lod : selectLod;
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
import engine.reflect.attrs : component, export_, range;
import engine.scene.graph : Transform;
import engine.scene.light : Light;

@safe:

/// Sentinel parent: entity has no parent (scene root).
enum EntityId noParent = EntityId.max;

/// Display name (interned).
struct Name {
    StringId id = StringId.init;
}

static assert(isPod!Name);

/// ECS hierarchy link (optional). Missing `Parent` ≡ root.
struct Parent {
    EntityId entity = noParent;
}

static assert(isPod!Parent);

/// Phantom type for mesh / asset handles on `Visual`.
struct MeshAssetDomain {}

/// Visual primitive or mesh reference for editor picking / spawn.
enum VisualKind : uint {
    none   = 0,
    cube   = 1,
    sphere = 2,
    plane  = 3,
    mesh   = 4,
}

/// Renderable descriptor. Local AABB half-extents are in object space
/// before `Transform` scale (unit cube → half 0.5).
struct Visual {
    VisualKind kind = VisualKind.cube;
    Vec3 localHalfExtents = Vec3(0.5f, 0.5f, 0.5f);
    Handle!MeshAssetDomain mesh = Handle!MeshAssetDomain.init;
    uint materialSlot = 0;
    /// Interned `*.asset.json` path when `kind == mesh` (ED-7 scene refs).
    StringId assetPath = StringId.init;
}

static assert(isPod!Visual);

/// Optional OpenPBR Surface v1.1 override applied over the asset / default material.
struct MaterialOverride {
    float[3] baseColor = [1.0f, 1.0f, 1.0f];
    float    baseWeight = 1.0f;
    float    baseMetalness = 0.0f;
    float    baseDiffuseRoughness = 0.0f;
    float    specularWeight = 1.0f;
    float    specularRoughness = 0.5f;
    float[3] specularColor = [1.0f, 1.0f, 1.0f];
    float    specularIor = 1.5f;
    float    specularAnisotropy = 0.0f;
    float    coatWeight = 0.0f;
    float[3] coatColor = [1.0f, 1.0f, 1.0f];
    float    coatRoughness = 0.1f;
    float    coatIor = 1.6f;
    float    coatDarkening = 1.0f;
    float    fuzzWeight = 0.0f;
    float[3] fuzzColor = [1.0f, 1.0f, 1.0f];
    float    fuzzRoughness = 0.5f;
    float    thinFilmWeight = 0.0f;
    float    thinFilmThickness = 500.0f;
    float    thinFilmIor = 1.4f;
    float[3] emissionColor = [1.0f, 1.0f, 1.0f];
    float    emissionLuminance = 0.0f;
    float    geometryOpacity = 1.0f;
    float    anisotropyRotation = 0.0f;
    float    thinFilmThicknessMin = 300.0f;
    float[3] transmissionColor = [1.0f, 1.0f, 1.0f];
    float    transmissionWeight = 0.0f;
    float    transmissionDepth = 0.0f;
    float    transmissionDispersion = 0.0f;
    float    transmissionThickness = 0.0f;
    float    subsurfaceWeight = 0.0f;
    float[3] subsurfaceColor = [1.0f, 0.4f, 0.25f];
    float    subsurfaceRadius = 1.0f;
    float[3] subsurfaceRadiusScale = [1.0f, 0.35f, 0.15f];
    float    subsurfaceAnisotropy = 0.0f;
    uint     flags = 0;
    /// Non-zero → override contributes to the viewport material.
    uint     active = 1;
}

static assert(isPod!MaterialOverride);

/// Motion type for editor / scene physics (maps to Box3D body types).
enum PhysicsMotion : uint {
    static_   = 0,
    dynamic_  = 1,
    kinematic = 2,
}

/// Collider shape kind. `triangleMesh` is static-only (API + UI refuse dynamic).
enum PhysicsShapeKind : uint {
    primitive    = 0, /// Box/sphere from `Visual` + `halfExtents`
    convexHull   = 1, /// Baked hull points live on the referenced asset
    triangleMesh = 2, /// Static mesh collider from the asset
}

/// Result of `validatePhysicsBody` / shape+motion policy checks.
enum PhysicsValidation : uint {
    ok                   = 0,
    meshDynamicForbidden = 1,
}

/// Editor / scene physics component (ED-5). Runtime Box3D bodies are owned by
/// `PhysicsSimSession` — this POD only stores authoring data.
struct PhysicsBody {
    uint enabled = 0;
    uint motion = PhysicsMotion.static_;
    uint shape = PhysicsShapeKind.primitive;
    /// Primitive half-extents (object space, pre-scale). Also used as AABB fallback.
    Vec3 halfExtents = Vec3(0.5f, 0.5f, 0.5f);
    /// Mass hint; used as Box3D shape density for dynamic bodies.
    float mass = 1;
    float friction = 0.5f;
    float restitution = 0;
    float linearDamping = 0;
    float angularDamping = 0;
    /// Interned path to `*.asset.json` (hull points / collision mesh). Null = none.
    StringId assetPath = StringId.init;
    uint maxHullVertices = 64;
    /// Draw collider wireframe gizmos when non-zero.
    uint showCollider = 1;
}

static assert(isPod!PhysicsBody);

/// Backward-compatible alias (Stream F stub name).
alias PhysicsBodyStub = PhysicsBody;

static assert(isPod!Transform);
static assert(isPod!Light);

/// Game-view lens. Distinct from the GPU `engine.scene.camera.Camera`.
@component
struct Camera3D {
    /// Non-zero marks the camera used by Game / Play.
    @export_ uint current = 1;
    @export_ @range(10, 120) float fovYDeg = 70;
    @export_ float nearPlane = 0.1f;
    @export_ float farPlane = 1000.0f;
}

static assert(isPod!Camera3D);

/**
 * Per-entity LOD selector. `errors` are mesh-relative (simplifier output).
 * `meshScale` is `simplifyScale` of the shared vertex buffer.
 * `indexOffset` / `indexCount` address the concatenated LOD index buffer.
 * The frame loop only writes `current`; it does not simplify.
 */
struct MeshLod {
    ubyte levelCount;
    ubyte current;
    float[8] errors;
    float bias = 1;
    float meshScale = 1;
    uint[8] indexOffset;
    uint[8] indexCount;
}

static assert(isPod!MeshLod);

/// Index range for the selected color LOD.
void lodIndexRange(const(MeshLod) lod, out uint offset, out uint count) pure nothrow @nogc {
    if (lod.levelCount == 0) {
        offset = 0;
        count = 0;
        return;
    }
    ubyte i = lod.current < lod.levelCount ? lod.current : cast(ubyte)(lod.levelCount - 1);
    offset = lod.indexOffset[i];
    count = lod.indexCount[i];
}

/// Shadow range: one level coarser than `current`, clamped to the last LOD.
void lodShadowRange(const(MeshLod) lod, out uint offset, out uint count) pure nothrow @nogc {
    if (lod.levelCount == 0) {
        offset = 0;
        count = 0;
        return;
    }
    uint next = cast(uint) lod.current + 1;
    if (next >= lod.levelCount)
        next = lod.levelCount - 1;
    offset = lod.indexOffset[next];
    count = lod.indexCount[next];
}

/**
 * Pick the coarsest LOD whose projected error is under one pixel.
 * `error * meshScale * worldScale` is the world-space tolerance.
 * A 20% band keeps the previous level when the choice is on the boundary.
 */
void lodSelectSystem(W)(ref W world, Vec3 cameraPos, float fovYRadians, float screenHeight) nothrow @nogc {
    foreach (entity; world.query!(Transform, MeshLod)) {
        Transform xform = world.get!Transform(entity);
        ref MeshLod lod = world.get!MeshLod(entity);
        if (lod.levelCount == 0)
            continue;
        float worldScale = absF(xform.scale.x);
        float sy = absF(xform.scale.y);
        float sz = absF(xform.scale.z);
        if (sy > worldScale)
            worldScale = sy;
        if (sz > worldScale)
            worldScale = sz;
        Vec3 delta = Vec3(xform.position.x - cameraPos.x, xform.position.y - cameraPos.y, xform.position.z - cameraPos.z);
        immutable levels = lod.levelCount > 8 ? 8 : lod.levelCount;
        lod.current = selectLod(lod.errors[0 .. levels], lod.current, lod.meshScale, worldScale,
                                delta.length(), fovYRadians, screenHeight, lod.bias);
    }
}

private float absF(float v) pure nothrow @nogc {
    return v < 0 ? -v : v;
}

/// Default editor ECS registry (ED-1…ED-5).
alias EditorWorld = World!(
    Transform,
    Name,
    Parent,
    Visual,
    MaterialOverride,
    Light,
    PhysicsBody,
    Camera3D,
    MeshLod,
    ReflectionProbe
);

/// Maximum simultaneous local reflection probes bound per frame (`OPBR-9`).
enum uint MAX_REFLECTION_PROBES = 4;

/// Local parallax-corrected reflection probe (`OPBR-9`).
@component
struct ReflectionProbe {
    Vec3 position = Vec3(0.0f, 1.0f, 0.0f);
    @export_ @range(0.5f, 500.0f) float radius = 8.0f;
    @export_ Vec3 boxExtents = Vec3(8.0f, 4.0f, 8.0f);
    @export_ @range(0.0f, 50.0f) float blendDistance = 2.0f;
    @export_ @range(0.0f, 8.0f) float intensity = 1.0f;
    @export_ float[3] tint = [1.0f, 1.0f, 1.0f];
    @export_ uint boxProjection = 1;
    @export_ uint enabled = 1;
}

static assert(isPod!ReflectionProbe);

/// True when shape is triangle mesh and motion is dynamic (forbidden).
bool isMeshDynamicForbidden(uint shape, uint motion) pure nothrow @nogc {
    return shape == PhysicsShapeKind.triangleMesh && motion == PhysicsMotion.dynamic_;
}

bool isMeshDynamicForbidden(ref const PhysicsBody body) pure nothrow @nogc {
    return isMeshDynamicForbidden(body.shape, body.motion);
}

/// Policy check for authoring / spawn. Mesh + dynamic is always refused.
PhysicsValidation validatePhysicsBody(ref const PhysicsBody body) pure nothrow @nogc {
    if (isMeshDynamicForbidden(body))
        return PhysicsValidation.meshDynamicForbidden;
    return PhysicsValidation.ok;
}

/// Coerce an illegal mesh+dynamic combo to static mesh (UI fallback).
void refuseMeshDynamic(ref PhysicsBody body) pure nothrow @nogc {
    if (isMeshDynamicForbidden(body))
        body.motion = PhysicsMotion.static_;
}

// ---------------------------------------------------------------------------
// Hierarchy / world-matrix helpers
// ---------------------------------------------------------------------------

/// Walk `Parent` links and compose world matrix (local T*R*S).
Mat4 worldMatrix(W)(ref W world, EntityId id)
if (is(typeof(world.get!Transform(id))) && is(typeof(world.has!Parent(id))))
{
    Mat4 local = world.has!Transform(id)
        ? world.get!Transform(id).localMatrix()
        : Mat4.identity();

    if (!world.has!Parent(id))
        return local;

    immutable p = world.get!Parent(id).entity;
    if (p == noParent || p == id || !world.alive(p))
        return local;

    return worldMatrix(world, p) * local;
}

/// World-space translation of an entity (from composed matrix).
Vec3 worldPosition(W)(ref W world, EntityId id) {
    immutable m = worldMatrix(world, id);
    return Vec3(m.m[12], m.m[13], m.m[14]);
}

/// Local Transform, or identity if missing.
Transform localTransform(W)(ref W world, EntityId id) {
    if (world.has!Transform(id))
        return world.get!Transform(id);
    return Transform.init;
}

/// Default half-extents for a visual kind (unit primitives).
Vec3 defaultHalfExtents(VisualKind kind) {
    final switch (kind) {
        case VisualKind.none:   return Vec3(0.1f, 0.1f, 0.1f);
        case VisualKind.cube:   return Vec3(0.5f, 0.5f, 0.5f);
        case VisualKind.sphere: return Vec3(0.5f, 0.5f, 0.5f);
        case VisualKind.plane:  return Vec3(0.5f, 0.01f, 0.5f);
        case VisualKind.mesh:   return Vec3(0.5f, 0.5f, 0.5f);
    }
}

@("lodSelect.pixels") nothrow unittest {
    EditorWorld world;
    auto near = world.spawn();
    auto far = world.spawn();
    Transform close;
    close.position = Vec3(0, 0, 0);
    Transform distant;
    distant.position = Vec3(0, 0, 100);
    world.set(near, close);
    world.set(far, distant);
    MeshLod lod;
    lod.levelCount = 3;
    lod.errors[0 .. 3] = [0, 0.001f, 0.002f];
    lod.meshScale = 1;
    lod.bias = 1;
    lod.indexOffset[0 .. 3] = [0, 100, 160];
    lod.indexCount[0 .. 3] = [100, 60, 30];
    world.set(near, lod);
    world.set(far, lod);
    lodSelectSystem(world, Vec3(0, 0, 0), 1.0f, 1080);
    assert(world.get!MeshLod(near).current == 0);
    assert(world.get!MeshLod(far).current == 2);
    uint off, count;
    lodShadowRange(world.get!MeshLod(far), off, count);
    assert(off == 160 && count == 30);
    lodIndexRange(world.get!MeshLod(near), off, count);
    assert(off == 0 && count == 100);
}
