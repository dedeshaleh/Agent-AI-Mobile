using UnityEngine;

/// <summary>Keeps a label or speech bubble parallel to the camera plane.</summary>
public class Billboard : MonoBehaviour
{
    Camera cam;

    void LateUpdate()
    {
        if (cam == null) cam = Camera.main;
        if (cam != null) transform.rotation = cam.transform.rotation;
    }
}
