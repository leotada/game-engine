/// C99 ImportC bindings for `stb_vorbis` (OGG Vorbis decoding).
module bindings.stb_vorbis;

@safe:

struct stb_vorbis;

struct stb_vorbis_info {
    uint sample_rate;
    int channels;
    uint setup_memory_required;
    uint setup_temp_memory_required;
    uint temp_memory_required;
    int max_frame_size;
}

extern(C) nothrow @nogc:

stb_vorbis* stb_vorbis_open_filename(const(char)* filename, int* error, const(void)* alloc_buffer);
stb_vorbis* stb_vorbis_open_memory(const(ubyte)* data, int len, int* error, const(void)* alloc_buffer);
stb_vorbis_info stb_vorbis_get_info(stb_vorbis* f);
int stb_vorbis_get_samples_float_interleaved(stb_vorbis* f, int channels, float* buffer, int num_floats);
int stb_vorbis_seek_start(stb_vorbis* f);
uint stb_vorbis_stream_length_in_samples(stb_vorbis* f);
void stb_vorbis_close(stb_vorbis* f);
