/// TTF Font loading, glyph rasterization via stb_truetype, and dynamic texture atlas.
module engine.ui.text.font;

import bindings.stb_truetype;
import engine.core.log : info, warn, err;
import engine.core.pod : isPod;

@safe:

/// Metrics and atlas coordinates for a single rasterized glyph.
struct Glyph {
    float u0 = 0, v0 = 0, u1 = 0, v1 = 0;
    float width = 0;
    float height = 0;
    float xOffset = 0;
    float yOffset = 0;
    float advance = 0;
    bool valid = false;
}

static assert(isPod!Glyph);

/// Dynamic font manager and texture atlas.
struct Font {
    private enum ATLAS_WIDTH = 512;
    private enum ATLAS_HEIGHT = 512;
    private enum MAX_GLYPHS = 256; // Standard ASCII + Latin-1 Supplement

    private stbtt_fontinfo info;
    private ubyte[] fontBytes;
    private ubyte[] atlasPixels; // 1 byte per pixel (R8_UNORM / Alpha)

    private Glyph[MAX_GLYPHS] glyphs;
    private int ascent = 0;
    private int descent = 0;
    private int lineGap = 0;
    private float pixelHeight = 16.0f;
    private float scale = 1.0f;

    // Shelf packer state
    private int currentX = 1;
    private int currentY = 1;
    private int rowHeight = 0;
    private bool atlasDirty = true;
    private bool initialized = false;

    /// Initialize font from TTF bytes in memory.
    bool loadFromMemory(ubyte[] ttfBytes, float defaultPixelHeight = 16.0f) nothrow {
        if (ttfBytes.length == 0) return false;
        fontBytes = ttfBytes;
        pixelHeight = defaultPixelHeight;

        immutable int ok = () @trusted {
            return stbtt_InitFont(&info, fontBytes.ptr, 0);
        }();
        if (ok == 0) return false;

        () @trusted {
            int a, d, g;
            stbtt_GetFontVMetrics(&info, &a, &d, &g);
            ascent = a;
            descent = d;
            lineGap = g;
            scale = stbtt_ScaleForPixelHeight(&info, pixelHeight);
        }();

        atlasPixels = new ubyte[ATLAS_WIDTH * ATLAS_HEIGHT];
        atlasPixels[] = 0;
        atlasDirty = true;
        initialized = true;

        // Pre-bake ASCII printable range (32 .. 126)
        foreach (int cp; 32 .. 127) {
            rasterizeGlyph(cp);
        }
        // Pre-bake Latin-1 supplement (160 .. 255) for Portuguese/Spanish accents
        foreach (int cp; 160 .. 256) {
            rasterizeGlyph(cp);
        }

        return true;
    }

    /// Check if font is initialized.
    bool isLoaded() const nothrow @nogc pure {
        return initialized;
    }

    /// Atlas dimensions.
    int atlasW() const nothrow @nogc pure { return ATLAS_WIDTH; }
    int atlasH() const nothrow @nogc pure { return ATLAS_HEIGHT; }

    /// Pixel data for GPU upload.
    const(ubyte)[] pixels() const nothrow @nogc pure {
        return atlasPixels;
    }

    /// Whether atlas needs re-uploading to GPU.
    bool isDirty() const nothrow @nogc pure {
        return atlasDirty;
    }

    /// Mark atlas as synced to GPU.
    void clearDirty() nothrow @nogc {
        atlasDirty = false;
    }

    /// Get font line height in pixels.
    float lineHeight() const nothrow @nogc pure {
        return (ascent - descent + lineGap) * scale;
    }

    /// Query or rasterize a glyph by Unicode codepoint.
    Glyph getGlyph(int codepoint) nothrow {
        if (!initialized) return Glyph.init;
        if (codepoint >= 0 && codepoint < MAX_GLYPHS && glyphs[codepoint].valid) {
            return glyphs[codepoint];
        }
        return rasterizeGlyph(codepoint);
    }

    /// Measure bounding box (width, height) of a UTF-8 string.
    void measure(scope const(char)[] text, out float outWidth, out float outHeight) nothrow {
        outWidth = 0;
        outHeight = lineHeight();
        if (text.length == 0 || !initialized) return;

        float cursorX = 0;
        size_t i = 0;
        while (i < text.length) {
            int cp = decodeUtf8(text, i);
            if (cp == '\n') {
                if (cursorX > outWidth) outWidth = cursorX;
                cursorX = 0;
                outHeight += lineHeight();
                continue;
            }
            Glyph g = getGlyph(cp);
            cursorX += g.advance;
        }
        if (cursorX > outWidth) outWidth = cursorX;
    }

    private Glyph rasterizeGlyph(int cp) nothrow {
        if (!initialized) return Glyph.init;

        int advance, lsb;
        int ix0, iy0, ix1, iy1;
        () @trusted {
            stbtt_GetCodepointHMetrics(&info, cp, &advance, &lsb);
            stbtt_GetCodepointBitmapBox(&info, cp, scale, scale, &ix0, &iy0, &ix1, &iy1);
        }();

        immutable int gw = ix1 - ix0;
        immutable int gh = iy1 - iy0;

        Glyph g;
        g.width = cast(float)gw;
        g.height = cast(float)gh;
        g.xOffset = cast(float)ix0;
        g.yOffset = cast(float)iy0;
        g.advance = cast(float)advance * scale;
        g.valid = true;

        if (gw <= 0 || gh <= 0) {
            if (cp >= 0 && cp < MAX_GLYPHS) glyphs[cp] = g;
            return g;
        }

        // Shelf packing in atlas
        if (currentX + gw + 1 >= ATLAS_WIDTH) {
            currentX = 1;
            currentY += rowHeight + 1;
            rowHeight = 0;
        }

        if (currentY + gh + 1 >= ATLAS_HEIGHT) {
            // Atlas is full — return untextured glyph with metrics
            return g;
        }

        if (gh > rowHeight) rowHeight = gh;

        immutable int gx = currentX;
        immutable int gy = currentY;
        currentX += gw + 1;

        // Render bitmap into atlas
        () @trusted {
            stbtt_MakeCodepointBitmap(
                &info,
                atlasPixels.ptr + (gy * ATLAS_WIDTH + gx),
                gw, gh, ATLAS_WIDTH,
                scale, scale,
                cp
            );
        }();

        g.u0 = cast(float)gx / cast(float)ATLAS_WIDTH;
        g.v0 = cast(float)gy / cast(float)ATLAS_HEIGHT;
        g.u1 = cast(float)(gx + gw) / cast(float)ATLAS_WIDTH;
        g.v1 = cast(float)(gy + gh) / cast(float)ATLAS_HEIGHT;

        atlasDirty = true;
        if (cp >= 0 && cp < MAX_GLYPHS) {
            glyphs[cp] = g;
        }
        return g;
    }

    private static int decodeUtf8(scope const(char)[] text, ref size_t index) nothrow @nogc pure {
        if (index >= text.length) return 0;
        immutable ubyte b0 = cast(ubyte)text[index++];
        if (b0 < 0x80) return b0;
        if ((b0 & 0xE0) == 0xC0 && index < text.length) {
            immutable ubyte b1 = cast(ubyte)text[index++];
            return ((b0 & 0x1F) << 6) | (b1 & 0x3F);
        }
        if ((b0 & 0xF0) == 0xE0 && index + 1 < text.length) {
            immutable ubyte b1 = cast(ubyte)text[index++];
            immutable ubyte b2 = cast(ubyte)text[index++];
            return ((b0 & 0x0F) << 12) | ((b1 & 0x3F) << 6) | (b2 & 0x3F);
        }
        if ((b0 & 0xF8) == 0xF0 && index + 2 < text.length) {
            immutable ubyte b1 = cast(ubyte)text[index++];
            immutable ubyte b2 = cast(ubyte)text[index++];
            immutable ubyte b3 = cast(ubyte)text[index++];
            return ((b0 & 0x07) << 18) | ((b1 & 0x3F) << 12) | ((b2 & 0x3F) << 6) | (b3 & 0x3F);
        }
        return b0;
    }
}

unittest {
    import std.file : exists, read;
    if (exists("assets/fonts/default.ttf")) {
        ubyte[] data = () @trusted { return cast(ubyte[]) read("assets/fonts/default.ttf"); }();
        Font font;
        assert(font.loadFromMemory(data, 16.0f));
        assert(font.isLoaded);

        Glyph a = font.getGlyph('A');
        assert(a.valid);
        assert(a.advance > 0);
        assert(a.width > 0);

        Glyph pt = font.getGlyph('ã');
        assert(pt.valid);

        float w, h;
        font.measure("Configuração", w, h);
        assert(w > 0);
        assert(h >= 16.0f);
    }
}
