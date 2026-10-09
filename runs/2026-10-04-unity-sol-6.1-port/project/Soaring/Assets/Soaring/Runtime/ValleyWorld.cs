using UnityEngine;
using System.Collections.Generic;
namespace Soaring
{
    public sealed class ValleyWorld : MonoBehaviour
    {
        public const int SolidMask = 1 << 8; public SoaringContent content;
        public float Ground(Vector3 position)
        {
            int n = content.heightMapSize;
            if (content.heights == null || n < 2)
                return -1;
            float x = Mathf.Clamp((position.x + 760) / 4, 0, n - 1.001f), z = Mathf.Clamp((position.z + 760) / 4, 0, n - 1.001f);
            int ix = (int)x, iz = (int)z;
            return Mathf.Lerp(Mathf.Lerp(content.heights[iz * n + ix], content.heights[iz * n + ix + 1], x - ix), Mathf.Lerp(content.heights[(iz + 1) * n + ix], content.heights[(iz + 1) * n + ix + 1], x - ix), z - iz);
        }
        static readonly Vector2[] river = { new(190, 578), new(181, 520), new(160, 450), new(140, 390), new(122, 320), new(98, 230), new(66, 130), new(48, 40), new(47, -30), new(62, -95), new(95, -150), new(122, -186) };
        public bool Water(Vector3 p)
        {
            float x = p.x - 228, z = -p.z - 228, c = Mathf.Cos(.35f), s = Mathf.Sin(.35f), u = (x * c + z * s) / 132, v = (-x * s + z * c) / 98;
            if (u * u + v * v < 1)
                return true;
            Vector2 q = new(p.x, p.z);
            for (int i = 0; i < river.Length - 1; i++)
            {
                var a = river[i];
                var ab = river[i + 1] - a;
                float t = Mathf.Clamp01(Vector2.Dot(q - a, ab) / ab.sqrMagnitude);
                if ((q - a - ab * t).sqrMagnitude < 36)
                    return true;
            }
            return false;
        }

        public Vector3 Wind(Vector3 p, float time)
        {
            var w = new Vector3(-2.6f, 0, -.45f) * (1 + .1f * Mathf.Sin(time * .57f) + .05f * Mathf.Sin(time * 1.46f + 1.3f)) * Mathf.Clamp(.4f + p.y * .02f, .4f, 1);
            for (int i = 0; i < content.thermals.Length; i++)
            {
                var t = content.thermals[i];
                float height = p.y - t.position.y;
                if (height < 0 || p.y > t.top)
                    continue;
                var centre = t.position + t.lean * height + new Vector3(11 * Mathf.Sin(time * (.041f + .006f * i) + i), 0, 11 * Mathf.Cos(time * (.033f + .005f * i) + i));
                float r2 = new Vector2(p.x - centre.x, p.z - centre.z).sqrMagnitude / (t.radius * t.radius);
                if (r2 < 1)
                    w.y += t.strength * (1 + .11f * Mathf.Sin(time * (.11f + .013f * i))) * Mathf.Pow(1 - r2, 2) * SizeRules.Smooth(0, 8, height) * (1 - SizeRules.Smooth(t.top - 35, t.top, p.y));
            }
            // Windward west escarpment and the north gorge supply ridge lift.
            if (p.z > -270 && p.z < 75 && p.x > -465 && p.x < -410 && p.y < 105)
                w.y += 3.7f * Mathf.Exp(-Mathf.Pow((p.x + 447) / 23, 2)) * SizeRules.Smooth(3, 22, p.y) * (1 - SizeRules.Smooth(75, 105, p.y));
            if (p.z > 320 && p.z < 580 && Mathf.Abs(p.x - (122 + (p.z - 320) * .26f)) < 60 && p.y < 135)
                w.y += 2.4f * (1 - SizeRules.Smooth(95, 135, p.y));
            float radius = new Vector2(p.x, p.z).magnitude;
            if (radius > content.bounds - 45)
                w -= new Vector3(p.x, 0, p.z).normalized * 6 * SizeRules.Smooth(content.bounds - 45, content.bounds, radius);
            w.y *= 1 - SizeRules.Smooth(content.ceiling - 45, content.ceiling - 5, p.y);
            return w;
        }
        Dictionary<Vector2Int, List<Refuge>> refugeCells;
        void IndexRefuges()
        {
            refugeCells = new();
            foreach (var r in content.refuges)
            {
                int x0 = Mathf.FloorToInt((r.position.x - r.radius) / 32), x1 = Mathf.FloorToInt((r.position.x + r.radius) / 32), z0 = Mathf.FloorToInt((r.position.z - r.radius) / 32), z1 = Mathf.FloorToInt((r.position.z + r.radius) / 32);
                for (int x = x0; x <= x1; x++)
                    for (int z = z0; z <= z1; z++)
                    {
                        var key = new Vector2Int(x, z);
                        if (!refugeCells.TryGetValue(key, out var list))
                            refugeCells[key] = list = new();
                        list.Add(r);
                    }
            }
        }
        public bool Protected(Vector3 p, float predatorSpan)
        {
            if (refugeCells == null)
                IndexRefuges();
            if (!refugeCells.TryGetValue(new Vector2Int(Mathf.FloorToInt(p.x / 32), Mathf.FloorToInt(p.z / 32)), out var refuges))
                return false;
            foreach (var r in refuges)
                if (predatorSpan > r.maxSpan && (p - r.position).sqrMagnitude < r.radius * r.radius)
                    return true;
            return false;
        }
        public Perch NearestPerch(Vector3 p, float span, float distance, bool free = true)
        {
            Perch best = null;
            float bestD = distance * distance;
            foreach (var perch in content.perches)
            {
                if (perch.maxSpan < span || (free && perch.occupant != null && perch.occupant.alive))
                    continue;
                float d = (perch.position - p).sqrMagnitude;
                if (d < bestD)
                {
                    best = perch;
                    bestD = d;
                }
            }
            return best;
        }
        public Refuge NearestRefuge(Vector3 p, float span)
        {
            Refuge best = default;
            float distance = float.MaxValue;
            foreach (var r in content.refuges)
            {
                if (r.maxSpan < span)
                    continue;
                float d = (r.position - p).sqrMagnitude;
                if (d < distance)
                {
                    distance = d;
                    best = r;
                }
            }
            return best;
        }
        public bool Clear(Vector3 from, Vector3 to, float radius) => !Physics.SphereCast(from, Mathf.Max(.01f, radius), (to - from).normalized, out _, Vector3.Distance(from, to), SolidMask, QueryTriggerInteraction.Ignore);
    }
}
