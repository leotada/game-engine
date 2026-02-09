module component.timeout;

import component;

class Timeout : Component
{
    float duration = 1.0;
    float elapsed = 0;
    bool expired = false;

    this()
    {
        // Default constructor for pooling
    }

    this(float duration)
    {
        this.duration = duration;
    }

    override void reset()
    {
        super.reset();
        duration = 1.0;
        elapsed = 0;
        expired = false;
    }
}
