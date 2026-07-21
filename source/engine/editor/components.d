/// POD editor / scene components shared by the level editor and runtime.
///
/// Typical editor world:
/// ```
/// alias EditorWorld = World!(
///     Transform, Name, Parent, Visual, MaterialOverride, Light, PhysicsBody);
/// ```
module engine.editor.components;

import engine.core.handle : Handle;
import engine.core.pod : isPod;
import engine.core.strings : StringId;
import engine.ecs.store : EntityId;
import engine.ecs.world : World;
import engine.math.mat : Mat4;
import engine.math.quat : Quat;
import engine.math.vec : Vec3;
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

/// Optional PBR override applied over the asset / default material.
struct MaterialOverride {
    float[4] baseColor = [1, 1, 1, 1];
    float metallic = 0;
    float roughness = 0.5f;
    uint flags = 0;
    /// Non-zero → override contributes to the viewport material.
    uint active = 1;
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

/// Default editor ECS registry (ED-1…ED-5).
alias EditorWorld = World!(
    Transform,
    Name,
    Parent,
    Visual,
    MaterialOverride,
    Light,
    PhysicsBody
);

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
