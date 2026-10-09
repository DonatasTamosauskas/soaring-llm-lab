using UnityEngine;
using UnityEngine.Rendering;
namespace Soaring
{
    public sealed class PlayerFlight : MonoBehaviour
    {
        public VRInput input; public ValleyWorld world; public GameSession game; [System.NonSerialized] public FlightModel model = new(); public bool perched = true; public Perch perch;
        public Vector3 previousPosition; public float protectionUntil, stunUntil; float lastFlap, lastHaptic, visualYaw, scale = .141f;
        Vector3 baselineHead; bool captureHead = true;
        public void RecenterRig() => captureHead = true;
        public float Span => SizeRules.Span(model.mass); public float Radius => Span * .16f;
        public void Spawn(bool resetMass = false)
        {
            if (resetMass)
                model.mass = SizeRules.StartMass;
            perch = world.NearestPerch(world.content.spawn, Span, 600, false);
            Vector3 p = perch != null ? perch.position + Vector3.up * Radius : world.content.spawn;
            Vector3 forward = perch != null ? perch.facing : world.content.spawnFacing;
            model.Reset(p, forward);
            previousPosition = p;
            perched = true;
            visualYaw = model.yaw * Mathf.Rad2Deg;
            protectionUntil = game.stats.duration + 5;
            lastFlap = game.stats.duration - 2;
            stunUntil = 0;
            scale = Span / (input.preferences.reach * 2 + .2f);
            captureHead = true;
            ApplyRigPose();
        }
        void FixedUpdate()
        {
            if (game.phase != GamePhase.Flying)
                return;
            if (input.xrRunning && !input.tracking)
                return;
            float dt = Time.fixedDeltaTime;
            previousPosition = model.position;
            var wings = input.wings;
            if (wings.leftFlap + wings.rightFlap > .2f)
                lastFlap = game.stats.duration;
            if (perched)
            {
                if (wings.leftFlap + wings.rightFlap > .18f)
                {
                    perched = false;
                    perch = null;
                    model.velocity = model.Forward * SizeRules.Cruise(model.mass) * .48f + Vector3.up * 2;
                    model.position += Vector3.up * Span * .3f;
                    stunUntil = game.stats.duration + .5f;
                    game.audio.Wingbeat();
                    input.Haptic(.22f);
                }
                return;
            }
            if (game.stats.duration < stunUntil)
            {
                wings.roll *= .2f;
                wings.pitch = Mathf.Min(0, wings.pitch);
            }
            float ground = GroundBeneath();
            model.Step(wings, world.Wind(model.position, game.stats.duration), ground, world.content.ceiling, dt, input.preferences);
            Vector3 delta = model.position - previousPosition;
            float distance = delta.magnitude;
            if (distance > .00001f && Physics.SphereCast(previousPosition, Radius, delta / distance, out var hit, distance + .002f, ValleyWorld.SolidMask, QueryTriggerInteraction.Ignore))
            {
                model.position = previousPosition + delta.normalized * Mathf.Max(0, hit.distance - .002f);
                float impact = -Vector3.Dot(model.velocity, hit.normal);
                var fit = world.NearestPerch(hit.point, Span, Span * .75f);
                if (game.stats.duration - lastFlap > 1.2f && model.airspeed < SizeRules.Cruise(model.mass) * .6f && fit != null)
                {
                    perch = fit;
                    perched = true;
                    model.position = fit.position + Vector3.up * Radius;
                    model.velocity = Vector3.zero;
                    game.audio.Cue("perch");
                }
                else if (hit.normal.y > .55f && model.airspeed < SizeRules.Cruise(model.mass) * .5f && game.stats.duration - lastFlap > 1.2f)
                {
                    model.velocity = Vector3.MoveTowards(Vector3.ProjectOnPlane(model.velocity, hit.normal), Vector3.zero, 6 * dt);
                    if (model.velocity.magnitude < .6f)
                    {
                        perched = true;
                        perch = null;
                        model.velocity = Vector3.zero;
                    }
                }
                else
                {
                    model.velocity = Vector3.ProjectOnPlane(model.velocity, hit.normal);
                    if (impact > SizeRules.Cruise(model.mass) * .4f)
                    {
                        model.velocity += hit.normal * impact * .2f;
                        stunUntil = game.stats.duration + .6f;
                        input.Haptic(.55f, .12f);
                        game.audio.Cue("collision");
                    }
                }
                if (world.Water(hit.point))
                {
                    model.velocity.y = 2;
                    model.position.y = Mathf.Max(model.position.y, 0);
                    input.Haptic(.3f);
                }
            }
            float radius = new Vector2(model.position.x, model.position.z).magnitude;
            if (radius > world.content.bounds - Radius)
            {
                var outward = new Vector3(model.position.x, 0, model.position.z).normalized;
                model.position -= outward * (radius - world.content.bounds + Radius);
                model.velocity -= outward * Mathf.Max(0, Vector3.Dot(model.velocity, outward));
            }
            model.position.y = Mathf.Min(model.position.y, world.content.ceiling - Radius);
            if (wings.leftFlap + wings.rightFlap > .6f && Time.unscaledTime - lastHaptic > .28f)
            {
                lastHaptic = Time.unscaledTime;
                input.Haptic(.12f);
                game.audio.Wingbeat();
            }
        }
        float GroundBeneath()
        {
            return Physics.Raycast(model.position + Vector3.up * Radius, Vector3.down, out var h, 1000, ValleyWorld.SolidMask, QueryTriggerInteraction.Ignore) ? h.point.y : -1;
        }
        void LateUpdate()
        {
            if (game.ready)
                ApplyRigPose();
        }
        void ApplyRigPose()
        {
            float desired = Span / (input.preferences.reach * 2 + .2f);
            scale = Mathf.Lerp(scale, desired, 1 - Mathf.Exp(-Time.unscaledDeltaTime / .45f));
            input.origin.transform.localScale = Vector3.one * scale;
            float heading = model.yaw * Mathf.Rad2Deg;
            visualYaw = Mathf.MoveTowardsAngle(visualYaw, heading, input.preferences.turnSpeed * Time.unscaledDeltaTime);
            input.origin.transform.rotation = Quaternion.Euler(0, visualYaw, 0);
            // Anchor the neutral head pose, preserving all subsequent physical
            // head movement. Recomputing this offset every frame cancels 6DoF.
            if (captureHead)
            {
                baselineHead = input.origin.transform.InverseTransformPoint(input.eye.transform.position);
                captureHead = false;
            }
            input.origin.transform.position = model.position - input.origin.transform.rotation * (baselineHead * scale);
            input.eye.nearClipPlane = Mathf.Max(.001f, .018f * scale);
            input.eye.farClipPlane = 1800;
        }
    }
}
