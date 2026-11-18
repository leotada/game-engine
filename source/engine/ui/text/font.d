/// TTF Font loading, glyph rasterization via SDL3_ttf / FreeType (SDF + bitmap),
/// multi-size metric scaling, fallback fonts, kerning, and dynamic texture atlas.
module engine.ui.text.font;

import bindings.sdl3;
import bindings.sdl3_ttf;
import engine.core.log : info, warn, err;
import engine.core.pod : isPod, Pod;

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

private struct GlyphEntry {
    ulong key = 0;
    Glyph glyph;
    bool occupied = false;
}

static assert(isPod!GlyphEntry);

private struct FontSource {
    TTF_Font* ttf = null;
    ubyte[] fontBytes; // kept alive while SDL_IOStream references this buffer
    float bakeSize = 0;
    int lineSkip = 0;
    bool active = false;
}

/// Dynamic font manager and texture atlas supporting SDF multi-size rendering,
/// fallback font chains, kerning, hinting, full Unicode codepoints, and automatic atlas growth.
struct Font {
    enum float SDF_BASE_HEIGHT = 48.0f;
    // Calibrated empirically against FreeType SDF in SDL3_ttf (spread=8 px, onedge=128/255, slope=16/px).
    enum int SDF_PADDING = 8;
    enum ubyte SDF_ONEDGE = 128;
    enum float SDF_PIXEL_DIST_SCALE = 16.0f;
    enum uint MAX_FALLBACKS = 4;

    private enum int INITIAL_ATLAS_DIM = 512;
    private enum int MAX_ATLAS_DIM = 2048;
    private enum size_t INITIAL_CACHE_CAP = 1024;

    private FontSource[1 + MAX_FALLBACKS] sources;
    private uint sourceCount = 0;

    private ubyte[] atlasPixels; // 1 byte per pixel (R8_UNORM / SDF or alpha)
    private Pod!GlyphEntry[] cache;
    private size_t cacheCount = 0;

    private int atlasWidth = INITIAL_ATLAS_DIM;
    private int atlasHeight = INITIAL_ATLAS_DIM;
    private uint atlasVer = 0;

    private float pixelHeight = 16.0f;
    private bool sdfEnabled = true;
    private TTF_HintingFlags currentHinting = TTF_HintingFlags.normal;

    // Shelf packer state
    private int currentX = 1;
    private int currentY = 1;
    private int rowHeight = 0;
    private bool atlasDirty = true;
    private bool initialized = false;

    /// Initialize font from TTF/OTF bytes in memory.
    /// When `useSdf` is true (default), glyphs are baked once into a FreeType SDF atlas
    /// and scale crisply to any pixel height.
    bool loadFromMemory(ubyte[] ttfBytes, float defaultPixelHeight = 16.0f, bool useSdf = true) nothrow {
        if (ttfBytes.length == 0) return false;

        destroy();

        pixelHeight = defaultPixelHeight > 0 ? defaultPixelHeight : 16.0f;
        sdfEnabled = useSdf;

        immutable float prebakeH = sdfEnabled ? SDF_BASE_HEIGHT : pixelHeight;
        if (!initSource(sources[0], ttfBytes, prebakeH, sdfEnabled, currentHinting)) return false;
        sourceCount = 1;

        atlasWidth = INITIAL_ATLAS_DIM;
        atlasHeight = INITIAL_ATLAS_DIM;
        atlasPixels = new ubyte[atlasWidth * atlasHeight];
        atlasPixels[] = 0;

        cache = new Pod!GlyphEntry[INITIAL_CACHE_CAP];
        cacheCount = 0;

        currentX = 1;
        currentY = 1;
        rowHeight = 0;
        atlasVer++;
        atlasDirty = true;
        initialized = true;

        // Pre-bake ASCII printable range (32 .. 126)
        foreach (int cp; 32 .. 127) {
            rasterizeGlyph(cp, prebakeH);
        }
        // Pre-bake Latin-1 supplement (160 .. 255) for Portuguese/Spanish accents
        foreach (int cp; 160 .. 256) {
            rasterizeGlyph(cp, prebakeH);
        }

        return true;
    }

    /// Initialize font from a TTF/OTF file path on disk.
    bool loadFromFile(scope const(char)[] path, float defaultPixelHeight = 16.0f, bool useSdf = true) nothrow {
        if (path.length == 0) return false;
        try {
            import std.file : exists, read;
            if (!exists(path)) return false;
            ubyte[] bytes = () @trusted { return cast(ubyte[]) read(path); }();
            return loadFromMemory(bytes, defaultPixelHeight, useSdf);
        } catch (Exception) {
            return false;
        }
    }

    /// Close all open SDL3_ttf handles and reset font state.
    void destroy() nothrow @nogc {
        if (sourceCount > 0 && sources[0].ttf !is null) {
            () @trusted { TTF_ClearFallbackFonts(sources[0].ttf); }();
        }
        foreach (i; 0 .. sourceCount) {
            if (sources[i].ttf !is null) {
                () @trusted { TTF_CloseFont(sources[i].ttf); }();
                sources[i].ttf = null;
            }
            sources[i].fontBytes = null;
            sources[i].bakeSize = 0;
            sources[i].lineSkip = 0;
            sources[i].active = false;
        }
        sourceCount = 0;
        initialized = false;
    }

    /// Register a fallback TTF/OTF font used when a codepoint is missing in the primary font.
    /// Up to `MAX_FALLBACKS` fallback fonts may be registered.
    bool addFallbackFont(ubyte[] ttfBytes) nothrow {
        if (!initialized || ttfBytes.length == 0 || sourceCount >= sources.length) return false;
        immutable float bakeH = sdfEnabled ? SDF_BASE_HEIGHT : sources[0].bakeSize;
        if (!initSource(sources[sourceCount], ttfBytes, bakeH, sdfEnabled, currentHinting)) return false;
        immutable bool attached = () @trusted {
            return TTF_AddFallbackFont(sources[0].ttf, sources[sourceCount].ttf);
        }();
        if (!attached) {
            () @trusted { TTF_CloseFont(sources[sourceCount].ttf); }();
            sources[sourceCount] = FontSource.init;
            return false;
        }
        sourceCount++;
        return true;
    }

    /// Update FreeType hinting mode across all loaded font faces.
    /// In bitmap mode, existing cached glyphs are rebaked under the new hinter.
    void setHinting(TTF_HintingFlags hinting) nothrow {
        currentHinting = hinting;
        if (!initialized) return;
        foreach (i; 0 .. sourceCount) {
            if (sources[i].ttf !is null) {
                () @trusted { TTF_SetFontHinting(sources[i].ttf, hinting); }();
            }
        }
        if (!sdfEnabled) {
            atlasPixels[] = 0;
            cache[] = GlyphEntry.init;
            cacheCount = 0;
            currentX = 1;
            currentY = 1;
            rowHeight = 0;
            atlasVer++;
            atlasDirty = true;
            foreach (int cp; 32 .. 127) {
                rasterizeGlyph(cp, pixelHeight);
            }
            foreach (int cp; 160 .. 256) {
                rasterizeGlyph(cp, pixelHeight);
            }
        }
    }

    /// Active hinting mode.
    TTF_HintingFlags hinting() const nothrow @nogc pure {
        return currentHinting;
    }

    /// Check if font is initialized.
    bool isLoaded() const nothrow @nogc pure {
        return initialized;
    }

    /// Whether this font renders via SDF.
    bool isSdf() const nothrow @nogc pure {
        return sdfEnabled;
    }

    /// Default pixel height configured at load time.
    float defaultSize() const nothrow @nogc pure {
        return pixelHeight;
    }

    /// SDF pixel scale parameter passed to the shader for a target pixel height.
    /// Returns 0 when bitmap mode is active.
    float sdfScaleForSize(float pxHeight) const nothrow @nogc pure {
        if (!sdfEnabled) return 0.0f;
        immutable float h = pxHeight > 0 ? pxHeight : pixelHeight;
        return h / SDF_BASE_HEIGHT;
    }

    /// Atlas dimensions.
    int atlasW() const nothrow @nogc pure { return atlasWidth; }
    int atlasH() const nothrow @nogc pure { return atlasHeight; }

    /// Monotonically increasing version bumped whenever the atlas texture resizes.
    uint atlasVersion() const nothrow @nogc pure { return atlasVer; }

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

    /// Get font line height in pixels for the default pixel height.
    float lineHeight() const nothrow @nogc pure {
        return lineHeight(pixelHeight);
    }

    /// Get font line height in pixels for a specific pixel height.
    float lineHeight(float pxHeight) const nothrow @nogc pure {
        if (!initialized || sourceCount == 0) return pxHeight;
        immutable float h = pxHeight > 0 ? pxHeight : pixelHeight;
        const src = &sources[0];
        if (src.bakeSize <= 0 || src.lineSkip <= 0) return h;
        return cast(float)src.lineSkip * (h / src.bakeSize);
    }

    /// Query kerning adjustment in pixels between `prevCodepoint` and `codepoint`.
    float getKerning(int prevCodepoint, int codepoint, float pxHeight = 0) nothrow @nogc {
        if (!initialized || sourceCount == 0 || prevCodepoint <= 0 || codepoint <= 0)
            return 0.0f;
        immutable float targetH = pxHeight > 0 ? pxHeight : pixelHeight;
        if (!sdfEnabled) {
            ensureBitmapSize(targetH);
        }
        int kern = 0;
        immutable bool ok = () @trusted {
            return TTF_GetGlyphKerning(sources[0].ttf, cast(uint)prevCodepoint, cast(uint)codepoint, &kern);
        }();
        if (!ok || kern == 0) return 0.0f;
        if (sdfEnabled) {
            return cast(float)kern * (targetH / SDF_BASE_HEIGHT);
        }
        return cast(float)kern;
    }

    /// Query or rasterize a glyph by Unicode codepoint at the default pixel height.
    Glyph getGlyph(int codepoint) nothrow {
        return getGlyph(codepoint, pixelHeight);
    }

    /// Query or rasterize a glyph by Unicode codepoint at a specific pixel height.
    Glyph getGlyph(int codepoint, float pxHeight) nothrow {
        if (!initialized) return Glyph.init;
        immutable float targetH = pxHeight > 0 ? pxHeight : pixelHeight;
        immutable ulong key = makeKey(codepoint, targetH);

        Glyph base;
        if (!lookupCache(key, base)) {
            immutable float bakeH = sdfEnabled ? SDF_BASE_HEIGHT : targetH;
            base = rasterizeGlyph(codepoint, bakeH);
        }

        if (!sdfEnabled || !base.valid) return base;

        immutable float ratio = targetH / SDF_BASE_HEIGHT;
        Glyph scaled = base;
        scaled.width *= ratio;
        scaled.height *= ratio;
        scaled.xOffset *= ratio;
        scaled.yOffset *= ratio;
        scaled.advance *= ratio;
        return scaled;
    }

    /// Measure bounding box (width, height) of a UTF-8 string at the default size.
    void measure(scope const(char)[] text, out float outWidth, out float outHeight) nothrow {
        measure(text, pixelHeight, outWidth, outHeight);
    }

    /// Measure bounding box (width, height) of a UTF-8 string at `pxHeight`.
    void measure(scope const(char)[] text, float pxHeight, out float outWidth, out float outHeight) nothrow {
        immutable float lh = lineHeight(pxHeight);
        outWidth = 0;
        outHeight = lh;
        if (text.length == 0 || !initialized) return;

        float cursorX = 0;
        int prevCp = 0;
        size_t i = 0;
        while (i < text.length) {
            immutable int cp = decodeUtf8(text, i);
            if (cp == '\n') {
                if (cursorX > outWidth) outWidth = cursorX;
                cursorX = 0;
                prevCp = 0;
                outHeight += lh;
                continue;
            }
            if (prevCp != 0) {
                cursorX += getKerning(prevCp, cp, pxHeight);
            }
            Glyph g = getGlyph(cp, pxHeight);
            cursorX += g.advance;
            prevCp = cp;
        }
        if (cursorX > outWidth) outWidth = cursorX;
    }

    /// Decode one UTF-8 codepoint starting at `index` and advance `index`.
    package(engine) static int decodeUtf8(scope const(char)[] text, ref size_t index) nothrow @nogc pure {
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

    private static bool initSource(ref FontSource src, ubyte[] ttfBytes, float ptsize, bool sdf, TTF_HintingFlags hinting) nothrow {
        if (ttfBytes.length == 0 || !ttfInit()) return false;
        src.fontBytes = ttfBytes;
        TTF_Font* font = () @trusted {
            SDL_IOStream* io = SDL_IOFromConstMem(src.fontBytes.ptr, src.fontBytes.length);
            if (io is null) return null;
            return TTF_OpenFontIO(io, true, ptsize);
        }();
        if (font is null) {
            src.fontBytes = null;
            return false;
        }
        () @trusted {
            TTF_SetFontHinting(font, hinting);
            if (sdf) TTF_SetFontSDF(font, true);
            src.lineSkip = TTF_GetFontLineSkip(font);
            if (src.lineSkip <= 0) src.lineSkip = TTF_GetFontHeight(font);
        }();
        src.ttf = font;
        src.bakeSize = ptsize;
        src.active = true;
        return true;
    }

    private void ensureBitmapSize(float targetH) nothrow @nogc {
        immutable float diff = targetH > sources[0].bakeSize
            ? targetH - sources[0].bakeSize
            : sources[0].bakeSize - targetH;
        if (diff <= 0.125f) return;

        foreach (i; 0 .. sourceCount) {
            if (sources[i].ttf !is null) {
                () @trusted { TTF_SetFontSize(sources[i].ttf, targetH); }();
                sources[i].bakeSize = targetH;
            }
        }
        sources[0].lineSkip = () @trusted {
            int ls = TTF_GetFontLineSkip(sources[0].ttf);
            if (ls <= 0) ls = TTF_GetFontHeight(sources[0].ttf);
            return ls;
        }();
    }

    private ulong makeKey(int cp, float pxHeight) const nothrow @nogc pure {
        immutable ulong cpPart = cast(ulong)cast(uint)cp;
        if (sdfEnabled) {
            return cpPart << 16;
        }
        immutable uint quant = pxHeight > 0 ? cast(uint)(pxHeight * 2.0f + 0.5f) : 32;
        return (cpPart << 16) | (quant & 0xFFFFu);
    }

    private static size_t hashKey(ulong k) nothrow @nogc pure {
        k ^= k >> 33;
        k *= 0xff51afd7ed558ccdUL;
        k ^= k >> 33;
        k *= 0xc4ceb9fe1a85ec53UL;
        k ^= k >> 33;
        return cast(size_t)k;
    }

    private bool lookupCache(ulong key, out Glyph outGlyph) const nothrow @nogc {
        if (cache.length == 0) return false;
        immutable size_t mask = cache.length - 1;
        size_t idx = hashKey(key) & mask;
        while (cache[idx].occupied) {
            if (cache[idx].key == key) {
                outGlyph = cache[idx].glyph;
                return true;
            }
            idx = (idx + 1) & mask;
        }
        return false;
    }

    private void insertCache(ulong key, in Glyph g) nothrow {
        if (cache.length == 0 || (cacheCount + 1) * 10 >= cache.length * 7) {
            rehashCache(cache.length == 0 ? INITIAL_CACHE_CAP : cache.length * 2);
        }
        insertIntoSlice(cache, cacheCount, key, g);
    }

    private static void insertIntoSlice(Pod!GlyphEntry[] tbl, ref size_t count, ulong key, in Glyph g) nothrow @nogc {
        immutable size_t mask = tbl.length - 1;
        size_t idx = hashKey(key) & mask;
        while (tbl[idx].occupied) {
            if (tbl[idx].key == key) {
                tbl[idx].glyph = g;
                return;
            }
            idx = (idx + 1) & mask;
        }
        tbl[idx] = GlyphEntry(key, g, true);
        count++;
    }

    private void rehashCache(size_t newCap) nothrow {
        auto next = new Pod!GlyphEntry[newCap];
        size_t newCount = 0;
        foreach (ref entry; cache) {
            if (entry.occupied) {
                insertIntoSlice(next, newCount, entry.key, entry.glyph);
            }
        }
        cache = next;
        cacheCount = newCount;
    }

    private bool growAtlas() nothrow {
        if (atlasWidth >= MAX_ATLAS_DIM && atlasHeight >= MAX_ATLAS_DIM) {
            return false;
        }

        immutable int oldW = atlasWidth;
        immutable int oldH = atlasHeight;
        int newW = oldW;
        int newH = oldH;
        if (newW <= newH && newW < MAX_ATLAS_DIM) {
            newW *= 2;
        } else if (newH < MAX_ATLAS_DIM) {
            newH *= 2;
        }

        auto next = new ubyte[newW * newH];
        next[] = 0;
        foreach (int y; 0 .. oldH) {
            immutable size_t srcOff = cast(size_t)y * oldW;
            immutable size_t dstOff = cast(size_t)y * newW;
            next[dstOff .. dstOff + oldW] = atlasPixels[srcOff .. srcOff + oldW];
        }

        immutable float sx = cast(float)oldW / cast(float)newW;
        immutable float sy = cast(float)oldH / cast(float)newH;
        foreach (ref entry; cache) {
            if (entry.occupied && entry.glyph.valid) {
                entry.glyph.u0 *= sx;
                entry.glyph.u1 *= sx;
                entry.glyph.v0 *= sy;
                entry.glyph.v1 *= sy;
            }
        }

        atlasPixels = next;
        atlasWidth = newW;
        atlasHeight = newH;
        atlasVer++;
        atlasDirty = true;
        return true;
    }

    private bool allocateAtlasRect(int gw, int gh, out int gx, out int gy) nothrow {
        while (true) {
            if (currentX + gw + 1 >= atlasWidth) {
                currentX = 1;
                currentY += rowHeight + 1;
                rowHeight = 0;
            }
            if (currentX + gw + 1 < atlasWidth && currentY + gh + 1 < atlasHeight) {
                if (gh > rowHeight) rowHeight = gh;
                gx = currentX;
                gy = currentY;
                currentX += gw + 1;
                return true;
            }
            if (!growAtlas()) {
                return false;
            }
        }
    }

    private Glyph rasterizeGlyph(int cp, float targetH) nothrow {
        if (!initialized || sourceCount == 0 || sources[0].ttf is null) return Glyph.init;

        if (!sdfEnabled) {
            ensureBitmapSize(targetH);
        }

        immutable ulong key = makeKey(cp, targetH);
        TTF_Font* primary = sources[0].ttf;

        int minx = 0, maxx = 0, miny = 0, maxy = 0, advance = 0;
        immutable bool hasMetrics = () @trusted {
            return TTF_GetGlyphMetrics(primary, cast(uint)cp, &minx, &maxx, &miny, &maxy, &advance);
        }();

        TTF_ImageType imgType = TTF_ImageType.invalid;
        SDL_Surface* surf = () @trusted {
            return TTF_GetGlyphImage(primary, cast(uint)cp, &imgType);
        }();
        scope (exit) {
            if (surf !is null) {
                () @trusted { SDL_DestroySurface(surf); }();
            }
        }

        Glyph g;
        g.advance = hasMetrics ? cast(float)advance : 0.0f;
        g.valid = hasMetrics || (surf !is null);

        if (surf is null) {
            insertCache(key, g);
            return g;
        }

        immutable int gw = () @trusted { return surf.w; }();
        immutable int gh = () @trusted { return surf.h; }();
        if (gw <= 0 || gh <= 0) {
            insertCache(key, g);
            return g;
        }

        // SDL3_ttf emits a 1x1 transparent surface for whitespace glyphs like ' '.
        if (gw == 1 && gh == 1 && maxx == minx && maxy == miny) {
            insertCache(key, g);
            return g;
        }

        if (sdfEnabled && imgType == TTF_ImageType.sdf) {
            g.xOffset = cast(float)(minx - SDF_PADDING);
            g.yOffset = cast(float)(-maxy - SDF_PADDING);
        } else {
            g.xOffset = cast(float)minx;
            g.yOffset = cast(float)(-maxy);
        }
        g.width = cast(float)gw;
        g.height = cast(float)gh;

        int gx = 0, gy = 0;
        if (!allocateAtlasRect(gw, gh, gx, gy)) {
            insertCache(key, g);
            return g;
        }

        () @trusted {
            SDL_LockSurface(surf);
            scope (exit) SDL_UnlockSurface(surf);

            const(ubyte)* srcBytes = cast(const(ubyte)*) surf.pixels;
            immutable int pitch = surf.pitch;
            immutable bool isRgba32 = pitch >= gw * 4;

            foreach (int row; 0 .. gh) {
                const(ubyte)* srcRow = srcBytes + cast(size_t)row * pitch;
                ubyte* dstRow = atlasPixels.ptr + (cast(size_t)(gy + row) * atlasWidth + gx);
                if (isRgba32) {
                    const(uint)* row32 = cast(const(uint)*) srcRow;
                    foreach (int col; 0 .. gw) {
                        dstRow[col] = cast(ubyte)((row32[col] >> 24) & 0xFFu);
                    }
                } else {
                    dstRow[0 .. gw] = srcRow[0 .. gw];
                }
            }
        }();

        g.u0 = cast(float)gx / cast(float)atlasWidth;
        g.v0 = cast(float)gy / cast(float)atlasHeight;
        g.u1 = cast(float)(gx + gw) / cast(float)atlasWidth;
        g.v1 = cast(float)(gy + gh) / cast(float)atlasHeight;

        atlasDirty = true;
        insertCache(key, g);
        return g;
    }
}

unittest {
    import std.file : exists, read;
    if (exists("assets/fonts/default.ttf")) {
        ubyte[] data = () @trusted { return cast(ubyte[]) read("assets/fonts/default.ttf"); }();
        Font font;
        assert(font.loadFromMemory(data, 16.0f));
        assert(font.isLoaded);
        assert(font.isSdf);

        Glyph gA = font.getGlyph('A');
        assert(gA.valid && gA.width > 0 && gA.advance > 0);

        Glyph gAccent = font.getGlyph('ã');
        assert(gAccent.valid && gAccent.width > 0);

        // Multi-size scaling with a single SDF font instance
        Glyph g14 = font.getGlyph('A', 14.0f);
        Glyph g24 = font.getGlyph('A', 24.0f);
        Glyph g48 = font.getGlyph('A', 48.0f);
        assert(g14.valid && g24.valid && g48.valid);
        assert(g24.advance > g14.advance && g48.advance > g24.advance);

        // Full Unicode codepoints (em-dash, bullet, arrows, symbols) without truncation
        foreach (int cp; [0x2014, 0x2022, 0x25C8, 0x26A1, 0x2605]) {
            Glyph gu = font.getGlyph(cp, 24.0f);
            assert(gu.valid && gu.advance > 0);
        }

        float w, h;
        font.measure("Configuração", w, h);
        assert(w > 0 && h >= 16.0f);

        float w48, h48;
        font.measure("◈ 120 ⚡ ★", 48.0f, w48, h48);
        assert(w48 > 0 && h48 >= 48.0f);

        // Kerning consistency: measure("VA") includes getKerning('V', 'A')
        Glyph gV = font.getGlyph('V', 24.0f);
        Glyph gA24 = font.getGlyph('A', 24.0f);
        float kernVA = font.getKerning('V', 'A', 24.0f);
        float wVA = 0, hVA = 0;
        font.measure("VA", 24.0f, wVA, hVA);
        float diff = wVA - (gV.advance + gA24.advance + kernVA);
        assert(diff > -0.01f && diff < 0.01f);

        // Hinting change and bitmap mode check
        font.setHinting(TTF_HintingFlags.light);
        assert(font.hinting == TTF_HintingFlags.light);

        font.destroy();
        assert(!font.isLoaded);

        // File loading + bitmap mode + re-hinting
        assert(font.loadFromFile("assets/fonts/default.ttf", 20.0f, false));
        assert(font.isLoaded && !font.isSdf);
        Glyph gB = font.getGlyph('B');
        assert(gB.valid && gB.width > 0 && gB.advance > 0);
        font.setHinting(TTF_HintingFlags.none);
        assert(font.getGlyph('B').valid);
        font.destroy();
        assert(!font.isLoaded);

        // Invalid data fails gracefully
        ubyte[] bad = [0x01, 0x02];
        assert(!font.loadFromMemory(bad));
    }
}
