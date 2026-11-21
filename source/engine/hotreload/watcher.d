/**
 * Debounced filesystem watcher used by every hot-reloader.
 *
 * Two backends:
 * - `inotify` (Linux): kernel events, reports the exact changed paths and
 *   starts watching subdirectories created after `init`.
 * - `polling` (every platform): rescans the watched roots every
 *   `pollInterval` seconds and compares modification times. Used on
 *   Windows/macOS/Web and as the Linux fallback when `inotify` is unavailable.
 *
 * `poll(dt)` returns true once changes have been quiet for the debounce
 * window; `changedPaths()` then lists the deduplicated paths of that batch
 * (files created, modified, moved in or deleted). The list stays valid until
 * the next `poll` that returns true.
 *
 * Dev-time tool: it allocates (path strings, directory scans) and must not be
 * polled from a `--assert-no-gc` frame loop.
 */
module engine.hotreload.watcher;

import std.datetime.systime : SysTime;
import std.file : exists, isDir, dirEntries, SpanMode;

version (linux) {
    import core.sys.linux.sys.inotify;
    import core.sys.posix.unistd : close, read;
}

@safe:

/// Which change-detection mechanism a `FileWatcher` uses.
enum WatchBackend : ubyte {
    /// `inotify` on Linux, `polling` everywhere else.
    automatic,
    /// Linux `inotify` (falls back to `polling` if it cannot be created).
    inotify,
    /// Portable modification-time polling.
    polling,
}

struct FileWatcher {
    private WatchBackend _backend = WatchBackend.automatic;
    private bool _active;
    private string[] _roots;
    private float _debounceDuration = 0.3f;
    private float _timer = 0.0f;
    private bool _hasPendingChanges;
    private string[] _pending;
    private bool[string] _pendingSet;
    private string[] _changedPaths;

    // inotify state
    private int _fd = -1;
    private int[string] _watchMap;
    private string[int] _wdToPath;

    // polling state
    /// Seconds between two directory rescans of the polling backend.
    float pollInterval = 0.25f;
    private float _pollTimer = 0.0f;
    private SysTime[string] _mtimes;

    /**
     * Start watching `rootDirs` recursively. Missing roots are skipped.
     * Returns false when no root exists.
     */
    bool init(string[] rootDirs, float debounceSeconds = 0.3f,
              WatchBackend backend = WatchBackend.automatic) @trusted {
        shutdown();
        _debounceDuration = debounceSeconds;
        _roots = null;
        foreach (dir; rootDirs)
            if (exists(dir) && isDir(dir)) _roots ~= dir;
        if (_roots.length == 0) return false;

        WatchBackend chosen = backend;
        if (chosen == WatchBackend.automatic) {
            version (linux) chosen = WatchBackend.inotify;
            else chosen = WatchBackend.polling;
        }
        version (linux) {
            if (chosen == WatchBackend.inotify) {
                _fd = inotify_init1(IN_NONBLOCK);
                if (_fd < 0) chosen = WatchBackend.polling;
            }
        } else {
            chosen = WatchBackend.polling;
        }
        _backend = chosen;

        if (_backend == WatchBackend.inotify) {
            foreach (dir; _roots) addDirectoryRecursive(dir);
        } else {
            scanPolling(false);
        }
        _active = true;
        return true;
    }

    /// Backend picked by `init` (`automatic` before `init`).
    WatchBackend backend() const nothrow @nogc { return _backend; }

    /// True between a successful `init` and `shutdown`.
    bool active() const nothrow @nogc { return _active; }

    /// Paths of the last settled batch (see `poll`).
    const(string)[] changedPaths() const nothrow @nogc { return _changedPaths; }

    /// Number of directories watched by the `inotify` backend.
    size_t watchedDirectoryCount() const nothrow @nogc { return _watchMap.length; }

    void shutdown() @trusted {
        version (linux) {
            if (_fd >= 0) {
                foreach (wd; _watchMap.values) inotify_rm_watch(_fd, wd);
                close(_fd);
            }
        }
        _fd = -1;
        _watchMap.clear();
        _wdToPath.clear();
        _mtimes.clear();
        _pending = null;
        _pendingSet.clear();
        _changedPaths = null;
        _hasPendingChanges = false;
        _timer = 0;
        _pollTimer = 0;
        _active = false;
    }

    /// Watch one directory (non-recursive). No-op for the polling backend.
    void addDirectory(string path) @trusted {
        version (linux) {
            import std.string : toStringz;
            if (_fd < 0 || !exists(path) || !isDir(path)) return;
            if (path in _watchMap) return;
            immutable mask = IN_CLOSE_WRITE | IN_MOVED_TO | IN_MOVED_FROM | IN_CREATE | IN_DELETE;
            immutable wd = inotify_add_watch(_fd, path.toStringz(), mask);
            if (wd >= 0) {
                _watchMap[path] = wd;
                _wdToPath[wd] = path;
            }
        }
    }

    /// Watch `root` and every subdirectory below it.
    void addDirectoryRecursive(string root) @trusted {
        if (!exists(root) || !isDir(root)) return;
        addDirectory(root);
        try {
            foreach (entry; dirEntries(root, SpanMode.breadth))
                if (entry.isDir) addDirectory(entry.name);
        } catch (Exception) {}
    }

    /**
     * Collect events. Returns true when a batch of changes has been quiet for
     * the debounce window; `changedPaths()` then holds that batch.
     */
    bool poll(float dt) @trusted {
        if (!_active) return false;

        bool detected;
        if (_backend == WatchBackend.inotify) {
            detected = drainInotify();
        } else {
            _pollTimer += dt;
            if (_pollTimer >= pollInterval) {
                _pollTimer = 0;
                detected = scanPolling(true);
            }
        }

        if (detected) {
            _hasPendingChanges = true;
            _timer = 0.0f; // restart the debounce window
        } else if (_hasPendingChanges) {
            _timer += dt;
            if (_timer >= _debounceDuration) {
                _hasPendingChanges = false;
                _timer = 0.0f;
                _changedPaths = _pending;
                _pending = null;
                _pendingSet.clear();
                return true;
            }
        }
        return false;
    }

    private void markChanged(string path) {
        if (path in _pendingSet) return;
        _pendingSet[path] = true;
        _pending ~= path;
    }

    private bool drainInotify() @trusted {
        version (linux) {
            if (_fd < 0) return false;
            ubyte[4096] buffer = void;
            bool detected;
            while (true) {
                immutable bytesRead = read(_fd, buffer.ptr, buffer.length);
                if (bytesRead <= 0) break;
                size_t offset = 0;
                while (offset + inotify_event.sizeof <= cast(size_t) bytesRead) {
                    auto ev = cast(const(inotify_event)*)(buffer.ptr + offset);
                    offset += inotify_event.sizeof + ev.len;
                    if (ev.mask & IN_IGNORED) {
                        if (auto p = ev.wd in _wdToPath) {
                            _watchMap.remove(*p);
                            _wdToPath.remove(ev.wd);
                        }
                        continue;
                    }
                    auto dir = ev.wd in _wdToPath;
                    if (dir is null || ev.len == 0) continue;
                    immutable name = nameOf(ev);
                    if (name.length == 0) continue;
                    immutable full = *dir ~ "/" ~ name;
                    detected = true;
                    if ((ev.mask & IN_ISDIR) && (ev.mask & (IN_CREATE | IN_MOVED_TO))) {
                        // New subdirectory: watch it, and report files that
                        // landed in it before the watch existed.
                        addDirectoryRecursive(full);
                        try {
                            foreach (entry; dirEntries(full, SpanMode.breadth))
                                if (!entry.isDir) markChanged(entry.name);
                        } catch (Exception) {}
                        continue;
                    }
                    if (ev.mask & IN_ISDIR) continue;
                    markChanged(full);
                }
            }
            return detected;
        } else {
            return false;
        }
    }

    version (linux) private static string nameOf(const(inotify_event)* ev) @trusted {
        auto raw = (cast(const(char)*) ev + inotify_event.sizeof)[0 .. ev.len];
        size_t n = 0;
        while (n < raw.length && raw[n] != '\0') n++;
        return raw[0 .. n].idup;
    }

    /// Rescan every root; returns true if anything was added/modified/removed.
    private bool scanPolling(bool report) @trusted {
        bool detected;
        bool[string] seen;
        foreach (root; _roots) {
            if (!exists(root)) continue;
            try {
                foreach (entry; dirEntries(root, SpanMode.breadth)) {
                    if (entry.isDir) continue;
                    immutable name = entry.name;
                    immutable mtime = entry.timeLastModified;
                    seen[name] = true;
                    auto old = name in _mtimes;
                    if (old is null || *old != mtime) {
                        _mtimes[name] = mtime;
                        if (report) {
                            markChanged(name);
                            detected = true;
                        }
                    }
                }
            } catch (Exception) {}
        }
        string[] removed;
        foreach (name; _mtimes.byKey)
            if (name !in seen) removed ~= name;
        foreach (name; removed) {
            _mtimes.remove(name);
            if (report) {
                markChanged(name);
                detected = true;
            }
        }
        return detected;
    }
}

version (unittest) private string watcherTestDir(string name) @trusted {
    import std.file : mkdirRecurse, rmdirRecurse;
    immutable dir = "build/test_watcher_" ~ name;
    if (exists(dir)) rmdirRecurse(dir);
    mkdirRecurse(dir);
    return dir;
}

version (unittest) private bool pollUntil(ref FileWatcher w, int maxSteps = 200) {
    foreach (_; 0 .. maxSteps)
        if (w.poll(0.05f)) return true;
    return false;
}

version (unittest) private bool containsPath(const(string)[] list, string path) {
    foreach (p; list) if (p == path) return true;
    return false;
}

@("watcher.pollingReportsChangedPaths") @trusted unittest {
    import core.time : seconds;
    import std.datetime.systime : Clock;
    import std.file : mkdirRecurse, remove, rmdirRecurse, setTimes, write;

    immutable dir = watcherTestDir("polling");
    scope (exit) rmdirRecurse(dir);
    write(dir ~ "/a.json", "{}");

    FileWatcher w;
    assert(w.init([dir], 0.1f, WatchBackend.polling));
    assert(w.backend == WatchBackend.polling);
    w.pollInterval = 0.05f;
    assert(!w.poll(0.05f));

    // Modify (explicit future mtime: filesystems may have coarse resolution).
    write(dir ~ "/a.json", "{\"x\":1}");
    immutable future = Clock.currTime() + 5.seconds;
    setTimes(dir ~ "/a.json", future, future);
    // A subdirectory created after init is covered by the recursive rescan.
    mkdirRecurse(dir ~ "/sub");
    write(dir ~ "/sub/b.json", "{}");

    assert(pollUntil(w));
    assert(containsPath(w.changedPaths, dir ~ "/a.json"));
    assert(containsPath(w.changedPaths, dir ~ "/sub/b.json"));
    assert(w.changedPaths.length == 2);

    remove(dir ~ "/sub/b.json");
    assert(pollUntil(w));
    assert(w.changedPaths == [dir ~ "/sub/b.json"]);
    w.shutdown();
    assert(!w.poll(1.0f));
}

version (linux) @("watcher.inotifyChangedPathsAndNewSubdirs") @trusted unittest {
    import std.file : mkdirRecurse, rmdirRecurse, write;

    immutable dir = watcherTestDir("inotify");
    scope (exit) rmdirRecurse(dir);

    FileWatcher w;
    assert(w.init([dir], 0.1f, WatchBackend.inotify));
    if (w.backend != WatchBackend.inotify) return; // inotify unavailable in this sandbox
    assert(w.watchedDirectoryCount == 1);

    write(dir ~ "/tune.json", "{}");
    assert(pollUntil(w));
    assert(w.changedPaths == [dir ~ "/tune.json"]);

    // New subdirectory gets a watch; a file written into it later is reported.
    mkdirRecurse(dir ~ "/nested");
    assert(pollUntil(w));
    assert(w.watchedDirectoryCount == 2);
    write(dir ~ "/nested/x.prefab.json", "{}");
    assert(pollUntil(w));
    assert(containsPath(w.changedPaths, dir ~ "/nested/x.prefab.json"));
    w.shutdown();
}

@("watcher.missingRootFails") unittest {
    FileWatcher w;
    assert(!w.init(["build/definitely_missing_dir_for_watcher"], 0.1f));
    assert(!w.active);
}
