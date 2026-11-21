/// Cascaded shadow map (CSM) math: practical split scheme (PSSM) and
/// rotation-stable, texel-snapped orthographic fitting for a directional
/// light. Pure CPU code, `@nogc`, no GPU state.
///
/// The cascades are fitted around a bounding sphere of each camera
/// sub-frustum, so the cascade size does not change when the camera rotates,
/// and the light-space origin is snapped to whole shadow-map texels so the
/// shadow edges do not shimmer when the camera translates.
module engine.scene.cascades;

import std.math : ceil, floor, pow, sqrt, tan;

import engine.math.mat : Mat4;
import engine.math.vec : Vec3;
import engine.scene.camera : Camera;

@safe:

/// Maximum number of directional shadow cascades (shadow-map array layers).
enum uint MAX_CASCADES = 4;

/// Directional-light cascade configuration (POD). `count = 0` disables CSM:
/// the engine then uses the caller-supplied `GpuDirLight.viewProj` as one
/// fixed shadow map (legacy behaviour).
struct CascadeSettings {
    /// Number of cascades, `0..MAX_CASCADES`.
    uint count = 4;
    /// Blend between uniform (0) and logarithmic (1) split distribution.
    float lambda = 0.75f;
    /// Shadows end at this view distance (clamped to the camera far plane).
    float maxDistance = 400.0f;
    /// Fraction of each cascade used to cross-fade into the next one.
    float blendFraction = 0.1f;
    /// Extra distance toward the light so casters outside the view still cast.
    float casterMargin = 250.0f;
    /// Shadow-map resolution of every cascade layer.
    uint resolution = 2048;
}

/// Fitted cascades for one frame.
struct CascadeSet {
    uint count;
    Mat4[MAX_CASCADES] viewProj;
    /// View-depth (distance along the camera forward axis) where each cascade ends.
    float[MAX_CASCADES] splitFar = 0;
    /// World size of one shadow-map texel per cascade.
    float[MAX_CASCADES] texelWorld = 0;
    /// Light-space depth range of each cascade (ortho far − near), world units.
    float[MAX_CASCADES] depthRange = 0;
    /// Distance where shadows start fading out / are fully faded.
    float fadeStart = 0, fadeEnd = 0;
}

pure nothrow @nogc:

/// Practical split scheme: `lambda` blends logarithmic and uniform splits.
/// Writes the far distance of each of the `count` cascades into `outFar`.
void computeCascadeSplits(float near, float far, uint count, float lambda,
                          scope float[] outFar) {
    assert(outFar.length >= count);
    if (near < 1e-3f) near = 1e-3f;
    if (far <= near) far = near + 1.0f;
    foreach (i; 0 .. count) {
        immutable p = cast(float)(i + 1) / cast(float) count;
        immutable logD = near * pow(far / near, p);
        immutable uniD = near + (far - near) * p;
        outFar[i] = lambda * logD + (1.0f - lambda) * uniD;
    }
    outFar[count - 1] = far;
}

/// Orthonormal light basis (right, up) for a light travelling along `-lightDir`.
void lightBasis(Vec3 lightDir, out Vec3 right, out Vec3 up) {
    immutable f = (lightDir * -1.0f).normalized();
    immutable worldUp = (f.y > 0.9f || f.y < -0.9f) ? Vec3(0, 0, 1) : Vec3(0, 1, 0);
    right = f.cross(worldUp).normalized();
    up = right.cross(f);
}

/// Bounding sphere of the camera sub-frustum `[splitNear, splitFar]`.
/// The radius is rounded up to 1/16 m so it is stable frame to frame.
void subFrustumSphere(Vec3 camPos, Vec3 fwd, Vec3 right, Vec3 up,
                      float tanHalfFovY, float aspect,
                      float splitNear, float splitFar,
                      out Vec3 center, out float radius) {
    Vec3[8] corners;
    foreach (k, d; [splitNear, splitFar]) {
        immutable h = d * tanHalfFovY;
        immutable w = h * aspect;
        immutable c = camPos + fwd * d;
        corners[k * 4 + 0] = c + right * w + up * h;
        corners[k * 4 + 1] = c - right * w + up * h;
        corners[k * 4 + 2] = c + right * w - up * h;
        corners[k * 4 + 3] = c - right * w - up * h;
    }
    // Sphere center on the view axis that minimises the max corner distance:
    // for a symmetric frustum slice the optimum lies on the axis at depth z*.
    immutable hn2 = (splitNear * tanHalfFovY) ^^ 2 * (1.0f + aspect * aspect);
    immutable hf2 = (splitFar * tanHalfFovY) ^^ 2 * (1.0f + aspect * aspect);
    float z = 0.5f * (splitNear + splitFar) + (hf2 - hn2) / (2.0f * (splitFar - splitNear));
    if (z > splitFar) z = splitFar;
    if (z < splitNear) z = splitNear;
    center = camPos + fwd * z;
    float r2 = 0;
    foreach (ref c; corners) {
        immutable d2 = (c - center).lengthSquared();
        if (d2 > r2) r2 = d2;
    }
    radius = ceil(sqrt(r2) * 16.0f) / 16.0f;
}

/// Ortho light view-projection for a sphere `(center, radius)`, with the
/// center snapped to whole texels of a `resolution`² map.
Mat4 fitSphereOrtho(Vec3 center, float radius, Vec3 lightDir, uint resolution,
                    float casterMargin, out float texelWorld, out float depthRange) {
    Vec3 right, up;
    lightBasis(lightDir, right, up);
    immutable L = lightDir.normalized();
    texelWorld = (2.0f * radius) / cast(float) resolution;
    // Snap the center's light-space x/y to the texel grid.
    immutable cx = right.dot(center), cy = up.dot(center);
    immutable sx = floor(cx / texelWorld) * texelWorld;
    immutable sy = floor(cy / texelWorld) * texelWorld;
    immutable snapped = center + right * (sx - cx) + up * (sy - cy);

    immutable back = radius + casterMargin;
    immutable eye = snapped + L * back;
    immutable view = Mat4.lookAt(eye, snapped, up);
    depthRange = back + radius;
    immutable proj = Mat4.ortho(-radius, radius, -radius, radius, 0.0f, depthRange);
    return proj * view;
}

/// Fit `settings.count` cascades for `camera` and a light whose surface→light
/// direction is `lightDir`.
CascadeSet buildCascades(ref const Camera camera, Vec3 lightDir, ref const CascadeSettings settings) {
    CascadeSet set;
    uint n = settings.count;
    if (n > MAX_CASCADES) n = MAX_CASCADES;
    if (n == 0) return set;
    set.count = n;

    immutable fwd = (camera.target - camera.position).normalized();
    immutable worldUp = (fwd.y > 0.99f || fwd.y < -0.99f) ? Vec3(0, 0, 1) : camera.up;
    immutable right = fwd.cross(worldUp).normalized();
    immutable up = right.cross(fwd);
    immutable tanHalf = tan(camera.fovY * 0.5f);

    float maxD = settings.maxDistance > 0 ? settings.maxDistance : camera.far;
    if (maxD > camera.far) maxD = camera.far;
    computeCascadeSplits(camera.near, maxD, n, settings.lambda, set.splitFar[]);

    immutable res = settings.resolution ? settings.resolution : 2048;
    float prev = camera.near;
    foreach (i; 0 .. n) {
        // Overlap the previous cascade by the blend band so cross-fading has data.
        immutable blendBand = (set.splitFar[i] - prev) * settings.blendFraction;
        immutable start = (prev - blendBand) > camera.near ? prev - blendBand : camera.near;
        Vec3 c;
        float r;
        subFrustumSphere(camera.position, fwd, right, up, tanHalf, camera.aspect,
                         start, set.splitFar[i], c, r);
        set.viewProj[i] = fitSphereOrtho(c, r, lightDir, res, settings.casterMargin,
                                         set.texelWorld[i], set.depthRange[i]);
        prev = set.splitFar[i];
    }
    immutable last = set.splitFar[n - 1];
    set.fadeEnd = last;
    set.fadeStart = last - (last - (n > 1 ? set.splitFar[n - 2] : camera.near)) * 0.2f;
    return set;
}

unittest {
    float[4] s;
    computeCascadeSplits(0.1f, 400.0f, 4, 0.75f, s[]);
    foreach (i; 1 .. 4) assert(s[i] > s[i - 1]);
    assert(s[3] == 400.0f);
    // lambda = 0 is uniform.
    computeCascadeSplits(0.0f + 1.0f, 101.0f, 4, 0.0f, s[]);
    assert(s[0] > 25.9f && s[0] < 26.1f);
}

unittest {
    // Every sub-frustum corner lies inside its fitted sphere.
    Camera cam = Camera.create(0.9f, 16.0f / 9.0f, 0.1f, 1000.0f);
    cam.position = Vec3(10, 5, -3);
    cam.target = Vec3(40, 2, 30);
    CascadeSettings cs;
    auto set = buildCascades(cam, Vec3(0.3f, 1.0f, 0.2f), cs);
    assert(set.count == 4);
    immutable fwd = (cam.target - cam.position).normalized();
    immutable right = fwd.cross(Vec3(0, 1, 0)).normalized();
    immutable up = right.cross(fwd);
    immutable tanHalf = tan(cam.fovY * 0.5f);
    float prev = cam.near;
    foreach (i; 0 .. set.count) {
        foreach (d; [prev, set.splitFar[i]]) {
            immutable h = d * tanHalf, w = h * cam.aspect;
            foreach (sx; [-1.0f, 1.0f]) foreach (sy; [-1.0f, 1.0f]) {
                immutable p = cam.position + fwd * d + right * (w * sx) + up * (h * sy);
                import engine.math.vec : Vec4;
                immutable clip = set.viewProj[i] * Vec4(p.x, p.y, p.z, 1.0f);
                assert(clip.x >= -1.001f && clip.x <= 1.001f);
                assert(clip.y >= -1.001f && clip.y <= 1.001f);
                assert(clip.z >= 0.0f && clip.z <= 1.0f);
            }
        }
        prev = set.splitFar[i];
    }
}

unittest {
    // Sub-texel camera translation keeps the snapped projection identical.
    Camera cam = Camera.create(0.9f, 1.5f, 0.1f, 500.0f);
    cam.position = Vec3(0, 3, 0);
    cam.target = Vec3(0, 3, 10);
    CascadeSettings cs;
    cs.count = 1;
    cs.maxDistance = 50;
    auto a = buildCascades(cam, Vec3(0.2f, 1, 0.4f), cs);
    // Move by a tiny fraction of a texel along the light axis only: the
    // snapped light-space position must not change.
    immutable L = Vec3(0.2f, 1, 0.4f).normalized();
    cam.position = cam.position + L * 0.0001f;
    cam.target = cam.target + L * 0.0001f;
    auto b = buildCascades(cam, Vec3(0.2f, 1, 0.4f), cs);
    foreach (k; 0 .. 16) {
        immutable d = a.viewProj[0].m[k] - b.viewProj[0].m[k];
        assert(d > -1e-3f && d < 1e-3f);
    }
    assert(a.texelWorld[0] > 0 && a.texelWorld[0] == b.texelWorld[0]);
}
