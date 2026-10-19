using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build;
using UnityEditor.SceneManagement;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.SceneManagement;

/// <summary>
/// One-shot project configuration: scene, build settings, URP asset and the Player settings the
/// flutter_embed_unity exporter checks. Menu "Agent HQ/Setup Project" or
/// Unity.exe -batchmode -buildTarget Android -executeMethod AgentHQSetup.Configure -quit.
/// Each step is isolated so one API drift does not abort the rest.
/// </summary>
public static class AgentHQSetup
{
    const string ScenePath = "Assets/AgentHQ/Scenes/Office.unity";
    const string SettingsFolder = "Assets/AgentHQ/Settings";
    const string RendererPath = SettingsFolder + "/UniversalRenderer.asset";
    const string PipelinePath = SettingsFolder + "/URP.asset";
    const string ProjectSettingsPath = "ProjectSettings/ProjectSettings.asset";

    [MenuItem("Agent HQ/Setup Project")]
    public static void Configure()
    {
        Step("Scene", CreateScene);
        Step("Build settings", AddSceneToBuild);
        Step("URP asset", CreatePipelineAsset);
        Step("URP quality", ConfigurePipelineQuality);
        Step("Player identity", ConfigureIdentity);
        Step("Android scripting", ConfigureAndroidScripting);
        Step("Android SDK and export", ConfigureAndroidExport);
        Step("Graphics APIs", ConfigureGraphicsApis);
        Step("Input handling", ConfigureInputHandling);
        Step("Shaders and stripping", ConfigureShadersAndStripping);
        Step("Save", () =>
        {
            AssetDatabase.SaveAssets();
            AssetDatabase.Refresh();
        });
        Debug.Log("[AgentHQSetup] Selesai.");
    }

    static void Step(string label, Action action)
    {
        try
        {
            action();
            Debug.Log($"[AgentHQSetup] OK: {label}");
        }
        catch (Exception e)
        {
            Debug.LogError($"[AgentHQSetup] GAGAL: {label}: {e}");
        }
    }

    // The whole office is created at runtime, so nothing in the scene references colliders,
    // URP shaders or the TextMesh font: without this step the build strips them (robots fail
    // in CreatePrimitive, materials render pink).
    static void ConfigureShadersAndStripping()
    {
        PlayerSettings.stripEngineCode = false;
        PlayerSettings.SetManagedStrippingLevel(NamedBuildTarget.Android, ManagedStrippingLevel.Minimal);

        EnsureFolder("Assets/AgentHQ/Resources/AgentHQ");
        CreateMaterialAsset("Assets/AgentHQ/Resources/AgentHQ/HqLit.mat",
            "Universal Render Pipeline/Lit", "Universal Render Pipeline/Unlit", "Standard");
        CreateMaterialAsset("Assets/AgentHQ/Resources/AgentHQ/HqText.mat",
            "GUI/Text Shader", "Legacy Shaders/GUI/Text Shader", "Sprites/Default");
        // Keyword-bearing copies so the _EMISSION and transparent Lit variants ship in the build;
        // Visuals copies these at runtime for Emissive and Glass surfaces.
        Material emissive = CreateMaterialAsset("Assets/AgentHQ/Resources/AgentHQ/HqEmissive.mat",
            "Universal Render Pipeline/Lit", "Universal Render Pipeline/Unlit", "Standard");
        Visuals.ConfigureEmissive(emissive, Color.white);
        EditorUtility.SetDirty(emissive);
        Material glass = CreateMaterialAsset("Assets/AgentHQ/Resources/AgentHQ/HqGlass.mat",
            "Universal Render Pipeline/Lit", "Universal Render Pipeline/Unlit", "Standard");
        if (glass.HasProperty("_BaseColor")) glass.SetColor("_BaseColor", new Color(1f, 1f, 1f, 0.35f));
        Visuals.ConfigureGlass(glass);
        EditorUtility.SetDirty(glass);

        var graphics = AssetDatabase.LoadAllAssetsAtPath("ProjectSettings/GraphicsSettings.asset").FirstOrDefault();
        if (graphics == null) throw new InvalidOperationException("GraphicsSettings.asset tidak bisa dimuat");
        var so = new SerializedObject(graphics);
        var list = so.FindProperty("m_AlwaysIncludedShaders");
        // Hidden/* shaders must not be force-included: the player build then fails writing
        // Library/PlayerDataCache/.../unity_builtin_extra ("m_LockCount == 0" assertion).
        for (int i = list.arraySize - 1; i >= 0; i--)
        {
            var existing = list.GetArrayElementAtIndex(i).objectReferenceValue as Shader;
            // Shaders living in unity_builtin_extra (GUI/Text Shader, Sprites/Default, ...) must not be
            // listed here either: the player build then has to rewrite that file and fails. They ship
            // via the material assets under Resources/AgentHQ instead.
            bool fromBuiltinExtra = existing != null &&
                AssetDatabase.GetAssetPath(existing).EndsWith("unity_builtin_extra", StringComparison.Ordinal);
            if (existing == null || fromBuiltinExtra || existing.name.StartsWith("Hidden/", StringComparison.Ordinal))
            {
                // Deleting an object-reference element first nulls it, then removes it.
                list.DeleteArrayElementAtIndex(i);
                if (i < list.arraySize && list.GetArrayElementAtIndex(i).objectReferenceValue == null)
                    list.DeleteArrayElementAtIndex(i);
            }
        }
        string[] wanted =
        {
            "Universal Render Pipeline/Lit", "Universal Render Pipeline/Unlit",
        };
        foreach (string name in wanted)
        {
            Shader shader = Shader.Find(name);
            if (shader == null)
            {
                Debug.LogWarning($"[AgentHQSetup] Shader tidak ditemukan: {name}");
                continue;
            }
            bool present = false;
            for (int i = 0; i < list.arraySize; i++)
            {
                if (list.GetArrayElementAtIndex(i).objectReferenceValue == shader) { present = true; break; }
            }
            if (present) continue;
            list.InsertArrayElementAtIndex(list.arraySize);
            list.GetArrayElementAtIndex(list.arraySize - 1).objectReferenceValue = shader;
            Debug.Log($"[AgentHQSetup] Always included shader: {name}");
        }
        so.ApplyModifiedPropertiesWithoutUndo();
        AssetDatabase.SaveAssets();
    }

    static Material CreateMaterialAsset(string path, params string[] shaderNames)
    {
        Shader shader = shaderNames.Select(Shader.Find).FirstOrDefault(s => s != null);
        if (shader == null) throw new InvalidOperationException($"Tidak ada shader untuk {path}");
        var existing = AssetDatabase.LoadAssetAtPath<Material>(path);
        if (existing != null)
        {
            if (existing.shader != shader) { existing.shader = shader; EditorUtility.SetDirty(existing); }
            return existing;
        }
        var material = new Material(shader);
        AssetDatabase.CreateAsset(material, path);
        Debug.Log($"[AgentHQSetup] Material dibuat: {path} ({shader.name})");
        return material;
    }

    // Shadow, MSAA and HDR settings on the URP asset. The matching C# setters are internal for
    // several of these fields, so write the serialized properties directly.
    static void ConfigurePipelineQuality()
    {
        var pipeline = AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>(PipelinePath);
        if (pipeline == null) throw new InvalidOperationException("URP asset belum ada: " + PipelinePath);
        var so = new SerializedObject(pipeline);
        SetBool(so, "m_MainLightShadowsSupported", true);
        SetBool(so, "m_SoftShadowsSupported", true);
        SetBool(so, "m_SupportsHDR", true);
        SetInt(so, "m_MainLightShadowmapResolution", 2048);
        SetInt(so, "m_MSAA", 4);
        SetInt(so, "m_ShadowCascadeCount", 1);
        SetFloat(so, "m_ShadowDistance", 60f);
        so.ApplyModifiedPropertiesWithoutUndo();
        EditorUtility.SetDirty(pipeline);
        AssetDatabase.SaveAssets();
    }

    static void SetBool(SerializedObject so, string name, bool value)
    {
        SerializedProperty p = so.FindProperty(name);
        if (p == null) { Debug.LogWarning($"[AgentHQSetup] Properti URP tidak ditemukan: {name}"); return; }
        p.boolValue = value;
    }

    static void SetInt(SerializedObject so, string name, int value)
    {
        SerializedProperty p = so.FindProperty(name);
        if (p == null) { Debug.LogWarning($"[AgentHQSetup] Properti URP tidak ditemukan: {name}"); return; }
        p.intValue = value;
    }

    static void SetFloat(SerializedObject so, string name, float value)
    {
        SerializedProperty p = so.FindProperty(name);
        if (p == null) { Debug.LogWarning($"[AgentHQSetup] Properti URP tidak ditemukan: {name}"); return; }
        p.floatValue = value;
    }

    static void EnsureFolder(string assetFolder)
    {
        string full = Path.Combine(Directory.GetCurrentDirectory(), assetFolder);
        if (!Directory.Exists(full)) Directory.CreateDirectory(full);
        AssetDatabase.Refresh();
    }

    static void CreateScene()
    {
        if (File.Exists(ScenePath))
        {
            Debug.Log("[AgentHQSetup] Scene sudah ada, dilewati.");
            return;
        }
        EnsureFolder(Path.GetDirectoryName(ScenePath));
        Scene scene = EditorSceneManager.NewScene(NewSceneSetup.EmptyScene, NewSceneMode.Single);

        var cameraObject = new GameObject("Main Camera");
        cameraObject.tag = "MainCamera";
        Camera cam = cameraObject.AddComponent<Camera>();
        cameraObject.AddComponent<AudioListener>();
        cam.orthographic = true;
        cam.orthographicSize = 9f;
        cam.clearFlags = CameraClearFlags.SolidColor;
        cam.backgroundColor = new Color(0.03f, 0.06f, 0.1f);
        cameraObject.transform.rotation = Quaternion.Euler(30f, 45f, 0f);
        cameraObject.transform.position = new Vector3(9.5f, 0f, -7.5f) - cameraObject.transform.forward * 40f;

        var lightObject = new GameObject("Directional Light");
        Light light = lightObject.AddComponent<Light>();
        light.type = LightType.Directional;
        light.intensity = 1.1f;
        light.color = new Color(1f, 0.96f, 0.9f);
        light.shadows = LightShadows.Soft;
        lightObject.transform.rotation = Quaternion.Euler(50f, -30f, 0f);

        new GameObject("Bootstrap").AddComponent<Bootstrap>();

        if (!EditorSceneManager.SaveScene(scene, ScenePath)) throw new Exception("SaveScene gagal");
    }

    static void AddSceneToBuild()
    {
        if (EditorBuildSettings.scenes.Any(s => s.path == ScenePath && s.enabled)) return;
        EditorBuildSettings.scenes = new[] { new EditorBuildSettingsScene(ScenePath, true) };
    }

    static void CreatePipelineAsset()
    {
        EnsureFolder(SettingsFolder);
        var pipeline = AssetDatabase.LoadAssetAtPath<UniversalRenderPipelineAsset>(PipelinePath);
        if (pipeline == null)
        {
            var renderer = AssetDatabase.LoadAssetAtPath<UniversalRendererData>(RendererPath);
            if (renderer == null)
            {
                renderer = ScriptableObject.CreateInstance<UniversalRendererData>();
                AssetDatabase.CreateAsset(renderer, RendererPath);
            }
            // The renderer data must be its own saved asset, otherwise the pipeline asset would
            // reference an unsaved in-memory object.
            pipeline = UniversalRenderPipelineAsset.Create(renderer);
            AssetDatabase.CreateAsset(pipeline, PipelinePath);
        }

        GraphicsSettings.defaultRenderPipeline = pipeline;

        int previous = QualitySettings.GetQualityLevel();
        for (int i = 0; i < QualitySettings.names.Length; i++)
        {
            QualitySettings.SetQualityLevel(i, false);
            QualitySettings.renderPipeline = pipeline;
        }
        QualitySettings.SetQualityLevel(previous, false);
        EditorUtility.SetDirty(pipeline);
    }

    static void ConfigureIdentity()
    {
        PlayerSettings.companyName = "AgentHQ";
        PlayerSettings.productName = "Agent HQ";
        PlayerSettings.SetApplicationIdentifier(NamedBuildTarget.Android, "id.agenthq.unity");
        PlayerSettings.defaultInterfaceOrientation = UIOrientation.LandscapeLeft;
        PlayerSettings.colorSpace = ColorSpace.Linear;
    }

    static void ConfigureAndroidScripting()
    {
        PlayerSettings.SetScriptingBackend(NamedBuildTarget.Android, ScriptingImplementation.IL2CPP);
        PlayerSettings.SetIl2CppCodeGeneration(NamedBuildTarget.Android, Il2CppCodeGeneration.OptimizeSpeed);
        PlayerSettings.SetIl2CppCompilerConfiguration(NamedBuildTarget.Android, Il2CppCompilerConfiguration.Release);
        // The flutter_embed_unity pre-check (ProjectExportChecker.PreCheckAndroid) refuses to export
        // unless BOTH ARMv7 and ARM64 are enabled; the Flutter app's abiFilters drop the 32-bit libs.
        PlayerSettings.Android.targetArchitectures = AndroidArchitecture.ARM64 | AndroidArchitecture.ARMv7;
    }

    static void ConfigureAndroidExport()
    {
        PlayerSettings.Android.minSdkVersion = AndroidSdkVersions.AndroidApiLevel23;
        PlayerSettings.Android.targetSdkVersion = AndroidSdkVersions.AndroidApiLevelAuto;
        PlayerSettings.Android.forceInternetPermission = false;
        PlayerSettings.Android.forceSDCardPermission = false;
        // Required by the exporter's pre-check in Unity 6: the embedded view needs the Activity entry.
        PlayerSettings.Android.applicationEntry = AndroidApplicationEntry.Activity;
        EditorUserBuildSettings.exportAsGoogleAndroidProject = true;
        EditorUserBuildSettings.androidBuildSystem = AndroidBuildSystem.Gradle;
        EditorUserBuildSettings.development = false;
        EditorUserBuildSettings.allowDebugging = false;
    }

    static void ConfigureGraphicsApis()
    {
        PlayerSettings.SetUseDefaultGraphicsAPIs(BuildTarget.Android, false);
        PlayerSettings.SetGraphicsAPIs(BuildTarget.Android, new[] { GraphicsDeviceType.OpenGLES3, GraphicsDeviceType.Vulkan });
    }

    // activeInputHandler: 0 = Input Manager (Old), 1 = Input System (New), 2 = Both. "Both" is only
    // valid when com.unity.inputsystem is installed, otherwise fall back to the legacy manager
    // which is all CameraRig uses.
    static void ConfigureInputHandling()
    {
        bool hasInputSystem = File.Exists("Packages/manifest.json")
                              && File.ReadAllText("Packages/manifest.json").Contains("com.unity.inputsystem");
        int value = hasInputSystem ? 2 : 0;

        UnityEngine.Object[] assets = AssetDatabase.LoadAllAssetsAtPath(ProjectSettingsPath);
        UnityEngine.Object settings = assets != null && assets.Length > 0 ? assets[0] : null;
        if (settings == null) settings = Unsupported.GetSerializedAssetInterfaceSingleton("PlayerSettings");
        if (settings == null) throw new Exception("PlayerSettings asset tidak ditemukan");

        var serialized = new SerializedObject(settings);
        SerializedProperty property = serialized.FindProperty("activeInputHandler");
        if (property == null) throw new Exception("Properti activeInputHandler tidak ditemukan");
        property.intValue = value;
        serialized.ApplyModifiedProperties();
        Debug.Log($"[AgentHQSetup] activeInputHandler = {value}");
    }
}
