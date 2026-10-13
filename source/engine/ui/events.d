/// Retained-mode UI events and event queue.
module engine.ui.events;

import engine.core.pod : isPod;
import engine.ui.tree : UiNodeId;

@safe:

enum UiEventKind : ubyte {
    none = 0,
    click,
    mouseDown,
    mouseUp,
    mouseEnter,
    mouseLeave,
    textChange,
    submit,
    scroll,
    dragStart,
    drag,
    drop,
    contextMenu,
}

enum MAX_EVENT_TEXT = 64;

/// POD UI event emitted by the UI input system.
struct UiEvent {
    UiNodeId node;
    UiEventKind kind = UiEventKind.none;
    float mouseX = 0;
    float mouseY = 0;
    float wheelX = 0;
    float wheelY = 0;
    char[MAX_EVENT_TEXT] text;
    uint textLen = 0;

    bool isClick(UiNodeId target) const nothrow @nogc pure {
        return kind == UiEventKind.click && node == target;
    }

    bool isSubmit(UiNodeId target) const nothrow @nogc pure {
        return kind == UiEventKind.submit && node == target;
    }

    bool isChange(UiNodeId target) const nothrow @nogc pure {
        return kind == UiEventKind.textChange && node == target;
    }
}

static assert(isPod!UiEvent);

/// Fixed-capacity POD event queue for frame processing.
struct UiEventQueue {
    private enum MAX_EVENTS = 256;
    private UiEvent[MAX_EVENTS] events;
    private uint count = 0;

    void clear() nothrow @nogc {
        count = 0;
    }

    bool push(in UiEvent ev) nothrow @nogc {
        if (count >= MAX_EVENTS) return false;
        events[count++] = ev;
        return true;
    }

    const(UiEvent)[] items() return const nothrow @nogc pure {
        return events[0 .. count];
    }

    size_t length() const nothrow @nogc pure {
        return count;
    }

    ref const(UiEvent) opIndex(size_t i) return const nothrow @nogc pure {
        assert(i < count);
        return events[i];
    }
}

static assert(isPod!UiEventQueue);
