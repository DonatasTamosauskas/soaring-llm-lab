using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.Rendering;
namespace Soaring.Editor
{
    [Serializable]
    class MeshRecord
    {
        public string file; public int vertices, triangles;
    }
    [Serializable]
    class InstanceRecord
    {
        public float[] matrix, color;
    }
    [Serializable]
    class NodeRecord
    {
        public string name; public int mesh; public float[] matrix; public float near, far; public bool water, foliage, soft, shadowOnly, castsShadow; public InstanceRecord[] instances;
    }
    [Serializable]
    class ColliderRecord
    {
        public string name, type; public int mesh; public float[] matrix, data;
    }
    [Serializable]
    class PerchRecord
    {
        public float[] position, facing; public int kind; public float maxSpan; public string district;
    }
    [Serializable]
    class LandmarkRecord
    {
        public string name, kind; public float[] position; public float radius;
    }
    [Serializable]
    class RefugeRecord
    {
        public float[] position; public float radius, maxSpan;
    }
    [Serializable]
    class ThermalRecord
    {
        public string name; public float[] position, lean; public float radius, strength, top;
    }
    [Serializable]
    class BirdRecord
    {
        public string id, name; public float mass, span; public int[] meshes;
    }
    [Serializable]
    class ExportRecord
    {
        public int version, seed; public float bounds, ceiling; public float[] spawn, facing; public MeshRecord[] meshes; public NodeRecord[] nodes; public ColliderRecord[] colliders; public PerchRecord[] perches; public LandmarkRecord[] landmarks; public RefugeRecord[] refuges; public ThermalRecord[] thermals; public BirdRecord[] birds;
    }
    public static class SourceImporter
    {
        const string Source = "Assets/Soaring/Data/FrozenWorld.zip", Generated = "Assets/Soaring/Generated";
        static Vector3 V(float[] v) => new(v[0], v[1], v[2]);
        static Matrix4x4 M(float[] a)
        {
            var m = new Matrix4x4();
            for (int i = 0; i < 16; i++)
                m[i] = a[i];
            return m;
        }
        static T Save<T>(T obj, string path) where T : UnityEngine.Object
        {
            obj.name = Path.GetFileNameWithoutExtension(path);
            var old = AssetDatabase.LoadAssetAtPath<T>(path);
            if (old)
            {
                EditorUtility.CopySerialized(obj, old);
                UnityEngine.Object.DestroyImmediate(obj);
                EditorUtility.SetDirty(old);
                return old;
            }
            AssetDatabase.CreateAsset(obj, path);
            return obj;
        }
        public static void Import()
        {
            using var archive = ZipFile.OpenRead(Source);
            using var manifest = new StreamReader(archive.GetEntry("world.json").Open());
            var doc = JsonUtility.FromJson<ExportRecord>(manifest.ReadToEnd());
            if (doc.version < 1 || doc.version > 2 || doc.colliders.Length == 0)
                throw new InvalidDataException("Incomplete Godot export; no collision data.");
            Directory.CreateDirectory(Generated + "/Meshes");
            Directory.CreateDirectory(Generated + "/Materials");
            Directory.CreateDirectory("Assets/Soaring/Resources");
            AssetDatabase.Refresh();
            var visualIds = new HashSet<int>(doc.nodes.Select(n => n.mesh).Concat(doc.birds.SelectMany(b => b.meshes)));
            var birdIds = new HashSet<int>(doc.birds.SelectMany(b => b.meshes));
            var meshes = new Mesh[doc.meshes.Length];
            AssetDatabase.StartAssetEditing();
            try
            {
                for (int id = 0; id < meshes.Length; id++)
                {
                    var mesh = ReadMesh(archive.GetEntry(doc.meshes[id].file).Open(), birdIds.Contains(id));
                    meshes[id] = visualIds.Contains(id) ? Save(mesh, Generated + "/Meshes/" + id.ToString("D4") + ".asset") : mesh;
                }
            }
            finally { AssetDatabase.StopAssetEditing(); }
            Material Mat(string name, string shader) => Save(new Material(Shader.Find(shader)) { name = name, enableInstancing = true }, Generated + "/Materials/" + name + ".mat");
            var solid = Mat("Valley", "Soaring/Valley");
            solid.SetFloat("_Sway", 0);
            EditorUtility.SetDirty(solid);
            var water = Mat("Water", "Soaring/Water");
            var foliage = Mat("Foliage", "Soaring/Valley");
            foliage.SetFloat("_Sway", .12f);
            EditorUtility.SetDirty(foliage);
            var bird = Mat("Bird", "Soaring/Bird");
            var marker = Mat("Marker", "Universal Render Pipeline/Unlit");
            var root = new GameObject("Soaring Valley");
            var visuals = new GameObject("Visuals").transform;
            visuals.SetParent(root.transform, false);
            foreach (var node in doc.nodes)
            {
                bool castsShadow = doc.version >= 2 ? node.castsShadow : ShadowPolicy.CastsScenery(node.name);
                if (node.instances != null && node.instances.Length > 0)
                {
                    var groups = new Dictionary<Vector2Int, List<CombineInstance>>();
                    var tintedMeshes = new List<Mesh>();
                    foreach (var instance in node.instances)
                    {
                        var matrix = M(instance.matrix);
                        var p = matrix.GetColumn(3);
                        var key = new Vector2Int(Mathf.FloorToInt(p.x / 48), Mathf.FloorToInt(p.z / 48));
                        if (!groups.TryGetValue(key, out var list))
                            groups[key] = list = new();
                        var mesh = UnityEngine.Object.Instantiate(meshes[node.mesh]);
                        var colors = mesh.colors;
                        var tint = instance.color != null ? new Color(instance.color[0], instance.color[1], instance.color[2], 1).linear : Color.white;
                        for (int k = 0; k < colors.Length; k++)
                        {
                            float alpha = colors[k].a;
                            colors[k] *= tint;
                            colors[k].a = alpha;
                        }
                        mesh.colors = colors;
                        tintedMeshes.Add(mesh);
                        list.Add(new()
                        {
                            mesh = mesh,
                            transform = matrix
                        });
                    }
                    int c = 0;
                    foreach (var entry in groups)
                    {
                        var mesh = new Mesh { name = node.name + " chunk " + entry.Key, indexFormat = IndexFormat.UInt32 };
                        mesh.CombineMeshes(entry.Value.ToArray(), true, true);
                        mesh = Save(mesh, Generated + "/Meshes/soft_" + node.mesh + "_" + c++ + ".asset");
                        CreateVisual(node.name, mesh, Matrix4x4.identity, foliage, visuals, 0, node.far > 0 ? node.far : 240, node.shadowOnly, castsShadow);
                    }
                    foreach (var mesh in tintedMeshes)
                        UnityEngine.Object.DestroyImmediate(mesh);
                }
                else
                    CreateVisual(node.name, meshes[node.mesh], M(node.matrix), node.water ? water : node.foliage ? foliage : solid, visuals, node.near, node.far, node.shadowOnly, castsShadow);
            }
            var collisions = new GameObject("Collision").transform;
            collisions.SetParent(root.transform, false);
            CollisionBaker.Begin();
            var primitives = new Dictionary<string, Mesh>();
            foreach (var record in doc.colliders)
            {
                Mesh collisionMesh;
                if (record.type == "mesh")
                    collisionMesh = meshes[record.mesh];
                else if (record.type == "convex")
                    collisionMesh = CollisionBaker.Hull(meshes[record.mesh].vertices);
                else
                {
                    string key = record.type + string.Join(",", record.data.Select(v => v.ToString("R", System.Globalization.CultureInfo.InvariantCulture)));
                    if (!primitives.TryGetValue(key, out collisionMesh))
                        primitives[key] = collisionMesh = CollisionBaker.Capsule(record.data[0], record.data.Length > 1 ? record.data[1] : record.data[0] * 2);
                }
                CollisionBaker.Add(collisionMesh, M(record.matrix));
                if (record.type == "convex")
                    UnityEngine.Object.DestroyImmediate(collisionMesh);
            }
            int collisionCount = 0;
            foreach (var mesh in CollisionBaker.Finish())
            {
                var saved = Save(mesh, Generated + "/Meshes/collision_" + collisionCount.ToString("D4") + ".asset");
                var go = new GameObject(saved.name);
                go.layer = 8;
                go.transform.SetParent(collisions, false);
                go.AddComponent<MeshCollider>().sharedMesh = saved;
                collisionCount++;
            }
            foreach (var mesh in primitives.Values)
                UnityEngine.Object.DestroyImmediate(mesh);
            for (int i = 0; i < meshes.Length; i++)
                if (!visualIds.Contains(i))
                    UnityEngine.Object.DestroyImmediate(meshes[i]);
            var prefab = PrefabUtility.SaveAsPrefabAsset(root, Generated + "/Valley.prefab");
            UnityEngine.Object.DestroyImmediate(root);
            var content = ScriptableObject.CreateInstance<SoaringContent>();
            content.valleyPrefab = prefab;
            content.bounds = doc.bounds;
            content.ceiling = doc.ceiling;
            using (var heightReader = new BinaryReader(archive.GetEntry("heightmap.bytes").Open()))
            {
                if (heightReader.ReadInt32() != 0x534f4847)
                    throw new InvalidDataException("Invalid terrain grid");
                content.heightMapSize = heightReader.ReadInt32();
                content.heights = new float[content.heightMapSize * content.heightMapSize];
                for (int i = 0; i < content.heights.Length; i++)
                    content.heights[i] = heightReader.ReadSingle();
            }
            content.spawn = V(doc.spawn);
            content.spawnFacing = V(doc.facing);
            content.birdMaterial = bird;
            content.markerMaterial = marker;
            content.comfortMaterial = Mat("Comfort", "Soaring/Comfort");
            content.particleMaterial = Mat("Pollen", "Universal Render Pipeline/Particles/Unlit");
            content.species = doc.birds.Select(b => new Species(b.id, b.name, b.mass, b.span) { lods = b.meshes.Select(i => meshes[i]).ToArray() }).ToArray();
            content.perches = doc.perches.Select(p => new Perch { position = V(p.position), facing = V(p.facing), kind = p.kind, maxSpan = p.maxSpan, district = p.district }).ToArray();
            content.landmarks = doc.landmarks.Select(l => new Landmark { name = l.name, kind = l.kind, position = V(l.position), radius = l.radius }).ToArray();
            content.refuges = doc.refuges.Select(r => new Refuge { position = V(r.position), radius = r.radius, maxSpan = r.maxSpan }).ToArray();
            content.thermals = doc.thermals.Select(t => new Thermal { name = t.name, position = V(t.position), lean = V(t.lean), radius = t.radius, strength = t.strength, top = t.top }).ToArray();
            Save(content, "Assets/Soaring/Resources/SoaringContent.asset");
            AssetDatabase.SaveAssets();
            Debug.Log($"SOARING_IMPORT_OK meshes={meshes.Length} colliders={collisionCount} perches={doc.perches.Length}");
        }
        static void SetTransform(Transform t, Matrix4x4 m)
        {
            t.localPosition = m.GetColumn(3);
            t.localRotation = m.rotation;
            t.localScale = m.lossyScale;
        }
        static void CreateVisual(string name, Mesh mesh, Matrix4x4 matrix, Material mat, Transform parent, float near, float far, bool shadowOnly, bool castsShadow)
        {
            var go = new GameObject(name);
            go.transform.SetParent(parent, false);
            SetTransform(go.transform, matrix);
            go.isStatic = true;
            go.AddComponent<MeshFilter>().sharedMesh = mesh;
            var renderer = go.AddComponent<MeshRenderer>();
            renderer.sharedMaterial = mat;
            renderer.shadowCastingMode = shadowOnly ? ShadowCastingMode.ShadowsOnly : castsShadow ? ShadowCastingMode.On : ShadowCastingMode.Off;
            renderer.receiveShadows = mat.shader.name == "Soaring/Valley" || mat.shader.name == "Soaring/Water";
            if (near > 0 || far > 0)
            {
                var lod = go.AddComponent<DistanceVisibility>();
                lod.target = renderer;
                lod.near = near;
                lod.far = far;
            }
        }
        static Mesh ReadMesh(Stream stream, bool bird)
        {
            using var reader = new BinaryReader(stream);
            if (reader.ReadInt32() != 0x534f4152)
                throw new InvalidDataException("Corrupt frozen mesh");
            int count = reader.ReadInt32(), indexCount = reader.ReadInt32();
            var positions = new Vector3[count];
            var normals = new Vector3[count];
            var colors = new Color[count];
            var uvs = new List<Vector4>[6];
            for (int i = 0; i < 6; i++)
                uvs[i] = new(count);
            for (int i = 0; i < count; i++)
            {
                positions[i] = new(reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle());
                normals[i] = new(reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle());
                var color = new Color(reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle());
                float alpha = color.a;
                colors[i] = color.linear;
                colors[i].a = alpha;
                for (int j = 0; j < 2; j++)
                    uvs[j].Add(new(reader.ReadSingle(), reader.ReadSingle(), 0, 0));
                for (int j = 2; j < 6; j++)
                    uvs[j].Add(new(reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle(), reader.ReadSingle()));
            }
            var indices = new int[indexCount];
            for (int i = 0; i < indexCount; i++)
                indices[i] = reader.ReadInt32();
            var mesh = new Mesh { name = "Imported mesh", indexFormat = count > 65535 ? IndexFormat.UInt32 : IndexFormat.UInt16 };
            mesh.vertices = positions;
            mesh.normals = normals;
            mesh.colors = colors;
            mesh.triangles = indices;
            if (bird)
            {
                for (int i = 0; i < 6; i++)
                    mesh.SetUVs(i, uvs[i]);
                mesh.bounds = new Bounds(Vector3.zero, new Vector3(1.4f, 1.4f, 1.6f));
            }
            else
                mesh.RecalculateBounds();
            return mesh;
        }
    }
}
