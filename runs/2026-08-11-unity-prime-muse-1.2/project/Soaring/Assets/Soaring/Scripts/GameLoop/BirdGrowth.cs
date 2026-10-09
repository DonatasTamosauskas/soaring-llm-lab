
using UnityEngine;

namespace Soaring.GameLoop
{
    /// <summary>
    /// Agar.io-like sizing: catching smaller birds grows you; larger birds eat you.
    /// Collision based on trigger volumes comparing SizeScale.
    /// Growth curve tuned for VR: slower growth, max cap, visual feedback.
    /// </summary>
    public class BirdGrowth : MonoBehaviour
    {
        [Header("Growth")]
        public float startScale = 1f;
        public float eatGrowth = 0.08f;
        public float eatGrowthFalloff = 0.85f; // successive eats give slightly less
        public float deathShrink = 0.5f;
        public float minScale = 0.6f;
        public float maxScale = 3.8f;
        public float lerpSpeed = 4f;

        [Header("Feedback")]
        public AudioClip eatSound;
        public AudioClip eatenSound;
        public ParticleSystem eatParticles;

        Soaring.Flight.BirdFlightController flight;
        float currentScale;
        float targetScale;
        int eatStreak;

        public float CurrentScale => currentScale;
        public float TargetScale => targetScale;

        public event System.Action<float,float> OnGrowth; // old,new
        public event System.Action OnEaten;
        public event System.Action<BirdGrowth> OnAteOther;

        void Awake()
        {
            flight = GetComponent<Soaring.Flight.BirdFlightController>();
            currentScale = startScale;
            targetScale = startScale;
            if (flight) flight.SizeScale = currentScale;
        }

        void Update()
        {
            currentScale = Mathf.MoveTowards(currentScale, targetScale, Time.deltaTime * lerpSpeed * 0.5f);
            // also lerp visual
            if (flight) flight.SizeScale = currentScale;
            transform.localScale = Vector3.Lerp(transform.localScale, Vector3.one * currentScale, Time.deltaTime * lerpSpeed);
        }

        void OnTriggerEnter(Collider other)
        {
            var otherGrowth = other.GetComponentInParent<BirdGrowth>();
            if (!otherGrowth || otherGrowth == this) return;
            // compare target scales for fairness (includes pending growth)
            float my = targetScale;
            float theirs = otherGrowth.targetScale;
            // needs meaningful difference to avoid flicker ties
            const float eps = 0.04f;
            if (my > theirs + eps)
            {
                // I eat them
                TryEat(otherGrowth);
            }
            else if (theirs > my + eps)
            {
                // they eat me
                // let the other handle it; but if they don't have trigger ordering reliable, handle both
                // We check if other already ate us to avoid double
            }
        }

        // Called by other bird OR by AI prey system
        public bool TryEat(BirdGrowth prey)
        {
            if (prey.targetScale >= targetScale - 0.04f) return false; // too big
            float gained = eatGrowth * Mathf.Pow(eatGrowthFalloff, eatStreak) * Mathf.Lerp(0.6f, 1.4f, Mathf.InverseLerp(0.5f, 2f, prey.targetScale));
            float next = Mathf.Clamp(targetScale + gained, minScale, maxScale);
            float prev = targetScale;
            targetScale = next;
            eatStreak++;
            // reset streak after delay via Invoke
            CancelInvoke(nameof(ResetStreak));
            Invoke(nameof(ResetStreak), 8f);

            OnGrowth?.Invoke(prev, next);
            OnAteOther?.Invoke(prey);

            if (eatSound) AudioSource.PlayClipAtPoint(eatSound, transform.position, 0.9f);
            if (eatParticles) eatParticles.Play();

            // notify prey
            prey.GotEaten(this);
            return true;
        }

        public void TryEatSimple(float preyScale)
        {
            float gained = eatGrowth * Mathf.Pow(eatGrowthFalloff, eatStreak) * Mathf.Lerp(0.6f, 1.2f, preyScale);
            targetScale = Mathf.Clamp(targetScale + gained, minScale, maxScale);
            eatStreak++;
            CancelInvoke(nameof(ResetStreak));
            Invoke(nameof(ResetStreak), 8f);
            currentScale = Mathf.MoveTowards(currentScale, targetScale, 0.02f);
            if (flight) flight.SizeScale = targetScale;
            if (eatSound) AudioSource.PlayClipAtPoint(eatSound, transform.position, 0.7f);
        }

        void GotEaten(BirdGrowth predator)
        {
            // shrink and respawn
            targetScale = Mathf.Clamp(targetScale * deathShrink, minScale, maxScale);
            currentScale = targetScale;
            if (flight) { flight.SizeScale = currentScale; flight.ApplyPredatorImpulse((transform.position - predator.transform.position).normalized + Vector3.up*0.6f, 12f); }
            eatStreak = 0;
            OnEaten?.Invoke();
            if (eatenSound) AudioSource.PlayClipAtPoint(eatenSound, transform.position, 0.9f);
            // brief invulnerability?
            var col = GetComponent<Collider>();
            if (col) { col.enabled = false; Invoke(nameof(ReenableCollider), 2f); }
        }

        void ReenableCollider() { var c=GetComponent<Collider>(); if(c) c.enabled=true; }
        void ResetStreak() => eatStreak = 0;

        // For AI prey pooling
        public void SetScale(float s) { targetScale = currentScale = Mathf.Clamp(s, minScale, maxScale); if(flight) flight.SizeScale=currentScale; transform.localScale=Vector3.one*currentScale; }
    }
}
