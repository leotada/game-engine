/// Helpers shared by the fullscreen post passes.
module engine.gpu.post_util;

import bindings.wgpu;
import engine.core.log;

@safe:

package(engine):

/// Owned single-mip render target.
struct TexRT {
    WGPUTexture texture;
    WGPUTextureView view;
    uint width;
    uint height;

    void release() nothrow @nogc @trusted {
        if (view !is null) { wgpuTextureViewRelease(view); view = null; }
        if (texture !is null) { wgpuTextureRelease(texture); texture = null; }
        width = height = 0;
    }
}

/// 2D render target that can also be sampled. `extraUsage` adds usages (storage, copy).
TexRT createRT(WGPUDevice device, uint w, uint h, WGPUTextureFormat fmt,
               WGPUTextureUsage extraUsage = WGPUTextureUsage.none) nothrow @nogc @trusted {
    TexRT rt;
    rt.width = w;
    rt.height = h;
    WGPUTextureDescriptor td;
    td.usage = WGPUTextureUsage.renderAttachment | WGPUTextureUsage.textureBinding | extraUsage;
    td.dimension = WGPUTextureDimension.dim2D;
    td.size = WGPUExtent3D(w, h, 1);
    td.format = fmt;
    td.mipLevelCount = 1;
    td.sampleCount = 1;
    rt.texture = wgpuDeviceCreateTexture(device, &td);
    if (rt.texture is null) fatal("Post RT texture creation failed");
    WGPUTextureViewDescriptor vd;
    vd.format = fmt;
    vd.dimension = WGPUTextureViewDimension.dim2D;
    vd.mipLevelCount = 1;
    vd.arrayLayerCount = 1;
    rt.view = wgpuTextureCreateView(rt.texture, &vd);
    return rt;
}

/// Draw one fullscreen triangle into `target`.
void drawPass(WGPUCommandEncoder encoder, WGPUTextureView target,
                      WGPURenderPipeline pipe, WGPUBindGroup bg, bool clear,
                      WGPUBindGroup bg1 = null) nothrow @nogc @trusted {
    WGPURenderPassColorAttachment ca;
    ca.view = target;
    ca.loadOp = clear ? WGPULoadOp.clear : WGPULoadOp.load;
    ca.storeOp = WGPUStoreOp.store;
    ca.clearValue = WGPUColor(0, 0, 0, 1);
    ca.depthSlice = WGPU_DEPTH_SLICE_UNDEFINED;

    WGPURenderPassDescriptor pd;
    pd.colorAttachmentCount = 1;
    pd.colorAttachments = &ca;
    auto pass = wgpuCommandEncoderBeginRenderPass(encoder, &pd);
    wgpuRenderPassEncoderSetPipeline(pass, pipe);
    wgpuRenderPassEncoderSetBindGroup(pass, 0, bg, 0, null);
    if (bg1 !is null) wgpuRenderPassEncoderSetBindGroup(pass, 1, bg1, 0, null);
    wgpuRenderPassEncoderDraw(pass, 3, 1, 0, 0);
    wgpuRenderPassEncoderEnd(pass);
    wgpuRenderPassEncoderRelease(pass);
}

WGPUPipelineLayout makePL(WGPUDevice device, WGPUBindGroupLayout bgl) nothrow @nogc @trusted {
    WGPUPipelineLayoutDescriptor d;
    d.bindGroupLayoutCount = 1;
    d.bindGroupLayouts = &bgl;
    return wgpuDeviceCreatePipelineLayout(device, &d);
}

WGPURenderPipeline tryMakeFSPipeline(
    WGPUDevice device, WGPUPipelineLayout pl, WGPUShaderModule sm,
    WGPUTextureFormat colorFmt, bool additive) nothrow @nogc @trusted {

    WGPUColorTargetState ct;
    ct.format = colorFmt;
    ct.writeMask = WGPUColorWriteMask.all;
    WGPUBlendState blend;
    if (additive) {
        blend.color.operation = WGPUBlendOperation.add;
        blend.color.srcFactor = WGPUBlendFactor.one;
        blend.color.dstFactor = WGPUBlendFactor.one;
        blend.alpha.operation = WGPUBlendOperation.add;
        blend.alpha.srcFactor = WGPUBlendFactor.one;
        blend.alpha.dstFactor = WGPUBlendFactor.one;
        ct.blend = &blend;
    }

    WGPUFragmentState fs;
    fs.module_ = sm;
    fs.entryPoint = wgpuStringView("fs_main");
    fs.targetCount = 1;
    fs.targets = &ct;

    WGPURenderPipelineDescriptor desc;
    desc.layout = pl;
    desc.vertex.module_ = sm;
    desc.vertex.entryPoint = wgpuStringView("vs_main");
    desc.fragment = &fs;
    desc.primitive.topology = WGPUPrimitiveTopology.triangleList;
    desc.multisample.count = 1;
    desc.multisample.mask = ~0u;

    return wgpuDeviceCreateRenderPipeline(device, &desc);
}

WGPURenderPipeline makeFSPipeline(
    WGPUDevice device, WGPUPipelineLayout pl, WGPUShaderModule sm,
    WGPUTextureFormat colorFmt, bool additive) nothrow @nogc @trusted {
    auto pipe = tryMakeFSPipeline(device, pl, sm, colorFmt, additive);
    if (pipe is null) fatal("Failed to create post pipeline");
    return pipe;
}
