/// World Chunk Streaming (9 km² scale) with hysteresis, background I/O/decode,
/// frame-time-budgeted GPU/ECS upload queue, and reference-counted asset unloading.
module engine.scene.streamer;

import core.atomic : atomicLoad, atomicStore, MemoryOrder;
import core.stdc.stdio : fclose, fopen, fread, fseek, ftell, SEEK_END, SEEK_SET;
import core.stdc.stdlib : free, malloc;
import core.sync.mutex : Mutex;
import core.thread : Thread;
import core.time : MonoTime;

import engine.core.gc : ScopedGcExcludedThread;
import engine.core.log : info, warn;
import engine.core.pod : isPod, Pod;
import engine.core.strings : StringId, StringTable;
import engine.ecs.scene_world : SceneWorld;
import engine.ecs.store : EntityId;
import engine.editor.scene_load : loadSceneAdditive, SceneLoadOptions;
import engine.graphics.model : GltfAsset;
import engine.graphics.texture : Texture;
import engine.math.bounds : Aabb;
import engine.math.vec : Vec3;
import engine.nav.bake : loadNavMeshFromBytes;
import engine.nav.mesh : NavMesh;
import engine.physics.body : CookedMesh;
import engine.project.asset_ref : AssetGuid;
import engine.scene.scene_file :
    ChunkManifest, parseSceneJson, SceneFile;

@safe:

enum ChunkState : ubyte {
    unloaded  = 0,
    loading   = 1,
    active    = 2,
    unloading = 3,
}

enum StreamAssetKind : ubyte {
    gltfModel  = 0,
    texture    = 1,
    cookedMesh = 2,
    navMeshTile = 3,
}

struct ChunkCoord {
    int x = 0;
    int z = 0;
}
static assert(isPod!ChunkCoord);

struct StreamedAssetRef {
    StreamAssetKind kind = StreamAssetKind.gltfModel;
    uint slotIndex = 0;
}
static assert(isPod!StreamedAssetRef);

struct ChunkCell {
    ChunkCoord coord;
    Aabb bounds;
    StringId scenePath;
    StringId navmeshPath;
    ChunkState state = ChunkState.unloaded;
    uint loadGeneration = 0;
    uint entityOffset = 0;
    uint entityCount = 0;
    uint assetOffset = 0;
    uint assetCount = 0;
}
static assert(isPod!ChunkCell);

struct StreamedGltfEntry {
    AssetGuid guid;
    StringId path;
    uint refCount = 0;
    bool loaded = false;
}
static assert(isPod!StreamedGltfEntry);

struct StreamedTextureEntry {
    AssetGuid guid;
    StringId path;
    uint refCount = 0;
    bool loaded = false;
}
static assert(isPod!StreamedTextureEntry);

struct StreamedCookedMeshEntry {
    AssetGuid guid;
    StringId path;
    uint refCount = 0;
    bool loaded = false;
}
static assert(isPod!StreamedCookedMeshEntry);

struct StreamedNavTileEntry {
    AssetGuid guid;
    StringId path;
    ChunkCoord coord;
    uint refCount = 0;
    bool loaded = false;
}
static assert(isPod!StreamedNavTileEntry);

/// Background-decoded raw file payload (C-heap buffers freed after upload/cancel).
struct DecodedChunkJob {
    uint cellIndex = 0;
    uint generation = 0;
    bool decoded = false;
    bool hasSceneData = false;
    bool hasNavData = false;
    ubyte* rawSceneBytes = null;
    size_t rawSceneLen = 0;
    ubyte* rawNavBytes = null;
    size_t rawNavLen = 0;
}

enum UploadJobStep : ubyte {
    loadAssets    = 0,
    spawnEntities = 1,
}

struct UploadQueueEntry {
    uint cellIndex = 0;
    uint generation = 0;
    UploadJobStep step = UploadJobStep.loadAssets;
    uint assetCursor = 0;
    uint decodedJobIndex = 0;
}
static assert(isPod!UploadQueueEntry);

struct StreamerStats {
    uint loadedCount = 0;
    uint loadingCount = 0;
    uint activeCount = 0;
    uint unloadingCount = 0;
    uint totalUnloads = 0;
    uint totalLoads = 0;
    uint activeGltfCount = 0;
    uint activeTextureCount = 0;
    uint activeCookedMeshCount = 0;
    uint activeNavTileCount = 0;
}
static assert(isPod!StreamerStats);

/// Manages spatial world chunk streaming with hysteresis, background I/O/decode,
/// frame-budgeted upload/spawn, and reference-counted resource unloading.
struct WorldStreamer {
    float cellSize = 256.0f;
    float loadRadius = 512.0f;
    float unloadRadius = 640.0f;
    /// Optional synthetic test mode: skip disk reads when chunk files do not exist.
    bool allowVirtualChunks = false;

    StringTable strings;
    Pod!ChunkCell[] cells;

    private Pod!EntityId[] _cellEntities;
    private Pod!StreamedAssetRef[] _cellAssets;

    private Pod!StreamedGltfEntry[] _gltfCache;
    private GltfAsset*[] _gltfAssets;
    private Pod!StreamedTextureEntry[] _textureCache;
    private Texture*[] _textures;
    private Pod!StreamedCookedMeshEntry[] _cookedMeshCache;
    private CookedMesh*[] _cookedMeshes;
    private Pod!StreamedNavTileEntry[] _navTileCache;
    private NavMesh*[] _navMeshes;

    private DecodedChunkJob[] _pendingDecode;
    private DecodedChunkJob[] _completedDecode;
    private Pod!UploadQueueEntry[] _uploadQueue;

    private Mutex _workerMutex;
    private Thread _workerThread;
    private shared bool _workerRunning = false;
    private shared bool _workerStop = false;

    private uint _totalLoads = 0;
    private uint _totalUnloads = 0;

    @disable this(this);

    ~this() @trusted {
        stopWorker();
        destroyAll();
    }

    /// Initialize cells and radii from a `SceneFile` v2 `ChunkManifest`.
    void initFromManifest(const ref ChunkManifest manifest) @trusted {
        clear();
        cellSize = manifest.cellSize > 0.0f ? manifest.cellSize : 256.0f;
        loadRadius = manifest.loadRadius > 0.0f ? manifest.loadRadius : 512.0f;
        unloadRadius = manifest.unloadRadius > loadRadius
            ? manifest.unloadRadius : loadRadius + cellSize * 0.5f;

        foreach (ref ch; manifest.chunks) {
            Aabb b = Aabb(
                Vec3(ch.bounds.min[0], ch.bounds.min[1], ch.bounds.min[2]),
                Vec3(ch.bounds.max[0], ch.bounds.max[1], ch.bounds.max[2]));
            addCell(ChunkCoord(ch.coordX, ch.coordZ), b, ch.scenePath, ch.navmeshPath);
        }
    }

    /// Append a chunk cell manually (useful for procedural worlds or tests).
    uint addCell(
        ChunkCoord coord,
        Aabb bounds,
        scope const(char)[] scenePath,
        scope const(char)[] navmeshPath = null
    ) @trusted {
        ChunkCell c;
        c.coord = coord;
        c.bounds = bounds;
        if (scenePath.length > 0)
            c.scenePath = strings.intern(scenePath);
        if (navmeshPath.length > 0)
            c.navmeshPath = strings.intern(navmeshPath);
        cells ~= c;
        return cast(uint)(cells.length - 1);
    }

    /// Start a background I/O & decode thread excluded from GC STW pauses.
    void startWorker() @trusted {
        if (atomicLoad!(MemoryOrder.acq)(_workerRunning))
            return;
        if (_workerMutex is null)
            _workerMutex = new Mutex();
        atomicStore!(MemoryOrder.rel)(_workerStop, false);
        atomicStore!(MemoryOrder.rel)(_workerRunning, true);
        auto selfPtr = &this;
        _workerThread = new Thread(() {
            workerLoop(selfPtr);
        });
        _workerThread.isDaemon = true;
        _workerThread.start();
    }

    /// Stop the background worker thread cleanly.
    void stopWorker() @trusted {
        if (!atomicLoad!(MemoryOrder.acq)(_workerRunning))
            return;
        atomicStore!(MemoryOrder.rel)(_workerStop, true);
        if (_workerThread !is null) {
            _workerThread.join();
            _workerThread = null;
        }
        atomicStore!(MemoryOrder.rel)(_workerRunning, false);
    }

    /// Main per-frame update: evaluates hysteresis, pumps background decodes,
    /// unloads out-of-range chunks, and processes the budgeted upload queue.
    void update(ref SceneWorld world, Vec3 focusPos, float uploadBudgetMs = 2.0f) @trusted {
        evaluateHysteresis(focusPos);
        if (!atomicLoad!(MemoryOrder.acq)(_workerRunning)) {
            pumpDecodeJobs();
        }
        drainCompletedDecodes();
        processUnloads(world);
        processUploadQueue(world, uploadBudgetMs);
    }

    /// Update chunk states based on XZ distance from `focusPos` with hysteresis.
    void evaluateHysteresis(Vec3 focusPos) @trusted {
        immutable float loadR2 = loadRadius * loadRadius;
        immutable float unloadR2 = unloadRadius * unloadRadius;

        foreach (i, ref cell; cells) {
            immutable float d2 = cellDistanceSqXZ(cell, focusPos);
            if (cell.state == ChunkState.unloaded) {
                if (d2 <= loadR2) {
                    enqueueCellLoad(cast(uint) i);
                }
            } else if (cell.state == ChunkState.active) {
                if (d2 > unloadR2) {
                    cell.state = ChunkState.unloading;
                }
            } else if (cell.state == ChunkState.loading) {
                if (d2 > unloadR2) {
                    // Cancel pending load by bumping generation.
                    cell.loadGeneration++;
                    cell.state = ChunkState.unloaded;
                }
            }
        }
    }

    /// Synchronously execute pending decode jobs (when no background worker thread is running).
    void pumpDecodeJobs() @trusted {
        if (_pendingDecode.length == 0)
            return;
        for (size_t i = 0; i < _pendingDecode.length; i++) {
            auto job = _pendingDecode[i];
            executeDecodeJobNoGc(job);
            _completedDecode ~= job;
        }
        _pendingDecode.length = 0;
    }

    /// Move completed decode jobs into the frame-budgeted upload queue.
    void drainCompletedDecodes() @trusted {
        if (_workerMutex !is null)
            _workerMutex.lock();
        scope (exit) {
            if (_workerMutex !is null)
                _workerMutex.unlock();
        }

        foreach (ref job; _completedDecode) {
            if (job.cellIndex >= cells.length) {
                freeDecodedBuffers(job);
                continue;
            }
            const cell = cells[job.cellIndex];
            if (cell.state != ChunkState.loading || cell.loadGeneration != job.generation) {
                freeDecodedBuffers(job);
                continue;
            }
            // Keep decoded job stored in _pendingUploadJobs via _completedDecode? We store index
            // in UploadQueueEntry and free when UploadQueueEntry completes.
            UploadQueueEntry q;
            q.cellIndex = job.cellIndex;
            q.generation = job.generation;
            q.step = UploadJobStep.loadAssets;
            q.assetCursor = 0;
            q.decodedJobIndex = cast(uint) _uploadJobs.length;
            _uploadJobs ~= job;
            _uploadQueue ~= q;
        }
        _completedDecode.length = 0;
    }

    private DecodedChunkJob[] _uploadJobs;

    /// Process queued upload/spawn steps within `maxBudgetMs` (always advances at least 1 step).
    uint processUploadQueue(ref SceneWorld world, float maxBudgetMs = 2.0f) @trusted {
        if (_uploadQueue.length == 0)
            return 0;

        immutable start = MonoTime.currTime();
        immutable long budgetHns = cast(long)(maxBudgetMs * 10_000.0f);
        uint stepsProcessed = 0;
        size_t head = 0;

        while (head < _uploadQueue.length) {
            if (stepsProcessed > 0) {
                immutable elapsedHns = (MonoTime.currTime() - start).total!"hnsecs";
                if (elapsedHns >= budgetHns)
                    break;
            }

            auto entry = _uploadQueue[head];
            if (entry.cellIndex >= cells.length) {
                if (entry.decodedJobIndex < _uploadJobs.length)
                    freeDecodedBuffers(_uploadJobs[entry.decodedJobIndex]);
                head++;
                stepsProcessed++;
                continue;
            }

            auto cell = &cells[entry.cellIndex];
            if (cell.state != ChunkState.loading || cell.loadGeneration != entry.generation) {
                if (entry.decodedJobIndex < _uploadJobs.length)
                    freeDecodedBuffers(_uploadJobs[entry.decodedJobIndex]);
                head++;
                stepsProcessed++;
                continue;
            }

            if (entry.step == UploadJobStep.loadAssets) {
                prepareChunkAssets(entry.cellIndex, entry.decodedJobIndex);
                _uploadQueue[head].step = UploadJobStep.spawnEntities;
                stepsProcessed++;
                continue;
            }

            // UploadJobStep.spawnEntities
            activateChunkEntities(world, entry.cellIndex, entry.decodedJobIndex);
            if (entry.decodedJobIndex < _uploadJobs.length)
                freeDecodedBuffers(_uploadJobs[entry.decodedJobIndex]);
            head++;
            stepsProcessed++;
        }

        if (head > 0) {
            if (head >= _uploadQueue.length) {
                _uploadQueue.length = 0;
                _uploadJobs.length = 0;
            } else {
                immutable remaining = _uploadQueue.length - head;
                foreach (i; 0 .. remaining)
                    _uploadQueue[i] = _uploadQueue[head + i];
                _uploadQueue.length = remaining;
            }
        }
        return stepsProcessed;
    }

    /// Unload all cells in `ChunkState.unloading`: destroy entities, release asset ref-counts,
    /// and destroy any asset whose ref-count drops to 0.
    void processUnloads(ref SceneWorld world) @trusted {
        foreach (i, ref cell; cells) {
            if (cell.state != ChunkState.unloading)
                continue;

            // Destroy chunk entities (EntityId slots are recycled into World free-list).
            immutable entEnd = cell.entityOffset + cell.entityCount;
            if (entEnd <= _cellEntities.length) {
                foreach (idx; cell.entityOffset .. entEnd) {
                    immutable eid = _cellEntities[idx];
                    if (world.alive(eid))
                        world.destroy(eid);
                }
            }
            cell.entityOffset = 0;
            cell.entityCount = 0;

            // Release ref-counted assets owned by this cell.
            immutable assetEnd = cell.assetOffset + cell.assetCount;
            if (assetEnd <= _cellAssets.length) {
                foreach (idx; cell.assetOffset .. assetEnd) {
                    releaseAsset(_cellAssets[idx]);
                }
            }
            cell.assetOffset = 0;
            cell.assetCount = 0;

            cell.state = ChunkState.unloaded;
            _totalUnloads++;
        }

        // Compact storage when no cells are active or loading.
        bool anyLive = false;
        foreach (ref cell; cells) {
            if (cell.state == ChunkState.active || cell.state == ChunkState.loading) {
                anyLive = true;
                break;
            }
        }
        if (!anyLive) {
            _cellEntities.length = 0;
            _cellAssets.length = 0;
        }
    }

    /// Acquire (or increment ref-count on) a `GltfAsset` slot.
    StreamedAssetRef acquireGltf(AssetGuid guid, scope const(char)[] path) @trusted {
        immutable sid = strings.intern(path);
        foreach (i, ref e; _gltfCache) {
            if ((!guid.isNull() && e.guid == guid) || e.path == sid) {
                e.refCount++;
                e.loaded = true;
                if (_gltfAssets[i] is null) _gltfAssets[i] = new GltfAsset;
                return StreamedAssetRef(StreamAssetKind.gltfModel, cast(uint) i);
            }
        }
        StreamedGltfEntry entry;
        entry.guid = guid;
        entry.path = sid;
        entry.refCount = 1;
        entry.loaded = true;
        _gltfCache ~= entry;
        _gltfAssets ~= new GltfAsset;
        return StreamedAssetRef(StreamAssetKind.gltfModel, cast(uint)(_gltfCache.length - 1));
    }

    /// Acquire (or increment ref-count on) a `Texture` slot.
    StreamedAssetRef acquireTexture(AssetGuid guid, scope const(char)[] path) @trusted {
        immutable sid = strings.intern(path);
        foreach (i, ref e; _textureCache) {
            if ((!guid.isNull() && e.guid == guid) || e.path == sid) {
                e.refCount++;
                e.loaded = true;
                if (_textures[i] is null) _textures[i] = new Texture;
                return StreamedAssetRef(StreamAssetKind.texture, cast(uint) i);
            }
        }
        StreamedTextureEntry entry;
        entry.guid = guid;
        entry.path = sid;
        entry.refCount = 1;
        entry.loaded = true;
        _textureCache ~= entry;
        _textures ~= new Texture;
        return StreamedAssetRef(StreamAssetKind.texture, cast(uint)(_textureCache.length - 1));
    }

    /// Acquire (or increment ref-count on) a `CookedMesh` slot.
    StreamedAssetRef acquireCookedMesh(AssetGuid guid, scope const(char)[] path) @trusted {
        immutable sid = strings.intern(path);
        foreach (i, ref e; _cookedMeshCache) {
            if ((!guid.isNull() && e.guid == guid) || e.path == sid) {
                e.refCount++;
                e.loaded = true;
                if (_cookedMeshes[i] is null) _cookedMeshes[i] = new CookedMesh;
                return StreamedAssetRef(StreamAssetKind.cookedMesh, cast(uint) i);
            }
        }
        StreamedCookedMeshEntry entry;
        entry.guid = guid;
        entry.path = sid;
        entry.refCount = 1;
        entry.loaded = true;
        _cookedMeshCache ~= entry;
        _cookedMeshes ~= new CookedMesh;
        return StreamedAssetRef(StreamAssetKind.cookedMesh, cast(uint)(_cookedMeshCache.length - 1));
    }

    /// Acquire (or increment ref-count on) a `NavMesh` tile slot.
    StreamedAssetRef acquireNavTile(
        AssetGuid guid,
        scope const(char)[] path,
        ChunkCoord coord,
        scope const(ubyte)[] navBytes = null
    ) @trusted {
        immutable sid = strings.intern(path);
        foreach (i, ref e; _navTileCache) {
            if ((!guid.isNull() && e.guid == guid) || (e.path == sid && e.coord == coord)) {
                e.refCount++;
                e.loaded = true;
                if (_navMeshes[i] is null) _navMeshes[i] = new NavMesh;
                return StreamedAssetRef(StreamAssetKind.navMeshTile, cast(uint) i);
            }
        }
        StreamedNavTileEntry entry;
        entry.guid = guid;
        entry.path = sid;
        entry.coord = coord;
        entry.refCount = 1;
        entry.loaded = true;
        auto nmPtr = new NavMesh;
        if (navBytes.length > 0) {
            import core.lifetime : move;
            auto nm = loadNavMeshFromBytes(navBytes);
            move(nm, *nmPtr);
        }
        _navTileCache ~= entry;
        _navMeshes ~= nmPtr;
        return StreamedAssetRef(StreamAssetKind.navMeshTile, cast(uint)(_navTileCache.length - 1));
    }

    /// Decrement ref-count and destroy the underlying GPU/physics/nav resource when `refCount == 0`.
    void releaseAsset(StreamedAssetRef r) @trusted {
        final switch (r.kind) {
            case StreamAssetKind.gltfModel:
                if (r.slotIndex < _gltfCache.length) {
                    auto e = &_gltfCache[r.slotIndex];
                    if (e.refCount > 0) e.refCount--;
                    if (e.refCount == 0 && e.loaded) {
                        if (_gltfAssets[r.slotIndex] !is null) _gltfAssets[r.slotIndex].destroy();
                        e.loaded = false;
                    }
                }
                break;
            case StreamAssetKind.texture:
                if (r.slotIndex < _textureCache.length) {
                    auto e = &_textureCache[r.slotIndex];
                    if (e.refCount > 0) e.refCount--;
                    if (e.refCount == 0 && e.loaded) {
                        if (_textures[r.slotIndex] !is null) _textures[r.slotIndex].destroy();
                        e.loaded = false;
                    }
                }
                break;
            case StreamAssetKind.cookedMesh:
                if (r.slotIndex < _cookedMeshCache.length) {
                    auto e = &_cookedMeshCache[r.slotIndex];
                    if (e.refCount > 0) e.refCount--;
                    if (e.refCount == 0 && e.loaded) {
                        if (_cookedMeshes[r.slotIndex] !is null) _cookedMeshes[r.slotIndex].destroy();
                        e.loaded = false;
                    }
                }
                break;
            case StreamAssetKind.navMeshTile:
                if (r.slotIndex < _navTileCache.length) {
                    auto e = &_navTileCache[r.slotIndex];
                    if (e.refCount > 0) e.refCount--;
                    if (e.refCount == 0 && e.loaded) {
                        if (_navMeshes[r.slotIndex] !is null) _navMeshes[r.slotIndex].destroy();
                        e.loaded = false;
                    }
                }
                break;
        }
    }

    uint assetRefCount(StreamedAssetRef r) const pure nothrow @nogc {
        final switch (r.kind) {
            case StreamAssetKind.gltfModel:
                return r.slotIndex < _gltfCache.length ? _gltfCache[r.slotIndex].refCount : 0;
            case StreamAssetKind.texture:
                return r.slotIndex < _textureCache.length ? _textureCache[r.slotIndex].refCount : 0;
            case StreamAssetKind.cookedMesh:
                return r.slotIndex < _cookedMeshCache.length ? _cookedMeshCache[r.slotIndex].refCount : 0;
            case StreamAssetKind.navMeshTile:
                return r.slotIndex < _navTileCache.length ? _navTileCache[r.slotIndex].refCount : 0;
        }
    }

    bool isAssetLoaded(StreamedAssetRef r) const pure nothrow @nogc {
        final switch (r.kind) {
            case StreamAssetKind.gltfModel:
                return r.slotIndex < _gltfCache.length && _gltfCache[r.slotIndex].loaded;
            case StreamAssetKind.texture:
                return r.slotIndex < _textureCache.length && _textureCache[r.slotIndex].loaded;
            case StreamAssetKind.cookedMesh:
                return r.slotIndex < _cookedMeshCache.length && _cookedMeshCache[r.slotIndex].loaded;
            case StreamAssetKind.navMeshTile:
                return r.slotIndex < _navTileCache.length && _navTileCache[r.slotIndex].loaded;
        }
    }

    StreamerStats stats() const pure nothrow @nogc {
        StreamerStats s;
        s.totalLoads = _totalLoads;
        s.totalUnloads = _totalUnloads;
        foreach (ref c; cells) {
            final switch (c.state) {
                case ChunkState.unloaded: break;
                case ChunkState.loading: s.loadingCount++; break;
                case ChunkState.active: s.activeCount++; s.loadedCount++; break;
                case ChunkState.unloading: s.unloadingCount++; break;
            }
        }
        foreach (ref e; _gltfCache) if (e.loaded) s.activeGltfCount++;
        foreach (ref e; _textureCache) if (e.loaded) s.activeTextureCount++;
        foreach (ref e; _cookedMeshCache) if (e.loaded) s.activeCookedMeshCount++;
        foreach (ref e; _navTileCache) if (e.loaded) s.activeNavTileCount++;
        return s;
    }

    size_t pendingUploadCount() const pure nothrow @nogc {
        return _uploadQueue.length;
    }

    void clear() @trusted {
        destroyAll();
        cells.length = 0;
        _cellEntities.length = 0;
        _cellAssets.length = 0;
        _totalLoads = 0;
        _totalUnloads = 0;
    }

    void destroyAll() @trusted {
        foreach (ref j; _pendingDecode) freeDecodedBuffers(j);
        _pendingDecode.length = 0;
        foreach (ref j; _completedDecode) freeDecodedBuffers(j);
        _completedDecode.length = 0;
        foreach (ref j; _uploadJobs) freeDecodedBuffers(j);
        _uploadJobs.length = 0;
        _uploadQueue.length = 0;

        foreach (i, ref e; _gltfCache) {
            if (e.loaded && _gltfAssets[i] !is null) _gltfAssets[i].destroy();
            e.loaded = false;
            e.refCount = 0;
        }
        _gltfCache.length = 0;
        _gltfAssets.length = 0;
        foreach (i, ref e; _textureCache) {
            if (e.loaded && _textures[i] !is null) _textures[i].destroy();
            e.loaded = false;
            e.refCount = 0;
        }
        _textureCache.length = 0;
        _textures.length = 0;
        foreach (i, ref e; _cookedMeshCache) {
            if (e.loaded && _cookedMeshes[i] !is null) _cookedMeshes[i].destroy();
            e.loaded = false;
            e.refCount = 0;
        }
        _cookedMeshCache.length = 0;
        _cookedMeshes.length = 0;
        foreach (i, ref e; _navTileCache) {
            if (e.loaded && _navMeshes[i] !is null) _navMeshes[i].destroy();
            e.loaded = false;
            e.refCount = 0;
        }
        _navTileCache.length = 0;
        _navMeshes.length = 0;
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

    private void enqueueCellLoad(uint cellIdx) @trusted {
        auto cell = &cells[cellIdx];
        cell.state = ChunkState.loading;
        cell.loadGeneration++;

        DecodedChunkJob job;
        job.cellIndex = cellIdx;
        job.generation = cell.loadGeneration;

        if (_workerMutex !is null)
            _workerMutex.lock();
        _pendingDecode ~= job;
        if (_workerMutex !is null)
            _workerMutex.unlock();
    }

    private void prepareChunkAssets(uint cellIdx, uint jobIdx) @trusted {
        auto cell = &cells[cellIdx];
        immutable assetStart = cast(uint) _cellAssets.length;
        uint assetCount = 0;

        if (jobIdx < _uploadJobs.length) {
            const job = _uploadJobs[jobIdx];
            if (job.hasNavData && job.rawNavBytes !is null && job.rawNavLen > 0) {
                auto navBytes = job.rawNavBytes[0 .. job.rawNavLen];
                auto r = acquireNavTile(AssetGuid.init, strings.get(cell.navmeshPath), cell.coord, navBytes);
                _cellAssets ~= r;
                assetCount++;
            } else if (!cell.navmeshPath.isNull && allowVirtualChunks) {
                auto r = acquireNavTile(AssetGuid.init, strings.get(cell.navmeshPath), cell.coord);
                _cellAssets ~= r;
                assetCount++;
            }

            if (job.hasSceneData && job.rawSceneBytes !is null && job.rawSceneLen > 0) {
                auto jsonText = cast(string) job.rawSceneBytes[0 .. job.rawSceneLen];
                try {
                    auto sf = parseSceneJson(jsonText);
                    foreach (ref link; sf.assetLinks) {
                        auto guid = AssetGuid.fromString(link.guid);
                        string path = (link.path >= 0 && link.path < cast(int) sf.strings.length)
                            ? sf.strings[link.path] : "";
                        if (link.kind == "texture") {
                            _cellAssets ~= acquireTexture(guid, path);
                            assetCount++;
                        } else if (link.kind == "cookedMesh") {
                            _cellAssets ~= acquireCookedMesh(guid, path);
                            assetCount++;
                        } else if (link.kind == "navmesh") {
                            _cellAssets ~= acquireNavTile(guid, path, cell.coord);
                            assetCount++;
                        } else if (link.kind == "splines") {
                            // CPU-side path data (`engine.scene.splines`), not a GPU asset.
                        } else {
                            _cellAssets ~= acquireGltf(guid, path);
                            assetCount++;
                        }
                    }
                    foreach (ref e; sf.entities) {
                        if (e.hasVisual && e.visual.hasAsset &&
                            e.visual.asset >= 0 && e.visual.asset < cast(int) sf.strings.length) {
                            auto guid = e.visual.hasAssetGuid
                                ? AssetGuid.fromString(e.visual.assetGuid)
                                : AssetGuid.init;
                            _cellAssets ~= acquireGltf(guid, sf.strings[e.visual.asset]);
                            assetCount++;
                        }
                    }
                } catch (Exception ex) {
                    warn("WorldStreamer: failed to parse chunk scene: ", ex.msg);
                }
            }
        }

        cell.assetOffset = assetStart;
        cell.assetCount = assetCount;
    }

    private void activateChunkEntities(ref SceneWorld world, uint cellIdx, uint jobIdx) @trusted {
        auto cell = &cells[cellIdx];
        immutable entStart = cast(uint) _cellEntities.length;
        uint entCount = 0;

        if (jobIdx < _uploadJobs.length) {
            const job = _uploadJobs[jobIdx];
            if (job.hasSceneData && job.rawSceneBytes !is null && job.rawSceneLen > 0) {
                auto jsonText = cast(string) job.rawSceneBytes[0 .. job.rawSceneLen];
                try {
                    auto sf = parseSceneJson(jsonText);
                    SceneLoadOptions opts;
                    opts.validate = false;
                    opts.checkAssetFiles = false;
                    auto res = loadSceneAdditive(world, sf, Vec3(0, 0, 0), opts);
                    foreach (eid; res.spawnedEntities) {
                        _cellEntities ~= eid;
                        entCount++;
                    }
                } catch (Exception ex) {
                    warn("WorldStreamer: failed to spawn chunk entities: ", ex.msg);
                }
            }
        }

        cell.entityOffset = entStart;
        cell.entityCount = entCount;
        cell.state = ChunkState.active;
        _totalLoads++;
    }

    private void executeDecodeJobNoGc(ref DecodedChunkJob job) @trusted {
        if (job.cellIndex >= cells.length)
            return;
        const cell = cells[job.cellIndex];
        if (!cell.scenePath.isNull) {
            auto path = strings.get(cell.scenePath);
            if (readFileNoGc(path, job.rawSceneBytes, job.rawSceneLen))
                job.hasSceneData = true;
        }
        if (!cell.navmeshPath.isNull) {
            auto path = strings.get(cell.navmeshPath);
            if (readFileNoGc(path, job.rawNavBytes, job.rawNavLen))
                job.hasNavData = true;
        }
        job.decoded = true;
    }

    private static void workerLoop(WorldStreamer* self) @trusted {
        auto gcGuard = ScopedGcExcludedThread.enter();
        while (!atomicLoad!(MemoryOrder.acq)(self._workerStop)) {
            DecodedChunkJob job;
            bool hasJob = false;

            self._workerMutex.lock();
            if (self._pendingDecode.length > 0) {
                job = self._pendingDecode[0];
                immutable rem = self._pendingDecode.length - 1;
                foreach (i; 0 .. rem)
                    self._pendingDecode[i] = self._pendingDecode[i + 1];
                self._pendingDecode.length = rem;
                hasJob = true;
            }
            self._workerMutex.unlock();

            if (hasJob) {
                self.executeDecodeJobNoGc(job);
                self._workerMutex.lock();
                self._completedDecode ~= job;
                self._workerMutex.unlock();
            } else {
                import core.time : msecs;
                Thread.sleep(2.msecs);
            }
        }
    }
}

private float cellDistanceSqXZ(const ref ChunkCell cell, Vec3 focusPos) pure nothrow @nogc {
    immutable cx = (cell.bounds.min.x + cell.bounds.max.x) * 0.5f;
    immutable cz = (cell.bounds.min.z + cell.bounds.max.z) * 0.5f;
    immutable dx = focusPos.x - cx;
    immutable dz = focusPos.z - cz;
    return dx * dx + dz * dz;
}

private bool readFileNoGc(scope const(char)[] path, out ubyte* outPtr, out size_t outLen) nothrow @nogc @trusted {
    outPtr = null;
    outLen = 0;
    if (path.length == 0 || path.length >= 1020)
        return false;

    char[1024] cPath = 0;
    cPath[0 .. path.length] = path[];
    cPath[path.length] = '\0';

    auto f = fopen(cPath.ptr, "rb");
    if (f is null)
        return false;
    scope (exit) fclose(f);

    if (fseek(f, 0, SEEK_END) != 0)
        return false;
    immutable sz = ftell(f);
    if (sz <= 0)
        return false;
    if (fseek(f, 0, SEEK_SET) != 0)
        return false;

    auto buf = cast(ubyte*) malloc(cast(size_t) sz);
    if (buf is null)
        return false;
    immutable got = fread(buf, 1, cast(size_t) sz, f);
    if (got == 0) {
        free(buf);
        return false;
    }
    outPtr = buf;
    outLen = got;
    return true;
}

private void freeDecodedBuffers(ref DecodedChunkJob job) nothrow @nogc @trusted {
    if (job.rawSceneBytes !is null) {
        free(job.rawSceneBytes);
        job.rawSceneBytes = null;
        job.rawSceneLen = 0;
    }
    if (job.rawNavBytes !is null) {
        free(job.rawNavBytes);
        job.rawNavBytes = null;
        job.rawNavLen = 0;
    }
}

// ---------------------------------------------------------------------------
// Unit tests (hysteresis, budgeted queue, ref-counting, 100-cycle 9 km² soak)
// ---------------------------------------------------------------------------

@("streamer.hysteresisAndBudget") @safe unittest {
    SceneWorld world;
    WorldStreamer streamer;
    streamer.cellSize = 256.0f;
    streamer.loadRadius = 300.0f;
    streamer.unloadRadius = 450.0f;
    streamer.allowVirtualChunks = true;

    streamer.addCell(
        ChunkCoord(0, 0),
        Aabb(Vec3(0, 0, 0), Vec3(256, 64, 256)),
        "", "virtual_0_0.navmesh");
    streamer.addCell(
        ChunkCoord(1, 0),
        Aabb(Vec3(256, 0, 0), Vec3(512, 64, 256)),
        "", "virtual_1_0.navmesh");

    // Focus at cell (0,0) center (128, 0, 128): cell 0 dist=0 <= 300, cell 1 dist=256 <= 300
    streamer.evaluateHysteresis(Vec3(128, 0, 128));
    assert(streamer.cells[0].state == ChunkState.loading);
    assert(streamer.cells[1].state == ChunkState.loading);
    streamer.pumpDecodeJobs();
    streamer.drainCompletedDecodes();
    assert(streamer.pendingUploadCount() == 2);

    // Zero-ms budget processes 1 step at a time (progressive upload).
    immutable s1 = streamer.processUploadQueue(world, 0.0f);
    assert(s1 == 1);
    assert(streamer.cells[0].state == ChunkState.loading); // still at spawnEntities step

    // Drain remaining steps
    while (streamer.pendingUploadCount() > 0)
        streamer.processUploadQueue(world, 50.0f);
    assert(streamer.cells[0].state == ChunkState.active);
    assert(streamer.cells[1].state == ChunkState.active);

    // Move focus to (-220, 0, 128): dist to cell 0 center (128,128) is 348m -> inside [300, 450] deadband!
    // Cell 0 MUST stay active (no thrashing). Cell 1 center (384,128) is 604m > 450 -> unloading!
    streamer.update(world, Vec3(-220, 0, 128));
    assert(streamer.cells[0].state == ChunkState.active);
    assert(streamer.cells[1].state == ChunkState.unloaded);
}

@("streamer.refCountedSharedAssets") @safe unittest {
    WorldStreamer streamer;
    auto g = AssetGuid.generate();
    auto r1 = streamer.acquireGltf(g, "assets/models/shared_tree.asset.json");
    auto r2 = streamer.acquireGltf(g, "assets/models/shared_tree.asset.json");
    assert(r1.slotIndex == r2.slotIndex);
    assert(streamer.assetRefCount(r1) == 2);
    assert(streamer.isAssetLoaded(r1));

    auto t1 = streamer.acquireTexture(AssetGuid.init, "assets/tex/road.png");
    auto m1 = streamer.acquireCookedMesh(AssetGuid.init, "assets/models/road.asset.json");
    auto n1 = streamer.acquireNavTile(AssetGuid.init, "assets/nav/0_0.navmesh", ChunkCoord(0, 0));
    assert(streamer.isAssetLoaded(t1));
    assert(streamer.isAssetLoaded(m1));
    assert(streamer.isAssetLoaded(n1));

    streamer.releaseAsset(r1);
    assert(streamer.assetRefCount(r1) == 1);
    assert(streamer.isAssetLoaded(r1));

    streamer.releaseAsset(r2);
    assert(streamer.assetRefCount(r1) == 0);
    assert(!streamer.isAssetLoaded(r1));

    streamer.releaseAsset(t1);
    streamer.releaseAsset(m1);
    streamer.releaseAsset(n1);
    assert(!streamer.isAssetLoaded(t1));
    assert(!streamer.isAssetLoaded(m1));
    assert(!streamer.isAssetLoaded(n1));
}

@("streamer.soak100Cycles9Km2") @safe unittest {
    import std.file : mkdirRecurse, rmdirRecurse, write;
    import std.format : format;
    import engine.editor.components : Visual;
    import engine.scene.graph : Transform;
    import engine.scene.scene_file :
        ChunkManifest, saveSceneFile, SceneAssetLink, SceneCellBounds,
        SceneChunkDescriptor, SceneEntityData;

    immutable tmpDir = "build/test_streamer_soak";
    mkdirRecurse(tmpDir);
    scope (exit) {
        import std.file : exists;
        if (exists(tmpDir)) rmdirRecurse(tmpDir);
    }

    // Build a 3072m x 3072m (9.4 km², 12 x 12 cells of 256m) manifest with chunk files.
    ChunkManifest manifest;
    manifest.cellSize = 256.0f;
    manifest.loadRadius = 300.0f;
    manifest.unloadRadius = 420.0f;

    foreach (cz; 0 .. 12) {
        foreach (cx; 0 .. 12) {
            immutable path = format("%s/chunk_%d_%d.scene.json", tmpDir, cx, cz);
            SceneFile cf;
            cf.schemaVersion = 2;
            cf.meta.name = format("chunk_%d_%d", cx, cz);
            cf.strings = ["assets/models/crate.asset.json"];
            cf.assetLinks ~= SceneAssetLink("0123456789abcdef0123456789abcdef", 0, "model");
            foreach (k; 0 .. 4) {
                SceneEntityData e;
                e.id = cast(uint)(k + 1);
                e.transform.pos = [cx * 256.0f + k * 10.0f, 0.0f, cz * 256.0f];
                e.hasVisual = true;
                e.visual.hasKind = true;
                e.visual.kind = "cube";
                cf.entities ~= e;
            }
            saveSceneFile(path, cf);

            SceneChunkDescriptor desc;
            desc.coordX = cx;
            desc.coordZ = cz;
            desc.bounds = SceneCellBounds(
                [cx * 256.0f, -10.0f, cz * 256.0f],
                [(cx + 1) * 256.0f, 200.0f, (cz + 1) * 256.0f]);
            desc.scenePath = path;
            manifest.chunks ~= desc;
        }
    }

    SceneWorld world;
    world.ensureRegistered!Transform();
    world.ensureRegistered!Visual();

    WorldStreamer streamer;
    streamer.initFromManifest(manifest);
    assert(streamer.cells.length == 144);

    // 100 chunk load/unload soak cycles: alternate between corner A and corner B
    size_t peakCapacity = 0;
    foreach (cycle; 0 .. 100) {
        Vec3 pos = (cycle % 2 == 0)
            ? Vec3(128.0f, 0.0f, 128.0f)
            : Vec3(2944.0f, 0.0f, 2944.0f);
        streamer.update(world, pos, 50.0f);
        if (world.capacity() > peakCapacity)
            peakCapacity = world.capacity();
    }

    // Move far outside the 9 km² map so every active chunk unloads cleanly.
    streamer.update(world, Vec3(-5000.0f, 0.0f, -5000.0f), 50.0f);

    immutable st = streamer.stats();
    assert(st.activeCount == 0);
    assert(st.totalLoads >= 100);
    assert(st.totalUnloads == st.totalLoads);
    assert(st.activeGltfCount == 0);
    assert(world.entityCount() == 0);
    assert(world.capacity() <= 64, "EntityId recycling must keep capacity bounded");
    assert(peakCapacity <= 64);
}
