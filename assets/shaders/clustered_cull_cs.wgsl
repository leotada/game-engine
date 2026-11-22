/// WGPU Compute shader for Clustered Forward light culling.
/// Dispatches one 64-thread workgroup per 3D frustum cluster `(16, 9, 24)`
/// to build compacted point/spot light lists in view space.

#include "common/light_types.wgsl"

struct ClusterCullUniforms {
    viewMatrix: mat4x4<f32>,
    invProj: mat4x4<f32>,
    nearZ: f32,
    farZ: f32,
    pointCount: u32,
    spotCount: u32,
    gridX: u32,
    gridY: u32,
    gridZ: u32,
    indexCapacity: u32,
};

struct ClusterState {
    globalOffset: atomic<u32>,
    overflowCount: atomic<u32>,
    _pad0: u32,
    _pad1: u32,
};

@group(0) @binding(0) var<uniform> U: ClusterCullUniforms;
@group(0) @binding(1) var<storage, read> pointLights: array<PointLight>;
@group(0) @binding(2) var<storage, read> spotLights: array<SpotLight>;
@group(0) @binding(3) var<storage, read_write> clusterGrid: array<ClusterRecord>;
@group(0) @binding(4) var<storage, read_write> clusterIndices: array<u32>;
@group(0) @binding(5) var<storage, read_write> clusterState: ClusterState;

const WORKGROUP_THREADS: u32 = 64u;
const MAX_POINTS_PER_WG: u32 = 1024u;
const MAX_SPOTS_PER_WG: u32 = 256u;

var<workgroup> wgMinAabb: vec3<f32>;
var<workgroup> wgMaxAabb: vec3<f32>;
var<workgroup> wgPointCount: atomic<u32>;
var<workgroup> wgSpotCount: atomic<u32>;
var<workgroup> wgBaseOffset: u32;
var<workgroup> wgStoredPoints: u32;
var<workgroup> wgStoredSpots: u32;
var<workgroup> wgPoints: array<u32, 1024>;
var<workgroup> wgSpots: array<u32, 256>;

fn unprojectCorner(ndcXY: vec2<f32>, ndcZ: f32) -> vec3<f32> {
    let h = U.invProj * vec4<f32>(ndcXY, ndcZ, 1.0);
    return h.xyz / h.w;
}

fn sphereIntersectsAabb(center: vec3<f32>, radius: f32, aabbMin: vec3<f32>, aabbMax: vec3<f32>) -> bool {
    let closest = clamp(center, aabbMin, aabbMax);
    let delta = center - closest;
    return dot(delta, delta) <= radius * radius;
}

/// Minimum enclosing bounding sphere of a finite spotlight cone: vec4(center, radius).
fn tightSpotBoundingSphere(apex: vec3<f32>, dir: vec3<f32>, range: f32, outerConeCos: f32) -> vec4<f32> {
    if (outerConeCos <= 0.0) {
        return vec4<f32>(apex, range);
    }
    // 1 / sqrt(2) ~= 0.70710678 (45 deg half-angle)
    if (outerConeCos < 0.70710678) {
        let sinTheta = sqrt(max(1.0 - outerConeCos * outerConeCos, 0.0));
        return vec4<f32>(apex + dir * (range * outerConeCos), range * sinTheta);
    }
    let radius = range / max(2.0 * outerConeCos, 1e-4);
    return vec4<f32>(apex + dir * radius, radius);
}

fn aabbMaxDot(aabbMin: vec3<f32>, aabbMax: vec3<f32>, dir: vec3<f32>) -> f32 {
    let extreme = vec3<f32>(
        select(aabbMin.x, aabbMax.x, dir.x >= 0.0),
        select(aabbMin.y, aabbMax.y, dir.y >= 0.0),
        select(aabbMin.z, aabbMax.z, dir.z >= 0.0),
    );
    return dot(extreme, dir);
}

@compute @workgroup_size(1, 1, 1)
fn cs_reset() {
    atomicStore(&clusterState.globalOffset, 0u);
    atomicStore(&clusterState.overflowCount, 0u);
}

@compute @workgroup_size(64, 1, 1)
fn cs_cull(
    @builtin(workgroup_id) wid: vec3<u32>,
    @builtin(local_invocation_index) lidx: u32
) {
    if (wid.x >= U.gridX || wid.y >= U.gridY || wid.z >= U.gridZ) {
        return;
    }

    let clusterIdx = wid.x + wid.y * U.gridX + wid.z * (U.gridX * U.gridY);

    if (lidx == 0u) {
        let nearZ = max(U.nearZ, 0.001);
        let farZ = max(U.farZ, nearZ + 0.1);
        let zRatio = farZ / nearZ;
        let invNZ = 1.0 / f32(max(U.gridZ, 1u));
        let d0 = nearZ * pow(zRatio, f32(wid.z) * invNZ);
        let d1 = nearZ * pow(zRatio, f32(wid.z + 1u) * invNZ);
        let zSpan = max(farZ - nearZ, 1e-4);
        let t0 = (d0 - nearZ) / zSpan;
        let t1 = (d1 - nearZ) / zSpan;

        let u0 = f32(wid.x) / f32(max(U.gridX, 1u));
        let u1 = f32(wid.x + 1u) / f32(max(U.gridX, 1u));
        let v0 = f32(wid.y) / f32(max(U.gridY, 1u));
        let v1 = f32(wid.y + 1u) / f32(max(U.gridY, 1u));

        // WebGPU framebuffer origin is top-left: UV y=0 maps to NDC y=+1, y=1 maps to y=-1.
        let x0 = u0 * 2.0 - 1.0;
        let x1 = u1 * 2.0 - 1.0;
        let yTop = 1.0 - v0 * 2.0;
        let yBot = 1.0 - v1 * 2.0;

        let n00 = unprojectCorner(vec2<f32>(x0, yBot), 0.0);
        let n10 = unprojectCorner(vec2<f32>(x1, yBot), 0.0);
        let n01 = unprojectCorner(vec2<f32>(x0, yTop), 0.0);
        let n11 = unprojectCorner(vec2<f32>(x1, yTop), 0.0);

        let f00 = unprojectCorner(vec2<f32>(x0, yBot), 1.0);
        let f10 = unprojectCorner(vec2<f32>(x1, yBot), 1.0);
        let f01 = unprojectCorner(vec2<f32>(x0, yTop), 1.0);
        let f11 = unprojectCorner(vec2<f32>(x1, yTop), 1.0);

        let c0 = mix(n00, f00, t0);
        let c1 = mix(n10, f10, t0);
        let c2 = mix(n01, f01, t0);
        let c3 = mix(n11, f11, t0);
        let c4 = mix(n00, f00, t1);
        let c5 = mix(n10, f10, t1);
        let c6 = mix(n01, f01, t1);
        let c7 = mix(n11, f11, t1);

        wgMinAabb = min(min(min(c0, c1), min(c2, c3)), min(min(c4, c5), min(c6, c7)));
        wgMaxAabb = max(max(max(c0, c1), max(c2, c3)), max(max(c4, c5), max(c6, c7)));
        atomicStore(&wgPointCount, 0u);
        atomicStore(&wgSpotCount, 0u);
    }
    workgroupBarrier();

    let aabbMin = wgMinAabb;
    let aabbMax = wgMaxAabb;
    let maxP = min(U.pointCount, arrayLength(&pointLights));
    for (var i = lidx; i < maxP; i += WORKGROUP_THREADS) {
        let pl = pointLights[i];
        if (pl.range <= 0.0 || pl.intensity <= 0.0) {
            continue;
        }
        let posVS = (U.viewMatrix * vec4<f32>(pl.position, 1.0)).xyz;
        if (sphereIntersectsAabb(posVS, pl.range, aabbMin, aabbMax)) {
            let slot = atomicAdd(&wgPointCount, 1u);
            if (slot < MAX_POINTS_PER_WG) {
                wgPoints[slot] = i;
            }
        }
    }

    let maxS = min(U.spotCount, arrayLength(&spotLights));
    for (var j = lidx; j < maxS; j += WORKGROUP_THREADS) {
        let sl = spotLights[j];
        if (sl.range <= 0.0 || sl.intensity <= 0.0) {
            continue;
        }
        let apexVS = (U.viewMatrix * vec4<f32>(sl.position, 1.0)).xyz;
        let dirVS = normalize((U.viewMatrix * vec4<f32>(sl.direction, 0.0)).xyz);
        if (sl.outerConeCos > 0.0 && aabbMaxDot(aabbMin, aabbMax, dirVS) < dot(apexVS, dirVS) - 1e-3) {
            continue;
        }
        let bs = tightSpotBoundingSphere(apexVS, dirVS, sl.range, sl.outerConeCos);
        if (sphereIntersectsAabb(bs.xyz, bs.w, aabbMin, aabbMax)) {
            let slot = atomicAdd(&wgSpotCount, 1u);
            if (slot < MAX_SPOTS_PER_WG) {
                wgSpots[slot] = j;
            }
        }
    }
    workgroupBarrier();

    if (lidx == 0u) {
        let rawP = atomicLoad(&wgPointCount);
        let rawS = atomicLoad(&wgSpotCount);
        if (rawP > MAX_POINTS_PER_WG || rawS > MAX_SPOTS_PER_WG) {
            atomicAdd(&clusterState.overflowCount, 1u);
        }
        let clampedP = min(rawP, MAX_POINTS_PER_WG);
        let clampedS = min(rawS, MAX_SPOTS_PER_WG);
        let wanted = clampedP + clampedS;
        var base = 0u;
        var pOut = 0u;
        var sOut = 0u;
        if (wanted > 0u) {
            base = atomicAdd(&clusterState.globalOffset, wanted);
            if (base < U.indexCapacity) {
                let avail = U.indexCapacity - base;
                pOut = min(clampedP, avail);
                sOut = min(clampedS, avail - pOut);
                if (pOut + sOut < wanted) {
                    atomicAdd(&clusterState.overflowCount, 1u);
                }
            } else {
                base = 0u;
                atomicAdd(&clusterState.overflowCount, 1u);
            }
        }
        wgBaseOffset = base;
        wgStoredPoints = pOut;
        wgStoredSpots = sOut;
        clusterGrid[clusterIdx] = ClusterRecord(base, pOut, sOut, 0u);
    }
    workgroupBarrier();

    let outBase = wgBaseOffset;
    let pOut = wgStoredPoints;
    let sOut = wgStoredSpots;
    for (var k = lidx; k < pOut; k += WORKGROUP_THREADS) {
        clusterIndices[outBase + k] = wgPoints[k];
    }
    for (var k = lidx; k < sOut; k += WORKGROUP_THREADS) {
        clusterIndices[outBase + pOut + k] = wgSpots[k];
    }
}
