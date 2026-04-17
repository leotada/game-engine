// Integrator — exponential damping (Bullet btRigidBody::applyDamping), then
// v += (F / m + g) · dt. Position integration happens AFTER the solver in
// integrateTransforms.
module engine.physics.integrator;

import std.math : pow;
import engine.math.vec;
import engine.math.quat;

@safe:

/// Bullet's applyDamping: v *= pow(1 - damping, dt). For small damping this
/// is close to v *= (1 - damping*dt) but correct for large dt.
Vec3 applyLinearDamping(Vec3 v, float damping, float dt) {
    if (damping <= 0) return v;
    return v * cast(float) pow(1.0f - damping, dt);
}
Vec3 applyAngularDamping(Vec3 w, float damping, float dt) {
    if (damping <= 0) return w;
    return w * cast(float) pow(1.0f - damping, dt);
}

/// One step of velocity integration including gravity for dynamic bodies.
Vec3 integrateLinearVelocity(Vec3 v, Vec3 force, float invMass, Vec3 gravity, float dt) {
    if (invMass <= 0) return Vec3(0, 0, 0);
    return v + (force * invMass + gravity) * dt;
}

/// Euler quaternion integrate (already provided by Quat.integrate).
Quat integrateOrientation(Quat q, Vec3 omega, float dt) {
    return q.integrate(omega, dt);
}
