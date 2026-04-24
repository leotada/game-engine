module engine.jph.physics.constraints.contact_constraint_manager_cache;

import engine.jph.core.array : Array;
import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.collision.collide_shape : cMaxContactPoints;
import engine.jph.physics.constraints.contact_constraint : ContactConstraint;

@safe:

struct CachedContactPoint {
@safe:
    Vec3 mPointOn1 = Vec3.sZero();
    Vec3 mPointOn2 = Vec3.sZero();
    float mNormalLambda = 0.0f;
    float[2] mFrictionLambda = [0.0f, 0.0f];
}

struct CachedManifold {
@safe:
    BodyID mBody1ID;
    BodyID mBody2ID;
    Vec3 mWorldSpaceNormal = Vec3.sZero();
    CachedContactPoint[cMaxContactPoints] mPoints;
    uint mNumContactPoints = 0;

    void AssignFromConstraint(ref const(ContactConstraint) inConstraint) nothrow @nogc {
        mBody1ID = inConstraint.mBody1ID;
        mBody2ID = inConstraint.mBody2ID;
        mWorldSpaceNormal = inConstraint.mWorldSpaceNormal;
        mNumContactPoints = inConstraint.GetNumContactPoints();

        foreach (index; 0 .. cMaxContactPoints) {
            mPoints[index] = CachedContactPoint.init;
            if (index >= mNumContactPoints)
                continue;

            immutable point = inConstraint.GetContactPoint(index);
            mPoints[index].mPointOn1 = point.mPointOn1;
            mPoints[index].mPointOn2 = point.mPointOn2;
            mPoints[index].mNormalLambda = point.mNormalPart.mTotalLambda;
            mPoints[index].mFrictionLambda[0] = point.mFrictionParts[0].mTotalLambda;
            mPoints[index].mFrictionLambda[1] = point.mFrictionParts[1].mTotalLambda;
        }
    }
}

struct ContactConstraintManagerCache {
@safe:
    Array!CachedManifold mManifolds;
    bool mSorted = false; // true after StoreConstraints sorts the array

    void Clear() nothrow @nogc {
        mManifolds.clear();
        mSorted = false;
    }

    void StoreConstraints(const(ContactConstraint)[] inConstraints) nothrow @nogc {
        mManifolds.clear();

        foreach (constraint; inConstraints) {
            CachedManifold manifold;
            manifold.AssignFromConstraint(constraint);
            mManifolds.push_back(manifold);
        }

        // Sort by canonical pair key so FindManifold can binary-search.
        // Insertion sort: manifold arrays are small (<= 4096) and nearly
        // sorted each frame (persistent contacts dominate).
        size_t n = mManifolds.size;
        foreach (i; 1 .. n) {
            immutable ulong ki = pairKey(mManifolds[i].mBody1ID, mManifolds[i].mBody2ID);
            CachedManifold tmp = mManifolds[i];
            long j = cast(long) i - 1;
            while (j >= 0 && pairKey(mManifolds[j].mBody1ID, mManifolds[j].mBody2ID) > ki) {
                mManifolds[j + 1] = mManifolds[j];
                --j;
            }
            mManifolds[j + 1] = tmp;
        }
        mSorted = true;
    }

    const(CachedManifold)[] GetManifolds() const nothrow @nogc {
        return mManifolds[];
    }

    /// O(log N) lookup by body pair.  Returns null if not found.
    /// Caller should try both (a,b) and (b,a) orders.
    const(CachedManifold)* FindManifold(BodyID a, BodyID b) const nothrow @nogc @trusted {
        if (!mSorted || mManifolds.size == 0) return null;
        immutable ulong target = pairKey(a, b);
        size_t lo = 0, hi = mManifolds.size;
        while (lo < hi) {
            immutable size_t mid = (lo + hi) >> 1;
            immutable ulong k = pairKey(mManifolds[mid].mBody1ID, mManifolds[mid].mBody2ID);
            if      (k < target) lo = mid + 1;
            else if (k > target) hi = mid;
            else                 return &(cast(CachedManifold[]) mManifolds[])[mid];
        }
        return null;
    }

    /// Same lookup on an arbitrary sorted slice — used by ContactConstraintManager
    /// and PhysicsSystem without needing a struct instance.
    package(engine.jph.physics)
    static const(CachedManifold)* staticFindIn(
            const(CachedManifold)[] cache,
            BodyID a, BodyID b) nothrow @nogc @trusted {
        if (cache.length == 0) return null;
        immutable ulong target = pairKey(a, b);
        size_t lo = 0, hi = cache.length;
        while (lo < hi) {
            immutable size_t mid = (lo + hi) >> 1;
            immutable ulong k = pairKey(cache[mid].mBody1ID, cache[mid].mBody2ID);
            if      (k < target) lo = mid + 1;
            else if (k > target) hi = mid;
            else                 return &cache[mid];
        }
        return null;
    }
}

/// Canonical 64-bit key for a body pair (body1 in high 32 bits).
/// Both (a,b) and (b,a) produce different keys — callers must try both.
private ulong pairKey(BodyID a, BodyID b) pure nothrow @nogc {
    return (cast(ulong) a.GetIndexAndSequenceNumber() << 32)
         | cast(ulong)  b.GetIndexAndSequenceNumber();
}

unittest {
    import engine.jph.math.vec3 : Vec3;
    import engine.jph.physics.constraints.contact_constraint : ContactConstraint;

    ContactConstraint constraint;
    constraint.mBody1ID = BodyID(1, 1);
    constraint.mBody2ID = BodyID(2, 1);
    constraint.mWorldSpaceNormal = Vec3.sAxisY();
    constraint.mNumContactPoints = 1;
    constraint.mPoints[0].mPointOn1 = Vec3(0, 1, 0);
    constraint.mPoints[0].mPointOn2 = Vec3(0, 0, 0);
    constraint.mPoints[0].mNormalPart.mTotalLambda = 1.5f;

    CachedManifold manifold;
    manifold.AssignFromConstraint(constraint);
    assert(manifold.mNumContactPoints == 1);
    assert(manifold.mPoints[0].mNormalLambda == 1.5f);

    ContactConstraintManagerCache cache;
    cache.StoreConstraints([constraint]);
    assert(cache.GetManifolds().length == 1);
    assert(cache.GetManifolds()[0].mPoints[0].mNormalLambda == 1.5f);
}