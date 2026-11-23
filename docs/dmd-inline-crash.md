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

## Status on DMD 2.114.0

- **The `-inline` bug above is not fixed.** The minimal reproducer still segfaults with
  `dmd -c -inline repro.d` on 2.114.0. Keep the named-local workaround in `SimdFloat4.opBinary`.
- **Backend stack overflow on large CTFE shader strings got wider.** On 2.113 only
  `engine.water.renderer` hit it (worked around with module-level `immutable` copies). On 2.114 the
  plain debug build (no `-inline`) also crashed in `engine.gpu.sky`, `engine.graphics.decals` and
  `engine.terrain.renderer`. It is a stack overflow: the same modules compile under
  `ulimit -s unlimited`. Fix: every `preprocessShader(...)` result in `engine.gpu.shaders` is now an
  `immutable string` global instead of an `enum`, so the source is one symbol and not a literal
  pasted into each function that uses it. CTFE reads (`static assert`) still work.
  **Rule:** declare new large generated shader sources as `immutable string`, not `enum`.
- **Prebuilt D static libraries must be rebuilt after a DMD upgrade.** `libs/<target>/libsymgc-cards.a`
  built with 2.113 fails to link against the 2.114 druntime (undefined
  `core.thread.osthread.suspend`, `Thread.isRunning`, `ClassInfo for Thread`). Run
  `tools/build_symgc.sh dmd` (or `ldc2`) with the new compiler.
- To find a crashing module, compile each one separately with codegen enabled (a frontend-only
  `-o-` pass does not reproduce backend crashes):
  `dmd -c -od/tmp/x -g -debug -Isource -Ivendor/zipd -Jassets/shaders -preview=dip1000 <file>.d`.
