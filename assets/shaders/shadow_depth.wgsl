struct LightUniforms {
    lightViewProj: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> u: LightUniforms;
#ifdef SKINNED
@group(1) @binding(0) var<storage, read> skinPalettes: array<mat4x4<f32>>;
#endif

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) uv: vec2<f32>,
    @location(3) model0: vec4<f32>,
    @location(4) model1: vec4<f32>,
    @location(5) model2: vec4<f32>,
    @location(6) model3: vec4<f32>,
    @location(7) tint: vec4<f32>,
#ifdef SKINNED
    @location(10) joints: vec4<u32>,
    @location(11) weights: vec4<f32>,
#endif
};

@vertex
fn vs_main(in: VertexInput) -> @builtin(position) vec4<f32> {
#ifdef SKINNED
    let palBase = bitcast<u32>(in.model0.w) & 0xFFFFu;
    let instModel = mat4x4<f32>(
        vec4<f32>(in.model0.xyz, 0.0),
        vec4<f32>(in.model1.xyz, 0.0),
        vec4<f32>(in.model2.xyz, 0.0),
        vec4<f32>(in.model3.xyz, 1.0)
    );
    let skinMat = skinPalettes[palBase + in.joints.x] * in.weights.x
                + skinPalettes[palBase + in.joints.y] * in.weights.y
                + skinPalettes[palBase + in.joints.z] * in.weights.z
                + skinPalettes[palBase + in.joints.w] * in.weights.w;
    return u.lightViewProj * (instModel * (skinMat * vec4<f32>(in.position, 1.0)));
#else
    let model = mat4x4<f32>(in.model0, in.model1, in.model2, in.model3);
    return u.lightViewProj * model * vec4<f32>(in.position, 1.0);
#endif
}
