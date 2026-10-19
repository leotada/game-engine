module d.gc.cpu;

auto getCoreCount() {
	auto coreCountPtr = cast(uint*) &gCoreCount;
	if (*coreCountPtr == 0) {
		*coreCountPtr = computeCoreCount();
	}

	return *coreCountPtr;
}

private:
shared uint gCoreCount;

auto computeCoreCount() {
	version(linux) {
		import core.sys.linux.sched;
		cpu_set_t set;
		sched_getaffinity(0, cpu_set_t.sizeof, &set);
		return CPU_COUNT(&set);
	}
	else version(Windows) {
		import core.cpuid;
		return threadsPerCPU();
	}
	else version(Posix) {
		import core.sys.posix.unistd : sysconf, _SC_NPROCESSORS_ONLN;
		auto count = sysconf(_SC_NPROCESSORS_ONLN);
		return count > 0 ? cast(uint) count : 1;
	}
	else {
		return 1;
	}
}

@"getCoreCount" unittest {
	version(linux) {
		import core.sys.linux.sys.sysinfo;
		assert(getCoreCount() == get_nprocs());
	}
}
