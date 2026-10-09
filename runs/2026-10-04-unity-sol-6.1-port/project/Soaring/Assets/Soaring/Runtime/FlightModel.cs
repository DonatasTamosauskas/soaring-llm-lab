using UnityEngine;
namespace Soaring
{
    public struct WingState
    {
        public float leftExtension, rightExtension, leftPitch, rightPitch, pitch, roll, leftFlap, rightFlap, stretch;
        public bool tuck; public float Spread => .5f * (leftExtension + rightExtension);
        public static WingState Neutral => new() { leftExtension = 1, rightExtension = 1 };
    }
    // SI units. The body banks and pitches; the tracking origin receives yaw only.
    // Lift/drag polar and scaling are derived from the Godot FlightParams model.
    public sealed class FlightModel
    {
        public Vector3 position, velocity; public float mass = .03f, yaw, pitch, bank, alpha, airspeed, turnRate, stallWarning;
        public bool stalled; public float leftEffort, rightEffort; float stallTime, deliberateTime;
        public const float G = 9.81f;
        public void Reset(Vector3 p, Vector3 forward, bool flying = false)
        {
            position = p;
            yaw = Mathf.Atan2(forward.x, forward.z);
            velocity = flying ? forward * SizeRules.Cruise(mass) : Vector3.zero;
            pitch = .065f;
            bank = alpha = turnRate = stallTime = leftEffort = rightEffort = 0;
            stalled = false;
        }
        public Vector3 Forward => new(Mathf.Sin(yaw), 0, Mathf.Cos(yaw));
        public void Step(WingState wings, Vector3 wind, float ground, float ceiling, float dt, Preferences settings)
        {
            int count = Mathf.Max(1, Mathf.CeilToInt(dt * 144));
            float h = dt / count;
            for (int i = 0; i < count; i++)
                Integrate(wings, wind, ground, ceiling, h, settings);
        }
        void Integrate(WingState w, Vector3 wind, float ground, float ceiling, float h, Preferences prefs)
        {
            float cruise = SizeRules.Cruise(mass), vmin = .45f * cruise, vmax = 2.6f * cruise, span = SizeRules.Span(mass);
            float size = Mathf.Clamp01(Mathf.Log(mass / .004f) / Mathf.Log(3 / .004f));
            float cln = .30f, clmax = cln / (.45f * .45f), s = 2 * mass * G / (1.225f * cruise * cruise * cln);
            float aspect = Mathf.Lerp(5, 8, size), ki = 1 / (Mathf.PI * .85f * aspect), ld = Mathf.Lerp(8.9f, 13.5f, size) * prefs.glideEfficiency;
            float cd0 = 1 / (4 * ki * ld * ld), an = cln / 4.6f, astall = clmax / 4.6f;
            Vector3 va = velocity - wind;
            airspeed = va.magnitude;
            float vh = new Vector2(va.x, va.z).magnitude;
            float gamma = Mathf.Atan2(va.y, Mathf.Max(vh, .01f));
            float flapBlend = 1 - Mathf.Exp(-h / .20f);
            leftEffort = Mathf.Lerp(leftEffort, Mathf.Clamp(w.leftFlap, 0, 1.3f), flapBlend);
            rightEffort = Mathf.Lerp(rightEffort, Mathf.Clamp(w.rightFlap, 0, 1.3f), flapBlend);
            float effort = .5f * (leftEffort + rightEffort);
            deliberateTime = w.pitch > .9f ? deliberateTime + h : 0;
            float command = w.pitch >= 0 ? Mathf.Lerp(an, astall - .017f, w.pitch) : Mathf.Lerp(an, -.10f, -w.pitch);
            command += Mathf.Min(.1f, .85f * an * (1 / Mathf.Max(Mathf.Cos(bank), .3f) - 1));
            if (w.tuck)
                command -= .035f;
            if (deliberateTime > .35f && position.y - ground > 11)
                command = astall + .09f;
            float target = gamma + command;
            if (stalled && stallTime > 1.5f)
                target = gamma + an;
            pitch += Mathf.Clamp((target - pitch) * (1 - Mathf.Exp(-h / Mathf.Lerp(.10f, .22f, size))), -5.6f * h, 5.6f * h);
            alpha = pitch - gamma;
            if (!stalled && airspeed > .5f * vmin && alpha > astall + .009f)
            {
                stalled = true;
                stallTime = 0;
            }
            if (stalled)
            {
                stallTime += h;
                if (stallTime > .3f && (alpha < astall - .052f || airspeed < .4f * vmin))
                {
                    stalled = false;
                    deliberateTime = 0;
                }
            }
            stallWarning = stalled ? 1 : SizeRules.Smooth(astall - .105f, astall, alpha) * SizeRules.Smooth(.4f, .5f, airspeed / vmin);
            float bankMax = Mathf.Clamp(Mathf.Atan(SizeRules.TurnRate(mass) * cruise / G), 55 * Mathf.Deg2Rad, 78 * Mathf.Deg2Rad);
            float asymmetry = leftEffort - rightEffort;
            if (Mathf.Abs(asymmetry) < .15f * (leftEffort + rightEffort))
                asymmetry = 0;
            float bankCommand = w.roll * bankMax + .314f * asymmetry + .5f * (w.leftExtension - w.rightExtension) * bankMax;
            float comfortBank = Mathf.Atan(prefs.turnSpeed * Mathf.Deg2Rad * Mathf.Max(vh, vmin * .5f) / G);
            bankCommand = Mathf.Clamp(bankCommand, -Mathf.Min(bankMax, comfortBank), Mathf.Min(bankMax, comfortBank));
            if (stalled)
                bankCommand += .26f * Mathf.Sign(bank + .01f) * SizeRules.Smooth(0, .5f, stallTime);
            bank += Mathf.Clamp((bankCommand - bank) * (1 - Mathf.Exp(-h / Mathf.Lerp(.18f, .36f, size))), -6 * h, 6 * h);
            float spread = Mathf.Clamp01(w.Spread), area = .25f + .75f * spread;
            float cl = Mathf.Clamp(4.6f * alpha, -.5f, clmax);
            if (stalled)
                cl = Mathf.Lerp(cl, .6f * clmax, SizeRules.Smooth(0, .15f, stallTime));
            float cd = cd0 + ki * cl * cl / Mathf.Max(area, .25f) + (1 - area) * .07f + (stalled ? .16f + 1.8f * Mathf.Pow(Mathf.Sin(alpha), 2) : 0);
            float thin = 1 - SizeRules.Smooth(ceiling - 45, ceiling - 5, position.y);
            float dynamic = .5f * 1.225f * airspeed * airspeed * thin;
            float lift = dynamic * s * area * cl;
            float drag = dynamic * s * cd;
            if (airspeed > vmax * .85f)
                drag += mass * G * 31 * Mathf.Pow(airspeed / vmax - .85f, 2);
            Vector3 f = Forward, r = new(Mathf.Cos(yaw), 0, -Mathf.Sin(yaw));
            Vector3 tangent = airspeed > .001f ? va / airspeed : f;
            Vector3 liftAxis = (Vector3.up - tangent * Vector3.Dot(Vector3.up, tangent)).normalized;
            liftAxis = liftAxis * Mathf.Cos(bank) + r * Mathf.Sin(bank);
            float groundDistance = position.y - ground - .16f * span;
            if (groundDistance < span)
                lift *= 1 + .6f * Mathf.Pow(1 - Mathf.Clamp01(groundDistance / span), 2);
            float hover = effort > .05f ? 1 - SizeRules.Smooth(.3f, .6f, airspeed / vmin) : 0;
            lift *= 1 - hover;
            Vector3 acceleration = Vector3.down * G + (liftAxis * lift - tangent * drag) / mass;
            float forceGain = Mathf.Lerp(1.35f, 1.7f, Mathf.Clamp01(vh / vmin)) * prefs.flapPower;
            for (int side = 0; side < 2; side++)
            {
                float e = side == 0 ? leftEffort : rightEffort, wp = side == 0 ? w.leftPitch : w.rightPitch;
                float tilt = Mathf.Clamp(-wp * .7f, -.45f, .65f);
                Vector3 direction = (Vector3.up * Mathf.Cos(bank) + r * Mathf.Sin(bank)) * Mathf.Cos(tilt) + f * Mathf.Sin(tilt);
                float force = .5f * G * forceGain * e / .445f;
                float along = Vector3.Dot(direction, va);
                if (along > 0)
                    force = Mathf.Min(force, .5f * (1.08f * SizeRules.Climb(mass) + .4f) * prefs.flapPower * e / .445f / along);
                acceleration += direction * force * thin;
            }
            if (groundDistance < span * .5f && va.y < 0 && gamma > -.61f)
                acceleration.y += 1.5f * G * Mathf.Pow(1 - Mathf.Clamp01(groundDistance / (span * .5f)), 2) * Mathf.Min(1, -va.y);
            if (position.y > ceiling - 8)
                acceleration.y -= G * SizeRules.Smooth(ceiling - 8, ceiling, position.y);
            float oldYaw = yaw;
            velocity += acceleration * h;
            if (vh > vmin * .3f)
            {
                float desired = Mathf.Atan2(velocity.x - wind.x, velocity.z - wind.z);
                float delta = Mathf.DeltaAngle(yaw * Mathf.Rad2Deg, desired * Mathf.Rad2Deg) * Mathf.Deg2Rad;
                yaw += Mathf.Clamp(delta, -prefs.turnSpeed * Mathf.Deg2Rad * h, prefs.turnSpeed * Mathf.Deg2Rad * h);
            }
            turnRate = (yaw - oldYaw) / h;
            velocity = Vector3.ClampMagnitude(velocity, vmax * 1.4f);
            position += velocity * h;
            if (!float.IsFinite(position.sqrMagnitude))
            {
                position = Vector3.up * 30;
                velocity = Vector3.zero;
            }
        }
    }
}
