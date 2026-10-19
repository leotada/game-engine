// A bullet-hell game written the way a game programmer would write it with a
// GC and no care for memory: `new` everywhere, no pools, no reuse, no
// GC.collect, garbage every frame (classes, closures, arrays rebuilt with
// filter/array, strings formatted for the HUD). It runs headless (no window:
// nothing to download) with a deterministic "player" and measures the cost of
// every frame, paced at 60 fps like a real game.
//
//   bullet_hell [seconds=60] [levelMiB=512] [bulletsPerSecond=20000]
//
// levelMiB is the live data a real game keeps around (map, entities, assets).
import core.stdc.stdio : printf, fprintf, stderr;
import core.stdc.stdlib : qsort;
import core.thread : Thread;
import core.time;
import std.algorithm : filter, remove;
import std.array : array, appender;
import std.format : format;
import std.conv : to;

struct Vec { float x = 0, y = 0; }

class Bullet {
	Vec pos, vel;
	int owner;
	float life;
	void delegate(Bullet) onExpire; // a closure per bullet, as people write it
	this(Vec p, Vec v, int o, float l, void delegate(Bullet) cb) {
		pos = p; vel = v; owner = o; life = l; onExpire = cb;
	}
}

class Particle {
	Vec pos, vel;
	float life;
	string tag;
	this(Vec p, Vec v, float l, string t) { pos = p; vel = v; life = l; tag = t; }
}

class Enemy {
	Vec pos;
	int id, hp = 50;
	float cooldown = 0;
	string name;
	this(int i, Vec p) { id = i; pos = p; name = "enemy-" ~ i.to!string; }
}

class Tile { // the level: lots of small linked objects, like a real map
	Tile[] neighbours;
	ubyte[] pixels;
	string name;
}

__gshared Tile[] level;
__gshared uint rngState = 12345;
uint rnd() { rngState = rngState * 1664525 + 1013904223; return rngState >> 8; }
float frand() { return (rnd() & 0xFFFF) / 65536.0f; }

extern(C) int cmpLong(const void* a, const void* b) {
	auto x = *cast(const long*) a, y = *cast(const long*) b;
	return x < y ? -1 : (x > y);
}

void main(string[] args) {
	auto seconds = args.length > 1 ? args[1].to!int : 60;
	auto levelMiB = args.length > 2 ? args[2].to!size_t : 512;
	auto perSecond = args.length > 3 ? args[3].to!int : 20000;

	// Build the level.
	enum tileBytes = 4096;
	level = new Tile[](levelMiB * 1024 * 1024 / (tileBytes + 128));
	foreach (i, ref t; level) {
		t = new Tile;
		t.pixels = new ubyte[](tileBytes);
		t.name = "tile-" ~ i.to!string;
		if (i) t.neighbours = [level[i - 1]];
	}

	Bullet[] bullets;
	Particle[] particles;
	Enemy[] enemies;
	foreach (i; 0 .. 24)
		enemies ~= new Enemy(i, Vec(40.0f + i * 30, 30));

	enum frames60 = 60;
	immutable total = seconds * frames60;
	auto ft = new long[](total);
	int score = 0, hits = 0;
	size_t peakBullets = 0;
	string hud;
	immutable perFrame = perSecond / frames60;

	foreach (f; 0 .. total) {
		immutable t0 = MonoTime.currTime;

		// Enemies fire patterns: a fresh Bullet and a fresh closure per shot.
		foreach (e; enemies) {
			e.cooldown -= 1.0f / 60;
			if (e.cooldown > 0) continue;
			e.cooldown = 0.05f;
			foreach (k; 0 .. perFrame / cast(int) enemies.length + 1) {
				auto ang = frand() * 6.2831853f;
				auto id = e.id;
				bullets ~= new Bullet(e.pos, Vec(cast(float) (200 * (frand() - 0.5f)), 60 + 120 * frand()),
					id, 2.0f + frand() * 3, (Bullet b) { score += id & 1; });
			}
		}

		// Move everything, then rebuild the lists the way people do.
		foreach (b; bullets) {
			b.pos.x += b.vel.x / 60;
			b.pos.y += b.vel.y / 60;
			b.life -= 1.0f / 60;
		}
		auto alive = bullets.filter!(b => b.life > 0 && b.pos.y < 600).array;
		foreach (b; bullets)
			if (b.life <= 0) b.onExpire(b);
		bullets = alive;
		if (bullets.length > peakBullets) peakBullets = bullets.length;

		// "Collision" with a player in the middle: a spark when near it.
		foreach (b; bullets) {
			immutable dx = b.pos.x - 320, dy = b.pos.y - 500;
			if (dx * dx + dy * dy < 400) {
				hits++;
				b.life = 0;
				foreach (k; 0 .. 6)
					particles ~= new Particle(b.pos, Vec(frand() * 80 - 40, frand() * 80 - 40), 0.5f, "spark" ~ k.to!string);
			}
		}
		foreach (p; particles) {
			p.pos.x += p.vel.x / 60;
			p.pos.y += p.vel.y / 60;
			p.life -= 1.0f / 60;
		}
		particles = particles.filter!(p => p.life > 0).array;

		// The level streams: replace a few tiles each frame.
		foreach (k; 0 .. 8) {
			auto i = rnd() % level.length;
			auto t = new Tile;
			t.pixels = new ubyte[](tileBytes);
			t.name = "tile-" ~ i.to!string;
			t.neighbours = [level[(i + 1) % level.length]];
			level[i] = t;
		}

		// HUD text, rebuilt every frame.
		hud = format("score %d  hits %d  bullets %d  particles %d  frame %d", score, hits, bullets.length, particles.length, f);

		ft[f] = (MonoTime.currTime - t0).total!"usecs";
		long spent = ft[f];
		while (spent < 16_666 && spent >= 0) {
			Thread.sleep(dur!"usecs"(16_666 - spent < 500 ? 16_666 - spent : 500));
			spent = (MonoTime.currTime - t0).total!"usecs";
		}
	}

	auto sorted = ft.dup;
	qsort(sorted.ptr, sorted.length, long.sizeof, &cmpLong);
	long over(long us) { long n = 0; foreach (v; ft) if (v > us) n++; return n; }
	printf("bullet_hell: %d s, level %lu MiB, %d bullets/s, peak bullets %lu, last HUD: %.*s\n",
		seconds, cast(ulong) levelMiB, perSecond, cast(ulong) peakBullets, cast(int) hud.length, hud.ptr);
	printf("frame_p50_us=%lld p99=%lld p999=%lld max=%lld over1ms=%lld over2ms=%lld over5ms=%lld over16ms=%lld frames=%lld\n",
		sorted[total / 2], sorted[total * 99 / 100], sorted[total * 999 / 1000], sorted[$ - 1],
		over(1000), over(2000), over(5000), over(16000), cast(long) total);
}
