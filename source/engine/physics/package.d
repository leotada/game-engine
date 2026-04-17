// Physics package re-export.
//
// The legacy Bullet-inspired engine (PhysicsWorld + SoA arrays) is the
// implementation. On top of it the Jolt-style facade (PhysicsSystem +
// BodyInterface + NarrowPhaseQuery + BodyCreationSettings + BodyID) is
// provided for new code and for porting samples from ref/JoltPhysics.
module engine.physics;

// Legacy / implementation types (still the public API PhysicsWorld uses).
public import engine.physics.types;
public import engine.physics.inertia;
public import engine.physics.dbvt;
public import engine.physics.narrowphase;
public import engine.physics.manifold_pool;
public import engine.physics.islands;
public import engine.physics.integrator;
public import engine.physics.solver;
public import engine.physics.world;

// Jolt-style facade.
public import engine.physics.body_id;
public import engine.physics.motion_type;
public import engine.physics.body_creation_settings;
public import engine.physics.ray_cast;
public import engine.physics.narrow_phase_query;
public import engine.physics.body_interface;
public import engine.physics.system;
