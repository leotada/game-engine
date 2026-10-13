/// Engine-wide logging.
/// Outputs to stderr for immediate flushing and records entries into an in-memory
/// ring buffer for the editor Console panel.
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

struct LogEntry {
    LogLevel level = LogLevel.info;
    char[256] message = void;
    uint len = 0;

    const(char)[] text() return const nothrow @nogc pure {
        return message[0 .. len];
    }
}

enum size_t LOG_HISTORY_CAPACITY = 256;

private __gshared LogLevel g_minLevel = LogLevel.info;
private __gshared LogEntry[LOG_HISTORY_CAPACITY] g_logHistory;
private __gshared size_t g_logHead = 0;
private __gshared size_t g_logCount = 0;

void setLogLevel(LogLevel level) nothrow @nogc @trusted {
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

/// Copies recent log entries to `outEntries`. Returns total active entries.
size_t copyLogHistory(scope LogEntry[] outEntries) nothrow @nogc @trusted {
    immutable total = g_logCount < LOG_HISTORY_CAPACITY ? g_logCount : LOG_HISTORY_CAPACITY;
    immutable n = outEntries.length < total ? outEntries.length : total;

    size_t startIdx = (g_logHead + LOG_HISTORY_CAPACITY - total) % LOG_HISTORY_CAPACITY;
    foreach (i; 0 .. n) {
        outEntries[i] = g_logHistory[(startIdx + i) % LOG_HISTORY_CAPACITY];
    }
    return total;
}

/// Clears in-memory log history.
void clearLogHistory() nothrow @nogc @trusted {
    g_logHead = 0;
    g_logCount = 0;
}

private void logImpl(Args...)(LogLevel level, string fmt, Args args) nothrow @nogc @trusted {
    if (level < g_minLevel) return;

    static immutable string[5] tags = ["TRACE", "INFO ", "WARN ", "ERROR", "FATAL"];

    // Format into fixed buffer
    char[256] buf = void;
    size_t p = 0;

    void putChar(char c) nothrow @nogc {
        if (p < buf.length) buf[p++] = c;
    }

    void putString(scope const(char)[] s) nothrow @nogc {
        foreach (c; s) putChar(c);
    }

    void putInt(long v) nothrow @nogc {
        if (v == 0) { putChar('0'); return; }
        if (v < 0) { putChar('-'); v = -v; }
        char[20] digits = void;
        size_t d = 0;
        while (v > 0) {
            digits[d++] = cast(char)('0' + (v % 10));
            v /= 10;
        }
        foreach_reverse (i; 0 .. d) putChar(digits[i]);
    }

    putString(fmt);

    static foreach (arg; args) {{
        alias T = typeof(arg);
        static if (is(T : const(char)[])) {
            putString(arg);
        } else static if (is(T : long)) {
            putInt(arg);
        } else static if (is(T : double) || is(T : float)) {
            // Simple float formatting
            long whole = cast(long) arg;
            putInt(whole);
            putChar('.');
            double frac = arg - cast(double) whole;
            if (frac < 0) frac = -frac;
            putInt(cast(long)(frac * 100.0) % 100);
        } else static if (is(T == bool)) {
            putString(arg ? "true" : "false");
        }
    }}

    // Output to stderr
    fprintf(stderr, "[%.*s] %.*s\n", cast(int) tags[level].length, tags[level].ptr, cast(int) p, buf.ptr);
    fflush(stderr);

    // Save into history ring buffer
    LogEntry entry;
    entry.level = level;
    entry.len = cast(uint) p;
    entry.message[0 .. p] = buf[0 .. p];

    g_logHistory[g_logHead] = entry;
    g_logHead = (g_logHead + 1) % LOG_HISTORY_CAPACITY;
    g_logCount++;
}

/// Assertion that always runs (debug + release).
void ensure(bool cond, string msg = "assertion failed") nothrow @nogc @trusted {
    if (!cond) fatal("%.*s", cast(int) msg.length, msg.ptr);
}

@safe unittest {
    clearLogHistory();
    info("Test message ", 42, " extra");

    LogEntry[10] entries;
    size_t count = copyLogHistory(entries);
    assert(count == 1);
    assert(entries[0].text() == "Test message 42 extra");
    assert(entries[0].level == LogLevel.info);
}
