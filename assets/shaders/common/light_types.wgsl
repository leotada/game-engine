/// Shared WGSL light & clustered-grid data types used by scene shaders and compute culling.

struct DirLight {
    direction: vec3<f32>,
    intensity: f32,
    color: vec3<f32>,
    castShadows: u32,
    viewProj: mat4x4<f32>,
};

struct PointLight {
    position: vec3<f32>,
    range: f32,
    color: vec3<f32>,
    intensity: f32,
    shadowSlot: i32,
    attenuation: f32,
    _pad1: f32,
    _pad2: f32,
};

struct SpotLight {
    position: vec3<f32>,
    range: f32,
    direction: vec3<f32>,
    intensity: f32,
    color: vec3<f32>,
    innerConeCos: f32,
    outerConeCos: f32,
    shadowSlot: i32,
    attenuation: f32,
    angleAttenuation: f32,
    viewProj: mat4x4<f32>,
};

struct ClusterRecord {
    offset: u32,
    pointCount: u32,
    spotCount: u32,
    _pad: u32,
};

const CLUSTER_GRID_X: u32 = 16u;
const CLUSTER_GRID_Y: u32 = 9u;
const CLUSTER_GRID_Z: u32 = 24u;
