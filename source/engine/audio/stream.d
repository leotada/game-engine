/// Compressed audio streaming (`stb_vorbis` OGG Vorbis) + lock-free SPSC PCM ring buffer.
/// Producer (`pump`) runs on the main/loader thread; consumer runs `@nogc` on the SDL3 audio thread.
module engine.audio.stream;

import bindings.stb_vorbis;
import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.stdc.stdlib : calloc, free;
import core.stdc.string : memcpy;

@safe:

/// Optional polymorphic decoder interface for off-thread compressed audio decoding.
interface AudioStreamDecoder {
    int channels() const nothrow @nogc;
    int sampleRate() const nothrow @nogc;
    int decodeInterleavedF32(float[] outSamples) nothrow @nogc;
    bool seekStart() nothrow @nogc;
    void close() nothrow @nogc;
}

/// Lock-free Single-Producer Single-Consumer ring buffer storing interleaved F32 PCM frames.
/// Capacity is rounded up to a power of two in frames.
struct PcmRingBuffer {
    @disable this(this);

    private float* _buf = null;
    private uint _frameMask = 0;
    private uint _frameCapacity = 0;
    private uint _channels = 2;
    private shared size_t _writeFrame = 0;
    private shared size_t _readFrame = 0;

    bool init(uint channels, uint minFrames = 32_768) nothrow @nogc @trusted {
        destroy();
        immutable uint ch = channels == 1 ? 1 : 2;
        uint cap = 64;
        while (cap < minFrames && cap < (1u << 20))
            cap <<= 1;

        auto ptr = cast(float*) calloc(cast(size_t) cap * ch, float.sizeof);
        if (ptr is null)
            return false;

        _buf = ptr;
        _frameCapacity = cap;
        _frameMask = cap - 1u;
        _channels = ch;
        atomicStore!(MemoryOrder.rel)(_writeFrame, 0);
        atomicStore!(MemoryOrder.rel)(_readFrame, 0);
        return true;
    }

    ~this() nothrow @nogc @trusted {
        destroy();
    }

    void destroy() nothrow @nogc @trusted {
        if (_buf !is null) {
            free(_buf);
            _buf = null;
        }
        _frameCapacity = 0;
        _frameMask = 0;
        atomicStore!(MemoryOrder.rel)(_writeFrame, 0);
        atomicStore!(MemoryOrder.rel)(_readFrame, 0);
    }

    bool valid() const pure nothrow @nogc {
        return _buf !is null && _frameCapacity > 0;
    }

    uint channels() const pure nothrow @nogc {
        return _channels;
    }

    uint readableFrames() const nothrow @nogc @trusted {
        immutable w = atomicLoad!(MemoryOrder.acq)(_writeFrame);
        immutable r = atomicLoad!(MemoryOrder.raw)(_readFrame);
        return cast(uint)(w - r);
    }

    uint writableFrames() const nothrow @nogc @trusted {
        immutable w = atomicLoad!(MemoryOrder.raw)(_writeFrame);
        immutable r = atomicLoad!(MemoryOrder.acq)(_readFrame);
        return _frameCapacity - cast(uint)(w - r);
    }

    /// Producer-only: push up to `frames` interleaved samples into the ring buffer.
    uint pushFrames(scope const(float)* src, uint frames) nothrow @nogc @trusted {
        if (!valid() || src is null || frames == 0)
            return 0;
        immutable uint avail = writableFrames();
        immutable uint toWrite = frames < avail ? frames : avail;
        if (toWrite == 0)
            return 0;

        immutable size_t w = atomicLoad!(MemoryOrder.raw)(_writeFrame);
        immutable uint startIdx = cast(uint)(w & _frameMask);
        immutable uint firstChunk = _frameCapacity - startIdx;
        if (toWrite <= firstChunk) {
            memcpy(_buf + cast(size_t) startIdx * _channels, src,
                cast(size_t) toWrite * _channels * float.sizeof);
        } else {
            memcpy(_buf + cast(size_t) startIdx * _channels, src,
                cast(size_t) firstChunk * _channels * float.sizeof);
            immutable uint rem = toWrite - firstChunk;
            memcpy(_buf, src + cast(size_t) firstChunk * _channels,
                cast(size_t) rem * _channels * float.sizeof);
        }

        atomicStore!(MemoryOrder.rel)(_writeFrame, w + toWrite);
        return toWrite;
    }

    /// Consumer-only: pop 1 interleaved frame (`channels` floats). Returns false if empty.
    bool popFrame(ref float[2] outFrame) nothrow @nogc @trusted {
        if (!valid())
            return false;
        immutable size_t w = atomicLoad!(MemoryOrder.acq)(_writeFrame);
        immutable size_t r = atomicLoad!(MemoryOrder.raw)(_readFrame);
        if (w == r)
            return false;

        immutable uint idx = cast(uint)(r & _frameMask);
        immutable size_t base = cast(size_t) idx * _channels;
        outFrame[0] = _buf[base];
        outFrame[1] = _channels > 1 ? _buf[base + 1] : _buf[base];
        atomicStore!(MemoryOrder.rel)(_readFrame, r + 1);
        return true;
    }

    /// Consumer-only: discard any buffered frames (call while audio stream is locked or idle).
    void clear() nothrow @nogc @trusted {
        immutable size_t w = atomicLoad!(MemoryOrder.acq)(_writeFrame);
        atomicStore!(MemoryOrder.rel)(_readFrame, w);
    }
}

/// Streaming OGG Vorbis source backed by `stb_vorbis` and a lock-free `PcmRingBuffer`.
/// Call `pump()` periodically (e.g., once per frame or on a loader thread) to keep the ring fed.
struct AudioStream {
    @disable this(this);

    private stb_vorbis* _vorbis = null;
    package PcmRingBuffer _ring;
    private int _channels = 2;
    private int _sampleRate = 48_000;
    private bool _loop = false;
    package shared bool _eof = false;

    /// Open an OGG Vorbis file from disk and prefill the ring buffer.
    static AudioStream openOggFile(scope const(char)[] path,
                                   bool loop = false,
                                   uint bufferFrames = 32_768) nothrow @nogc @trusted {
        AudioStream s;
        if (path.length == 0 || path.length >= 1024)
            return s;

        char[1024] cPath = void;
        memcpy(cPath.ptr, path.ptr, path.length);
        cPath[path.length] = '\0';

        int errCode = 0;
        auto v = stb_vorbis_open_filename(cPath.ptr, &errCode, null);
        if (v is null)
            return s;
        s.initFromHandle(v, loop, bufferFrames);
        return s;
    }

    /// Open an OGG Vorbis stream from an in-memory buffer (caller must keep `oggBytes` alive
    /// while `AudioStream` is open).
    static AudioStream openOggMemory(scope const(ubyte)[] oggBytes,
                                     bool loop = false,
                                     uint bufferFrames = 32_768) nothrow @nogc @trusted {
        AudioStream s;
        if (oggBytes.length == 0 || oggBytes.length > int.max)
            return s;

        int errCode = 0;
        auto v = stb_vorbis_open_memory(oggBytes.ptr, cast(int) oggBytes.length, &errCode, null);
        if (v is null)
            return s;
        s.initFromHandle(v, loop, bufferFrames);
        return s;
    }

    ~this() nothrow @nogc @trusted {
        close();
    }

    void close() nothrow @nogc @trusted {
        if (_vorbis !is null) {
            stb_vorbis_close(_vorbis);
            _vorbis = null;
        }
        _ring.destroy();
        atomicStore!(MemoryOrder.rel)(_eof, true);
    }

    bool isValid() const pure nothrow @nogc {
        return _vorbis !is null && _ring.valid();
    }

    int channels() const pure nothrow @nogc {
        return _channels;
    }

    int sampleRate() const pure nothrow @nogc {
        return _sampleRate;
    }

    bool isLooping() const pure nothrow @nogc {
        return _loop;
    }

    void setLooping(bool loop) pure nothrow @nogc {
        _loop = loop;
    }

    bool isEof() const nothrow @nogc @trusted {
        return atomicLoad!(MemoryOrder.acq)(_eof);
    }

    uint bufferedFrames() const nothrow @nogc {
        return _ring.readableFrames();
    }

    bool seekStart() nothrow @nogc @trusted {
        if (_vorbis is null)
            return false;
        immutable ok = stb_vorbis_seek_start(_vorbis) != 0;
        if (ok)
            atomicStore!(MemoryOrder.rel)(_eof, false);
        return ok;
    }

    /// Decode up to `maxFrames` from OGG Vorbis into the lock-free ring buffer.
    /// Returns total frames decoded in this call.
    uint pump(uint maxFrames = 4096) nothrow @nogc @trusted {
        if (!isValid() || isEof())
            return 0;

        immutable uint ch = cast(uint) _channels;
        immutable uint writable = _ring.writableFrames();
        uint remaining = maxFrames < writable ? maxFrames : writable;
        if (remaining == 0)
            return 0;

        float[2048] temp = void;
        immutable uint maxChunkFrames = cast(uint)(temp.length / ch);
        uint totalDecoded = 0;

        while (remaining > 0) {
            uint chunk = remaining < maxChunkFrames ? remaining : maxChunkFrames;
            immutable int got = stb_vorbis_get_samples_float_interleaved(
                _vorbis, _channels, temp.ptr, cast(int)(chunk * ch));
            if (got > 0) {
                immutable uint pushed = _ring.pushFrames(temp.ptr, cast(uint) got);
                totalDecoded += pushed;
                remaining -= pushed;
                if (pushed < cast(uint) got)
                    break;
            } else {
                if (_loop) {
                    if (stb_vorbis_seek_start(_vorbis) == 0) {
                        atomicStore!(MemoryOrder.rel)(_eof, true);
                        break;
                    }
                    // Guard against empty stream infinite loop
                    if (totalDecoded == 0) {
                        immutable int retry = stb_vorbis_get_samples_float_interleaved(
                            _vorbis, _channels, temp.ptr, cast(int)(chunk * ch));
                        if (retry <= 0) {
                            atomicStore!(MemoryOrder.rel)(_eof, true);
                            break;
                        }
                        immutable uint pushed = _ring.pushFrames(temp.ptr, cast(uint) retry);
                        totalDecoded += pushed;
                        remaining -= pushed;
                    }
                } else {
                    atomicStore!(MemoryOrder.rel)(_eof, true);
                    break;
                }
            }
        }
        return totalDecoded;
    }

private:
    void initFromHandle(stb_vorbis* v, bool loop, uint bufferFrames) nothrow @nogc @trusted {
        immutable info = stb_vorbis_get_info(v);
        if (info.channels <= 0 || info.sample_rate == 0) {
            stb_vorbis_close(v);
            return;
        }
        immutable uint clampedCh = info.channels >= 2 ? 2 : 1;
        if (!_ring.init(clampedCh, bufferFrames)) {
            stb_vorbis_close(v);
            return;
        }
        _vorbis = v;
        _channels = info.channels > 2 ? 2 : info.channels;
        _sampleRate = cast(int) info.sample_rate;
        _loop = loop;
        atomicStore!(MemoryOrder.rel)(_eof, false);
        pump(bufferFrames / 2);
    }
}

@safe nothrow @nogc unittest {
    PcmRingBuffer ring;
    assert(ring.init(2, 64));
    float[8] inData = [0.1f, 0.2f, 0.3f, 0.4f, 0.5f, 0.6f, 0.7f, 0.8f];
    assert(ring.pushFrames(inData.ptr, 4) == 4);
    assert(ring.readableFrames() == 4);

    float[2] frame;
    assert(ring.popFrame(frame) && frame[0] == 0.1f && frame[1] == 0.2f);
    assert(ring.popFrame(frame) && frame[0] == 0.3f && frame[1] == 0.4f);
    assert(ring.readableFrames() == 2);
    ring.clear();
    assert(ring.readableFrames() == 0);
    assert(!ring.popFrame(frame));
}
