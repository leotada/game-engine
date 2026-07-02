module bindings.box3d.callbacks;

import bindings.box3d.raw;

@safe:

alias Box3DTaskCallback = b3TaskCallback;
alias Box3DEnqueueTaskCallback = b3EnqueueTaskCallback;
alias Box3DFinishTaskCallback = b3FinishTaskCallback;

alias Box3DCustomFilterCallback = b3CustomFilterFcn;
alias Box3DPreSolveCallback = b3PreSolveFcn;
alias Box3DOverlapResultCallback = b3OverlapResultFcn;
alias Box3DCastResultCallback = b3CastResultFcn;
alias Box3DFrictionCallback = b3FrictionCallback;
alias Box3DRestitutionCallback = b3RestitutionCallback;

// All callback implementations passed to Box3D must be extern(C) nothrow @nogc.
// Threaded callbacks must not mutate the Box3D world. Context pointers must refer
// to POD or pre-allocated engine memory, not GC-owned objects.
