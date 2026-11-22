# DMD 2.113 `-inline` crash (SIGSEGV) in the SIMD backend

## Symptom

`dub build --config=gesc --build=release` (and any other release build with DMD, because
`release` passes `-release -inline -O`) died with `/usr/bin/dmd failed with exit code -11`.
Peak memory was about 6.9 GB, so it was not an out-of-memory kill: the compiler itself segfaulted.

## Root cause

A DMD 2.113.0 inliner bug, independent of `-O` and `-release`; plain `-inline` is enough.
It was introduced into the engine by the `core.simd` backend (`engine.animation.math.simd_backend`,
commit `5935688`); it is unrelated to the clustered-light or GESC work.

The trigger is the combination of:

1. a struct holding an anonymous `union { struct { float x = 0, y = 0, z = 0, w = 0; } float4 v; }`;
2. a function that returns a constructor call of that struct (`return V(v * o.v);`), inlined;
3. the inlined call used as an argument of another struct literal (`Col(a * b, ...)`).

Minimal reproducer (`dmd -c -inline repro.d` segfaults):

```d
import core.simd;
struct V {
    union { struct { float x = 0, y = 0, z = 0, w = 0; } float4 v; }
    this(float4 vec) { v = vec; }
    V mul(V o) const { return V(v * o.v); }
}
struct C { V x, y, z, w; }
void f(ref C r, V a) { r = C(a.mul(a), a, a, a); }
```

Modules that failed to compile: `engine.animation.math.soa`, `engine.animation.local_to_model`,
`engine.animation.skeleton_utils` (and everything importing them, including the viatura-VI game).

## Fix

`SimdFloat4.opBinary` now builds the result in a named local (`SimdFloat4 r; r.v = ...; return r;`),
which the inliner handles. Behaviour and generated math are unchanged. The scalar backend
(`-version=EngineAnimScalarMath`) was never affected.

## Compiler policy

Release builds should use LDC2 (`--compiler=ldc2 --build=release`); DMD is for development.
If another DMD `-inline` crash shows up, bisect per module with
`dmd -c -of/tmp/x.o -inline -Isource -preview=dip1000 <file>.d`.
