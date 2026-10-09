using UnityEngine;
namespace Soaring
{
    public static class WingPoseMath
    {
        // Remove arm swing before extracting controller twist around the
        // calibrated forearm. Raising an arm must not change angle of attack.
        public static float WristPitch(Quaternion neutral, Vector3 neutralArm, Quaternion rotation, Vector3 arm, float side)
        {
            if (arm.sqrMagnitude < .001f || neutralArm.sqrMagnitude < .001f)
                return 0;
            neutralArm.Normalize();
            var swing = Quaternion.FromToRotation(neutralArm, arm.normalized);
            var delta = Quaternion.Inverse(swing) * rotation * Quaternion.Inverse(neutral);
            float projected = Vector3.Dot(new Vector3(delta.x, delta.y, delta.z), neutralArm);
            float angle = Mathf.DeltaAngle(0, 2 * Mathf.Atan2(projected, delta.w) * Mathf.Rad2Deg) * side;
            float magnitude = Mathf.Max(0, Mathf.Abs(angle) - 4) / 51;
            return Mathf.Sign(angle) * Mathf.Clamp01(magnitude);
        }
    }
}
