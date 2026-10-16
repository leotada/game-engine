struct UiUniforms {
    screenSize: vec2<f32>,
};
@group(0) @binding(0) var<uniform> uiU: UiUniforms;
@group(0) @binding(1) var uiSampler: sampler;
@group(0) @binding(2) var uiTexture: texture_2d<f32>;

struct UiVertexInput {
    @location(0) position: vec2<f32>,
    @location(1) uv: vec2<f32>,
    @location(2) color: vec4<f32>,
    @location(3) rectParams: vec4<f32>,
    @location(4) localPos: vec2<f32>,
    @location(5) borderColor: vec4<f32>,
    @location(6) mode: f32,
};

struct UiVertexOutput {
    @builtin(position) clipPos: vec4<f32>,
    @location(0) uv: vec2<f32>,
    @location(1) color: vec4<f32>,
    @location(2) rectParams: vec4<f32>,
    @location(3) localPos: vec2<f32>,
    @location(4) borderColor: vec4<f32>,
    @location(5) mode: f32,
};

@vertex
fn vs_ui(in: UiVertexInput) -> UiVertexOutput {
    let ndc = vec2<f32>(
        in.position.x / uiU.screenSize.x * 2.0 - 1.0,
        1.0 - in.position.y / uiU.screenSize.y * 2.0
    );
    var out: UiVertexOutput;
    out.clipPos = vec4<f32>(ndc, 0.0, 1.0);
    out.uv = in.uv;
    out.color = in.color;
    out.rectParams = in.rectParams;
    out.localPos = in.localPos;
    out.borderColor = in.borderColor;
    out.mode = in.mode;
    return out;
}

@fragment
fn fs_ui(in: UiVertexOutput) -> @location(0) vec4<f32> {
    if (in.mode < 0.5) {
        // Mode 0: Solid / Rounded Rectangle with SDF antialiasing
        let halfSize = in.rectParams.xy * 0.5;
        let r = min(in.rectParams.z, min(halfSize.x, halfSize.y));
        let borderW = in.rectParams.w;
        let q = abs(in.localPos) - halfSize + vec2<f32>(r, r);
        let dist = length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - r;
        let alpha = clamp(0.5 - dist, 0.0, 1.0);
        if (alpha <= 0.0) {
            discard;
        }

        var col = in.color;
        if (borderW > 0.0) {
            let innerDist = dist + borderW;
            let borderFactor = clamp(innerDist + 0.5, 0.0, 1.0);
            col = mix(in.color, in.borderColor, borderFactor);
        }
        return vec4<f32>(col.rgb, col.a * alpha);
    } else if (in.mode < 1.5) {
        // Mode 1: Font glyph (R8 alpha mask)
        let alphaMask = textureSample(uiTexture, uiSampler, in.uv).r;
        let finalA = in.color.a * alphaMask;
        if (finalA <= 0.01) {
            discard;
        }
        return vec4<f32>(in.color.rgb, finalA);
    } else {
        // Mode 2: RGBA Texture / Image
        let tex = textureSample(uiTexture, uiSampler, in.uv);
        return tex * in.color;
    }
}
