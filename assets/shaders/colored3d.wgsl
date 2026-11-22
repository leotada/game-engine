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
    let c0 = model[0].xyz;
    let c1 = model[1].xyz;
    let c2 = model[2].xyz;
    let n0 = cross(c1, c2);
    let n1 = cross(c2, c0);
    let n2 = cross(c0, c1);
    let det = dot(c0, n0);
    var normalMat = mat3x3<f32>(c0, c1, c2);
    if (abs(det) > 1e-12) {
        normalMat = mat3x3<f32>(n0, n1, n2) * select(1.0, -1.0, det < 0.0);
    }
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
