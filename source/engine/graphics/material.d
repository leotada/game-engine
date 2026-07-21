/// Material — PBR metallic-roughness bind group for the textured 3D pipeline.
/// Materials are cheap handles; many can share Texture/Sampler resources.
module engine.graphics.material;

import bindings.wgpu;
import engine.gpu.buffer : createUniformBuffer, updateBuffer, destroyBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : MATERIAL_PARAMS_SIZE;
import engine.graphics.texture : Texture, Sampler;
import engine.core.log;

@safe:

/// Bit flags controlling which optional maps contribute in the fragment shader.
enum MaterialFlags : uint {
    none               = 0,
    metallicRoughness  = 1,
    normal             = 2,
    occlusion          = 4,
    emissive           = 8,
}

/// POD uniform matching WGSL `MaterialParams` (32 bytes).
struct MaterialParams {
    float[4] baseColorFactor = [1, 1, 1, 1];
    float metallic = 0;
    float roughness = 1;
    uint flags = MaterialFlags.none;
    float _pad = 0;
}

/// Shared 1×1 fallback textures so every material binds a fixed BGL layout.
struct MaterialDefaults {
    Texture white;       // albedo / AO fallback
    Texture metallicRoughness; // G=1 roughness, B=0 metallic
    Texture flatNormal;  // (0.5, 0.5, 1)
    Texture black;       // emissive fallback
    bool ready;

    @disable this(this);

    void ensure(ref GpuContext gpu) {
        if (ready) return;
        white = Texture.solid(gpu, 255, 255, 255, 255);
        metallicRoughness = Texture.solid(gpu, 0, 255, 0, 255);
        flatNormal = Texture.solid(gpu, 128, 128, 255, 255);
        black = Texture.solid(gpu, 0, 0, 0, 255);
        ready = true;
    }

    void destroy() nothrow @nogc {
        if (!ready) return;
        white.destroy();
        metallicRoughness.destroy();
        flatNormal.destroy();
        black.destroy();
        ready = false;
    }
}

/// Package-level defaults used when optional maps are null.
package(engine) MaterialDefaults gMaterialDefaults;

/// A bindable PBR material: MaterialParams UBO + sampler + albedo (+ optional maps).
struct Material {
    package(engine) WGPUBindGroup bindGroup;
    package(engine) WGPUBuffer paramsBuf;

    @disable this(this);

    /// Albedo-only material: metallic=0, roughness=1, baseColorFactor=1, no extra maps.
    static Material create(ref GpuContext gpu,
                           WGPUBindGroupLayout layout,
                           ref Sampler sampler,
                           ref Texture albedo) {
        return create(gpu, layout, sampler, albedo, MaterialParams.init,
                      null, null, null, null);
    }

    /// Full PBR material. Null optional maps bind engine 1×1 defaults.
    /// Set corresponding `MaterialFlags` bits when providing real maps.
    static Material create(ref GpuContext gpu,
                           WGPUBindGroupLayout layout,
                           ref Sampler sampler,
                           ref Texture albedo,
                           MaterialParams params,
                           Texture* metallicRoughness,
                           Texture* normal,
                           Texture* occlusion,
                           Texture* emissive) @trusted {
        gMaterialDefaults.ensure(gpu);

        Texture* mr  = metallicRoughness !is null ? metallicRoughness : &gMaterialDefaults.metallicRoughness;
        Texture* nrm = normal !is null ? normal : &gMaterialDefaults.flatNormal;
        Texture* ao  = occlusion !is null ? occlusion : &gMaterialDefaults.white;
        Texture* em  = emissive !is null ? emissive : &gMaterialDefaults.black;

        Material m;
        m.paramsBuf = createUniformBuffer(gpu.getDevice(), MATERIAL_PARAMS_SIZE);
        updateBuffer(gpu.getQueue(), m.paramsBuf, (&params)[0 .. 1]);

        WGPUBindGroupEntry[7] entries;
        entries[0].binding = 0;
        entries[0].buffer  = m.paramsBuf;
        entries[0].offset  = 0;
        entries[0].size    = MATERIAL_PARAMS_SIZE;

        entries[1].binding = 1;
        entries[1].sampler = sampler.sampler;

        entries[2].binding = 2;
        entries[2].textureView = albedo.view;
        entries[3].binding = 3;
        entries[3].textureView = mr.view;
        entries[4].binding = 4;
        entries[4].textureView = nrm.view;
        entries[5].binding = 5;
        entries[5].textureView = ao.view;
        entries[6].binding = 6;
        entries[6].textureView = em.view;

        WGPUBindGroupDescriptor desc;
        desc.layout     = layout;
        desc.entryCount = 7;
        desc.entries    = entries.ptr;

        m.bindGroup = wgpuDeviceCreateBindGroup(gpu.getDevice(), &desc);
        if (m.bindGroup is null) fatal("Failed to create Material bind group");
        return m;
    }

    bool valid() const nothrow @nogc { return bindGroup !is null; }

    /// Upload new PBR params to the material UBO (live editor overrides).
    void updateParams(ref GpuContext gpu, MaterialParams params) nothrow @nogc @trusted {
        if (paramsBuf is null) return;
        updateBuffer(gpu.getQueue(), paramsBuf, (&params)[0 .. 1]);
    }

    void destroy() nothrow @nogc @trusted {
        if (bindGroup !is null) { wgpuBindGroupRelease(bindGroup); bindGroup = null; }
        destroyBuffer(paramsBuf);
        paramsBuf = null;
    }
}
