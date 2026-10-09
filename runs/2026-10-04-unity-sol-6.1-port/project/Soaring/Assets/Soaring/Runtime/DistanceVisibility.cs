using UnityEngine;
namespace Soaring
{
    public sealed class DistanceVisibility : MonoBehaviour
    {
        public float near, far; public Renderer target; float next;
        void Update()
        {
            if (Time.unscaledTime < next)
                return;
            next = Time.unscaledTime + .25f;
            var cam = Camera.main;
            if (!cam)
                return;
            float d = Vector3.Distance(cam.transform.position, target.bounds.ClosestPoint(cam.transform.position));
            target.enabled = (near <= 0 || d >= near) && (far <= 0 || d < far);
        }
    }
}
