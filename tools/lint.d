// GC-safe storage lint for engine sources.
//
// Walks source/engine/**/*.d (excluding jph/) and fails if a struct
// field looks like a GC-traced indirection (string, wstring, dstring,
// or delegate).
//
// Usage:  dub run --config=lint
//
// See docs/gc-safe-architecture-plan.md section 2.5 / section 5 step 4.
module tools.lint;

import std.algorithm : canFind, endsWith, startsWith;
import std.file      : dirEntries, readText, SpanMode;
import std.format    : format;
import std.path      : buildNormalizedPath, relativePath;
import std.regex     : ctRegex, matchFirst;
import std.stdio     : stderr, writeln, writefln;
import std.string    : indexOf, strip, splitLines;

@safe:

private enum engineRoot = "source/engine";

private immutable stringFieldRe = ctRegex!(
    r"(?:^|\s|;|\{)\s*(?:private|public|package|export|protected)?\s*"
    ~ r"(?:shared\s+|immutable\s+|const\s+)*"
    ~ r"(string|wstring|dstring)\s+\w+\s*[;=]");

private immutable delegateFieldRe = ctRegex!(
    r"\bdelegate\b");

struct Finding
{
    string file;
    size_t line;
    string message;
}

void main() @trusted
{
    Finding[] findings;
    immutable root = buildNormalizedPath(engineRoot);

    foreach (entry; dirEntries(root, "*.d", SpanMode.depth))
    {
        immutable rel = relativePath(entry.name);
        if (rel.canFind("/jph/") || rel.startsWith("jph/")
            || rel.canFind("\\jph\\"))
            continue;

        scanFile(entry.name, rel, findings);
    }

    if (findings.length == 0)
    {
        writeln("lint: ok - no GC-traced fields in engine storage structs");
        return;
    }

    stderr.writeln("lint: GC-safe violations:");
    foreach (f; findings)
        stderr.writefln("  %s:%s: %s", f.file, f.line, f.message);
    stderr.writefln("lint: %s violation(s)", findings.length);
    import core.stdc.stdlib : exit;
    exit(1);
}

private void scanFile(string path, string rel, ref Finding[] findings) @trusted
{
    immutable text = readText(path);
    auto lines = text.splitLines;

    bool inStruct;
    bool inUnittest;
    string structName;
    int braceDepth;
    int unittestDepth;
    int absoluteDepth;

    foreach (i, line; lines)
    {
        immutable ln = i + 1;
        immutable trimmed = line.strip;

        immutable prevAbs = absoluteDepth;
        foreach (c; line)
        {
            if (c == '{') absoluteDepth++;
            else if (c == '}') absoluteDepth--;
        }

        // Attribute-prefixed unittests: `@safe nothrow unittest {`
        if (!inUnittest && (trimmed.startsWith("unittest")
                || trimmed.endsWith("unittest")
                || trimmed.canFind(" unittest")))
        {
            inUnittest = true;
            unittestDepth = prevAbs;
            continue;
        }
        if (inUnittest)
        {
            if (absoluteDepth <= unittestDepth)
                inUnittest = false;
            else
                continue;
        }

        if (!inStruct)
        {
            auto m = matchFirst(trimmed, ctRegex!(r"^(?:private|public|package|export)?\s*"
                                                   ~ r"struct\s+(\w+)"));
            if (!m)
                continue;

            inStruct = true;
            structName = m[1];
            braceDepth = 0;
            foreach (c; line)
            {
                if (c == '{') braceDepth++;
                else if (c == '}') braceDepth--;
            }

            // One-liner: struct Foo { string x; }
            if (braceDepth <= 0 && line.canFind('{'))
            {
                checkFieldLine(line, rel, ln, structName, findings);
                inStruct = false;
            }
            continue;
        }

        foreach (c; line)
        {
            if (c == '{') braceDepth++;
            else if (c == '}') braceDepth--;
        }

        if (braceDepth <= 0)
        {
            inStruct = false;
            continue;
        }

        if (braceDepth != 1)
            continue;

        if (trimmed.length == 0 || trimmed.startsWith("//")
            || trimmed.startsWith("*") || trimmed.startsWith("/*"))
            continue;

        if (trimmed.startsWith("this(") || trimmed.startsWith("~this")
            || trimmed.startsWith("static ") || trimmed.startsWith("enum ")
            || trimmed.startsWith("alias ") || trimmed.startsWith("import ")
            || trimmed.startsWith("invariant"))
            continue;

        immutable paren = cast(ptrdiff_t) trimmed.indexOf('(');
        immutable eq = cast(ptrdiff_t) trimmed.indexOf('=');
        if (paren >= 0 && (eq < 0 || paren < eq))
            continue;

        if (matchFirst(line, stringFieldRe) || matchFirst(line, delegateFieldRe))
        {
            findings ~= Finding(rel, ln, format(
                "struct '%s' has GC-traced field - use StringId / Handle!T / "
                ~ "fixed buffers (see docs/gc-safe-architecture-plan.md)",
                structName));
        }
    }
}

private void checkFieldLine(string line, string rel, size_t ln, string structName,
    ref Finding[] findings) @trusted
{
    if (matchFirst(line, stringFieldRe) || matchFirst(line, delegateFieldRe))
    {
        findings ~= Finding(rel, ln, format(
            "struct '%s' has GC-traced field - use StringId / Handle!T / "
            ~ "fixed buffers (see docs/gc-safe-architecture-plan.md)",
            structName));
    }
}
