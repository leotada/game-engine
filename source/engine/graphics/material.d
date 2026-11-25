/// Material — PBR metallic-roughness bind group for the textured 3D pipeline.
/// Materials are cheap handles; many can share Texture/Sampler resources.
module engine.graphics.material;

import bindings.wgpu;
import engine.core.pod : isPod;
import engine.gpu.buffer : createUniformBuffer, updateBuffer, destroyBuffer;
import engine.gpu.context : GpuContext;
import engine.gpu.pipeline : MATERIAL_BINDING_COUNT, MATERIAL_PARAMS_SIZE, SURFACE_PARAMS_SIZE, RenderState, BlendMode;
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
    /// Per-pixel coat weight (R) & coat roughness (G) map (`coatMap`, binding 8).
    coat               = 1 << 7,
    /// Tangent-space coat normal map (`coatNormalMap`, binding 9).
    coatNormal         = 1 << 8,
    /// Per-pixel fuzz color (RGB) & fuzz roughness (A) map (`fuzzMap`, binding 10).
    fuzz               = 1 << 9,
    /// Per-pixel anisotropy direction (RG) & strength (B) in `anisoFilmMap` (binding 11).
    anisotropy         = 1 << 10,
    /// Per-pixel thin-film thickness multiplier in `anisoFilmMap.a` (binding 11).
    thinFilm           = 1 << 11,
    /// Per-pixel transmission weight (R) & volume thickness (G) (`transmissionMap`, binding 12).
    transmission       = 1 << 12,
    /// OpenPBR `geometry_thin_walled`: back-face diffuse transmission for foliage/cloth/paper.
    thinWalled         = 1 << 13,
    /// Per-pixel subsurface / diffuse-transmission weight in `transmissionMap.b` (binding 12).
    subsurface         = 1 << 14,
    /// Opt-in per-material Screen-Space Reflections (`OPBR-9`).
    ssr                = 1 << 15,
    /// Raise the roughness where the vertex normal turns fast on screen
    /// (specular antialiasing of curved and distant geometry).
    geometricSpecularAa = 1 << 16,
    /// Fade where the surface comes within `softDistance` in front of the opaque
    /// scene. Alpha and additive materials only.
    soft               = 1 << 17,
    /// Particle lighting: wrapped diffuse (`lightWrap`) from the sun, the clustered
    /// lights and the ambient, with shadows, on a ball normal (or `normal` map).
    /// Ignored with `unlit`.
    litParticle        = 1 << 18,
    /// Albedo, normal and emissive maps are atlases of `flipbookGrid` frames; the
    /// instance `custom.w` holds the frame (and is no longer the rain shelter).
    flipbook           = 1 << 19,
    /// The normal map holds X and Y only; Z is rebuilt. Set by `Material.create` for BC5 textures.
    normalXy           = 1 << 20,
    /// Tubes of `thinRadius` never get narrower than `thinPixels` on screen: vertices move along
    /// their normals and coverage drops (dither, or alpha when `RenderState.depthWrite` is off).
    thin               = 1 << 21,
}

/// Canonical OpenPBR Surface v1.1 + OPBR-6/7/8 uniform block matching WGSL `MaterialParams` (240 bytes = 15 × vec4<f32>).
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

    // vec4 [8] (offset 128..144): Geometry opacity, flags, anisotropy rotation & thin-film minimum thickness
    float    geometryOpacity = 1.0f;              // openpbr: geometry_opacity [0..1]
    uint     flags = MaterialFlags.none;          // bound texture map bitmask
    float    anisotropyRotation = 0.0f;           // radians (`KHR_materials_anisotropy.anisotropyRotation`)
    float    thinFilmThicknessMin = 300.0f;       // nanometers (`KHR_materials_iridescence.iridescenceThicknessMinimum`)

    // vec4 [9] (offset 144..160): Transmission tint & weight
    float[3] transmissionColor = [1.0f, 1.0f, 1.0f]; // openpbr: transmission_color / volume attenuationColor
    float    transmissionWeight = 0.0f;           // openpbr: transmission_weight [0..1]

    // vec4 [10] (offset 160..176): Volume attenuation depth, dispersion, slab thickness & subsurface weight
    float    transmissionDepth = 0.0f;            // openpbr: transmission_depth (0 = infinite / no Beer-Lambert drop)
    float    transmissionDispersion = 0.0f;       // openpbr: transmission_dispersion (`KHR_materials_dispersion`)
    float    transmissionThickness = 0.0f;        // world-space volume thickness factor (`KHR_materials_volume`)
    float    subsurfaceWeight = 0.0f;             // openpbr: subsurface_weight [0..1]

    // vec4 [11] (offset 176..192): Subsurface scatter color & radius
    float[3] subsurfaceColor = [1.0f, 0.4f, 0.25f]; // openpbr: subsurface_color (mean free path tint)
    float    subsurfaceRadius = 1.0f;             // openpbr: subsurface_radius (mean free path scalar)

    // vec4 [12] (offset 192..208): Subsurface RGB radius scale & scattering anisotropy
    float[3] subsurfaceRadiusScale = [1.0f, 0.35f, 0.15f]; // openpbr: subsurface_radius_scale (RGB MFP)
    float    subsurfaceAnisotropy = 0.0f;         // openpbr: subsurface_scatter_anisotropy [-1..1]

    // vec4 [13] (offset 208..224): Surface options (each is ignored until its feature is enabled)
    float    alphaCutoff = 0.5f;                  // alpha-mask threshold (`RenderState.alphaMask`)
    float    softDistance = 0.0f;                 // soft-particle fade distance in meters (`MaterialFlags.soft`)
    float    thinRadius = 0.0f;                   // world radius of thin tubes (`MaterialFlags.thin`)
    float    thinPixels = 1.0f;                   // smallest drawn width in pixels (`MaterialFlags.thin`)

    // vec4 [14] (offset 224..240): Flipbook atlas
    float[2] flipbookGrid = [1.0f, 1.0f];         // atlas columns, rows (`MaterialFlags.flipbook`)
    float    flipbookBlend = 1.0f;                // 1 = cross-fade consecutive frames, 0 = hard steps
    float    lightWrap = 0.5f;                    // how far diffuse light wraps around (`MaterialFlags.litParticle`)
}
static assert(MaterialParams.sizeof == MATERIAL_PARAMS_SIZE);
static assert(isPod!MaterialParams);

/// Shared 1×1 fallback textures so every material binds a fixed BGL layout.
struct MaterialDefaults {
    Texture white;       // albedo / AO / coat / fuzz / transmission fallback
    Texture metallicRoughness; // G=1 roughness, B=0 metallic
    Texture flatNormal;  // (0.5, 0.5, 1)
    Texture black;       // emissive fallback
    Texture anisoDefault; // RG=(1, 0.5)->(+1,0) dir, B=1 strength, A=1 thin-film thickness
    bool ready;

    @disable this(this);

    void ensure(ref GpuContext gpu) {
        if (ready) return;
        white = Texture.solid(gpu, 255, 255, 255, 255);
        metallicRoughness = Texture.solid(gpu, 0, 255, 0, 255);
        flatNormal = Texture.solid(gpu, 128, 128, 255, 255);
        black = Texture.solid(gpu, 0, 0, 0, 255);
        anisoDefault = Texture.solid(gpu, 255, 128, 255, 255);
        ready = true;
    }

    void destroy() nothrow @nogc {
        if (!ready) return;
        white.destroy();
        metallicRoughness.destroy();
        flatNormal.destroy();
        black.destroy();
        anisoDefault.destroy();
        ready = false;
    }
}

/// Optional per-pixel OPBR-6/7 layer texture maps passed to `Material.create`.
struct MaterialLayerMaps {
    Texture* coat;         // R=coatWeight, G=coatRoughness
    Texture* coatNormal;   // RGB=tangent-space coat normal
    Texture* fuzz;         // RGB=fuzzColor, A=fuzzRoughness
    Texture* anisoFilm;    // RG=anisoDir, B=anisoStrength, A=thinFilmThickness
    Texture* transmission; // R=transmissionWeight, G=volumeThickness
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
    /// True when the material uses refractive transmission (`transmissionWeight > 0`
    /// or `MaterialFlags.transmission`); routed into the post-snapshot back-to-front pass.
    bool transmissive = false;
    /// True when the material opts into OPBR-9 Screen-Space Reflections (`MaterialFlags.ssr`).
    bool ssr = false;
    /// True when the material fades against the scene depth (`MaterialFlags.soft`).
    bool soft = false;
    /// True when the material uses `soft`, `litParticle` or `flipbook`.
    package(engine) bool sprite = false;
    /// True when the normal map holds X and Y only.
    package(engine) bool normalXy = false;
    /// True for `MaterialFlags.thin`.
    package(engine) bool thin = false;
    /// Blend mode, depth write and culling. Non-default states get their own
    /// pipeline; `Scene3DTextured` draws depth-writing batches first, then
    /// alpha/transmissive batches back to front, then additive batches.
    RenderState renderState;
    /// Largest distance (world units) a `displace` / `displaceEx` hook moves a
    /// vertex. GPU culling (`StaticBuildOptions.gpuCull`) grows the bounds by it.
    float displacementBound = 0;

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
                           Texture* emissive,
                           MaterialLayerMaps layers = MaterialLayerMaps.init) @trusted {
        gMaterialDefaults.ensure(gpu);

        Texture* mr   = metallicRoughness !is null ? metallicRoughness : &gMaterialDefaults.metallicRoughness;
        Texture* nrm  = normal !is null ? normal : &gMaterialDefaults.flatNormal;
        Texture* ao   = occlusion !is null ? occlusion : &gMaterialDefaults.white;
        Texture* em   = emissive !is null ? emissive : &gMaterialDefaults.black;
        Texture* coat = layers.coat !is null ? layers.coat : &gMaterialDefaults.white;
        Texture* cnrm = layers.coatNormal !is null ? layers.coatNormal : &gMaterialDefaults.flatNormal;
        Texture* fz   = layers.fuzz !is null ? layers.fuzz : &gMaterialDefaults.white;
        Texture* af   = layers.anisoFilm !is null ? layers.anisoFilm : &gMaterialDefaults.anisoDefault;
        Texture* tr   = layers.transmission !is null ? layers.transmission : &gMaterialDefaults.white;

        if (nrm.normalXy) params.flags |= MaterialFlags.normalXy;
        Material m;
        m.normalXy = (params.flags & MaterialFlags.normalXy) != 0;
        m.thin = (params.flags & MaterialFlags.thin) != 0;
        m.transmissive = params.transmissionWeight > 0.0f
                      || (params.flags & MaterialFlags.transmission) != 0;
        m.ssr = (params.flags & MaterialFlags.ssr) != 0;
        m.setSpriteFlags(params.flags);
        m.paramsBuf = createUniformBuffer(gpu.getDevice(), MATERIAL_PARAMS_SIZE);
        updateBuffer(gpu.getQueue(), m.paramsBuf, (&params)[0 .. 1]);

        m.surfaceBuf = createUniformBuffer(gpu.getDevice(), SURFACE_PARAMS_SIZE);
        immutable float[16] zeroSurface = 0.0f;
        updateBuffer(gpu.getQueue(), m.surfaceBuf, zeroSurface[]);

        WGPUBindGroupEntry[MATERIAL_BINDING_COUNT] entries;
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

        entries[8].binding  = 8;
        entries[8].textureView = coat.view;
        entries[9].binding  = 9;
        entries[9].textureView = cnrm.view;
        entries[10].binding = 10;
        entries[10].textureView = fz.view;
        entries[11].binding = 11;
        entries[11].textureView = af.view;
        entries[12].binding = 12;
        entries[12].textureView = tr.view;

        WGPUBindGroupDescriptor desc;
        desc.layout     = layout;
        desc.entryCount = MATERIAL_BINDING_COUNT;
        desc.entries    = entries.ptr;

        m.bindGroup = wgpuDeviceCreateBindGroup(gpu.getDevice(), &desc);
        if (m.bindGroup is null) fatal("Failed to create Material bind group");
        return m;
    }

    private void setSpriteFlags(uint flags) nothrow @nogc {
        soft = (flags & MaterialFlags.soft) != 0;
        sprite = (flags & (MaterialFlags.soft | MaterialFlags.litParticle | MaterialFlags.flipbook)) != 0;
    }

    bool valid() const nothrow @nogc { return bindGroup !is null; }

    /// Upload new PBR params to the material UBO (live editor overrides).
    void updateParams(ref GpuContext gpu, MaterialParams params) nothrow @nogc @trusted {
        if (paramsBuf is null) return;
        transmissive = params.transmissionWeight > 0.0f
                    || (params.flags & MaterialFlags.transmission) != 0;
        ssr = (params.flags & MaterialFlags.ssr) != 0;
        setSpriteFlags(params.flags);
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
