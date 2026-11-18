/// SDL3_image bindings for the game engine.
/// Supports static linkage (`-version=StaticSDLDeps` for release exports)
/// and lazy dynamic loading via `SDL_LoadObject` during engine development.
module bindings.sdl3_image;

import bindings.sdl3;

@safe:

struct IMG_Animation {
    int w;
    int h;
    int count;
    SDL_Surface** frames;
    int* delays;
}

version (StaticSDLDeps) {
    bool imgInit() nothrow @nogc { return true; }
    bool imgIsAvailable() nothrow @nogc { return true; }

    extern (C) nothrow @nogc @system {
        int IMG_Version();

        SDL_Surface* IMG_Load(const(char)* file);
        SDL_Surface* IMG_Load_IO(SDL_IOStream* src, bool closeio);
        SDL_Surface* IMG_LoadTyped_IO(SDL_IOStream* src, bool closeio, const(char)* type);

        SDL_Surface* IMG_LoadPNG_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadJPG_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadWEBP_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadAVIF_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadQOI_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadTGA_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadBMP_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadGIF_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadSVG_IO(SDL_IOStream* src);
        SDL_Surface* IMG_LoadSizedSVG_IO(SDL_IOStream* src, int width, int height);

        bool IMG_isPNG(SDL_IOStream* src);
        bool IMG_isJPG(SDL_IOStream* src);
        bool IMG_isWEBP(SDL_IOStream* src);
        bool IMG_isAVIF(SDL_IOStream* src);
        bool IMG_isQOI(SDL_IOStream* src);
        bool IMG_isBMP(SDL_IOStream* src);
        bool IMG_isGIF(SDL_IOStream* src);
        bool IMG_isSVG(SDL_IOStream* src);
        bool IMG_isTIF(SDL_IOStream* src);

        bool IMG_SavePNG(SDL_Surface* surface, const(char)* file);
        bool IMG_SavePNG_IO(SDL_Surface* surface, SDL_IOStream* dst, bool closeio);
        bool IMG_SaveJPG(SDL_Surface* surface, const(char)* file, int quality);
        bool IMG_SaveJPG_IO(SDL_Surface* surface, SDL_IOStream* dst, bool closeio, int quality);
        bool IMG_SaveAVIF(SDL_Surface* surface, const(char)* file, int quality);
        bool IMG_SaveAVIF_IO(SDL_Surface* surface, SDL_IOStream* dst, bool closeio, int quality);

        IMG_Animation* IMG_LoadAnimation(const(char)* file);
        IMG_Animation* IMG_LoadAnimation_IO(SDL_IOStream* src, bool closeio);
        IMG_Animation* IMG_LoadAnimationTyped_IO(SDL_IOStream* src, bool closeio, const(char)* type);
        void IMG_FreeAnimation(IMG_Animation* anim);
    }
} else {
    private extern (C) nothrow @nogc {
        alias FnIMG_Version              = int function();
        alias FnIMG_Load                 = SDL_Surface* function(const(char)*);
        alias FnIMG_Load_IO              = SDL_Surface* function(SDL_IOStream*, bool);
        alias FnIMG_LoadTyped_IO         = SDL_Surface* function(SDL_IOStream*, bool, const(char)*);
        alias FnIMG_LoadFromIO           = SDL_Surface* function(SDL_IOStream*);
        alias FnIMG_LoadSizedSVG_IO      = SDL_Surface* function(SDL_IOStream*, int, int);
        alias FnIMG_IsType               = bool function(SDL_IOStream*);
        alias FnIMG_SavePNG              = bool function(SDL_Surface*, const(char)*);
        alias FnIMG_SavePNG_IO           = bool function(SDL_Surface*, SDL_IOStream*, bool);
        alias FnIMG_SaveQuality          = bool function(SDL_Surface*, const(char)*, int);
        alias FnIMG_SaveQuality_IO       = bool function(SDL_Surface*, SDL_IOStream*, bool, int);
        alias FnIMG_LoadAnimation        = IMG_Animation* function(const(char)*);
        alias FnIMG_LoadAnimation_IO     = IMG_Animation* function(SDL_IOStream*, bool);
        alias FnIMG_LoadAnimationTypedIO = IMG_Animation* function(SDL_IOStream*, bool, const(char)*);
        alias FnIMG_FreeAnimation        = void function(IMG_Animation*);
    }

    private __gshared {
        SDL_SharedObject* gImgLib = null;
        bool gImgAttempted = false;
        bool gImgAvailable = false;

        FnIMG_Version              pIMG_Version;
        FnIMG_Load                 pIMG_Load;
        FnIMG_Load_IO              pIMG_Load_IO;
        FnIMG_LoadTyped_IO         pIMG_LoadTyped_IO;
        FnIMG_LoadFromIO           pIMG_LoadPNG_IO;
        FnIMG_LoadFromIO           pIMG_LoadJPG_IO;
        FnIMG_LoadFromIO           pIMG_LoadWEBP_IO;
        FnIMG_LoadFromIO           pIMG_LoadAVIF_IO;
        FnIMG_LoadFromIO           pIMG_LoadQOI_IO;
        FnIMG_LoadFromIO           pIMG_LoadTGA_IO;
        FnIMG_LoadFromIO           pIMG_LoadBMP_IO;
        FnIMG_LoadFromIO           pIMG_LoadGIF_IO;
        FnIMG_LoadFromIO           pIMG_LoadSVG_IO;
        FnIMG_LoadSizedSVG_IO      pIMG_LoadSizedSVG_IO;
        FnIMG_IsType               pIMG_isPNG;
        FnIMG_IsType               pIMG_isJPG;
        FnIMG_IsType               pIMG_isWEBP;
        FnIMG_IsType               pIMG_isAVIF;
        FnIMG_IsType               pIMG_isQOI;
        FnIMG_IsType               pIMG_isBMP;
        FnIMG_IsType               pIMG_isGIF;
        FnIMG_IsType               pIMG_isSVG;
        FnIMG_IsType               pIMG_isTIF;
        FnIMG_SavePNG              pIMG_SavePNG;
        FnIMG_SavePNG_IO           pIMG_SavePNG_IO;
        FnIMG_SaveQuality          pIMG_SaveJPG;
        FnIMG_SaveQuality_IO       pIMG_SaveJPG_IO;
        FnIMG_SaveQuality          pIMG_SaveAVIF;
        FnIMG_SaveQuality_IO       pIMG_SaveAVIF_IO;
        FnIMG_LoadAnimation        pIMG_LoadAnimation;
        FnIMG_LoadAnimation_IO     pIMG_LoadAnimation_IO;
        FnIMG_LoadAnimationTypedIO pIMG_LoadAnimationTyped_IO;
        FnIMG_FreeAnimation        pIMG_FreeAnimation;
    }

    private T loadSym(T)(SDL_SharedObject* lib, const(char)* name) nothrow @nogc @system {
        return cast(T) SDL_LoadFunction(lib, name);
    }

    /// Initialize dynamic SDL3_image library if available on host.
    bool imgInit() nothrow @nogc @trusted {
        if (gImgAttempted) return gImgAvailable;
        gImgAttempted = true;

        version (Windows) {
            static immutable const(char)*[1] candidates = ["SDL3_image.dll".ptr];
        } else version (OSX) {
            static immutable const(char)*[4] candidates = [
                "libSDL3_image.0.dylib".ptr,
                "libSDL3_image.dylib".ptr,
                "@executable_path/../Frameworks/libSDL3_image.dylib".ptr,
                "libs/macos-arm64/libSDL3_image.dylib".ptr,
            ];
        } else {
            static immutable const(char)*[4] candidates = [
                "libSDL3_image.so.0".ptr,
                "libSDL3_image.so".ptr,
                "libs/linux-x86_64/libSDL3_image.so".ptr,
                "libs/libSDL3_image.so".ptr,
            ];
        }

        foreach (cand; candidates) {
            gImgLib = SDL_LoadObject(cand);
            if (gImgLib !is null) break;
        }
        if (gImgLib is null) return false;

        pIMG_Version              = loadSym!FnIMG_Version(gImgLib, "IMG_Version");
        pIMG_Load                 = loadSym!FnIMG_Load(gImgLib, "IMG_Load");
        pIMG_Load_IO              = loadSym!FnIMG_Load_IO(gImgLib, "IMG_Load_IO");
        pIMG_LoadTyped_IO         = loadSym!FnIMG_LoadTyped_IO(gImgLib, "IMG_LoadTyped_IO");
        pIMG_LoadPNG_IO           = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadPNG_IO");
        pIMG_LoadJPG_IO           = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadJPG_IO");
        pIMG_LoadWEBP_IO          = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadWEBP_IO");
        pIMG_LoadAVIF_IO          = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadAVIF_IO");
        pIMG_LoadQOI_IO           = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadQOI_IO");
        pIMG_LoadTGA_IO           = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadTGA_IO");
        pIMG_LoadBMP_IO           = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadBMP_IO");
        pIMG_LoadGIF_IO           = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadGIF_IO");
        pIMG_LoadSVG_IO           = loadSym!FnIMG_LoadFromIO(gImgLib, "IMG_LoadSVG_IO");
        pIMG_LoadSizedSVG_IO      = loadSym!FnIMG_LoadSizedSVG_IO(gImgLib, "IMG_LoadSizedSVG_IO");
        pIMG_isPNG                = loadSym!FnIMG_IsType(gImgLib, "IMG_isPNG");
        pIMG_isJPG                = loadSym!FnIMG_IsType(gImgLib, "IMG_isJPG");
        pIMG_isWEBP               = loadSym!FnIMG_IsType(gImgLib, "IMG_isWEBP");
        pIMG_isAVIF               = loadSym!FnIMG_IsType(gImgLib, "IMG_isAVIF");
        pIMG_isQOI                = loadSym!FnIMG_IsType(gImgLib, "IMG_isQOI");
        pIMG_isBMP                = loadSym!FnIMG_IsType(gImgLib, "IMG_isBMP");
        pIMG_isGIF                = loadSym!FnIMG_IsType(gImgLib, "IMG_isGIF");
        pIMG_isSVG                = loadSym!FnIMG_IsType(gImgLib, "IMG_isSVG");
        pIMG_isTIF                = loadSym!FnIMG_IsType(gImgLib, "IMG_isTIF");
        pIMG_SavePNG              = loadSym!FnIMG_SavePNG(gImgLib, "IMG_SavePNG");
        pIMG_SavePNG_IO           = loadSym!FnIMG_SavePNG_IO(gImgLib, "IMG_SavePNG_IO");
        pIMG_SaveJPG              = loadSym!FnIMG_SaveQuality(gImgLib, "IMG_SaveJPG");
        pIMG_SaveJPG_IO           = loadSym!FnIMG_SaveQuality_IO(gImgLib, "IMG_SaveJPG_IO");
        pIMG_SaveAVIF             = loadSym!FnIMG_SaveQuality(gImgLib, "IMG_SaveAVIF");
        pIMG_SaveAVIF_IO          = loadSym!FnIMG_SaveQuality_IO(gImgLib, "IMG_SaveAVIF_IO");
        pIMG_LoadAnimation        = loadSym!FnIMG_LoadAnimation(gImgLib, "IMG_LoadAnimation");
        pIMG_LoadAnimation_IO     = loadSym!FnIMG_LoadAnimation_IO(gImgLib, "IMG_LoadAnimation_IO");
        pIMG_LoadAnimationTyped_IO = loadSym!FnIMG_LoadAnimationTypedIO(gImgLib, "IMG_LoadAnimationTyped_IO");
        pIMG_FreeAnimation        = loadSym!FnIMG_FreeAnimation(gImgLib, "IMG_FreeAnimation");

        gImgAvailable = pIMG_Load_IO !is null && pIMG_LoadTyped_IO !is null;
        return gImgAvailable;
    }

    bool imgIsAvailable() nothrow @nogc {
        return imgInit();
    }

    @system nothrow @nogc {
        int IMG_Version() {
            return imgInit() && pIMG_Version !is null ? pIMG_Version() : 0;
        }

        SDL_Surface* IMG_Load(const(char)* file) {
            if (imgInit() && pIMG_Load !is null) return pIMG_Load(file);
            return SDL_LoadSurface(file);
        }

        SDL_Surface* IMG_Load_IO(SDL_IOStream* src, bool closeio) {
            if (imgInit() && pIMG_Load_IO !is null) return pIMG_Load_IO(src, closeio);
            return SDL_LoadSurface_IO(src, closeio);
        }

        SDL_Surface* IMG_LoadTyped_IO(SDL_IOStream* src, bool closeio, const(char)* type) {
            if (imgInit() && pIMG_LoadTyped_IO !is null) return pIMG_LoadTyped_IO(src, closeio, type);
            return SDL_LoadSurface_IO(src, closeio);
        }

        SDL_Surface* IMG_LoadPNG_IO(SDL_IOStream* src) {
            if (imgInit() && pIMG_LoadPNG_IO !is null) return pIMG_LoadPNG_IO(src);
            return SDL_LoadPNG_IO(src, false);
        }

        SDL_Surface* IMG_LoadJPG_IO(SDL_IOStream* src) {
            return (imgInit() && pIMG_LoadJPG_IO !is null) ? pIMG_LoadJPG_IO(src) : null;
        }

        SDL_Surface* IMG_LoadWEBP_IO(SDL_IOStream* src) {
            return (imgInit() && pIMG_LoadWEBP_IO !is null) ? pIMG_LoadWEBP_IO(src) : null;
        }

        SDL_Surface* IMG_LoadAVIF_IO(SDL_IOStream* src) {
            return (imgInit() && pIMG_LoadAVIF_IO !is null) ? pIMG_LoadAVIF_IO(src) : null;
        }

        SDL_Surface* IMG_LoadQOI_IO(SDL_IOStream* src) {
            return (imgInit() && pIMG_LoadQOI_IO !is null) ? pIMG_LoadQOI_IO(src) : null;
        }

        SDL_Surface* IMG_LoadTGA_IO(SDL_IOStream* src) {
            return (imgInit() && pIMG_LoadTGA_IO !is null) ? pIMG_LoadTGA_IO(src) : null;
        }

        SDL_Surface* IMG_LoadBMP_IO(SDL_IOStream* src) {
            if (imgInit() && pIMG_LoadBMP_IO !is null) return pIMG_LoadBMP_IO(src);
            return SDL_LoadBMP_IO(src, false);
        }

        SDL_Surface* IMG_LoadGIF_IO(SDL_IOStream* src) {
            return (imgInit() && pIMG_LoadGIF_IO !is null) ? pIMG_LoadGIF_IO(src) : null;
        }

        SDL_Surface* IMG_LoadSVG_IO(SDL_IOStream* src) {
            return (imgInit() && pIMG_LoadSVG_IO !is null) ? pIMG_LoadSVG_IO(src) : null;
        }

        SDL_Surface* IMG_LoadSizedSVG_IO(SDL_IOStream* src, int width, int height) {
            return (imgInit() && pIMG_LoadSizedSVG_IO !is null) ? pIMG_LoadSizedSVG_IO(src, width, height) : null;
        }

        bool IMG_isPNG(SDL_IOStream* src)  { return (imgInit() && pIMG_isPNG !is null)  ? pIMG_isPNG(src)  : false; }
        bool IMG_isJPG(SDL_IOStream* src)  { return (imgInit() && pIMG_isJPG !is null)  ? pIMG_isJPG(src)  : false; }
        bool IMG_isWEBP(SDL_IOStream* src) { return (imgInit() && pIMG_isWEBP !is null) ? pIMG_isWEBP(src) : false; }
        bool IMG_isAVIF(SDL_IOStream* src) { return (imgInit() && pIMG_isAVIF !is null) ? pIMG_isAVIF(src) : false; }
        bool IMG_isQOI(SDL_IOStream* src)  { return (imgInit() && pIMG_isQOI !is null)  ? pIMG_isQOI(src)  : false; }
        bool IMG_isBMP(SDL_IOStream* src)  { return (imgInit() && pIMG_isBMP !is null)  ? pIMG_isBMP(src)  : false; }
        bool IMG_isGIF(SDL_IOStream* src)  { return (imgInit() && pIMG_isGIF !is null)  ? pIMG_isGIF(src)  : false; }
        bool IMG_isSVG(SDL_IOStream* src)  { return (imgInit() && pIMG_isSVG !is null)  ? pIMG_isSVG(src)  : false; }
        bool IMG_isTIF(SDL_IOStream* src)  { return (imgInit() && pIMG_isTIF !is null)  ? pIMG_isTIF(src)  : false; }

        bool IMG_SavePNG(SDL_Surface* surface, const(char)* file) {
            if (imgInit() && pIMG_SavePNG !is null) return pIMG_SavePNG(surface, file);
            return SDL_SavePNG(surface, file);
        }

        bool IMG_SavePNG_IO(SDL_Surface* surface, SDL_IOStream* dst, bool closeio) {
            if (imgInit() && pIMG_SavePNG_IO !is null) return pIMG_SavePNG_IO(surface, dst, closeio);
            return SDL_SavePNG_IO(surface, dst, closeio);
        }

        bool IMG_SaveJPG(SDL_Surface* surface, const(char)* file, int quality) {
            return (imgInit() && pIMG_SaveJPG !is null) ? pIMG_SaveJPG(surface, file, quality) : false;
        }

        bool IMG_SaveJPG_IO(SDL_Surface* surface, SDL_IOStream* dst, bool closeio, int quality) {
            return (imgInit() && pIMG_SaveJPG_IO !is null) ? pIMG_SaveJPG_IO(surface, dst, closeio, quality) : false;
        }

        bool IMG_SaveAVIF(SDL_Surface* surface, const(char)* file, int quality) {
            return (imgInit() && pIMG_SaveAVIF !is null) ? pIMG_SaveAVIF(surface, file, quality) : false;
        }

        bool IMG_SaveAVIF_IO(SDL_Surface* surface, SDL_IOStream* dst, bool closeio, int quality) {
            return (imgInit() && pIMG_SaveAVIF_IO !is null) ? pIMG_SaveAVIF_IO(surface, dst, closeio, quality) : false;
        }

        IMG_Animation* IMG_LoadAnimation(const(char)* file) {
            return (imgInit() && pIMG_LoadAnimation !is null) ? pIMG_LoadAnimation(file) : null;
        }

        IMG_Animation* IMG_LoadAnimation_IO(SDL_IOStream* src, bool closeio) {
            return (imgInit() && pIMG_LoadAnimation_IO !is null) ? pIMG_LoadAnimation_IO(src, closeio) : null;
        }

        IMG_Animation* IMG_LoadAnimationTyped_IO(SDL_IOStream* src, bool closeio, const(char)* type) {
            return (imgInit() && pIMG_LoadAnimationTyped_IO !is null) ? pIMG_LoadAnimationTyped_IO(src, closeio, type) : null;
        }

        void IMG_FreeAnimation(IMG_Animation* anim) {
            if (imgInit() && pIMG_FreeAnimation !is null) pIMG_FreeAnimation(anim);
        }
    }
}
