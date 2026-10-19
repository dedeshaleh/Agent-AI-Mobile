using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// One robot agent: a port of game/scripts/agent.gd. Moves tile by tile through a reservation map
/// shared by all agents (reserve the next tile, re-plan around tiles reserved by others, release
/// the origin tile on arrival, never swap through another robot) and draws itself from primitives.
/// </summary>
public class AgentController : MonoBehaviour
{
    public static readonly string[] Titles = { "Data", "Analyst", "Strategist", "Reporter" };
    public const float TilesPerSecond = 2.6f;
    const int BubbleMaxChars = 60;
    const int BubbleLineChars = 30;

    public int AgentIndex { get; private set; }
    public Vector2Int Tile { get; private set; }
    public string State { get; private set; } = "IDLE";
    public float Speed = TilesPerSecond;
    public bool IsWalking => State == "WALKING";
    public bool Speaking => bubble != null && bubble.activeSelf;
    public event Action<AgentController> Arrived;

    OfficeDirector director;
    Dictionary<Vector2Int, int> reservations;
    readonly List<Vector2Int> path = new List<Vector2Int>();
    Vector2Int nextTile;
    bool hasNext;
    float phase;
    Color tint;
    Quaternion facing = OfficeBuilder.FaceCamera;

    Transform pivot, body, legL, legR, armL, armR, eyeL, eyeR, antennaTip, ring;
    GameObject bubble;
    Transform bubbleQuad;
    TextMesh bubbleText;

    public void Setup(int index, Dictionary<Vector2Int, int> sharedReservations, OfficeDirector owner = null)
    {
        AgentIndex = index;
        director = owner;
        reservations = sharedReservations;
        tint = OfficeGrid.RoomColors[index];
        Tile = OfficeGrid.Homes[index];
        transform.position = OfficeGrid.WorldPosition(Tile);
        reservations[Tile] = index;
        name = "Agent " + Titles[index];
        BuildBody();
        State = "IDLE";
    }

    public bool Go(Vector2Int destination)
    {
        Vector2Int origin = hasNext ? nextTile : Tile;
        List<Vector2Int> route = OfficeGrid.Route(origin, destination);
        if (route.Count == 0)
        {
            if (hasNext) ArriveAt(nextTile); // never leave a robot between two tiles
            path.Clear();
            State = "FAILED";
            return false;
        }
        path.Clear();
        path.AddRange(route);
        if (path[0] == origin) path.RemoveAt(0);
        if (hasNext) path.Insert(0, nextTile); // finish the step already in progress first
        State = "WALKING";
        return true;
    }

    /// <summary>State pushed by Flutter (AgentState.wire). WALKING without a path is ignored.</summary>
    public void SetState(string state)
    {
        if (string.IsNullOrEmpty(state)) return;
        if (state == "WALKING" && path.Count == 0 && !hasNext) return;
        if (state != "WALKING" && hasNext) ArriveAt(nextTile);
        State = state;
    }

    public void SetSpeaking(string text)
    {
        if (bubble == null) return;
        if (string.IsNullOrEmpty(text))
        {
            bubble.SetActive(false);
            return;
        }
        string shown = text.Length > BubbleMaxChars ? text.Substring(0, BubbleMaxChars - 1) + "…" : text;
        List<string> lines = Wrap(shown, BubbleLineChars);
        int widest = 1;
        foreach (string line in lines) widest = Mathf.Max(widest, line.Length);
        bubbleText.text = string.Join("\n", lines);
        float height = lines.Count * 0.24f + 0.14f;
        // The capsule's rounded ends are half-circles of radius height/2, so pad the width by the
        // full height to keep the corner characters inside the pill.
        float width = widest * 0.1f + height;
        // Capsule rotated 90° about z: localScale.x is the pill thickness (vertical on screen) and
        // 2 * localScale.y its length (horizontal).
        bubbleQuad.localScale = new Vector3(height, width * 0.5f, 0.06f);
        bubbleQuad.localPosition = new Vector3(0f, height * 0.5f, 0.05f);
        bubbleText.transform.localPosition = new Vector3(0f, height * 0.5f, -0.01f);
        bubble.SetActive(true);
    }

    public void SetSelected(bool selected)
    {
        if (ring != null) ring.gameObject.SetActive(selected);
    }

    void Update()
    {
        if (director != null && director.Paused) return;
        float dt = Time.deltaTime * (director != null ? director.SpeedMultiplier : 1f);
        phase += dt;
        if (State == "WALKING") Step(dt);
        Animate();
    }

    void Step(float dt)
    {
        if (path.Count == 0)
        {
            State = "WORKING";
            facing = OfficeBuilder.FaceCamera;
            Arrived?.Invoke(this);
            return;
        }

        Vector2Int target = path[0];
        if (!hasNext)
        {
            if (reservations.TryGetValue(target, out int owner) && owner != AgentIndex)
            {
                Replan();
                return;
            }
            reservations[target] = AgentIndex;
            nextTile = target;
            hasNext = true;
            Vector3 direction = OfficeGrid.WorldPosition(target) - OfficeGrid.WorldPosition(Tile);
            if (direction.sqrMagnitude > 0.001f) facing = Quaternion.LookRotation(direction, Vector3.up);
        }

        Vector3 goal = OfficeGrid.WorldPosition(target);
        transform.position = Vector3.MoveTowards(transform.position, goal, dt * Speed);
        if ((transform.position - goal).sqrMagnitude < 0.0001f) ArriveAt(target);
    }

    // Re-plan around every tile another robot holds; if no alternative exists, wait in place.
    void Replan()
    {
        var blocked = new HashSet<Vector2Int>();
        foreach (KeyValuePair<Vector2Int, int> entry in reservations)
        {
            if (entry.Value != AgentIndex && !OfficeGrid.IsSolid(entry.Key)) blocked.Add(entry.Key);
        }
        List<Vector2Int> alternate = OfficeGrid.Route(Tile, path[path.Count - 1], blocked);
        if (alternate.Count > 1)
        {
            alternate.RemoveAt(0);
            path.Clear();
            path.AddRange(alternate);
        }
    }

    void ArriveAt(Vector2Int target)
    {
        transform.position = OfficeGrid.WorldPosition(target);
        if (reservations.TryGetValue(Tile, out int owner) && owner == AgentIndex) reservations.Remove(Tile);
        reservations[target] = AgentIndex;
        Tile = target;
        hasNext = false;
        if (path.Count > 0 && path[0] == target) path.RemoveAt(0);
    }

    void Animate()
    {
        bool walking = State == "WALKING" && hasNext;
        bool seated = State == "MEETING" || State == "TALKING" || State == "WORKING";
        float bob = walking ? Mathf.Sin(phase * 13f) * 0.04f : Mathf.Sin(phase * 2f) * 0.015f;
        float stride = walking ? Mathf.Sin(phase * 13f) * 0.1f : 0f;

        pivot.rotation = Quaternion.RotateTowards(pivot.rotation, facing, 720f * Time.deltaTime);
        body.localPosition = new Vector3(0f, (seated ? -0.1f : 0f) + bob, 0f);
        legL.localPosition = new Vector3(-0.13f, 0.14f, stride);
        legR.localPosition = new Vector3(0.13f, 0.14f, -stride);

        float typing = State == "WORKING" ? Mathf.Sin(phase * 14f) * 0.03f : stride * 0.3f;
        armL.localPosition = new Vector3(-0.3f, 0.46f + typing, 0.05f);
        armR.localPosition = new Vector3(0.3f, 0.46f - typing, 0.05f);

        bool blink = Mathf.Repeat(phase + AgentIndex, 4.8f) < 0.14f;
        var eyeScale = new Vector3(0.09f, blink ? 0.015f : 0.1f, 0.02f);
        eyeL.localScale = eyeScale;
        eyeR.localScale = eyeScale;

        antennaTip.localScale = Vector3.one * (State == "DONE" ? 0.11f + Mathf.Sin(phase * 4f) * 0.03f : 0.1f);
        if (bubble.activeSelf) bubble.transform.localPosition = new Vector3(0f, 1.95f + Mathf.Sin(phase * 3f) * 0.03f, 0f);
    }

    // Visual build only: the transforms Animate() drives keep their names, positions and scales.
    void BuildBody()
    {
        Color dark = Visuals.Darken(tint, 0.4f);
        Color shell = Visuals.Darken(tint, 0.2f);
        Color face = OfficeGrid.Hex("101f2e");
        Color eye = OfficeGrid.Hex("c7f9ff");
        Color lamp = OfficeGrid.Hex("b2ffcf");
        Color shadow = OfficeGrid.Hex("08101a");
        Color joint = OfficeGrid.Hex("2c3844");
        Color visorGlass = Visuals.Lighten(tint, 0.5f);

        pivot = new GameObject("Pivot").transform;
        pivot.SetParent(transform, false);
        pivot.rotation = facing;

        ring = Visuals.Primitive(PrimitiveType.Cylinder, pivot, "SelectionRing", new Vector3(0f, 0.012f, 0f),
            new Vector3(0.95f, 0.006f, 0.95f), tint, SurfaceKind.Emissive, false).transform;
        ring.gameObject.SetActive(false);
        var blob = Visuals.Primitive(PrimitiveType.Cylinder, pivot, "Shadow", new Vector3(0f, 0.02f, 0f),
            new Vector3(0.62f, 0.006f, 0.62f), shadow, SurfaceKind.Matte, false);
        blob.GetComponent<Renderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;

        legL = Visuals.Primitive(PrimitiveType.Capsule, pivot, "LegL", new Vector3(-0.13f, 0.14f, 0f),
            new Vector3(0.12f, 0.12f, 0.12f), dark, SurfaceKind.Metal, false).transform;
        legR = Visuals.Primitive(PrimitiveType.Capsule, pivot, "LegR", new Vector3(0.13f, 0.14f, 0f),
            new Vector3(0.12f, 0.12f, 0.12f), dark, SurfaceKind.Metal, false).transform;
        // Feet: flattened spheres under each leg (static, legs only swing a little).
        Visuals.Primitive(PrimitiveType.Sphere, legL, "Foot", new Vector3(0f, -0.9f, 0.2f), new Vector3(1.3f, 0.5f, 1.6f), joint, SurfaceKind.Matte, false);
        Visuals.Primitive(PrimitiveType.Sphere, legR, "Foot", new Vector3(0f, -0.9f, 0.2f), new Vector3(1.3f, 0.5f, 1.6f), joint, SurfaceKind.Matte, false);

        body = new GameObject("Body").transform;
        body.SetParent(pivot, false);
        // Rounded torso: a capsule (0.48 tall) with a dark belt across the middle.
        Visuals.Primitive(PrimitiveType.Capsule, body, "Torso", new Vector3(0f, 0.5f, 0f), new Vector3(0.44f, 0.24f, 0.32f), shell, SurfaceKind.Metal, false);
        Visuals.Primitive(PrimitiveType.Cylinder, body, "Belt", new Vector3(0f, 0.38f, 0f), new Vector3(0.46f, 0.025f, 0.34f), joint, SurfaceKind.Matte, false);
        Visuals.Primitive(PrimitiveType.Sphere, body, "Badge", new Vector3(0f, 0.58f, 0.145f), new Vector3(0.09f, 0.09f, 0.05f), Visuals.Lighten(tint, 0.35f), SurfaceKind.Emissive, false);

        Visuals.Primitive(PrimitiveType.Sphere, body, "ShoulderL", new Vector3(-0.27f, 0.62f, 0.05f), Vector3.one * 0.13f, joint, SurfaceKind.Glossy, false);
        Visuals.Primitive(PrimitiveType.Sphere, body, "ShoulderR", new Vector3(0.27f, 0.62f, 0.05f), Vector3.one * 0.13f, joint, SurfaceKind.Glossy, false);
        armL = Visuals.Primitive(PrimitiveType.Capsule, body, "ArmL", new Vector3(-0.3f, 0.46f, 0.05f), new Vector3(0.09f, 0.15f, 0.09f), tint, SurfaceKind.Metal, false).transform;
        armR = Visuals.Primitive(PrimitiveType.Capsule, body, "ArmR", new Vector3(0.3f, 0.46f, 0.05f), new Vector3(0.09f, 0.15f, 0.09f), tint, SurfaceKind.Metal, false).transform;
        Visuals.Primitive(PrimitiveType.Sphere, armL, "HandL", new Vector3(0f, -0.95f, 0f), new Vector3(1.25f, 0.75f, 1.25f), joint, SurfaceKind.Glossy, false);
        Visuals.Primitive(PrimitiveType.Sphere, armR, "HandR", new Vector3(0f, -0.95f, 0f), new Vector3(1.25f, 0.75f, 1.25f), joint, SurfaceKind.Glossy, false);

        // Head: glossy sphere, dark face plate, emissive eyes, then a glass visor dome over the face.
        Visuals.Primitive(PrimitiveType.Cylinder, body, "Neck", new Vector3(0f, 0.76f, 0f), new Vector3(0.14f, 0.03f, 0.14f), joint, SurfaceKind.Matte, false);
        Visuals.Primitive(PrimitiveType.Sphere, body, "Head", new Vector3(0f, 0.97f, 0f), new Vector3(0.54f, 0.44f, 0.46f), tint, SurfaceKind.Glossy, false);
        Visuals.Primitive(PrimitiveType.Sphere, body, "FacePlate", new Vector3(0f, 0.97f, 0.15f), new Vector3(0.42f, 0.3f, 0.16f), face, SurfaceKind.Matte, false);
        eyeL = Visuals.Primitive(PrimitiveType.Sphere, body, "EyeL", new Vector3(-0.11f, 0.99f, 0.235f), new Vector3(0.09f, 0.1f, 0.02f), eye, SurfaceKind.Emissive, false).transform;
        eyeR = Visuals.Primitive(PrimitiveType.Sphere, body, "EyeR", new Vector3(0.11f, 0.99f, 0.235f), new Vector3(0.09f, 0.1f, 0.02f), eye, SurfaceKind.Emissive, false).transform;
        Visuals.Primitive(PrimitiveType.Sphere, body, "Visor", new Vector3(0f, 0.97f, 0.16f), new Vector3(0.48f, 0.34f, 0.2f), visorGlass, SurfaceKind.Glass, false);
        Visuals.Primitive(PrimitiveType.Sphere, body, "EarL", new Vector3(-0.27f, 0.97f, 0f), new Vector3(0.06f, 0.14f, 0.14f), joint, SurfaceKind.Glossy, false);
        Visuals.Primitive(PrimitiveType.Sphere, body, "EarR", new Vector3(0.27f, 0.97f, 0f), new Vector3(0.06f, 0.14f, 0.14f), joint, SurfaceKind.Glossy, false);
        Visuals.Primitive(PrimitiveType.Cylinder, body, "Antenna", new Vector3(0f, 1.25f, 0f), new Vector3(0.03f, 0.07f, 0.03f), joint, SurfaceKind.Metal, false);
        antennaTip = Visuals.Primitive(PrimitiveType.Sphere, body, "AntennaTip", new Vector3(0f, 1.36f, 0f), Vector3.one * 0.1f, lamp, SurfaceKind.Emissive, false).transform;

        var collider = gameObject.AddComponent<CapsuleCollider>();
        collider.center = new Vector3(0f, 0.75f, 0f);
        collider.radius = 0.38f;
        collider.height = 1.6f;

        Visuals.Label(transform, "Name", Titles[AgentIndex], new Vector3(0f, 1.72f, 0f), 0.05f, OfficeGrid.Hex("dce8f5"));

        bubble = new GameObject("SpeechBubble");
        bubble.transform.SetParent(transform, false);
        bubble.transform.localPosition = new Vector3(0f, 1.95f, 0f);
        bubble.AddComponent<Billboard>();
        // Rounded pill: a capsule laid on its side behind the text (sized in SetSpeaking), plus a
        // small tail sphere pointing at the robot.
        var back = Visuals.Primitive(PrimitiveType.Capsule, bubble.transform, "Background", new Vector3(0f, 0.2f, 0.05f),
            new Vector3(0.4f, 0.5f, 0.06f), OfficeGrid.Hex("f2f6fa"), SurfaceKind.Glossy, false);
        back.transform.localRotation = Quaternion.Euler(0f, 0f, 90f);
        back.GetComponent<Renderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        bubbleQuad = back.transform;
        var tail = Visuals.Primitive(PrimitiveType.Sphere, bubble.transform, "Tail", new Vector3(0f, -0.02f, 0.05f),
            new Vector3(0.12f, 0.12f, 0.05f), OfficeGrid.Hex("f2f6fa"), SurfaceKind.Glossy, false);
        tail.GetComponent<Renderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
        bubbleText = Visuals.Label(bubble.transform, "Text", "", new Vector3(0f, 0.2f, -0.01f), 0.04f, OfficeGrid.Hex("101f2e"));
        Destroy(bubbleText.GetComponent<Billboard>()); // the bubble root already billboards
        bubble.SetActive(false);
    }

    // TextMesh has no word wrap, so break the text greedily on spaces.
    static List<string> Wrap(string text, int maxChars)
    {
        var lines = new List<string>();
        var current = "";
        foreach (string word in text.Split(' '))
        {
            string candidate = current.Length == 0 ? word : current + " " + word;
            if (candidate.Length <= maxChars)
            {
                current = candidate;
                continue;
            }
            if (current.Length > 0) lines.Add(current);
            current = word.Length > maxChars ? word.Substring(0, maxChars) : word;
        }
        if (current.Length > 0 || lines.Count == 0) lines.Add(current);
        return lines;
    }
}
