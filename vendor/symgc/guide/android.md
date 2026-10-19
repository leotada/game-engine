# Android

**Status, 2026-10-12: untested.** The collector compiles for `aarch64-linux-android` with the card barrier. It has
never been linked or run on Android: the development machine has no NDK, emulator or device. This page is the plan for
the first session that has them, written from LDC's documentation and from reading the code, and it will contain
mistakes. Whoever runs it first should correct it.

Android means LDC: neither DMD nor GDC can target it.

## What is already done in the collector

Three things would have broken on a phone, and are handled (they are described in `how-it-works.md`, "The card window"):

* **Tagged pointers.** Since Android 11, `malloc` on arm64 hands out pointers with a tag in the top byte. A barrier that
  indexes the card table with the raw address would write far outside the table. The barrier is range checked against
  the collector's window, so such a store marks nothing.
* **Start-up in a shared library.** A game on Android is a `.so`, and Android ignores `.preinit_array` in shared
  libraries. The card table is set up by the collector when it starts, and until then every barrier is a no-op, so no
  hook has to run first.
* **A small address space.** Many devices give a process 39 bits (512 GiB for everything). The window defaults to
  16 GiB there, and the collector halves its request until the system agrees, down to 2 GiB.

And one thing the code does differently on Android: `sched_getcpu` needs API level 29, and the loader refuses a library
that names a symbol the device does not have, so a thread picks its arena from its thread id instead.

## What a first session has to do

1. **A runtime for Android.** druntime and Phobos cross-built for the target, with `-gc-card-marking`, by
   `ldc-build-runtime` (check `ldc-build-runtime --help`; the options below are from the LDC wiki, "Build D for
   Android"). Roughly:

   ```sh
   ldc-build-runtime --ldcSrcDir=<ldc checkout> --buildDir=android-aarch64 \
     --dFlags="-mtriple=aarch64-linux-android21;-gc-card-marking" \
     --targetSystem="Android;Linux;UNIX" \
     CMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
     ANDROID_ABI=arm64-v8a ANDROID_NATIVE_API_LEVEL=21
   ```

   plus a section in `ldc2.conf` for `aarch64-.*-linux-android` that points at that build's `lib` directory, and
   `-gcc=$ANDROID_NDK/toolchains/llvm/prebuilt/<host>/bin/aarch64-linux-android21-clang` to link. Use `x86_64` for an
   emulator on an x86-64 host.
2. **Start with executables, not an APK.** Android lets `adb shell` run a native executable. Build the correctness tests
   as executables, push them and run them:

   ```sh
   ldc2 -mtriple=aarch64-linux-android21 -O3 -release -gc-card-marking \
     -d-version=Symgc_cards -d-version=Symgc_druntime_hooks -Isymgc/source \
     -of=cards_window plans/bench/core_bench/cards_window.d $(find symgc/source -name '*.d')
   adb push cards_window /data/local/tmp/ && adb shell /data/local/tmp/cards_window --DRT-gcopt=gc:sdcq
   ```

   In this order: `cards_window` (the window, the tag, the fallback), `mark_race`, `finalizer_order`,
   `thread_exit_race`, `phobos_stress`. The first is the cheap canary; the second is the one that proves the barrier
   and the mark work together.
3. **Then a shared library**, because that is what a game is: the same test code built `-shared` into a `.so`, loaded by a
   small native program with `dlopen`, calling a function that runs `rt_init`, the test and `rt_term`. This is the
   case `.preinit_array` could not have worked for.
4. **Then a frame loop on a device**: `bullet_hell_stress.d` at a heap that fits the device (try 512 MiB), with
   `GC.frameStats()` on screen, at 60 fps, to see where the pauses are on a phone's cores. Phones mix fast and slow
   cores and throttle when hot; where the two mark threads run (`SYMGC_MARK_THREADS`) will matter.

## What each kind of emulator or device tests

| | Bionic libc, `adb shell` executables, `.so` loading | Tagged malloc pointers | Real arm64 timing |
|---|---|---|---|
| x86_64 emulator image (fast on an x86-64 host) | yes | **no**: x86-64 has no top-byte tagging, so `malloc` returns plain pointers | no |
| arm64 emulator image (slow: translated) | yes | yes, on an image with tagging enabled | no |
| arm64 device | yes | yes | yes |

So the x86_64 emulator is the right first target for everything except the tag, which `cards_window` covers by calling
the barrier's range function with a tagged address (it cannot store through one on x86-64). Tagging needs an arm64
image or a device, and Android 11 or later.

## Things to look at, not yet checked

* **Signals.** The collector stops threads with signals (`SIGSUSPEND`, `SIGRESUME` in `d/gc/signal.d`). ART installs its
  own handlers and chains signals; check that neither side eats the other's.
* **`madvise(MADV_DONTNEED)`** to return pages: fine on Linux, check it on the Android kernel in use.
* **App lifecycle.** Stop the GC threads (or at least the sweeper's pacing) when the activity pauses, and call
  `GC.defrag()` on `onTrimMemory`.
* **Memory limits.** Android may kill the process well before the window is exhausted; `GC.frameStats().usedSize` is
  the number to watch.
* **The kernel tracker is not an option on phones**: it needs Linux 6.7+, and it is x86-64 only as written.
