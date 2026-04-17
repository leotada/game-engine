// 
module engine.physics.integrator;

import engine.math.vec;
import engine.math.quat;
import engine.math.mat3;

@safe:

// 
void integrateVelocities(
    scope Vec3[] velocity,
    scope Vec3[] angularVel,
    scope Vec3[] force,
    scope Vec3[] torque,
    scope const(Mat3)[] invInertiaWorld,
    scope const(float)[] invMass,
    Vec3 gravity,
    float dt,
) {
    immutable size_t n = velocity.length;
    foreach (i; 0 .. n) {
        if (invMass[i] > 0.0f) {
            velocity[i]   = velocity[i]   + (force[i]  * invMass[i] + gravity) * dt;
            angularVel[i] = angularVel[i] + (invInertiaWorld[i] * torque[i]) * dt;
        }
        force[i]  = Vec3(0, 0, 0);
        torque[i] = Vec3(0, 0, 0);
    }
}

void integratePositions(
    scope Vec3[] position,
    scope Quat[] orientation,
    scope const(Vec3)[] velocity,
    scope const(Vec3)[] angularVel,
    float dt,
) {
    immutable size_t n = position.length;
    foreach (i; 0 .. n) {
        position[i] = position[i] + velocity[i] * dt;
        orientation[i] = orientation[i].integrate(angularVel[i], dt);
    }
}
