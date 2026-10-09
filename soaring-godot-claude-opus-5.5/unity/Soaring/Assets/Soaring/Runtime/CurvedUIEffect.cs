using System.Collections.Generic;
using UnityEngine;
using UnityEngine.UI;
namespace Soaring
{
    // Curves native uGUI glyphs and artwork without an extra render texture,
    // camera, or per-frame CPU rebuild. Pointer hits use the same geometry.
    public sealed class CurvedUIEffect : BaseMeshEffect
    {
        public RectTransform root;
        public float radius = 1500;
        readonly List<UIVertex> source = new();
        UIVertex At(UIVertex a, UIVertex b, UIVertex c, float u, float v)
        {
            var q = UIVertex.simpleVert;
            q.position = a.position + (b.position - a.position) * u + (c.position - a.position) * v;
            q.uv0 = a.uv0 + (b.uv0 - a.uv0) * u + (c.uv0 - a.uv0) * v;
            q.color = (Color)a.color * (1 - u - v) + (Color)b.color * u + (Color)c.color * v;
            var flat = root.InverseTransformPoint(transform.TransformPoint(q.position));
            q.position = transform.InverseTransformPoint(root.TransformPoint(CurvedPanelGeometry.Bend(flat, radius)));
            return q;
        }
        void Triangle(VertexHelper vh, UIVertex a, UIVertex b, UIVertex c)
        {
            int start = vh.currentVertCount;
            vh.AddVert(a); vh.AddVert(b); vh.AddVert(c);
            vh.AddTriangle(start, start + 1, start + 2);
        }
        public override void ModifyMesh(VertexHelper vh)
        {
            if (!IsActive() || !root) return;
            source.Clear(); vh.GetUIVertexStream(source); vh.Clear();
            for (int i = 0; i < source.Count; i += 3)
            {
                var a = source[i]; var b = source[i + 1]; var c = source[i + 2];
                float ax = root.InverseTransformPoint(transform.TransformPoint(a.position)).x;
                float bx = root.InverseTransformPoint(transform.TransformPoint(b.position)).x;
                float cx = root.InverseTransformPoint(transform.TransformPoint(c.position)).x;
                int n = Mathf.Clamp(Mathf.CeilToInt((Mathf.Max(ax, bx, cx) - Mathf.Min(ax, bx, cx)) / 64), 1, 24);
                for (int row = 0; row < n; row++)
                    for (int col = 0; col < n - row; col++)
                    {
                        float u = row / (float)n, v = col / (float)n, step = 1f / n;
                        Triangle(vh, At(a, b, c, u, v), At(a, b, c, u + step, v), At(a, b, c, u, v + step));
                        if (col < n - row - 1)
                            Triangle(vh, At(a, b, c, u + step, v), At(a, b, c, u + step, v + step), At(a, b, c, u, v + step));
                    }
            }
        }
    }
}
