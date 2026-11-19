struct SpriteUniforms {
    viewProj: mat4x4<f32>,
};
@group(0) @binding(0) var<uniform> spriteU: SpriteUniforms;
@group(0) @binding(1) var spriteSampler: sampler;
@group(0) @binding(2) var spriteTexture: texture_2d<f32>;

struct SpriteVertexInput {
    @location(0) unitPos: vec2<f32>,
    @location(1) posSize: vec4<f32>,      // pos.x, pos.y, size.x, size.y
    @location(2) uvRect: vec4<f32>,       // u0, v0, u1, v1
    @location(3) color: vec4<f32>,        // r, g, b, a
    @location(4) originSinCos: vec4<f32>, // origin.x, origin.y, sin(rot), cos(rot)
};

struct SpriteVertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
};

@vertex
fn vs_sprite(in: SpriteVertexInput) -> SpriteVertexOutput {
    let local = (in.unitPos - in.originSinCos.xy) * in.posSize.zw;
    let s = in.originSinCos.z;
    let c = in.originSinCos.w;
    let rotated = vec2<f32>(
        local.x * c - local.y * s,
        local.x * s + local.y * c,
    );
    let worldPos = in.posSize.xy + rotated;

    var out: SpriteVertexOutput;
    out.clipPos = spriteU.viewProj * vec4<f32>(worldPos, 0.0, 1.0);
    out.uv = mix(in.uvRect.xy, in.uvRect.zw, in.unitPos);
    out.color = in.color;
    return out;
}

@fragment
fn fs_sprite(in: SpriteVertexOutput) -> @location(0) vec4<f32> {
    let tex = textureSample(spriteTexture, spriteSampler, in.uv) * in.color;
    if (tex.a <= 0.001) {
        discard;
    }
    return tex;
}
