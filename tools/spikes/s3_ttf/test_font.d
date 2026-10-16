module test_font;

import std.file : read;
import std.stdio : writeln, writefln;

extern(C) nothrow @nogc {
    struct stbtt_fontinfo {
        void* userdata;
        ubyte* data;
        int fontstart;
        int numGlyphs;
        int loca, head, glyf, hhea, hmtx, kern, gpos, svg;
        int index_map;
        int indexToLocFormat;
        // cbuffer
        ubyte[1024] _padding;
    }

    int stbtt_InitFont(stbtt_fontinfo* info, const(ubyte)* data, int offset);
    float stbtt_ScaleForPixelHeight(const(stbtt_fontinfo)* info, float pixels);
    ubyte* stbtt_GetCodepointBitmap(
        const(stbtt_fontinfo)* info,
        float scale_x, float scale_y,
        int codepoint,
        int* width, int* height,
        int* xoff, int* yoff
    );
    void stbtt_FreeBitmap(ubyte* bitmap, void* userdata);
}

void main() {
    writeln("Iniciando spike S3: teste de rasterização TTF via stb_truetype...");

    string fontPath = "/usr/share/fonts/truetype/LiberationSans-Bold.ttf";
    ubyte[] fontBytes = cast(ubyte[]) read(fontPath);
    writeln("Fonte carregada do disco: ", fontBytes.length, " bytes");

    stbtt_fontinfo info;
    int ok = stbtt_InitFont(&info, fontBytes.ptr, 0);
    assert(ok != 0, "Falha ao inicializar fonte TTF");

    float scale = stbtt_ScaleForPixelHeight(&info, 24.0f);
    assert(scale > 0.0f);

    int w, h, xoff, yoff;
    ubyte* bitmap = stbtt_GetCodepointBitmap(&info, scale, scale, 'A', &w, &h, &xoff, &yoff);
    assert(bitmap !is null, "Falha ao renderizar glifo 'A'");
    writefln("Glifo 'A' rasterizado com sucesso! Dimensões: %dx%d px (offsets: %d, %d)", w, h, xoff, yoff);

    // Mini render ASCII do glifo 'A'
    foreach (y; 0 .. h) {
        char[64] line;
        foreach (x; 0 .. w) {
            ubyte val = bitmap[y * w + x];
            line[x] = val > 128 ? '#' : (val > 32 ? '.' : ' ');
        }
        writefln("  %s", line[0 .. w]);
    }

    stbtt_FreeBitmap(bitmap, null);
    writeln("Spike S3 concluído com SUCESSO: stb_truetype totalmente funcional no D!");
}
