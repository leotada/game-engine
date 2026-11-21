/**
 * `*.splines.json` — road, traffic and river paths for a world.
 *
 * ---
 * {"format":"game-engine.splines","version":1,
 *  "splines":[
 *    {"name":"main_road","role":"road","kind":"catmullRom","closed":false,"alpha":0.5,
 *     "width":8,"lanes":2,"speedLimit":13.9,
 *     "points":[[0,0,0],[120,2,40],[260,4,40]]},
 *    {"name":"bus_loop","role":"traffic","kind":"bezier","closed":true,
 *     "points":[[0,0,0],[10,0,0],[20,0,10], ...]}]}
 * ---
 *
 * `kind` is `catmullRom` (default) or `bezier` (control points
 * `P0, C0, C1, P1, ...`); see `engine.math.spline`. `role` is free-form
 * (`road`, `traffic`, `river`, `rail`, ...). Unknown keys are rejected so typos
 * surface early. A root `*.scene.json` references the file through an
 * `assetLinks` entry with `"kind":"splines"`; `tools/blender_export_scene.py`
 * writes both.
 *
 * Load time only (allocates). Every curve is baked (`Spline3.rebuild`) on
 * load, so the returned paths are ready for `@nogc` queries.
 */
module engine.scene.splines;

import std.exception : enforce;
import std.json : JSONType, JSONValue, parseJSON;
import engine.math.spline : Spline3, SplineHit, SplineKind;
import engine.math.vec : Vec3;
import engine.scene.scene_file : SceneFile;

@safe:

enum splineSetFormatId = "game-engine.splines";
enum splineSetVersion = 1;
/// `SceneAssetLink.kind` naming a spline set.
enum splineAssetLinkKind = "splines";

/// One named path with its gameplay attributes.
struct SplinePath {
    string name;
    string role = "road";
    /// Full road / river width in metres.
    float width = 8.0f;
    uint lanes = 2;
    /// Metres per second; 0 = unspecified.
    float speedLimit = 0;
    Spline3 curve;
}

struct SplineSet {
    SplinePath[] paths;

    /// Path called `name`, or null.
    inout(SplinePath)* find(scope const(char)[] name) inout return @trusted {
        foreach (ref p; paths) if (p.name == name) return &p;
        return null;
    }

    /// Number of paths with `role`.
    size_t countRole(scope const(char)[] role) const {
        size_t n;
        foreach (ref p; paths) if (p.role == role) n++;
        return n;
    }

    /**
     * Closest point over every path with `role` (any role when empty).
     * Returns the path index (or -1) and fills `hit`.
     */
    ptrdiff_t closest(Vec3 pos, out SplineHit hit, scope const(char)[] role = null) const {
        ptrdiff_t best = -1;
        foreach (i, ref p; paths) {
            if (role.length && p.role != role) continue;
            immutable h = p.curve.closestPoint(pos);
            if (best < 0 || h.separation < hit.separation) {
                hit = h;
                best = cast(ptrdiff_t) i;
            }
        }
        return best;
    }
}

/// Read and parse a `*.splines.json` file.
SplineSet loadSplineSetFile(string path) @trusted {
    import std.file : readText;
    return parseSplineSetJson(readText(path));
}

/// Parse spline-set JSON text and bake every curve.
SplineSet parseSplineSetJson(string text, uint samplesPerSegment = 32) @trusted {
    auto root = parseJSON(text);
    enforce(root.type == JSONType.object, "splines: root must be an object");
    onlyKeys(root, ["format", "version", "splines"], "splines root");
    enforce("format" in root && root["format"].type == JSONType.string
        && root["format"].str == splineSetFormatId,
        "splines: format must be '" ~ splineSetFormatId ~ "'");
    enforce("version" in root && root["version"].type == JSONType.integer
        && root["version"].integer >= 1 && root["version"].integer <= splineSetVersion,
        "splines: unsupported version");
    enforce("splines" in root && root["splines"].type == JSONType.array, "splines: 'splines' must be an array");

    SplineSet set;
    foreach (i, ref item; root["splines"].array) {
        enforce(item.type == JSONType.object, "splines[]: entry must be an object");
        onlyKeys(item, ["name", "role", "kind", "closed", "alpha", "width", "lanes", "speedLimit", "points"],
            "splines[]");
        SplinePath p;
        enforce("name" in item && item["name"].type == JSONType.string, "splines[]: 'name' must be a string");
        p.name = item["name"].str;
        if ("role" in item) {
            enforce(item["role"].type == JSONType.string, "splines[].role must be a string");
            p.role = item["role"].str;
        }
        if ("kind" in item) {
            enforce(item["kind"].type == JSONType.string, "splines[].kind must be a string");
            immutable k = item["kind"].str;
            if (k == "catmullRom") p.curve.kind = SplineKind.catmullRom;
            else if (k == "bezier") p.curve.kind = SplineKind.bezier;
            else enforce(false, "splines[].kind must be 'catmullRom' or 'bezier', got '" ~ k ~ "'");
        }
        if ("closed" in item) {
            enforce(item["closed"].type == JSONType.true_ || item["closed"].type == JSONType.false_,
                "splines[].closed must be a boolean");
            p.curve.closed = item["closed"].type == JSONType.true_;
        }
        if ("alpha" in item) p.curve.alpha = num(item["alpha"], "splines[].alpha");
        if ("width" in item) p.width = num(item["width"], "splines[].width");
        if ("lanes" in item) {
            immutable l = num(item["lanes"], "splines[].lanes");
            enforce(l >= 0 && l == cast(uint) l, "splines[].lanes must be a non-negative integer");
            p.lanes = cast(uint) l;
        }
        if ("speedLimit" in item) p.speedLimit = num(item["speedLimit"], "splines[].speedLimit");
        enforce("points" in item && item["points"].type == JSONType.array, "splines[].points must be an array");
        foreach (ref pt; item["points"].array) {
            enforce(pt.type == JSONType.array && pt.array.length == 3, "splines[].points[] must be [x,y,z]");
            p.curve.points ~= Vec3(num(pt[0], "x"), num(pt[1], "y"), num(pt[2], "z"));
        }
        enforce(p.curve.segmentCount > 0,
            "splines[]: '" ~ p.name ~ "' has too few points for its kind");
        p.curve.rebuild(samplesPerSegment);
        set.paths ~= p;
    }
    return set;
}

/// Serialize `set` (stable key order; inverse of `parseSplineSetJson`).
string splineSetToJson(ref const SplineSet set) @trusted {
    JSONValue[] items;
    foreach (ref p; set.paths) {
        JSONValue[] pts;
        foreach (v; p.curve.points) pts ~= JSONValue([v.x, v.y, v.z]);
        JSONValue o;
        o["name"] = p.name;
        o["role"] = p.role;
        o["kind"] = p.curve.kind == SplineKind.bezier ? "bezier" : "catmullRom";
        o["closed"] = p.curve.closed;
        o["alpha"] = p.curve.alpha;
        o["width"] = p.width;
        o["lanes"] = p.lanes;
        o["speedLimit"] = p.speedLimit;
        o["points"] = JSONValue(pts);
        items ~= o;
    }
    JSONValue root;
    root["format"] = splineSetFormatId;
    root["version"] = splineSetVersion;
    root["splines"] = JSONValue(items);
    return root.toString();
}

/// Path of the first `assetLinks` entry of kind `splines` in `scene`, or null.
string sceneSplineSetPath(ref const SceneFile scene) {
    foreach (ref l; scene.assetLinks)
        if (l.kind == splineAssetLinkKind && l.path >= 0 && l.path < cast(int) scene.strings.length)
            return scene.strings[l.path];
    return null;
}

private float num(ref const JSONValue v, string what) @trusted {
    if (v.type == JSONType.integer) return cast(float) v.integer;
    if (v.type == JSONType.uinteger) return cast(float) v.uinteger;
    enforce(v.type == JSONType.float_, what ~ " must be a number");
    return cast(float) v.floating;
}

private void onlyKeys(ref const JSONValue v, string[] allowed, string ctx) @trusted {
    foreach (string k, ref const JSONValue _; v.object) {
        bool ok;
        foreach (a; allowed) if (a == k) ok = true;
        enforce(ok, ctx ~ ": unknown key '" ~ k ~ "'");
    }
}

@("splines.parseRoundTripAndQuery") unittest {
    immutable text = `{"format":"game-engine.splines","version":1,"splines":[
        {"name":"main_road","role":"road","width":10,"lanes":4,"speedLimit":22.2,
         "points":[[0,0,0],[100,0,0],[200,0,0]]},
        {"name":"loop","role":"traffic","kind":"bezier","closed":true,
         "points":[[0,0,50],[10,0,50],[20,0,60],[20,0,70],[20,0,80],[10,0,90]]}]}`;
    auto set = parseSplineSetJson(text);
    assert(set.paths.length == 2);
    auto road = set.find("main_road");
    assert(road !is null && road.lanes == 4 && road.width == 10);
    assert(road.curve.baked && road.curve.length > 199 && road.curve.length < 201);
    assert(set.find("loop").curve.closed && set.find("loop").curve.kind == SplineKind.bezier);
    assert(set.countRole("road") == 1 && set.countRole("traffic") == 1);

    SplineHit hit;
    assert(set.closest(Vec3(150, 0, 3), hit, "road") == 0);
    assert(hit.distance > 149 && hit.distance < 151);

    auto again = parseSplineSetJson(splineSetToJson(set));
    assert(again.paths.length == 2 && again.paths[1].curve.points == set.paths[1].curve.points);
    assert(again.paths[0].speedLimit == road.speedLimit);
}

@("splines.rejectsBadInput") unittest {
    import std.exception : assertThrown;
    assertThrown(parseSplineSetJson(`{"format":"x","version":1,"splines":[]}`));
    assertThrown(parseSplineSetJson(`{"format":"game-engine.splines","version":1,
        "splines":[{"name":"a","points":[[0,0,0]]}]}`));
    assertThrown(parseSplineSetJson(`{"format":"game-engine.splines","version":1,
        "splines":[{"name":"a","widht":3,"points":[[0,0,0],[1,0,0]]}]}`));
    assertThrown(parseSplineSetJson(`{"format":"game-engine.splines","version":1,
        "splines":[{"name":"a","kind":"nurbs","points":[[0,0,0],[1,0,0]]}]}`));
}
