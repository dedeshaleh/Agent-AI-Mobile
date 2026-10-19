using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

/// <summary>Surface presets applied on top of URP/Lit. Each maps to smoothness/metallic/emission and a procedural texture.</summary>
public enum SurfaceKind { Matte, Glossy, Metal, Emissive, Wood, Fabric, Glass }

/// <summary>
/// Runtime material, primitive and label helpers. Everything is built from primitives so the
/// project needs no imported art assets.
/// </summary>
public static class Visuals
{
    static Material baseMaterial, emissiveMaterial, glassMaterial;
    static Font builtinFont;

    readonly struct MaterialKey
    {
        public readonly Color Color;
        public readonly SurfaceKind Kind;
        public readonly int TextureId;
        public readonly Vector2 Tiling;

        public MaterialKey(Color color, SurfaceKind kind, int textureId, Vector2 tiling)
        {
            Color = color; Kind = kind; TextureId = textureId; Tiling = tiling;
        }

        public override bool Equals(object obj) =>
            obj is MaterialKey k && k.Color == Color && k.Kind == Kind && k.TextureId == TextureId && k.Tiling == Tiling;

        public override int GetHashCode() =>
            Color.GetHashCode() ^ ((int)Kind * 397) ^ (TextureId * 31) ^ Tiling.GetHashCode();
    }

    static readonly Dictionary<MaterialKey, Material> materials = new Dictionary<MaterialKey, Material>();

    public static Color Darken(Color c, float amount) =>
        new Color(c.r * (1f - amount), c.g * (1f - amount), c.b * (1f - amount), c.a);

    public static Color Lighten(Color c, float amount) =>
        new Color(c.r + (1f - c.r) * amount, c.g + (1f - c.g) * amount, c.b + (1f - c.b) * amount, c.a);

    public static Color WithAlpha(Color c, float alpha) => new Color(c.r, c.g, c.b, alpha);

    /// <summary>Backward compatible: a matte, untextured surface.</summary>
    public static Material MaterialFor(Color color) => MaterialFor(color, SurfaceKind.Matte);

    /// <summary>
    /// Cached material for a colour and surface kind. 'texture' overrides the kind's default
    /// texture (Wood/Metal/Fabric carry their own); 'tiling' sets _BaseMap tiling for merged
    /// floor slabs. Every material is a copy of a Resources asset so its shader variant ships.
    /// </summary>
    public static Material MaterialFor(Color color, SurfaceKind kind, Texture2D texture = null, Vector2? tiling = null)
    {
        if (texture == null) texture = DefaultTexture(kind);
        Vector2 scale = tiling ?? Vector2.one;
        var key = new MaterialKey(color, kind, texture != null ? texture.GetInstanceID() : 0, scale);
        if (materials.TryGetValue(key, out Material cached)) return cached;

        Material material;
        switch (kind)
        {
            case SurfaceKind.Glass: material = new Material(GlassMaterial()); break;
            case SurfaceKind.Emissive: material = new Material(EmissiveMaterial()); break;
            default: material = new Material(BaseMaterial()); break;
        }
        material.name = $"Hq {kind} {ColorUtility.ToHtmlStringRGB(color)}";
        Apply(material, color, kind, texture, scale);
        materials[key] = material;
        return material;
    }

    static Texture2D DefaultTexture(SurfaceKind kind)
    {
        switch (kind)
        {
            case SurfaceKind.Wood: return ProceduralTextures.Wood();
            case SurfaceKind.Metal: return ProceduralTextures.BrushedMetal();
            case SurfaceKind.Fabric: return ProceduralTextures.Fabric();
            default: return null;
        }
    }

    static void Apply(Material m, Color color, SurfaceKind kind, Texture2D texture, Vector2 tiling)
    {
        float smoothness = 0.25f, metallic = 0f;
        switch (kind)
        {
            case SurfaceKind.Glossy: smoothness = 0.8f; metallic = 0.05f; break;
            // Without a reflection probe a fully metallic surface goes almost black, so stay moderate.
            case SurfaceKind.Metal: smoothness = 0.65f; metallic = 0.55f; break;
            case SurfaceKind.Wood: smoothness = 0.45f; break;
            case SurfaceKind.Fabric: smoothness = 0.08f; break;
            case SurfaceKind.Emissive: smoothness = 0.5f; break;
            case SurfaceKind.Glass: smoothness = 0.95f; break;
        }

        Color baseColor = kind == SurfaceKind.Glass ? WithAlpha(color, color.a < 0.99f ? color.a : 0.35f) : color;
        if (m.HasProperty("_BaseColor")) m.SetColor("_BaseColor", baseColor);
        if (m.HasProperty("_Color")) m.SetColor("_Color", baseColor);
        if (m.HasProperty("_Smoothness")) m.SetFloat("_Smoothness", smoothness);
        if (m.HasProperty("_Glossiness")) m.SetFloat("_Glossiness", smoothness);
        if (m.HasProperty("_Metallic")) m.SetFloat("_Metallic", metallic);

        if (texture != null)
        {
            if (m.HasProperty("_BaseMap"))
            {
                m.SetTexture("_BaseMap", texture);
                m.SetTextureScale("_BaseMap", tiling);
            }
            else if (m.HasProperty("_MainTex"))
            {
                m.SetTexture("_MainTex", texture);
                m.SetTextureScale("_MainTex", tiling);
            }
        }

        if (kind == SurfaceKind.Emissive)
        {
            ConfigureEmissive(m, color * 1.4f);
            // The screen texture carries the lit pixels; emission is texture * colour.
            if (texture != null && m.HasProperty("_EmissionMap"))
            {
                m.SetTexture("_EmissionMap", texture);
                m.SetTextureScale("_EmissionMap", tiling);
            }
        }
        else if (kind == SurfaceKind.Glass)
        {
            ConfigureGlass(m);
        }
    }

    /// <summary>Turns on URP/Lit emission (also used by the Editor setup on the Resources asset).</summary>
    public static void ConfigureEmissive(Material m, Color emission)
    {
        if (m.HasProperty("_EmissionColor")) m.SetColor("_EmissionColor", emission);
        m.EnableKeyword("_EMISSION");
        m.globalIlluminationFlags = MaterialGlobalIlluminationFlags.RealtimeEmissive;
    }

    /// <summary>Alpha-blended transparent URP/Lit setup (also used by the Editor setup on the Resources asset).</summary>
    public static void ConfigureGlass(Material m)
    {
        if (m.HasProperty("_Surface")) m.SetFloat("_Surface", 1f);   // SurfaceType.Transparent
        if (m.HasProperty("_Blend")) m.SetFloat("_Blend", 0f);       // BlendMode.Alpha
        if (m.HasProperty("_SrcBlend")) m.SetFloat("_SrcBlend", (float)BlendMode.SrcAlpha);
        if (m.HasProperty("_DstBlend")) m.SetFloat("_DstBlend", (float)BlendMode.OneMinusSrcAlpha);
        if (m.HasProperty("_SrcBlendAlpha")) m.SetFloat("_SrcBlendAlpha", (float)BlendMode.One);
        if (m.HasProperty("_DstBlendAlpha")) m.SetFloat("_DstBlendAlpha", (float)BlendMode.OneMinusSrcAlpha);
        if (m.HasProperty("_ZWrite")) m.SetFloat("_ZWrite", 0f);
        if (m.HasProperty("_AlphaClip")) m.SetFloat("_AlphaClip", 0f);
        m.SetOverrideTag("RenderType", "Transparent");
        m.EnableKeyword("_SURFACE_TYPE_TRANSPARENT");
        m.DisableKeyword("_ALPHATEST_ON");
        m.DisableKeyword("_ALPHAPREMULTIPLY_ON");
        m.renderQueue = (int)RenderQueue.Transparent;
    }

    // The default primitive material (URP Lit when a URP asset is active) is always shipped in
    // the build, whereas a shader found only via Shader.Find may be stripped. Prefer the former.
    static Material BaseMaterial()
    {
        if (baseMaterial != null) return baseMaterial;
        // Material asset created by AgentHQSetup: being a real asset under Resources/, its shader
        // is guaranteed to survive build-time shader stripping.
        Material fromResources = Resources.Load<Material>("AgentHQ/HqLit");
        if (fromResources != null && fromResources.shader != null && fromResources.shader.isSupported)
        {
            baseMaterial = fromResources;
            return baseMaterial;
        }
        var probe = GameObject.CreatePrimitive(PrimitiveType.Cube);
        probe.SetActive(false);
        Material shared = probe.GetComponent<Renderer>().sharedMaterial;
        Object.Destroy(probe);
        if (shared != null && shared.shader != null)
        {
            baseMaterial = shared;
            return baseMaterial;
        }
        Shader shader = Shader.Find("Universal Render Pipeline/Lit");
        if (shader == null) shader = Shader.Find("Universal Render Pipeline/Unlit");
        if (shader == null) shader = Shader.Find("Standard");
        baseMaterial = new Material(shader);
        return baseMaterial;
    }

    // Resources assets whose keywords (_EMISSION, _SURFACE_TYPE_TRANSPARENT) keep those shader
    // variants in the build. Fall back to the plain Lit material when the setup step has not run.
    static Material EmissiveMaterial()
    {
        if (emissiveMaterial != null) return emissiveMaterial;
        Material fromResources = Resources.Load<Material>("AgentHQ/HqEmissive");
        emissiveMaterial = fromResources != null && fromResources.shader != null && fromResources.shader.isSupported
            ? fromResources
            : BaseMaterial();
        return emissiveMaterial;
    }

    static Material GlassMaterial()
    {
        if (glassMaterial != null) return glassMaterial;
        Material fromResources = Resources.Load<Material>("AgentHQ/HqGlass");
        glassMaterial = fromResources != null && fromResources.shader != null && fromResources.shader.isSupported
            ? fromResources
            : BaseMaterial();
        return glassMaterial;
    }

    /// <summary>Backward compatible overload (matte surface).</summary>
    public static GameObject Primitive(PrimitiveType type, Transform parent, string name, Vector3 localPosition,
        Vector3 localScale, Color color, bool keepCollider)
    {
        return Primitive(type, parent, name, localPosition, localScale, color, SurfaceKind.Matte, keepCollider);
    }

    public static GameObject Primitive(PrimitiveType type, Transform parent, string name, Vector3 localPosition,
        Vector3 localScale, Color color, SurfaceKind kind = SurfaceKind.Matte, bool keepCollider = true,
        Texture2D texture = null, Vector2? tiling = null)
    {
        var go = GameObject.CreatePrimitive(type);
        go.name = name;
        go.transform.SetParent(parent, false);
        go.transform.localPosition = localPosition;
        go.transform.localScale = localScale;
        var renderer = go.GetComponent<Renderer>();
        renderer.sharedMaterial = MaterialFor(color, kind, texture, tiling);
        // Transparent and self-lit parts are decoration: skip their shadow pass.
        if (kind == SurfaceKind.Glass || kind == SurfaceKind.Emissive) renderer.shadowCastingMode = ShadowCastingMode.Off;
        if (!keepCollider)
        {
            Collider collider = go.GetComponent<Collider>();
            if (collider != null) Object.Destroy(collider);
        }
        return go;
    }

    /// <summary>World-space label that always faces the camera. Text height is roughly characterSize * fontSize / 10 units.</summary>
    public static TextMesh Label(Transform parent, string name, string text, Vector3 localPosition, float characterSize,
        Color color, TextAnchor anchor = TextAnchor.MiddleCenter)
    {
        var go = new GameObject(name);
        go.transform.SetParent(parent, false);
        go.transform.localPosition = localPosition;
        var mesh = go.AddComponent<TextMesh>();
        Font font = BuiltinFont();
        if (font != null)
        {
            mesh.font = font;
            go.GetComponent<MeshRenderer>().sharedMaterial = TextMaterial(font);
        }
        mesh.text = text;
        mesh.fontSize = 50;
        mesh.characterSize = characterSize;
        mesh.anchor = anchor;
        mesh.alignment = TextAlignment.Center;
        mesh.color = color;
        go.GetComponent<MeshRenderer>().shadowCastingMode = ShadowCastingMode.Off;
        go.AddComponent<Billboard>();
        return mesh;
    }

    static Material textMaterial;

    // The font's own material uses GUI/Text Shader from unity_builtin_extra, which can be stripped
    // from the player; HqText.mat (a Resources asset created by AgentHQSetup) pins that shader.
    static Material TextMaterial(Font font)
    {
        if (textMaterial != null) return textMaterial;
        Material pinned = Resources.Load<Material>("AgentHQ/HqText");
        if (pinned == null || pinned.shader == null || !pinned.shader.isSupported)
        {
            textMaterial = font.material;
            return textMaterial;
        }
        textMaterial = new Material(pinned) { mainTexture = font.material.mainTexture };
        return textMaterial;
    }

    static Font BuiltinFont()
    {
        if (builtinFont != null) return builtinFont;
        try
        {
            builtinFont = Resources.GetBuiltinResource<Font>("LegacyRuntime.ttf");
        }
        catch (System.Exception)
        {
            builtinFont = null;
        }
        if (builtinFont == null)
        {
            try
            {
                builtinFont = Resources.GetBuiltinResource<Font>("Arial.ttf");
            }
            catch (System.Exception)
            {
                builtinFont = null;
            }
        }
        return builtinFont;
    }
}
