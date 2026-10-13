/// Inotify-backed filesystem watcher with debouncing.
module engine.hotreload.watcher;

import core.sys.linux.sys.inotify;
import core.sys.posix.unistd : close, read;
import core.sys.posix.fcntl : fcntl, F_GETFL, F_SETFL, O_NONBLOCK;
import core.stdc.errno : errno, EAGAIN, EWOULDBLOCK;
import std.file : exists, isDir, dirEntries, SpanMode, timeLastModified;
import std.string : toStringz;
import std.datetime.systime : SysTime, Clock;

@safe:

struct FileWatcher {
    private int _fd = -1;
    private int[string] _watchMap;
    private float _debounceDuration = 0.3f; // 300ms
    private float _timer = 0.0f;
    private bool _hasPendingChanges = false;
    private string[] _changedPaths;

    bool init(string[] rootDirs, float debounceSeconds = 0.3f) @trusted {
        _debounceDuration = debounceSeconds;
        _fd = inotify_init1(IN_NONBLOCK);
        if (_fd < 0) return false;

        foreach (dir; rootDirs) {
            addDirectoryRecursive(dir);
        }
        return true;
    }

    void shutdown() @trusted {
        if (_fd >= 0) {
            foreach (wd; _watchMap.values) {
                inotify_rm_watch(_fd, wd);
            }
            _watchMap.clear();
            close(_fd);
            _fd = -1;
        }
    }

    void addDirectory(string path) @trusted {
        if (_fd < 0 || !exists(path) || !isDir(path)) return;
        if (path in _watchMap) return;

        immutable mask = IN_CLOSE_WRITE | IN_MOVED_TO | IN_CREATE | IN_DELETE;
        int wd = inotify_add_watch(_fd, path.toStringz(), mask);
        if (wd >= 0) {
            _watchMap[path] = wd;
        }
    }

    void addDirectoryRecursive(string root) @trusted {
        if (!exists(root) || !isDir(root)) return;
        addDirectory(root);
        try {
            foreach (entry; dirEntries(root, SpanMode.breadth)) {
                if (entry.isDir) {
                    addDirectory(entry.name);
                }
            }
        } catch (Exception) {}
    }

    /// Polls events. Returns true if debounced changes are ready to trigger.
    bool poll(float dt) @trusted {
        if (_fd < 0) return false;

        // Drain inotify events
        ubyte[4096] buffer = void;
        bool detectedEvent = false;

        while (true) {
            auto bytesRead = read(_fd, buffer.ptr, buffer.length);
            if (bytesRead <= 0) break;

            size_t offset = 0;
            while (offset < cast(size_t) bytesRead) {
                auto ev = cast(const(inotify_event)*)(buffer.ptr + offset);
                detectedEvent = true;
                offset += inotify_event.sizeof + ev.len;
            }
        }

        if (detectedEvent) {
            _hasPendingChanges = true;
            _timer = 0.0f; // reset debounce timer
        }

        if (_hasPendingChanges) {
            _timer += dt;
            if (_timer >= _debounceDuration) {
                _hasPendingChanges = false;
                _timer = 0.0f;
                return true;
            }
        }

        return false;
    }
}
