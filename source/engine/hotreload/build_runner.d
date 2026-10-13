/// Child process compilation runner and compiler diagnostic parser.
module engine.hotreload.build_runner;

import std.file : exists, mkdirRecurse, readText;
import std.process : executeShell, Config, spawnShell, tryWait, kill, Pid;
import std.stdio : File;
import std.string : splitLines, indexOf;
import std.conv : to;

@safe:

struct Diagnostic {
    string file;
    int line = 1;
    int column = 1;
    bool isError = true;
    string message;
}

struct BuildResult {
    bool success = false;
    int exitCode = -1;
    string rawOutput;
    Diagnostic[] diagnostics;
}

struct BuildRunner {
    string command = "dub build --config=game-module --compiler=dmd";
    string workingDir = ".";
    private string _logPath = ".engine/hotreload.log";
    private bool _active = false;
    private Pid _pid;

    bool active() const nothrow @nogc { return _active; }

    /// Start the build and return immediately. The UI thread must not block
    /// on the compiler — a synchronous dub build freezes the editor for seconds.
    /// The log `File` is closed after spawn; the child keeps its own dup.
    bool start() @trusted {
        if (_active) return false;
        try {
            if (!exists(".engine")) mkdirRecurse(".engine");
            auto log = File(_logPath, "w");
            _pid = spawnShell(command, File("/dev/null", "r"), log, log, null, Config.none, workingDir);
            log.flush();
            log.close();
            _active = true;
            return true;
        } catch (Exception) {
            _active = false;
            return false;
        }
    }

    /// Returns true when the background build has finished and `res` is filled.
    bool poll(out BuildResult res) @trusted {
        if (!_active) return false;
        auto st = tryWait(_pid);
        if (!st.terminated) return false;
        _active = false;
        res.exitCode = st.status;
        try res.rawOutput = readText(_logPath);
        catch (Exception) res.rawOutput = "";
        res.success = st.status == 0;
        res.diagnostics = parseDiagnostics(res.rawOutput);
        return true;
    }

    void cancel() @trusted {
        if (!_active) return;
        try kill(_pid);
        catch (Exception) {}
        _active = false;
    }

    BuildResult run() @trusted {
        BuildResult res;
        try {
            auto proc = executeShell(command, null, Config.none, size_t.max, workingDir);
            res.exitCode = proc.status;
            res.rawOutput = proc.output;
            res.success = (proc.status == 0);
            res.diagnostics = parseDiagnostics(proc.output);
        } catch (Exception e) {
            res.exitCode = -1;
            res.rawOutput = "Failed to execute build command: " ~ e.msg;
            res.success = false;
        }
        return res;
    }

    static Diagnostic[] parseDiagnostics(string output) {
        Diagnostic[] diags;
        foreach (line; output.splitLines()) {
            auto d = parseLine(line);
            if (d.file.length > 0) {
                diags ~= d;
            }
        }
        return diags;
    }

    private static Diagnostic parseLine(string line) {
        Diagnostic d;
        // Looking for pattern: <file>(<line>,<col>): <Error|Warning>: <msg>
        // Or: <file>(<line>): <Error|Warning>: <msg>
        auto parenOpen = line.indexOf('(');
        if (parenOpen <= 0) return d;

        auto parenClose = line.indexOf(')', parenOpen);
        if (parenClose <= parenOpen) return d;

        auto colonAfter = line.indexOf(':', parenClose);
        if (colonAfter <= parenClose) return d;

        string file = line[0 .. parenOpen];
        string posStr = line[parenOpen + 1 .. parenClose];
        string rest = line[colonAfter + 1 .. $];

        int lineNum = 1;
        int colNum = 1;
        auto comma = posStr.indexOf(',');
        if (comma > 0) {
            try {
                lineNum = posStr[0 .. comma].to!int();
                colNum = posStr[comma + 1 .. $].to!int();
            } catch (Exception) {}
        } else {
            try {
                lineNum = posStr.to!int();
            } catch (Exception) {}
        }

        bool isErr = (rest.indexOf("Error") >= 0 || rest.indexOf("error") >= 0);
        d.file = file;
        d.line = lineNum;
        d.column = colNum;
        d.isError = isErr;
        d.message = rest;
        return d;
    }
}
