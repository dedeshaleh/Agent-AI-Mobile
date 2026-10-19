using UnityEngine;

/// <summary>
/// Small grayscale textures generated once at runtime (no imported art). They are all tileable and
/// meant to be tinted through the material's base/emission colour, so one texture serves every
/// room colour. Total generation cost is a few milliseconds.
/// </summary>
public static class ProceduralTextures
{
    const int Size = 256;

    static Texture2D floorTile, wood, brushedMetal, fabric, screen;

    public static Texture2D FloorTile() => floorTile != null ? floorTile : floorTile = Build("HqFloorTile", FloorPixel);
    public static Texture2D Wood() => wood != null ? wood : wood = Build("HqWood", WoodPixel);
    public static Texture2D BrushedMetal() => brushedMetal != null ? brushedMetal : brushedMetal = Build("HqMetal", MetalPixel);
    public static Texture2D Fabric() => fabric != null ? fabric : fabric = Build("HqFabric", FabricPixel);
    public static Texture2D Screen() => screen != null ? screen : screen = Build("HqScreen", ScreenPixel);

    delegate float PixelFunc(int x, int y);

    static Texture2D Build(string name, PixelFunc pixel)
    {
        var texture = new Texture2D(Size, Size, TextureFormat.RGBA32, true)
        {
            name = name,
            filterMode = FilterMode.Bilinear,
            wrapMode = TextureWrapMode.Repeat,
            anisoLevel = 2,
        };
        var pixels = new Color32[Size * Size];
        for (int y = 0; y < Size; y++)
        {
            for (int x = 0; x < Size; x++)
            {
                byte v = (byte)Mathf.RoundToInt(Mathf.Clamp01(pixel(x, y)) * 255f);
                pixels[y * Size + x] = new Color32(v, v, v, 255);
            }
        }
        texture.SetPixels32(pixels);
        texture.Apply(true, true);
        return texture;
    }

    // Two tiles per texture repeat (so one floor unit shows 2x2 tiles), per-tile shade variation,
    // thin grout lines and faint noise.
    static float FloorPixel(int x, int y)
    {
        const int tiles = 2;
        int tileSize = Size / tiles;
        int tx = x / tileSize, ty = y / tileSize;
        float shade = 0.82f + Hash(tx * 7 + 3, ty * 13 + 5, 11) * 0.18f;
        shade += (Fbm(x / 24f, y / 24f, Size / 24, 3, 21) - 0.5f) * 0.12f;
        int lx = x % tileSize, ly = y % tileSize;
        int grout = 3;
        if (lx < grout || ly < grout || lx >= tileSize - grout || ly >= tileSize - grout) shade *= 0.55f;
        else if (lx < grout + 2 || ly < grout + 2) shade *= 0.92f; // soft bevel on two edges
        return shade;
    }

    // Wavy grain stripes along x plus fine noise.
    static float WoodPixel(int x, int y)
    {
        float wobble = Fbm(x / 64f, y / 10f, Size / 64, 3, 31) * 6f;
        float ring = Mathf.Sin((y + wobble * 4f) * 0.35f);
        float grain = 0.72f + ring * 0.12f;
        grain += (Fbm(x / 3f, y / 20f, Size / 3, 2, 32) - 0.5f) * 0.14f;
        return grain;
    }

    // Fine horizontal streaks: high frequency across y, low across x.
    static float MetalPixel(int x, int y)
    {
        float streak = Fbm(x / 40f, y / 1.5f, Size / 40, 2, 41);
        float value = 0.78f + (streak - 0.5f) * 0.34f;
        value += (Hash(x, y, 42) - 0.5f) * 0.05f;
        return value;
    }

    // Carpet: medium noise plus a subtle weave checker.
    static float FabricPixel(int x, int y)
    {
        float value = 0.7f + (Fbm(x / 6f, y / 6f, Size / 6, 3, 51) - 0.5f) * 0.3f;
        bool weave = ((x / 3) & 1) == ((y / 3) & 1);
        value += weave ? 0.04f : -0.04f;
        return value;
    }

    // Dark panel with a chart of lit bars in the lower half and three "text" lines above.
    // White parts glow in the material's emission colour.
    static float ScreenPixel(int x, int y)
    {
        const int margin = 20;
        if (x < margin || x >= Size - margin || y < margin || y >= Size - margin) return 0.04f;
        float value = 0.1f + (Hash(x / 4, y / 4, 61) - 0.5f) * 0.03f;

        // Chart area: y from margin to 140, six bars of hashed heights.
        int chartTop = 140;
        if (y < chartTop)
        {
            int barWidth = (Size - 2 * margin) / 6;
            int bar = (x - margin) / barWidth;
            int inBar = (x - margin) % barWidth;
            int height = 30 + (int)(Hash(bar, 9, 62) * 80f);
            if (inBar > 6 && inBar < barWidth - 6 && y - margin < height) value = 0.85f;
            else if ((y - margin) % 28 == 0) value = 0.22f; // grid line
            return value;
        }

        // Text lines: three rows of dashes with hashed lengths.
        int lineHeight = 22;
        int row = (y - chartTop - 10) / lineHeight;
        int inRow = (y - chartTop - 10) % lineHeight;
        if (row >= 0 && row < 3 && inRow >= 6 && inRow < 14)
        {
            int length = 60 + (int)(Hash(row, 3, 63) * 140f);
            int seg = (x - margin) / 14;
            bool gap = (x - margin) % 14 >= 11;
            if (x - margin < length && !gap && Hash(seg, row, 64) > 0.15f) value = row == 0 ? 0.9f : 0.5f;
        }
        return value;
    }

    static float Hash(int x, int y, int seed)
    {
        unchecked
        {
            uint h = (uint)(x * 374761393) + (uint)(y * 668265263) + (uint)(seed * 1274126177);
            h = (h ^ (h >> 13)) * 1274126177u;
            h ^= h >> 16;
            return (h & 0xFFFF) / 65535f;
        }
    }

    // Tileable value noise: lattice coordinates wrap at 'period'.
    static float ValueNoise(float x, float y, int period, int seed)
    {
        if (period < 1) period = 1;
        int xi = Mathf.FloorToInt(x), yi = Mathf.FloorToInt(y);
        float fx = x - xi, fy = y - yi;
        fx = fx * fx * (3f - 2f * fx);
        fy = fy * fy * (3f - 2f * fy);
        int x0 = Mod(xi, period), x1 = Mod(xi + 1, period);
        int y0 = Mod(yi, period), y1 = Mod(yi + 1, period);
        float a = Hash(x0, y0, seed), b = Hash(x1, y0, seed);
        float c = Hash(x0, y1, seed), d = Hash(x1, y1, seed);
        return Mathf.Lerp(Mathf.Lerp(a, b, fx), Mathf.Lerp(c, d, fx), fy);
    }

    static float Fbm(float x, float y, int period, int octaves, int seed)
    {
        float sum = 0f, amplitude = 0.5f, total = 0f;
        for (int i = 0; i < octaves; i++)
        {
            sum += ValueNoise(x, y, period, seed + i) * amplitude;
            total += amplitude;
            x *= 2f;
            y *= 2f;
            period *= 2;
            amplitude *= 0.5f;
        }
        return sum / total;
    }

    static int Mod(int a, int m)
    {
        int r = a % m;
        return r < 0 ? r + m : r;
    }
}
