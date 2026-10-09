using System;
using UnityEngine;
namespace Soaring
{
    public static class CatchRule
    {
        public static float ContactDistance(float predatorMass, float preyMass, bool player, float assist = 0, bool preyPlayer = false)
        {
            float span = SizeRules.Span(predatorMass), radii = .16f * (span + SizeRules.Span(preyMass));
            float reach = player ? span * 2 / Mathf.Sqrt(SizeRules.TimeScale(predatorMass)) * (1 + 1.25f * assist) : span * (preyPlayer ? .15f : .25f);
            return player ? Mathf.Min(radii + reach, 2.9f * span) : radii + reach;
        }
        // All roots of reach, overlap and aim-cone inequalities partition a frame.
        // Testing their intervals catches even fast crossing or late cone entry.
        public static float ContactTime(Vector3 p0, Vector3 p1, Vector3 q0, Vector3 q1, float reach, float overlap, Vector3 forward, Vector3 velocityDirection, float coneDegrees, bool useVelocity = true)
        {
            Vector3 d = q0 - p0, dv = q1 - q0 - (p1 - p0);
            double a = dv.sqrMagnitude, hb = Vector3.Dot(d, dv), cc = d.sqrMagnitude - reach * reach;
            float lo = 0, hi = 1;
            if (a < 1e-12)
            {
                if (cc > 0)
                    return -1;
            }
            else
            {
                double disc = hb * hb - a * cc;
                if (disc < 0)
                    return -1;
                double root = Math.Sqrt(disc);
                lo = (float)Math.Max(0, (-hb - root) / a);
                hi = (float)Math.Min(1, (-hb + root) / a);
                if (lo > hi)
                    return -1;
            }
            Span<float> roots = stackalloc float[20];
            int n = 0;
            roots[n++] = lo;
            roots[n++] = hi;
            if (overlap > 0)
                AddRoots(a, 2 * hb, d.sqrMagnitude - overlap * overlap, lo, hi, roots, ref n);
            double cosine = Math.Max(0, Math.Cos(coneDegrees * Math.PI / 180));
            int axes = useVelocity && velocityDirection.sqrMagnitude > .01f ? 2 : 1;
            for (int i = 0; i < axes; i++)
            {
                var f = i == 0 ? forward : velocityDirection;
                double u0 = Vector3.Dot(f, d), u1 = Vector3.Dot(f, dv), k = cosine * cosine;
                AddRoots(u1 * u1 - k * a, 2 * (u0 * u1 - k * hb), u0 * u0 - k * d.sqrMagnitude, lo, hi, roots, ref n);
                if (Math.Abs(u1) > 1e-12)
                {
                    float t = (float)(-u0 / u1);
                    if (t > lo && t < hi)
                        roots[n++] = t;
                }
            }
            for (int i = 1; i < n; i++)
            {
                float value = roots[i];
                int j = i - 1;
                while (j >= 0 && roots[j] > value)
                {
                    roots[j + 1] = roots[j];
                    j--;
                }
                roots[j + 1] = value;
            }
            for (int i = 0; i < n; i++)
            {
                if (Aimed(d + dv * roots[i], overlap, forward, velocityDirection, (float)cosine, axes == 2))
                    return roots[i];
                if (i + 1 < n && Aimed(d + dv * ((roots[i] + roots[i + 1]) * .5f), overlap, forward, velocityDirection, (float)cosine, axes == 2))
                    return roots[i];
            }
            return -1;
        }
        static bool Aimed(Vector3 d, float overlap, Vector3 f, Vector3 v, float cosine, bool useVelocity)
        {
            float distance = d.magnitude;
            if (overlap > 0 && distance <= overlap)
                return true;
            float limit = cosine * distance - 1e-7f;
            return Vector3.Dot(f, d) >= limit || (useVelocity && Vector3.Dot(v, d) >= limit);
        }
        static void AddRoots(double a, double b, double c, float lo, float hi, Span<float> roots, ref int count)
        {
            if (Math.Abs(a) < 1e-12)
            {
                if (Math.Abs(b) > 1e-12)
                    Add((float)(-c / b), lo, hi, roots, ref count);
                return;
            }
            double disc = b * b - 4 * a * c;
            if (disc < 0)
                return;
            double s = Math.Sqrt(disc);
            Add((float)((-b - s) / (2 * a)), lo, hi, roots, ref count);
            Add((float)((-b + s) / (2 * a)), lo, hi, roots, ref count);
        }
        static void Add(float t, float lo, float hi, Span<float> roots, ref int count)
        {
            if (t > lo && t < hi && count < roots.Length)
                roots[count++] = t;
        }
    }
}
