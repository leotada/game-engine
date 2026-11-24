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

    void putUnsigned(ulong v, uint base, uint width, bool zeroPad, bool negative) nothrow @nogc {
        char[20] digits = void;
        size_t d = 0;
        do {
            digits[d++] = "0123456789abcdef"[cast(size_t)(v % base)];
            v /= base;
        } while (v > 0);
        immutable size_t used = d + (negative ? 1 : 0);
        immutable size_t pad = width > used ? width - used : 0;
        if (!zeroPad) foreach (_; 0 .. pad) putChar(' ');
        if (negative) putChar('-');
        if (zeroPad) foreach (_; 0 .. pad) putChar('0');
        foreach_reverse (i; 0 .. d) putChar(digits[i]);
    }

    void putFloat(double v, int precision) nothrow @nogc {
        import core.stdc.stdio : snprintf;
        char[64] tmp = void;
        // Huge magnitudes would not fit in fixed notation: fall back to %g.
        immutable bool huge = v > 1e30 || v < -1e30;
        immutable n = huge
            ? snprintf(tmp.ptr, tmp.length, "%g", v)
            : snprintf(tmp.ptr, tmp.length, "%.*f", precision, v);
        if (n > 0)
            putString(tmp[0 .. n < cast(int) tmp.length ? n : tmp.length - 1]);
    }

    /// One argument; `conv` is the placeholder conversion ('s' when the argument is appended).
    void putArg(T)(T arg, char conv, uint width, bool zeroPad, int precision) nothrow @nogc {
        static if (is(T : const(char)[])) {
            putString(arg);
        } else static if (is(immutable T == immutable bool)) {
            putString(arg ? "true" : "false");
        } else static if (is(immutable T == immutable char)) {
            putChar(arg);
        } else static if (is(T : long)) {
            if (conv == 'x' || conv == 'X') {
                static if (T.sizeof <= 4)
                    putUnsigned(cast(uint) arg, 16, width, zeroPad, false);
                else
                    putUnsigned(cast(ulong) arg, 16, width, zeroPad, false);
            } else if (arg < 0) {
                // Negate through ulong: `-long.min` overflows.
                putUnsigned(-cast(ulong) cast(long) arg, 10, width, zeroPad, true);
            } else {
                putUnsigned(cast(ulong) arg, 10, width, zeroPad, false);
            }
        } else static if (is(T : double)) {
            putFloat(arg, precision >= 0 ? precision : 2);
        }
    }

    // `fmt` may hold printf-style placeholders (%s %d %i %u %x %f %g with optional zero flag, width and precision,
    // and %%). Arguments without a placeholder are appended. A '%' that is not a placeholder is printed as is.
    size_t used = 0;
    size_t i = 0;
    while (i < fmt.length) {
        if (fmt[i] != '%' || Args.length == 0) {
            putChar(fmt[i++]);
            continue;
        }
        size_t j = i + 1;
        if (j < fmt.length && fmt[j] == '%') {
            putChar('%');
            i = j + 1;
            continue;
        }
        bool zeroPad = false;
        uint width = 0;
        int precision = -1;
        if (j < fmt.length && fmt[j] == '0') { zeroPad = true; j++; }
        while (j < fmt.length && fmt[j] >= '0' && fmt[j] <= '9' && width < 100)
            width = width * 10 + (fmt[j++] - '0');
        if (j < fmt.length && fmt[j] == '.') {
            j++;
            precision = 0;
            while (j < fmt.length && fmt[j] >= '0' && fmt[j] <= '9' && precision < 10)
                precision = precision * 10 + (fmt[j++] - '0');
            if (precision > 20) precision = 20;
        }
        bool isConv = false;
        if (j < fmt.length) {
            switch (fmt[j]) {
                case 's', 'd', 'i', 'u', 'x', 'X', 'f', 'g': isConv = true; break;
                default: break;
            }
        }
        if (!isConv || used >= Args.length) {
            putChar(fmt[i++]);
            continue;
        }
        immutable char conv = fmt[j];
        static foreach (ai, arg; args) {
            if (used == ai)
                putArg(arg, conv, width, zeroPad, precision);
        }
        used++;
        i = j + 1;
    }
    static foreach (ai, arg; args) {
        if (ai >= used)
            putArg(arg, 's', 0, false, -1);
    }

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
    if (!cond) fatal("", msg);
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

@("log: printf placeholders, appended arguments and number formatting")
@safe unittest {
    static string last(Args...)(string fmt, Args args) {
        clearLogHistory();
        info(fmt, args);
        LogEntry[1] e;
        copyLogHistory(e);
        return e[0].text().idup;
    }
    assert(last("loaded %s (%d entities)", "a.json", 3) == "loaded a.json (3 entities)");
    assert(last("0x%08x", 0xABCDu) == "0x0000abcd");
    assert(last("%.3f|%5d|%%", 1.5, 42) == "1.500|   42|%");
    assert(last("half %d", 1, " tail ", 2) == "half 1 tail 2");
    // No placeholder / no argument left: printed as is.
    assert(last("100% of ", 5) == "100% of 5");
    assert(last("%s and %s", "x") == "x and %s");
    assert(last("raw %s") == "raw %s");
    assert(last("f=", 1.05f, " n=", -0.5f, " b=", true) == "f=1.05 n=-0.50 b=true");
    assert(last("", long.min) == "-9223372036854775808");
    assert(last("", ulong.max) == "18446744073709551615");
    assert(last("", 'c', float.infinity) == "cinf");
}
