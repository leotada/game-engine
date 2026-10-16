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
