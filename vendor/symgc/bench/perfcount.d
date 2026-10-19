/**
 * Minimal user-space hardware counters through perf_event_open (no `perf` binary needed).
 * Counts only user-mode events, which kernel.perf_event_paranoid <= 2 allows.
 */
module perfcount;

import core.sys.posix.unistd : read, close;

extern (C) nothrow @nogc
{
    long syscall(long number, ...);
    int ioctl(int fd, ulong request, ...);
}

private enum SYS_perf_event_open = 298; // x86-64 Linux
private enum PERF_TYPE_HARDWARE = 0;
private enum PERF_TYPE_HW_CACHE = 3;
enum PERF_COUNT_HW_CPU_CYCLES = 0;
enum PERF_COUNT_HW_INSTRUCTIONS = 1;
enum PERF_COUNT_HW_CACHE_REFERENCES = 2;   // on AMD Zen: L2 requests (last-level reference)
enum PERF_COUNT_HW_CACHE_MISSES = 3;       // on AMD Zen: L2 misses (last-level miss)

struct PerfEventAttr
{
    uint type;
    uint size;
    ulong config;
    ulong samplePeriod;
    ulong sampleType;
    ulong readFormat;
    ulong flags;          // bit 0 disabled, bit 5 exclude_kernel, bit 6 exclude_hv
    uint wakeupEvents;
    uint bpType;
    ulong bpAddr;
    ulong bpLen;
    ulong branchSampleType;
    ulong sampleRegsUser;
    uint sampleStackUser;
    int clockid;
    ulong sampleRegsIntr;
    uint auxWatermark;
    ushort sampleMaxStack;
    ushort reserved2;
}

struct PerfCounter
{
    int fd = -1;

    static PerfCounter open(ulong hwConfig)
    {
        PerfEventAttr a;
        a.type = PERF_TYPE_HARDWARE;
        a.size = PerfEventAttr.sizeof;
        a.config = hwConfig;
        a.flags = (1 << 0) | (1 << 5) | (1 << 6); // disabled, exclude kernel and hypervisor
        PerfCounter c;
        c.fd = cast(int) syscall(SYS_perf_event_open, &a, 0, -1, -1, 0);
        return c;
    }

    bool ok() const { return fd >= 0; }

    private enum PERF_EVENT_IOC_ENABLE = 0x2400;
    private enum PERF_EVENT_IOC_DISABLE = 0x2401;
    private enum PERF_EVENT_IOC_RESET = 0x2403;

    void start()
    {

        if (fd < 0) return;
        ioctl(fd, PERF_EVENT_IOC_RESET, 0);
        ioctl(fd, PERF_EVENT_IOC_ENABLE, 0);
    }

    ulong stop()
    {

        if (fd < 0) return 0;
        ioctl(fd, PERF_EVENT_IOC_DISABLE, 0);
        ulong v;
        read(fd, &v, v.sizeof);
        return v;
    }

    void close_()
    {
        if (fd >= 0) close(fd);
        fd = -1;
    }
}

version (PerfCountMain)
{
    import std.stdio;
    void main()
    {
        auto cm = PerfCounter.open(PERF_COUNT_HW_CACHE_MISSES);
        auto ci = PerfCounter.open(PERF_COUNT_HW_INSTRUCTIONS);
        writeln("cache-misses counter ", cm.ok ? "available" : "NOT available", ", instructions ", ci.ok ? "available" : "NOT available");
        if (!cm.ok) return;
        auto a = new long[](64 * 1024 * 1024 / 8);
        cm.start(); ci.start();
        long s;
        foreach (i; 0 .. 20_000_000)
            s += a[(i * 104729UL) % a.length];
        auto m = cm.stop(); auto n = ci.stop();
        writeln("sum ", s, " cache-misses ", m, " instructions ", n);
    }
}
