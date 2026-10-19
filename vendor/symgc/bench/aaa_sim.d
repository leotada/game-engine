// Game-shaped workloads modelled on three kinds of big games, written the way a
// programmer writes them with a GC and no care for memory: classes, closures,
// arrays rebuilt every frame, associative arrays, strings, no pools, no
// GC.collect. 60 fps, a main thread plus a job pool (fork-join per frame, like a
// real engine's job system), and a streaming thread where the genre has one.
//
//   aaa_sim <rts|openworld|city> [seconds=60] [assetMiB=2048] [jobs=6] [nogc=0] [population=100000]
//
//   rts        4,000 units in two armies on a 256x256 grid: spatial hash rebuilt per
//              frame, target search, A* paths on the job pool, projectiles, an AI
//              commander, kills and respawns, an event log, the selection UI.
//   openworld  a player driving through a 64x64-cell world: a streaming thread loads
//              the cells ahead (mesh and collision data, ~400 props, ~15 NPCs each) and
//              the far ones are dropped; NPC AI, traffic, physics contacts, HUD, a mission
//              script with string variables.
//   city       100,000 citizens, 15,000 buildings, a 200x200 road graph: a slice of the
//              citizens updated per frame on the job pool, routes searched on the road
//              graph, an economy tick, traffic counts, births and deaths, info panels.
//
// assetMiB is the rest of a game's resident CPU-side data (audio banks, animation,
// navmeshes, collision, scripts, metadata): mostly pointer-free buffers plus their
// small metadata objects. nogc=1 runs the same frames with GC.disable(): the frame
// times are then the game's own cost, and the heap growth is the allocation rate.
import core.stdc.stdio : printf;
import core.stdc.stdlib : qsort;
import core.thread : Thread;
import core.sync.mutex : Mutex;
import core.atomic : atomicLoad, atomicStore, atomicOp;
import core.memory : GC;
import core.time;
import std.parallelism : TaskPool;
import std.algorithm : filter, sort, min, max;
import std.array : array;
import std.range : take;
import std.format : format;
import std.conv : to;
import std.math : sqrt;

struct V2 { float x = 0, y = 0; }
float dist2(V2 a, V2 b) { auto dx = a.x - b.x, dy = a.y - b.y; return dx * dx + dy * dy; }

uint rngState = 12345;  // thread-local
uint rnd() { rngState = rngState * 1664525 + 1013904223; return rngState >> 8; }
float frand() { return (rnd() & 0xFFFF) / 65536.0f; }

TaskPool pool;
enum frameUs = 16_666;

// ---------------------------------------------------------------- assets
class Asset {
	string name;
	ubyte[] data;      // pointer-free payload
	Asset[] deps;
	string[string] meta;
}
__gshared Asset[] assets;

void loadAssets(size_t mib) {
	size_t bytes = 0;
	size_t i = 0;
	while (bytes < mib * 1024 * 1024) {
		auto a = new Asset;
		auto sz = 4096 + (rnd() % 64) * 4096;   // 4 KiB .. 260 KiB
		a.data = new ubyte[](sz);
		a.data[0] = cast(ubyte) i;
		a.name = "asset/" ~ i.to!string ~ ".bin";
		a.meta["kind"] = (i % 3 == 0) ? "anim" : (i % 3 == 1) ? "audio" : "collision";
		a.meta["lod"] = (i % 4).to!string;
		if (i > 0) a.deps = [assets[rnd() % i]];
		assets ~= a;
		bytes += sz + 256;
		i++;
	}
}

// ---------------------------------------------------------------- RTS
enum G = 256;

class Order { int kind; V2 target; Unit targetUnit; }
class Projectile { V2 pos, vel; Unit target; float life; int dmg; }
class Unit {
	int id, team;
	V2 pos;
	float hp = 100, cooldown = 0;
	Unit target;
	V2[] path;
	size_t pathIdx;
	Order[] orders;
	string name;
	Projectile fired;
	bool wantsPath;
}

struct Rts {
	ubyte[] walk;
	Unit[] units;
	Projectile[] shots;
	string[] log;
	int nextId;
	size_t kills, paths;

	Unit spawn(int team) {
		auto u = new Unit;
		u.id = nextId++;
		u.team = team;
		u.pos = V2(team == 0 ? frand() * 60 : G - 1 - frand() * 60, frand() * (G - 1));
		u.name = (team == 0 ? "blue-" : "red-") ~ u.id.to!string;
		u.orders ~= new Order;
		u.orders[0].kind = 1;
		u.orders[0].target = V2(G / 2 + (frand() - 0.5f) * 80, frand() * (G - 1));
		u.wantsPath = true;
		return u;
	}

	void init() {
		walk = new ubyte[](G * G);
		foreach (i; 0 .. G * G / 8) walk[rnd() % (G * G)] = 1;   // rocks
		foreach (i; 0 .. 4000) units ~= spawn(i & 1);
	}

	static V2[] astar(const(ubyte)[] walk, V2 from, V2 to) {
		static struct N { float f; uint id; }
		uint start = cast(uint) from.y * G + cast(uint) from.x;
		uint goal = cast(uint) to.y * G + cast(uint) to.x;
		float[uint] g;
		uint[uint] came;
		// open list: a binary heap in a growing array
		N[] heap = new N[](64);
		size_t n;
		void push(N x) {
			if (n == heap.length) heap.length = heap.length * 2;
			size_t i = n++;
			heap[i] = x;
			while (i && heap[(i - 1) / 2].f > heap[i].f) { auto t = heap[i]; heap[i] = heap[(i - 1) / 2]; heap[(i - 1) / 2] = t; i = (i - 1) / 2; }
		}
		N pop() {
			auto top = heap[0];
			heap[0] = heap[--n];
			size_t i = 0;
			for (;;) {
				size_t l = 2 * i + 1, r = l + 1, s = i;
				if (l < n && heap[l].f < heap[s].f) s = l;
				if (r < n && heap[r].f < heap[s].f) s = r;
				if (s == i) break;
				auto t = heap[i]; heap[i] = heap[s]; heap[s] = t; i = s;
			}
			return top;
		}
		g[start] = 0;
		push(N(0, start));
		size_t expanded;
		while (n && expanded < 1500) {
			auto cur = pop();
			if (cur.id == goal) break;
			expanded++;
			int cx = cur.id % G, cy = cur.id / G;
			static immutable int[2][8] dirs = [[1, 0], [-1, 0], [0, 1], [0, -1], [1, 1], [-1, -1], [1, -1], [-1, 1]];
			foreach (d; dirs) {
				int nx = cx + d[0], ny = cy + d[1];
				if (nx < 0 || ny < 0 || nx >= G || ny >= G) continue;
				uint nid = ny * G + nx;
				if (walk[nid]) continue;
				float ng = g[cur.id] + (d[0] && d[1] ? 1.414f : 1.0f);
				if (auto p = nid in g) if (*p <= ng) continue;
				g[nid] = ng;
				came[nid] = cur.id;
				float h = sqrt(cast(float) ((nx - to.x) * (nx - to.x) + (ny - to.y) * (ny - to.y)));
				push(N(ng + h, nid));
			}
		}
		V2[] path;
		uint c = goal;
		if (c !in came) c = start;
		while (c != start) {
			path ~= V2(c % G + 0.5f, c / G + 0.5f);
			c = came[c];
		}
		return path;
	}

	void frame(size_t f) {
		// spatial hash, rebuilt every frame
		Unit[][uint] cells;
		foreach (u; units) cells[(cast(uint) u.pos.y / 16) * 64 + cast(uint) u.pos.x / 16] ~= u;

		// unit logic on the job pool
		foreach (u; pool.parallel(units, 64)) {
			rngState = cast(uint) (u.id * 2654435761 + f);
			u.cooldown -= 1.0f / 60;
			if (u.target is null || u.target.hp <= 0) {
				Unit[] near;
				int cx = cast(int) u.pos.x / 16, cy = cast(int) u.pos.y / 16;
				foreach (dy; -1 .. 2) foreach (dx; -1 .. 2) {
					if (auto p = cast(uint) ((cy + dy) * 64 + cx + dx) in cells)
						foreach (o; *p) if (o.team != u.team && o.hp > 0) near ~= o;
				}
				u.target = null;
				float bd = float.max;
				foreach (o; near) { auto d = dist2(o.pos, u.pos); if (d < bd) { bd = d; u.target = o; } }
			}
			if (u.target !is null && dist2(u.target.pos, u.pos) < 64 && u.cooldown <= 0) {
				u.cooldown = 1.0f + frand();
				auto p = new Projectile;
				p.pos = u.pos;
				auto d = V2(u.target.pos.x - u.pos.x, u.target.pos.y - u.pos.y);
				p.vel = V2(d.x * 2, d.y * 2);
				p.target = u.target;
				p.life = 0.5f;
				p.dmg = 8 + rnd() % 8;
				u.fired = p;
			} else if (u.pathIdx < u.path.length) {
				auto w = u.path[$ - 1 - u.pathIdx];
				auto d = V2(w.x - u.pos.x, w.y - u.pos.y);
				auto l = sqrt(d.x * d.x + d.y * d.y);
				if (l < 0.3f) u.pathIdx++;
				else { u.pos.x += d.x / l * 0.1f; u.pos.y += d.y / l * 0.1f; }
			}
		}

		// paths: up to 10 requests a frame (600/s, time-sliced as RTS engines do), searched on the job pool
		Unit[] req = units.filter!(u => u.wantsPath).take(10).array;
		foreach (u; pool.parallel(req, 1)) {
			auto o = u.orders[$ - 1];
			u.path = astar(walk, u.pos, o.target);
			u.pathIdx = 0;
			u.wantsPath = false;
		}
		paths += req.length;

		// projectiles
		foreach (u; units) if (u.fired !is null) { shots ~= u.fired; u.fired = null; }
		foreach (p; shots) {
			p.pos.x += p.vel.x / 60;
			p.pos.y += p.vel.y / 60;
			p.life -= 1.0f / 60;
			if (p.life <= 0 && p.target.hp > 0) {
				p.target.hp -= p.dmg;
				if (p.target.hp <= 0) {
					kills++;
					log ~= format("%s destroyed at (%.0f, %.0f)", p.target.name, p.target.pos.x, p.target.pos.y);
					if (log.length > 200) log = log[$ - 200 .. $];
				}
			}
		}
		shots = shots.filter!(p => p.life > 0).array;

		// the dead are replaced by reinforcements
		foreach (ref u; units) if (u.hp <= 0) u = spawn(u.team);

		// AI commander: new orders for a tenth of an army twice a second
		if (f % 30 == 0) {
			foreach (u; units) if (u.team == (f / 30) % 2 && rnd() % 10 == 0) {
				auto o = new Order;
				o.kind = 1;
				o.target = V2(frand() * (G - 1), frand() * (G - 1));
				u.orders ~= o;
				if (u.orders.length > 8) u.orders = u.orders[$ - 8 .. $];
				u.wantsPath = true;
			}
		}

		// selection UI
		auto sel = units.filter!(u => u.team == 0 && u.pos.x < 80).take(60).array;
		string panel;
		foreach (u; sel.take(12)) panel ~= format("%s hp %.0f\n", u.name, u.hp);
		hud = format("kills %d paths %d shots %d selected %d", kills, paths, shots.length, sel.length) ~ "\n" ~ panel;
	}
	string hud;
}

// ---------------------------------------------------------------- open world
enum W = 64;
enum cellSize = 200.0f;

class Component { int kind; float[4] params; Prop owner; }
class Prop { V2 pos; float[16] xf; string model; Component[] comps; }
class Npc { V2 pos, goal; int state; float timer = 0; Npc[] near; string name; V2[] route; }
class Car { V2 pos, vel; V2[] route; size_t idx; Npc driver; }
class Cell {
	int cx, cy;
	ubyte[] mesh;
	float[] collision;
	Prop[] props;
	Npc[] npcs;
	string[string] meta;
}

__gshared Mutex streamLock;
__gshared ulong[] streamWant;
__gshared Cell[] streamReady;
shared bool streamStop;

Cell buildCell(int cx, int cy) {
	auto c = new Cell;
	c.cx = cx; c.cy = cy;
	c.mesh = new ubyte[]((1 + rnd() % 3) * 1024 * 1024);
	c.mesh[0] = 1;
	c.collision = new float[](64 * 1024);
	c.collision[0] = 1;
	foreach (i; 0 .. 400) {
		auto p = new Prop;
		p.pos = V2(cx * cellSize + frand() * cellSize, cy * cellSize + frand() * cellSize);
		p.model = "props/" ~ (rnd() % 300).to!string ~ ".mdl";
		foreach (k; 0 .. 1 + rnd() % 3) { auto co = new Component; co.kind = k; co.owner = p; p.comps ~= co; }
		c.props ~= p;
	}
	foreach (i; 0 .. 15) {
		auto n = new Npc;
		n.pos = V2(cx * cellSize + frand() * cellSize, cy * cellSize + frand() * cellSize);
		n.goal = n.pos;
		n.name = format("ped-%d-%d-%d", cx, cy, i);
		c.npcs ~= n;
	}
	c.meta["district"] = format("district-%d", (cx / 8) * 8 + cy / 8);
	c.meta["weather"] = (rnd() & 1) ? "clear" : "rain";
	return c;
}

void streamThread() {
	rngState = 777;
	while (!atomicLoad(streamStop)) {
		ulong key = ulong.max;
		synchronized (streamLock) if (streamWant.length) { key = streamWant[0]; streamWant = streamWant[1 .. $]; }
		if (key == ulong.max) { Thread.sleep(2.msecs); continue; }
		auto c = buildCell(cast(int) (key >> 32), cast(int) (key & 0xFFFF_FFFF));
		synchronized (streamLock) streamReady ~= c;
	}
}

struct OpenWorld {
	Cell[ulong] world;
	bool[ulong] requested;
	Car[] cars;
	V2 player;
	string[string] mission;
	string hud;
	size_t loaded, dropped;

	static ulong key(int x, int y) { return (cast(ulong) x << 32) | cast(uint) y; }

	void init() {
		streamLock = new Mutex;
		player = V2(8 * cellSize, 8 * cellSize);
		foreach (y; 5 .. 12) foreach (x; 5 .. 12) world[key(x, y)] = buildCell(x, y);
		foreach (i; 0 .. 250) {
			auto c = new Car;
			c.pos = V2(player.x + (frand() - 0.5f) * 1200, player.y + (frand() - 0.5f) * 1200);
			cars ~= c;
		}
		mission["stage"] = "1";
	}

	void frame(size_t f) {
		// drive: 30 m/s along a slow curve
		player.x += 0.5f;
		player.y += 0.25f + 0.25f * ((f / 600) % 2);
		int pcx = cast(int) (player.x / cellSize), pcy = cast(int) (player.y / cellSize);

		// stream: request the 7x7 window around the player, drop what is beyond 4 cells
		foreach (y; pcy - 3 .. pcy + 4) foreach (x; pcx - 3 .. pcx + 4) {
			auto k = key(x % W, y % W);
			if (k !in world && k !in requested) { requested[k] = true; synchronized (streamLock) streamWant ~= k; }
		}
		Cell[] ready;
		synchronized (streamLock) { ready = streamReady; streamReady = null; }
		foreach (c; ready) { world[key(c.cx, c.cy)] = c; requested.remove(key(c.cx, c.cy)); loaded++; }
		ulong[] far;
		foreach (k, c; world) if (abs(c.cx - pcx % W) > 4 || abs(c.cy - pcy % W) > 4) far ~= k;
		foreach (k; far) { world.remove(k); dropped++; }

		// NPCs of the loaded cells
		Npc[] active;
		foreach (c; world) active ~= c.npcs;
		Npc[][uint] buckets;
		foreach (n; active) buckets[(cast(uint) (n.pos.y / 20) & 0xFFF) << 12 | (cast(uint) (n.pos.x / 20) & 0xFFF)] ~= n;
		foreach (n; pool.parallel(active, 32)) {
			rngState = cast(uint) (cast(size_t) cast(void*) n + f);
			n.timer -= 1.0f / 60;
			if (n.timer <= 0) {
				n.timer = 2 + frand() * 4;
				n.goal = V2(n.pos.x + (frand() - 0.5f) * 60, n.pos.y + (frand() - 0.5f) * 60);
				V2[] r;
				foreach (k; 0 .. 8 + rnd() % 8) r ~= V2(n.pos.x + (n.goal.x - n.pos.x) * k / 16, n.pos.y + (n.goal.y - n.pos.y) * k / 16);
				n.route = r;
				Npc[] near;
				if (auto b = ((cast(uint) (n.pos.y / 20) & 0xFFF) << 12 | (cast(uint) (n.pos.x / 20) & 0xFFF)) in buckets)
					foreach (o; *b) if (o !is n) near ~= o;
				n.near = near;
				n.state = near.length > 3 ? 2 : 1;
			}
			n.pos.x += (n.goal.x - n.pos.x) * 0.01f;
			n.pos.y += (n.goal.y - n.pos.y) * 0.01f;
		}

		// traffic around the player
		foreach (c; pool.parallel(cars, 16)) {
			if (c.idx >= c.route.length) {
				V2[] r;
				foreach (k; 0 .. 20) r ~= V2(player.x + (frand() - 0.5f) * 1200, player.y + (frand() - 0.5f) * 1200);
				c.route = r;
				c.idx = 0;
			}
			auto w = c.route[c.idx];
			c.pos.x += (w.x - c.pos.x) * 0.02f;
			c.pos.y += (w.y - c.pos.y) * 0.02f;
			if (dist2(c.pos, w) < 25) c.idx++;
		}

		// physics contacts of the props near the player (rebuilt per frame)
		static struct Contact { Prop a; Car b; V2 n; }
		Contact[] contacts;
		if (auto c = key(pcx % W, pcy % W) in world)
			foreach (p; (*c).props) foreach (car; cars[0 .. 40])
				if (dist2(p.pos, car.pos) < 400) contacts ~= Contact(p, car, V2(p.pos.x - car.pos.x, p.pos.y - car.pos.y));

		// mission script and HUD
		if (f % 120 == 0) {
			mission["stage"] = (mission["stage"].to!int + 1).to!string;
			mission["objective"] = format("reach (%.0f, %.0f)", player.x + 500, player.y + 300);
		}
		V2[] blips;
		foreach (n; active.take(200)) blips ~= n.pos;
		hud = format("speed %.0f km/h  cells %d  npcs %d  contacts %d  blips %d  %s",
			108.0, world.length, active.length, contacts.length, blips.length, mission["objective"]);
	}
}
int abs(int x) { return x < 0 ? -x : x; }

// ---------------------------------------------------------------- city
__gshared int R = 200;   // road grid side; grows with the population

class RoadNode { int id; V2 pos; RoadNode[] edges; }
class Building { int id, kind; V2 pos; RoadNode access; float[6] stock; Citizen[] occupants; string name; }
class Citizen {
	int id, state;
	Building home, work;
	RoadNode[] route;
	size_t routeIdx;
	float[8] needs;
	string name;
}

struct City {
	RoadNode[] roads;
	Building[] buildings;
	Citizen[] citizens;
	double[string] districtIncome;
	float[] history;
	string[] panels;
	string hud;
	int nextId;
	size_t trips;

	Citizen born() {
		auto c = new Citizen;
		c.id = nextId++;
		c.home = buildings[rnd() % buildings.length];
		c.work = buildings[rnd() % buildings.length];
		c.needs[] = 0.5f;
		c.name = "citizen-" ~ c.id.to!string;
		c.home.occupants ~= c;
		return c;
	}

	size_t population = 100_000;

	void init() {
		// 100k citizens: a 200x200 road grid and 15,000 buildings; scaled with the population
		R = max(200, cast(int) sqrt(population * 0.4));
		roads = new RoadNode[](R * R);
		foreach (i, ref n; roads) { n = new RoadNode; n.id = cast(int) i; n.pos = V2(i % R, i / R); }
		foreach (i, n; roads) {
			int x = cast(int) (i % R), y = cast(int) (i / R);
			if (x + 1 < R) { n.edges ~= roads[i + 1]; roads[i + 1].edges ~= n; }
			if (y + 1 < R) { n.edges ~= roads[i + R]; roads[i + R].edges ~= n; }
		}
		foreach (int i; 0 .. cast(int) (population * 15 / 100)) {
			auto b = new Building;
			b.id = i;
			b.kind = i % 4;
			b.access = roads[rnd() % roads.length];
			b.pos = b.access.pos;
			b.name = format("%s #%d", ["House", "Shop", "Factory", "Office"][i % 4], i);
			buildings ~= b;
		}
		foreach (i; 0 .. population) citizens ~= born();
	}

	static RoadNode[] route(RoadNode from, RoadNode to) {
		RoadNode[RoadNode] came;
		RoadNode[] frontier = [from];
		came[from] = null;
		size_t expanded;
		while (frontier.length && expanded < 600) {
			RoadNode[] next;
			foreach (n; frontier) {
				if (n is to) { frontier = null; break; }
				expanded++;
				foreach (e; n.edges) if (e !in came) { came[e] = n; next ~= e; }
			}
			if (frontier is null) break;
			// greedy towards the goal: keep the closest half
			next.sort!((a, b) => dist2(a.pos, to.pos) < dist2(b.pos, to.pos));
			frontier = next[0 .. min(next.length, 24)];
		}
		RoadNode[] path;
		auto c = to in came ? to : from;
		while (c !is null && c !is from) { path ~= c; c = came[c]; }
		return path;
	}

	void frame(size_t f) {
		// a thirtieth of the citizens per frame
		immutable slice = citizens.length / 30;
		auto part = citizens[(f % 30) * slice .. (f % 30 + 1) * slice];
		foreach (c; pool.parallel(part, 64)) {
			rngState = cast(uint) (c.id * 2654435761 + f);
			foreach (ref n; c.needs) n = max(0.0f, n - 0.01f);
			if (c.routeIdx < c.route.length) { c.routeIdx++; continue; }
			if (rnd() % 200 == 0) {   // about 1,000 trips started per second
				auto dest = c.state == 0 ? c.work : c.home;
				c.route = route(c.state == 0 ? c.home.access : c.work.access, dest.access);
				c.routeIdx = 0;
				c.state ^= 1;
			}
		}
		trips += part.length / 200;

		// economy every 10 frames
		if (f % 10 == 0) {
			double[int] income;
			foreach (b; buildings) {
				b.stock[b.kind] += 0.1f * b.occupants.length;
				income[cast(int) (b.pos.x / 25) * 8 + cast(int) (b.pos.y / 25)] += b.stock[b.kind];
			}
			double[string] named;
			foreach (k, v; income) named[format("district-%d", k)] = v;
			districtIncome = named;
			history ~= cast(float) income.length;
			if (history.length > 300) history = history[$ - 300 .. $].dup;
		}

		// traffic load per road node: rebuilt every frame from the moving citizens
		int[int] load;
		foreach (c; part) if (c.routeIdx < c.route.length) load[c.route[c.routeIdx].id]++;

		// births and deaths
		foreach (k; 0 .. 5) {
			auto i = rnd() % citizens.length;
			auto old = citizens[i];
			old.home.occupants = old.home.occupants.filter!(o => o !is old).array;
			citizens[i] = born();
		}

		// info panels for what the mouse hovers, and the chart
		panels = null;
		foreach (k; 0 .. 20) {
			auto b = buildings[(f * 7 + k * 131) % buildings.length];
			panels ~= format("%s: %d people, stock %.1f", b.name, b.occupants.length, b.stock[b.kind]);
		}
		auto chart = history.dup;
		hud = format("population %d  trips %d  congested %d  districts %d  chart %d",
			citizens.length, trips, load.length, districtIncome.length, chart.length);
	}
}

// ---------------------------------------------------------------- main
// symgc reports the time threads lose to memory management (ns: alloc slow paths,
// collection start/assist, stopped by the collector); read around every frame.
// Build with -d-version=Symgc_gctime for our symgc: upstream symgc does not have the counters.
version(Symgc_gctime) {
	extern(C) void __sd_gc_time_thread(ulong* dst);
	extern(C) void __sd_gc_time_total(ulong* dst);
	version(Symgc_lock_hist) {
		extern(C) void __sd_gc_lock_hist(ulong* count, ulong* time);
		extern(C) void __sd_gc_holder_hist(ulong* count, ulong* time);
		extern(C) void __sd_gc_seg_hist(ulong* count, ulong* time);
	}
	enum haveGcTime = true;
} else {
	enum haveGcTime = false;
}

struct GcClock {
	// alloc, collect, pause, bin lock, fresh slab, filler lock
	enum kinds = 6;
	ulong[kinds] thread, total;
	void read() {
		static if (haveGcTime) {
			__sd_gc_time_thread(thread.ptr);
			__sd_gc_time_total(total.ptr);
		}
	}
}

extern(C) int cmpLong(const void* a, const void* b) {
	auto x = *cast(const long*) a, y = *cast(const long*) b;
	return x < y ? -1 : (x > y);
}

void main(string[] args) {
	auto mode = args.length > 1 ? args[1] : "rts";
	auto seconds = args.length > 2 ? args[2].to!int : 60;
	auto assetMiB = args.length > 3 ? args[3].to!size_t : 2048;
	auto jobs = args.length > 4 ? args[4].to!uint : 6;
	auto nogc = args.length > 5 ? args[5].to!int : 0;
	auto population = args.length > 6 ? args[6].to!size_t : 100_000;   // city only

	pool = new TaskPool(jobs);
	pool.isDaemon = true;

	loadAssets(assetMiB);
	Rts rts;
	OpenWorld ow;
	City city;
	Thread streamer;
	final switch (mode) {
		case "rts": rts.init(); break;
		case "openworld": ow.init(); streamer = new Thread(&streamThread); streamer.start(); break;
		case "city": city.population = population; city.init(); break;
	}

	if (nogc) GC.disable();
	immutable used0 = GC.stats().usedSize;
	immutable total = seconds * 60;
	auto ft = new long[](total);
	auto gcMain = new long[](total);   // us the main thread lost to memory management
	auto gcAll = new long[](total);    // us all threads lost, summed (job threads run in parallel)
	ulong[GcClock.kinds] kindMain, kindAll;   // ns per kind over the run
	string hud;
	foreach (f; 0 .. total) {
		GcClock c0, c1;
		c0.read();
		immutable t0 = MonoTime.currTime;
		final switch (mode) {
			case "rts": rts.frame(f); hud = rts.hud; break;
			case "openworld": ow.frame(f); hud = ow.hud; break;
			case "city": city.frame(f); hud = city.hud; break;
		}
		ft[f] = (MonoTime.currTime - t0).total!"usecs";
		c1.read();
		ulong m = 0, a = 0;
		foreach (k; 0 .. GcClock.kinds) {
			m += c1.thread[k] - c0.thread[k];
			a += c1.total[k] - c0.total[k];
			kindMain[k] += c1.thread[k] - c0.thread[k];
			kindAll[k] += c1.total[k] - c0.total[k];
		}
		gcMain[f] = m / 1000;
		gcAll[f] = a / 1000;
		long spent = ft[f];
		while (spent < frameUs && spent >= 0) {
			Thread.sleep(dur!"usecs"(frameUs - spent < 500 ? frameUs - spent : 500));
			spent = (MonoTime.currTime - t0).total!"usecs";
		}
	}
	immutable used1 = GC.stats().usedSize;
	if (streamer !is null) { atomicStore(streamStop, true); streamer.join(); }

	auto sorted = ft.dup;
	qsort(sorted.ptr, sorted.length, long.sizeof, &cmpLong);
	long over(long us) { long n = 0; foreach (v; ft) if (v > us) n++; return n; }
	auto line = hud.length > 90 ? hud[0 .. 90] : hud;
	printf("aaa_sim %.*s: %d s, assets %lu MiB, jobs %u, nogc %d | %.*s\n", cast(int) mode.length, mode.ptr,
		seconds, cast(ulong) assetMiB, jobs, nogc, cast(int) line.length, line.ptr);
	if (nogc)
		printf("allocated_MiB_per_s=%.1f (heap growth with the collector off)\n",
			(cast(double) used1 - used0) / (1024.0 * 1024) / seconds);
	printf("frame_p50_us=%lld p99=%lld p999=%lld max=%lld over1ms=%lld over2ms=%lld over5ms=%lld over16ms=%lld frames=%lld\n",
		sorted[total / 2], sorted[total * 99 / 100], sorted[total * 999 / 1000], sorted[$ - 1],
		over(1000), over(2000), over(5000), over(16000), cast(long) total);
	static if (haveGcTime) {
		// The collector's share of each frame, and the game's own time without it.
		auto own = new long[](total);
		foreach (i; 0 .. total) own[i] = ft[i] - gcMain[i];
		void dist(string name, long[] v) {
			auto s = v.dup;
			qsort(s.ptr, s.length, long.sizeof, &cmpLong);
			printf("%-28s p50=%lld p99=%lld p999=%lld max=%lld (us)\n", name.ptr,
				s[total / 2], s[total * 99 / 100], s[total * 999 / 1000], s[$ - 1]);
		}
		dist("gc_main (main thread)", gcMain);
		dist("gc_all (all threads, sum)", gcAll);
		dist("frame minus gc_main", own);
		static immutable kindNames = ["alloc", "collect", "pause", "binlock", "freshslab", "fillerlock"];
		foreach (who, arr; [kindMain, kindAll]) {
			printf("gc time over the run, ms, %s:", who == 0 ? "main".ptr : "all ".ptr);
			foreach (k; 0 .. GcClock.kinds) printf(" %s=%.1f", kindNames[k].ptr, arr[k] / 1e6);
			printf("\n");
		}
		// the ten slowest frames, split
		auto idx = new size_t[](total);
		foreach (i; 0 .. total) idx[i] = i;
		import std.algorithm : sort;
		idx.sort!((x, y) => ft[x] > ft[y]);
		printf("slowest frames (frame us / gc_main us / gc_all us):");
		foreach (i; idx[0 .. 10]) printf(" %lld/%lld/%lld", ft[i], gcMain[i], gcAll[i]);
		printf("\n");

		// A build with -d-version=Symgc_lock_hist counts every wait of each
		// kind by power of two of 100 ns: how many there were, and their time.
		version(Symgc_lock_hist) {
			ulong[24 * GcClock.kinds] hc, ht;
			__sd_gc_lock_hist(hc.ptr, ht.ptr);
			foreach (k; 0 .. GcClock.kinds) {
				ulong n, t;
				foreach (b; 0 .. 24) { n += hc[k * 24 + b]; t += ht[k * 24 + b]; }
				printf("waits %s: %llu, %.1f ms; by 2^b x 100ns (count/ms):", kindNames[k].ptr, n, t / 1e6);
				foreach (b; 0 .. 24)
					if (hc[k * 24 + b]) printf(" %d:%llu/%.1f", b, hc[k * 24 + b], ht[k * 24 + b] / 1e6);
				printf("\n");
			}

			// How long an allocation holds the page filler's lock, by part.
			{
				ulong[24 * 8] sc, st;
				__sd_gc_seg_hist(sc.ptr, st.ptr);
				static immutable segNames = ["whole", "extent", "block", "newblock", "reserve"];
				foreach (s; 0 .. 5) {
					ulong n, t, longN, longT;
					foreach (b; 0 .. 24) {
						n += sc[s * 24 + b]; t += st[s * 24 + b];
						if (b >= 10) { longN += sc[s * 24 + b]; longT += st[s * 24 + b]; }
					}
					printf("filler hold %-8s: %llu, %.1f ms; >=100us: %llu, %.1f ms;", segNames[s].ptr, n, t / 1e6, longN, longT / 1e6);
					foreach (b; 8 .. 24)
						if (sc[s * 24 + b]) printf(" %d:%llu", b, sc[s * 24 + b]);
					printf("\n");
				}
			}

			// The page filler's lock waits by who held the lock before.
			ulong[24 * 8] oc, ot;
			__sd_gc_holder_hist(oc.ptr, ot.ptr);
			static immutable holderNames = ["other", "alloc", "free", "prepare", "finalize", "sweep", "assist", "-"];
			foreach (h; 0 .. 7) {
				ulong n, t, longN, longT;
				foreach (b; 0 .. 24) {
					n += oc[h * 24 + b]; t += ot[h * 24 + b];
					if (b >= 10) { longN += oc[h * 24 + b]; longT += ot[h * 24 + b]; }
				}
				printf("filler waits after %-8s: %llu, %.1f ms; of those >=100us: %llu, %.1f ms\n",
					holderNames[h].ptr, n, t / 1e6, longN, longT / 1e6);
			}
		}
	}
	{
		import std.file : readText;
		import std.string : splitLines, startsWith, strip;
		string rss, hwm;
		foreach (l; readText("/proc/self/status").splitLines) {
			if (l.startsWith("VmRSS:")) rss = l[6 .. $].strip;
			if (l.startsWith("VmHWM:")) hwm = l[6 .. $].strip;
		}
		printf("rss=%.*s peak_rss=%.*s\n", cast(int) rss.length, rss.ptr, cast(int) hwm.length, hwm.ptr);
	}
}
