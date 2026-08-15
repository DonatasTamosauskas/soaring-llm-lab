
using UnityEngine;

namespace Soaring.World
{
    /// <summary>
    /// Procedurally populates perches, poles, buildings with ledges, tree branches, windows.
    /// Tiled city/park generator for acrobatic flight. Lightweight, no external deps, URP only.
    /// Call Generate() to rebuild.
    /// </summary>
    [ExecuteInEditMode]
    public class WorldBuilder : MonoBehaviour
    {
        [Header("World Size")]
        public Vector2 size = new Vector2(220,220);
        public int treeCount = 36;
        public int poleCount = 22;
        public int buildingCount = 14;
        public int perchBranchCount = 28;

        [Header("Prefabs / Materials (auto if null)")]
        public Material groundMat;
        public Material barkMat;
        public Material leafMat;
        public Material perchMat;
        public Material buildingMat;
        public Material windowMat;
        public PhysicsMaterial perchPhysMat;

        [Header("Options")]
        public int seed = 42;
        public bool clearOnGenerate = true;
        public LayerMask perchLayerValue; // will assign layer Perch if exists, else Default

        Transform generatedRoot;

        [ContextMenu("Generate")]
        public void Generate()
        {
            Random.State st = Random.state;
            Random.InitState(seed);
            if (clearOnGenerate) Clear();
            generatedRoot = new GameObject("GeneratedWorld").transform;
            generatedRoot.SetParent(transform);

            EnsureMaterials();

            // ground
            var ground = GameObject.CreatePrimitive(PrimitiveType.Plane);
            ground.name = "Ground";
            ground.transform.SetParent(generatedRoot);
            ground.transform.localScale = new Vector3(size.x/10f, 1, size.y/10f);
            ground.transform.position = Vector3.zero;
            ground.GetComponent<MeshRenderer>().sharedMaterial = groundMat;
            // large box collider for flight
            // Perch layer
            int perchLayer = LayerMask.NameToLayer("Perch");
            if (perchLayer == -1) perchLayer = 0;

            // Trees with perch branches
            for(int i=0;i<treeCount;i++)
            {
                Vector3 p = RandGroundPos(pad:10);
                CreateTree(p, perchLayer);
            }
            // Electric poles with wires + perches
            for(int i=0;i<poleCount;i++)
            {
                Vector3 p = RandGroundPos(pad:6);
                CreatePole(p, perchLayer);
            }
            // Buildings with window ledges
            for(int i=0;i<buildingCount;i++)
            {
                Vector3 p = RandGroundPos(pad:18);
                CreateBuilding(p, perchLayer);
            }
            // Extra floating perches (branches) for acrobatics
            for(int i=0;i<perchBranchCount;i++)
            {
                Vector3 p = RandGroundPos(pad:8) + Vector3.up * Random.Range(8f, 28f);
                CreateFloatingPerch(p, perchLayer);
            }

            Random.state = st;
            Debug.Log($"[WorldBuilder] Generated {treeCount} trees, {poleCount} poles, {buildingCount} buildings, {perchBranchCount} perches");
        }

        Vector3 RandGroundPos(float pad)
        {
            return new Vector3(Random.Range(-size.x*0.5f+pad, size.x*0.5f-pad), 0, Random.Range(-size.y*0.5f+pad, size.y*0.5f-pad));
        }

        void CreateTree(Vector3 pos, int layer)
        {
            var root = new GameObject($"Tree_{pos.x:F0}_{pos.z:F0}");
            root.transform.SetParent(generatedRoot);
            root.transform.position = pos;
            float h = Random.Range(8f, 18f);
            float r = Random.Range(0.35f, 0.62f);

            // trunk
            var trunk = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
            trunk.name="Trunk";
            trunk.transform.SetParent(root.transform);
            trunk.transform.localPosition = new Vector3(0,h*0.5f,0);
            trunk.transform.localScale = new Vector3(r*2, h*0.5f, r*2);
            trunk.GetComponent<MeshRenderer>().sharedMaterial = barkMat;
            DestroyImmediate(trunk.GetComponent<CapsuleCollider>()); // cylinder has Capsule?
            var tc = trunk.AddComponent<CapsuleCollider>();
            trunk.layer = layer; trunk.tag="Perch"; trunk.AddComponent<Perch>().isPerchable=true;

            // canopy (two spheres)
            for(int j=0;j<2;j++){
                var canopy = GameObject.CreatePrimitive(PrimitiveType.Sphere);
                canopy.name="Canopy";
                canopy.transform.SetParent(root.transform);
                canopy.transform.localPosition = new Vector3(Random.Range(-1f,1f), h-1.5f + Random.Range(0,2f), Random.Range(-1f,1f));
                canopy.transform.localScale = Vector3.one * Random.Range(4f,7f);
                canopy.GetComponent<MeshRenderer>().sharedMaterial = leafMat;
                DestroyImmediate(canopy.GetComponent<SphereCollider>());
                canopy.AddComponent<SphereCollider>().isTrigger=false;
            }
            // perch branches (horizontal cylinders)
            int branches = Random.Range(2,4);
            for(int b=0;b<branches;b++){
                float bh = Random.Range(h*0.45f, h*0.88f);
                float len = Random.Range(2.2f, 4f);
                var br = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
                br.name="Branch";
                br.transform.SetParent(root.transform);
                br.transform.localPosition = new Vector3(0,bh,0);
                br.transform.localRotation = Quaternion.Euler(0, Random.Range(0,360f), 90f);
                br.transform.localScale = new Vector3(0.14f, len*0.5f, 0.14f);
                br.GetComponent<MeshRenderer>().sharedMaterial = barkMat;
                br.layer=layer; br.tag="Perch"; br.AddComponent<Perch>().isPerchable=true;
                // capsule collider oriented Y - rotated 90 makes it horizontal; capsule collider will be wrong - replace with box
                DestroyImmediate(br.GetComponent<CapsuleCollider>());
                var bc = br.AddComponent<BoxCollider>();
                bc.size = new Vector3(0.7f, 2f, 0.7f);
                if(perchPhysMat) bc.material = perchPhysMat;
            }
        }

        void CreatePole(Vector3 pos, int layer)
        {
            var root = new GameObject($"Pole_{pos.x:F0}");
            root.transform.SetParent(generatedRoot);
            root.transform.position = pos;
            float h = Random.Range(9f, 14f);
            var pole = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
            pole.name="Pole";
            pole.transform.SetParent(root.transform);
            pole.transform.localPosition = new Vector3(0,h*0.5f,0);
            pole.transform.localScale = new Vector3(0.18f, h*0.5f, 0.18f);
            pole.GetComponent<MeshRenderer>().sharedMaterial = barkMat;
            DestroyImmediate(pole.GetComponent<CapsuleCollider>());
            pole.AddComponent<BoxCollider>();
            pole.layer=layer; pole.tag="Perch"; pole.AddComponent<Perch>().isPerchable=true;
            // crossbeam
            var beam = GameObject.CreatePrimitive(PrimitiveType.Cube);
            beam.name="Crossbeam";
            beam.transform.SetParent(root.transform);
            beam.transform.localPosition = new Vector3(0,h-0.6f,0);
            beam.transform.localScale = new Vector3(3.2f,0.15f,0.18f);
            beam.GetComponent<MeshRenderer>().sharedMaterial = buildingMat;
            beam.layer=layer; beam.tag="Perch"; beam.AddComponent<Perch>().isPerchable=true;
            // wires (thin cubes between poles - fake)
            // Perch stubs on top
        }

        void CreateBuilding(Vector3 pos, int layer)
        {
            var root = new GameObject($"Building_{pos.x:F0}_{pos.z:F0}");
            root.transform.SetParent(generatedRoot);
            root.transform.position = pos;
            float w = Random.Range(9f, 18f);
            float d = Random.Range(9f, 16f);
            float h = Random.Range(12f, 32f);
            var b = GameObject.CreatePrimitive(PrimitiveType.Cube);
            b.name="Block";
            b.transform.SetParent(root.transform);
            b.transform.localPosition = new Vector3(0,h*0.5f,0);
            b.transform.localScale = new Vector3(w,h,d);
            b.GetComponent<MeshRenderer>().sharedMaterial = buildingMat;
            b.layer=0;
            // window ledges around sides at intervals
            for(int floor=1; floor< h/3f; floor++){
                float y = floor*3f + 0.35f;
                foreach(var side in new[]{(Vector3.forward, 0f), (Vector3.back,180f), (Vector3.left,90f), (Vector3.right,270f)}){
                    var ledge = GameObject.CreatePrimitive(PrimitiveType.Cube);
                    ledge.name=$"Ledge_{floor}_{side.Item2}";
                    ledge.transform.SetParent(root.transform);
                    Vector3 dir = side.Item1;
                    Vector3 off = dir * ( (Mathf.Abs(dir.x)>0.5f? w:d)*0.5f + 0.28f);
                    ledge.transform.localPosition = off + Vector3.up*y;
                    ledge.transform.localRotation = Quaternion.Euler(0, side.Item2, 0);
                    ledge.transform.localScale = new Vector3(Mathf.Abs(dir.z)>0.5f? w*0.7f: d*0.7f, 0.12f, 0.55f);
                    var r = ledge.GetComponent<MeshRenderer>(); r.sharedMaterial = perchMat;
                    ledge.layer=layer; ledge.tag="Perch"; ledge.AddComponent<Perch>().isPerchable=true;
                    ledge.GetComponent<BoxCollider>().material = perchPhysMat;
                    // small window plane visual
                    var win = GameObject.CreatePrimitive(PrimitiveType.Quad);
                    win.name="Window";
                    win.transform.SetParent(root.transform);
                    win.transform.localPosition = dir * ((Mathf.Abs(dir.x)>0.5f? w:d)*0.5f+0.01f) + Vector3.up*(y+0.7f);
                    win.transform.localRotation = Quaternion.LookRotation(-dir);
                    win.transform.localScale = new Vector3(1.8f,1.3f,1);
                    win.GetComponent<MeshRenderer>().sharedMaterial = windowMat;
                }
            }
        }

        void CreateFloatingPerch(Vector3 pos, int layer)
        {
            var go = GameObject.CreatePrimitive(PrimitiveType.Cylinder);
            go.name="FloatingBranch";
            go.transform.SetParent(generatedRoot);
            go.transform.position = pos;
            go.transform.rotation = Quaternion.Euler(Random.Range(80,100), Random.Range(0,360f), Random.Range(-12,12));
            go.transform.localScale = new Vector3(0.18f, Random.Range(1.5f,3f), 0.18f);
            go.GetComponent<MeshRenderer>().sharedMaterial = barkMat;
            DestroyImmediate(go.GetComponent<CapsuleCollider>());
            var bc = go.AddComponent<BoxCollider>(); bc.material = perchPhysMat;
            go.layer=layer; go.tag="Perch"; go.AddComponent<Perch>().isPerchable=true;
        }

        void EnsureMaterials()
        {
            Shader lit = Shader.Find("Universal Render Pipeline/Lit");
            if(!groundMat){ groundMat = new Material(lit); groundMat.color = new Color(0.38f,0.52f,0.32f); groundMat.name="GroundMat"; }
            if(!barkMat){ barkMat = new Material(lit); barkMat.color = new Color(0.32f,0.21f,0.13f); barkMat.name="BarkMat"; }
            if(!leafMat){ leafMat = new Material(lit); leafMat.color = new Color(0.18f,0.42f,0.17f); leafMat.name="LeafMat"; }
            if(!perchMat){ perchMat = new Material(lit); perchMat.color = new Color(0.62f,0.58f,0.5f); perchMat.name="PerchMat"; }
            if(!buildingMat){ buildingMat = new Material(lit); buildingMat.color = new Color(0.62f,0.62f,0.64f); buildingMat.name="BuildingMat"; }
            if(!windowMat){ windowMat = new Material(lit); windowMat.color = new Color(0.12f,0.18f,0.32f); windowMat.SetFloat("_Metallic",0.6f); windowMat.SetFloat("_Smoothness",0.8f); windowMat.name="WindowMat"; }
            if(!perchPhysMat){ perchPhysMat = new PhysicsMaterial("Perch"){ staticFriction=1f, dynamicFriction=0.9f, bounciness=0f }; }
        }

        public void Clear()
        {
            if(generatedRoot) DestroyImmediate(generatedRoot.gameObject);
            // find stale
            var stale = GameObject.Find("GeneratedWorld");
            if(stale) DestroyImmediate(stale);
            // clean older
            for(int i=transform.childCount-1;i>=0;i--) if(transform.GetChild(i).name=="GeneratedWorld") DestroyImmediate(transform.GetChild(i).gameObject);
        }
    }

    public class Perch : MonoBehaviour
    {
        public bool isPerchable = true;
        public float perchRadius = 0.9f;
        void Reset(){ gameObject.tag="Perch"; }
    }
}
