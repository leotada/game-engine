/// Camera — perspective projection + view matrix for 3D scenes.
module engine.scene.camera;

import engine.math.mat;
import engine.math.vec;

pure nothrow @nogc @safe:

struct Camera {
    float fovY   = 0.9;
    float aspect = 16.0 / 9.0;
    float near   = 0.1;
    float far    = 100.0;

    Vec3 position = Vec3(0, 5, 10);
    Vec3 target   = Vec3(0, 0, 0);
    Vec3 up       = Vec3(0, 1, 0);

    static Camera create(float fovY, float aspect, float near = 0.1, float far = 100.0) {
        Camera c;
        c.fovY   = fovY;
        c.aspect = aspect;
        c.near   = near;
        c.far    = far;
        return c;
    }

    /// Convenience: compute aspect from integer width/height.
    static Camera create(float fovY, int width, int height, float near = 0.1, float far = 100.0) {
        return create(fovY, cast(float) width / cast(float) height, near, far);
    }

    void lookAt(Vec3 eye, Vec3 tgt) {
        position = eye;
        target   = tgt;
    }

    Mat4 viewProjection() const {
        return Mat4.perspective(fovY, aspect, near, far)
             * Mat4.lookAt(position, target, up);
    }
}
