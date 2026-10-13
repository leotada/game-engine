/// Text shaping, line wrapping, and ellipsis truncation for UI elements.
module engine.ui.text.shaping;

import engine.ui.text.font;

@safe:

/// Truncate text with ellipsis "..." if it exceeds maxWidth.
/// Writes the result into outBuffer and returns the written slice.
const(char)[] truncateWithEllipsis(
    ref Font font,
    scope const(char)[] input,
    float maxWidth,
    return scope char[] outBuffer
) nothrow {
    if (input.length == 0 || maxWidth <= 0 || outBuffer.length == 0) {
        return "";
    }

    float fullW, fullH;
    font.measure(input, fullW, fullH);
    if (fullW <= maxWidth) {
        immutable size_t n = input.length < outBuffer.length ? input.length : outBuffer.length;
        outBuffer[0 .. n] = input[0 .. n];
        return outBuffer[0 .. n];
    }

    float dotW, dotH;
    font.measure("...", dotW, dotH);
    if (dotW >= maxWidth) {
        if (outBuffer.length >= 1) {
            outBuffer[0] = '.';
            return outBuffer[0 .. 1];
        }
        return "";
    }

    float avail = maxWidth - dotW;
    float curW = 0;
    size_t lastValidByte = 0;

    size_t i = 0;
    while (i < input.length) {
        immutable ubyte b = cast(ubyte)input[i++];
        int cp = b;
        if (b >= 0xC0) {
            if ((b & 0xE0) == 0xC0 && i < input.length) {
                cp = ((b & 0x1F) << 6) | (cast(ubyte)input[i++] & 0x3F);
            } else if ((b & 0xF0) == 0xE0 && i + 1 < input.length) {
                cp = ((b & 0x0F) << 12) | ((cast(ubyte)input[i++] & 0x3F) << 6) | (cast(ubyte)input[i++] & 0x3F);
            }
        }

        Glyph g = font.getGlyph(cp);
        if (curW + g.advance > avail) {
            break;
        }
        curW += g.advance;
        lastValidByte = i;
    }

    size_t n = 0;
    immutable size_t maxPrefix = outBuffer.length >= 3 ? outBuffer.length - 3 : 0;
    immutable size_t prefixLen = lastValidByte < maxPrefix ? lastValidByte : maxPrefix;
    outBuffer[0 .. prefixLen] = input[0 .. prefixLen];
    n = prefixLen;

    if (n + 3 <= outBuffer.length) {
        outBuffer[n++] = '.';
        outBuffer[n++] = '.';
        outBuffer[n++] = '.';
    }
    return outBuffer[0 .. n];
}

unittest {
    import std.file : exists, read;
    if (exists("assets/fonts/default.ttf")) {
        ubyte[] data = () @trusted { return cast(ubyte[]) read("assets/fonts/default.ttf"); }();
        Font font;
        font.loadFromMemory(data, 16.0f);

        string longText = "Este é um texto longo para testar a truncagem com reticências";
        char[128] buf;
        const(char)[] res = truncateWithEllipsis(font, longText, 100.0f, buf);

        assert(res.length > 3);
        assert(res[$ - 3 .. $] == "...");
    }
}
