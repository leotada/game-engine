// Jolt — Physics/Collision/CollideShape.h port (minimal narrowphase surface).
//
// This slice restores the contact manifold data used by the simple rigid-body
// path. The full collector hierarchy and manifold reduction can layer on top.
module engine.jph.physics.collision.collide_shape;

import engine.jph.math.vec3 : Vec3;
import engine.jph.physics.body.bodyid : BodyID;
import engine.jph.physics.shape.sub_shape_id : SubShapeID, SubShapeIDPair;

@safe:

enum uint cMaxContactPoints = 4;

struct CollideShapeSettings {
@safe:
	float mCollisionTolerance = 1.0e-4f;
	float mPenetrationTolerance = 1.0e-4f;
	float mMaxSeparationDistance = 0.0f;
}

struct ContactPoint {
@safe:
	Vec3 mPointOn1 = Vec3.sZero();
	Vec3 mPointOn2 = Vec3.sZero();
	float mPenetrationDepth = 0.0f;

	this(Vec3 inPointOn1, Vec3 inPointOn2, float inPenetrationDepth) pure nothrow @nogc {
		mPointOn1 = inPointOn1;
		mPointOn2 = inPointOn2;
		mPenetrationDepth = inPenetrationDepth;
	}
}

struct ContactManifold {
@safe:
	BodyID mBody1ID;
	BodyID mBody2ID;
	SubShapeID mSubShapeID1;
	SubShapeID mSubShapeID2;
	Vec3 mWorldSpaceNormal = Vec3.sZero();
	ContactPoint[cMaxContactPoints] mContactPoints;
	uint mNumContactPoints = 0;

	void Clear() nothrow @nogc {
		this = ContactManifold.init;
	}

	bool IsEmpty() const pure nothrow @nogc {
		return mNumContactPoints == 0;
	}

	uint GetNumContactPoints() const pure nothrow @nogc {
		return mNumContactPoints;
	}

	ref const(ContactPoint) GetContactPoint(uint inIndex) const return nothrow @nogc {
		assert(inIndex < mNumContactPoints);
		return mContactPoints[inIndex];
	}

	bool AddContactPoint(Vec3 inPointOn1,
						 Vec3 inPointOn2,
						 float inPenetrationDepth) nothrow @nogc {
		if (mNumContactPoints >= cMaxContactPoints)
			return false;

		mContactPoints[mNumContactPoints++] = ContactPoint(
			inPointOn1,
			inPointOn2,
			inPenetrationDepth);
		return true;
	}

	SubShapeIDPair GetSubShapeIDPair() const pure nothrow @nogc {
		return SubShapeIDPair(mBody1ID, mSubShapeID1, mBody2ID, mSubShapeID2);
	}

	ContactManifold Reversed() const nothrow @nogc {
		ContactManifold reversed;
		reversed.mBody1ID = mBody2ID;
		reversed.mBody2ID = mBody1ID;
		reversed.mSubShapeID1 = mSubShapeID2;
		reversed.mSubShapeID2 = mSubShapeID1;
		reversed.mWorldSpaceNormal = -mWorldSpaceNormal;
		reversed.mNumContactPoints = mNumContactPoints;

		foreach (index; 0 .. mNumContactPoints) {
			immutable point = mContactPoints[index];
			reversed.mContactPoints[index] = ContactPoint(
				point.mPointOn2,
				point.mPointOn1,
				point.mPenetrationDepth);
		}

		return reversed;
	}
}

void InitializeContactManifold(ref ContactManifold ioManifold,
							   BodyID inBody1ID,
							   BodyID inBody2ID,
							   Vec3 inWorldSpaceNormal,
							   SubShapeID inSubShapeID1 = SubShapeID.init,
							   SubShapeID inSubShapeID2 = SubShapeID.init) nothrow @nogc {
	ioManifold = ContactManifold.init;
	ioManifold.mBody1ID = inBody1ID;
	ioManifold.mBody2ID = inBody2ID;
	ioManifold.mSubShapeID1 = inSubShapeID1;
	ioManifold.mSubShapeID2 = inSubShapeID2;
	ioManifold.mWorldSpaceNormal = inWorldSpaceNormal;
}

unittest {
	ContactManifold manifold;
	assert(manifold.IsEmpty());
	assert(manifold.AddContactPoint(Vec3(1, 0, 0), Vec3(0, 0, 0), 0.5f));
	assert(!manifold.IsEmpty());
	assert(manifold.GetNumContactPoints() == 1);
	assert(manifold.GetContactPoint(0).mPenetrationDepth == 0.5f);
}

unittest {
	ContactManifold manifold;
	manifold.mBody1ID = BodyID(1, 1);
	manifold.mBody2ID = BodyID(2, 1);
	manifold.mWorldSpaceNormal = Vec3.sAxisY();
	assert(manifold.AddContactPoint(Vec3(1, 2, 3), Vec3(4, 5, 6), 0.25f));

	immutable reversed = manifold.Reversed();
	assert(reversed.mBody1ID == BodyID(2, 1));
	assert(reversed.mBody2ID == BodyID(1, 1));
	assert(reversed.mWorldSpaceNormal == -Vec3.sAxisY());
	assert(reversed.GetContactPoint(0).mPointOn1 == Vec3(4, 5, 6));
	assert(reversed.GetContactPoint(0).mPointOn2 == Vec3(1, 2, 3));
}
