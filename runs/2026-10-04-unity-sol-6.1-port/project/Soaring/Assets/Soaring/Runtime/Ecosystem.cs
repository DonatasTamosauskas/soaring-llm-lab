using System;
using UnityEngine;
using UnityEngine.Rendering;
namespace Soaring
{
    public sealed class Ecosystem : MonoBehaviour
    {
        public ValleyWorld world; public PlayerFlight player; public GameSession game; public readonly BirdAgent[] birds = new BirdAgent[144]; public int population = 28; System.Random random = new(101);
        sealed class Batch
        {
            public Matrix4x4[] matrices = new Matrix4x4[160]; public Vector4[] poses = new Vector4[160]; public float[] highlights = new float[160]; public MaterialPropertyBlock block = new(); public int count;
        }
        SkyLife sky;
        Batch[,] batches = new Batch[10, 3]; [NonSerialized] public BirdAgent threat, prey; public float threatLevel; float nextCall;
        public void Initialize()
        {
            var displays = new System.Collections.Generic.List<UnityEngine.XR.XRDisplaySubsystem>();
            SubsystemManager.GetSubsystems(displays);
            population = Application.platform == RuntimePlatform.Android || displays.Exists(d => d.running) ? 28 : 60;
            for (int i = 0; i < birds.Length; i++)
                birds[i] = new BirdAgent { id = i };
            for (int i = 0; i < 10; i++)
                for (int j = 0; j < 3; j++)
                    batches[i, j] = new Batch();
            sky = new SkyLife(this);
            ResetPopulation();
        }
        float Range(float a, float b) => (float)(a + (b - a) * random.NextDouble());
        Vector3 RandomDirection()
        {
            float a = Range(0, Mathf.PI * 2);
            return new(Mathf.Sin(a), 0, Mathf.Cos(a));
        }
        public void ResetPopulation()
        {
            random = new(101);
            foreach (var p in world.content.perches)
                p.occupant = null;
            for (int i = 0; i < birds.Length; i++)
            {
                birds[i].alive = false;
                birds[i].perch = null;
            }
            for (int i = 0; i < population; i++)
                Spawn(birds[i], true);
            sky?.Reset();
            threat = prey = null;
        }
        void Spawn(BirdAgent b, bool initial = false)
        {
            int tier = SizeRules.Tier(player.model.mass);
            int slot = b.id % 10;
            b.tier = slot < 5 ? Mathf.Max(0, tier - 1 - (slot % 2)) : slot < 8 ? Mathf.Min(9, tier + 1 + (slot % 2)) : Mathf.Clamp(tier + random.Next(-2, 3), 0, 9);
            if (b.id % 10 == 0)
                b.tier = 0;
            b.mass = SizeRules.Ladder[b.tier].mass;
            b.alive = true;
            b.hidden = false;
            b.attacking = false;
            b.perch = null;
            b.target = null;
            b.stamina = Range(.6f, 1);
            b.phase = Range(0, 1);
            b.flock = b.id / 4;
            Vector3 direction = initial ? RandomDirection() : Quaternion.Euler(0, Range(-65, 65), 0) * player.model.Forward;
            float distance = Range(12, initial ? 180 : 70) * Mathf.Clamp(SizeRules.TimeScale(player.model.mass), 1, 2);
            b.position = player.model.position + direction * distance + Vector3.up * Range(-3, 18);
            float radius = new Vector2(b.position.x, b.position.z).magnitude;
            if (radius > world.content.bounds - 50)
                b.position *= .7f;
            b.position.y = Mathf.Max(b.position.y, world.Ground(b.position) + Range(3, 15));
            b.previous = b.position;
            b.heading = RandomDirection();
            b.velocity = b.heading * SizeRules.Cruise(b.mass);
            b.goal = b.position + b.heading * 40;
            b.state = BirdState.Cruise;
            b.thinkAt = Range(0, .8f);
            b.handlingUntil = 0;
            b.attackUntil = 0;
        }
        public BirdAgent SendAttacker()
        {
            BirdAgent best = null;
            float d = float.MaxValue;
            foreach (var b in birds)
            {
                if (b.pellet || !b.alive || b.hidden || !SizeRules.CanEat(b.mass, player.model.mass))
                    continue;
                float bd = (b.position - player.model.position).sqrMagnitude;
                if (bd < d)
                {
                    d = bd;
                    best = b;
                }
            }
            if (best == null)
            {
                foreach (var b in birds)
                    if (!b.pellet && b.alive && !b.attacking)
                    {
                        best = b;
                        break;
                    }
                if (best != null)
                {
                    best.tier = Mathf.Min(9, SizeRules.Tier(player.model.mass) + 1);
                    best.mass = SizeRules.Ladder[best.tier].mass;
                }
            }
            if (best != null)
            {
                Release(best);
                best.attacking = true;
                best.attackUntil = game.stats.duration + 22;
                best.state = BirdState.Hunt;
                best.thinkAt = 0;
                game.audio.BirdCall(best, true);
            }
            return best;
        }
        void Release(BirdAgent b)
        {
            if (b.perch != null && b.perch.occupant == b)
                b.perch.occupant = null;
            b.perch = null;
            b.hidden = false;
        }
        public void Remove(BirdAgent b)
        {
            Release(b);
            b.alive = false;
            b.stateUntil = game.stats.duration + Range(1.5f, 4);
        }
        void FixedUpdate()
        {
            if (!game.ready)
                return;
            if (game.phase != GamePhase.Flying && game.phase != GamePhase.Menu || game.phase == GamePhase.Flying && player.input.xrRunning && !player.input.tracking)
                return;
            float t = game.phase == GamePhase.Menu ? Time.unscaledTime : game.stats.duration, dt = Time.fixedDeltaTime;
            for (int i = 0; i < population; i++)
            {
                var b = birds[i];
                if (!b.alive)
                {
                    if (t >= b.stateUntil || game.phase == GamePhase.Menu)
                        Spawn(b);
                    continue;
                }
                b.previous = b.position;
                if ((b.position - player.model.position).sqrMagnitude > 360 * 360)
                {
                    Spawn(b);
                    continue;
                }
                if (t >= b.thinkAt)
                {
                    Think(b, t);
                    b.thinkAt = t + Range(.15f, .35f);
                }
                Move(b, dt, t);
            }
            sky.Step(dt, t);
            SelectCues();
            if (Time.unscaledTime > nextCall)
            {
                nextCall = Time.unscaledTime + Range(2, 5);
                var b = birds[random.Next(population)];
                if (b.alive && !b.hidden)
                    game.audio.BirdCall(b, false);
            }
        }
        void Think(BirdAgent b, float t)
        {
            if (b.state == BirdState.Hide)
            {
                if (t < b.stateUntil)
                    return;
                b.hidden = false;
                b.state = BirdState.Flee;
                b.stateUntil = t + 3;
            }
            if (b.state == BirdState.Rest)
            {
                if (t < b.stateUntil)
                {
                    b.stamina = Mathf.Min(1, b.stamina + .08f);
                    return;
                }
                Release(b);
                b.state = BirdState.Cruise;
                b.position += Vector3.up * b.Span;
            }
            if (b.attacking)
            {
                if (t > b.attackUntil || !SizeRules.CanEat(b.mass, player.model.mass) || world.Protected(player.model.position, b.Span))
                {
                    b.attacking = false;
                    game.stats.escapes++;
                    b.state = BirdState.Cruise;
                }
                else
                {
                    b.state = BirdState.Hunt;
                    b.goal = player.model.position + player.model.velocity * .35f;
                    return;
                }
            }
            Vector3 danger = Vector3.zero;
            float closest = 28 * 28;
            BirdAgent food = null;
            float bestFood = 0;
            foreach (var other in birds)
            {
                if (other == b || !other.alive || other.hidden)
                    continue;
                float d = (other.position - b.position).sqrMagnitude;
                if (SizeRules.CanEat(other.mass, b.mass) && d < closest)
                {
                    closest = d;
                    danger = other.position;
                }
                if (SizeRules.Worthwhile(b.mass, other.mass) && d < 65 * 65)
                {
                    float value = SizeRules.MealValue(b.mass, other.mass) / (1 + Mathf.Sqrt(d));
                    if (value > bestFood)
                    {
                        bestFood = value;
                        food = other;
                    }
                }
            }
            float playerDistance = (player.model.position - b.position).sqrMagnitude;
            if (game.phase == GamePhase.Flying && SizeRules.CanEat(player.model.mass, b.mass) && playerDistance < closest)
            {
                closest = playerDistance;
                danger = player.model.position;
            }
            if (closest < 28 * 28)
            {
                Release(b);
                b.state = BirdState.Flee;
                b.goal = b.position + (b.position - danger).normalized * 35 + Vector3.down * Range(0, 4);
                var refuge = world.NearestRefuge(b.position, b.Span);
                if (refuge.radius > 0 && (refuge.position - b.position).sqrMagnitude < 45 * 45)
                {
                    b.goal = refuge.position;
                    if ((b.position - refuge.position).sqrMagnitude < refuge.radius * refuge.radius)
                    {
                        b.state = BirdState.Hide;
                        b.hidden = true;
                        b.velocity = Vector3.zero;
                        b.stateUntil = t + Range(3, 10);
                    }
                }
                return;
            }
            if (b.stamina < .2f)
            {
                var perch = world.NearestPerch(b.position, b.Span, 80);
                if (perch != null)
                {
                    b.goal = perch.position + Vector3.up * b.Radius;
                    b.state = BirdState.Rest;
                    b.perch = perch;
                    perch.occupant = b;
                    b.stateUntil = t + Range(4, 10);
                    return;
                }
            }
            if (food != null && b.stamina > .3f && b.tier >= 2)
            {
                b.state = BirdState.Hunt;
                b.target = food;
                b.goal = food.position + food.velocity * .3f;
                return;
            }
            if (b.tier >= 6 && b.stamina < .65f)
            {
                var th = world.content.thermals[b.id % world.content.thermals.Length];
                float a = t * .28f + b.id;
                b.goal = th.position + new Vector3(Mathf.Cos(a) * th.radius * .45f, Mathf.Clamp(b.position.y + 3, 20, 160), Mathf.Sin(a) * th.radius * .45f);
                b.state = BirdState.Soar;
                return;
            }
            b.state = b.tier <= 4 ? BirdState.Flock : BirdState.Cruise;
            b.target = null;
            float angle = t * .11f + b.flock * .7f;
            Vector3 centre = player.model.position + Quaternion.Euler(0, b.flock * 57 % 360, 0) * player.model.Forward * (30 + 12 * b.flock % 100);
            b.goal = centre + new Vector3(Mathf.Cos(angle) * 23, 6 + Mathf.Sin(angle * .3f) * 5, Mathf.Sin(angle) * 23);
            if (b.tier == 0)
                b.goal = centre + new Vector3(Mathf.Sin(t + b.id) * 5, 2 + Mathf.Sin(t * .7f + b.id), Mathf.Cos(t + b.id) * 5);
        }
        void Move(BirdAgent b, float dt, float time)
        {
            if (b.hidden)
                return;
            if (b.state == BirdState.Rest && b.perch != null && (b.position - b.goal).sqrMagnitude < Mathf.Pow(b.Span + .25f, 2))
            {
                b.position = b.goal;
                b.velocity = Vector3.zero;
                b.fold = Mathf.MoveTowards(b.fold, 1, dt * 4);
                return;
            }
            Vector3 desired = (b.goal - b.position).normalized;
            float ground = world.Ground(b.position);
            if (b.position.y < ground + 2 + b.Span)
                desired = (desired + Vector3.up * 1.7f).normalized;
            if (Physics.SphereCast(b.position, b.Radius, b.heading, out var obstruction, Mathf.Max(4, b.velocity.magnitude * .6f), ValleyWorld.SolidMask, QueryTriggerInteraction.Ignore))
                desired = (desired + obstruction.normal * 2 + Vector3.up).normalized;
            float radius = new Vector2(b.position.x, b.position.z).magnitude;
            if (radius > world.content.bounds - 35)
                desired = (-new Vector3(b.position.x, 0, b.position.z).normalized + Vector3.up * .15f).normalized;
            if (b.position.y > 230)
                desired.y = -.4f;
            if (b.attacking && (b.position - player.model.position).magnitude < b.velocity.magnitude * .4f && b.committedUntil <= time)
            {
                b.committedHeading = b.heading;
                b.committedUntil = time + .4f;
            }
            if (b.attacking && b.committedUntil > time)
                desired = b.committedHeading;
            float turn = SizeRules.TurnRate(b.mass) * dt * (b.attacking ? .8f : 1);
            Vector3 old = b.heading;
            b.heading = Vector3.RotateTowards(b.heading, desired, turn, 0).normalized;
            float speed = SizeRules.Cruise(b.mass) * (b.state == BirdState.Flee ? 1.3f : b.state == BirdState.Hunt ? 1.22f : b.state == BirdState.Rest ? .5f : b.tier == 0 ? .35f : .9f);
            Vector3 wind = world.Wind(b.position, time);
            float vy = Mathf.Clamp(b.heading.y * speed + wind.y, -speed * .6f, SizeRules.Climb(b.mass) + wind.y);
            var target = b.heading * speed + new Vector3(wind.x, 0, wind.z) * .4f;
            target.y = vy;
            b.velocity = Vector3.MoveTowards(b.velocity, target, 15 * dt);
            Vector3 delta = b.velocity * dt;
            if (Physics.SphereCast(b.position, b.Radius, delta.normalized, out var hit, delta.magnitude, ValleyWorld.SolidMask, QueryTriggerInteraction.Ignore))
            {
                b.velocity = Vector3.ProjectOnPlane(b.velocity, hit.normal);
                delta = b.velocity * dt;
            }
            b.position += delta;
            b.position.y = Mathf.Clamp(b.position.y, ground + b.Radius + .05f, world.content.ceiling - 10);
            float yawDelta = Vector3.SignedAngle(old, b.heading, Vector3.up);
            b.bank = Mathf.Lerp(b.bank, Mathf.Clamp(-yawDelta / Mathf.Max(dt, .001f) * .006f, -1.1f, 1.1f), 1 - Mathf.Exp(-dt / .15f));
            b.stamina = Mathf.Clamp01(b.stamina + (b.state == BirdState.Soar ? .035f : -.004f) * dt);
            b.flapAmount = b.state == BirdState.Soar ? .05f : b.tier == 0 ? 1 : .65f;
            b.phase = Mathf.Repeat(b.phase + dt * Mathf.Lerp(4, 1.3f, b.tier / 9f), 1);
            b.fold = Mathf.MoveTowards(b.fold, b.heading.y < -.55f ? .7f : 0, dt * 3);
        }
        void SelectCues()
        {
            threat = prey = null;
            threatLevel = 0;
            float best = float.MaxValue;
            foreach (var b in birds)
            {
                if (!b.alive || b.hidden)
                    continue;
                float d = Vector3.Distance(b.position, player.model.position);
                if (b.attacking)
                {
                    float level = Mathf.Clamp01(1 - d / 90);
                    if (level > threatLevel)
                    {
                        threatLevel = level;
                        threat = b;
                    }
                }
                if (SizeRules.Worthwhile(player.model.mass, b.mass) && d < best && Vector3.Dot(player.model.Forward, (b.position - player.model.position).normalized) > -.1f && world.Clear(player.model.position, b.position, player.Radius))
                {
                    best = d;
                    prey = b;
                }
            }
        }
        void AddToBatch(BirdAgent b, bool highlight)
        {
            float d = Vector3.Distance(player.model.position, b.position);
            float angle = b.Span / Mathf.Max(d, .001f);
            int lod = angle > .05f ? 0 : angle > .016f ? 1 : 2;
            var batch = batches[b.tier, lod];
            int index = batch.count++;
            Quaternion rotation = Quaternion.LookRotation(b.heading) * Quaternion.AngleAxis(b.bank * Mathf.Rad2Deg, Vector3.forward);
            batch.matrices[index] = Matrix4x4.TRS(b.position, rotation, Vector3.one * b.Span);
            batch.poses[index] = new(b.phase, b.flapAmount, b.fold, b.perch != null && b.velocity.sqrMagnitude < .01f ? 1 : 0);
            batch.highlights[index] = highlight && game.phase == GamePhase.Flying ? (SizeRules.Worthwhile(player.model.mass, b.mass) ? 1 : SizeRules.CanEat(b.mass, player.model.mass) ? 2 : 0) : 0;
        }
        void LateUpdate()
        {
            if (world == null || world.content == null || batches[0, 0] == null)
                return;
            for (int i = 0; i < 10; i++)
                for (int j = 0; j < 3; j++)
                    batches[i, j].count = 0;
            foreach (var b in birds)
            {
                if (!b.alive || b.hidden)
                    continue;
                AddToBatch(b, true);
            }
            foreach (var b in sky.murmuration)
                if (b.alive)
                    AddToBatch(b, false);
            for (int i = 0; i < 10; i++)
                for (int j = 0; j < 3; j++)
                {
                    var b = batches[i, j];
                    if (b.count == 0)
                        continue;
                    b.block.SetVectorArray("_BirdPose", b.poses);
                    b.block.SetFloatArray("_BirdHighlight", b.highlights);
                    Graphics.DrawMeshInstanced(world.content.species[i].lods[j], 0, world.content.birdMaterial, b.matrices, b.count, b.block, j < 2 ? ShadowCastingMode.On : ShadowCastingMode.Off, true, 0, null, LightProbeUsage.Off);
                }
        }
    }
}
