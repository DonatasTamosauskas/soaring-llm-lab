using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

namespace Soaring
{
    public static class PlayerWingArt
    {
        // Layered swept feathers, combined by colour: three draws per tracked wing.
        public static Transform Create(Transform hand, int side, Material navy, Material teal, Material ivory)
        {
            var pivot = new GameObject("Layered flight feathers").transform;
            pivot.SetParent(hand, false);
            pivot.localScale = Vector3.one * .58f;
            var groups = new[] { new List<CombineInstance>(), new List<CombineInstance>(), new List<CombineInstance>() };
            for (int i = 0; i < 8; i++)
            {
                float angle = side * (i * 6 - 18);
                var pose = Matrix4x4.TRS(new Vector3(side * (.015f + i * .040f), -.012f + i * .002f, .065f - i * .006f), Quaternion.Euler(0, angle, side * -5), Vector3.one);
                float length = .30f - i * .013f;
                groups[0].Add(new CombineInstance { mesh = Feather(.063f, length, 0, .73f), transform = pose });
                groups[2].Add(new CombineInstance { mesh = Feather(.063f, length, .73f, 1), transform = pose });
                var covert = Matrix4x4.TRS(new Vector3(side * (.005f + i * .040f), .008f, .06f), Quaternion.Euler(0, angle, 0), Vector3.one);
                groups[1].Add(new CombineInstance { mesh = Feather(.060f, length * .45f, 0, 1), transform = covert });
            }
            var materials = new[] { navy, teal, ivory };
            for (int i = 0; i < groups.Length; i++)
            {
                var go = new GameObject(i == 0 ? "Primary feathers" : i == 1 ? "Teal coverts" : "Ivory feather tips");
                go.transform.SetParent(pivot, false);
                var combined = new Mesh { name = go.name };
                combined.CombineMeshes(groups[i].ToArray(), true, true);
                go.AddComponent<MeshFilter>().sharedMesh = combined;
                var r = go.AddComponent<MeshRenderer>(); r.sharedMaterial = materials[i]; r.shadowCastingMode = ShadowCastingMode.Off;
                foreach (var piece in groups[i]) Object.Destroy(piece.mesh);
            }
            return pivot;
        }

        static Mesh Feather(float width, float length, float start, float end)
        {
            var outline = new[] {
                new Vector3(-width * .42f * (1-start*.95f),0,length*start),
                new Vector3(width * .42f * (1-start*.95f),0,length*start),
                new Vector3(width * .42f * (1-end*.95f),0,length*end),
                new Vector3(-width * .42f * (1-end*.95f),0,length*end),
                new Vector3(0,.013f,length*(start+end)*.5f),
                new Vector3(0,-.007f,length*(start+end)*.5f)
            };
            var faces = new[] { 0,4,1,1,4,2,2,4,3,3,4,0,1,5,0,2,5,1,3,5,2,0,5,3 };
            var vertices = new Vector3[faces.Length]; var indices = new int[faces.Length];
            for(int i=0;i<faces.Length;i++){ vertices[i]=outline[faces[i]]; indices[i]=i; }
            var mesh = new Mesh { vertices = vertices, triangles = indices };
            mesh.RecalculateNormals(); return mesh;
        }
    }
}
