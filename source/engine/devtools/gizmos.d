/// Immediate-mode 3D debug gizmos: lines, boxes, rays, axes, grids.
///
/// Usage (per frame):
///   gizmos.begin(camera.viewProj());
///   gizmos.line(Vec3(0,0,0), Vec3(1,0,0), Color4.red);
///   gizmos.box(Vec3(0,0,0), Vec3(1,1,1), Color4.green);
///   gizmos.axes(Vec3(0,0,0), 1.0f);
///   gizmos.grid(20, 20, Color4(0.3, 0.3, 0.3, 1.0));
///   gizmos.render(frame);
///
/// Draws as WGPUPrimitiveTopology.lineList without depth testing, so
/// gizmos always appear on top of the scene — ideal for debug overlays.
///
/// Fixed GPU vertex buffer capacity (MAX_VERTS). Exceeding it silently
/// drops subsequent lines with a log warning (once per frame).
module engine.devtools.gizmos;

import bindings.wgpu;

import engine.core.log;
import engine.gpu.buffer   : createDynamicVertexBuffer, createUniformBuffer, destroyBuffer;
import engine.gpu.context  : GpuContext;
import engine.gpu.pipeline : Pipeline3D;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shader   : createShaderModule;
import engine.gpu.shaders  : gizmoLineShaderSource;
import engine.graphics.types : Color4;
import engine.math.mat    : Mat4;
import engine.math.vec    : Vec3;

@safe:

private enum size_t MAX_VERTS = 65536;   // 32 768 lines
private enum size_t VERTEX_STRIDE = 7 * float.sizeof; // pos(3) + color(4) = 28 bytes

struct GizmoRenderer {
    private Pipeline3D pipe;
    private WGPUBuffer vertexBuf;
    private WGPUBuffer uniformBuf;
    private WGPUBindGroup bindGroup;
    private WGPUDevice device;
    private WGPUQueue  queue;

    // CPU-side buffer filled between begin() and render().
    private float[MAX_VERTS * 7] verts = 0;
    private size_t vertCount = 0;
    private bool overflowed = false;

    @disable this(this);

    static GizmoRenderer create(ref GpuContext gpu) @trusted {
        GizmoRenderer g;
        g.device = gpu.getDevice();
        g.queue  = gpu.getQueue();
        g.buildPipeline(Renderer.sceneFormat());
        g.vertexBuf  = createDynamicVertexBuffer(g.device, MAX_VERTS * VERTEX_STRIDE);
        g.uniformBuf = createUniformBuffer(g.device, 64);
        g.buildBindGroup();
        info("GizmoRenderer ready (", MAX_VERTS, " vertex capacity)");
        return g;
    }

    /// Start a new frame — clears accumulated lines and uploads viewProj.
    void begin(Mat4 viewProj) @trusted nothrow @nogc {
        vertCount = 0;
        overflowed = false;
        wgpuQueueWriteBuffer(queue, uniformBuf, 0, viewProj.m.ptr, 64);
    }

    // --- primitive: single line ------------------------------------------
    void line(Vec3 a, Vec3 b, Color4 c) nothrow @nogc {
        if (vertCount + 2 > MAX_VERTS) { overflowed = true; return; }
        pushVert(a, c);
        pushVert(b, c);
    }

    // --- primitive: 3-axis gizmo (X=red, Y=green, Z=blue) ----------------
    void axes(Vec3 origin, float scale = 1.0f) nothrow @nogc {
        line(origin, origin + Vec3(scale, 0, 0), Color4(1, 0.2f, 0.2f, 1));
        line(origin, origin + Vec3(0, scale, 0), Color4(0.2f, 1, 0.2f, 1));
        line(origin, origin + Vec3(0, 0, scale), Color4(0.2f, 0.4f, 1, 1));
    }

    // --- primitive: axis-aligned wireframe box ---------------------------
    /// Draws 12 edges of an AABB centered on `center` with full extents `extent`.
    void box(Vec3 center, Vec3 extent, Color4 c) nothrow @nogc {
        immutable hx = extent.x * 0.5f, hy = extent.y * 0.5f, hz = extent.z * 0.5f;
        immutable mnx = center.x - hx, mxx = center.x + hx;
        immutable mny = center.y - hy, mxy = center.y + hy;
        immutable mnz = center.z - hz, mxz = center.z + hz;
        // Bottom square (y = mny)
        line(Vec3(mnx, mny, mnz), Vec3(mxx, mny, mnz), c);
        line(Vec3(mxx, mny, mnz), Vec3(mxx, mny, mxz), c);
        line(Vec3(mxx, mny, mxz), Vec3(mnx, mny, mxz), c);
        line(Vec3(mnx, mny, mxz), Vec3(mnx, mny, mnz), c);
        // Top square (y = mxy)
        line(Vec3(mnx, mxy, mnz), Vec3(mxx, mxy, mnz), c);
        line(Vec3(mxx, mxy, mnz), Vec3(mxx, mxy, mxz), c);
        line(Vec3(mxx, mxy, mxz), Vec3(mnx, mxy, mxz), c);
        line(Vec3(mnx, mxy, mxz), Vec3(mnx, mxy, mnz), c);
        // Vertical pillars
        line(Vec3(mnx, mny, mnz), Vec3(mnx, mxy, mnz), c);
        line(Vec3(mxx, mny, mnz), Vec3(mxx, mxy, mnz), c);
        line(Vec3(mxx, mny, mxz), Vec3(mxx, mxy, mxz), c);
        line(Vec3(mnx, mny, mxz), Vec3(mnx, mxy, mxz), c);
    }

    // --- primitive: ray from origin along direction ---------------------
    void ray(Vec3 origin, Vec3 direction, float length_, Color4 c) nothrow @nogc {
        import std.math : sqrt;
        immutable ls = direction.x*direction.x + direction.y*direction.y + direction.z*direction.z;
        if (ls <= 0) return;
        immutable inv = length_ / sqrt(ls);
        line(origin, Vec3(origin.x + direction.x*inv,
                          origin.y + direction.y*inv,
                          origin.z + direction.z*inv), c);
    }

    // --- primitive: ground grid on XZ plane -----------------------------
    /// `size` = full side length, `cells` = subdivisions per axis.
    void grid(float size, int cells, Color4 c, float y = 0) nothrow @nogc {
        if (cells <= 0) return;
        immutable half = size * 0.5f;
        immutable step = size / cast(float) cells;
        foreach (i; 0 .. cells + 1) {
            immutable p = -half + cast(float) i * step;
            line(Vec3(-half, y, p), Vec3(half, y, p), c);
            line(Vec3(p, y, -half), Vec3(p, y,  half), c);
        }
    }

    /// Encode and submit accumulated lines into the given frame pass.
    /// Safe to call with zero lines (no-op).
    void render(ref FrameContext frame) @trusted nothrow @nogc {
        if (!frame.valid || vertCount == 0) return;
        if (overflowed) warn("GizmoRenderer: vertex buffer overflow — some lines dropped");

        immutable byteCount = vertCount * VERTEX_STRIDE;
        wgpuQueueWriteBuffer(queue, vertexBuf, 0, verts.ptr, cast(size_t) byteCount);

        wgpuRenderPassEncoderSetPipeline(frame.pass, pipe.pipeline);
        wgpuRenderPassEncoderSetBindGroup(frame.pass, 0, bindGroup, 0, null);
        wgpuRenderPassEncoderSetVertexBuffer(frame.pass, 0, vertexBuf, 0, byteCount);
        wgpuRenderPassEncoderDraw(frame.pass, cast(uint) vertCount, 1, 0, 0);
    }

    void destroy() @trusted nothrow @nogc {
        if (bindGroup  !is null) { wgpuBindGroupRelease(bindGroup);  bindGroup  = null; }
        destroyBuffer(uniformBuf); uniformBuf = null;
        destroyBuffer(vertexBuf);  vertexBuf  = null;
        pipe.release();
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    private void pushVert(Vec3 p, Color4 c) nothrow @nogc {
        immutable base = vertCount * 7;
        verts[base + 0] = p.x;
        verts[base + 1] = p.y;
        verts[base + 2] = p.z;
        verts[base + 3] = c.r;
        verts[base + 4] = c.g;
        verts[base + 5] = c.b;
        verts[base + 6] = c.a;
        vertCount++;
    }

    private void buildPipeline(WGPUTextureFormat surfaceFormat) @trusted {
        pipe.shaderModule = createShaderModule(device, gizmoLineShaderSource.ptr);

        WGPUBindGroupLayoutEntry bgle;
        bgle.binding = 0;
        bgle.visibility = WGPUShaderStage.vertex;
        bgle.buffer.type = WGPUBufferBindingType.uniform;
        bgle.buffer.minBindingSize = 64;

        WGPUBindGroupLayoutDescriptor bglDesc;
        bglDesc.entryCount = 1;
        bglDesc.entries = &bgle;
        pipe.bindGroupLayout = wgpuDeviceCreateBindGroupLayout(device, &bglDesc);

        WGPUPipelineLayoutDescriptor plDesc;
        plDesc.bindGroupLayoutCount = 1;
        plDesc.bindGroupLayouts = &pipe.bindGroupLayout;
        pipe.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &plDesc);

        WGPUVertexAttribute[2] attrs = [
            { format: WGPUVertexFormat.float32x3, offset: 0,  shaderLocation: 0 },
            { format: WGPUVertexFormat.float32x4, offset: 12, shaderLocation: 1 },
        ];
        WGPUVertexBufferLayout layout;
        layout.arrayStride    = VERTEX_STRIDE;
        layout.stepMode       = WGPUVertexStepMode.vertex;
        layout.attributeCount = 2;
        layout.attributes     = attrs.ptr;

        WGPUColorTargetState ct;
        ct.format = surfaceFormat;
        ct.writeMask = WGPUColorWriteMask.all;

        WGPUFragmentState fs;
        fs.module_     = pipe.shaderModule;
        fs.entryPoint  = wgpuStringView("fs_main");
        fs.targetCount = 1;
        fs.targets     = &ct;

        // Depth state: use same format as main renderer but disable writes
        // and pass the depth test always — gizmos overlay everything.
        WGPUDepthStencilState depthState;
        depthState.format            = WGPUTextureFormat.depth24Plus;
        depthState.depthWriteEnabled = WGPUOptionalBool.false_;
        depthState.depthCompare      = WGPUCompareFunction.always;

        WGPURenderPipelineDescriptor pd;
        pd.layout = pipe.pipelineLayout;
        pd.vertex.module_     = pipe.shaderModule;
        pd.vertex.entryPoint  = wgpuStringView("vs_main");
        pd.vertex.bufferCount = 1;
        pd.vertex.buffers     = &layout;
        pd.primitive.topology = WGPUPrimitiveTopology.lineList;
        pd.primitive.cullMode = WGPUCullMode.none;
        pd.depthStencil = &depthState;
        pd.fragment     = &fs;

        pipe.pipeline = wgpuDeviceCreateRenderPipeline(device, &pd);
    }

    private void buildBindGroup() @trusted {
        WGPUBindGroupEntry entry;
        entry.binding = 0;
        entry.buffer  = uniformBuf;
        entry.size    = 64;
        WGPUBindGroupDescriptor bgd;
        bgd.layout     = pipe.bindGroupLayout;
        bgd.entryCount = 1;
        bgd.entries    = &entry;
        bindGroup = wgpuDeviceCreateBindGroup(device, &bgd);
    }
}
