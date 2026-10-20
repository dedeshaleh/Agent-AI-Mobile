using System;
using UnityEngine;

/// <summary>
/// Flutter ⇄ Unity message endpoint. Lives on a GameObject named exactly "FlutterBridge" so
/// Flutter can call sendToUnity("FlutterBridge", "OnMessage", json). Field names mirror
/// app/lib/game_bridge/game_protocol.dart exactly.
/// </summary>
public class FlutterBridge : MonoBehaviour
{
    public const int ProtocolVersion = 1;

    // JsonUtility cannot parse polymorphic JSON, so one class carries every optional field.
    // Missing fields keep their defaults; booleans default to false, so "active"/"paused" are
    // taken as given.
    [Serializable]
    class IncomingMessage
    {
        public string type;
        public int agent = -1;
        public string target;
        public string state;
        public string text;
        public bool active;
        public bool paused;
        public int value = 1;
    }

    [Serializable] class ReadyMessage { public string type = "ready"; public int version = ProtocolVersion; }
    [Serializable] class ArrivedMessage { public string type = "arrived"; public int agent; public int room; }
    [Serializable] class AgentTappedMessage { public string type = "agentTapped"; public int agent; }
    [Serializable] class RoomTappedMessage { public string type = "roomTapped"; public int room; }
    [Serializable] class MeetingSeatedMessage { public string type = "meetingSeated"; }
    [Serializable] class ErrorMessage { public string type = "error"; public string message; }
    [Serializable] class StatsMessage { public string type = "stats"; public float fps; public float frameMs; public string gpu; }

    OfficeDirector director;
    CameraRig cameraRig;
    int statFrames;
    float statElapsed;

    void Start()
    {
        Bind();
        Send(new ReadyMessage());
    }

    // Once per second: render FPS and frame time for the Flutter performance overlay.
    void Update()
    {
        statFrames++;
        statElapsed += Time.unscaledDeltaTime;
        if (statElapsed < 1f) return;
        Send(new StatsMessage
        {
            fps = statFrames / statElapsed,
            frameMs = statElapsed / statFrames * 1000f,
            gpu = SystemInfo.graphicsDeviceName,
        });
        statFrames = 0;
        statElapsed = 0f;
    }

    void Bind()
    {
        if (director == null)
        {
            director = OfficeDirector.Instance;
            if (director != null)
            {
                director.AgentArrived += (agent, room) => Send(new ArrivedMessage { agent = agent, room = room });
                director.MeetingSeated += () => Send(new MeetingSeatedMessage());
            }
        }
        if (cameraRig == null)
        {
            cameraRig = FindFirstObjectByType<CameraRig>();
            if (cameraRig != null)
            {
                cameraRig.AgentTapped += agent => Send(new AgentTappedMessage { agent = agent });
                cameraRig.RoomTapped += room => Send(new RoomTappedMessage { room = room });
            }
        }
    }

    /// <summary>Entry point for sendToUnity("FlutterBridge", "OnMessage", json).</summary>
    public void OnMessage(string json)
    {
        IncomingMessage message;
        try
        {
            message = JsonUtility.FromJson<IncomingMessage>(json);
        }
        catch (Exception e)
        {
            SendError("Pesan bukan JSON: " + e.Message);
            return;
        }
        if (message == null || string.IsNullOrEmpty(message.type))
        {
            SendError("Pesan tanpa field type: " + json);
            return;
        }

        Bind();
        if (director == null)
        {
            SendError("OfficeDirector belum siap");
            return;
        }

        switch (message.type)
        {
            case "walkTo":
                if (!director.WalkTo(message.agent, message.target, out string error)) SendError(error);
                break;
            case "setState":
                WithAgent(message.agent, a => a.SetState(message.state));
                break;
            case "speak":
                WithAgent(message.agent, a => a.SetSpeaking(message.text ?? ""));
                break;
            case "meeting":
                director.SetMeeting(message.active);
                break;
            case "pause":
                director.Paused = message.paused;
                break;
            case "speed":
                director.SetSpeed(message.value);
                break;
            case "select":
                director.Select(message.agent);
                break;
            case "resetCamera":
                if (cameraRig != null) cameraRig.ResetCamera();
                break;
            default:
                SendError("Tipe pesan tidak dikenal: " + message.type);
                break;
        }
    }

    void WithAgent(int index, Action<AgentController> action)
    {
        AgentController agent = director.Agent(index);
        if (agent == null)
        {
            SendError("Indeks agent tidak valid: " + index);
            return;
        }
        action(agent);
    }

    void SendError(string message) => Send(new ErrorMessage { message = message });

    static void Send(object dto) => SendToFlutter.Send(JsonUtility.ToJson(dto));
}
