module d.sync.waiter;

version(linux) {
	import d.sync.futex.waiter;
	alias Waiter = FutexWaiter;
} else version(Windows) {
	import d.sync.win32.waiter;
	alias Waiter = Win32Waiter;
} else version(OSX) {
	import d.sync.darwin.waiter;
	alias Waiter = DarwinWaiter;
} else version(iOS) {
	import d.sync.darwin.waiter;
	alias Waiter = DarwinWaiter;
} else version(TVOS) {
	import d.sync.darwin.waiter;
	alias Waiter = DarwinWaiter;
} else version(WatchOS) {
	import d.sync.darwin.waiter;
	alias Waiter = DarwinWaiter;
} else {
	static assert(false, "Unsupported platform");
}
