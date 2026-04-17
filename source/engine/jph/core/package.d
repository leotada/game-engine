// Re-export of the engine.jph.core sub-modules.
module engine.jph.core;

public import engine.jph.core.types;
public import engine.jph.core.noncopyable;
public import engine.jph.core.memory;
public import engine.jph.core.atomics;
// engine.jph.core.color is intentionally NOT re-exported here: its `Color`
// struct collides with engine.gpu.renderer.Color. Modules that need it
// (jobsystem, debug renderer) import it explicitly.
public import engine.jph.core.profiler;
public import engine.jph.core.reference;
public import engine.jph.core.staticarray;
public import engine.jph.core.array;
public import engine.jph.core.tempallocator;
public import engine.jph.core.jobsystem : JobSystem, JobSystemSingleThreaded,
    JobHandle, Barrier, JobFunction, Job;
