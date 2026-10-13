/// User-Defined Attributes (UDAs) for components, fields, and systems.
module engine.reflect.attrs;

@safe:

/// Marks a struct as an ECS component.
struct component {}

/// Exposes a field to the editor Inspector and serialization.
struct export_ {}
alias exported = export_;

/// Explicitly hides a field from the editor Inspector (still serialized).
struct hide {}

/// Restricts a numeric field to a range [min, max] (slider in Inspector).
struct range {
    float min = 0;
    float max = 1;
}

/// Tooltip documentation displayed when hovering over the field in the Inspector.
struct tooltip {
    string text;
}

/// Adds a section header above this field in the Inspector.
struct header {
    string text;
}

/// Hints that this field was formerly named `oldName`, enabling automatic schema migration.
struct formerlyNamed {
    string oldName;
}

/// Indicates that a component script or system executes inside the editor even when Play Mode is stopped.
struct runInEditor {}

/// System execution stages.
enum Stage : uint {
    preUpdate   = 0,
    fixedUpdate = 1,
    update      = 2,
    lateUpdate  = 3,
}

/// Marks a free function as an ECS system with a specific stage and execution order.
struct system {
    Stage stage = Stage.update;
    int order = 0;
}
