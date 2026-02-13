# Game Engine

A high-performance game engine built in D using **Data-Oriented Design** and **compile-time metaprogramming** for zero-overhead ECS architecture.

## Performance

**Benchmark Results** (Release build, 17k active entities):
- **268.6 FPS** average
- **0.78 ms** max GC pause time
- **3.72 ms** average frame time
- **188k entities** created over 20 seconds

## Architecture

### Data-Oriented ECS with Metaprogramming

This engine uses **compile-time code generation** to eliminate virtual dispatch and maximize cache locality:

- **Components** are POD structs in contiguous arrays (cache-friendly)
- **Registry** uses variadic templates to generate stores at compile time
- **Systems** are template functions (zero vtable overhead)
- **Entities** are just `uint` IDs (no heap allocations)
- **Sparse Set** for O(1) component lookup without hash maps

```
source/
├── app.d                  # Main entry point with game loop
├── benchmark.d            # Performance benchmark (20s stress test)
├── ecs/
│   ├── package.d          # ECS public exports
│   ├── store.d            # ComponentStore(T) with sparse set
│   └── registry.d         # Registry!(Components...) variadic template
├── component/
│   ├── package.d          # Component exports
│   ├── position.d         # Position struct (x, y, z)
│   ├── particle.d         # Particle physics struct
│   ├── circle.d           # Circle rendering struct
│   └── timeout.d          # Timeout lifecycle struct
├── system/
│   ├── package.d          # System exports
│   ├── particle.d         # Physics system (template function)
│   ├── timeout.d          # Timeout system (template function)
│   └── circle.d           # Circle renderer (struct with template method)
├── math/
│   └── vector.d           # 3D Vector math (POD struct)
└── docs/
    └── why-this-is-fast.md  # Performance explanation for Python programmers
```

### Key Optimizations

1. **Cache Locality**: All components of the same type stored contiguously in `T[]` arrays
2. **Sparse Set**: O(1) component access via `sparse[entityId] → dense[idx]` (no hash maps)
3. **Compile-Time Dispatch**: `Registry!(Position, Particle, Circle, Timeout)` generates specialized stores
4. **Template Systems**: Systems are template functions resolved at compile time (no vtable)

See [docs/why-this-is-fast.md](docs/why-this-is-fast.md) for detailed explanation.

## Requirements

- D compiler (DMD, LDC, or GDC)
- [DUB](https://dub.pm/) package manager
- [Raylib](https://www.raylib.com/) library (version 5.0+)

## Building

```bash
# Build the project
dub build

# Build with optimizations
dub build --build=release

# Run the demo
dub run

# Run benchmark (20 second stress test)
dub run --config=benchmark --build=release

# Run unit tests
dub test
```

## Demo

The default demo spawns 600 particles with gravity that timeout after 2 seconds.

The benchmark spawns particles continuously from 7 fountain points, stress-testing the ECS with thousands of active entities.

## GC and Real-Time Performance

This engine proves that **GC + real-time is viable** with proper architecture:

- **0.78 ms max pause** (vs 16.6 ms frame budget at 60 FPS)
- **Struct-based DOD** reduces GC scan from ~100k objects to ~10 objects
- **No manual memory management** needed — GC overhead is negligible

The key: keep hot data in structs/arrays, not classes on the heap.

## License

Proprietary - Copyright © 2022, Leonardo Tada
