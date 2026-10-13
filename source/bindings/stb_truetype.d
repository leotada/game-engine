/// Manual bindings to stb_truetype (C99 single-header font rasterizer).
module bindings.stb_truetype;

@safe:

extern(C) nothrow @nogc {
    struct stbtt_fontinfo {
        void* userdata;
        ubyte* data;
        int fontstart;
        int numGlyphs;
        int loca, head, glyf, hhea, hmtx, kern, gpos, svg;
        int index_map;
        int indexToLocFormat;
        ubyte[1024] _cbuffer;
    }

    int stbtt_InitFont(stbtt_fontinfo* info, const(ubyte)* data, int offset);
    float stbtt_ScaleForPixelHeight(const(stbtt_fontinfo)* info, float pixels);
    void stbtt_GetFontVMetrics(const(stbtt_fontinfo)* info, int* ascent, int* descent, int* lineGap);
    void stbtt_GetCodepointHMetrics(const(stbtt_fontinfo)* info, int codepoint, int* advanceWidth, int* leftSideBearing);
    int stbtt_GetCodepointKernAdvance(const(stbtt_fontinfo)* info, int ch1, int ch2);
    void stbtt_GetCodepointBitmapBox(
        const(stbtt_fontinfo)* info,
        int codepoint,
        float scale_x, float scale_y,
        int* ix0, int* iy0, int* ix1, int* iy1
    );
    void stbtt_MakeCodepointBitmap(
        const(stbtt_fontinfo)* info,
        ubyte* output,
        int out_w, int out_h, int out_stride,
        float scale_x, float scale_y,
        int codepoint
    );
    ubyte* stbtt_GetCodepointBitmap(
        const(stbtt_fontinfo)* info,
        float scale_x, float scale_y,
        int codepoint,
        int* width, int* height,
        int* xoff, int* yoff
    );
    void stbtt_FreeBitmap(ubyte* bitmap, void* userdata);
}
