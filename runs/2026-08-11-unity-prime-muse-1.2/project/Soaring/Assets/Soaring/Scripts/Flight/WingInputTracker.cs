
using UnityEngine;
using Unity.XR.CoreUtils;
using UnityEngine.XR;

namespace Soaring.Flight
{
    /// <summary>
    /// Reads raw XR controller / hand tracking data and computes bird-wing semantics.
    /// Primary input is Transforms (assigned to the XR controller objects) for maximal
    /// compatibility with Meta XR Simulator, Quest, and XR Device Simulator.
    /// Falls back to InputDevices if transforms not assigned.
    /// </summary>
    public class WingInputTracker : MonoBehaviour
    {
        [Header("References - Assign XR Controller Transforms")]
        public Transform leftController;
        public Transform rightController;
        public Transform head; // HMD / Main Camera

        [Header("Tuning")]
        public float smoothing = 12f;
        public float velocitySmoothing = 8f;

        // Raw
        public Vector3 LeftPos { get; private set; }
        public Vector3 RightPos { get; private set; }
        public Quaternion LeftRot { get; private set; } = Quaternion.identity;
        public Quaternion RightRot { get; private set; } = Quaternion.identity;

        // Smoothed velocities
        public Vector3 LeftVelocity { get; private set; }
        public Vector3 RightVelocity { get; private set; }
        public Vector3 LeftAngularVelocity { get; private set; }
        public Vector3 RightAngularVelocity { get; private set; }

        // Derived bird semantics
        /// <summary>Wingspan distance between controllers (meters)</summary>
        public float WingSpan => Vector3.Distance(LeftPos, RightPos);
        /// <summary>Midpoint of wings</summary>
        public Vector3 WingCenter => (LeftPos + RightPos) * 0.5f;
        /// <summary>Mean wing plane normal (average up of each wing)</summary>
        public Vector3 MeanWingUp => ((LeftRot * Vector3.up) + (RightRot * Vector3.up)).normalized;
        public Vector3 MeanWingForward => ((LeftRot * Vector3.forward) + (RightRot * Vector3.forward)).normalized;
        /// <summary>Roll angle from differential height (-1..1) plus controller roll</summary>
        public float BankInput { get; private set; }
        /// <summary>Pitch from mean controller pitch (-1 dive, +1 climb/brake)</summary>
        public float PitchInput { get; private set; }
        /// <summary>Yaw torque from differential yaw / twist</summary>
        public float YawInput { get; private set; }

        /// <summary>How efficiently positioned wings are for generating lift (0..1)
        /// 1 = horizontal like a bird gliding, 0 = vertical like air brakes</summary>
        public float WingEfficiency { get; private set; }

        // internal
        Vector3 _prevL, _prevR;
        Quaternion _prevLRot, _prevRRot;
        Vector3 _velL, _velR;
        bool _hasPrev;

        void Awake()
        {
            if (!head && Camera.main) head = Camera.main.transform;
            // auto-find if not assigned
            if (!leftController || !rightController) AutoFindControllers();
        }

        void AutoFindControllers()
        {
            var origin = FindFirstObjectByType<Unity.XR.CoreUtils.XROrigin>();
            if (!origin) return;
            // try by name
            leftController = origin.transform.Find("Camera Offset/Left Controller") ?? origin.transform.Find("Camera Offset/LeftHand Controller");
            rightController = origin.transform.Find("Camera Offset/Right Controller") ?? origin.transform.Find("Camera Offset/RightHand Controller");
            if (!head) head = origin.Camera.transform;
        }

        void Update()
        {
            if (!leftController || !rightController) return;

            LeftPos = leftController.position;
            RightPos = rightController.position;
            LeftRot = leftController.rotation;
            RightRot = rightController.rotation;

            if (!_hasPrev)
            {
                _prevL = LeftPos; _prevR = RightPos;
                _prevLRot = LeftRot; _prevRRot = RightRot;
                _hasPrev = true;
                return;
            }

            float dt = Time.deltaTime;
            if (dt < 1e-5f) return;

            Vector3 rawVL = (LeftPos - _prevL) / dt;
            Vector3 rawVR = (RightPos - _prevR) / dt;

            // exponential smoothing for velocity
            float k = 1f - Mathf.Exp(-velocitySmoothing * dt);
            _velL = Vector3.Lerp(_velL, rawVL, k);
            _velR = Vector3.Lerp(_velR, rawVR, k);
            LeftVelocity = _velL;
            RightVelocity = _velR;

            // angular vel approx
            Quaternion dL = LeftRot * Quaternion.Inverse(_prevLRot);
            dL.ToAngleAxis(out float aL, out Vector3 axisL);
            if (aL > 180) aL -= 360;
            LeftAngularVelocity = axisL * aL * Mathf.Deg2Rad / dt;

            Quaternion dR = RightRot * Quaternion.Inverse(_prevRRot);
            dR.ToAngleAxis(out float aR, out Vector3 axisR);
            if (aR > 180) aR -= 360;
            RightAngularVelocity = axisR * aR * Mathf.Deg2Rad / dt;

            // Derive bank: differential height normalized by wings pan + controller roll
            Vector3 headUp = head ? head.up : Vector3.up;
            // height diff in head space
            Vector3 headPos = head ? head.position : Vector3.zero;
            // Use world y diff for bank; simple but intuitive
            float heightDiff = RightPos.y - LeftPos.y; // positive = right higher -> bank right? Actually left low -> right high => roll left? Let's tune: positive diff => roll right (bank to right)
            float rollFromHeight = Mathf.Clamp(heightDiff / 0.6f, -1f, 1f); // 60cm diff = full bank

            // add controller roll contribution (avg roll angle)
            float leftRoll = GetRoll(LeftRot, head);
            float rightRoll = GetRoll(RightRot, head);
            float rollFromRotation = Mathf.Clamp((leftRoll + rightRoll) * 0.5f / 45f, -1f, 1f);

            BankInput = Mathf.Clamp(rollFromHeight * 0.7f + rollFromRotation * 0.8f, -1f, 1f);

            // Pitch from mean controller pitch: convert to -1..1
            float leftPitch = GetPitch(LeftRot, head);
            float rightPitch = GetPitch(RightRot, head);
            float meanPitch = (leftPitch + rightPitch) * 0.5f; // degrees, positive = nose up
            // -30 dive, +30 climb -> map
            PitchInput = Mathf.Clamp(meanPitch / 35f, -1f, 1f);

            // Yaw from differential twist (one wing forward, one back) + yaw rotation
            Vector3 leftFwd = LeftRot * Vector3.forward;
            Vector3 rightFwd = RightRot * Vector3.forward;
            // project onto horizontal plane
            Vector3 lh = head ? head.InverseTransformDirection(leftFwd) : leftFwd;
            Vector3 rh = head ? head.InverseTransformDirection(rightFwd) : rightFwd;
            float yawDiff = (rh.x - lh.x); // crude
            YawInput = Mathf.Clamp(yawDiff * 1.2f + (leftRoll - rightRoll)/60f, -1f, 1f);

            // Wing efficiency: dot of wing up with world up, averaged, and wing horizontality
            float effL = Mathf.Clamp01(Vector3.Dot(LeftRot * Vector3.up, Vector3.up) * 0.5f + 0.5f);
            float effR = Mathf.Clamp01(Vector3.Dot(RightRot * Vector3.up, Vector3.up) * 0.5f + 0.5f);
            // also penalize if wings are too far apart vertically (bad form)
            float vertPenalty = Mathf.Clamp01(1f - Mathf.Abs(heightDiff) * 0.8f);
            WingEfficiency = (effL + effR) * 0.5f * Mathf.Lerp(0.85f, 1f, vertPenalty);

            _prevL = LeftPos; _prevR = RightPos;
            _prevLRot = LeftRot; _prevRRot = RightRot;
        }

        float GetRoll(Quaternion q, Transform h)
        {
            // return roll in degrees relative to head
            Vector3 up = q * Vector3.up;
            Vector3 headUp = h ? h.up : Vector3.up;
            Vector3 headRight = h ? h.right : Vector3.right;
            // project up onto head's right/up plane
            float roll = Mathf.Atan2(Vector3.Dot(up, headRight), Vector3.Dot(up, headUp)) * Mathf.Rad2Deg;
            // roll 0 = upright, 90 = wing on side
            return roll;
        }
        float GetPitch(Quaternion q, Transform h)
        {
            Vector3 fwd = q * Vector3.forward;
            Vector3 headFwd = h ? h.forward : Vector3.forward;
            Vector3 headUp = h ? h.up : Vector3.up;
            // pitch is angle between forward and horizontal plane
            float pitch = Mathf.Atan2(Vector3.Dot(fwd, headUp), Vector3.Dot(fwd, headFwd)) * Mathf.Rad2Deg;
            return pitch;
        }

        // For debug / tuning
        public float DownStrokePower
        {
            get
            {
                // positive when moving down quickly (negative Y velocity)
                float l = Mathf.Max(0, -LeftVelocity.y);
                float r = Mathf.Max(0, -RightVelocity.y);
                return (l + r) * 0.5f;
            }
        }
    }
}
