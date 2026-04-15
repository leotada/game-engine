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
