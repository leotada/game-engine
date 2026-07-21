/// Engine-wide logging.
/// Outputs to stderr for immediate flushing.
module engine.core.log;

import core.stdc.stdio : fprintf, stderr, fflush;
import core.stdc.stdlib : abort;

@safe:

enum LogLevel {
    trace,
    info,
    warn,
    err,
    fatal,
}

private __gshared LogLevel g_minLevel = LogLevel.info;

void setLogLevel(LogLevel level) @trusted {
    g_minLevel = level;
}

void trace(Args...)(string fmt, Args args) nothrow @nogc { logImpl(LogLevel.trace, fmt, args); }
void info(Args...)(string fmt, Args args) nothrow @nogc  { logImpl(LogLevel.info,  fmt, args); }
void warn(Args...)(string fmt, Args args) nothrow @nogc  { logImpl(LogLevel.warn,  fmt, args); }
void err(Args...)(string fmt, Args args) nothrow @nogc   { logImpl(LogLevel.err,   fmt, args); }

void fatal(Args...)(string fmt, Args args) nothrow @nogc @trusted {
    logImpl(LogLevel.fatal, fmt, args);
    abort();
}

private void logImpl(Args...)(LogLevel level, string fmt, Args args) nothrow @nogc @trusted {
    if (level < g_minLevel) return;

    static immutable string[5] tags = ["TRACE", "INFO ", "WARN ", "ERROR", "FATAL"];

    fprintf(stderr, "[%.*s] ", cast(int) tags[level].length, tags[level].ptr);
    fprintf(stderr, "%.*s", cast(int) fmt.length, fmt.ptr);
    fprintf(stderr, "\n");
    fflush(stderr);
}

/// Assertion that always runs (debug + release).
void ensure(bool cond, string msg = "assertion failed") nothrow @nogc @trusted {
    if (!cond) fatal("%.*s", cast(int) msg.length, msg.ptr);
}
