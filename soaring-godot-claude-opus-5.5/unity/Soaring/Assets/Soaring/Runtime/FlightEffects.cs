using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;
namespace Soaring
{
    public sealed class FlightEffects : MonoBehaviour
    {
        public GameSession game; public PlayerFlight player; public VRInput input; public Ecosystem ecosystem; public SoaringContent content;
        Mesh ring, triangle, feather, wingMesh; Material edible, danger, feathers, comfort, wingMaterial; Matrix4x4[] rings = new Matrix4x4[144], triangles = new Matrix4x4[144], featherMatrices = new Matrix4x4[96];
        struct Flake
        {
            public Vector3 position, velocity; public Quaternion rotation; public float life, span;
        }
        Flake[] flakes = new Flake[96]; int flakeIndex; MeshRenderer comfortRenderer; MaterialPropertyBlock comfortBlock; float vignette;
        MeshRenderer wingsRenderer; Vector3[] wingVertices; Vector3[] wingNormals; Color[] wingColors; Color[] speciesColors; TrailRenderer[] trails;
        public void Initialize()
        {
            comfortBlock = new MaterialPropertyBlock();
            speciesColors = new Color[10];
            for (int i = 0; i < 10; i++)
            {
                var colors = content.species[i].lods[0].colors;
                speciesColors[i] = colors.Length > 0 ? colors[0] : Color.gray;
            }
            trails = new TrailRenderer[2];
            for (int i = 0; i < 2; i++)
            {
                var trail = new GameObject("Wingtip trail").AddComponent<TrailRenderer>();
                trail.transform.SetParent(transform);
                trail.time = .3f;
                trail.minVertexDistance = .02f;
                trail.sharedMaterial = content.particleMaterial;
                trail.startColor = new Color(.8f, .9f, 1, .16f);
                trail.endColor = new Color(.8f, .9f, 1, 0);
                trail.emitting = false;
                trails[i] = trail;
            }

            edible = new Material(content.markerMaterial) { color = new Color(.25f, .14f, 1) };
            danger = new Material(content.markerMaterial) { color = new Color(1, 0, .6f) };
            feathers = new Material(content.markerMaterial) { color = new Color(.92f, .88f, .7f) };
            ring = Marker(false);
            triangle = Marker(true);
            feather = new Mesh();
            feather.vertices = new[] { new Vector3(-.13f, 0, 0), new Vector3(.13f, 0, 0), new Vector3(0, .8f, 0) };
            feather.triangles = new[] { 0, 1, 2, 2, 1, 0 };
            feather.RecalculateNormals();
            var veil = new GameObject("Comfort vignette", typeof(MeshFilter), typeof(MeshRenderer));
            veil.transform.SetParent(input.eye.transform, false);
            veil.transform.localPosition = Vector3.forward * .1f;
            var quad = new Mesh { name = "Comfort screen" };
            quad.vertices = new[] { new Vector3(-1, -1, 0), new Vector3(1, -1, 0), new Vector3(1, 1, 0), new Vector3(-1, 1, 0) };
            quad.uv = new[] { Vector2.zero, Vector2.right, Vector2.one, Vector2.up };
            quad.triangles = new[] { 0, 1, 2, 0, 2, 3 };
            quad.bounds = new Bounds(Vector3.zero, Vector3.one * 10000);
            veil.GetComponent<MeshFilter>().mesh = quad;
            comfortRenderer = veil.GetComponent<MeshRenderer>();
            comfort = new Material(content.comfortMaterial);
            comfortRenderer.sharedMaterial = comfort;
            comfortRenderer.shadowCastingMode = ShadowCastingMode.Off;
            var wingObject = new GameObject("Your feathered wings", typeof(MeshFilter), typeof(MeshRenderer));
            wingObject.transform.SetParent(input.leftHand.parent, false);
            wingMesh = new Mesh { name = "Tracked wings" };
            wingMesh.MarkDynamic();
            wingVertices = new Vector3[2 * 12 * 6];
            wingNormals = new Vector3[wingVertices.Length];
            wingColors = new Color[wingVertices.Length];
            var indices = new int[wingVertices.Length * 2];
            for (int i = 0; i < wingVertices.Length; i += 3)
            {
                int j = i * 2;
                indices[j] = i;
                indices[j + 1] = i + 1;
                indices[j + 2] = i + 2;
                indices[j + 3] = i + 2;
                indices[j + 4] = i + 1;
                indices[j + 5] = i;
            }
            wingMesh.vertices = wingVertices;
            wingMesh.triangles = indices;
            wingObject.GetComponent<MeshFilter>().sharedMesh = wingMesh;
            wingsRenderer = wingObject.GetComponent<MeshRenderer>();
            wingMaterial = new Material(content.valleyPrefab.GetComponentInChildren<MeshRenderer>().sharedMaterial);
            wingsRenderer.sharedMaterial = wingMaterial;
            wingsRenderer.shadowCastingMode = ShadowCastingMode.Off;
            foreach (var thermal in content.thermals)
            {
                var motes = new GameObject("Thermal pollen " + thermal.name).AddComponent<ParticleSystem>();
                motes.transform.SetParent(transform);
                motes.transform.position = thermal.position;
                var main = motes.main;
                main.startLifetime = 15;
                main.startSpeed = 1.7f;
                main.startSize = .065f;
                main.maxParticles = 60;
                main.startColor = new Color(.96f, .91f, .55f, .6f);
                main.simulationSpace = ParticleSystemSimulationSpace.World;
                var emission = motes.emission;
                emission.rateOverTime = 4;
                var shape = motes.shape;
                shape.shapeType = ParticleSystemShapeType.Circle;
                shape.radius = thermal.radius * .7f;
                shape.rotation = new Vector3(-90, 0, 0);
                var renderer = motes.GetComponent<ParticleSystemRenderer>();
                renderer.sharedMaterial = content.particleMaterial;
                renderer.shadowCastingMode = ShadowCastingMode.Off;
                motes.Play();
            }
        }
        static Mesh Marker(bool danger)
        {
            var vs = new List<Vector3>();
            var ts = new List<int>();
            int sides = danger ? 3 : 24;
            for (int i = 0; i < sides; i++)
            {
                float a = i * Mathf.PI * 2 / sides + Mathf.PI / 2, b = (i + 1) * Mathf.PI * 2 / sides + Mathf.PI / 2;
                int j = vs.Count;
                vs.Add(new(Mathf.Cos(a), Mathf.Sin(a), 0));
                vs.Add(new(Mathf.Cos(b), Mathf.Sin(b), 0));
                vs.Add(new(Mathf.Cos(a) * .82f, Mathf.Sin(a) * .82f, 0));
                vs.Add(new(Mathf.Cos(b) * .82f, Mathf.Sin(b) * .82f, 0));
                ts.AddRange(new[] { j, j + 1, j + 2, j + 2, j + 1, j + 3, j + 2, j + 1, j, j + 3, j + 1, j + 2 });
            }
            var mesh = new Mesh();
            mesh.SetVertices(vs);
            mesh.SetTriangles(ts, 0);
            mesh.RecalculateBounds();
            return mesh;
        }
        public void Burst(Vector3 position, float span)
        {
            for (int i = 0; i < 18; i++)
            {
                int j = flakeIndex++ % flakes.Length;
                flakes[j] = new()
                {
                    position = position,
                    velocity = Random.onUnitSphere * span * 2 + Vector3.up * span,
                    rotation = Random.rotation,
                    life = 1.4f,
                    span = span * .15f
                };
            }
        }
        void LateUpdate()
        {
            if (!ring)
                return;
            float dt = Time.unscaledDeltaTime;
            int rc = 0, tc = 0, fc = 0;
            bool fly = game.phase == GamePhase.Flying;
            if (fly)
                foreach (var b in ecosystem.birds)
                {
                    if (!b.alive || b.hidden)
                        continue;
                    float distance = Vector3.Distance(input.eye.transform.position, b.position);
                    bool edibleBird = SizeRules.Worthwhile(player.model.mass, b.mass), dangerBird = SizeRules.CanEat(b.mass, player.model.mass);
                    if (!edibleBird && !dangerBird || distance > 160)
                        continue;
                    float radius = Mathf.Max(b.Span * .6f, distance * .006f);
                    var rotation = Quaternion.LookRotation((b.position - input.eye.transform.position).normalized);
                    var matrix = Matrix4x4.TRS(b.position, rotation, Vector3.one * radius);
                    if (edibleBird)
                        rings[rc++] = matrix;
                    else
                        triangles[tc++] = matrix;
                }
            for (int i = 0; i < flakes.Length; i++)
            {
                if (flakes[i].life <= 0)
                    continue;
                if (fly)
                {
                    flakes[i].life -= dt;
                    flakes[i].velocity += Vector3.down * dt * .5f;
                    flakes[i].position += flakes[i].velocity * dt;
                }
                featherMatrices[fc++] = Matrix4x4.TRS(flakes[i].position, flakes[i].rotation, Vector3.one * flakes[i].span * Mathf.Clamp01(flakes[i].life));
            }
            if (rc > 0)
                Graphics.DrawMeshInstanced(ring, 0, edible, rings, rc, null, ShadowCastingMode.Off, false);
            if (tc > 0)
                Graphics.DrawMeshInstanced(triangle, 0, danger, triangles, tc, null, ShadowCastingMode.Off, false);
            if (fc > 0)
                Graphics.DrawMeshInstanced(feather, 0, feathers, featherMatrices, fc, null, ShadowCastingMode.Off, false);
            float speed = player.model.airspeed / SizeRules.Cruise(player.model.mass), turn = Mathf.Abs(player.model.turnRate) * Mathf.Rad2Deg;
            float target = fly ? input.preferences.comfort * Mathf.Max(SizeRules.Smooth(.9f, 2.3f, speed), SizeRules.Smooth(30, 150, turn)) : 0;
            vignette = Mathf.Lerp(vignette, target, 1 - Mathf.Exp(-dt / .18f));
            comfortBlock.SetFloat("_Strength", vignette);
            comfortRenderer.SetPropertyBlock(comfortBlock);
            comfortRenderer.enabled = vignette > .005f;
            for (int i = 0; i < 2; i++)
            {
                var hand = i == 0 ? input.leftHand : input.rightHand;
                trails[i].transform.position = hand.position;
                trails[i].startWidth = player.Span * .008f;
                trails[i].endWidth = 0;
                trails[i].emitting = fly && speed > 1.3f;
            }
            UpdateWings();
        }
        void UpdateWings()
        {
            wingsRenderer.enabled = game.phase == GamePhase.Flying;
            if (!wingsRenderer.enabled)
                return;
            int tier = SizeRules.Tier(player.model.mass);
            Color color = speciesColors[tier];
            int index = 0;
            var lateral = Vector3.ProjectOnPlane(input.rightHand.localPosition - input.leftHand.localPosition, Vector3.up).normalized;
            if (lateral.sqrMagnitude < .01f)
                lateral = Vector3.right;
            var bodyForward = Vector3.Cross(lateral, Vector3.up);
            for (int side = -1; side <= 1; side += 2)
            {
                var hand = side < 0 ? input.leftHand : input.rightHand;
                var shoulder = input.eye.transform.localPosition + lateral * (side * .17f) + Vector3.down * .2f - bodyForward * .05f;
                var tip = hand.localPosition;
                var axis = tip - shoulder;
                var backwards = Vector3.ProjectOnPlane(hand.localRotation * Vector3.back, axis).normalized;
                if (backwards.sqrMagnitude < .01f)
                    backwards = Vector3.ProjectOnPlane(-bodyForward, axis).normalized;
                for (int featherIndex = 0; featherIndex < 12; featherIndex++)
                {
                    float a = featherIndex / 12f, b = (featherIndex + 1) / 12f;
                    var p = Vector3.Lerp(shoulder, tip, a);
                    var q = Vector3.Lerp(shoulder, tip, b);
                    float length = .11f + .23f * Mathf.Sin(a * Mathf.PI * .75f);
                    var tail = p + backwards * length;
                    var tail2 = q + backwards * (length * .97f);
                    wingVertices[index] = p;
                    wingVertices[index + 1] = q;
                    wingVertices[index + 2] = tail;
                    wingVertices[index + 3] = tail;
                    wingVertices[index + 4] = q;
                    wingVertices[index + 5] = tail2;
                    var normal = Vector3.Cross(q - p, tail - p).normalized;
                    for (int j = 0; j < 6; j++)
                    {
                        wingNormals[index + j] = normal;
                        wingColors[index + j] = color * (.8f + .2f * a);
                        wingColors[index + j].a = 0;
                    }
                    index += 6;
                }
            }
            wingMesh.vertices = wingVertices;
            wingMesh.normals = wingNormals;
            wingMesh.colors = wingColors;
            wingMesh.RecalculateBounds();
        }
        void OnDestroy()
        {
            foreach (var m in new[] { edible, danger, feathers, comfort, wingMaterial })
                if (m)
                    Destroy(m);
            foreach (var m in new[] { ring, triangle, feather, wingMesh })
                if (m)
                    Destroy(m);
        }
    }
}
