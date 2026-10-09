using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
namespace Soaring.Editor
{
    // Bake static compound shapes into spatial triangle meshes. Gameplay uses
    // swept spheres, so it needs no Rigidbody on scenery or convex cooking at runtime.
    static class CollisionBaker
    {
        sealed class Chunk
        {
            public List<Vector3> vertices = new(); public List<int> indices = new(); public Dictionary<Vector3, int> lookup = new();
            public void Add(Vector3 a, Vector3 b, Vector3 c)
            {
                foreach (var p in new[] { a, b, c })
                {
                    if (!lookup.TryGetValue(p, out int i))
                    {
                        i = vertices.Count;
                        vertices.Add(p);
                        lookup[p] = i;
                    }
                    indices.Add(i);
                }
            }
        }
        static Dictionary<Vector2Int, Chunk> chunks;
        public static void Begin() => chunks = new();
        public static void Add(Mesh mesh, Matrix4x4 matrix)
        {
            var vs = mesh.vertices;
            var ts = mesh.triangles;
            for (int i = 0; i < ts.Length; i += 3)
            {
                var a = matrix.MultiplyPoint3x4(vs[ts[i]]);
                var b = matrix.MultiplyPoint3x4(vs[ts[i + 1]]);
                var c = matrix.MultiplyPoint3x4(vs[ts[i + 2]]);
                AddTriangle(a, b, c);
            }
        }
        static void AddTriangle(Vector3 a, Vector3 b, Vector3 c)
        {
            // Tessellate huge original ground/boundary triangles before spatial
            // partitioning; otherwise a centroid chunk still spans the valley.
            float ab = (a - b).sqrMagnitude, bc = (b - c).sqrMagnitude, ca = (c - a).sqrMagnitude;
            if (Mathf.Max(ab, bc, ca) > 64 * 64)
            {
                if (ab >= bc && ab >= ca)
                {
                    var m = (a + b) * .5f;
                    AddTriangle(a, m, c);
                    AddTriangle(m, b, c);
                }
                else if (bc >= ca)
                {
                    var m = (b + c) * .5f;
                    AddTriangle(a, b, m);
                    AddTriangle(a, m, c);
                }
                else
                {
                    var m = (c + a) * .5f;
                    AddTriangle(a, b, m);
                    AddTriangle(m, b, c);
                }
                return;
            }
            var centre = (a + b + c) / 3;
            var key = new Vector2Int(Mathf.FloorToInt(centre.x / 64), Mathf.FloorToInt(centre.z / 64));
            if (!chunks.TryGetValue(key, out var chunk))
                chunks[key] = chunk = new();
            chunk.Add(a, b, c);
        }
        public static List<Mesh> Finish()
        {
            var result = new List<Mesh>();
            foreach (var pair in chunks)
            {
                var mesh = new Mesh { name = "Collision " + pair.Key, indexFormat = IndexFormat.UInt32 };
                mesh.SetVertices(pair.Value.vertices);
                mesh.SetTriangles(pair.Value.indices, 0);
                mesh.RecalculateBounds();
                result.Add(mesh);
            }
            chunks = null;
            return result;
        }
        public static Mesh Capsule(float radius, float height)
        {
            const int sides = 8, segments = 6;
            var vs = new List<Vector3>();
            var ts = new List<int>();
            float half = Mathf.Max(0, height / 2 - radius);
            radius /= Mathf.Cos(Mathf.PI / sides);
            for (int y = 0; y <= segments; y++)
            {
                float a = -Mathf.PI / 2 + Mathf.PI * y / segments;
                float r = Mathf.Cos(a) * radius, h = Mathf.Sin(a) * radius + (y <= segments / 2 ? -half : half);
                for (int i = 0; i < sides; i++)
                {
                    float p = i * Mathf.PI * 2 / sides;
                    vs.Add(new(Mathf.Cos(p) * r, h, Mathf.Sin(p) * r));
                }
            }
            for (int y = 0; y < segments; y++)
                for (int i = 0; i < sides; i++)
                {
                    int a = y * sides + i, b = y * sides + (i + 1) % sides, c = a + sides, d = b + sides;
                    ts.AddRange(new[] { a, c, b, b, c, d });
                }
            var mesh = new Mesh();
            mesh.SetVertices(vs);
            mesh.SetTriangles(ts, 0);
            return mesh;
        }
        struct Face
        {
            public int a, b, c; public Face(int a, int b, int c)
            {
                this.a = a;
                this.b = b;
                this.c = c;
            }
        }
        public static Mesh Hull(Vector3[] vs)
        {
            int a = 0, b = 1, c = 2, d = 3;
            float far = -1;
            for (int i = 1; i < vs.Length; i++)
            {
                float dist = (vs[i] - vs[a]).sqrMagnitude;
                if (dist > far)
                {
                    b = i;
                    far = dist;
                }
            }
            far = -1;
            for (int i = 0; i < vs.Length; i++)
            {
                float dist = Vector3.Cross(vs[b] - vs[a], vs[i] - vs[a]).sqrMagnitude;
                if (dist > far)
                {
                    c = i;
                    far = dist;
                }
            }
            Vector3 normal = Vector3.Cross(vs[b] - vs[a], vs[c] - vs[a]);
            far = -1;
            for (int i = 0; i < vs.Length; i++)
            {
                float dist = Mathf.Abs(Vector3.Dot(normal, vs[i] - vs[a]));
                if (dist > far)
                {
                    d = i;
                    far = dist;
                }
            }
            Vector3 inside = (vs[a] + vs[b] + vs[c] + vs[d]) / 4;
            var faces = new List<Face>();
            void AddFace(int x, int y, int z)
            {
                if (Vector3.Dot(Vector3.Cross(vs[y] - vs[x], vs[z] - vs[x]), inside - vs[x]) > 0)
                    (y, z) = (z, y);
                faces.Add(new(x, y, z));
            }
            AddFace(a, b, c);
            AddFace(a, d, b);
            AddFace(b, d, c);
            AddFace(c, d, a);
            for (int p = 0; p < vs.Length; p++)
            {
                if (p == a || p == b || p == c || p == d)
                    continue;
                var edges = new List<(int, int)>();
                void Edge(int x, int y)
                {
                    int reverse = edges.FindIndex(e => e.Item1 == y && e.Item2 == x);
                    if (reverse >= 0)
                        edges.RemoveAt(reverse);
                    else
                        edges.Add((x, y));
                }
                for (int f = faces.Count - 1; f >= 0; f--)
                {
                    var face = faces[f];
                    var n = Vector3.Cross(vs[face.b] - vs[face.a], vs[face.c] - vs[face.a]);
                    if (Vector3.Dot(n, vs[p] - vs[face.a]) <= 1e-6f * n.magnitude)
                        continue;
                    Edge(face.a, face.b);
                    Edge(face.b, face.c);
                    Edge(face.c, face.a);
                    faces.RemoveAt(f);
                }
                foreach (var edge in edges)
                    AddFace(edge.Item1, edge.Item2, p);
            }
            var triangles = new List<int>();
            foreach (var face in faces)
                triangles.AddRange(new[] { face.a, face.b, face.c });
            var mesh = new Mesh();
            mesh.vertices = vs;
            mesh.SetTriangles(triangles, 0);
            return mesh;
        }
    }
}
