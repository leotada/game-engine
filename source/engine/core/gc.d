/**
 * Selects the steadygc collector (vendor/symgc) for an executable.
 *
 * steadygc is a druntime plug-in: linking it in is not enough, druntime must
 * be told to use it through `rt_options`. That symbol has to exist exactly
 * once per executable, so it lives in a mixin the executable's main module
 * instantiates — never in a library module, which would force the collector
 * on every program that links the engine.
 *
 * ```d
 * import engine.core.gc : UseSteadyGC;
 * mixin UseSteadyGC;
 * ```
 *
 * The collector is compiled in only when the build defines `SteadyGC` (dub.json
 * does so on Linux x86-64, the one platform it has been measured on); on other
 * platforms the mixin is empty and the program uses druntime's GC.
 *
 * Switching at run time, with the same binary:
 *   `--DRT-gcopt=gc:conservative`  druntime's GC
 *   `--DRT-gcopt=gc:sdc`           steadygc, prints "using SYM GC!"
 *
 * Build in release mode: dub compiles the collector with the project's
 * settings, and a debug collector is slow. See vendor/symgc/guide/usage.md.
 */
module engine.core.gc;

@safe:

/// Instantiate once, at module scope, in the module that defines `main`.
mixin template UseSteadyGC()
{
    version (SteadyGC)
    {
        import symgc.gcobj;  // links the collector in
        extern(C) __gshared string[] rt_options = ["gcopt=gc:sdcq"];  // selects it, quietly
    }
}
