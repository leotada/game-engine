/// Scene graph — parent/child transform hierarchy.
/// A compact, cache-friendly tree: all nodes in a flat array, parents referenced by index.
/// Local transforms → world matrices computed in a single pre-order sweep.
module engine.scene.graph;

import engine.math.vec : Vec3;
import engine.math.mat : Mat4;
import engine.core.pod : Pod;
import engine.core.attrs : noGcStorage;

@safe:

/// Node identifier. 0 is always the invisible root.
alias NodeId = uint;
enum NodeId ROOT = 0;
enum NodeId INVALID_NODE = uint.max;

/// Local transform: translation + uniform Y rotation + non-uniform scale.
/// Components are POD — safe for the ECS and no GC indirections.
@noGcStorage
struct Transform {
    Vec3  position = Vec3(0, 0, 0);
    Vec3  scale    = Vec3(1, 1, 1);
    float rotationY = 0;

    /// Build the 4×4 local-to-parent matrix.
    Mat4 localMatrix() const {
        return Mat4.translation(position.x, position.y, position.z)
             * Mat4.rotationY(rotationY)
             * Mat4.scaling(scale.x, scale.y, scale.z);
    }
}

/// Scene graph node. Parent-indexed; children tracked for traversal order.
/// Nodes must be added in parent-before-child order — this is natural when
/// you build the tree by calling `addChild` from the root downward.
struct SceneGraph {
    Pod!Transform[] local;   // per-node local transform
    Pod!NodeId[]    parent;  // parent index; ROOT's parent is itself
    Pod!Mat4[]      world;   // computed world matrix (updated by `updateWorld`)

    static SceneGraph create() {
        SceneGraph g;
        // Seed the root node (identity transform, self-parent).
        g.local  ~= Transform.init;
        g.parent ~= ROOT;
        g.world  ~= Mat4.identity();
        return g;
    }

    /// Add a new node under `parentId`. Returns the new node id.
    NodeId addChild(NodeId parentId, Transform t = Transform.init) {
        assert(parentId < local.length, "addChild: invalid parent id");
        immutable id = cast(NodeId) local.length;
        local  ~= t;
        parent ~= parentId;
        world  ~= Mat4.identity();
        return id;
    }

    /// Mutate a node's local transform.
    ref Transform transform(NodeId id) return {
        assert(id < local.length, "transform: invalid id");
        return local[id];
    }

    /// Fetch the last-computed world matrix.
    Mat4 worldMatrix(NodeId id) const {
        assert(id < world.length, "worldMatrix: invalid id");
        return world[id];
    }

    /// Compute all world matrices from local transforms.
    /// O(N). Correct as long as parent indices are always less than their child's index,
    /// which is guaranteed by `addChild`.
    void updateWorld() {
        // ROOT is identity.
        world[ROOT] = local[ROOT].localMatrix();
        foreach (i; 1 .. local.length) {
            immutable p = parent[i];
            world[i] = world[p] * local[i].localMatrix();
        }
    }

    /// Total node count (including ROOT).
    size_t length() const { return local.length; }
}
