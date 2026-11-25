// Scene inputs of a post pass (PostPassDesc.sceneInputs), @group(1).
// Depth is the scene depth buffer (0 = near, 1 = far / nothing drawn).
// View space looks down -Z; `uv` is the pass's 0..1 coordinate, y down.
struct SceneCamera {
    view: mat4x4<f32>,
    proj: mat4x4<f32>,
    viewProj: mat4x4<f32>,
    invView: mat4x4<f32>,
    invProj: mat4x4<f32>,
    invViewProj: mat4x4<f32>,
    // xyz = world position, w = seconds (`Scene3DTextured.setTime`)
    position: vec4<f32>,
    // x = near, y = far, z = 1 when a 3D scene was drawn this frame, w unused
    planes: vec4<f32>,
    // pixel rectangle of the scene in the depth buffer: x, y, width, height
    viewport: vec4<f32>,
};
@group(1) @binding(0) var<uniform> sceneCamera: SceneCamera;
@group(1) @binding(1) var sceneDepthTex: texture_depth_2d;
@group(1) @binding(2) var input0: texture_2d<f32>;
@group(1) @binding(3) var input1: texture_2d<f32>;
@group(1) @binding(4) var input2: texture_2d<f32>;
@group(1) @binding(5) var input3: texture_2d<f32>;

// Depth-buffer texel under `uv`.
fn scenePixel(uv: vec2<f32>) -> vec2<i32> {
    let size = vec2<i32>(textureDimensions(sceneDepthTex));
    return clamp(vec2<i32>(floor(uv * vec2<f32>(size))), vec2<i32>(0), size - vec2<i32>(1));
}

fn sceneDepthAt(p: vec2<i32>) -> f32 {
    let size = vec2<i32>(textureDimensions(sceneDepthTex));
    return textureLoad(sceneDepthTex, clamp(p, vec2<i32>(0), size - vec2<i32>(1)), 0);
}

fn sceneDepth(uv: vec2<f32>) -> f32 { return sceneDepthAt(scenePixel(uv)); }

// Positive distance along the view axis.
fn sceneLinearDepth(depth: f32) -> f32 {
    let n = sceneCamera.planes.x;
    let f = sceneCamera.planes.y;
    return n * f / (f - depth * (f - n));
}

// NDC of a depth-buffer pixel position (texel centers are at .5).
fn sceneNdc(pixel: vec2<f32>) -> vec2<f32> {
    let t = (pixel - sceneCamera.viewport.xy) / sceneCamera.viewport.zw;
    return vec2<f32>(t.x * 2.0 - 1.0, 1.0 - t.y * 2.0);
}

// View-space position of a depth-buffer texel.
fn sceneViewPosition(p: vec2<i32>) -> vec3<f32> {
    let h = sceneCamera.invProj * vec4<f32>(sceneNdc(vec2<f32>(p) + 0.5), sceneDepthAt(p), 1.0);
    return h.xyz / h.w;
}

fn sceneWorldPosition(p: vec2<i32>) -> vec3<f32> {
    let h = sceneCamera.invViewProj * vec4<f32>(sceneNdc(vec2<f32>(p) + 0.5), sceneDepthAt(p), 1.0);
    return h.xyz / h.w;
}

// View-space geometric normal from depth: on each axis the neighbor closest
// in depth is used, so edges do not bleed. Flat per triangle, no normal maps.
fn sceneViewNormal(p: vec2<i32>) -> vec3<f32> {
    let c = sceneViewPosition(p);
    let l = sceneViewPosition(p - vec2<i32>(1, 0));
    let r = sceneViewPosition(p + vec2<i32>(1, 0));
    let u = sceneViewPosition(p - vec2<i32>(0, 1));
    let d = sceneViewPosition(p + vec2<i32>(0, 1));
    let dx = select(r - c, c - l, abs(l.z - c.z) < abs(r.z - c.z));
    let dy = select(d - c, c - u, abs(u.z - c.z) < abs(d.z - c.z));
    let n = normalize(cross(dy, dx));
    return select(n, -n, dot(n, c) > 0.0);
}

fn sceneWorldNormal(p: vec2<i32>) -> vec3<f32> {
    return normalize((sceneCamera.invView * vec4<f32>(sceneViewNormal(p), 0.0)).xyz);
}
