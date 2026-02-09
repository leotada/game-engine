module system.graphic.circle;

import system.graphic;

import component.graphic.circle;
import entity.manager;
import entity;
import math.vector;

import raylib;

class CircleSystem : IGraphic
{
    private RenderTexture2D circleTexture;
    private bool initialized = false;
    private enum TEXTURE_SIZE = 64;
    private enum CIRCLE_RADIUS = 30;

    // Initialize the circle texture (called once)
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

    // Check if circle is within screen bounds (with padding for radius)
    bool isOnScreen(Vector pos, float radius)
    {
        int screenWidth = GetScreenWidth();
        int screenHeight = GetScreenHeight();

        if (pos.x + radius < 0)
            return false;
        if (pos.x - radius > screenWidth)
            return false;
        if (pos.y + radius < 0)
            return false;
        if (pos.y - radius > screenHeight)
            return false;

        return true;
    }

    void draw(Vector basePosition, ref Circle circle)
    {
        if (!initialized)
            initTexture();

        float size = circle.radius * 2;

        DrawTexturePro(
            circleTexture.texture,
            Rectangle(0, 0, TEXTURE_SIZE, -TEXTURE_SIZE),
            Rectangle(
                basePosition.x - circle.radius,
                basePosition.y - circle.radius,
                size,
                size
        ),
        Vector2(0, 0),
        0,
        circle.color
        );
    }

    void run(ref EntityManager entityManager, double frameTime)
    {
        foreach (ref Entity entity; entityManager.getByComponent!Circle())
        {
            if (entity is null || !entity.active)
                continue;

            Circle circle = entity.getComponent!Circle();
            if (circle is null)
                continue;

            if (!isOnScreen(entity.position, circle.radius))
                continue;

            draw(entity.position, circle);
        }
    }
}
