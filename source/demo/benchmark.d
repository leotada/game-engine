/// 3D Benchmark — grid of spinning cubes with instanced rendering and FPS overlay.
module demo.benchmark;

import bindings.wgpu;
import engine.app;
import engine.gpu.pipeline;
import engine.gpu.buffer;
import engine.gpu.text;
import engine.gpu.renderer : Color;
import engine.math.mat;
import engine.math.vec;
import engine.core.log;
import bindings.sdl3;

@safe:

// ---------------------------------------------------------------------------
// Cube mesh data — 24 vertices (4 per face, with normals), 36 indices
// Vertex format: float32x3 position + float32x3 normal = 24 bytes/vertex
// ---------------------------------------------------------------------------
private struct CubeVertex {
    float[3] pos;
    float[3] normal;
}

// Unit cube centered at origin, side length 1.0
private static immutable CubeVertex[24] cubeVertices = [
    // Front face (z = +0.5, normal = 0,0,1)
    CubeVertex([-0.5, -0.5,  0.5], [ 0,  0,  1]),
    CubeVertex([ 0.5, -0.5,  0.5], [ 0,  0,  1]),
    CubeVertex([ 0.5,  0.5,  0.5], [ 0,  0,  1]),
    CubeVertex([-0.5,  0.5,  0.5], [ 0,  0,  1]),
    // Back face (z = -0.5, normal = 0,0,-1)
    CubeVertex([ 0.5, -0.5, -0.5], [ 0,  0, -1]),
    CubeVertex([-0.5, -0.5, -0.5], [ 0,  0, -1]),
    CubeVertex([-0.5,  0.5, -0.5], [ 0,  0, -1]),
    CubeVertex([ 0.5,  0.5, -0.5], [ 0,  0, -1]),
    // Right face (x = +0.5, normal = 1,0,0)
    CubeVertex([ 0.5, -0.5,  0.5], [ 1,  0,  0]),
    CubeVertex([ 0.5, -0.5, -0.5], [ 1,  0,  0]),
    CubeVertex([ 0.5,  0.5, -0.5], [ 1,  0,  0]),
    CubeVertex([ 0.5,  0.5,  0.5], [ 1,  0,  0]),
    // Left face (x = -0.5, normal = -1,0,0)
    CubeVertex([-0.5, -0.5, -0.5], [-1,  0,  0]),
    CubeVertex([-0.5, -0.5,  0.5], [-1,  0,  0]),
    CubeVertex([-0.5,  0.5,  0.5], [-1,  0,  0]),
    CubeVertex([-0.5,  0.5, -0.5], [-1,  0,  0]),
    // Top face (y = +0.5, normal = 0,1,0)
    CubeVertex([-0.5,  0.5,  0.5], [ 0,  1,  0]),
    CubeVertex([ 0.5,  0.5,  0.5], [ 0,  1,  0]),
    CubeVertex([ 0.5,  0.5, -0.5], [ 0,  1,  0]),
    CubeVertex([-0.5,  0.5, -0.5], [ 0,  1,  0]),
    // Bottom face (y = -0.5, normal = 0,-1,0)
    CubeVertex([-0.5, -0.5, -0.5], [ 0, -1,  0]),
    CubeVertex([ 0.5, -0.5, -0.5], [ 0, -1,  0]),
    CubeVertex([ 0.5, -0.5,  0.5], [ 0, -1,  0]),
    CubeVertex([-0.5, -0.5,  0.5], [ 0, -1,  0]),
];

private static immutable ushort[36] cubeIndices = [
     0, 1, 2,  2, 3, 0,   // front
     4, 5, 6,  6, 7, 4,   // back
     8, 9,10, 10,11, 8,   // right
    12,13,14, 14,15,12,   // left
    16,17,18, 18,19,16,   // top
    20,21,22, 22,23,20,   // bottom
];

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------
private enum GRID_N = 10;                       // 10×10×10 = 1000 cubes
private enum CUBE_COUNT = GRID_N * GRID_N * GRID_N;
private enum CUBE_SPACING = 1.5f;               // distance between cube centers
private enum SCREEN_W = 1280;
private enum SCREEN_H = 720;

void main() {
    // -----------------------------------------------------------------------
    // Init: window + GPU via App
    // -----------------------------------------------------------------------
    auto app = App.create("3D Benchmark", SCREEN_W, SCREEN_H, WGPUPresentMode.mailbox);

    // -----------------------------------------------------------------------
    // Create GPU resources
    // -----------------------------------------------------------------------
    auto device = () @trusted { return app.gpu.getDevice(); }();
    auto queue  = () @trusted { return app.gpu.getQueue(); }();

    // Cube mesh buffers
    auto vertexBuf = () @trusted {
        return createVertexBuffer(device, queue,
            cubeVertices.ptr, cubeVertices.sizeof);
    }();
    scope(exit) () @trusted { wgpuBufferDestroy(vertexBuf); wgpuBufferRelease(vertexBuf); }();

    auto indexBuf = () @trusted {
        return createIndexBuffer(device, queue,
            cubeIndices.ptr, cubeIndices.sizeof);
    }();
    scope(exit) () @trusted { wgpuBufferDestroy(indexBuf); wgpuBufferRelease(indexBuf); }();

    // Instance buffer (model matrices — 64 bytes per cube)
    auto instanceBuf = () @trusted {
        return createDynamicVertexBuffer(device, CUBE_COUNT * 64);
    }();
    scope(exit) () @trusted { wgpuBufferDestroy(instanceBuf); wgpuBufferRelease(instanceBuf); }();

    // Uniform buffer (VP matrix — 64 bytes)
    auto uniformBuf = createUniformBuffer(device, 64);
    scope(exit) () @trusted { wgpuBufferDestroy(uniformBuf); wgpuBufferRelease(uniformBuf); }();

    // 3D pipeline
    auto pipe3d = createPipeline3D(device, app.gpu.getFormat());
    scope(exit) pipe3d.release();

    // Create bind group for VP uniform
    auto vpBindGroup = () @trusted {
        WGPUBindGroupEntry bgEntry;
        bgEntry.binding = 0;
        bgEntry.buffer  = uniformBuf;
        bgEntry.offset  = 0;
        bgEntry.size    = 64;

        WGPUBindGroupDescriptor bgDesc;
        bgDesc.layout     = pipe3d.bindGroupLayout;
        bgDesc.entryCount = 1;
        bgDesc.entries    = &bgEntry;
        return wgpuDeviceCreateBindGroup(device, &bgDesc);
    }();
    scope(exit) () @trusted { wgpuBindGroupRelease(vpBindGroup); }();

    // Text renderer
    auto textRenderer = TextRenderer.create(device, queue, app.gpu.getFormat(), SCREEN_W, SCREEN_H);
    scope(exit) textRenderer.destroy();

    // FPS counter
    auto fps = FpsCounter.create();

    // -----------------------------------------------------------------------
    // Pre-compute per-cube rotation axes and speeds
    // -----------------------------------------------------------------------
    struct CubeState {
        Vec3 position;
        Vec3 axis;     // rotation axis (normalized)
        float speed;   // radians per second
        float angle;   // current angle
    }

    CubeState[CUBE_COUNT] cubes = void;
    {
        immutable halfExtent = (GRID_N - 1) * CUBE_SPACING * 0.5f;
        size_t idx = 0;
        foreach (iz; 0 .. GRID_N) {
            foreach (iy; 0 .. GRID_N) {
                foreach (ix; 0 .. GRID_N) {
                    cubes[idx].position = Vec3(
                        ix * CUBE_SPACING - halfExtent,
                        iy * CUBE_SPACING - halfExtent,
                        iz * CUBE_SPACING - halfExtent,
                    );
                    // Pseudo-random axis and speed derived from index
                    immutable fi = cast(float)(idx);
                    cubes[idx].axis = Vec3(
                        sinF(fi * 1.37f),
                        sinF(fi * 2.41f + 1.0f),
                        sinF(fi * 0.79f + 2.0f),
                    ).normalized();
                    cubes[idx].speed = 0.5f + sinF(fi * 0.31f) * sinF(fi * 0.31f) * 2.0f;
                    cubes[idx].angle = 0;
                    idx++;
                }
            }
        }
    }

    // Camera setup
    immutable gridCenter = Vec3(0, 0, 0);
    immutable cameraDistance = GRID_N * CUBE_SPACING * 1.5f;
    immutable eye = Vec3(cameraDistance * 0.6f, cameraDistance * 0.5f, cameraDistance * 0.7f);
    immutable view = Mat4.lookAt(eye, gridCenter, Vec3(0, 1, 0));
    immutable proj = Mat4.perspective(0.785f, cast(float) SCREEN_W / cast(float) SCREEN_H, 0.1f, 200.0f);
    immutable vp = proj * view;

    // Upload VP matrix
    () @trusted {
        wgpuQueueWriteBuffer(queue, uniformBuf, 0, vp.m.ptr, vp.m.sizeof);
    }();

    // Instance data buffer (CPU side)
    float[16][CUBE_COUNT] instanceData = void;

    // -----------------------------------------------------------------------
    // Main loop
    // -----------------------------------------------------------------------
    while (app.running()) {
        app.pollEvents();

        // Timing
        immutable dt = fps.tick();

        // Update cube rotations and build instance data
        foreach (i; 0 .. CUBE_COUNT) {
            cubes[i].angle += cubes[i].speed * dt;
            immutable model = Mat4.translation(
                cubes[i].position.x,
                cubes[i].position.y,
                cubes[i].position.z,
            ) * axisAngle(cubes[i].axis, cubes[i].angle);
            instanceData[i] = model.m;
        }

        // Upload instance data
        () @trusted {
            wgpuQueueWriteBuffer(queue, instanceBuf, 0,
                instanceData.ptr, instanceData.sizeof);
        }();

        // Render
        auto frame = app.renderer.beginFrame(Color(0.05, 0.05, 0.12, 1.0));
        if (!frame.valid) continue;

        () @trusted {
            // 3D draw
            wgpuRenderPassEncoderSetPipeline(frame.pass, pipe3d.pipeline);
            wgpuRenderPassEncoderSetBindGroup(frame.pass, 0, vpBindGroup, 0, null);
            wgpuRenderPassEncoderSetVertexBuffer(frame.pass, 0, vertexBuf, 0, cubeVertices.sizeof);
            wgpuRenderPassEncoderSetVertexBuffer(frame.pass, 1, instanceBuf, 0, CUBE_COUNT * 64);
            wgpuRenderPassEncoderSetIndexBuffer(frame.pass, indexBuf, WGPUIndexFormat.uint16, 0, cubeIndices.sizeof);
            wgpuRenderPassEncoderDrawIndexed(frame.pass, 36, CUBE_COUNT, 0, 0, 0);
        }();

        // FPS text overlay
        textRenderer.drawText(frame.pass, fps.text(), 10, 10, 3);

        app.renderer.endFrame(frame);
    }

    info("Benchmark finished");
}

// ---------------------------------------------------------------------------
// Math helpers
// ---------------------------------------------------------------------------

/// Rotation matrix around an arbitrary axis by angle (radians).
private Mat4 axisAngle(Vec3 axis, float angle) pure nothrow @nogc @safe {
    import std.math : sin, cos;
    immutable c = cos(angle);
    immutable s = sin(angle);
    immutable t = 1.0f - c;
    immutable x = axis.x, y = axis.y, z = axis.z;

    Mat4 r;
    r.m[0]  = t*x*x + c;     r.m[1]  = t*x*y + s*z;   r.m[2]  = t*x*z - s*y;   r.m[3]  = 0;
    r.m[4]  = t*x*y - s*z;   r.m[5]  = t*y*y + c;     r.m[6]  = t*y*z + s*x;   r.m[7]  = 0;
    r.m[8]  = t*x*z + s*y;   r.m[9]  = t*y*z - s*x;   r.m[10] = t*z*z + c;     r.m[11] = 0;
    r.m[12] = 0;             r.m[13] = 0;             r.m[14] = 0;             r.m[15] = 1;
    return r;
}

/// @nogc-safe sine approximation using std.math
private float sinF(float x) pure nothrow @nogc @safe {
    import std.math : sin;
    return sin(x);
}
