module component.timeout;

/// Timeout component — POD struct.
struct Timeout
{
    float duration = 1.0;
    float elapsed = 0;
    bool expired = false;

    void reset()
    {
        duration = 1.0;
        elapsed = 0;
        expired = false;
    }
}
