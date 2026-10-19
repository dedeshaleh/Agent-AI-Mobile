using System;
using UnityEngine;

/// <summary>
/// Orthographic isometric camera (rotation 30°/45°) framing the 20×16 grid, with one-finger pan,
/// two-finger pinch zoom and tap picking. Uses the legacy Input API; the mouse path only runs on
/// platforms without touch so Android never sees duplicated simulated-mouse events.
/// </summary>
public class CameraRig : MonoBehaviour
{
    public event Action<int> AgentTapped;
    public event Action<int> RoomTapped;

    const float HomeSize = 9f;
    const float MinSize = 5f;
    const float MaxSize = 14f;
    const float MaxTapSeconds = 0.4f;
    const float PanLimitX = 12f;
    const float PanLimitY = 8f;

    static readonly Vector3 Focus = new Vector3((OfficeGrid.Width - 1) * 0.5f, 0f, -(OfficeGrid.Height - 1) * 0.5f);
    static readonly Quaternion Tilt = Quaternion.Euler(30f, 45f, 0f);

    Camera cam;
    Vector2 pan;
    Vector2 pressPosition;
    Vector2 lastMouse;
    float pressTime;
    bool pressed;
    bool dragged;

    public void Configure(Camera camera)
    {
        cam = camera;
        cam.orthographic = true;
        cam.clearFlags = CameraClearFlags.SolidColor;
        cam.backgroundColor = OfficeGrid.Hex("07101a");
        cam.allowMSAA = true;
        cam.allowHDR = true;
        cam.nearClipPlane = 0.1f;
        cam.farClipPlane = 200f;
        ResetCamera();
    }

    public void ResetCamera()
    {
        pan = Vector2.zero;
        if (cam != null) cam.orthographicSize = HomeSize;
        Place();
    }

    void Place()
    {
        transform.rotation = Tilt;
        transform.position = Focus + transform.right * pan.x + transform.up * pan.y - transform.forward * 40f;
    }

    void Update()
    {
        if (cam == null) return;
        if (Input.touchSupported)
        {
            if (Input.touchCount > 0) HandleTouch();
        }
        else
        {
            HandleMouse();
        }
    }

    void HandleTouch()
    {
        if (Input.touchCount >= 2)
        {
            Touch a = Input.GetTouch(0);
            Touch b = Input.GetTouch(1);
            float previous = ((a.position - a.deltaPosition) - (b.position - b.deltaPosition)).magnitude;
            float current = (a.position - b.position).magnitude;
            if (previous > 1f && current > 1f) Zoom(cam.orthographicSize * previous / current);
            pressed = false;
            return;
        }

        Touch touch = Input.GetTouch(0);
        switch (touch.phase)
        {
            case TouchPhase.Began:
                Press(touch.position);
                break;
            case TouchPhase.Moved:
                Drag(touch.position, touch.deltaPosition);
                break;
            case TouchPhase.Ended:
                Release(touch.position);
                break;
            case TouchPhase.Canceled:
                pressed = false;
                break;
        }
    }

    void HandleMouse()
    {
        if (Input.GetMouseButtonDown(0))
        {
            Press(Input.mousePosition);
            lastMouse = Input.mousePosition;
        }
        else if (Input.GetMouseButton(0))
        {
            Vector2 position = Input.mousePosition;
            Drag(position, position - lastMouse);
            lastMouse = position;
        }
        else if (Input.GetMouseButtonUp(0))
        {
            Release(Input.mousePosition);
        }
        float scroll = Input.mouseScrollDelta.y;
        if (Mathf.Abs(scroll) > 0.01f) Zoom(cam.orthographicSize - scroll * 0.8f);
    }

    void Press(Vector2 position)
    {
        pressed = true;
        dragged = false;
        pressPosition = position;
        pressTime = Time.unscaledTime;
    }

    void Drag(Vector2 position, Vector2 delta)
    {
        if (!pressed) return;
        if (!dragged && (position - pressPosition).magnitude > DragThreshold()) dragged = true;
        if (!dragged) return;
        float unitsPerPixel = 2f * cam.orthographicSize / Mathf.Max(1, Screen.height);
        pan -= delta * unitsPerPixel;
        pan.x = Mathf.Clamp(pan.x, -PanLimitX, PanLimitX);
        pan.y = Mathf.Clamp(pan.y, -PanLimitY, PanLimitY);
        Place();
    }

    void Release(Vector2 position)
    {
        bool tap = pressed && !dragged && Time.unscaledTime - pressTime < MaxTapSeconds;
        pressed = false;
        if (tap) Tap(position);
    }

    void Zoom(float size)
    {
        cam.orthographicSize = Mathf.Clamp(size, MinSize, MaxSize);
        Place();
    }

    static float DragThreshold()
    {
        float dpi = Screen.dpi > 0f ? Screen.dpi : 160f;
        return 12f * Mathf.Max(1f, dpi / 160f);
    }

    void Tap(Vector2 screenPosition)
    {
        Ray ray = cam.ScreenPointToRay(screenPosition);
        if (!Physics.Raycast(ray, out RaycastHit hit, 500f)) return;
        AgentController agent = hit.collider.GetComponentInParent<AgentController>();
        if (agent != null)
        {
            AgentTapped?.Invoke(agent.AgentIndex);
            return;
        }
        int room = OfficeGrid.RoomAt(OfficeGrid.TileAt(hit.point));
        if (room >= 0) RoomTapped?.Invoke(room);
    }
}
