/// Mesh processing (pure-D meshoptimizer). M0 exports types, scratch, and quantize.
/// M1 adds index generation. `import engine` does not re-export this package until M3.
module engine.meshopt;

public import engine.meshopt.indexgen;
public import engine.meshopt.quantize;
public import engine.meshopt.scratch;
public import engine.meshopt.types;
