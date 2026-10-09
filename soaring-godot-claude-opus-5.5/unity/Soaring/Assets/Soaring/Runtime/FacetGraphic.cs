using UnityEngine;
using UnityEngine.UI;
namespace Soaring
{
    public sealed class FacetGraphic : MaskableGraphic
    {
        public float cut = 14, border;
        public Color edge = new(1, .79f, .3f, 1);
        public bool facets;
        void Polygon(VertexHelper vh, Rect r, Color tint)
        {
            float k = Mathf.Min(cut, Mathf.Min(r.width, r.height) * .2f);
            var points = new Vector2[] { new(r.xMin+k,r.yMin),new(r.xMax-k,r.yMin),new(r.xMax,r.yMin+k),new(r.xMax,r.yMax-k),new(r.xMax-k,r.yMax),new(r.xMin+k,r.yMax),new(r.xMin,r.yMax-k),new(r.xMin,r.yMin+k) };
            int start = vh.currentVertCount;
            vh.AddVert(r.center, tint, Vector2.zero);
            foreach (var p in points) vh.AddVert(p, tint, Vector2.zero);
            for (int i = 0; i < 8; i++) vh.AddTriangle(start, start + 1 + i, start + 1 + (i + 1) % 8);
        }
        protected override void OnPopulateMesh(VertexHelper vh)
        {
            vh.Clear(); var r = rectTransform.rect;
            if (border > 0) Polygon(vh, r, edge);
            r.xMin += border; r.xMax -= border; r.yMin += border; r.yMax -= border;
            Polygon(vh, r, color);
            if (facets)
            {
                int start = vh.currentVertCount;
                Color light = Color.Lerp(color, Color.white, .025f);
                vh.AddVert(new Vector3(r.xMin + cut, r.yMax), light, Vector2.zero);
                vh.AddVert(new Vector3(r.xMax - cut, r.yMax), light, Vector2.zero);
                vh.AddVert(new Vector3(r.xMax, r.yMax - cut), light, Vector2.zero);
                vh.AddVert(new Vector3(r.xMin, r.yMin + r.height * .28f), light, Vector2.zero);
                vh.AddTriangle(start,start+1,start+2); vh.AddTriangle(start,start+2,start+3);
            }
        }
    }
}
