/// WGSL shader source strings for the 3D instanced pipeline and 2D text pipeline.
module engine.gpu.shaders;

@safe:

/// 3D instanced shader: vertex position + normal (buffer 0),
/// model matrix as 4× vec4 columns (buffer 1, instance),
/// VP uniform (group 0, binding 0).
/// Fragment: directional lighting (N·L).
enum cube3dShaderSource = `
struct Uniforms {
    viewProj: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) model0: vec4<f32>,
    @location(3) model1: vec4<f32>,
    @location(4) model2: vec4<f32>,
    @location(5) model3: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) worldNormal: vec3<f32>,
    @location(1) color: vec3<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let model = mat4x4<f32>(in.model0, in.model1, in.model2, in.model3);
    let worldPos = model * vec4<f32>(in.position, 1.0);
    let normalMat = mat3x3<f32>(model[0].xyz, model[1].xyz, model[2].xyz);
    var out: VertexOutput;
    out.clipPos = u.viewProj * worldPos;
    out.worldNormal = normalize(normalMat * in.normal);
    // Derive color from normal for visual variety
    out.color = abs(in.normal) * 0.5 + vec3<f32>(0.3, 0.3, 0.4);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let lightDir = normalize(vec3<f32>(0.3, 1.0, 0.5));
    let ambient = 0.15;
    let diffuse = max(dot(in.worldNormal, lightDir), 0.0);
    let brightness = ambient + diffuse * 0.85;
    return vec4<f32>(in.color * brightness, 1.0);
}
`;

/// 3D instanced shader with per-instance color.
/// Same vertex layout as cube3dShaderSource but instance buffer adds a color vec4.
/// Instance buffer: model matrix (4× vec4, 64 bytes) + color (vec4, 16 bytes) = 80 bytes.
enum colored3dShaderSource = `
struct Uniforms {
    viewProj: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) model0: vec4<f32>,
    @location(3) model1: vec4<f32>,
    @location(4) model2: vec4<f32>,
    @location(5) model3: vec4<f32>,
    @location(6) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) worldNormal: vec3<f32>,
    @location(1) color: vec3<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let model = mat4x4<f32>(in.model0, in.model1, in.model2, in.model3);
    let worldPos = model * vec4<f32>(in.position, 1.0);
    let normalMat = mat3x3<f32>(model[0].xyz, model[1].xyz, model[2].xyz);
    var out: VertexOutput;
    out.clipPos = u.viewProj * worldPos;
    out.worldNormal = normalize(normalMat * in.normal);
    out.color = in.color.rgb;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let lightDir = normalize(vec3<f32>(0.3, 1.0, 0.5));
    let ambient = 0.18;
    let diffuse = max(dot(in.worldNormal, lightDir), 0.0);
    let brightness = ambient + diffuse * 0.82;
    return vec4<f32>(in.color * brightness, 1.0);
}
`;

/// 2D text shader: textured quads with alpha from R8 font atlas.
/// Vertex buffer: position (float32x2) + texcoord (float32x2).
/// Bind group 0: binding 0 = sampler, binding 1 = texture.
/// Uniform push: screen dimensions for orthographic projection.
enum text2dShaderSource = `
struct TextUniforms {
    screenSize: vec2<f32>,
};
@group(0) @binding(0) var<uniform> textU: TextUniforms;
@group(0) @binding(1) var fontSampler: sampler;
@group(0) @binding(2) var fontTexture: texture_2d<f32>;

struct TextVertexInput {
    @location(0) position: vec2<f32>,
    @location(1) texcoord: vec2<f32>,
};

struct TextVertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_text(in: TextVertexInput) -> TextVertexOutput {
    // Convert pixel coordinates to NDC: [0, screenW] → [-1, 1]
    let ndc = vec2<f32>(
        in.position.x / textU.screenSize.x * 2.0 - 1.0,
        1.0 - in.position.y / textU.screenSize.y * 2.0,
    );
    var out: TextVertexOutput;
    out.clipPos = vec4<f32>(ndc, 0.0, 1.0);
    out.uv = in.texcoord;
    return out;
}

@fragment
fn fs_text(in: TextVertexOutput) -> @location(0) vec4<f32> {
    let alpha = textureSample(fontTexture, fontSampler, in.uv).r;
    if (alpha < 0.5) {
        discard;
    }
    return vec4<f32>(1.0, 1.0, 1.0, alpha);
}
`;

/// 3D instanced PBR textured shader (metallic-roughness + PCF shadows + IBL).
/// Vertex buffer 0: position + normal + uv (stride 32).
/// Vertex buffer 1: model mat4 + tint (stride 80).
/// @group(0) Frame: FrameUniforms, comparison sampler, depth texture.
/// @group(1) Material: MaterialParams, sampler, albedo + optional maps.
/// @group(2) IBL: irradiance cube, prefiltered specular, BRDF LUT, sampler.
enum textured3dShaderSource = `
struct FrameUniforms {
    viewProj: mat4x4<f32>,
    lightViewProj: mat4x4<f32>,
    lightDir: vec3<f32>,
    shadowBias: f32,
    cameraPos: vec3<f32>,
    _pad0: f32,
};
@group(0) @binding(0) var<uniform> frame: FrameUniforms;
@group(0) @binding(1) var shadowSampler: sampler_comparison;
@group(0) @binding(2) var shadowMap: texture_depth_2d;

struct MaterialParams {
    baseColorFactor: vec4<f32>,
    metallic: f32,
    roughness: f32,
    flags: u32,
    _pad1: f32,
};
@group(1) @binding(0) var<uniform> mat: MaterialParams;
@group(1) @binding(1) var texSampler: sampler;
@group(1) @binding(2) var albedoMap: texture_2d<f32>;
@group(1) @binding(3) var mrMap: texture_2d<f32>;
@group(1) @binding(4) var normalMap: texture_2d<f32>;
@group(1) @binding(5) var occlusionMap: texture_2d<f32>;
@group(1) @binding(6) var emissiveMap: texture_2d<f32>;

@group(2) @binding(0) var irradianceMap: texture_cube<f32>;
@group(2) @binding(1) var specularMap: texture_cube<f32>;
@group(2) @binding(2) var brdfLut: texture_2d<f32>;
@group(2) @binding(3) var iblSampler: sampler;

const FLAG_MR: u32 = 1u;
const FLAG_NORMAL: u32 = 2u;
const FLAG_AO: u32 = 4u;
const FLAG_EMISSIVE: u32 = 8u;
const PI: f32 = 3.14159265359;
const SPECULAR_MIPS: f32 = 4.0;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) model0: vec4<f32>,
    @location(4) model1: vec4<f32>,
    @location(5) model2: vec4<f32>,
    @location(6) model3: vec4<f32>,
    @location(7) tint: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) worldPos: vec3<f32>,
    @location(1) worldNormal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) tint: vec3<f32>,
    @location(4) worldTangent: vec3<f32>,
    @location(5) worldBitangent: vec3<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let model = mat4x4<f32>(in.model0, in.model1, in.model2, in.model3);
    let worldPos4 = model * vec4<f32>(in.position, 1.0);
    let normalMat = mat3x3<f32>(model[0].xyz, model[1].xyz, model[2].xyz);
    var out: VertexOutput;
    out.clipPos = frame.viewProj * worldPos4;
    out.worldPos = worldPos4.xyz;
    out.worldNormal = normalize(normalMat * in.normal);
    // Approximate TBN from normal (no vertex tangents yet).
    var t = normalize(normalMat * vec3<f32>(1.0, 0.0, 0.0));
    if (abs(dot(t, out.worldNormal)) > 0.9) {
        t = normalize(normalMat * vec3<f32>(0.0, 0.0, 1.0));
    }
    out.worldTangent = normalize(t - out.worldNormal * dot(out.worldNormal, t));
    out.worldBitangent = cross(out.worldNormal, out.worldTangent);
    out.uv = in.uv;
    out.tint = in.tint.rgb;
    return out;
}

fn distributionGGX(NdotH: f32, roughness: f32) -> f32 {
    let a = roughness * roughness;
    let a2 = a * a;
    let d = NdotH * NdotH * (a2 - 1.0) + 1.0;
    return a2 / (PI * d * d);
}

fn geometrySchlickGGX(NdotX: f32, roughness: f32) -> f32 {
    let r = roughness + 1.0;
    let k = (r * r) / 8.0;
    return NdotX / (NdotX * (1.0 - k) + k);
}

fn geometrySmith(NdotV: f32, NdotL: f32, roughness: f32) -> f32 {
    return geometrySchlickGGX(NdotV, roughness) * geometrySchlickGGX(NdotL, roughness);
}

fn fresnelSchlick(cosTheta: f32, F0: vec3<f32>) -> vec3<f32> {
    return F0 + (1.0 - F0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

fn fresnelSchlickRoughness(cosTheta: f32, F0: vec3<f32>, roughness: f32) -> vec3<f32> {
    return F0 + (max(vec3<f32>(1.0 - roughness), F0) - F0)
         * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

fn sampleShadowPCF(worldPos: vec3<f32>) -> f32 {
    var shadowPos = frame.lightViewProj * vec4<f32>(worldPos, 1.0);
    let ndc = shadowPos.xyz / shadowPos.w;
    let uv = ndc.xy * vec2<f32>(0.5, -0.5) + vec2<f32>(0.5, 0.5);
    let depth = ndc.z;
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0 || depth <= 0.0 || depth >= 1.0) {
        return 1.0;
    }
    let texel = 1.0 / f32(textureDimensions(shadowMap).x);
    var shadow = 0.0;
    for (var y = -1; y <= 1; y++) {
        for (var x = -1; x <= 1; x++) {
            let offset = vec2<f32>(f32(x), f32(y)) * texel;
            shadow += textureSampleCompare(shadowMap, shadowSampler, uv + offset, depth - frame.shadowBias);
        }
    }
    return shadow / 9.0;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let albedoSample = textureSample(albedoMap, texSampler, in.uv);
    var albedo = albedoSample.rgb * mat.baseColorFactor.rgb * in.tint;
    var metallic = mat.metallic;
    var roughness = mat.roughness;
    if ((mat.flags & FLAG_MR) != 0u) {
        let mr = textureSample(mrMap, texSampler, in.uv);
        roughness = clamp(roughness * mr.g, 0.04, 1.0);
        metallic = clamp(metallic * mr.b, 0.0, 1.0);
    } else {
        roughness = clamp(roughness, 0.04, 1.0);
        metallic = clamp(metallic, 0.0, 1.0);
    }

    var N = normalize(in.worldNormal);
    if ((mat.flags & FLAG_NORMAL) != 0u) {
        let nSample = textureSample(normalMap, texSampler, in.uv).xyz * 2.0 - 1.0;
        let TBN = mat3x3<f32>(normalize(in.worldTangent), normalize(in.worldBitangent), N);
        N = normalize(TBN * nSample);
    }

    var ao = 1.0;
    if ((mat.flags & FLAG_AO) != 0u) {
        ao = textureSample(occlusionMap, texSampler, in.uv).r;
    }

    var emissive = vec3<f32>(0.0);
    if ((mat.flags & FLAG_EMISSIVE) != 0u) {
        emissive = textureSample(emissiveMap, texSampler, in.uv).rgb;
    }

    let V = normalize(frame.cameraPos - in.worldPos);
    let L = normalize(frame.lightDir);
    let H = normalize(V + L);
    let NdotL = max(dot(N, L), 0.0);
    let NdotV = max(dot(N, V), 0.001);
    let NdotH = max(dot(N, H), 0.0);
    let HdotV = max(dot(H, V), 0.0);

    let F0 = mix(vec3<f32>(0.04), albedo, metallic);
    let D = distributionGGX(NdotH, roughness);
    let G = geometrySmith(NdotV, NdotL, roughness);
    let F = fresnelSchlick(HdotV, F0);
    let specular = (D * G * F) / max(4.0 * NdotV * NdotL, 0.001);
    let kS = F;
    let kD = (vec3<f32>(1.0) - kS) * (1.0 - metallic);
    let radiance = vec3<f32>(1.0, 0.98, 0.92) * 3.5;
    let shadow = sampleShadowPCF(in.worldPos);
    let direct = (kD * albedo / PI + specular) * radiance * NdotL * shadow;

    // IBL
    let F_ibl = fresnelSchlickRoughness(NdotV, F0, roughness);
    let kD_ibl = (vec3<f32>(1.0) - F_ibl) * (1.0 - metallic);
    let irradiance = textureSample(irradianceMap, iblSampler, N).rgb;
    let diffuseIbl = kD_ibl * irradiance * albedo;
    let R = reflect(-V, N);
    let mip = roughness * SPECULAR_MIPS;
    let prefiltered = textureSampleLevel(specularMap, iblSampler, R, mip).rgb;
    let brdf = textureSample(brdfLut, iblSampler, vec2<f32>(NdotV, roughness)).rg;
    let specularIbl = prefiltered * (F_ibl * brdf.x + brdf.y);
    let ambient = (diffuseIbl + specularIbl) * ao;

    var color = direct + ambient + emissive;
    color = clamp(color, vec3<f32>(0.0), vec3<f32>(1.0));
    return vec4<f32>(color, albedoSample.a * mat.baseColorFactor.a);
}
`;

/// Depth-only shader for shadow map rendering. Uses the same vertex layout
/// as the textured 3D pipeline (TexVert buffer 0 + InstanceData buffer 1),
/// but reads only position + model matrix columns. The single uniform is
/// the light's view-projection matrix.
///
/// No fragment stage — writes depth only.
enum shadowDepthShaderSource = `
struct LightUniforms {
    lightViewProj: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> u: LightUniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) model0: vec4<f32>,
    @location(4) model1: vec4<f32>,
    @location(5) model2: vec4<f32>,
    @location(6) model3: vec4<f32>,
    @location(7) tint: vec4<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4<f32> {
    let model = mat4x4<f32>(in.model0, in.model1, in.model2, in.model3);
    return u.lightViewProj * model * vec4<f32>(in.position, 1.0);
}
`;

/// Unlit 3D line shader for debug gizmos. One buffer (buffer 0) with
/// position(float32x3) + color(float32x4) per vertex. Single uniform:
/// viewProj mat4x4. Topology: lineList. No depth testing (overlay).
enum gizmoLineShaderSource = `
struct Uniforms {
    viewProj: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    out.clipPos = u.viewProj * vec4<f32>(in.position, 1.0);
    out.color = in.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.color;
}
`;
