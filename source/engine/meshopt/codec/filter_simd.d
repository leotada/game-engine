// Ported from meshoptimizer v1.3 (src/vertexfilter.cpp), Copyright (c) 2016-2026 Arseny Kapoulkine, MIT License.
/// Filter SIMD decode is not enabled.
///
/// Upstream `decodeFilterOct` for 8-bit data uses `_mm_rsqrt_ps`, which is not
/// bit-exact with the scalar `SIMD_FALLBACK` path the goldens are checked
/// against. Shipping that kernel would make LDC loads disagree with DMD and
/// with the scalar C++ oracle. The scalar filters in `filter.d` are what both
/// compilers run. On this host the scalar octahedral decode is faster than the
/// C++ scalar build; it does not reach the C++ rsqrt SIMD rate. That miss is
/// recorded in docs/plan-meshoptimizer.md and is not claimed as a pass.
module engine.meshopt.codec.filter_simd;

@safe:
