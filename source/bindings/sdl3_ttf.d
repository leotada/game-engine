/// SDL3_ttf bindings for the game engine.
/// Supports static linkage (`-version=StaticSDLDeps` for release exports)
/// and lazy dynamic loading via `SDL_LoadObject` during engine development.
module bindings.sdl3_ttf;

import bindings.sdl3;

@safe:

struct TTF_Font;

alias TTF_FontStyleFlags = uint;

enum TTF_FontStyle : TTF_FontStyleFlags {
    normal        = 0x00,
    bold          = 0x01,
    italic        = 0x02,
    underline     = 0x04,
    strikethrough = 0x08,
}

enum uint TTF_STYLE_NORMAL        = 0x00;
enum uint TTF_STYLE_BOLD          = 0x01;
enum uint TTF_STYLE_ITALIC        = 0x02;
enum uint TTF_STYLE_UNDERLINE     = 0x04;
enum uint TTF_STYLE_STRIKETHROUGH = 0x08;

enum TTF_HintingFlags : int {
    invalid       = -1,
    normal        = 0,
    light         = 1,
    mono          = 2,
    none          = 3,
    lightSubpixel = 4,
}

enum TTF_HorizontalAlignment : int {
    invalid = -1,
    left    = 0,
    center  = 1,
    right   = 2,
}

enum TTF_Direction : int {
    invalid = 0,
    ltr     = 4,
    rtl     = 5,
    ttb     = 6,
    btt     = 7,
}

enum TTF_ImageType : int {
    invalid = 0,
    alpha   = 1,
    color   = 2,
    sdf     = 3,
}

version (StaticSDLDeps) {
    extern (C) nothrow @nogc @system {
        int TTF_Version();
        bool TTF_Init();
        void TTF_Quit();
        int TTF_WasInit();

        TTF_Font* TTF_OpenFont(const(char)* file, float ptsize);
        TTF_Font* TTF_OpenFontIO(SDL_IOStream* src, bool closeio, float ptsize);
        TTF_Font* TTF_CopyFont(TTF_Font* existing_font);
        void TTF_CloseFont(TTF_Font* font);

        bool TTF_AddFallbackFont(TTF_Font* font, TTF_Font* fallback);
        void TTF_RemoveFallbackFont(TTF_Font* font, TTF_Font* fallback);
        void TTF_ClearFallbackFonts(TTF_Font* font);

        bool TTF_SetFontSize(TTF_Font* font, float ptsize);
        float TTF_GetFontSize(TTF_Font* font);
        void TTF_SetFontStyle(TTF_Font* font, TTF_FontStyleFlags style);
        TTF_FontStyleFlags TTF_GetFontStyle(const(TTF_Font)* font);
        bool TTF_SetFontOutline(TTF_Font* font, int outline);
        int TTF_GetFontOutline(const(TTF_Font)* font);
        void TTF_SetFontHinting(TTF_Font* font, TTF_HintingFlags hinting);
        TTF_HintingFlags TTF_GetFontHinting(const(TTF_Font)* font);
        bool TTF_SetFontSDF(TTF_Font* font, bool enabled);
        bool TTF_GetFontSDF(const(TTF_Font)* font);
        void TTF_SetFontKerning(TTF_Font* font, bool enabled);
        bool TTF_GetFontKerning(const(TTF_Font)* font);

        int TTF_GetFontHeight(const(TTF_Font)* font);
        int TTF_GetFontAscent(const(TTF_Font)* font);
        int TTF_GetFontDescent(const(TTF_Font)* font);
        int TTF_GetFontLineSkip(const(TTF_Font)* font);
        void TTF_SetFontLineSkip(TTF_Font* font, int lineskip);

        bool TTF_FontHasGlyph(TTF_Font* font, uint ch);
        SDL_Surface* TTF_GetGlyphImage(TTF_Font* font, uint ch, TTF_ImageType* image_type);
        SDL_Surface* TTF_GetGlyphImageForIndex(TTF_Font* font, uint glyph_index, TTF_ImageType* image_type);
        bool TTF_GetGlyphMetrics(TTF_Font* font, uint ch, int* minx, int* maxx, int* miny, int* maxy, int* advance);
        bool TTF_GetGlyphKerning(TTF_Font* font, uint previous_ch, uint ch, int* kerning);

        bool TTF_GetStringSize(TTF_Font* font, const(char)* text, size_t length, int* w, int* h);
        bool TTF_GetStringSizeWrapped(TTF_Font* font, const(char)* text, size_t length, int wrap_width, int* w, int* h);
        bool TTF_MeasureString(TTF_Font* font, const(char)* text, size_t length, int max_width, int* measured_width, size_t* measured_length);

        SDL_Surface* TTF_RenderGlyph_Solid(TTF_Font* font, uint ch, SDL_Color fg);
        SDL_Surface* TTF_RenderGlyph_Shaded(TTF_Font* font, uint ch, SDL_Color fg, SDL_Color bg);
        SDL_Surface* TTF_RenderGlyph_Blended(TTF_Font* font, uint ch, SDL_Color fg);
        SDL_Surface* TTF_RenderGlyph_LCD(TTF_Font* font, uint ch, SDL_Color fg, SDL_Color bg);
        SDL_Surface* TTF_RenderText_Solid(TTF_Font* font, const(char)* text, size_t length, SDL_Color fg);
        SDL_Surface* TTF_RenderText_Blended(TTF_Font* font, const(char)* text, size_t length, SDL_Color fg);
        SDL_Surface* TTF_RenderText_Blended_Wrapped(TTF_Font* font, const(char)* text, size_t length, SDL_Color fg, int wrap_width);
        SDL_Surface* TTF_RenderText_LCD(TTF_Font* font, const(char)* text, size_t length, SDL_Color fg, SDL_Color bg);
    }

    bool ttfIsAvailable() nothrow @nogc {
        return true;
    }

    bool ttfInit() nothrow @nogc {
        return () @trusted {
            if (TTF_WasInit() > 0) return true;
            return TTF_Init();
        }();
    }
} else {
    private extern (C) nothrow @nogc {
        alias FnTTF_Version               = int function();
        alias FnTTF_Init                  = bool function();
        alias FnTTF_Quit                  = void function();
        alias FnTTF_WasInit               = int function();
        alias FnTTF_OpenFont              = TTF_Font* function(const(char)*, float);
        alias FnTTF_OpenFontIO            = TTF_Font* function(SDL_IOStream*, bool, float);
        alias FnTTF_CopyFont              = TTF_Font* function(TTF_Font*);
        alias FnTTF_CloseFont             = void function(TTF_Font*);
        alias FnTTF_AddFallbackFont       = bool function(TTF_Font*, TTF_Font*);
        alias FnTTF_RemoveFallbackFont    = void function(TTF_Font*, TTF_Font*);
        alias FnTTF_ClearFallbackFonts    = void function(TTF_Font*);
        alias FnTTF_SetFontSize           = bool function(TTF_Font*, float);
        alias FnTTF_GetFontSize           = float function(TTF_Font*);
        alias FnTTF_SetFontStyle          = void function(TTF_Font*, TTF_FontStyleFlags);
        alias FnTTF_GetFontStyle          = TTF_FontStyleFlags function(const(TTF_Font)*);
        alias FnTTF_SetFontOutline        = bool function(TTF_Font*, int);
        alias FnTTF_GetFontOutline        = int function(const(TTF_Font)*);
        alias FnTTF_SetFontHinting        = void function(TTF_Font*, TTF_HintingFlags);
        alias FnTTF_GetFontHinting        = TTF_HintingFlags function(const(TTF_Font)*);
        alias FnTTF_SetFontSDF            = bool function(TTF_Font*, bool);
        alias FnTTF_GetFontSDF            = bool function(const(TTF_Font)*);
        alias FnTTF_SetFontKerning        = void function(TTF_Font*, bool);
        alias FnTTF_GetFontKerning        = bool function(const(TTF_Font)*);
        alias FnTTF_GetFontHeight         = int function(const(TTF_Font)*);
        alias FnTTF_GetFontAscent         = int function(const(TTF_Font)*);
        alias FnTTF_GetFontDescent        = int function(const(TTF_Font)*);
        alias FnTTF_GetFontLineSkip       = int function(const(TTF_Font)*);
        alias FnTTF_SetFontLineSkip       = void function(TTF_Font*, int);
        alias FnTTF_FontHasGlyph          = bool function(TTF_Font*, uint);
        alias FnTTF_GetGlyphImage         = SDL_Surface* function(TTF_Font*, uint, TTF_ImageType*);
        alias FnTTF_GetGlyphImageForIndex = SDL_Surface* function(TTF_Font*, uint, TTF_ImageType*);
        alias FnTTF_GetGlyphMetrics       = bool function(TTF_Font*, uint, int*, int*, int*, int*, int*);
        alias FnTTF_GetGlyphKerning       = bool function(TTF_Font*, uint, uint, int*);
        alias FnTTF_GetStringSize         = bool function(TTF_Font*, const(char)*, size_t, int*, int*);
        alias FnTTF_GetStringSizeWrapped  = bool function(TTF_Font*, const(char)*, size_t, int, int*, int*);
        alias FnTTF_MeasureString         = bool function(TTF_Font*, const(char)*, size_t, int, int*, size_t*);
        alias FnTTF_RenderGlyph_Solid     = SDL_Surface* function(TTF_Font*, uint, SDL_Color);
        alias FnTTF_RenderGlyph_Shaded    = SDL_Surface* function(TTF_Font*, uint, SDL_Color, SDL_Color);
        alias FnTTF_RenderGlyph_Blended   = SDL_Surface* function(TTF_Font*, uint, SDL_Color);
        alias FnTTF_RenderGlyph_LCD       = SDL_Surface* function(TTF_Font*, uint, SDL_Color, SDL_Color);
        alias FnTTF_RenderText_Solid      = SDL_Surface* function(TTF_Font*, const(char)*, size_t, SDL_Color);
        alias FnTTF_RenderText_Blended    = SDL_Surface* function(TTF_Font*, const(char)*, size_t, SDL_Color);
        alias FnTTF_RenderText_BlendedW   = SDL_Surface* function(TTF_Font*, const(char)*, size_t, SDL_Color, int);
        alias FnTTF_RenderText_LCD        = SDL_Surface* function(TTF_Font*, const(char)*, size_t, SDL_Color, SDL_Color);
    }

    private __gshared {
        SDL_SharedObject* gTtfLib = null;
        bool gTtfAttempted = false;
        bool gTtfAvailable = false;

        FnTTF_Version               pTTF_Version;
        FnTTF_Init                  pTTF_Init;
        FnTTF_Quit                  pTTF_Quit;
        FnTTF_WasInit               pTTF_WasInit;
        FnTTF_OpenFont              pTTF_OpenFont;
        FnTTF_OpenFontIO            pTTF_OpenFontIO;
        FnTTF_CopyFont              pTTF_CopyFont;
        FnTTF_CloseFont             pTTF_CloseFont;
        FnTTF_AddFallbackFont       pTTF_AddFallbackFont;
        FnTTF_RemoveFallbackFont    pTTF_RemoveFallbackFont;
        FnTTF_ClearFallbackFonts    pTTF_ClearFallbackFonts;
        FnTTF_SetFontSize           pTTF_SetFontSize;
        FnTTF_GetFontSize           pTTF_GetFontSize;
        FnTTF_SetFontStyle          pTTF_SetFontStyle;
        FnTTF_GetFontStyle          pTTF_GetFontStyle;
        FnTTF_SetFontOutline        pTTF_SetFontOutline;
        FnTTF_GetFontOutline        pTTF_GetFontOutline;
        FnTTF_SetFontHinting        pTTF_SetFontHinting;
        FnTTF_GetFontHinting        pTTF_GetFontHinting;
        FnTTF_SetFontSDF            pTTF_SetFontSDF;
        FnTTF_GetFontSDF            pTTF_GetFontSDF;
        FnTTF_SetFontKerning        pTTF_SetFontKerning;
        FnTTF_GetFontKerning        pTTF_GetFontKerning;
        FnTTF_GetFontHeight         pTTF_GetFontHeight;
        FnTTF_GetFontAscent         pTTF_GetFontAscent;
        FnTTF_GetFontDescent        pTTF_GetFontDescent;
        FnTTF_GetFontLineSkip       pTTF_GetFontLineSkip;
        FnTTF_SetFontLineSkip       pTTF_SetFontLineSkip;
        FnTTF_FontHasGlyph          pTTF_FontHasGlyph;
        FnTTF_GetGlyphImage         pTTF_GetGlyphImage;
        FnTTF_GetGlyphImageForIndex pTTF_GetGlyphImageForIndex;
        FnTTF_GetGlyphMetrics       pTTF_GetGlyphMetrics;
        FnTTF_GetGlyphKerning       pTTF_GetGlyphKerning;
        FnTTF_GetStringSize         pTTF_GetStringSize;
        FnTTF_GetStringSizeWrapped  pTTF_GetStringSizeWrapped;
        FnTTF_MeasureString         pTTF_MeasureString;
        FnTTF_RenderGlyph_Solid     pTTF_RenderGlyph_Solid;
        FnTTF_RenderGlyph_Shaded    pTTF_RenderGlyph_Shaded;
        FnTTF_RenderGlyph_Blended   pTTF_RenderGlyph_Blended;
        FnTTF_RenderGlyph_LCD       pTTF_RenderGlyph_LCD;
        FnTTF_RenderText_Solid      pTTF_RenderText_Solid;
        FnTTF_RenderText_Blended    pTTF_RenderText_Blended;
        FnTTF_RenderText_BlendedW   pTTF_RenderText_Blended_Wrapped;
        FnTTF_RenderText_LCD        pTTF_RenderText_LCD;
    }

    private T loadSym(T)(SDL_SharedObject* lib, const(char)* name) nothrow @nogc @system {
        return cast(T) SDL_LoadFunction(lib, name);
    }

    private bool ttfLoadLibrary() nothrow @nogc @trusted {
        if (gTtfAttempted) return gTtfAvailable;
        gTtfAttempted = true;

        version (Windows) {
            static immutable const(char)*[1] candidates = ["SDL3_ttf.dll".ptr];
        } else version (OSX) {
            static immutable const(char)*[4] candidates = [
                "libSDL3_ttf.0.dylib".ptr,
                "libSDL3_ttf.dylib".ptr,
                "@executable_path/../Frameworks/libSDL3_ttf.dylib".ptr,
                "libs/macos-arm64/libSDL3_ttf.dylib".ptr,
            ];
        } else {
            static immutable const(char)*[4] candidates = [
                "libSDL3_ttf.so.0".ptr,
                "libSDL3_ttf.so".ptr,
                "libs/linux-x86_64/libSDL3_ttf.so".ptr,
                "libs/libSDL3_ttf.so".ptr,
            ];
        }

        foreach (cand; candidates) {
            gTtfLib = SDL_LoadObject(cand);
            if (gTtfLib !is null) break;
        }
        if (gTtfLib is null) return false;

        pTTF_Version                    = loadSym!FnTTF_Version(gTtfLib, "TTF_Version");
        pTTF_Init                       = loadSym!FnTTF_Init(gTtfLib, "TTF_Init");
        pTTF_Quit                       = loadSym!FnTTF_Quit(gTtfLib, "TTF_Quit");
        pTTF_WasInit                    = loadSym!FnTTF_WasInit(gTtfLib, "TTF_WasInit");
        pTTF_OpenFont                   = loadSym!FnTTF_OpenFont(gTtfLib, "TTF_OpenFont");
        pTTF_OpenFontIO                 = loadSym!FnTTF_OpenFontIO(gTtfLib, "TTF_OpenFontIO");
        pTTF_CopyFont                   = loadSym!FnTTF_CopyFont(gTtfLib, "TTF_CopyFont");
        pTTF_CloseFont                  = loadSym!FnTTF_CloseFont(gTtfLib, "TTF_CloseFont");
        pTTF_AddFallbackFont            = loadSym!FnTTF_AddFallbackFont(gTtfLib, "TTF_AddFallbackFont");
        pTTF_RemoveFallbackFont         = loadSym!FnTTF_RemoveFallbackFont(gTtfLib, "TTF_RemoveFallbackFont");
        pTTF_ClearFallbackFonts         = loadSym!FnTTF_ClearFallbackFonts(gTtfLib, "TTF_ClearFallbackFonts");
        pTTF_SetFontSize                = loadSym!FnTTF_SetFontSize(gTtfLib, "TTF_SetFontSize");
        pTTF_GetFontSize                = loadSym!FnTTF_GetFontSize(gTtfLib, "TTF_GetFontSize");
        pTTF_SetFontStyle               = loadSym!FnTTF_SetFontStyle(gTtfLib, "TTF_SetFontStyle");
        pTTF_GetFontStyle               = loadSym!FnTTF_GetFontStyle(gTtfLib, "TTF_GetFontStyle");
        pTTF_SetFontOutline             = loadSym!FnTTF_SetFontOutline(gTtfLib, "TTF_SetFontOutline");
        pTTF_GetFontOutline             = loadSym!FnTTF_GetFontOutline(gTtfLib, "TTF_GetFontOutline");
        pTTF_SetFontHinting             = loadSym!FnTTF_SetFontHinting(gTtfLib, "TTF_SetFontHinting");
        pTTF_GetFontHinting             = loadSym!FnTTF_GetFontHinting(gTtfLib, "TTF_GetFontHinting");
        pTTF_SetFontSDF                 = loadSym!FnTTF_SetFontSDF(gTtfLib, "TTF_SetFontSDF");
        pTTF_GetFontSDF                 = loadSym!FnTTF_GetFontSDF(gTtfLib, "TTF_GetFontSDF");
        pTTF_SetFontKerning             = loadSym!FnTTF_SetFontKerning(gTtfLib, "TTF_SetFontKerning");
        pTTF_GetFontKerning             = loadSym!FnTTF_GetFontKerning(gTtfLib, "TTF_GetFontKerning");
        pTTF_GetFontHeight              = loadSym!FnTTF_GetFontHeight(gTtfLib, "TTF_GetFontHeight");
        pTTF_GetFontAscent              = loadSym!FnTTF_GetFontAscent(gTtfLib, "TTF_GetFontAscent");
        pTTF_GetFontDescent             = loadSym!FnTTF_GetFontDescent(gTtfLib, "TTF_GetFontDescent");
        pTTF_GetFontLineSkip            = loadSym!FnTTF_GetFontLineSkip(gTtfLib, "TTF_GetFontLineSkip");
        pTTF_SetFontLineSkip            = loadSym!FnTTF_SetFontLineSkip(gTtfLib, "TTF_SetFontLineSkip");
        pTTF_FontHasGlyph               = loadSym!FnTTF_FontHasGlyph(gTtfLib, "TTF_FontHasGlyph");
        pTTF_GetGlyphImage              = loadSym!FnTTF_GetGlyphImage(gTtfLib, "TTF_GetGlyphImage");
        pTTF_GetGlyphImageForIndex      = loadSym!FnTTF_GetGlyphImageForIndex(gTtfLib, "TTF_GetGlyphImageForIndex");
        pTTF_GetGlyphMetrics            = loadSym!FnTTF_GetGlyphMetrics(gTtfLib, "TTF_GetGlyphMetrics");
        pTTF_GetGlyphKerning            = loadSym!FnTTF_GetGlyphKerning(gTtfLib, "TTF_GetGlyphKerning");
        pTTF_GetStringSize              = loadSym!FnTTF_GetStringSize(gTtfLib, "TTF_GetStringSize");
        pTTF_GetStringSizeWrapped       = loadSym!FnTTF_GetStringSizeWrapped(gTtfLib, "TTF_GetStringSizeWrapped");
        pTTF_MeasureString              = loadSym!FnTTF_MeasureString(gTtfLib, "TTF_MeasureString");
        pTTF_RenderGlyph_Solid          = loadSym!FnTTF_RenderGlyph_Solid(gTtfLib, "TTF_RenderGlyph_Solid");
        pTTF_RenderGlyph_Shaded         = loadSym!FnTTF_RenderGlyph_Shaded(gTtfLib, "TTF_RenderGlyph_Shaded");
        pTTF_RenderGlyph_Blended        = loadSym!FnTTF_RenderGlyph_Blended(gTtfLib, "TTF_RenderGlyph_Blended");
        pTTF_RenderGlyph_LCD            = loadSym!FnTTF_RenderGlyph_LCD(gTtfLib, "TTF_RenderGlyph_LCD");
        pTTF_RenderText_Solid           = loadSym!FnTTF_RenderText_Solid(gTtfLib, "TTF_RenderText_Solid");
        pTTF_RenderText_Blended         = loadSym!FnTTF_RenderText_Blended(gTtfLib, "TTF_RenderText_Blended");
        pTTF_RenderText_Blended_Wrapped = loadSym!FnTTF_RenderText_BlendedW(gTtfLib, "TTF_RenderText_Blended_Wrapped");
        pTTF_RenderText_LCD             = loadSym!FnTTF_RenderText_LCD(gTtfLib, "TTF_RenderText_LCD");

        gTtfAvailable = pTTF_Init !is null && pTTF_OpenFontIO !is null && pTTF_GetGlyphImage !is null;
        return gTtfAvailable;
    }

    /// Returns true if the SDL3_ttf dynamic library is available on this host.
    bool ttfIsAvailable() nothrow @nogc {
        return ttfLoadLibrary();
    }

    /// Loads SDL3_ttf dynamically and ensures TTF_Init() has been initialized.
    bool ttfInit() nothrow @nogc @trusted {
        if (!ttfLoadLibrary()) return false;
        if (pTTF_WasInit !is null && pTTF_WasInit() > 0) return true;
        return pTTF_Init !is null ? pTTF_Init() : false;
    }

    @system nothrow @nogc {
        int TTF_Version() {
            return (ttfLoadLibrary() && pTTF_Version !is null) ? pTTF_Version() : 0;
        }

        bool TTF_Init() {
            return (ttfLoadLibrary() && pTTF_Init !is null) ? pTTF_Init() : false;
        }

        void TTF_Quit() {
            if (gTtfAvailable && pTTF_Quit !is null) pTTF_Quit();
        }

        int TTF_WasInit() {
            return (gTtfAvailable && pTTF_WasInit !is null) ? pTTF_WasInit() : 0;
        }

        TTF_Font* TTF_OpenFont(const(char)* file, float ptsize) {
            return (ttfInit() && pTTF_OpenFont !is null) ? pTTF_OpenFont(file, ptsize) : null;
        }

        TTF_Font* TTF_OpenFontIO(SDL_IOStream* src, bool closeio, float ptsize) {
            return (ttfInit() && pTTF_OpenFontIO !is null) ? pTTF_OpenFontIO(src, closeio, ptsize) : null;
        }

        TTF_Font* TTF_CopyFont(TTF_Font* existing_font) {
            return (gTtfAvailable && pTTF_CopyFont !is null) ? pTTF_CopyFont(existing_font) : null;
        }

        void TTF_CloseFont(TTF_Font* font) {
            if (gTtfAvailable && pTTF_CloseFont !is null) pTTF_CloseFont(font);
        }

        bool TTF_AddFallbackFont(TTF_Font* font, TTF_Font* fallback) {
            return (gTtfAvailable && pTTF_AddFallbackFont !is null) ? pTTF_AddFallbackFont(font, fallback) : false;
        }

        void TTF_RemoveFallbackFont(TTF_Font* font, TTF_Font* fallback) {
            if (gTtfAvailable && pTTF_RemoveFallbackFont !is null) pTTF_RemoveFallbackFont(font, fallback);
        }

        void TTF_ClearFallbackFonts(TTF_Font* font) {
            if (gTtfAvailable && pTTF_ClearFallbackFonts !is null) pTTF_ClearFallbackFonts(font);
        }

        bool TTF_SetFontSize(TTF_Font* font, float ptsize) {
            return (gTtfAvailable && pTTF_SetFontSize !is null) ? pTTF_SetFontSize(font, ptsize) : false;
        }

        float TTF_GetFontSize(TTF_Font* font) {
            return (gTtfAvailable && pTTF_GetFontSize !is null) ? pTTF_GetFontSize(font) : 0.0f;
        }

        void TTF_SetFontStyle(TTF_Font* font, TTF_FontStyleFlags style) {
            if (gTtfAvailable && pTTF_SetFontStyle !is null) pTTF_SetFontStyle(font, style);
        }

        TTF_FontStyleFlags TTF_GetFontStyle(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontStyle !is null) ? pTTF_GetFontStyle(font) : 0;
        }

        bool TTF_SetFontOutline(TTF_Font* font, int outline) {
            return (gTtfAvailable && pTTF_SetFontOutline !is null) ? pTTF_SetFontOutline(font, outline) : false;
        }

        int TTF_GetFontOutline(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontOutline !is null) ? pTTF_GetFontOutline(font) : 0;
        }

        void TTF_SetFontHinting(TTF_Font* font, TTF_HintingFlags hinting) {
            if (gTtfAvailable && pTTF_SetFontHinting !is null) pTTF_SetFontHinting(font, hinting);
        }

        TTF_HintingFlags TTF_GetFontHinting(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontHinting !is null) ? pTTF_GetFontHinting(font) : TTF_HintingFlags.invalid;
        }

        bool TTF_SetFontSDF(TTF_Font* font, bool enabled) {
            return (gTtfAvailable && pTTF_SetFontSDF !is null) ? pTTF_SetFontSDF(font, enabled) : false;
        }

        bool TTF_GetFontSDF(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontSDF !is null) ? pTTF_GetFontSDF(font) : false;
        }

        void TTF_SetFontKerning(TTF_Font* font, bool enabled) {
            if (gTtfAvailable && pTTF_SetFontKerning !is null) pTTF_SetFontKerning(font, enabled);
        }

        bool TTF_GetFontKerning(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontKerning !is null) ? pTTF_GetFontKerning(font) : false;
        }

        int TTF_GetFontHeight(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontHeight !is null) ? pTTF_GetFontHeight(font) : 0;
        }

        int TTF_GetFontAscent(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontAscent !is null) ? pTTF_GetFontAscent(font) : 0;
        }

        int TTF_GetFontDescent(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontDescent !is null) ? pTTF_GetFontDescent(font) : 0;
        }

        int TTF_GetFontLineSkip(const(TTF_Font)* font) {
            return (gTtfAvailable && pTTF_GetFontLineSkip !is null) ? pTTF_GetFontLineSkip(font) : 0;
        }

        void TTF_SetFontLineSkip(TTF_Font* font, int lineskip) {
            if (gTtfAvailable && pTTF_SetFontLineSkip !is null) pTTF_SetFontLineSkip(font, lineskip);
        }

        bool TTF_FontHasGlyph(TTF_Font* font, uint ch) {
            return (gTtfAvailable && pTTF_FontHasGlyph !is null) ? pTTF_FontHasGlyph(font, ch) : false;
        }

        SDL_Surface* TTF_GetGlyphImage(TTF_Font* font, uint ch, TTF_ImageType* image_type) {
            return (gTtfAvailable && pTTF_GetGlyphImage !is null) ? pTTF_GetGlyphImage(font, ch, image_type) : null;
        }

        SDL_Surface* TTF_GetGlyphImageForIndex(TTF_Font* font, uint glyph_index, TTF_ImageType* image_type) {
            return (gTtfAvailable && pTTF_GetGlyphImageForIndex !is null) ? pTTF_GetGlyphImageForIndex(font, glyph_index, image_type) : null;
        }

        bool TTF_GetGlyphMetrics(TTF_Font* font, uint ch, int* minx, int* maxx, int* miny, int* maxy, int* advance) {
            return (gTtfAvailable && pTTF_GetGlyphMetrics !is null) ? pTTF_GetGlyphMetrics(font, ch, minx, maxx, miny, maxy, advance) : false;
        }

        bool TTF_GetGlyphKerning(TTF_Font* font, uint previous_ch, uint ch, int* kerning) {
            return (gTtfAvailable && pTTF_GetGlyphKerning !is null) ? pTTF_GetGlyphKerning(font, previous_ch, ch, kerning) : false;
        }

        bool TTF_GetStringSize(TTF_Font* font, const(char)* text, size_t length, int* w, int* h) {
            return (gTtfAvailable && pTTF_GetStringSize !is null) ? pTTF_GetStringSize(font, text, length, w, h) : false;
        }

        bool TTF_GetStringSizeWrapped(TTF_Font* font, const(char)* text, size_t length, int wrap_width, int* w, int* h) {
            return (gTtfAvailable && pTTF_GetStringSizeWrapped !is null) ? pTTF_GetStringSizeWrapped(font, text, length, wrap_width, w, h) : false;
        }

        bool TTF_MeasureString(TTF_Font* font, const(char)* text, size_t length, int max_width, int* measured_width, size_t* measured_length) {
            return (gTtfAvailable && pTTF_MeasureString !is null) ? pTTF_MeasureString(font, text, length, max_width, measured_width, measured_length) : false;
        }

        SDL_Surface* TTF_RenderGlyph_Solid(TTF_Font* font, uint ch, SDL_Color fg) {
            return (gTtfAvailable && pTTF_RenderGlyph_Solid !is null) ? pTTF_RenderGlyph_Solid(font, ch, fg) : null;
        }

        SDL_Surface* TTF_RenderGlyph_Shaded(TTF_Font* font, uint ch, SDL_Color fg, SDL_Color bg) {
            return (gTtfAvailable && pTTF_RenderGlyph_Shaded !is null) ? pTTF_RenderGlyph_Shaded(font, ch, fg, bg) : null;
        }

        SDL_Surface* TTF_RenderGlyph_Blended(TTF_Font* font, uint ch, SDL_Color fg) {
            return (gTtfAvailable && pTTF_RenderGlyph_Blended !is null) ? pTTF_RenderGlyph_Blended(font, ch, fg) : null;
        }

        SDL_Surface* TTF_RenderGlyph_LCD(TTF_Font* font, uint ch, SDL_Color fg, SDL_Color bg) {
            return (gTtfAvailable && pTTF_RenderGlyph_LCD !is null) ? pTTF_RenderGlyph_LCD(font, ch, fg, bg) : null;
        }

        SDL_Surface* TTF_RenderText_Solid(TTF_Font* font, const(char)* text, size_t length, SDL_Color fg) {
            return (gTtfAvailable && pTTF_RenderText_Solid !is null) ? pTTF_RenderText_Solid(font, text, length, fg) : null;
        }

        SDL_Surface* TTF_RenderText_Blended(TTF_Font* font, const(char)* text, size_t length, SDL_Color fg) {
            return (gTtfAvailable && pTTF_RenderText_Blended !is null) ? pTTF_RenderText_Blended(font, text, length, fg) : null;
        }

        SDL_Surface* TTF_RenderText_Blended_Wrapped(TTF_Font* font, const(char)* text, size_t length, SDL_Color fg, int wrap_width) {
            return (gTtfAvailable && pTTF_RenderText_Blended_Wrapped !is null)
                ? pTTF_RenderText_Blended_Wrapped(font, text, length, fg, wrap_width)
                : null;
        }

        SDL_Surface* TTF_RenderText_LCD(TTF_Font* font, const(char)* text, size_t length, SDL_Color fg, SDL_Color bg) {
            return (gTtfAvailable && pTTF_RenderText_LCD !is null) ? pTTF_RenderText_LCD(font, text, length, fg, bg) : null;
        }
    }
}
