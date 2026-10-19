// Used by mark_race_glue.d with -version=GlueUnmarked, and compiled WITHOUT
// -preview=gcbarrier: the stores that create these values are the ones the code
// generator makes by itself (the elements of the literal, the fields of the new
// struct, the closure frame), and here they get no barrier. The assignment that
// stores the result into the holder is in mark_race_glue.d, with the barrier.
//
// If the test fails with this module and passes without it, those stores matter:
// a barrier that only rewrites assignment expressions in the frontend would not
// be enough.
module mark_race_glue_ext;

struct Node
{
    ulong id;
    Node* a;
    Node* b;
    ulong check;
    ubyte[40] pad;
}

struct Pair
{
    Node* x;
    Node* y;
}

// 16 elements: a literal that is a whole size class of its own, not a few bytes
// sharing a 512-byte card with other objects that were marked for other reasons.
Node*[] mk0(Node* n, Node* o) { return [n, o, o, o, o, o, o, o, o, o, o, o, o, o, o, o]; }
Pair* mk1(Node* n, Node* o) { return new Pair(n, o); }
Node* delegate() mk3(Node* n) { return () => n; }
