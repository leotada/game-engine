/// Material — PBR metallic-roughness bind group for the textured 3D pipeline.
/// Materials are cheap handles; many can share Texture/Sampler resources.
module engine.graphics.material;

import bindings.wgpu;
import engine.core.pod : isPod;
import engine.gpu.buffer : createUniformBuffer, updateBuffer, destroyBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : MATERIAL_PARAMS_SIZE, SURFACE_PARAMS_SIZE, RenderState, BlendMode;
import engine.graphics.texture : Texture, Sampler;
import engine.core.log;

@safe:

/// Bit flags controlling which optional maps contribute in the fragment shader.
enum MaterialFlags : uint {
    none               = 0,
    metallicRoughness  = 1 << 0,
    normal             = 1 << 1,
    occlusion          = 1 << 2,
    emissive           = 1 << 3,
    /// Wave-contact wet marks inside water bodies whose wetline is enabled
    /// (`engine.water`, shared wave data at frame binding 10). Rocks, piers
    /// and banks that waves wash over should set it. Bit 5 is reserved
    /// (formerly `waterRiverMode`; the wave set now comes from the body).
    waterWetCaustics   = 1 << 4,
    /// Skip all lighting: output = base color × tint + emission.
    unlit              = 1 << 6,
}

/// Canonical OpenPBR Surface v1.1 uniform block matching WGSL `MaterialParams` (144 bytes = 9 × vec4<f32>).
struct MaterialParams {
    // vec4 [0] (offset 0..16): Base color & weight
    float[3] baseColor = [1.0f, 1.0f, 1.0f];      // openpbr: base_color
    float    baseWeight = 1.0f;                   // openpbr: base_weight [0..1]

    // vec4 [1] (offset 16..32): Base metalness, diffuse roughness, Specular weight & roughness
    float    baseMetalness = 0.0f;                // openpbr: base_metalness [0..1]
    float    baseDiffuseRoughness = 0.0f;         // openpbr: base_diffuse_roughness [0..1]
    float    specularWeight = 1.0f;               // openpbr: specular_weight [0..1]
    float    specularRoughness = 1.0f;            // openpbr: specular_roughness [0..1]

    // vec4 [2] (offset 32..48): Specular color (dielectric tint & F82 conductor edge tint) & IOR
    float[3] specularColor = [1.0f, 1.0f, 1.0f];  // openpbr: specular_color
    float    specularIor = 1.5f;                  // openpbr: specular_ior (1.5 => F0 = 0.04)

    // vec4 [3] (offset 48..64): Specular anisotropy & Coat weight / roughness / IOR
    float    specularAnisotropy = 0.0f;           // openpbr: specular_anisotropy [-1..1]
    float    coatWeight = 0.0f;                   // openpbr: coat_weight [0..1]
    float    coatRoughness = 0.1f;                // openpbr: coat_roughness [0..1]
    float    coatIor = 1.6f;                      // openpbr: coat_ior

    // vec4 [4] (offset 64..80): Coat color & darkening
    float[3] coatColor = [1.0f, 1.0f, 1.0f];      // openpbr: coat_color (absorption transmittance)
    float    coatDarkening = 1.0f;                // openpbr: coat_darkening [0..1]

    // vec4 [5] (offset 80..96): Fuzz (sheen) color & weight
    float[3] fuzzColor = [1.0f, 1.0f, 1.0f];      // openpbr: fuzz_color
    float    fuzzWeight = 0.0f;                   // openpbr: fuzz_weight [0..1]

    // vec4 [6] (offset 96..112): Fuzz roughness & Thin-film iridescence
    float    fuzzRoughness = 0.5f;                // openpbr: fuzz_roughness [0..1]
    float    thinFilmWeight = 0.0f;               // openpbr: thin_film_weight [0..1]
    float    thinFilmThickness = 500.0f;          // openpbr: thin_film_thickness (nanometers)
    float    thinFilmIor = 1.4f;                  // openpbr: thin_film_ior

    // vec4 [7] (offset 112..128): Emission
    float[3] emissionColor = [1.0f, 1.0f, 1.0f];  // openpbr: emission_color
    float    emissionLuminance = 0.0f;            // openpbr: emission_luminance

    // vec4 [8] (offset 128..144): Geometry opacity & flags
    float    geometryOpacity = 1.0f;              // openpbr: geometry_opacity [0..1]
    uint     flags = MaterialFlags.none;          // bound texture map bitmask
    float    _pad0 = 0.0f;
    float    _pad1 = 0.0f;
}
static assert(MaterialParams.sizeof == MATERIAL_PARAMS_SIZE);
static assert(isPod!MaterialParams);

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
    package(engine) WGPUBuffer surfaceBuf;
    /// Custom surface shader used to draw this material: 0 is the stock PBR
    /// shader, otherwise an id from `Scene3DTextured.createSurfaceShader`.
    uint surfaceShader = 0;
    /// Blend mode, depth write and culling. Non-default states get their own
    /// pipeline; `Scene3DTextured` draws depth-writing batches first, then
    /// alpha batches back to front, then additive batches.
    RenderState renderState;

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

        m.surfaceBuf = createUniformBuffer(gpu.getDevice(), SURFACE_PARAMS_SIZE);
        immutable float[16] zeroSurface = 0.0f;
        updateBuffer(gpu.getQueue(), m.surfaceBuf, zeroSurface[]);

        WGPUBindGroupEntry[8] entries;
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

        entries[7].binding = 7;
        entries[7].buffer  = m.surfaceBuf;
        entries[7].offset  = 0;
        entries[7].size    = SURFACE_PARAMS_SIZE;

        WGPUBindGroupDescriptor desc;
        desc.layout     = layout;
        desc.entryCount = 8;
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

    /// Upload the 4 × vec4 block a custom surface shader reads as
    /// `surfaceParams.p0 .. p3`.
    void updateSurfaceParams(ref GpuContext gpu, in float[16] values) nothrow @nogc @trusted {
        if (surfaceBuf is null) return;
        updateBuffer(gpu.getQueue(), surfaceBuf, values[]);
    }

    void destroy() nothrow @nogc @trusted {
        if (bindGroup !is null) { wgpuBindGroupRelease(bindGroup); bindGroup = null; }
        destroyBuffer(paramsBuf);
        paramsBuf = null;
        destroyBuffer(surfaceBuf);
        surfaceBuf = null;
    }
}
