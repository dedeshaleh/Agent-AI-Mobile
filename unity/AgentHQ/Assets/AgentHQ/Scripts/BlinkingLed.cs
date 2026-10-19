using UnityEngine;

/// <summary>
/// Swaps a renderer between two shared materials (lit/unlit) on a fixed period. Swapping shared
/// materials keeps the SRP batcher happy and allocates nothing per frame.
/// </summary>
public class BlinkingLed : MonoBehaviour
{
    Renderer target;
    Material on, off;
    float period = 1f, offset;
    bool lit = true;

    public void Configure(Material onMaterial, Material offMaterial, float blinkPeriod, float phaseOffset)
    {
        target = GetComponent<Renderer>();
        on = onMaterial;
        off = offMaterial;
        period = Mathf.Max(0.05f, blinkPeriod);
        offset = phaseOffset;
    }

    void Update()
    {
        if (target == null) return;
        bool shouldBeLit = Mathf.Repeat(Time.time + offset, period) < period * 0.6f;
        if (shouldBeLit == lit) return;
        lit = shouldBeLit;
        target.sharedMaterial = lit ? on : off;
    }
}
