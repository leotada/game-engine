// Linear-blend skinning: up to 4 influences per vertex, palette in a read-only storage buffer.
// Palette entry j = jointModelMatrix[j] * inverseBind[j] (see engine.animation.ecs.skinPaletteSystem).
struct Uniforms {
    viewProj: mat4x4<f32>,
    color: vec4<f32>,
    lightDir: vec4<f32>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;
@group(0) @binding(1) var<storage, read> palette: array<mat4x4<f32>>;

struct VertexInput {
    @location(0) position: vec3<f32>,
    @location(1) normal: vec3<f32>,
    @location(2) joints: vec4<u32>,
    @location(3) weights: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) normal: vec3<f32>,
};

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    let skin = palette[in.joints.x] * in.weights.x
             + palette[in.joints.y] * in.weights.y
             + palette[in.joints.z] * in.weights.z
             + palette[in.joints.w] * in.weights.w;
    var out: VertexOutput;
    out.clipPos = u.viewProj * (skin * vec4<f32>(in.position, 1.0));
    // Uniform scale assumed for normals (rigid or near-rigid skeletons).
    out.normal = (skin * vec4<f32>(in.normal, 0.0)).xyz;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let n = normalize(in.normal);
    let diffuse = max(dot(n, normalize(-u.lightDir.xyz)), 0.0);
    return vec4<f32>(u.color.rgb * (0.25 + 0.75 * diffuse), u.color.a);
}
