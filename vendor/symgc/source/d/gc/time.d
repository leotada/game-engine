module d.gc.time;

import core.time;

enum ulong Microsecond = 10;
enum ulong Millisecond = 1000 * Microsecond;
enum ulong Second = 1000 * Millisecond;
enum ulong Minute = 60 * Second;
enum ulong Hour = 60 * Minute;
enum ulong Day = 24 * Hour;
enum ulong Week = 7 * Day;

pragma(inline, true)
ulong getMonotonicTime() {
	version(Posix) {
		import core.sys.posix.time : clock_gettime, CLOCK_MONOTONIC, timespec;
		timespec ts = void;
		clock_gettime(CLOCK_MONOTONIC, &ts);
		return cast(ulong) ts.tv_sec * 10_000_000UL + cast(ulong) ts.tv_nsec / 100UL;
	} else {
		auto cur = MonoTime.currTime();
		return (cur - MonoTime.zero).total!"hnsecs";
	}
}

version(Windows) {
	import core.sys.windows.basetsd : HANDLE;
	import core.sys.windows.winnt : LARGE_INTEGER, TIMER_ALL_ACCESS, DWORD, BOOL, LONG;

	enum DWORD CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x00000002;
	extern(Windows) nothrow @nogc {
		HANDLE CreateWaitableTimerExW(void*, const(wchar)*, DWORD, DWORD);
		BOOL SetWaitableTimer(HANDLE, const(LARGE_INTEGER)*, LONG, void*, void*, BOOL);
		DWORD WaitForSingleObject(HANDLE, DWORD);
		BOOL CloseHandle(HANDLE);
	}
}

/**
 * Sleep for about `us` microseconds. The collector paces itself with sleeps
 * of 50 to 100 microseconds, which Posix gives. Windows sleeps in ticks of
 * the system timer (a millisecond at best), so a short wait yields the core
 * instead of sleeping a whole tick, and a longer one sleeps in whole
 * milliseconds.
 */
void sleepMicros(uint us) {
	version(Windows) {
		import core.sys.windows.winbase : Sleep, SwitchToThread;

		if (us < 100) {
			SwitchToThread();
			return;
		}

		LARGE_INTEGER dueTime;
		// Negative value in units of 100ns indicates relative time
		dueTime.QuadPart = -(cast(long) us * 10L);
		HANDLE timer = CreateWaitableTimerExW(null, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
		if (timer !is null) {
			if (SetWaitableTimer(timer, &dueTime, 0, null, null, false)) {
				WaitForSingleObject(timer, (us + 999) / 1000 + 1);
				CloseHandle(timer);
				return;
			}
			CloseHandle(timer);
		}

		if (us < 1000) {
			SwitchToThread();
		} else {
			Sleep((us + 999) / 1000);
		}
	} else version(Posix) {
		import core.sys.posix.unistd : usleep;
		usleep(us);
	}
}
