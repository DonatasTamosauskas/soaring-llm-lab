
using UnityEngine;

namespace Soaring.Flight
{
    /// <summary>
    /// Spawns procedural wing visuals that follow controller transforms and flap amplit
    /// Useful for third-person / mirror view and for sizing via BirdGrowth.
    /// Also drives simple anemometry feedback particles.
    /// </summary>
    public class WingVisuals : MonoBehaviour
    {
        public Transform leftWingRoot;
        public Transform rightWingRoot;
        public WingInputTracker tracker;
        public BirdFlightController flight;
        public ParticleSystem windParticles;
        public float flapLerp = 18f;

        public Transform birdBody; // scales with growth

        Vector3 leftInit, rightInit;

        void Awake()
        {
            if (!tracker) tracker = GetComponentInParent<WingInputTracker>();
            if (!flight) flight = GetComponentInParent<BirdFlightController>();
            if (leftWingRoot) leftInit = leftWingRoot.localPosition;
            if (rightWingRoot) rightInit = rightWingRoot.localPosition;
        }

        void Update()
        {
            if (!tracker) return;
            // drive wing pitch based on hand velocity for visual flap
            if (leftWingRoot)
            {
                float flap = -tracker.LeftVelocity.y * 0.12f;
                leftWingRoot.localRotation = Quaternion.Slerp(leftWingRoot.localRotation,
                    Quaternion.Euler(flap* 30f, 0, -tracker.BankInput*20f), Time.deltaTime*flapLerp);
            }
            if (rightWingRoot)
            {
                float flap2 = -tracker.RightVelocity.y * 0.12f;
                rightWingRoot.localRotation = Quaternion.Slerp(rightWingRoot.localRotation,
                    Quaternion.Euler(flap2*30f, 0, -tracker.BankInput*20f), Time.deltaTime*flapLerp);
            }
            if (windParticles && flight)
            {
                var em = windParticles.emission;
                em.rateOverTime = Mathf.Lerp(0, 80, Mathf.InverseLerp(4f, 20f, flight.Speed));
                windParticles.transform.forward = -flight.Velocity.normalized;
            }
            if (birdBody && flight)
            {
                float s = flight.SizeScale;
                birdBody.localScale = Vector3.Lerp(birdBody.localScale, Vector3.one * s, Time.deltaTime*4f);
            }
        }
    }
}
