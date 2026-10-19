using UnityEngine;
using UnityEngine.Rendering;

/// <summary>
/// The scene only needs a Camera, a Directional Light and this component: on Awake it creates
/// (if missing) the office, the director with its four agents, the FlutterBridge and the camera rig.
/// </summary>
public class Bootstrap : MonoBehaviour
{
    void Awake()
    {
        Application.targetFrameRate = 30;
        RenderSettings.ambientMode = AmbientMode.Flat;
        RenderSettings.ambientLight = new Color(0.22f, 0.26f, 0.34f); // dark blue-grey
        RenderSettings.fog = false;

        if (FindFirstObjectByType<OfficeBuilder>() == null)
        {
            new GameObject("Office").AddComponent<OfficeBuilder>();
        }

        OfficeDirector director = OfficeDirector.Instance;
        if (director == null) director = FindFirstObjectByType<OfficeDirector>();
        if (director == null) director = new GameObject("OfficeDirector").AddComponent<OfficeDirector>();
        while (director.Agents.Count < OfficeGrid.Homes.Length) director.CreateAgent(director.Agents.Count);

        ConfigureLights();

        Camera cam = Camera.main;
        if (cam == null) cam = FindFirstObjectByType<Camera>();
        if (cam == null)
        {
            cam = new GameObject("Main Camera").AddComponent<Camera>();
            cam.tag = "MainCamera";
        }
        CameraRig rig = cam.GetComponent<CameraRig>();
        if (rig == null) rig = cam.gameObject.AddComponent<CameraRig>();
        rig.Configure(cam);

        if (GameObject.Find("FlutterBridge") == null)
        {
            new GameObject("FlutterBridge").AddComponent<FlutterBridge>();
        }
    }

    // Key light: warm, soft shadows. Fill: weak, cool, from the opposite side, no shadows. The
    // scene's own Directional Light (if any) becomes the key so its settings stay in one place.
    static void ConfigureLights()
    {
        Light key = null;
        foreach (Light existing in FindObjectsByType<Light>(FindObjectsSortMode.None))
        {
            if (existing.type != LightType.Directional || existing.name == "Fill Light") continue;
            key = existing;
            break;
        }
        if (key == null)
        {
            key = new GameObject("Directional Light").AddComponent<Light>();
            key.type = LightType.Directional;
        }
        key.transform.rotation = Quaternion.Euler(50f, -30f, 0f);
        key.intensity = 1.1f;
        key.color = new Color(1f, 0.96f, 0.9f);
        key.shadows = LightShadows.Soft;
        key.shadowStrength = 0.6f;
        key.shadowBias = 0.03f;
        key.shadowNormalBias = 0.5f;

        if (GameObject.Find("Fill Light") == null)
        {
            var fill = new GameObject("Fill Light").AddComponent<Light>();
            fill.type = LightType.Directional;
            fill.transform.rotation = Quaternion.Euler(35f, 150f, 0f);
            fill.intensity = 0.25f;
            fill.color = new Color(0.72f, 0.82f, 1f);
            fill.shadows = LightShadows.None;
        }
    }
}
