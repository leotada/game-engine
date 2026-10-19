/+ dub.json:
   {
	   "name": "telemetry",
	   "dependencies": {
		   "symgc" : {
			   "path" : "../../"
		   }
	   },
	   "targetPath": "./bin"
   }
+/
//T retval:0
//T desc: Test game engine controls, frame telemetry, and thread exclusion

import core.memory;
import core.time;
import core.thread;
import core.stdc.stdio : printf;

extern(C) __gshared rt_options = ["gcopt=gc:sdc"];

class LargeEntity {
	ubyte[4096] buffer;
	int id;
	this(int id) { this.id = id; }
}

void testFrameStats()
{
	printf("Testing GC.frameStats()...\n");
	// Allocate some objects to produce telemetry activity
	LargeEntity[] entities;
	foreach (i; 0 .. 100) {
		entities ~= new LargeEntity(i);
	}

	auto fs = GC.frameStats();
	printf("  usedSize: %llu bytes, freeSize: %llu bytes\n", cast(ulong) fs.usedSize, cast(ulong) fs.freeSize);
	printf("  threadAllocTime: %lld ns, totalAllocTime: %lld ns\n",
		cast(long) fs.threadAllocTime.total!"nsecs", cast(long) fs.totalAllocTime.total!"nsecs");
	printf("  threadCollectTime: %lld ns, totalCollectTime: %lld ns\n",
		cast(long) fs.threadCollectTime.total!"nsecs", cast(long) fs.totalCollectTime.total!"nsecs");
	printf("  threadPauseTime: %lld ns, totalPauseTime: %lld ns\n",
		cast(long) fs.threadPauseTime.total!"nsecs", cast(long) fs.totalPauseTime.total!"nsecs");
	printf("  numCollections: %zu, isCycleActive: %d\n", fs.numCollections, fs.isCycleActive ? 1 : 0);

	assert(fs.usedSize > 0, "usedSize must be > 0");
	assert(fs.threadAllocTime >= Duration.zero, "threadAllocTime must be >= 0");
	assert(fs.totalAllocTime >= Duration.zero, "totalAllocTime must be >= 0");
	printf("  GC.frameStats() PASSED.\n");
}

void testThreadExclusion()
{
	printf("Testing thread exclusion (audio/real-time exemption)...\n");
	assert(!GC.isThreadExcluded(), "Main thread should not be excluded initially");

	GC.excludeCurrentThread();
	assert(GC.isThreadExcluded(), "Main thread should be excluded after excludeCurrentThread()");

	GC.includeCurrentThread();
	assert(!GC.isThreadExcluded(), "Main thread should not be excluded after includeCurrentThread()");

	// Multi-threaded test: simulated audio thread
	__gshared bool audioRunning = true;
	__gshared uint audioTicks = 0;
	__gshared bool audioExcludedConfirmed = false;

	auto audioThread = new Thread({
		assert(!GC.isThreadExcluded());
		GC.excludeCurrentThread();
		assert(GC.isThreadExcluded());
		audioExcludedConfirmed = true;

		// Real-time audio loop simulation (pure compute, zero GC allocation)
		while (audioRunning) {
			audioTicks++;
			Thread.sleep(100.usecs);
		}

		GC.includeCurrentThread();
		assert(!GC.isThreadExcluded());
	});

	audioThread.start();

	// Wait for audio thread to exclude itself
	while (!audioExcludedConfirmed) {
		Thread.yield();
	}

	// Main thread triggers a collection cycle
	printf("  Triggering GC collection while audio thread runs excluded...\n");
	foreach (i; 0 .. 500) {
		new LargeEntity(i);
	}
	GC.collect();

	// Verify audio thread kept ticking smoothly
	assert(audioTicks > 0, "Audio thread must continue ticking");
	audioRunning = false;
	audioThread.join();

	printf("  Audio thread finished with %u ticks.\n", audioTicks);
	printf("  Thread exclusion PASSED.\n");
}

void testPacingStep()
{
	printf("Testing cooperative inter-frame pacing GC.step()...\n");
	// Test default step (zero duration: single sweep pass)
	GC.step();

	// Test timed step (1 millisecond)
	GC.step(1.msecs);

	// Test microsecond step
	GC.step(500.usecs);

	printf("  GC.step() PASSED.\n");
}

void main()
{
	testFrameStats();
	testThreadExclusion();
	testPacingStep();
	printf("All Game Engine Controls & Telemetry tests passed successfully!\n");
}
