module d.gc.capi;

import d.gc.tcache;
import d.gc.emap;

extern(C):

/**
 * Standard C allocating functions.
 */
/+
void* malloc(size_t size) {
	return threadCache.alloc(size, true, false);
}

void free(void* ptr) {
	threadCache.free(ptr);
}

void* calloc(size_t nmemb, size_t size) {
	return threadCache.alloc(nmemb * size, true, true);
}

void* realloc(void* ptr, size_t size) {
	return threadCache.realloc(ptr, size, true);
}
// +/
/**
 * SDC runtime API.
 */
void* __sd_gc_alloc(size_t size) {
	return threadCache.alloc(size, true, false);
}

void* __sd_gc_array_alloc(size_t size) {
	return __sd_gc_alloc(size);
}

void* __sd_gc_alloc_finalizer(size_t size, void* finalizer) {
	return threadCache.allocAppendable(size, true, false, finalizer);
}

void __sd_gc_free(void* ptr) {
	threadCache.free(ptr);
}

void __sd_gc_destroy(void* ptr) {
	threadCache.destroy(ptr);
}

void* __sd_gc_realloc(void* ptr, size_t size) {
	return threadCache.realloc(ptr, size, true);
}

void __sd_gc_tl_flush_cache() {
	threadCache.flush();
}

/**
 * Garbage collection cycles.
 */
void __sd_gc_collect() {
	import d.gc.collector;
	auto collector = Collector(&threadCache);
	collector.runGCCycle();
}

void __sd_gc_run_finalizers(const void[] segment) {
	import d.gc.collector;
	auto collector = Collector(&threadCache);
	collector.runFinalizers(segment);
}

void __sd_gc_profile_stats(ulong* dst) {
	import d.gc.collector;
	profileStats(dst);
}

bool __sd_gc_set_finalizer_attr(void* ptr, void* finalizer) {
	return threadCache.setFinalizerAttr(ptr, finalizer);
}

void __sd_gc_clear_finalizer_attr(void* ptr) {
	threadCache.clearFinalizerAttr(ptr);
}

void __sd_gc_add_roots(const void[] range) {
	import d.gc.global;
	gState.addRoots(range);
}

void __sd_gc_remove_roots(const void* ptr) {
	import d.gc.global;
	gState.removeRoots(ptr);
}

void __sd_gc_add_tls_segment(const void[] range) {
	threadCache.addTLSSegment(range);
}

void __sd_gc_tl_activate(bool activated) {
	threadCache.activateGC(activated);
}

uint __sd_gc_enable() {
	import d.gc.collector;
	return enableAutomaticCollections();
}

uint __sd_gc_disable() {
	import d.gc.collector;
	return disableAutomaticCollections();
}

/**
 * Time lost to memory management, in nanoseconds, six values: `dst[0]` the
 * allocator's slow paths, `dst[1]` starting or helping a collection, `dst[2]`
 * stopped by the collector, and three parts of the slow paths, not counted in
 * `dst[0]`: `dst[3]` waiting for a bin's lock, `dst[4]` getting a new slab,
 * `dst[5]` waiting for the page filler's lock. For the calling thread since it
 * started, or for all the program's threads since it started. Read it before
 * and after a frame for the collector's share of that frame.
 */
void __sd_gc_time_thread(ulong* dst) {
	import d.gc.gctime;
	readThread(dst);
}

void __sd_gc_time_total(ulong* dst) {
	import d.gc.gctime;
	readTotal(dst);
}

PageDescriptor __sd_gc_maybe_get_page_descriptor(void* ptr) {
	return threadCache.maybeGetPageDescriptor(ptr);
}

void __sd_gc_exclude_current_thread() {
	threadCache.state.preventPausing();
	threadCache.activateGC(false);
}

void __sd_gc_include_current_thread() {
	threadCache.state.allowPausing();
	threadCache.activateGC(true);
}

bool __sd_gc_is_thread_excluded() {
	import d.gc.tstate : SuspendState;
	return threadCache.state.suspendState == SuspendState.Detached;
}

void __sd_gc_step(ulong maxTimeHns) {
	import d.gc.collector;
	auto collector = Collector(&threadCache);
	collector.assistSweepTimed(maxTimeHns);
}

size_t __sd_gc_defrag() {
	import d.gc.collector;
	auto collector = Collector(&threadCache);
	return collector.defrag();
}
