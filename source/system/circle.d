module system.circle;

import component.circle;
import component.position;
import raylib;

/// Circle rendering system — template function, zero virtual dispatch.
/// Renders circles using a cached hardware texture for batch performance.
struct CircleRenderer
{
    private RenderTexture2D circleTexture;
    private bool initialized = false;
    private enum TEXTURE_SIZE = 64;
    private enum CIRCLE_RADIUS = 30;

    /// Initialize the circle texture (called once)
    private void initTexture()
    {
        if (initialized)
            return;

        circleTexture = LoadRenderTexture(TEXTURE_SIZE, TEXTURE_SIZE);
        BeginTextureMode(circleTexture);
        ClearBackground(Color(0, 0, 0, 0));
        DrawCircle(TEXTURE_SIZE / 2, TEXTURE_SIZE / 2, CIRCLE_RADIUS, Colors.WHITE);
        EndTextureMode();

        initialized = true;
    }

    /// Check if circle is within screen bounds
    private static bool isOnScreen(Position pos, float radius)
    {
        int screenWidth = GetScreenWidth();
        int screenHeight = GetScreenHeight();

        return !(pos.x + radius < 0 ||
                pos.x - radius > screenWidth ||
                pos.y + radius < 0 ||
                pos.y - radius > screenHeight);
    }

    /// Draw a single circle at the given position
    private void draw(Position pos, ref Circle circle)
    {
        if (!initialized)
            initTexture();

        float size = circle.radius * 2;

        DrawTexturePro(
            circleTexture.texture,
            Rectangle(0, 0, TEXTURE_SIZE, -TEXTURE_SIZE),
            Rectangle(
                pos.x - circle.radius,
                pos.y - circle.radius,
                size,
                size
        ),
        Vector2(0, 0),
        0,
        circle.color
        );
    }

    /// Run the circle rendering system — template function
    void run(Registry)(ref Registry reg, double frameTime)
    {
        if (!initialized)
            initTexture();

        foreach (entityId; reg.entitiesWith!(Circle, Position))
        {
            auto circle = reg.store!Circle.getPointer(entityId);
            auto pos = reg.store!Position.getPointer(entityId);

            if (circle is null || pos is null)
                continue;

            if (!isOnScreen(*pos, circle.radius))
                continue;

            draw(*pos, *circle);
        }
    }
}
