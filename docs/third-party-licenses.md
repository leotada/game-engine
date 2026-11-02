# Third-party licenses

## meshoptimizer

The mesh processing code under `source/engine/meshopt/` is a pure-D port of
[meshoptimizer](https://github.com/zeux/meshoptimizer) v1.3 (commit `9e1f07b`).
The upstream library is MIT licensed. The reference clone lives in gitignored
`ref/meshoptimizer/` and is never linked into the engine.

```
MIT License

Copyright (c) 2016-2026 Arseny Kapoulkine

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Test corpus

`assets/models/meshopt/pirate.obj` is upstream `demo/pirate.obj`.

```
Pirate by Clint Bellanger
https://opengameart.org/content/pirate
Distributed under CC-BY-SA 3.0
```

Procedural grid, sphere, torus, UV-seam, and soup meshes are generated in
tests and are not separate licensed assets. No scanned mesh is committed.
