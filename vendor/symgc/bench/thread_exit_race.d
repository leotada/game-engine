// Threads that start and exit while the collector marks concurrently.
//
// The start pause lists every thread's stack and TLS ranges and the mark
// threads read them after the world restarts. A thread that exits in between
// takes its stack (and its static TLS, which glibc keeps in the stack mapping)
// with it. This test keeps collections running with a large pointer-rich live
// heap and starts and joins short-lived threads all the time.
//
//   thread_exit_race [seconds=30] [liveMiB=1024]
import core.thread : Thread;
import core.atomic : atomicOp, atomicLoad;
import core.time;
import std.conv : to;
import std.stdio : writefln;

class Node { Node next; Node[] kids; long[6] pad; }

shared size_t threadsRun;
Node[] tlsData;   // thread-local: lives in the exiting thread's TLS block

void shortLived(uint seed) {
	// some stack depth and TLS data pointing at the heap
	Node[64] onStack;
	foreach (i, ref n; onStack) { n = new Node; n.kids = new Node[](4); }
	tlsData = onStack[].dup;
	foreach (k; 0 .. 200) { auto n = new Node; n.next = onStack[k % 64]; onStack[k % 64] = n; }
	atomicOp!"+="(threadsRun, 1);
}

void main(string[] args) {
	auto seconds = args.length > 1 ? args[1].to!int : 30;
	auto liveMiB = args.length > 2 ? args[2].to!size_t : 1024;

	// a pointer-rich live heap so each mark takes a while
	auto live = new Node[](liveMiB * 1024 * 1024 / 96);
	foreach (i, ref n; live) { n = new Node; if (i) n.next = live[i - 1]; }

	auto end = MonoTime.currTime + seconds.seconds;
	uint seed = 1;
	size_t churn;
	while (MonoTime.currTime < end) {
		Thread[8] ts;
		foreach (ref t; ts) { auto s = seed++; t = new Thread({ shortLived(s); }); t.start(); }
		// garbage on the main thread keeps the collector busy
		foreach (k; 0 .. 20_000) { auto n = new Node; n.kids = new Node[](2); churn += cast(size_t) cast(void*) n & 1; }
		foreach (t; ts) t.join();
		// replace part of the live heap
		foreach (k; 0 .. 2000) live[(seed * 7919 + k) % live.length] = new Node;
	}
	writefln("THREAD EXIT RACE OK: %s threads, live %s MiB", atomicLoad(threadsRun), liveMiB);
}
