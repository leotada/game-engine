module d.gc.dirty;

/**
 * Which pages of the scannable heap were written since we last looked.
 *
 * A concurrent mark scans objects while the program changes them. A pointer
 * stored into an object the marker already scanned is lost unless something
 * tells the collector to look again. The compiler could say so (a write
 * barrier), but that excludes every other compiler, C, and the kernel writing
 * into a buffer. The kernel can say so instead, for any write: Linux 6.7 and
 * later write-protect pages on request and report the written ones through
 * `PAGEMAP_SCAN`, with `userfaultfd` in asynchronous mode so that the first
 * write to a protected page is handled in the kernel, without a signal or a
 * handler. plans/spikes/dirty measures it: arming 2 GiB takes 13 ms (0.2 ms
 * with huge pages), scanning takes 1 to 10 ms for up to 400,000 dirty pages,
 * and a writer pays under 1 us once per page.
 *
 * A mark that uses this must treat every page reported here as a root range
 * (the "dirty rescan" of a mostly-concurrent collector), and rescan roots and
 * stacks while the world is stopped. Where the kernel cannot do this,
 * `dirtyAvailable` is false and the collector must stop the world for the whole
 * mark.
 *
 * Only memory that holds pointers is registered: the data region is not
 * scanned, so there is nothing to track.
 */

import d.sync.mutex;

version(Symgc_cards) {
	// Card marking active: kernel dirty-page tracking is omitted completely
} else version(linux) version(X86_64) {
	version = DirtyTracking;
}

alias DirtyRangeDg = void delegate(const(void)* start, size_t size);

/**
 * With `Symgc_cards`, the ranges to look at are the ones that hold pointers;
 * the cards themselves are in d.gc.cards.
 */
version(Symgc_cards) {
	enum MaxCardRanges = 4096;

	struct CardRanges {
		Mutex mutex;
		size_t count;
		size_t[MaxCardRanges] starts;
		size_t[MaxCardRanges] sizes;

	shared:
		bool available() {
			import core.stdc.stdlib : getenv;
			auto env = getenv("SYMGC_CONCURRENT_MARK");
			return env is null || env[0] != '0';
		}

		void register(void* start, size_t size) {
			mutex.lock();
			scope(exit) mutex.unlock();

			auto t = cast(CardRanges*) &this;
			assert(t.count < MaxCardRanges, "Too many pointer regions!");
			t.starts[t.count] = cast(size_t) start;
			t.sizes[t.count] = size;
			t.count++;
		}

		size_t collect(scope DirtyRangeDg dg) {
			mutex.lock();
			scope(exit) mutex.unlock();

			import d.gc.cards;
			auto t = cast(CardRanges*) &this;
			size_t pages = 0;
			foreach (i; 0 .. t.count) {
				pages += collectCards(t.starts[i], t.sizes[i], dg);
			}

			return pages;
		}
	}

	shared CardRanges gCardRanges;
}

/**
 * Is tracking available? Decided once, on the first call.
 */
bool dirtyAvailable() {
	version(Symgc_cards) {
		return gCardRanges.available();
	} else version(DirtyTracking) {
		return gDirty.ensureInit();
	} else {
		return false;
	}
}

/**
 * Track the writes to a mapping that holds pointers. Called when the mapping
 * is created, with the world running. If the mapping cannot be tracked,
 * tracking is turned off for good: a mark that missed a range would be unsound.
 */
void dirtyRegister(void* start, size_t size) {
	version(Symgc_cards) {
		gCardRanges.register(start, size);
	} else version(DirtyTracking) {
		gDirty.register(start, size);
	}
}

/**
 * Mark every tracked page as unwritten. Pages that nobody armed yet are
 * reported as written by the next `dirtyCollect`, which only makes the set
 * larger, so arming is an optimization and never needed for correctness.
 */
void dirtyArm() {
	version(Symgc_cards) {
		gCardRanges.collect(null);
	} else version(DirtyTracking) {
		gDirty.collect(null);
	}
}

/**
 * Call `dg` with every range written since the last `dirtyArm` or
 * `dirtyCollect`, and (when `rearm` is true) mark those pages as unwritten
 * again. Returns the number of pages reported.
 */
size_t dirtyCollect(scope DirtyRangeDg dg, bool rearm = true) {
	version(Symgc_cards) {
		return gCardRanges.collect(dg);
	} else version(DirtyTracking) {
		return gDirty.collect(dg, rearm);
	} else {
		return 0;
	}
}

version(DirtyTracking):

private:

// The numbers of <linux/userfaultfd.h> and <linux/fs.h>, x86-64.
enum SYS_userfaultfd = 323;
enum UFFD_USER_MODE_ONLY = 1;
enum O_CLOEXEC = 0x80000;
enum O_NONBLOCK = 0x800;
enum UFFD_API = 0xAA;
enum UFFD_FEATURE_WP_UNPOPULATED = 1UL << 13;
enum UFFD_FEATURE_WP_ASYNC = 1UL << 15;
enum UFFDIO_REGISTER_MODE_WP = 1UL << 1;
enum UFFDIO_API = 0xc018aa3fUL;
enum UFFDIO_REGISTER = 0xc020aa00UL;
enum PAGEMAP_SCAN = 0xc0606610UL;
enum PM_SCAN_WP_MATCHING = 1UL << 0;
enum PM_SCAN_CHECK_WPASYNC = 1UL << 1;
enum PAGE_IS_WRITTEN = 1UL << 1;

struct uffdio_api {
	ulong api;
	ulong features;
	ulong ioctls;
}

struct uffdio_range {
	ulong start;
	ulong len;
}

struct uffdio_register {
	uffdio_range range;
	ulong mode;
	ulong ioctls;
}

struct page_region {
	ulong start;
	ulong end;
	ulong categories;
}

struct pm_scan_arg {
	ulong size;
	ulong flags;
	ulong start;
	ulong end;
	ulong walk_end;
	ulong vec;
	ulong vec_len;
	ulong max_pages;
	ulong category_inverted;
	ulong category_mask;
	ulong category_anyof_mask;
	ulong return_mask;
}

static assert(uffdio_api.sizeof == 24 && uffdio_register.sizeof == 32);
static assert(pm_scan_arg.sizeof == 96 && page_region.sizeof == 24);

extern(C) nothrow @nogc {
	long syscall(long number, ...);
	int ioctl(int fd, ulong request, ...);
	int open(const(char)* path, int flags, ...);
}

enum MaxRanges = 1024;
enum PageSize = 4096;

struct Range {
	size_t start;
	size_t size;
}

struct DirtyTracker {
	Mutex mutex;

	bool tried;
	bool available;

	// For the unit test: track even if the environment did not ask.
	bool forced;

	int uffd = -1;
	int pagemap = -1;

	size_t count;
	Range[MaxRanges] ranges;

shared:
	bool ensureInit() {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(DirtyTracker*) &this).initImpl();
	}

	void register(void* start, size_t size) {
		mutex.lock();
		scope(exit) mutex.unlock();

		(cast(DirtyTracker*) &this).registerImpl(start, size);
	}

	size_t collect(scope DirtyRangeDg dg, bool rearm = true) {
		mutex.lock();
		scope(exit) mutex.unlock();

		return (cast(DirtyTracker*) &this).collectImpl(dg, rearm);
	}
}

shared DirtyTracker gDirty;

private:

// Everything below runs with the tracker's mutex held.

bool initImpl(ref DirtyTracker t) {
	return t.initImpl();
}

bool initImpl(DirtyTracker* t) {
	assert(t.mutex.isHeld(), "Mutex not held!");

	if (t.tried) {
		return t.available;
	}

	t.tried = true;

	// On by default when the kernel supports it. SYMGC_CONCURRENT_MARK=0 or
	// SYMGC_DIRTY=0 turns it off (a stop-the-world mark).
	import core.stdc.stdlib : getenv;
	auto want = getenv("SYMGC_CONCURRENT_MARK");
	if (!t.forced && want !is null && want[0] == '0') {
		return false;
	}

	// The unit tests drive the collector from threads druntime does not know,
	// so a background mark has nothing to stop: they ask for it explicitly.
	version(Symgc_testing) {
		if (!t.forced && (want is null || want[0] != '1')) {
			return false;
		}
	}

	auto env = getenv("SYMGC_DIRTY");
	if (env !is null && env[0] == '0') {
		return false;
	}

	auto uffd = cast(int) syscall(SYS_userfaultfd, O_CLOEXEC | O_NONBLOCK | UFFD_USER_MODE_ONLY);
	if (uffd < 0) {
		return false;
	}

	uffdio_api api;
	api.api = UFFD_API;
	api.features = UFFD_FEATURE_WP_ASYNC | UFFD_FEATURE_WP_UNPOPULATED;
	if (ioctl(uffd, UFFDIO_API, &api) < 0) {
		closeFd(uffd);
		return false;
	}

	auto pagemap = open("/proc/self/pagemap", 0 /* O_RDONLY */);
	if (pagemap < 0) {
		closeFd(uffd);
		return false;
	}

	// Probe PAGEMAP_SCAN itself on a page of our own.
	{
		import core.sys.posix.sys.mman;
		auto p = mmap(null, PageSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
		if (p is MAP_FAILED) {
			closeFd(uffd);
			closeFd(pagemap);
			return false;
		}

		scope(exit) munmap(p, PageSize);

		*cast(ubyte*) p = 1;

		uffdio_register reg;
		reg.range.start = cast(size_t) p;
		reg.range.len = PageSize;
		reg.mode = UFFDIO_REGISTER_MODE_WP;
		bool ok = ioctl(uffd, UFFDIO_REGISTER, &reg) == 0;

		page_region[1] vec;
		pm_scan_arg arg;
		arg.size = pm_scan_arg.sizeof;
		arg.flags = PM_SCAN_WP_MATCHING | PM_SCAN_CHECK_WPASYNC;
		arg.start = cast(size_t) p;
		arg.end = cast(size_t) p + PageSize;
		arg.vec = cast(size_t) vec.ptr;
		arg.vec_len = 1;
		arg.category_mask = PAGE_IS_WRITTEN;
		arg.return_mask = PAGE_IS_WRITTEN;
		ok = ok && ioctl(pagemap, PAGEMAP_SCAN, &arg) >= 0;

		if (!ok) {
			closeFd(uffd);
			closeFd(pagemap);
			return false;
		}
	}

	t.uffd = uffd;
	t.pagemap = pagemap;
	t.available = true;
	return true;
}

void closeFd(int fd) {
	import core.sys.posix.unistd : close;
	close(fd);
}

void registerImpl(DirtyTracker* t, void* start, size_t size) {
	assert(t.mutex.isHeld(), "Mutex not held!");

	if (!t.initImpl()) {
		return;
	}

	uffdio_register reg;
	reg.range.start = cast(size_t) start;
	reg.range.len = size;
	reg.mode = UFFDIO_REGISTER_MODE_WP;

	if (t.count == MaxRanges || ioctl(t.uffd, UFFDIO_REGISTER, &reg) < 0) {
		// A mark that does not see a range is unsound: no tracking at all.
		t.available = false;
		return;
	}

	t.ranges[t.count++] = Range(cast(size_t) start, size);
}

size_t collectImpl(DirtyTracker* t, scope DirtyRangeDg dg, bool rearm = true) {
	assert(t.mutex.isHeld(), "Mutex not held!");

	if (!t.available) {
		return 0;
	}

	// A planted bug for the tests (SYMGC_DIRTY_SKIP=1): report nothing, so
	// the mark never rescans what the program wrote. The mark race stress
	// must fail with it, or it is not testing anything.
	version(Symgc_verify) {
		import core.stdc.stdlib : getenv;
		auto skip = getenv("SYMGC_DIRTY_SKIP");
		if (skip !is null && skip[0] == '1' && dg !is null) {
			dg = null;
		}
	}

	enum Cap = 2048;
	page_region[Cap] vec;
	size_t pages = 0;

	foreach (r; t.ranges[0 .. t.count]) {
		auto cursor = r.start;
		auto end = r.start + r.size;

		while (cursor < end) {
			pm_scan_arg arg;
			arg.size = pm_scan_arg.sizeof;
			arg.flags = PM_SCAN_CHECK_WPASYNC | (rearm ? PM_SCAN_WP_MATCHING : 0);
			arg.start = cursor;
			arg.end = end;
			arg.vec = cast(size_t) vec.ptr;
			arg.vec_len = Cap;
			arg.category_mask = PAGE_IS_WRITTEN;
			arg.return_mask = PAGE_IS_WRITTEN;

			auto n = ioctl(t.pagemap, PAGEMAP_SCAN, &arg);
			if (n < 0) {
				// The mapping went away under us, or the kernel refuses.
				// Neither can be told from a missed write: turn tracking off.
				t.available = false;
				return pages;
			}

			foreach (ref pr; vec[0 .. n]) {
				pages += (pr.end - pr.start) / PageSize;
				if (dg !is null) {
					dg(cast(const(void)*) pr.start, pr.end - pr.start);
				}
			}

			// The scan stops early when the vector is full, and `walk_end`
			// is where to go on. Pages it reported were re-armed, so a
			// repeated look cannot report them twice.
			if (arg.walk_end <= cursor) {
				break;
			}

			cursor = arg.walk_end;
		}
	}

	return pages;
}

@"dirty tracking" unittest {
	import core.sys.posix.sys.mman;

	// Nothing was registered if nobody asked for tracking, so this is safe.
	gDirty.mutex.lock();
	auto t = cast(DirtyTracker*) &gDirty;
	if (!t.available) {
		t.forced = true;
		t.tried = false;
	}

	gDirty.mutex.unlock();

	if (!dirtyAvailable()) {
		// An old kernel, or a restricted container: nothing to test here.
		return;
	}

	enum Size = 8 * 1024 * 1024;
	auto p = cast(ubyte*) mmap(null, Size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
	assert(p !is cast(ubyte*) MAP_FAILED);
	scope(exit) munmap(p, Size);

	foreach (i; 0 .. Size / PageSize) {
		p[i * PageSize] = 1;
	}

	dirtyRegister(p, Size);
	assert(dirtyAvailable());

	// Not armed yet: everything populated is reported. Arm, and nothing is.
	dirtyArm();
	assert(dirtyCollect(null) == 0);

	p[3 * PageSize] = 2;
	p[1000 * PageSize + 17] = 2;
	p[1001 * PageSize] = 2;

	size_t[3] starts;
	size_t seen;
	auto pages = dirtyCollect((const(void)* s, size_t size) {
		assert(seen < starts.length);
		starts[seen++] = (cast(size_t) s - cast(size_t) p) / PageSize;
		assert(size % PageSize == 0);
	});

	// Pages 1000 and 1001 are adjacent: one range.
	assert(pages == 3);
	assert(seen == 2 && starts[0] == 3 && starts[1] == 1000);

	// Reported, so re-armed: not reported twice.
	assert(dirtyCollect(null) == 0);
}
