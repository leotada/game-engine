/// Material — albedo texture + sampler binding for the textured 3D pipeline.
/// Materials are cheap handles; many can share the same Texture/Sampler.
module engine.graphics.material;

import bindings.wgpu;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : Pipeline3D;
import engine.graphics.texture : Texture, Sampler;
import engine.core.log;

@safe:

/// A bindable material: (texture, sampler, shared uniform VP).
/// The layout is driven by the textured pipeline's bind group layout.
/// Each material owns its bind group but shares the uniform buffer provided at creation.
struct Material {
    package(engine) WGPUBindGroup bindGroup;

    @disable this(this);

    /// Create a material that binds (uniformBuffer, sampler, texture).
    /// The uniform buffer (VP matrix, 64 bytes) is typically owned by a scene renderer.
    static Material create(ref GpuContext gpu,
                           WGPUBindGroupLayout layout,
                           WGPUBuffer uniformBuffer,
                           ref Sampler sampler,
                           ref Texture texture) @trusted {
        WGPUBindGroupEntry[3] entries;
        entries[0].binding = 0;
        entries[0].buffer  = uniformBuffer;
        entries[0].offset  = 0;
        entries[0].size    = 64;

        entries[1].binding = 1;
        entries[1].sampler = sampler.sampler;

        entries[2].binding = 2;
        entries[2].textureView = texture.view;

        WGPUBindGroupDescriptor desc;
        desc.layout     = layout;
        desc.entryCount = 3;
        desc.entries    = entries.ptr;

        Material m;
        m.bindGroup = wgpuDeviceCreateBindGroup(gpu.getDevice(), &desc);
        if (m.bindGroup is null) fatal("Failed to create Material bind group");
        return m;
    }

    bool valid() const nothrow @nogc { return bindGroup !is null; }

    void destroy() nothrow @nogc @trusted {
        if (bindGroup !is null) { wgpuBindGroupRelease(bindGroup); bindGroup = null; }
    }
}
