using UnityEngine;
namespace Soaring
{
    public static class CurvedPanelGeometry
    {
        public static Vector3 Bend(Vector3 flat, float radius)
        {
            float angle = flat.x / radius;
            return new(radius * Mathf.Sin(angle), flat.y, flat.z + radius * (Mathf.Cos(angle) - 1));
        }
        // Circle centre is at the viewer, one radius behind the panel centre.
        // Returns both the rendered surface and its unwrapped layout coordinate.
        public static bool Hit(Ray ray, float radius, out Vector2 flat, out Vector3 surface)
        {
            flat = default; surface = default;
            var o = ray.origin + Vector3.forward * radius;
            var d = ray.direction;
            float a = d.x * d.x + d.z * d.z;
            if (a < 1e-8f) return false;
            float b = 2 * (o.x * d.x + o.z * d.z), c = o.x * o.x + o.z * o.z - radius * radius;
            float disc = b * b - 4 * a * c;
            if (disc < 0) return false;
            float root = Mathf.Sqrt(disc), t0 = (-b - root) / (2 * a), t1 = (-b + root) / (2 * a);
            float t = t0 > .001f ? t0 : t1;
            if (t <= .001f) return false;
            surface = ray.GetPoint(t);
            float angle = Mathf.Atan2(surface.x, surface.z + radius);
            if (Mathf.Abs(angle) > Mathf.PI * .5f) return false;
            flat = new(angle * radius, surface.y);
            return true;
        }
    }
}
