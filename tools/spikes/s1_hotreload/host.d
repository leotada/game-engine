module host;

import core.runtime : Runtime;
import core.memory : GC;
import core.sys.posix.dlfcn;
import std.file : copy, remove, exists;
import std.format : format;
import std.stdio : writeln, writefln;

alias GameTickFn = extern(C) int function(int);

void main() {
    writeln("Iniciando spike S1: teste de hot-reload com DMD...");

    enum cycles = 50;
    foreach (i; 0 .. cycles) {
        string soName = format("tools/spikes/s1_hotreload/libgame_inst_%d.so", i);
        copy("tools/spikes/s1_hotreload/libgame.so", soName);
        scope(exit) {
            if (exists(soName)) remove(soName);
        }

        void* handle = Runtime.loadLibrary(soName);
        if (handle is null) {
            writefln("ERRO no ciclo %d: falha ao carregar %s", i, soName);
            assert(false);
        }

        auto fn = cast(GameTickFn) dlsym(handle, "game_tick");
        if (fn is null) {
            writefln("ERRO no ciclo %d: símbolo não encontrado", i);
            assert(false);
        }

        int res = fn(i);
        assert(res == i * 2 + 1);

        bool unloaded = Runtime.unloadLibrary(handle);
        if (!unloaded) {
            writefln("ERRO no ciclo %d: falha ao descarregar", i);
            assert(false);
        }

        // Executa GC para verificar se o descarregamento não corrompe a heap
        if (i % 10 == 0) {
            GC.collect();
        }
    }

    GC.collect();
    writeln("Spike S1 concluído com SUCESSO: 50 ciclos de load/unload/GC executados sem falhas!");
}
