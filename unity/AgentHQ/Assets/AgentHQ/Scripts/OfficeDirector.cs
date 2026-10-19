using System;
using System.Collections.Generic;
using UnityEngine;

/// <summary>
/// Owns the four agents, the shared tile reservation map, pause/speed flags and the meeting
/// choreography (seat reservation by agent index, arrival barrier, then home). Flutter remains
/// the source of truth for the workflow; this only moves robots and reports what happened.
/// </summary>
public class OfficeDirector : MonoBehaviour
{
    public static OfficeDirector Instance { get; private set; }

    public readonly List<AgentController> Agents = new List<AgentController>();
    public readonly Dictionary<Vector2Int, int> Reservations = new Dictionary<Vector2Int, int>();
    public bool Paused;
    public float SpeedMultiplier = 1f;
    public bool MeetingActive { get; private set; }

    /// <summary>(agent index, room index or -1 for a corridor)</summary>
    public event Action<int, int> AgentArrived;
    public event Action MeetingSeated;

    bool seatedAnnounced;

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    void OnDestroy()
    {
        if (Instance == this) Instance = null;
    }

    public AgentController CreateAgent(int index)
    {
        var agent = new GameObject("Agent" + index).AddComponent<AgentController>();
        agent.Setup(index, Reservations, this);
        agent.Arrived += OnAgentArrived;
        Agents.Add(agent);
        return agent;
    }

    public AgentController Agent(int index) => index >= 0 && index < Agents.Count ? Agents[index] : null;

    void Update()
    {
        if (!MeetingActive || seatedAnnounced) return;
        for (int i = 0; i < Agents.Count; i++)
        {
            if (Agents[i].Tile != OfficeGrid.Seats[i] || Agents[i].IsWalking) return;
        }
        seatedAnnounced = true;
        foreach (AgentController agent in Agents) agent.SetState("MEETING");
        MeetingSeated?.Invoke();
    }

    public bool BeginMeeting()
    {
        if (MeetingActive) return false;
        MeetingActive = true;
        seatedAnnounced = false;
        for (int i = 0; i < Agents.Count; i++) Agents[i].Go(OfficeGrid.Seats[i]);
        return true;
    }

    public void EndMeeting()
    {
        MeetingActive = false;
        seatedAnnounced = false;
        foreach (AgentController agent in Agents)
        {
            agent.SetSpeaking("");
            agent.Go(OfficeGrid.Homes[agent.AgentIndex]);
        }
    }

    public void SetMeeting(bool active)
    {
        if (active) BeginMeeting();
        else EndMeeting();
    }

    public void SetSpeed(int value) => SpeedMultiplier = Mathf.Clamp(value, 1, 4);

    public void Select(int index)
    {
        foreach (AgentController agent in Agents) agent.SetSelected(agent.AgentIndex == index);
    }

    /// <summary>Targets: "home", "seat" or "room:&lt;0-3&gt;".</summary>
    public bool WalkTo(int index, string target, out string error)
    {
        error = null;
        AgentController agent = Agent(index);
        if (agent == null)
        {
            error = "Indeks agent tidak valid: " + index;
            return false;
        }
        Vector2Int destination;
        switch (target)
        {
            case "home":
                destination = OfficeGrid.Homes[index];
                break;
            case "seat":
                destination = OfficeGrid.Seats[index];
                break;
            default:
                if (target != null && target.StartsWith("room:") && int.TryParse(target.Substring(5), out int room)
                    && room >= 0 && room < OfficeGrid.Rooms.Length)
                {
                    destination = RoomTarget(agent, room);
                    break;
                }
                error = "Target walkTo tidak dikenal: " + target;
                return false;
        }
        if (!agent.Go(destination))
        {
            error = $"Agent {index} tidak dapat mencapai {destination}";
            return false;
        }
        return true;
    }

    // The agent's own home when it lies in the room; otherwise the first free floor tile that is
    // not furniture, not any agent's home, and not occupied or reserved by another agent.
    Vector2Int RoomTarget(AgentController agent, int room)
    {
        Vector2Int home = OfficeGrid.Homes[agent.AgentIndex];
        if (OfficeGrid.RoomAt(home) == room) return home;
        RectInt rect = OfficeGrid.Rooms[room];
        for (int y = rect.yMin; y < rect.yMax; y++)
        {
            for (int x = rect.xMin; x < rect.xMax; x++)
            {
                var p = new Vector2Int(x, y);
                if (OfficeGrid.IsSolid(p)) continue;
                if (Array.IndexOf(OfficeGrid.Homes, p) >= 0) continue;
                if (Reservations.TryGetValue(p, out int owner) && owner != agent.AgentIndex) continue;
                return p;
            }
        }
        return home;
    }

    void OnAgentArrived(AgentController agent) =>
        AgentArrived?.Invoke(agent.AgentIndex, OfficeGrid.RoomAt(agent.Tile));
}
