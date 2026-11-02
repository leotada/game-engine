/// Mesh processing (pure-D meshoptimizer). M0 exports types, scratch, and quantize.
/// M1 adds index generation. M2 adds cache, overdraw, fetch, analysis, and strips.
/// M3 adds the import-time pipeline. M4 adds simplification. M8 adds tangents.
module engine.meshopt;

public import engine.meshopt.analyze;
public import engine.meshopt.indexgen;
public import engine.meshopt.overdraw;
public import engine.meshopt.pipeline;
public import engine.meshopt.quantize;
public import engine.meshopt.scratch;
public import engine.meshopt.simplify;
public import engine.meshopt.stripify;
public import engine.meshopt.tangent;
public import engine.meshopt.types;
public import engine.meshopt.vcache;
public import engine.meshopt.vfetch;
