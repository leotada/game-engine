/// Editor selection state — single + multi-select (ED-8).
module engine.editor.selection;

import engine.ecs.store : EntityId;

@safe:

/// Sentinel: nothing selected.
enum EntityId noSelection = EntityId.max;

/// Multi-entity selection with a designated primary (inspector / gizmo pivot).
struct Selection {
    enum capacity = 64;

    EntityId primary = noSelection;
    EntityId[capacity] ids;
    int count = 0;

    bool empty() const nothrow @nogc {
        return count == 0 || primary == noSelection;
    }

    void clear() nothrow @nogc {
        primary = noSelection;
        count = 0;
    }

    /// Replace selection with a single entity.
    void select(EntityId id) nothrow @nogc {
        if (id == noSelection) {
            clear();
            return;
        }
        primary = id;
        ids[0] = id;
        count = 1;
    }

    /// Add `id` if not already selected (no-op at capacity).
    void add(EntityId id) nothrow @nogc {
        if (id == noSelection) return;
        if (isSelected(id)) {
            primary = id;
            return;
        }
        if (count >= capacity) return;
        ids[count++] = id;
        primary = id;
    }

    /// Toggle membership (Shift+click). Clearing the last item clears selection.
    void toggle(EntityId id) nothrow @nogc {
        if (id == noSelection) return;
        immutable idx = indexOf(id);
        if (idx >= 0) {
            removeAt(idx);
            if (count == 0)
                primary = noSelection;
            else if (primary == id)
                primary = ids[0];
            return;
        }
        add(id);
    }

    bool isSelected(EntityId id) const nothrow @nogc {
        return indexOf(id) >= 0;
    }

    /// Drop dead entities; repair primary.
    void validateWorld(W)(ref W world) nothrow @nogc {
        int dst = 0;
        foreach (i; 0 .. count) {
            immutable id = ids[i];
            if (world.alive(id))
                ids[dst++] = id;
        }
        count = dst;
        if (count == 0) {
            primary = noSelection;
            return;
        }
        if (primary == noSelection || !world.alive(primary) || !isSelected(primary))
            primary = ids[0];
    }

    private int indexOf(EntityId id) const nothrow @nogc {
        foreach (i; 0 .. count)
            if (ids[i] == id) return i;
        return -1;
    }

    private void removeAt(int idx) nothrow @nogc {
        if (idx < 0 || idx >= count) return;
        foreach (i; idx + 1 .. count)
            ids[i - 1] = ids[i];
        count--;
    }
}

@safe unittest {
    Selection s;
    assert(s.empty);
    s.select(3);
    assert(s.isSelected(3));
    assert(s.count == 1);
    s.add(5);
    assert(s.count == 2);
    assert(s.isSelected(5));
    assert(s.primary == 5);
    s.toggle(3);
    assert(!s.isSelected(3));
    assert(s.count == 1);
    s.clear();
    assert(s.empty);
}
