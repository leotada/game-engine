// Auto exposure: log-luminance histogram of the HDR image, trimmed mean,
// adaptation of one value that stays on the GPU.

const BINS: u32 = 256u;
// Histogram weight of one pixel, split between the two nearest bins.
const UNIT: f32 = 16.0;

struct Params {
    // min EV, 1 / EV range, EV range, unused
    range: vec4<f32>,
    // low percentile, high percentile, key, reset (0 or 1)
    meter: vec4<f32>,
    // log2 min exposure, log2 max exposure, blend to bright, blend to dark
    adapt: vec4<f32>,
};

struct State {
    exposure: f32,
    logExposure: f32,
    averageLuminance: f32,
    valid: f32,
};

@group(0) @binding(0) var<uniform> p: Params;
@group(0) @binding(1) var hdrTex: texture_2d<f32>;
@group(0) @binding(2) var<storage, read_write> histogram: array<atomic<u32>, 256>;
@group(0) @binding(3) var<storage, read_write> state: State;

// One pixel of every 4x4, moving within the block along the image so that thin
// repeated features are not all hit or all missed.
@compute @workgroup_size(16, 16)
fn cs_histogram(@builtin(global_invocation_id) id: vec3<u32>) {
    let size = textureDimensions(hdrTex);
    let q = id.xy * 4u + vec2<u32>((id.x + id.y * 2u) & 3u, (id.x * 2u + id.y) & 3u);
    if (any(q >= size)) { return; }
    let c = textureLoad(hdrTex, q, 0).rgb;
    let lum = clamp(dot(c, vec3<f32>(0.2126, 0.7152, 0.0722)), 1e-9, 65504.0);
    let x = clamp((log2(lum) - p.range.x) * p.range.y, 0.0, 1.0) * f32(BINS - 1u);
    let bin = min(u32(x), BINS - 2u);
    let hi = u32(clamp((x - f32(bin)) * UNIT + 0.5, 0.0, UNIT));
    if (hi > 0u) { atomicAdd(&histogram[bin + 1u], hi); }
    if (hi < u32(UNIT)) { atomicAdd(&histogram[bin], u32(UNIT) - hi); }
}

@compute @workgroup_size(1)
fn cs_resolve() {
    var total = 0.0;
    for (var i = 0u; i < BINS; i++) { total += f32(atomicLoad(&histogram[i])); }
    let lo = total * p.meter.x;
    let hi = total * p.meter.y;
    var seen = 0.0;
    var sum = 0.0;
    var weight = 0.0;
    for (var i = 0u; i < BINS; i++) {
        let n = f32(atomicExchange(&histogram[i], 0u));
        let w = max(min(seen + n, hi) - max(seen, lo), 0.0);
        seen += n;
        sum += w * (p.range.x + f32(i) / f32(BINS - 1u) * p.range.z);
        weight += w;
    }
    if (weight <= 0.0) { return; }
    let average = sum / weight;
    let goal = clamp(log2(p.meter.z) - average, p.adapt.x, p.adapt.y);
    var e = goal;
    if (state.valid > 0.5 && p.meter.w < 0.5) {
        let blend = select(p.adapt.w, p.adapt.z, goal < state.logExposure);
        e = mix(state.logExposure, goal, blend);
    }
    state.logExposure = e;
    state.exposure = exp2(e);
    state.averageLuminance = exp2(average);
    state.valid = 1.0;
}
