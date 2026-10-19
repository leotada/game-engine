module d.sync.darwin.waiter;

version(OSX) {
	version = Darwin;
} else version(iOS) {
	version = Darwin;
} else version(TVOS) {
	version = Darwin;
} else version(WatchOS) {
	version = Darwin;
}

version(Darwin):

import d.sync.atomic;
import core.stdc.errno;

extern(C) nothrow @nogc {
	// Darwin kernel user-space locking primitives exported by libSystem.B.dylib (macOS 10.12+, iOS 10+)
	enum uint UL_COMPARE_AND_WAIT = 1;
	enum uint ULF_NO_ERRNO = 0x01000000;

	int __ulock_wait(uint operation, void* addr, ulong value, uint timeout_us);
	int __ulock_wake(uint operation, void* addr, ulong wake_value);
}

struct DarwinWaiter {
	Atomic!uint wakeupCount;

	bool block( /* TODO: timeout */ ) shared {
		while (true) {
			auto c = wakeupCount.load();
			while (c > 0) {
				if (wakeupCount.casWeak(c, c - 1)) {
					// We consumed a wake up.
					return true;
				}
			}

			assert(c == 0, "Failed to consume wake up!");

			// Darwin __ulock_wait: operation, address, expected_value, timeout_us
			auto ret = __ulock_wait(UL_COMPARE_AND_WAIT | ULF_NO_ERRNO, cast(void*)&wakeupCount, 0, 0);
			if (ret < 0) {
				auto err = -ret;
				switch (err) {
					case EINTR, EWOULDBLOCK:
						continue;

					case ETIMEDOUT:
						return false;

					default:
						assert(0, "darwin ulock_wait operation failed!");
				}
			}
		}
	}

	void wakeup() shared {
		auto wuc = wakeupCount.fetchAdd(1);
		if (wuc == 0) {
			poke();
		}
	}

	void poke() shared {
		auto ret = __ulock_wake(UL_COMPARE_AND_WAIT | ULF_NO_ERRNO, cast(void*)&wakeupCount, 0);
		// Note: -ENOENT simply means no thread was waiting on the address, which is normal
		if (ret < 0 && -ret != ENOENT) {
			assert(0, "darwin ulock_wake operation failed!");
		}
	}
}
