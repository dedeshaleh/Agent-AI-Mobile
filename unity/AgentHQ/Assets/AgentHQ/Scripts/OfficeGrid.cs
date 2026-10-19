using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Logical office grid: a 1:1 port of game/scripts/office_map.gd. The same grid drives
/// rendering, picking and navigation. Tile (x, y) maps to world (x, 0, -y); 1 tile = 1 unit.
/// </summary>
public static class OfficeGrid
{
    public const int Width = 20;
    public const int Height = 16;

    public static readonly string[] RoomNames = { "DATA LAB", "ANALYSIS", "MEETING", "REPORT STUDIO" };

    public static readonly Color[] RoomColors =
    {
        Hex("48a9ff"), Hex("62dfb0"), Hex("f6b95c"), Hex("ee86b9")
    };

    public static readonly RectInt[] Rooms =
    {
        new RectInt(1, 1, 8, 6), new RectInt(11, 1, 8, 6), new RectInt(1, 9, 8, 6), new RectInt(11, 9, 8, 6)
    };

    public static readonly Vector2Int[] Homes =
    {
        new Vector2Int(4, 4), new Vector2Int(14, 4), new Vector2Int(3, 12), new Vector2Int(14, 12)
    };

    public static readonly Vector2Int[] Seats =
    {
        new Vector2Int(3, 11), new Vector2Int(6, 11), new Vector2Int(3, 13), new Vector2Int(6, 13)
    };

    public static readonly Vector2Int[] Furniture =
    {
        new Vector2Int(4, 3), new Vector2Int(5, 3), new Vector2Int(14, 3), new Vector2Int(15, 3),
        new Vector2Int(14, 11), new Vector2Int(15, 11), new Vector2Int(4, 11), new Vector2Int(5, 11),
        new Vector2Int(4, 12), new Vector2Int(5, 12), new Vector2Int(4, 13), new Vector2Int(5, 13)
    };

    public static readonly Vector2Int[] Plants =
    {
        new Vector2Int(1, 6), new Vector2Int(18, 6), new Vector2Int(1, 14), new Vector2Int(18, 14)
    };

    static readonly Vector2Int[] Directions =
    {
        new Vector2Int(1, 0), new Vector2Int(-1, 0), new Vector2Int(0, 1), new Vector2Int(0, -1)
    };

    public static bool InBounds(Vector2Int p) => p.x >= 0 && p.y >= 0 && p.x < Width && p.y < Height;

    public static bool IsFloor(Vector2Int p)
    {
        if (!InBounds(p)) return false;
        // Corridors: two vertical columns and two horizontal rows between the rooms.
        if (p.x == 9 || p.x == 10 || p.y == 7 || p.y == 8) return true;
        return RoomAt(p) >= 0;
    }

    public static int RoomAt(Vector2Int p)
    {
        for (int i = 0; i < Rooms.Length; i++)
        {
            if (Rooms[i].Contains(p)) return i;
        }
        return -1;
    }

    public static bool IsFurniture(Vector2Int p)
    {
        for (int i = 0; i < Furniture.Length; i++)
        {
            if (Furniture[i] == p) return true;
        }
        return false;
    }

    public static bool IsSolid(Vector2Int p) => !IsFloor(p) || IsFurniture(p);

    public static Vector3 WorldPosition(Vector2Int tile) => new Vector3(tile.x, 0f, -tile.y);

    public static Vector2Int TileAt(Vector3 world) =>
        new Vector2Int(Mathf.RoundToInt(world.x), Mathf.RoundToInt(-world.z));

    /// <summary>
    /// 4-neighbour A* with Manhattan heuristic. The result starts with <paramref name="from"/>
    /// and ends with <paramref name="to"/>; it is empty when either tile is out of bounds,
    /// solid, or (for the destination) in <paramref name="extraBlocked"/>, or when no path exists.
    /// </summary>
    public static List<Vector2Int> Route(Vector2Int from, Vector2Int to, HashSet<Vector2Int> extraBlocked = null)
    {
        var result = new List<Vector2Int>();
        if (!InBounds(from) || !InBounds(to)) return result;
        if (IsSolid(from) || IsSolid(to)) return result;
        if (extraBlocked != null && extraBlocked.Contains(to)) return result;

        int count = Width * Height;
        var cost = new int[count];
        var parent = new int[count];
        var closed = new bool[count];
        for (int i = 0; i < count; i++)
        {
            cost[i] = int.MaxValue;
            parent[i] = -1;
        }

        int start = Index(from);
        int goal = Index(to);
        var open = new List<int> { start };
        cost[start] = 0;

        while (open.Count > 0)
        {
            int best = 0;
            int bestF = cost[open[0]] + Manhattan(TileOf(open[0]), to);
            for (int i = 1; i < open.Count; i++)
            {
                int f = cost[open[i]] + Manhattan(TileOf(open[i]), to);
                if (f < bestF)
                {
                    bestF = f;
                    best = i;
                }
            }

            int current = open[best];
            open.RemoveAt(best);
            if (current == goal) break;
            closed[current] = true;

            Vector2Int tile = TileOf(current);
            for (int d = 0; d < Directions.Length; d++)
            {
                Vector2Int next = tile + Directions[d];
                if (!InBounds(next) || IsSolid(next)) continue;
                if (extraBlocked != null && extraBlocked.Contains(next)) continue;
                int ni = Index(next);
                if (closed[ni]) continue;
                int ng = cost[current] + 1;
                if (ng >= cost[ni]) continue;
                cost[ni] = ng;
                parent[ni] = current;
                if (!open.Contains(ni)) open.Add(ni);
            }
        }

        if (goal != start && parent[goal] < 0) return result;
        for (int i = goal; i >= 0; i = parent[i]) result.Add(TileOf(i));
        result.Reverse();
        return result;
    }

    public static Color Hex(string hex) =>
        ColorUtility.TryParseHtmlString("#" + hex, out Color c) ? c : Color.magenta;

    static int Index(Vector2Int p) => p.y * Width + p.x;
    static Vector2Int TileOf(int index) => new Vector2Int(index % Width, index / Width);
    static int Manhattan(Vector2Int a, Vector2Int b) => Mathf.Abs(a.x - b.x) + Mathf.Abs(a.y - b.y);
}
