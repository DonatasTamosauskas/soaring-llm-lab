
using UnityEngine;
using System.Collections.Generic;

namespace Soaring.GameLoop
{
    /// <summary>
    /// Manages flock: spawns prey/predator birds, maintains Agar loop, provides world bounds.
    /// Wire single instance in scene; auto-creates pool at runtime.
    /// </summary>
    public class BirdManager : MonoBehaviour
    {
        [Header("Prefabs")]
        public BirdAgent preyPrefab;
        public BirdAgent predatorPrefab;
        public bool autoCreateFallbackPrefabs = true;

        [Header("Counts")]
        public int preyCount = 28;
        public int predatorCount = 8;
        public float respawnDelay = 3f;

        [Header("World")]
        public Bounds worldBounds = new Bounds(Vector3.zero, new Vector3(220, 90, 220));
        public Vector2 heightRange = new Vector2(6f, 42f);

        List<BirdAgent> pool = new();
        List<BirdAgent> active = new();
        Transform poolParent;

        void Awake()
        {
            poolParent = new GameObject("BirdPool").transform;
            poolParent.SetParent(transform);
            if (autoCreateFallbackPrefabs && (!preyPrefab || !predatorPrefab)) CreateFallbackPrefabs();
        }

        void Start()
        {
            for(int i=0;i<preyCount;i++) SpawnOne(true);
            for(int i=0;i<predatorCount;i++) SpawnOne(false);
        }

        void CreateFallbackPrefabs()
        {
            BirdAgent Make(Faction f, Color c, float scale)
            {
                var go = new GameObject(f==Faction.Prey?"PreyFallback":"PredatorFallback");
                go.tag = "Bird";
                var mf = go.AddComponent<MeshFilter>(); mf.mesh = CreateBirdMesh();
                var mr = go.AddComponent<MeshRenderer>(); mr.sharedMaterial = new Material(Shader.Find("Universal Render Pipeline/Lit")){ color=c };
                go.AddComponent<SphereCollider>().isTrigger=true; 
                var gr = go.AddComponent<BirdGrowth>(); gr.startScale = scale;
                var ag = go.AddComponent<BirdAgent>(); ag.faction = (BirdFaction)f; ag.baseScale=scale;
                go.SetActive(false);
                return ag;
            }
            if(!preyPrefab) preyPrefab = Make(Faction.Prey, new Color(0.9f,0.8f,0.45f), 0.65f);
            if(!predatorPrefab) predatorPrefab = Make(Faction.Predator, new Color(0.78f,0.22f,0.22f), 1.5f);
            // don't save as asset; runtime only is fine for rapid iteration
        }
        enum Faction{ Prey, Predator }
        Mesh CreateBirdMesh()
        {
            // simple low-poly bird: capsule-like via primitive
            var m = new Mesh();
            m.vertices = new Vector3[]{ new Vector3(0,0,0.6f), new Vector3(0,0,-0.6f), new Vector3(-0.35f,0,0), new Vector3(0.35f,0,0), new Vector3(0,0.18f,0)};
            m.triangles = new int[]{0,2,4, 0,4,3, 1,4,2, 1,3,4, 0,3,1, 0,1,2};
            m.RecalculateNormals(); return m;
        }

        void SpawnOne(bool isPrey)
        {
            BirdAgent pref = isPrey ? preyPrefab : predatorPrefab;
            BirdAgent a;
            // try pool
            for(int i=pool.Count-1;i>=0;i--) if(!pool[i].gameObject.activeSelf && pool[i].faction == (isPrey?BirdFaction.Prey:BirdFaction.Predator)) { a=pool[i]; pool.RemoveAt(i); goto reuse; }
            a = Instantiate(pref, poolParent);
            reuse:
            a.transform.position = RandomPos();
            a.gameObject.SetActive(true);
            active.Add(a);
        }

        Vector3 RandomPos()
        {
            Vector3 p = worldBounds.center + new Vector3(Random.Range(-worldBounds.extents.x, worldBounds.extents.x)*0.85f, 0, Random.Range(-worldBounds.extents.z, worldBounds.extents.z)*0.85f);
            p.y = Random.Range(heightRange.x, heightRange.y);
            return p;
        }

        public void ReturnToPool(BirdAgent agent)
        {
            agent.gameObject.SetActive(false);
            active.Remove(agent);
            pool.Add(agent);
            // respawn after delay elsewhere
            Invoke(nameof(RespawnOne), respawnDelay);
        }

        void RespawnOne()
        {
            // balance: keep counts
            int preyAlive = 0, predAlive=0;
            foreach(var a in active){ if(a.faction==BirdFaction.Prey) preyAlive++; else predAlive++; }
            if(preyAlive < preyCount) SpawnOne(true);
            else if(predAlive < predatorCount) SpawnOne(false);
            else SpawnOne(Random.value<0.75f);
        }

        void OnDrawGizmosSelected(){ Gizmos.color=new Color(0.4f,0.8f,1f,0.18f); Gizmos.DrawCube(worldBounds.center, worldBounds.size); Gizmos.color=Color.cyan; Gizmos.DrawWireCube(worldBounds.center, worldBounds.size); }
    }
}
