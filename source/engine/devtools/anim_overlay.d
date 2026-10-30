/// Overlay line for the animation runtime ("sampled characters / ms").
module engine.devtools.anim_overlay;

import engine.devtools.overlay : DebugOverlay;

@safe:

/// Adds an `anim` line: character count, total ms spent in the animation systems this frame,
/// and the microseconds per character.
void animationOverlay(ref DebugOverlay overlay, size_t characters, double frameMs) {
    immutable perChar = characters > 0 ? frameMs * 1000.0 / cast(double) characters : 0.0;
    overlay.label("anim", characters, " chars, ", frameMs, " ms (", perChar, " us/char)");
}
