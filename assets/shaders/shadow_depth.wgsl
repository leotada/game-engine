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
