/// Engine sky renderer: fullscreen triangle at the far plane drawn with the
/// scene's `@group(0)` frame bind group (`assets/shaders/sky.wgsl`). The sky
/// is driven entirely by frame uniforms (sun = directional light, moon,
/// stars, cloud coverage, exposure, fog), so it needs no buffers of its own.
///
/// `Scene3DTextured.setSkyEnabled(true)` creates and draws one automatically
/// after the opaque batches; use this type directly only for custom passes.
module engine.gpu.sky;

import bindings.wgpu;
import engine.core.log;
import engine.gpu.renderer : FrameContext, Renderer;
import engine.gpu.shader : createShaderModule;
import engine.gpu.shaders : skyShaderSource;

@safe:

struct SkyRenderer {
    private WGPUShaderModule shaderModule;
    private WGPUPipelineLayout pipelineLayout;
    private WGPURenderPipeline pipeline;

    @disable this(this);

    /// `frameLayout` is `Scene3DTextured.frameLayout()`.
    static SkyRenderer create(WGPUDevice device, WGPUBindGroupLayout frameLayout) @trusted {
        SkyRenderer r;
        r.shaderModule = createShaderModule(device, skyShaderSource);
        if (r.shaderModule is null) fatal("Sky shader compile failed");

        WGPUPipelineLayoutDescriptor pld;
        pld.bindGroupLayoutCount = 1;
        pld.bindGroupLayouts = &frameLayout;
        r.pipelineLayout = wgpuDeviceCreatePipelineLayout(device, &pld);

        WGPUColorTargetState target;
        target.format = Renderer.sceneFormat();
        target.writeMask = WGPUColorWriteMask.all;
        WGPUFragmentState fs;
        fs.module_ = r.shaderModule;
        fs.entryPoint = wgpuStringView("fs_main");
        fs.targetCount = 1;
        fs.targets = &target;

        WGPUDepthStencilState depth;
        depth.format = WGPUTextureFormat.depth24Plus;
        depth.depthWriteEnabled = WGPUOptionalBool.false_;
        depth.depthCompare = WGPUCompareFunction.lessEqual;

        WGPURenderPipelineDescriptor pd;
        pd.layout = r.pipelineLayout;
        pd.vertex.module_ = r.shaderModule;
        pd.vertex.entryPoint = wgpuStringView("vs_main");
        pd.fragment = &fs;
        pd.primitive.topology = WGPUPrimitiveTopology.triangleList;
        pd.primitive.cullMode = WGPUCullMode.none;
        pd.depthStencil = &depth;
        r.pipeline = wgpuDeviceCreateRenderPipeline(device, &pd);
        if (r.pipeline is null) fatal("Sky pipeline creation failed");
        return r;
    }

    bool valid() const nothrow @nogc { return pipeline !is null; }

    /// Draw inside the scene pass; `frameGroup` is the scene's `@group(0)`.
    void draw(ref FrameContext frame, WGPUBindGroup frameGroup) nothrow @nogc @trusted {
        if (pipeline is null || !frame.valid) return;
        frame.setPipeline(pipeline);
        frame.setBindGroup(0, frameGroup);
        frame.draw(3, 1);
    }

    void destroy() nothrow @nogc @trusted {
        if (pipeline !is null) { wgpuRenderPipelineRelease(pipeline); pipeline = null; }
        if (pipelineLayout !is null) { wgpuPipelineLayoutRelease(pipelineLayout); pipelineLayout = null; }
        if (shaderModule !is null) { wgpuShaderModuleRelease(shaderModule); shaderModule = null; }
    }
}
