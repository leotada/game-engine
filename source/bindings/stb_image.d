/// Manual bindings to stb_image (C99 single-header image loader).
module bindings.stb_image;

@safe:

extern(C) nothrow @nogc {
    ubyte* stbi_load(const(char)* filename, int* x, int* y, int* channels_in_file, int desired_channels);
    ubyte* stbi_load_from_memory(const(ubyte)* buffer, int len, int* x, int* y, int* channels_in_file, int desired_channels);
    void stbi_image_free(void* retval_from_stbi_load);
    void stbi_set_flip_vertically_on_load(int flag_true_if_should_flip);
    const(char)* stbi_failure_reason();
}
