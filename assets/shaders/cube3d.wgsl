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
