
using UnityEngine;
using UnityEngine.XR;

namespace Soaring.Flight
{
    /// <summary>
    /// CORE FLIGHT MECHANIC - Bird-like flapping physics.
    /// Inspired by real bird aerodynamics: flapping creates thrust + lift, wings tilted control efficiency.
    /// - Downstroke velocity of controllers => thrust & lift (proportional, mass-dependent)
    /// - Wing tilt / bank => turn authority and lift vectoring (gliding turn)
    /// - Pitch => speed/brake, dive converts to lift via L/D
    /// - WingEfficiency from tracker modulates lift (horizontal wings = efficient)
    /// - Gravity, drag, stall, thermals approximated
    /// Uses CharacterController for collisions but fully physics-driven velocity integration.
    /// Designed to be THE ONLY locomotion - disable any XRI MoveProviders.
    /// Works with Meta XR Simulator out of the box (just assign controller transforms).
    /// </summary>
    [RequireComponent(typeof(CharacterController))]
    public class BirdFlightController : MonoBehaviour
    {
        [Header("References")]
        public WingInputTracker tracker;
        public Transform head; // HMD
        public Transform flightRoot; // usually XROrigin Camera Offset transform (where we apply motion). If null, moves this object.

        [Header(" Flight Tuning - PERFECT THESE ")]
        [Tooltip("Lift per m/s of downstroke")]
        public float flapLift = 3.2f;
        [Tooltip("Forward thrust per m/s of downstroke")]
        public float flapThrust = 2.0f;
        [Tooltip("Base glide lift when moving forward (L = k * v^2 * efficiency)")]
        public float glideLiftFactor = 0.14f;
        [Tooltip("How bank angles velocity")]
        public float bankTurnStrength = 45f;
        [Tooltip("Pitch affects speed (dive = accel)")]
        public float pitchSpeedFactor = 6f;
        public float gravity = 9.81f;
        [Tooltip("Drag - quadratic")]
        public float drag = 0.045f;
        public float parasiteDrag = 0.02f;
        [Tooltip("Min speed before stall")]
        public float stallSpeed = 3f;
        public float stallLiftPenalty = 0.6f;
        [Tooltip("Max speed clamp")]
        public float maxSpeed = 28f;
        [Tooltip("Flap cooldown to avoid pump spam")]
        public float flapCooldown = 0.18f;
        [Tooltip("Energy recovery when gliding")]
        public float glideRecoveryRate = 0.8f;

        [Header("Perch / Cling")]
        public float perchStickDistance = 1.0f;
        public LayerMask perchMask = ~0;
        public float perchBreakForce = 2f;

        [Header("Comfort")]
        public float vignetteOnHighSpeed = 0.6f;

        // runtime
        CharacterController cc;
        Vector3 velocity;
        float flapTimer;
        bool isPerched;
        Vector3 perchNormal;
        float energy = 1f; // 0..1 flap stamina

        // Bird size (growth via GameLoop)
        float sizeScale = 1f;
        float mass => Mathf.Lerp(0.4f, 2.2f, Mathf.InverseLerp(1f, 3f, sizeScale));

        public Vector3 Velocity => velocity;
        public float Speed => velocity.magnitude;
        public bool IsPerched => isPerched;
        public float SizeScale { get => sizeScale; set => sizeScale = Mathf.Clamp(value, 0.6f, 4f); }

        void Awake()
        {
            cc = GetComponent<CharacterController>();
            if (!tracker) tracker = GetComponent<WingInputTracker>() ?? FindFirstObjectByType<WingInputTracker>();
            if (!head && Camera.main) head = Camera.main.transform;
            if (!flightRoot) flightRoot = transform; // if XROrigin, actually move the origin; this controller is on origin
            // ensure CC is reasonable for bird
            cc.radius = 0.35f;
            cc.height = 1.2f;
            cc.skinWidth = 0.06f;
        }

        void OnEnable()
        {
            velocity = head ? head.forward * 5f : Vector3.forward * 5f;
        }

        void Update()
        {
            float dt = Time.deltaTime;
            if (dt <= 0) return;
            if (!tracker || !head) return;

            flapTimer -= dt;
            HandlePerch(dt);

            if (isPerched)
            {
                // Perched: wait for strong flap to take off
                float downPower = tracker.DownStrokePower;
                if (downPower > perchBreakForce)
                {
                    isPerched = false;
                    // launch
                    Vector3 launchDir = (head.forward + Vector3.up * 0.6f).normalized;
                    float launchStrength = Mathf.Clamp(downPower * 1.5f, 5f, 12f);
                    velocity = launchDir * launchStrength + velocity * 0.2f;
                }
                else
                {
                    // stick - zero velocity, counter gravity via perch
                    velocity = Vector3.Lerp(velocity, Vector3.zero, dt * 8f);
                    // allow looking around but not falling
                }
                ApplyMovement(dt);
                return;
            }

            // === FLAPPING ===
            // detect downstroke: both hands moving down simultaneously gives most power, alternating also works
            float downL = Mathf.Max(0, -tracker.LeftVelocity.y);
            float downR = Mathf.Max(0, -tracker.RightVelocity.y);
            float avgDown = (downL + downR) * 0.5f;
            float maxDown = Mathf.Max(downL, downR);
            bool isFlapping = avgDown > 1.2f || maxDown > 2.0f;
            bool canFlap = flapTimer <= 0f && isFlapping && energy > 0.05f;

            if (canFlap)
            {
                // Flap power scales with down speed and wing efficiency (horizontal wings flap better)
                float efficiency = Mathf.Clamp01(tracker.WingEfficiency);
                float flapPower = avgDown * Mathf.Lerp(0.6f, 1f, efficiency);
                // async flap: big downstroke => more lift/thrust
                float liftBoost = flapPower * flapLift / mass;
                float thrustBoost = flapPower * flapThrust * Mathf.Lerp(1.2f, 0.7f, Mathf.Clamp01(Speed / 18f)) / mass;

                // Direction: lift is up + slightly head up; thrust is head forward projected horizontal + pitch influence
                Vector3 up = Vector3.up;
                Vector3 fwd = GetFlightForward();
                // tilt lift vector by bank (banked wings vector lift sideways => turn)
                Vector3 liftDir = (up - fwd * tracker.BankInput * 0.35f).normalized;
                // pitch tilts lift/thrust: pitching down converts lift to thrust
                float pitch = tracker.PitchInput; // -1 dive, +1 brake/climb
                // dive: add forward, pitch up: add up at cost of speed
                liftDir = Vector3.Slerp(liftDir, fwd, Mathf.Clamp01(-pitch * 0.5f));
                fwd = Vector3.Slerp(fwd, up, Mathf.Clamp01(pitch * 0.6f));

                velocity += liftDir * liftBoost + fwd * thrustBoost;
                // add a little burst damping to prevent endless pump
                flapTimer = flapCooldown * Mathf.Lerp(1f, 0.6f, Mathf.Clamp01(flapPower/8f));
                energy = Mathf.Clamp01(energy - 0.08f * Mathf.Clamp01(flapPower/6f));
                // haptic
                PulseHaptics(0.6f, 0.08f);
            }
            else
            {
                // recover energy while gliding
                energy = Mathf.Clamp01(energy + dt * glideRecoveryRate * (Speed > stallSpeed ? 1f : 0.3f));
            }

            // === GLIDE LIFT (forward motion => lift) ===
            float forwardSpeed = Vector3.Dot(velocity, GetFlightForward());
            forwardSpeed = Mathf.Max(0, forwardSpeed);
            float glideLift = glideLiftFactor * forwardSpeed * forwardSpeed * Mathf.Clamp01(tracker.WingEfficiency) * SizeFactorLift();
            // stall penalty
            if (Speed < stallSpeed)
                glideLift *= Mathf.Lerp(stallLiftPenalty, 1f, Speed / stallSpeed);
            // pitch modulates glide: pitching up increases AoA but at drag cost; pitching down reduces lift
            float glidePitch = tracker.PitchInput;
            glideLift *= Mathf.Lerp(1f, 0.55f, Mathf.Clamp01(-glidePitch)); // dive reduces glide lift slightly (converted to speed)
            // apply glide lift upward (banked => lift vector tilts)
            Vector3 glideLiftVec = Vector3.up * glideLift;
            // bank tilts lift vector => induces turn
            glideLiftVec = Quaternion.AngleAxis(tracker.BankInput * 35f, GetFlightForward()) * glideLiftVec;
            velocity += glideLiftVec * dt;

            // === TURNING ===
            // Bank induces yaw rate proportional to speed (like real banked turn: yawRate = g * tan(bank)/v)
            float bank = tracker.BankInput; // -1..1
            float speedForTurn = Mathf.Max(stallSpeed, Speed);
            float bankAngleDeg = bank * 55f; // max 55 deg bank
            float yawRate = 0f;
            if (Mathf.Abs(bank) > 0.08f)
            {
                float g = gravity;
                float bankRad = bankAngleDeg * Mathf.Deg2Rad;
                yawRate = (g * Mathf.Tan(bankRad) / speedForTurn) * Mathf.Rad2Deg; // deg/s
                // add yaw input (differential twist) as additional yaw torque
                yawRate += tracker.YawInput * 45f * Mathf.Clamp01(speedForTurn/6f);
            }
            else
            {
                // small yaw from twist even when not banked
                yawRate = tracker.YawInput * 25f;
            }
            // apply yaw to velocity vector (coord turning)
            if (Mathf.Abs(yawRate) > 0.01f)
            {
                Quaternion yawRot = Quaternion.AngleAxis(yawRate * dt, Vector3.up);
                velocity = yawRot * velocity;
                // also rotate the whole rig if flightRoot is the origin
                // We do NOT snap head; we rotate velocity. Optional: slightly rotate root for visual lean
            }

            // Pitch affects speed: dive converts altitude to speed, climb bleeds
            // Model: pitch input modifies forward acceleration
            velocity += GetFlightForward() * (-tracker.PitchInput * pitchSpeedFactor * dt * Mathf.Clamp01(Speed/4f));

            // === GRAVITY ===
            float gravityScale = 1f;
            // larger birds fall faster but generate more lift — already mass-scaled
            velocity.y -= gravity * gravityScale * dt;

            // === DRAG ===
            float vMag = velocity.magnitude;
            if (vMag > 0.01f)
            {
                // quadratic + parasite; wings tucked (low efficiency) => more drag when braking (pitch up)
                float dragFactor = drag + parasiteDrag * Mathf.Clamp01(tracker.PitchInput * 0.5f + 0.5f);
                // Wings spread = more drag at high speed, but needed for lift — tradeoff
                dragFactor *= Mathf.Lerp(0.7f, 1.25f, Mathf.Clamp01(tracker.WingEfficiency));
                Vector3 dragForce = -velocity.normalized * (dragFactor * vMag * vMag * dt);
                velocity += dragForce;
                // also linear damping for low speed stability
                velocity *= 1f - (0.02f * dt);
            }

            velocity = Vector3.ClampMagnitude(velocity, maxSpeed);

            // === AUTO-LEVEL & STABILITY ===
            // mild auto-level when not actively banking (birds naturally stabilize)
            if (Mathf.Abs(bank) < 0.12f && Speed > stallSpeed)
            {
                velocity = Vector3.Lerp(velocity, new Vector3(velocity.x, velocity.y * 0.98f, velocity.z), dt * 0.6f);
            }

            ApplyMovement(dt);
        }

        Vector3 GetFlightForward()
        {
            if (head) return Vector3.ProjectOnPlane(head.forward, Vector3.up).normalized;
            return transform.forward;
        }
        float SizeFactorLift() => Mathf.Lerp(0.85f, 1.35f, Mathf.InverseLerp(0.6f, 3f, sizeScale));

        void ApplyMovement(float dt)
        {
            if (!cc) return;
            Vector3 motion = velocity * dt;
            // CharacterController handles collisions; if we hit wall, reflect slightly for acrobatic bounce
            CollisionFlags flags = cc.Move(motion);
            if ((flags & CollisionFlags.Sides) != 0)
            {
                // slide: bleed some speed but keep flow
                velocity *= 0.92f;
                // try perch if slow and near surface with perchable tag/layer
            }
            if ((flags & CollisionFlags.Above) != 0) velocity.y = Mathf.Min(0, velocity.y);
            if ((flags & CollisionFlags.Below) != 0 && velocity.y < 0) velocity.y = Mathf.Min(0, velocity.y * 0.3f);
        }

        void HandlePerch(float dt)
        {
            if (isPerched) return;
            if (Speed > 4f) return; // too fast to perch
            Vector3 origin = head ? head.position : transform.position;
            // ray down + forward to find perch
            if (Physics.SphereCast(origin, 0.25f, Vector3.down, out RaycastHit hit, perchStickDistance, perchMask) ||
                Physics.SphereCast(origin, 0.25f, GetFlightForward(), out hit, 1.2f, perchMask))
            {
                // must be looking at perch roughly and slow
                bool isPerchTag = hit.collider.CompareTag("Perch") || hit.collider.gameObject.layer == LayerMask.NameToLayer("Perch");
                // also allow any collider if slow and bank low (cling to branches/poles/windows)
                if (isPerchTag || (Speed < 2.5f && hit.normal.y > -0.2f))
                {
                    isPerched = true;
                    perchNormal = hit.normal;
                    velocity *= 0.15f;
                }
            }
        }

        public void AddSize(float delta)
        {
            SizeScale += delta;
            // grow collider a bit
            if (cc) cc.radius = Mathf.Lerp(0.35f, 0.75f, Mathf.InverseLerp(0.6f, 4f, sizeScale));
        }

        public void ApplyPredatorImpulse(Vector3 dir, float force)
        {
            velocity += dir * force;
            isPerched = false;
        }

        void PulseHaptics(float amp, float dur)
        {
            // try both controllers - safe if no haptics
            try
            {
                var left = UnityEngine.XR.InputDevices.GetDeviceAtXRNode(XRNode.LeftHand);
                var right = UnityEngine.XR.InputDevices.GetDeviceAtXRNode(XRNode.RightHand);
                if (left.isValid) left.SendHapticImpulse(0, amp, dur);
                if (right.isValid) right.SendHapticImpulse(0, amp, dur);
            }
            catch {}
        }

        // Gizmo
        void OnDrawGizmosSelected()
        {
            Gizmos.color = Color.cyan;
            Gizmos.DrawRay(transform.position, velocity);
        }

        // Used by BirdGrowth to force unperch on respawn etc.
        public void ForceUnperch() => isPerched = false;
    }
}
