using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Procedurally builds the office from primitives on Awake: one textured floor slab per room and
/// per corridor rectangle, low walls (merged into straight runs, with a lighter cap and a
/// baseboard) on every floor edge that borders a non-floor tile, desks with lit monitors, the
/// meeting table with a glass top and four seats, plants, a few props and floating room labels.
/// Geometry stays 1:1 with OfficeGrid; only the visuals changed from the primitive version.
/// </summary>
public class OfficeBuilder : MonoBehaviour
{
    static readonly Color FloorBase = OfficeGrid.Hex("1b2b3b");
    static readonly Color CorridorWall = OfficeGrid.Hex("2a3b4d");
    static readonly Color DeskColor = OfficeGrid.Hex("597289");
    static readonly Color TableColor = OfficeGrid.Hex("846644");
    static readonly Color ScreenColor = OfficeGrid.Hex("0a1725");
    static readonly Color SeatColor = OfficeGrid.Hex("a38658");
    static readonly Color HomeColor = OfficeGrid.Hex("42576a");
    static readonly Color PotColor = OfficeGrid.Hex("b5674a");
    static readonly Color SoilColor = OfficeGrid.Hex("2d2219");
    static readonly Color LeafColor = OfficeGrid.Hex("57a581");
    static readonly Color MetalColor = OfficeGrid.Hex("9aa7b5");
    static readonly Color DarkMetal = OfficeGrid.Hex("3b4652");
    static readonly Color GlassTint = OfficeGrid.Hex("bfe6ff");
    static readonly Color WhiteboardColor = OfficeGrid.Hex("e9eef3");
    static readonly Color MugColor = OfficeGrid.Hex("f2f6fa");

    static readonly Vector2Int[] Neighbours =
    {
        new Vector2Int(1, 0), new Vector2Int(-1, 0), new Vector2Int(0, 1), new Vector2Int(0, -1)
    };

    // Monitors and seated robots face the camera, which looks along world (+x, +z); an object's
    // local +z therefore points towards the camera after this rotation.
    public static readonly Quaternion FaceCamera = Quaternion.Euler(0f, 225f, 0f);

    void Awake()
    {
        BuildFloors();
        BuildWalls();
        BuildFurniture();
        BuildMarkers();
        BuildPlants();
        BuildProps();
        BuildLabels();
    }

    // ---- Floors -------------------------------------------------------------------------------

    void BuildFloors()
    {
        var root = new GameObject("Floor").transform;
        root.SetParent(transform, false);

        for (int i = 0; i < OfficeGrid.Rooms.Length; i++)
        {
            RectInt r = OfficeGrid.Rooms[i];
            Color tint = Visuals.Darken(OfficeGrid.RoomColors[i], 0.7f);
            bool carpet = i == 2; // meeting room
            FloorSlab(root, $"Floor {OfficeGrid.RoomNames[i]}", r.xMin, r.yMin, r.xMax - 1, r.yMax - 1, tint,
                carpet ? SurfaceKind.Fabric : SurfaceKind.Matte, carpet ? null : ProceduralTextures.FloorTile());
        }

        // Corridor tiles merged greedily into rectangles (extend right, then down while the span stays corridor).
        var visited = new HashSet<Vector2Int>();
        int count = 0;
        for (int y = 0; y < OfficeGrid.Height; y++)
        {
            for (int x = 0; x < OfficeGrid.Width; x++)
            {
                var p = new Vector2Int(x, y);
                if (!IsCorridor(p) || visited.Contains(p)) continue;
                int x1 = x;
                while (x1 + 1 < OfficeGrid.Width && IsCorridor(new Vector2Int(x1 + 1, y)) && !visited.Contains(new Vector2Int(x1 + 1, y))) x1++;
                int y1 = y;
                while (y1 + 1 < OfficeGrid.Height && SpanIsCorridor(x, x1, y1 + 1, visited)) y1++;
                for (int yy = y; yy <= y1; yy++)
                    for (int xx = x; xx <= x1; xx++) visited.Add(new Vector2Int(xx, yy));
                FloorSlab(root, $"Corridor {count++}", x, y, x1, y1, Visuals.Darken(FloorBase, 0.1f), SurfaceKind.Matte,
                    ProceduralTextures.FloorTile());
            }
        }
    }

    static bool IsCorridor(Vector2Int p) => OfficeGrid.IsFloor(p) && OfficeGrid.RoomAt(p) < 0;

    static bool SpanIsCorridor(int x0, int x1, int y, HashSet<Vector2Int> visited)
    {
        for (int x = x0; x <= x1; x++)
        {
            var p = new Vector2Int(x, y);
            if (!IsCorridor(p) || visited.Contains(p)) return false;
        }
        return true;
    }

    static void FloorSlab(Transform root, string name, int x0, int y0, int x1, int y1, Color tint, SurfaceKind kind, Texture2D texture)
    {
        int w = x1 - x0 + 1, h = y1 - y0 + 1;
        Vector3 centre = (OfficeGrid.WorldPosition(new Vector2Int(x0, y0)) + OfficeGrid.WorldPosition(new Vector2Int(x1, y1))) * 0.5f;
        Visuals.Primitive(PrimitiveType.Cube, root, name, centre + new Vector3(0f, -0.05f, 0f), new Vector3(w, 0.1f, h), tint,
            kind, true, texture, new Vector2(w, h));
    }

    // ---- Walls --------------------------------------------------------------------------------

    static bool WallNeeded(Vector2Int p, Vector2Int d) => OfficeGrid.IsFloor(p) && !OfficeGrid.IsFloor(p + d);

    void BuildWalls()
    {
        var root = new GameObject("Walls").transform;
        root.SetParent(transform, false);
        var visited = new HashSet<Vector2Int>();

        foreach (Vector2Int d in Neighbours)
        {
            visited.Clear();
            Vector2Int step = d.x != 0 ? new Vector2Int(0, 1) : new Vector2Int(1, 0);
            for (int y = 0; y < OfficeGrid.Height; y++)
            {
                for (int x = 0; x < OfficeGrid.Width; x++)
                {
                    var p = new Vector2Int(x, y);
                    if (visited.Contains(p) || !WallNeeded(p, d)) continue;
                    int room = OfficeGrid.RoomAt(p);
                    int length = 1;
                    visited.Add(p);
                    while (true)
                    {
                        Vector2Int q = p + step * length;
                        if (!WallNeeded(q, d) || OfficeGrid.RoomAt(q) != room || visited.Contains(q)) break;
                        visited.Add(q);
                        length++;
                    }
                    Color wallColor = room < 0 ? CorridorWall : Visuals.Darken(OfficeGrid.RoomColors[room], 0.45f);
                    WallRun(root, p, p + step * (length - 1), d, length, wallColor);
                }
            }
        }
    }

    static void WallRun(Transform root, Vector2Int from, Vector2Int to, Vector2Int d, int length, Color color)
    {
        Vector3 centre = (OfficeGrid.WorldPosition(from) + OfficeGrid.WorldPosition(to)) * 0.5f
                         + new Vector3(d.x * 0.5f, 0f, -d.y * 0.5f);
        bool alongZ = d.x != 0;
        Vector3 Scale(float thickness, float height, float extra) =>
            alongZ ? new Vector3(thickness, height, length + extra) : new Vector3(length + extra, height, thickness);
        string suffix = $"{from.x},{from.y}";
        Visuals.Primitive(PrimitiveType.Cube, root, "Wall " + suffix, centre + new Vector3(0f, 0.25f, 0f), Scale(0.1f, 0.5f, 0f),
            color, SurfaceKind.Matte, false);
        Visuals.Primitive(PrimitiveType.Cube, root, "WallCap " + suffix, centre + new Vector3(0f, 0.515f, 0f), Scale(0.14f, 0.03f, 0.04f),
            Visuals.Lighten(color, 0.28f), SurfaceKind.Glossy, false);
        Visuals.Primitive(PrimitiveType.Cube, root, "Baseboard " + suffix, centre + new Vector3(0f, 0.03f, 0f), Scale(0.14f, 0.06f, 0.04f),
            Visuals.Darken(color, 0.35f), SurfaceKind.Matte, false);
    }

    // ---- Furniture ----------------------------------------------------------------------------

    void BuildFurniture()
    {
        var root = new GameObject("Furniture").transform;
        root.SetParent(transform, false);

        // One table covers every furniture tile inside the meeting room.
        var min = new Vector2Int(int.MaxValue, int.MaxValue);
        var max = new Vector2Int(int.MinValue, int.MinValue);
        int deskIndex = 0;
        foreach (Vector2Int p in OfficeGrid.Furniture)
        {
            int room = OfficeGrid.RoomAt(p);
            if (room == 2)
            {
                min = Vector2Int.Min(min, p);
                max = Vector2Int.Max(max, p);
                continue;
            }
            Color accent = room >= 0 ? OfficeGrid.RoomColors[room] : SeatColor;
            BuildDesk(root, p, accent, (deskIndex++ & 1) == 1);
        }

        if (min.x <= max.x)
        {
            Vector3 a = OfficeGrid.WorldPosition(min);
            Vector3 b = OfficeGrid.WorldPosition(max);
            Vector3 centre = (a + b) * 0.5f;
            var size = new Vector3(max.x - min.x + 0.9f, 0.1f, max.y - min.y + 0.9f);
            var table = new GameObject("MeetingTable").transform;
            table.SetParent(root, false);
            table.localPosition = centre;
            Visuals.Primitive(PrimitiveType.Cube, table, "Top", new Vector3(0f, 0.55f, 0f), size, TableColor, SurfaceKind.Wood);
            Visuals.Primitive(PrimitiveType.Cube, table, "Rim", new Vector3(0f, 0.49f, 0f),
                new Vector3(size.x - 0.2f, 0.04f, size.z - 0.2f), Visuals.Darken(TableColor, 0.3f), SurfaceKind.Wood, false);
            Visuals.Primitive(PrimitiveType.Cylinder, table, "GlassTop", new Vector3(0f, 0.612f, 0f),
                new Vector3(size.x * 0.88f, 0.008f, size.z * 0.88f), GlassTint, SurfaceKind.Glass, false);
            float lx = size.x * 0.5f - 0.18f, lz = size.z * 0.5f - 0.18f;
            for (int i = 0; i < 4; i++)
            {
                var offset = new Vector3(i % 2 == 0 ? -lx : lx, 0.25f, i < 2 ? -lz : lz);
                Visuals.Primitive(PrimitiveType.Cylinder, table, "Leg", offset, new Vector3(0.09f, 0.25f, 0.09f), DarkMetal,
                    SurfaceKind.Metal, false);
            }
        }
    }

    void BuildDesk(Transform root, Vector2Int p, Color accent, bool withMug)
    {
        Vector3 centre = OfficeGrid.WorldPosition(p);
        var desk = new GameObject($"Desk {p.x},{p.y}").transform;
        desk.SetParent(root, false);
        desk.localPosition = centre;

        Visuals.Primitive(PrimitiveType.Cube, desk, "Body", new Vector3(0f, 0.2f, 0f), new Vector3(0.9f, 0.4f, 0.78f), DeskColor,
            SurfaceKind.Wood);
        Visuals.Primitive(PrimitiveType.Cube, desk, "Top", new Vector3(0f, 0.42f, 0f), new Vector3(0.96f, 0.04f, 0.84f),
            Visuals.Darken(DeskColor, 0.3f), SurfaceKind.Wood, false);
        // Drawer line: a thin dark groove on the camera-facing sides.
        Visuals.Primitive(PrimitiveType.Cube, desk, "Groove", new Vector3(0f, 0.3f, 0f), new Vector3(0.91f, 0.015f, 0.79f),
            Visuals.Darken(DeskColor, 0.55f), SurfaceKind.Matte, false);

        // Monitor: dark frame, emissive screen quad on the camera-facing side, metal stand.
        var monitor = Visuals.Primitive(PrimitiveType.Cube, desk, "Monitor", new Vector3(0f, 0.7f, 0f),
            new Vector3(0.5f, 0.32f, 0.04f), ScreenColor, SurfaceKind.Glossy, false);
        monitor.transform.rotation = FaceCamera;
        // A Quad's visible face points down its local -z; turn it so it faces the monitor's +z (the camera).
        var screen = Visuals.Primitive(PrimitiveType.Quad, monitor.transform, "Screen", new Vector3(0f, 0f, 0.51f),
            new Vector3(0.92f, 0.88f, 1f), accent, SurfaceKind.Emissive, false, ProceduralTextures.Screen());
        screen.transform.localRotation = Quaternion.Euler(0f, 180f, 0f);
        Visuals.Primitive(PrimitiveType.Cylinder, desk, "StandNeck", new Vector3(0f, 0.49f, 0f), new Vector3(0.04f, 0.06f, 0.04f),
            MetalColor, SurfaceKind.Metal, false);
        Visuals.Primitive(PrimitiveType.Cylinder, desk, "StandBase", new Vector3(0f, 0.447f, 0f), new Vector3(0.22f, 0.008f, 0.22f),
            MetalColor, SurfaceKind.Metal, false);

        if (withMug)
        {
            var mug = Visuals.Primitive(PrimitiveType.Cylinder, desk, "Mug", new Vector3(0.32f, 0.485f, 0.22f),
                new Vector3(0.09f, 0.045f, 0.09f), MugColor, SurfaceKind.Glossy, false);
            Visuals.Primitive(PrimitiveType.Cylinder, mug.transform, "Coffee", new Vector3(0f, 0.9f, 0f),
                new Vector3(0.8f, 0.12f, 0.8f), OfficeGrid.Hex("3b2415"), SurfaceKind.Glossy, false);
        }
    }

    // ---- Seats and home markers ---------------------------------------------------------------

    void BuildMarkers()
    {
        var root = new GameObject("Markers").transform;
        root.SetParent(transform, false);
        foreach (Vector2Int seat in OfficeGrid.Seats)
        {
            Vector3 centre = OfficeGrid.WorldPosition(seat);
            Visuals.Primitive(PrimitiveType.Cylinder, root, $"SeatBase {seat.x},{seat.y}", centre + new Vector3(0f, 0.015f, 0f),
                new Vector3(0.5f, 0.015f, 0.5f), DarkMetal, SurfaceKind.Metal, false);
            Visuals.Primitive(PrimitiveType.Cylinder, root, $"Seat {seat.x},{seat.y}", centre + new Vector3(0f, 0.08f, 0f),
                new Vector3(0.64f, 0.05f, 0.64f), SeatColor, SurfaceKind.Fabric, false);
        }
        foreach (Vector2Int home in OfficeGrid.Homes)
        {
            if (System.Array.IndexOf(OfficeGrid.Seats, home) >= 0) continue;
            Visuals.Primitive(PrimitiveType.Cylinder, root, $"Home {home.x},{home.y}",
                OfficeGrid.WorldPosition(home) + new Vector3(0f, 0.012f, 0f), new Vector3(0.6f, 0.012f, 0.6f), HomeColor,
                SurfaceKind.Glossy, false);
        }
    }

    // ---- Plants -------------------------------------------------------------------------------

    void BuildPlants()
    {
        var root = new GameObject("Plants").transform;
        root.SetParent(transform, false);
        int i = 0;
        foreach (Vector2Int p in OfficeGrid.Plants)
        {
            Vector3 centre = OfficeGrid.WorldPosition(p);
            Visuals.Primitive(PrimitiveType.Cylinder, root, "Pot", centre + new Vector3(0f, 0.15f, 0f),
                new Vector3(0.46f, 0.15f, 0.46f), PotColor, SurfaceKind.Matte);
            Visuals.Primitive(PrimitiveType.Cylinder, root, "Soil", centre + new Vector3(0f, 0.3f, 0f),
                new Vector3(0.4f, 0.01f, 0.4f), SoilColor, SurfaceKind.Matte, false);
            // Three overlapping canopies with slight colour variation; mirror every other plant.
            float m = (i++ & 1) == 0 ? 1f : -1f;
            Visuals.Primitive(PrimitiveType.Sphere, root, "Leaves", centre + new Vector3(0f, 0.56f, 0f),
                new Vector3(0.52f, 0.5f, 0.52f), LeafColor, SurfaceKind.Matte, false);
            Visuals.Primitive(PrimitiveType.Sphere, root, "Leaves", centre + new Vector3(0.16f * m, 0.7f, 0.08f),
                new Vector3(0.38f, 0.36f, 0.38f), Visuals.Lighten(LeafColor, 0.18f), SurfaceKind.Matte, false);
            Visuals.Primitive(PrimitiveType.Sphere, root, "Leaves", centre + new Vector3(-0.14f * m, 0.66f, -0.12f),
                new Vector3(0.36f, 0.34f, 0.36f), Visuals.Darken(LeafColor, 0.18f), SurfaceKind.Matte, false);
        }
    }

    // ---- Props: whiteboard (meeting room), server rack (Data room) ----------------------------

    void BuildProps()
    {
        var root = new GameObject("Props").transform;
        root.SetParent(transform, false);
        BuildWhiteboard(root);
        BuildServerRack(root);
    }

    // Free-standing whiteboard in the far corner of the meeting room, turned towards the camera
    // (the room's inner wall faces point away from it).
    void BuildWhiteboard(Transform root)
    {
        RectInt room = OfficeGrid.Rooms[2];
        var tile = new Vector2Int(room.xMax - 1, room.yMax - 1);
        var board = new GameObject("Whiteboard").transform;
        board.SetParent(root, false);
        board.position = OfficeGrid.WorldPosition(tile) + new Vector3(0.1f, 0f, 0.1f);
        board.rotation = FaceCamera;

        Visuals.Primitive(PrimitiveType.Cube, board, "Frame", new Vector3(0f, 0.95f, 0f), new Vector3(0.96f, 0.66f, 0.05f),
            DarkMetal, SurfaceKind.Metal, false);
        Visuals.Primitive(PrimitiveType.Cube, board, "Board", new Vector3(0f, 0.95f, 0.02f), new Vector3(0.88f, 0.58f, 0.03f),
            WhiteboardColor, SurfaceKind.Glossy, false);
        Color[] bars = { OfficeGrid.RoomColors[0], OfficeGrid.RoomColors[1], OfficeGrid.RoomColors[3] };
        float[] heights = { 0.28f, 0.42f, 0.18f };
        for (int i = 0; i < 3; i++)
        {
            Visuals.Primitive(PrimitiveType.Cube, board, "Bar", new Vector3(-0.22f + i * 0.22f, 0.72f + heights[i] * 0.5f, 0.04f),
                new Vector3(0.12f, heights[i], 0.012f), bars[i], SurfaceKind.Matte, false);
        }
        Visuals.Primitive(PrimitiveType.Cylinder, board, "PostL", new Vector3(-0.4f, 0.31f, 0f), new Vector3(0.04f, 0.31f, 0.04f),
            DarkMetal, SurfaceKind.Metal, false);
        Visuals.Primitive(PrimitiveType.Cylinder, board, "PostR", new Vector3(0.4f, 0.31f, 0f), new Vector3(0.04f, 0.31f, 0.04f),
            DarkMetal, SurfaceKind.Metal, false);
    }

    // Server rack in the far corner of the Data room with blinking LEDs.
    void BuildServerRack(Transform root)
    {
        RectInt room = OfficeGrid.Rooms[0];
        var tile = new Vector2Int(room.xMax - 1, room.yMin);
        var rack = new GameObject("ServerRack").transform;
        rack.SetParent(root, false);
        rack.position = OfficeGrid.WorldPosition(tile);
        rack.rotation = FaceCamera;

        Color body = OfficeGrid.Hex("1f2a36");
        Visuals.Primitive(PrimitiveType.Cube, rack, "Cabinet", new Vector3(0f, 0.6f, 0f), new Vector3(0.62f, 1.2f, 0.62f), body,
            SurfaceKind.Metal);
        Color led = OfficeGrid.RoomColors[0];
        Material on = Visuals.MaterialFor(led, SurfaceKind.Emissive);
        Material off = Visuals.MaterialFor(Visuals.Darken(led, 0.75f), SurfaceKind.Glossy);
        for (int i = 0; i < 5; i++)
        {
            float y = 0.22f + i * 0.2f;
            Visuals.Primitive(PrimitiveType.Cube, rack, "Slot", new Vector3(0f, y, 0.311f), new Vector3(0.54f, 0.12f, 0.01f),
                Visuals.Lighten(body, 0.12f), SurfaceKind.Metal, false);
            var ledGo = Visuals.Primitive(PrimitiveType.Sphere, rack, "Led", new Vector3(0.2f - (i % 2) * 0.08f, y, 0.325f),
                Vector3.one * 0.035f, led, SurfaceKind.Emissive, false);
            ledGo.AddComponent<BlinkingLed>().Configure(on, off, 0.7f + i * 0.35f, i * 0.23f);
        }
    }

    // ---- Labels -------------------------------------------------------------------------------

    void BuildLabels()
    {
        var root = new GameObject("Labels").transform;
        root.SetParent(transform, false);
        for (int i = 0; i < OfficeGrid.Rooms.Length; i++)
        {
            RectInt rect = OfficeGrid.Rooms[i];
            var topCentre = new Vector2Int(rect.xMin + rect.width / 2, rect.yMin);
            Vector3 position = OfficeGrid.WorldPosition(topCentre) + new Vector3(-0.5f, 1.1f, 0.4f);
            Visuals.Label(root, $"Label {OfficeGrid.RoomNames[i]}", OfficeGrid.RoomNames[i], position, 0.09f,
                OfficeGrid.RoomColors[i]);
        }
    }
}
