
using UnityEngine;

namespace Soaring.GameLoop
{
    public enum BirdFaction { Prey, Predator, Player }

    /// <summary>
    /// Simple bird agent for the Agar.io loop. Prey < player < predator by scale.
    /// Flocks with boids, flees larger birds, hunts smaller.
    /// Perches occasionally on Perch-tagged objects.
    /// </summary>
    [RequireComponent(typeof(SphereCollider))]
    public class BirdAgent : MonoBehaviour
    {
        [Header("Identity")]
        public BirdFaction faction = BirdFaction.Prey;
        public float baseScale = 0.7f;
        public float scaleVariance = 0.25f;
        public float speed = 7f;
        public float turnRate = 120f;
        public float bobAmp = 0.35f;

        [Header("AI")]
        public float perceptionRadius = 18f;
        public float fleeRadius = 14f;
        public float perchChance = 0.015f;
        public float unperchDelay = 4f;

        BirdGrowth growth;
        Vector3 velocity;
        Vector3 targetVelocity;
        bool perched;
        float perchedTimer;
        Transform perchPoint;
        float bobPhase;

        static Transform player;
        static BirdGrowth playerGrowth;

        void Awake()
        {
            growth = GetComponent<BirdGrowth>();
            GetComponent<SphereCollider>().isTrigger = true;
            GetComponent<SphereCollider>().radius = 0.6f;
            if (growth)
            {
                float s = baseScale + Random.Range(-scaleVariance, scaleVariance);
                if (faction == BirdFaction.Predator) s += 0.5f;
                if (faction == BirdFaction.Prey) s = Mathf.Clamp(s, 0.35f, 0.95f);
                growth.SetScale(s);
                growth.OnEaten += OnEaten;
            }
            velocity = Random.onUnitSphere * speed * 0.5f;
            velocity.y = Mathf.Abs(velocity.y) * 0.5f + 1f;
            bobPhase = Random.Range(0f, Mathf.PI*2f);
            if (!player) { var p = FindFirstObjectByType<Soaring.Flight.BirdFlightController>(); if(p) { player=p.transform; playerGrowth=p.GetComponent<BirdGrowth>(); } }
        }

        void OnEaten()
        {
            // return to pool via manager
            var mgr = FindFirstObjectByType<BirdManager>();
            if (mgr) mgr.ReturnToPool(this);
            else gameObject.SetActive(false);
        }

        void Update()
        {
            float dt = Time.deltaTime;
            if (perched)
            {
                perchedTimer -= dt;
                transform.position = perchPoint ? perchPoint.position + Vector3.up*0.35f : transform.position;
                // look around
                transform.Rotate(0, 10f*dt, 0);
                if (perchedTimer <=0 || ShouldFlee())
                {
                    perched = false;
                    velocity = (Random.onUnitSphere + Vector3.up).normalized * speed;
                }
                return;
            }

            // Seek / flee
            Vector3 accel = Vector3.zero;
            if (ShouldFlee())
            {
                Vector3 away = (transform.position - player.position).normalized;
                targetVelocity = away * speed * 1.6f + Vector3.up * 2f;
                accel = (targetVelocity - velocity) * 3f;
            }
            else if (faction == BirdFaction.Predator && player && playerGrowth && growth.TargetScale > playerGrowth.TargetScale + 0.15f)
            {
                // predator hunts player if larger
                Vector3 toP = player.position - transform.position;
                if (toP.magnitude < perceptionRadius * 1.2f)
                {
                    targetVelocity = toP.normalized * speed * 1.2f;
                    accel = (targetVelocity - velocity) * 2f;
                }
                else accel = Wander();
            }
            else if (faction == BirdFaction.Prey)
            {
                // prey wanders and flees any larger
                // check nearest predator
                var nearestThreat = FindNearestThreat();
                if (nearestThreat)
                {
                    Vector3 away = (transform.position - nearestThreat.position).normalized;
                    targetVelocity = away * speed * 1.4f;
                    accel = (targetVelocity - velocity) * 3f;
                }
                else accel = Wander();
            }
            else accel = Wander();

            // try perch
            if (Random.value < perchChance * dt * 60f && !ShouldFlee())
            {
                TryPerch();
            }

            // gravity vs lift approximation
            accel.y += Mathf.Sin(Time.time * 2.1f + bobPhase) * 1.2f;

            velocity += accel * dt;
            // clamp
            float maxS = speed * (perched?0.1f: ShouldFlee()?1.6f:1f);
            velocity = Vector3.ClampMagnitude(velocity, maxS);
            velocity += -Vector3.up * 1.2f * dt; // gentle sink if not flapping (we fake lift via accel.y)

            transform.position += velocity * dt;
            if (velocity.sqrMagnitude > 0.1f)
            {
                Quaternion look = Quaternion.LookRotation(velocity.normalized, Vector3.up);
                // bank into turn
                float bank = Vector3.SignedAngle(transform.forward, velocity.normalized, Vector3.up);
                look *= Quaternion.Euler(0,0, -Mathf.Clamp(bank, -35f, 35f)*0.5f);
                transform.rotation = Quaternion.Slerp(transform.rotation, look, dt * (turnRate * Mathf.Deg2Rad * 0.6f));
            }
            // world bounds
            Bounds b = FindFirstObjectByType<BirdManager>()?.worldBounds ?? new Bounds(Vector3.zero, Vector3.one*400f);
            if (!b.Contains(transform.position))
            {
                Vector3 toCenter = (b.center - transform.position).normalized;
                velocity = Vector3.Lerp(velocity, toCenter * speed, dt*2f);
            }

            // bob
            transform.position += Vector3.up * Mathf.Sin(Time.time*3f + bobPhase) * bobAmp * dt;
        }

        Vector3 Wander()
        {
            // gentle random walk + boids separation
            Vector3 wander = velocity.normalized * speed;
            wander += Random.insideUnitSphere * 2f;
            // separation from nearby birds
            Collider[] near = Physics.OverlapSphere(transform.position, 4f);
            Vector3 sep = Vector3.zero; int cnt=0;
            foreach(var c in near){ if(c.transform==transform) continue; var ba=c.GetComponent<BirdAgent>(); if(!ba) continue; Vector3 d = transform.position - ba.transform.position; float m=d.magnitude; if(m<0.01f) continue; sep += d.normalized / Mathf.Max(0.2f,m); cnt++; }
            if(cnt>0) { sep/=cnt; wander += sep * 4f; }
            return (wander.normalized * speed - velocity) * 1.2f;
        }

        bool ShouldFlee()
        {
            if (!player || !playerGrowth || !growth) return false;
            float my = growth.TargetScale;
            float theirs = playerGrowth.TargetScale;
            float dist = Vector3.Distance(transform.position, player.position);
            // prey flees player if player larger; predator flees if player larger than predator
            if (my < theirs - 0.05f && dist < fleeRadius) return true;
            // also flee any nearby larger bird
            return false;
        }

        Transform FindNearestThreat()
        {
            Collider[] cols = Physics.OverlapSphere(transform.position, perceptionRadius);
            Transform best=null; float bestD=float.MaxValue;
            foreach(var c in cols){ var g=c.GetComponent<BirdGrowth>(); if(!g) continue; if(g.TargetScale <= growth.TargetScale+0.05f) continue; float d=Vector3.Distance(transform.position, c.transform.position); if(d<bestD){ bestD=d; best=c.transform; } }
            return best;
        }

        void TryPerch()
        {
            Collider[] hits = Physics.OverlapSphere(transform.position, 14f);
            Transform best=null; float bd=float.MaxValue;
            foreach(var h in hits){ if(!h.CompareTag("Perch")) continue; float d=Vector3.Distance(transform.position, h.transform.position); if(d<bd){ bd=d; best=h.transform; } }
            if(best){ perched=true; perchPoint=best; perchedTimer=Random.Range(3f, unperchDelay); velocity*=0.2f; }
        }

        void OnDrawGizmosSelected(){ Gizmos.color=Color.yellow; Gizmos.DrawWireSphere(transform.position, perceptionRadius); }
    }
}
